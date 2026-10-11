-- 遥控接管（FPV）：把辅助程序喂进来的状态包变成相机姿态和速度。
-- 飞控和物理抄的是我们自己那套 EEfpv（renodx-Endfield-Enhancer 的 fpv.hpp）：
-- 三种模式（角度模式 / 半自稳 / 手动模式）+ 加速度积分（机体推力、重力、阻力）。
--
-- 数据不是落文件读的：模组的 C++ 侧注册了一个 Lua 源（ZML/Mod/fpvfreecam/state），
-- 每次 LoadLua 它现生成一小段 `return {…}`，所以取到的永远是最新一包。
-- 包内容见 Endfield-FpvHelper/fpvhelper/ipc.py。
--
-- 约定：这条链路只管姿态，不管相机是不是我们拿着——拿不拿得住由 freecam.lua 判断。
-- 任何一步不对就返回 false，让自由镜头照常用键鼠飞。
--
-- 游戏内的两个开关（绑在游戏原生按键设置里，freecam.lua 注册）：
--   遥控接收开关  Insert  关掉就完全不认遥控器，立刻交回键鼠（设置页里的 fpv 是总闸）
--   强制接管      Delete  排障用：忽略 arm / 校准 / 映射是否标全，只要收到包就接管
--   链路自检      End  按一下，把整条链路的状态写进 runtime.log，并尽力在游戏里弹一下
--
-- 遥控器上的四个开关（包里 switches 的位，见辅助程序那栏"映射"）：
--   bit0 arm     解锁，解锁了才接管（写进 flags 的 ST_ARMED）
--   bit1 mode    两档开关才用它：拨到高位 = 手动模式（杆位即角速度，不限姿态、能翻能倒飞）；
--                拨到低位 = 用设置里选的模式。模式开关是三档拨杆时不用这一位，改看下面 aux
--   bit2 buzzer  按住 = 回平键：忽略杆位，按松杆自稳回平（横滚与俯仰拉平，偏航仍随杆）
--   bit3 turtle  按住 = 翻正键：姿态收平、偏航冻结、油门切至悬停
--
-- 三档拨杆（模式开关）：辅助程序那头把模式行设成「多档」逐档标定，档位号走 aux 低两位
-- （0 角度模式 / 1 半自稳 / 2 手动模式），并置 flags 的 bit4 表示 aux 有效；档位顺序在
-- 辅助程序的「档位顺序」那栏排。没置这个位就退回上面 bit1 / 设置里 fpv_mode 的老行为。
return function()
    local clamp=function(x,a,b) if x<a then return a elseif x>b then return b end return x end
    local wrap=function(x) return (x+180)%360-180 end
    local function pullto(v,t,step)          -- 朝 t 收，别过头
        if v<t-step then return v+step elseif v>t+step then return v-step end
        return t
    end
    local function bit(v,i) return math.floor((v or 0)/2^i)%2==1 end
    local STALE=.25          -- 秒，超过这个没新包就算断了
    local RESET=300          -- 度每秒：翻正键的收平速度
    local RELAX=240          -- 度每秒：交回键鼠时，叠加的横滚收回去的速度
    local MODE_CN={angle='角度模式',horizon='半自稳',rate='半自稳(随杆)',acro='手动模式',
                   buzz='回平键',flip='翻正键'}
    local ROOT='ZML/Mod/fpvfreecam/'
    local PATH=ROOT..'state'
    local PUSH_ROOT=ROOT
    local F={on=false,why='init',n=0,seq=-1,age=1e9,mode='rate',recv=true,force=false}

    -- 各种"不接管"的中文说法，自检时直接给人看
    local WHY={
        init='还没跑起来',off='模组设置页里的「遥控接管」关着',
        recv_off='游戏内接收开关关着（Insert）',
        no_camera='自由镜头没开着（先按 \\）',
        no_module='没拿到 C++ 那半注入的模块，FreeCam.dll 八成不是新版',
        no_compiler='这个 Lua 环境没有 loadstring',
        bad_source='C++ 那半吐出来的源码编不过',bad_table='状态模块没返回表',
        no_packet='一个状态包都没收到：辅助程序那边「发给游戏」没开，或者端口不对',
        stale='包断了，超过 0.25 秒没有新包',
        hold='辅助程序那边按着急停',
        calib='辅助程序正在校准',
        disarmed='遥控器 arm 开关没推上来',
        not_valid='映射没标全（roll/pitch/yaw/throttle 有一路没校准），辅助程序不上报 ST_VALID',
        ok='正常接管中'}

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

    function F.toggleRecv() F.recv=not F.recv;return F.recv end
    function F.toggleForce() F.force=not F.force;return F.force end

    -- 拿一帧状态，顺便判断现在能不能接管。返回 true 时 F.state 是最新包。
    -- 相机不在我们手上（off / no_camera）就直接把横滚叠加角清掉；
    -- 其余"包有问题"的拒绝不清，留给 heartbeat 收着退回 0，交回键鼠时不会一巴掌扇回去。
    function F.pull(M)
        F.on=false
        local c=M.settings
        if not (c and c.fpv) then F.why='off';F.state=nil;M.roll=nil;return false end
        if not F.recv then F.why='recv_off';F.state=nil;M.roll=nil;return false end
        if not M.holding() then F.why='no_camera';F.state=nil;M.roll=nil;return false end
        local t=fetch()
        if t==nil then F.state=nil;return false end
        F.state=t
        F.n=(F.n or 0)+1
        F.seq=t.seq or -1
        F.age=(t.age or 1e9)/1000
        if t.ok~=1 then F.why='no_packet';return false end
        if F.age>STALE then F.why='stale';return false end
        -- 强制接管是排障开关：只留"还有没有新包"这条底线，别的检查全跳过
        if not F.force then
            if tonumber(t.hold)==1 then F.why='hold';return false end
            if tonumber(t.calib)==1 then F.why='calib';return false end
            if tonumber(t.armed)~=1 then F.why='disarmed';return false end
            if (tonumber(t.flags) or 0)%2==0 then F.why='not_valid';return false end  -- ST_VALID：映射没标全，归一化不可信
        end
        F.why='ok'
        F.on=true
        return true
    end

    local U=CS.UnityEngine
    local V,Q=U.Vector3,U.Quaternion

    -- ---- 飞控：抄我们自己那套 EEfpv（renodx-Endfield-Enhancer 的 fpv.hpp）----
    -- 包里 roll/pitch/yaw 直接就是杆量：-10000..10000 = -100%..100%，不用再反推。
    -- 多少度每秒（fpv_rate_*）、曲线多陡（fpv_expo）全归下面这份设置管，
    -- 辅助程序那边只管把杆量发过来，两边不用再对数字（协议 v2 起）。
    -- 三种模式：0 角度模式（杆位=目标倾角，拿当前姿态做 P 控）
    --           1 半自稳（双杆在死区里待够 horizon_delay 秒才切角度模式，出死区立刻回速率）
    --           2 手动模式（杆位=角速度，带 expo 曲线 a*x^3+(1-a)*x，
    --                      姿态不设限，翻得过去、也能倒着飞）
    -- 油门照搬 EEfpv 的真物理：沿机体上方的推力 - 重力 - 阻力（线性+二次）。
    local STICK_MAX=10000
    local function expo(x,a) return a*x*x*x+(1-a)*x end
    local function stick(s,c)
        local dz=c.fpv_deadzone or .02
        local function one(v)
            local x=clamp((v or 0)/STICK_MAX,-1,1)
            local m=math.abs(x)
            if m<dz then return 0 end
            return (x>0 and 1 or -1)*((m-dz)/(1-dz))
        end
        -- 三路都是"正 = 右滚 / 推杆向前（低头）/ 右偏航"，不翻号。
        -- 0.1.23 之前俯仰这里多按了一个负号，实测推杆向前成了翘头。
        return one(s.roll),one(s.pitch),one(s.yaw)
    end

    -- 走一帧飞控：改 M.pitch/M.roll/M.yaw 和 M.velocity，返回这帧的 rotation 给 freecam.lua。
    function F.flight(M,dt,c)
        local s=F.state
        if s==nil then return nil end
        if not (dt>0) then dt=1/60 end
        c=c or M.settings or {}
        local sw=tonumber(s.switches) or 0
        local fl=tonumber(s.flags) or 0
        local stRoll,stPitch,stYaw=stick(s,c)
        local thr=clamp((s.throttle or 0)/1000,0,1)
        local tilt=c.fpv_tilt_max or 60
        local kp=c.fpv_angle_kp or 6
        local alim=c.fpv_angle_rate_limit or 360
        local thrust=c.fpv_thrust or 24
        local ex=c.fpv_expo or .35
        local lim=c.fpv_limit or 60
        local rrate=c.fpv_rate_roll or 400
        local prate=c.fpv_rate_pitch or 400
        local yrate=c.fpv_rate_yaw or 500
        F.hover=(c.fpv_gravity or 9.81)/(thrust~=0 and thrust or 1)
        local pitch=M.pitch or 0            -- 正 = 低头（和 EEfpv 一个口径）
        local roll=M.roll or 0              -- 正 = 左滚（同上；EEfpv 的 roll_current 也是这个号）
        local mode=math.floor(c.fpv_mode or 0)
        if bit(fl,4) then                   -- 模式开关是三档：档位号在 aux 低两位
            mode=math.floor(tonumber(s.aux) or 0)%4
        elseif bit(sw,1) then               -- 两档开关：拨到高位 = 手动模式
            mode=2
        end
        mode=clamp(mode,0,2)
        -- 角度模式：杆位*tilt_max 是目标倾角，(目标-当前) 乘 P 增益就是角速度指令
        local ap=clamp(kp*(stPitch*tilt-pitch),-alim,alim)
        local ar=clamp(kp*(stRoll*tilt+roll),-alim,alim)
        -- 手动模式：杆位过 expo 再乘满杆角速度
        local rp=expo(stPitch,ex)*prate
        local rr=expo(stRoll,ex)*rrate
        local ry=expo(stYaw,ex)*yrate
        local rateP,rateR,rateY
        if bit(sw,3) then
            -- 翻正：姿态收平、偏航冻住、油门切到悬停（不是掉下去，是停在半空）
            F.mode='flip'
            local inv=1/dt
            rateP=(pullto(pitch,0,RESET*dt)-pitch)*inv
            rateR=(roll-pullto(roll,0,RESET*dt))*inv
            rateY=0
            thr=F.hover
        elseif bit(sw,2) then
            -- 按住回平键：不理杆位，当成松杆自稳
            F.mode='buzz'
            rateP,rateR=clamp(kp*(-pitch),-alim,alim),clamp(kp*roll,-alim,alim)
            rateY=ry
        elseif mode==0 then
            F.mode='angle'
            rateP,rateR,rateY=ap,ar,ry
        elseif mode==1 then
            -- 半自稳：双杆都回中（死区里已经归零）并撑够 horizon_delay 才切角度模式
            local centered=(stPitch==0 and stRoll==0)
            F.hold=centered and math.min((F.hold or 0)+dt,(c.fpv_horizon_delay or .3)+.5) or 0
            local engaged=centered and F.hold>=(c.fpv_horizon_delay or .3)
            F.mode=engaged and 'horizon' or 'rate'
            if engaged then rateP,rateR=ap,ar else rateP,rateR=rp,rr end
            rateY=ry
        else
            F.mode='acro'
            rateP,rateR,rateY=rp,rr,ry
        end
        -- 姿态积分：三个角速度都是机体轴的（俯仰绕右轴、横滚绕前轴、偏航绕竖轴），
        -- 所以姿态就是"当前四元数 × 三个体轴小旋转"，一路乘过去，跟机身指哪儿没关系。
        -- 用的是 Unity 那套左手口：绕 +x（右轴）正转是低头、绕 +z（前轴）正转是左滚，和欧拉那边一个号。
        -- 偏航这里要特别说一句：绕的必须是**机体**竖轴。0.1.26 之前写成世界竖轴（V(0,1,0)），
        -- 机头朝天的时候打偏航就变成绕着机头自转，画面几乎不动；真机是在竖直平面里翻过去。
        local rot
        if F.mode=='acro' then
            local q=F.q
            if q==nil then q=Q.Euler(pitch,M.yaw or 0,roll) end
            local qp=Q.AngleAxis(rateP*dt,q*V(1,0,0))       -- 俯仰：绕机体右轴
            local qr=Q.AngleAxis(-rateR*dt,q*V(0,0,1))      -- 横滚：绕机体前轴（roll 是减，见上面）
            local qy=Q.AngleAxis(rateY*dt,q*V(0,1,0))       -- 偏航：绕机体竖轴
            -- 这里的轴是"机体的轴在世界里指哪儿"，所以要从左边乘（左乘 = 在世界里转出来那个姿态）；
            -- 乘在右边就变成"拿世界的轴当机体的轴用"，机头一歪就串轴。
            q=qy*(qr*(qp*q))
            F.q=q
            rot=q
            local eu=q.eulerAngles                          -- 交回键鼠那边还是靠欧拉角，同步回去
            M.pitch=wrap(eu.x)
            M.roll =wrap(eu.z)
            M.yaw  =eu.y
        else
            -- 角度那几档（角度模式 / 半自稳）保持欧拉角：它们的杆位本来就是"相对地平线的倾角"，
            -- P 控也是照着欧拉角修的，两个方向正好对上——角度档机头朝天这种事本来就不会发生。
            F.q=nil
            local fast=(F.mode=='rate')                     -- 半自稳里杆一出来那一档，还是按 fpv_limit 夹
            local plim=fast and lim or 89
            local rlim=fast and lim or math.max(lim,tilt)
            M.pitch=clamp(pitch+rateP*dt,-plim,plim)
            M.roll =clamp(roll -rateR*dt,-rlim,rlim)
            M.yaw  =wrap((M.yaw or 0)+rateY*dt)
            rot=Q.Euler(M.pitch,M.yaw,M.roll or 0)
        end
        -- 力学：沿机体上方的推力 + 重力 + 阻力（线性+二次），逐分量写，少踩别名的坑
        local up=rot*V(0,1,0)
        local v=M.velocity or V.zero
        local speed=math.sqrt(v.sqrMagnitude)
        local k=(c.fpv_drag_linear or .02)+(c.fpv_drag_quad or .02)*speed
        local t=thr*thrust
        local g=c.fpv_gravity or 9.81
        M.velocity=V(v.x+(up.x*t-v.x*k)*dt,
                     v.y+(up.y*t-g-v.y*k)*dt,
                     v.z+(up.z*t-v.z*k)*dt)
        F.thr,F.speed,F.vy,F.sr,F.sp,F.sy=thr,speed,M.velocity.y,stRoll,stPitch,stYaw
        return rot
    end

    -- 镜头角度：真穿越机的相机都是斜着装在机头，往上仰十几二十度，平飞时前方才落在画面中间。
    -- 这是相机的固定安装角，只改喂给渲染的那个朝向；飞控用的还是机体系姿态（M.pitch 那些），一点没动。
    -- 约定和姿态一致：绕 +x（机体右轴）正转是低头，所以"上仰多少度"要取负。
    function F.camera(rot,c)
        local tilt=(c and c.fpv_cam_tilt) or 0
        if rot==nil or tilt==0 then return rot end
        return rot*Q.AngleAxis(-tilt,V(1,0,0))
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
            F.q=nil                                  -- acro 的姿态基也别留，下次进来重新从欧拉角起
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
    -- 事件名只有 64 字符，所以包号/年龄/收包数留给 C++ 那边 1Hz 的那条，这里只放要现场看的。
    function F.status()
        local head=string.format('n%d_%s%s%s',F.n,F.why,F.recv and '' or '_r0',F.force and '_f1' or '')
        if F.state==nil then return head end
        return string.format('%s_%s_r%d_p%d_y%d_t%d_sw%d_v%d',
            head,F.mode,
            F.state.roll or 0,F.state.pitch or 0,F.state.yaw or 0,
            F.state.throttle or 0,F.state.switches or 0,
            math.floor(F.speed or 0))
    end

    -- 一整句话，给人看的，自检键按下去时用。
    function F.describe()
        local t=F.state
        local n=string.format('FPV 自检：%s',WHY[F.why] or F.why)
        if not F.recv then n=n..'；接收开关关着' end
        if F.force then n=n..'；强制接管开着' end
        if t==nil then return n..'（Lua 这一帧没拿到状态模块）' end
        return string.format('%s｜seq %d｜包龄 %dms｜flags %d｜横滚 %d 俯仰 %d 偏航 %d 油门 %d 开关 %d｜模式 %s｜杆 %d/%d｜悬停 %d%%｜速度 %.1f 竖 %.1f',
            n,t.seq or -1,math.floor(t.age or 0),t.flags or 0,
            t.roll or 0,t.pitch or 0,t.yaw or 0,t.throttle or 0,t.switches or 0,
            MODE_CN[F.mode] or F.mode or 'none',
            math.floor((F.sr or 0)*100),math.floor((F.sp or 0)*100),
            math.floor((F.hover or 0)*100),F.speed or 0,F.vy or 0)
    end

    -- 借 C++ 那半的模组日志把中文写进 runtime.log：路径段字符集只收 [A-Za-z0-9.-_/]，
    -- 所以正文编成十六进制塞进 ZML/Mod/fpvfreecam/log-<hex>，C++ 那边解回来。
    local function clip(s,max)
        if #s<=max then return s end
        local cut=max
        while cut>0 do                        -- 别把多字节字符切一半
            local b=string.byte(s,cut+1)
            if b==nil or b<128 or b>=192 then break end
            cut=cut-1
        end
        return s:sub(1,cut)
    end
    local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)) end
    function F.log(text)
        local line=clip(tostring(text),180)
        local ok,err=pcall(function() return LuaManagerInst:LoadLua(PUSH_ROOT..'log-'..hex(line)) end)
        if ok then F.lastLog=line else F.logErr=tostring(err) end
        return ok==true
    end

    return F
end
