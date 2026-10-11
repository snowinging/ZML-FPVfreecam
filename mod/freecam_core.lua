-- 自由镜头底层相机装置：接管主相机、每帧写入最终位姿。
-- 约定：这一层不抛异常，所有失败都返回 nil/false + 原因码，由上层决定怎么办。
local U=CS.UnityEngine
local V,Q=U.Vector3,U.Quaternion
local function live(o) return o~=nil and not o:Equals(nil) end
local function copy(v) return V(v.x,v.y,v.z) end
local function near(a,b) return math.abs(a-b)<.001 end

local function viewGates(l)
    local pc=GameInstance.playerController
    local mgr=GameInstance.cameraManager
    local level=mgr and mgr:GetMainLevelCameraController()
    local brain=mgr and mgr.cinemachineBrainCpt
    local active=live(brain) and brain.ActiveVirtualCamera or nil
    local tempCamera=false
    if mgr~=nil then tempCamera=not mgr:IsCommonTempControllerActive() end
    return {
        focus=U.Application.isFocused,
        gameplay=GameInstance.isInGameplay,
        blocked_input=pc==nil or not pc.blockPlayerInput,
        cursor=not InputManager.cursorVisible,
        phase_level=UIUtils.IsPhaseLevelOnTop(),
        top_view=not LuaSystemManager.factory.inTopView,
        ability=not Utils.isInCustomAbility(),
        temp_camera=tempCamera,
        controller=mgr~=nil and level~=nil and mgr.curActiveController==level,
        active_camera=live(brain) and level~=nil and (active==level.virtualCamera or
            (l and live(l.virtual) and active==l.virtual and not l.releasing)),
    }
end

