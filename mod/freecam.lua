-- 自由镜头（FreeCam）：脱开角色，用键鼠自由飞行的观察相机。
local U=CS.UnityEngine
local V,Q=U.Vector3,U.Quaternion
local K=U.KeyCode
local ID='freecam'
local traceback=debug and debug.traceback or function(e) return tostring(e) end
assert(not rawget(_G,'ZMLFreecam'),'freecam namespace occupied')
local function live(o) return o~=nil and not o:Equals(nil) end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function angle(x) return (x+180)%360-180 end

local function settingsApi()
    local f=assert(loadstring(LuaManagerInst:LoadLua('ZML/Api'),'@ZML/Api'))
    return f()
end
local api=settingsApi()

local M={}                                   -- 先占好名字，reportEvent 要引用它
local INST=(rawget(_G,'ZMLFreecamInst') or 0)+1
rawset(_G,'ZMLFreecamInst',INST)

-- 报点：事件名走 api.report（只收 a-z0-9_:-），同名事件限流，错误详情走 logger 且限次。
local lastEvent,lastEventAt,loggedErrors=nil,-1,0
local pushText                      -- 由下面 FPV 那半接上：出错时把完整正文写进模组日志
local FPV                           -- 遥控接管那半，见文件下方 ZMLFCFpv（必须在 announce 之前声明）
local function reportEvent(event,err)
    local now=U.Time.realtimeSinceStartup
    event=tostring(event)
    if not (event==lastEvent and now-lastEventAt<1) then
        lastEvent,lastEventAt=event,now
        pcall(api.report,ID,event)
    end
    if err then
        -- 报错正文顺手编成一个合法事件名，这样在 runtime.log 里直接看得见，不依赖 logger。
        -- 但事件名只有 60 字符，够看是哪一行、看不到变量名，所以正文再走一遍中文日志通道。
        pcall(api.report,ID,'err_'..tostring(err):lower():gsub('[^a-z0-9]',''):sub(1,60))
        if pushText then
            local text=tostring(err)
            for i=1,math.min(4,math.max(1,math.ceil(#text/150))) do
                pcall(pushText,'freecam 出错：'..text:sub((i-1)*150+1,i*150))
            end
        end
    end
    if err and loggedErrors<3 then
        loggedErrors=loggedErrors+1
        pcall(function()
            logger.error('ZML FreeCam: '..event..': '..tostring(err):gsub('[%c]',' '):sub(1,512))
        end)
    end
end
local P={report=reportEvent}

-- 游戏内弹提示：各版本 UI 入口名字不一样，挨个试；一个都不成也只是说不了话，功能照旧。
local toasts,toastProbed
local function toast(text)
    if not toastProbed then
        toastProbed=true
        toasts={}
        pcall(require_ex,'Common/Utils/UIUtils')      -- 顺手把 UIUtils 带进 _G
        for _,holder in ipairs({'UIUtils','TipsManager','TipManager','TipsModule','MessageTip'}) do
            local t=rawget(_G,holder)
            if type(t)=='table' then
                for _,f in ipairs({'ShowTips','ShowTip','ShowCommonTips','ShowMessage','Show'}) do
                    if type(t[f])=='function' then toasts[#toasts+1]={t,f};break end
                end
            end
        end
    end
    for _,c in ipairs(toasts or {}) do
        if pcall(c[1][c[2]],text) then return true end
    end
    return false
end

-- 按键取上升沿：keybinds 的 pressed() 是边沿语义，但万一某个版本给的是"按住"，
-- 那就靠上一帧的状态自己造边沿，免得按一下连翻好几次。
local keyHeld={}
local function pressedEdge(name,handle)
    if handle==nil then return false end
    local ok,down=pcall(handle.pressed)
    down=(ok and down) and true or false
    local was=keyHeld[name]
    keyHeld[name]=down
    return down and not was
end

-- 说一句人话：优先借 C++ 那半的模组日志（正文可读），再试游戏内提示，
-- 最后至少留个事件名在 runtime.log 里，让人知道按了什么。
local function announce(text)
    text=tostring(text)
    local viaLog=FPV and FPV.log and pcall(FPV.log,text) or false
    local viaToast=toast(text)
    if not pcall(function() logger.info('ZML FreeCam: '..text) end) then
        pcall(function() logger.error('ZML FreeCam: '..text) end)
    end
    reportEvent('say_'..(viaLog and 'l' or 'n')..(viaToast and 't' or 'n'))
end

local action,handles,unsubscribe
local MOVE_ACTIONS={
    {key='f',id='forward',label='前进',primary='I'},
    {key='b',id='back',label='后退',primary='K'},
    {key='l',id='left',label='左移',primary='J'},
    {key='r',id='right',label='右移',primary='L'},
    {key='u',id='up',label='上升',primary='U'},
    {key='d',id='down',label='下降',primary='O'},
    {key='boost',id='boost',label='加速',primary='LeftShift'},
}
-- 遥控接管在游戏内的三个键，都进游戏原生按键设置，绑什么主人自己改。
-- 这三个键本身就是检测：按键列表里能看见它们，说明模组加载上了。
local FPV_ACTIONS={
    {key='recv',id='fpv_recv',label='遥控接收开关',primary='Ctrl+F7'},
    {key='force',id='fpv_force',label='遥控强制接管',primary='Ctrl+F8'},
    {key='check',id='fpv_check',label='遥控链路自检',primary='Ctrl+F9'},
}
local function ensureKeys()
    require_ex('Common/Utils/UIUtils')
    if not rawget(_G,'ZMLKeybinds') then require_ex('UI/Panels/GameSetting/GameSettingCtrl') end
    local k=assert(rawget(_G,'ZMLKeybinds'),'keybinds dependency unavailable')
    assert(k.api==1,'keybinds version unavailable')
    if k._attachGate then k._attachGate() end
    action=k.find(ID,'toggle') or assert(k.register(ID,{id='toggle',name='自由镜头 · 开关',primary='Ctrl+F6',secondary='None'}))
    assert(type(action.pressed)=='function','keybinds continuous input API required')
    -- 六向移动 + 加速都丢进游戏原生的按键设置里，各自单独绑。
    M.acts={}
    local n=0
    for _,def in ipairs(MOVE_ACTIONS) do
        local h=k.find(ID,def.id)
        if h==nil then h=k.register(ID,{id=def.id,name='自由镜头 · '..def.label,primary=def.primary,secondary='None'}) end
        if h~=nil and type(h.down)=='function' then M.acts[def.key]=h;n=n+1 end
    end
    M.bound=n
    -- 这三个键不管有没有 FPV 模块都注册：看得见它们，就说明模组加载上了。
    -- 真按下去而没有 FPV 模块，就当面说清楚，别装死。
    M.fpvKeys={}
    for _,def in ipairs(FPV_ACTIONS) do
        local h=k.find(ID,def.id)
        if h==nil then h=k.register(ID,{id=def.id,name='自由镜头 · '..def.label,primary=def.primary,secondary='None'}) end
        if h~=nil and type(h.pressed)=='function' then M.fpvKeys[def.key]=h end
    end
end
function P.pressed() return action and action.pressed() or false end

-- 移动输入：直接读按键状态，不再猜 Unity 轴映射（轴只留作兜底）。
-- 兜底键位：故意和角色的 WASD 完全错开，这样即使原生绑定读不到，也不会跟角色抢键。
local KEY_SET={f={K.I},b={K.K},l={K.J},r={K.L},up={K.U},dn={K.O},
    boost={K.LeftShift,K.RightShift}}
local input={probed=false}
local function keySet() return KEY_SET end
local function keyDown(k)
    if not input.keyOk then return false end
    local ok,down=pcall(U.Input.GetKey,k)
    if not ok then input.keyOk=false;return false end
    return down and true or false
end
local function anyDown(list)
    for i=1,#list do if keyDown(list[i]) then return true end end
    return false
end
local function probeInput()
    local k=keySet()
    input.keyOk=pcall(function() return U.Input.GetKey(k.f[1]) end) and true or false
    local ok=pcall(function() return InputManagerInst:GetAxis('Mouse X') end)
    if ok then input.axis=function(n) return InputManagerInst:GetAxis(n) end
    else
        local ok2=pcall(function() return U.Input.GetAxis('Mouse X') end)
        if ok2 then input.axis=function(n) return U.Input.GetAxis(n) end end
    end
    input.probed=true
    reportEvent(string.format('probe_i%d_k%d_a%d_b%d',INST,input.keyOk and 1 or 0,input.axis and 1 or 0,M.bound or 0))
end
local function axis(name)
    if not input.axis then return 0 end
    local ok,v=pcall(input.axis,name)
    if not ok or type(v)~='number' then return 0 end
    return v
end

M=ZMLFCFactory(P)
-- 遥控接管：模组 C++ 侧注入的模块。C++ 那层只相当于调掉了外壳，ZMLFCFpv 还是工厂，
-- 得自己再叫一声；拼装方式见 src/plugin.cpp 的 start()。拿不到就当没这功能，键鼠照常。
local fpvMod=ZMLFCFpv
if type(fpvMod)=='function' then pcall(function() fpvMod=fpvMod() end) end
FPV=(type(fpvMod)=='table') and fpvMod or nil
if FPV and type(FPV.log)=='function' then pushText=FPV.log end

local function number(v,name,lo,hi,fallback)
    local x=v[name]
    if x==nil then return fallback end
    x=tonumber(x)
    if x==nil or x~=x or x<lo or x>hi then reportEvent('cfg_bad_'..name);return fallback end
    return x
end
local function bool(v,name,fallback)
    local x=v[name]
    if x==nil then return fallback end
    x=tostring(x)
    if x~='true' and x~='false' then reportEvent('cfg_bad_'..name);return fallback end
    return x=='true'
end
function M.configure(v)
    v=v or {}
    local c={}
    c.fov=number(v,'fov',40,120,90)
    c.sensitivity=number(v,'sensitivity',.2,8,2)
    c.speed=number(v,'speed',.5,60,8)
    c.boost=number(v,'boost',1,10,4)
    c.smoothing=number(v,'smoothing',0,.4,.12)
    c.pitch_limit=number(v,'pitch_limit',40,90,89)
    c.invert_y=bool(v,'invert_y',false)
    c.enabled=bool(v,'enabled',true)
    c.fpv=bool(v,'fpv',true)                 -- 允许遥控器（辅助程序）接管
    c.fpv_scale=number(v,'fpv_scale',.2,4,1) -- 角速率倍率
    c.fpv_limit=number(v,'fpv_limit',20,89,60) -- 俯仰/横滚角上限
    c.fpv_selflevel=bool(v,'fpv_selflevel',true)     -- mode 开关在关位时自稳（松杆回平）
    c.fpv_level_speed=number(v,'fpv_level_speed',10,400,90) -- 自稳回平速度（度/秒）
    M.settings=c
    if not c.enabled then M.wanted=false;M.release(true) end
end

-- 释放：幂等 + 限次重试，试完还不行就强拆，绝不把 lease 留成半死状态。
function M.release(force)
    if M.releasing then return false end
    local l=M.lease
    if l==nil then return true end
    M.releaseTries=(M.releaseTries or 0)+1
    M.releasing=true
    local ok,done=pcall(P.release,l)
    M.releasing=nil
    if ok and done==true then
        M.lease=nil;M.velocity=nil;M.stale=0;M.releaseTries=0
        return true
    end
    if force or M.releaseTries>45 then
        pcall(P.releaseHard,l)
        M.lease=nil;M.velocity=nil;M.stale=0;M.releaseTries=0
        reportEvent('release_forced',(not ok and done) or (done~=true and ('step'..tostring(done))) or nil)
        return true
    end
    if M.releaseTries==1 then reportEvent('release_retry',ok and nil or done) end
    return false
end
function M.toggle()
    local now=U.Time.realtimeSinceStartup
    if M.toggleAt and now-M.toggleAt<.25 then return end     -- 边沿触发防抖
    M.toggleAt=now
    if not M.settings or not M.settings.enabled then return end
    if M.wanted then
        M.wanted=false
        reportEvent('disarmed')
        M.release()
        return
    end
    if M.lease then M.release(true) end                     -- 残留的接管先清干净再进场
    M.failed=false;M.faultCount=0;M.faultLogged=false;M.stale=0
    local ok,why=P.available(nil)
    if not ok then reportEvent('gate_'..tostring(why));return end
    if not input.probed then pcall(probeInput) end
    M.wanted=true
    reportEvent('armed')
end
function M.holding() return M.wanted and M.lease~=nil and not M.failed end
function M.isActive() return M.holding() end
function M.forceClose() M.wanted=false;return M.release(true) end

-- 视角输入：吃掉游戏相机管线里的鼠标增量（与第一人称同一条路）。
function M.move(ctrl,delta)
    if M.busy~=nil or not M.holding() then return false end
    if FPV and not M.fpvBroken and FPV.on then return true end  -- 遥控接管期间鼠标不动相机，但增量要吃掉
    local x,y=0,0
    if delta then x,y=delta.x,delta.y end
    if DeviceInfo.usingController then x=x*90;y=y*90 end
    if x==0 and y==0 then return false end
    M.deltaFrame=U.Time.frameCount
    M.moveHits=(M.moveHits or 0)+1
    M.applyLook(x,y)
    return true
end
function M.applyLook(x,y)
    local s=M.settings
    M.yaw=angle(M.yaw+x*s.sensitivity)
    M.pitch=clamp(M.pitch-y*s.sensitivity*(s.invert_y and -1 or 1),-s.pitch_limit,s.pitch_limit)
end

-- 原生绑定优先：六个方向各自读按住状态，任何一步抛错就退回硬编码键位。
local function movement()
    local acts=M.acts
    if acts and acts.f and acts.b and acts.l and acts.r and not M.actsBroken then
        local ok,f,r,u,boost=pcall(function()
            local a=(acts.f.down() and 1 or 0)-(acts.b.down() and 1 or 0)
            local b=(acts.r.down() and 1 or 0)-(acts.l.down() and 1 or 0)
            local c=0
            if acts.u and acts.d then c=(acts.u.down() and 1 or 0)-(acts.d.down() and 1 or 0) end
            return a,b,c,acts.boost and acts.boost.down() and true or false
        end)
        if ok then return f,r,u,boost end
        M.actsBroken=true
        reportEvent('act_failed')
    end
    return nil
end
local function readInputs(dt)
    local f,r,u,boost=movement()
    if f==nil then
        local ks=keySet()
        f,r,u,boost=0,0,0,false
        if input.keyOk then
            f=(anyDown(ks.f) and 1 or 0)-(anyDown(ks.b) and 1 or 0)
            r=(anyDown(ks.r) and 1 or 0)-(anyDown(ks.l) and 1 or 0)
            u=(anyDown(ks.up) and 1 or 0)-(anyDown(ks.dn) and 1 or 0)
            boost=anyDown(ks.boost)
        else
            r=clamp(axis('Horizontal'),-1,1)      -- Horizontal 才是横向
            f=clamp(axis('Vertical'),-1,1)        -- Vertical 才是纵向
        end
    end
    -- 没走游戏相机管线时自己补鼠标增量。
    local mx,my=axis('Mouse X'),axis('Mouse Y')
    if U.Time.frameCount~=M.deltaFrame and (mx~=0 or my~=0) then M.applyLook(mx,my) end
    return f,r,u,boost,mx,my
end

local function diag(f,r,u,mx,my)
    local now=U.Time.realtimeSinceStartup
    if M.diagAt and now-M.diagAt<1 then return end
    M.diagAt=now
    reportEvent(string.format('in_i%d_f%d_r%d_u%d_mx%d_my%d_n%d_a%d_mv%d_re%d',
        INST,math.floor(f*10),math.floor(r*10),math.floor(u*10),
        math.floor(mx*10),math.floor(my*10),
        (M.acts and not M.actsBroken) and 1 or 0,input.axis and 1 or 0,M.moveHits or 0,M.reentry or 0))
    if FPV and not M.fpvBroken then reportEvent('fpv_i'..INST..'_'..FPV.status()) end
end

-- 遥控接管那半每帧的动作：心跳 + 游戏内三个键。
-- 整段外面套了 pcall：FPV 那半就算炸了，也只能让遥控功能自己歇着，键鼠飞行照旧。
local function fpvTick(dt)
    if FPV then FPV.heartbeat(M,dt) end
    local keys=M.fpvKeys
    if keys==nil then return end
    local function need() announce('FPV：没拿到 C++ 那半注入的模块（FreeCam.dll 八成不是新版），这个键用不了') end
    if pressedEdge('recv',keys.recv) then
        if FPV then announce('FPV：游戏内接收开关 → '..(FPV.toggleRecv() and '开' or '关（遥控器不再接管，键鼠照常）'))
        else need() end
    end
    if pressedEdge('force',keys.force) then
        if FPV then announce('FPV：强制接管 → '..(FPV.toggleForce() and '开（忽略 arm、校准、映射检查，排障用）' or '关'))
        else need() end
    end
    if pressedEdge('check',keys.check) then
        if FPV then announce(FPV.describe())
        else announce('FPV 自检：没拿到 C++ 那半注入的模块（FreeCam.dll 八成不是新版），游戏侧和辅助程序侧的链路都查不了') end
    end
end

local function frameBody(dt)
    if not M.settings then return end
    dt=clamp(tonumber(dt) or 0,0,.1)
    if not M.fpvBroken then
        local ok=pcall(fpvTick,dt)
        if not ok then M.fpvBroken=true;reportEvent('fpv_fail') end
    end
    if P.pressed() then M.toggle() end
    if M.lease and M.lease.releasing then
        if not M.release() then return end
    end
    if not M.wanted or M.failed then
        if M.lease then M.release() end
        return
    end
    local l=M.lease
    -- 关键：门只看"有没有被别的控制器拿走"，自己拿着的相机不算被抢。
    local ok,why=P.available(l)
    if not ok then
        M.stale=(M.stale or 0)+1
        if M.stale>90 then M.wanted=false;reportEvent('gate_lost');M.release() end
        return
    end
    M.stale=0
    if l==nil then
        local nl,reason=P.capture()
        if nl==nil then M.wanted=false;reportEvent('capture_'..tostring(reason));return end
        l=nl
        M.lease=l
        M.yaw,M.pitch=l.yaw,l.pitch
        M.velocity=V.zero
        M.scroll=0
        M.moveHits=0
        local ins,inWhy=P.install(l,M.settings)
        if not ins then
            M.lease=nil;M.wanted=false
            pcall(P.release,l)
            reportEvent('install_'..tostring(inWhy))
            return
        end
        M.releaseTries=0
        reportEvent('entered')
    end
    local c=M.settings
    local f,r,u,boost,mx,my
    if FPV and not M.fpvBroken and FPV.pull(M) then
        f=FPV.attitude(M,dt,c)                  -- 遥控接管：角速率积分姿态，油门当推力
        r,u,boost,mx,my=0,0,false,0,0
    else
        f,r,u,boost,mx,my=readInputs(dt)
    end
    diag(f,r,u,mx,my)
    local rotation=Q.Euler(M.pitch,M.yaw,M.roll or 0)
    local want=(rotation*V(0,0,1))*f+(rotation*V(1,0,0))*r+V(0,1,0)*u
    if want.sqrMagnitude>1 then want=want.normalized end
    local target=want*(c.speed*(boost and c.boost or 1))
    if c.smoothing>0 and dt>0 then
        M.velocity=V.Lerp(M.velocity,target,1-math.exp(-dt/c.smoothing))
    else
        M.velocity=target
    end
    l.position=l.position+M.velocity*dt
    local posed,reason=P.pose(l,l.position,rotation,dt,c)
    if not posed then
        M.stale=(M.stale or 0)+1
        if M.stale>3 then M.wanted=false;reportEvent('lost_'..tostring(reason));M.release(true) end
    end
end

local function tailBody(dt)
    local l=M.lease
    if l==nil or M.failed or not M.wanted or l.releasing then return end
    if not live(l.camera) or not live(l.virtual) then return end
    if not P.ownsCamera(l) then
        M.stale=(M.stale or 0)+1
        if M.stale>90 then M.wanted=false;reportEvent('lost_camera');M.release(true) end
        return
    end
    P.commit(l,M.settings)
end

-- 所有入口都套一层：重入直接丢掉，出错只记一次并立刻收场。
local function traceHandler(e)
    return tostring(e)..'\n'..traceback('',2)
end
local function run(name,body,arg)
    if M.busy~=nil then M.reentry=(M.reentry or 0)+1;return end
    M.busy=name
    local ok,err=xpcall(function() return body(arg) end,traceHandler)
    if not ok then M.fault(err) end
    M.busy=nil
end
function M.fault(err)
    M.failed=true
    M.wanted=false
    M.faultCount=(M.faultCount or 0)+1
    if not M.faultLogged then
        M.faultLogged=true
        reportEvent('freecam_failed',err)
    end
    if M.lease then pcall(M.release) end
end

local function detach()
    local list=handles
    handles={}
    for _,key in ipairs(list or {}) do pcall(function() LuaUpdate:Remove(key) end) end
    if unsubscribe then pcall(unsubscribe);unsubscribe=nil end
end

function M.show(ctrl)
    pcall(detach)
    local ok,err=pcall(function()
        ensureKeys()
        M.configure(api.get(ID) or {})
        unsubscribe=api.subscribe(ID,function(_,_,values) run('cfg',M.configure,values) end)
        handles={LuaUpdate:Add('Tick',function(dt) run('frame',frameBody,dt) end),
            LuaUpdate:Add('TailTick',function(dt) run('tail',tailBody,dt) end)}
        M.stale=0
        reportEvent('ready')
    end)
    if not ok then pcall(detach);M.fault(err) end
end
function M.hide(ctrl)
    reportEvent('view_hide')
    M.wanted=false
    pcall(detach)
    pcall(M.release,true)
end
function M.close(ctrl) M.hide(ctrl) end
_G.ZMLFreecam=M
return M
