-- 遥控接管（FPV）：把辅助程序喂进来的状态包变成相机姿态。
--
-- 数据不是落文件读的：模组的 C++ 侧注册了一个 Lua 源（ZML/Mod/freecam/state），
-- 每次 LoadLua 它现生成一小段 `return {…}`，所以取到的永远是最新一包。
-- 包内容见 Endfield-FpvHelper/fpvhelper/ipc.py。
--
-- 约定：这条链路只管姿态，不管相机是不是我们拿着——拿不拿得住由 freecam.lua 判断。
-- 任何一步不对就返回 false，让自由镜头照常用键鼠飞。
--
-- 遥控器上的四个开关（包里 switches 的位，见辅助程序那栏"映射"）：
--   bit0 arm     解锁，解锁了才接管（写进 flags 的 ST_ARMED）
--   bit1 mode    拨上去 = 纯速率（穿越机手感）；拨下来 = 自稳（松杆自动回平）
--   bit2 buzzer  按住 = 强制回平（横滚俯仰拉回水平，偏航不动）
--   bit3 turtle  按住 = 翻正：立刻收平、偏航冻结、油门切断
return function()
    local clamp=function(x,a,b) if x<a then return a elseif x>b then return b end return x end
    local wrap=function(x) return (x+180)%360-180 end
    local function pullto(v,t,step)          -- 朝 t 收，别过头
        if v<t-step then return v+step elseif v>t+step then return v-step end
        return t
    end
    local function bit(v,i) return math.floor((v or 0)/2^i)%2==1 end
    local STALE=.25          -- 秒，超过这个没新包就算断了
    local BAND=5             -- 度每秒：杆位小于这个算回中，自稳就把它拉平
    local RESET=300          -- 度每秒：turtle 翻正的速度
    local RELAX=240          -- 度每秒：交回键鼠时，叠加的横滚收回去的速度
    local ROOT='ZML/Mod/freecam/'
    local PATH=ROOT..'state'
    local PUSH_ROOT=ROOT
    local F={on=false,why='init',n=0,seq=-1,age=1e9,mode='rate'}

    local function fetch()
        local ok,src=pcall(function() return LuaManagerInst:LoadLua(PATH) end)
        if not ok or type(src)~='string' or #src==0 then F.why='no_module';return nil end
        -- 游戏里 Lua 是 loadstring（见 ModLoader 的 zml.lua 和 MOD_API.md），
        -- 这里仍然 pcall 包一层：源码编不出来也该是"没接管"，不是每帧报错。
        local okc,chunk,err=pcall(loadstring,src,'@zml/fpv-state')
        if not okc then F.why='no_compiler';F.err=tostring(chunk);return nil end
        if chunk==nil then F.why='bad_source';F.err=err;return nil end
        local ok2,t=pcall(chunk)
        if not ok2 or type(t)~='table' then F.why='bad_table';return nil end
        return t
    end

    -- 拿一帧状态，顺便判断现在能不能接管。返回 true 时 F.state 是最新包。
    -- 相机不在我们手上（off / no_camera）就直接把横滚叠加角清掉；
    -- 其余"包有问题"的拒绝不清，留给 heartbeat 收着退回 0，交回键鼠时不会一巴掌扇回去。
    function F.pull(M)
        F.on=false
        local c=M.settings
        if not (c and c.fpv) then F.why='off';F.state=nil;M.roll=nil;return false end
        if not M.holding() then F.why='no_camera';F.state=nil;M.roll=nil;return false end
        local t=fetch()
        if t==nil then F.state=nil;return false end
        F.state=t
        F.n=(F.n or 0)+1
        F.seq=t.seq or -1
        F.age=(t.age or 1e9)/1000
        if t.ok~=1 then F.why='no_packet';return false end
        if F.age>STALE then F.why='stale';return false end
        if tonumber(t.hold)==1 then F.why='hold';return false end
        if tonumber(t.calib)==1 then F.why='calib';return false end
        if tonumber(t.armed)~=1 then F.why='disarmed';return false end
        if (tonumber(t.flags) or 0)%2==0 then F.why='not_valid';return false end  -- ST_VALID：映射没标全，归一化不可信
        F.why='ok'
        F.on=true
        return true
    end

    -- 用角速率把姿态积出来（和真穿越机一样：杆位=角速度，不是角度）。
    -- 正负：包里 roll>0 是右滚、pitch>0 是抬头、yaw>0 是右偏航；
    -- Unity 的欧拉角 x 越小越抬头、z 的右滚是负的，所以俯仰和横滚都是减。
    function F.attitude(M,dt,c)
        local s=F.state
        if s==nil then return 0 end
        local k=c.fpv_scale
        local lim=c.fpv_limit
        local sw=tonumber(s.switches) or 0
        local rawRoll=(s.roll or 0)*k
        local rawPitch=(s.pitch or 0)*k
        local buzz=bit(sw,2)
        local flip=bit(sw,3)
        local roll=M.roll or 0
        local pitch=M.pitch or 0
        if flip then
            -- 翻正：横滚俯仰立刻收平，偏航冻住，油门也切掉（翻过来了就别继续冲）
            F.mode='flip'
            M.roll,M.pitch=pullto(roll,0,RESET*dt),pullto(pitch,0,RESET*dt)
            return 0
        end
        -- 自稳：mode 开关在关位（默认位）时就开着，配置里可以整个关掉
        local selflevel=c.fpv_selflevel and not bit(sw,1)
        local flat=(buzz and 2 or 1)*(c.fpv_level_speed or 90)*dt
        if buzz then F.mode='buzz'
        elseif selflevel then F.mode='level'
        else F.mode='rate' end
        -- 松杆或按住 buzzer：把横滚俯仰往水平收，这段时间杆位不算数
        local zr=buzz or (selflevel and math.abs(rawRoll)<BAND)
        local zp=buzz or (selflevel and math.abs(rawPitch)<BAND)
        if zr then roll=pullto(roll,0,flat) else roll=clamp(roll-rawRoll*dt,-lim,lim) end
        if zp then pitch=pullto(pitch,0,flat) else pitch=clamp(pitch-rawPitch*dt,-lim,lim) end
        M.roll,M.pitch=roll,pitch
        M.yaw=wrap((M.yaw or 0)+(s.yaw or 0)*k*dt)
        return clamp((s.throttle or 0)/1000,0,1)
    end

    -- 每帧都要走一遍（不管有没有在飞）：算 Lua 侧帧率，
    -- 并且每 0.5 秒回推一次"相机是不是被遥控接管着"，让辅助程序那栏有得看。
    local PUSH_PERIOD=.5
    function F.heartbeat(M,dt)
        F.frames=(F.frames or 0)+1
        F.clock=(F.clock or 0)+dt
        if F.clock>=1 then
            F.fps=math.floor(F.frames/F.clock+.5)
            F.frames,F.clock=0,0
        end
        if not (F.on and M.holding()) then
            -- 交回键鼠时别一巴掌扇回去：横滚叠加角收着退回 0（俯仰偏航就是视线角度，留着）
            local r=M.roll or 0
            if r~=0 then
                r=pullto(r,0,RELAX*dt)
                if r==0 then M.roll=nil else M.roll=r end
            end
        end
        F.pushAt=(F.pushAt or 0)+dt
        if F.pushAt<PUSH_PERIOD then return end
        F.pushAt=0
        local path=PUSH_ROOT..string.format('push_cam-%d_fps-%d',
            (F.on and M.holding()) and 1 or 0,F.fps or 0)
        local ok,err=pcall(function() return LuaManagerInst:LoadLua(path) end)
        if not ok then F.pushErr=tostring(err) end
        F.pushOk=ok
    end

    -- 一秒钟一条诊断，用来看"为什么没接管 / 现在什么模式"。
    function F.status()
        if F.state==nil then return string.format('n%d_%s',F.n,F.why) end
        return string.format('n%d_%s_%s_seq%d_age%d_r%d_p%d_y%d_t%d_sw%d',
            F.n,F.why,F.mode,F.seq,math.floor(F.age*1000),
            F.state.roll or 0,F.state.pitch or 0,F.state.yaw or 0,
            F.state.throttle or 0,F.state.switches or 0)
    end

    return F
end