return function(P)
    -- 注意：不含 blocked_input —— 那个是过场/菜单在用的，不能拿它把自己判出局。
    local GATE_KEYS={'focus','gameplay','cursor','phase_level','top_view','ability','temp_camera','controller','active_camera'}
    -- 必须把当前 lease 传进来：不然自己接管的相机会被 active_camera 门判成"被别人抢了"。
    function P.available(l)
        local g=viewGates(l or nil)
        for _,k in ipairs(GATE_KEYS) do if not g[k] then return false,k end end
        return true
    end
    function P.capture()
        local mgr=GameInstance.cameraManager
        if mgr==nil then return nil,'camera_manager' end
        local cam=mgr.mainCamera
        if not live(cam) then return nil,'main_camera' end
        local brain=mgr.cinemachineBrainCpt
        if not live(brain) then return nil,'brain' end
        local ctrl=mgr:GetMainLevelCameraController()
        if ctrl==nil then return nil,'controller' end
        local e=cam.transform.eulerAngles
        local pitch=e.x
        if pitch>180 then pitch=pitch-360 end
        return {manager=mgr,camera=cam,brain=brain,originalController=ctrl,
            originalFov=cam.fieldOfView,originalNear=cam.nearClipPlane,
            position=copy(cam.transform.position),yaw=e.y,pitch=pitch,objects={}}
    end
    function P.install(l,c)
        l.objects=l.objects or {}
        local go=U.GameObject('ZML Freecam Camera')
        if go==nil then return false,'game_object' end
        l.objects[#l.objects+1]=go
        go.transform:SetParent(l.manager.virtualCamsRoot,false)
        local vc=go:AddComponent(typeof(CS.Cinemachine.CinemachineVirtualCamera))
        if vc==nil then return false,'virtual_camera' end
        l.virtual=vc
        vc.Priority=-100
        local lens=vc.m_Lens
        lens.NearClipPlane=.035;lens.FarClipPlane=l.camera.farClipPlane;lens.FieldOfView=c.fov
        vc.m_Lens=lens
        local rot=Q.Euler(l.pitch,l.yaw,0)
        vc:ForceCameraPosition(l.position,rot)
        local ok,id=pcall(function() return l.brain:SetCameraOverride(-1,nil,vc,1,0) end)
        if not ok or type(id)~='number' or id<0 then return false,'override_rejected' end
        l.overrideId=id
        l.activationFrame=U.Time.frameCount
        l.lastPosition,l.lastRotation=copy(l.position),rot
        l.installed=true
        l.released=false
        return true
    end
    function P.ownsCamera(l)
        if l==nil or l.released or l.releasing then return false end
        if l.overrideId==nil then return false end
        local ok,owned=pcall(function()
            if not live(l.virtual) or not live(l.brain) then return false end
            if l.manager.curActiveController~=l.originalController then return false end
            return l.brain.ActiveVirtualCamera==l.virtual or
                (U.Time.frameCount==l.activationFrame and l.brain.ActiveVirtualCamera==l.originalController.virtualCamera)
        end)
        return ok and owned==true
    end
    -- 早于相机求值的一次写入：把虚拟相机推到目标位姿并续租 override。
    function P.pose(l,position,rotation,dt,c)
        if l.released or l.releasing then return false,'releasing' end
        if not live(l.virtual) or not live(l.camera) then return false,'rig_destroyed' end
        if l.overrideId==nil then return false,'override_lost' end
        if l.lastFovApplied~=c.fov then l.virtual:SetFieldOfView(c.fov);l.lastFovApplied=c.fov end
        l.virtual:ForceCameraPosition(position,rotation)
        -- dt 传 0：只是续租，不要每帧重启一次混合，否则 Cinemachine 会持续重算。
        local ok,handle=pcall(function() return l.brain:SetCameraOverride(l.overrideId,nil,l.virtual,1,0) end)
        if not ok or handle~=l.overrideId then
            l.overrideId=nil
            return false,'override_lost'
        end
        -- 把游戏自己那套相机参数一起跟过来，退出时才不会被旧角度拽回去。
        if not l.angleFailed then
            local p=l.originalController and l.originalController.param
            if p==nil then l.angleFailed=true
            elseif not pcall(function() p:SetHorizontalAngle(rotation.eulerAngles.y,false) end) then l.angleFailed=true end
        end
        l.lastPosition,l.lastRotation,l.lastFov=copy(position),rotation,c.fov
        return true
    end
    -- 所有 Lua 更新跑完之后的一次硬写入，绕过 Cinemachine 的混合。
    function P.commit(l,c)
        if l.released or l.releasing then return false end
        if not live(l.camera) then return false end
        l.camera.transform:SetPositionAndRotation(l.lastPosition,l.lastRotation)
        if not near(l.camera.fieldOfView,c.fov) then l.camera.fieldOfView=c.fov end
        if not near(l.camera.nearClipPlane,.035) then l.camera.nearClipPlane=.035 end
        l.actualOwned=true
        return true
    end
    -- 幂等释放：override 先还，再还原相机，最后才销毁自己造的物件。
    -- 任何一步失败都不会把 lease 弄成半死状态，下次调用接着做没做完的部分。
    function P.release(l)
        if l==nil then return true end
        if l.released then return true end
        l.releasing=true
        local success=true
        local failStep=nil
        local function attempt(step,fn)
            if not pcall(fn) then success=false;failStep=failStep or step end
        end

        -- 0) 先记下"相机原本该由谁驱动"，必须在放 override 之前判断。
        if l.actualOwned and l.restoreActual==nil then
            local ok,val=pcall(function()
                return l.manager.curActiveController==l.originalController and live(l.virtual) and
                    (l.brain.ActiveVirtualCamera==l.virtual or
                     l.brain.ActiveVirtualCamera==l.originalController.virtualCamera)
            end)
            l.restoreActual=(ok and val) and true or false
        end

        -- 1) 还 override：放不掉就留着 id，下次继续放，绝不能带着句柄砸物件。
        if l.overrideId~=nil then
            local ok=pcall(function()
                if live(l.brain) then l.brain:ReleaseCameraOverride(l.overrideId) end
            end)
            if ok then l.overrideId=nil else success=false;failStep=failStep or 1 end
        end

        -- 2) 还原相机镜片/视野（只有我们硬写过才还原）
        if l.actualOwned then attempt(2,function()
            if l.restoreActual and live(l.camera) then
                if near(l.camera.nearClipPlane,.035) then l.camera.nearClipPlane=l.originalNear end
                if near(l.camera.fieldOfView,l.lastFov or l.originalFov) then l.camera.fieldOfView=l.originalFov end
            end
            l.actualOwned=false
        end) end

        -- 3) override 清干净了才销毁物件
        if success and l.overrideId==nil then
            for i=#l.objects,1,-1 do
                local o=l.objects[i]
                l.objects[i]=nil
                attempt(3,function() if live(o) then U.Object.Destroy(o) end end)
            end
            l.installed=false
            l.released=true
        end
        return success,failStep
    end
    -- 兜底：不管成功与否，把句柄和物件都丢掉，至少让相机能回到原控制器。
    function P.releaseHard(l)
        if l==nil then return true end
        if l.overrideId~=nil then
            pcall(function() if live(l.brain) then l.brain:ReleaseCameraOverride(l.overrideId) end end)
            l.overrideId=nil
        end
        for i=#(l.objects or {}),1,-1 do
            local o=l.objects[i]
            l.objects[i]=nil
            pcall(function() if live(o) then U.Object.Destroy(o) end end)
        end
        l.actualOwned=false
        l.installed=false
        l.released=true
        return true
    end
    return P
end
