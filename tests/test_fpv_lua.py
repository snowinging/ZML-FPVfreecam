#!/usr/bin/env python3
"""fpv_link.lua 的离线测试：不用进游戏，拿 lupa 跑 Lua 层。

它把 C++ 侧那个 Lua 源假掉——LuaManagerInst:LoadLua 直接返回我们拼的 `return {…}`，
和 fpvlink.cpp 生成的格式一致（见 tests/fpv_probe.cpp 里打印出来的样子）。

测三块：
  1) 接管判断的八条拒绝路径 + 交回键鼠的横滚衰减（这套逻辑没动过）
  2) 飞控：角度模式 / 半自稳 / 手动模式 / 回平键 / 翻正键（抄 EEfpv 的 fpv.hpp）
  3) 物理：机体推力 - 重力 - 阻力，油门大小和悬停油门

跑法：python3 tests/test_fpv_lua.py
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / 'mod' / 'fpv_link.lua'

ST_VALID, ST_ARMED, ST_HOLD, ST_CALIB, ST_MODE_SEL = 1, 2, 4, 8, 16
BIT_ARM, BIT_MODE, BIT_BUZZER, BIT_TURTLE = 0, 1, 2, 3

fails = []


def check(name, ok, detail=''):
    print(('  ok   ' if ok else '  FAIL ') + name + (('  ' + detail) if detail else ''))
    if not ok:
        fails.append(name)


def src(ok=1, armed=1, hold=0, calib=0, flags=ST_VALID | ST_ARMED,
        roll=0, pitch=0, yaw=0, throttle=0, switches=0, seq=1, age=0, aux=0):
    """照 fpvlink.cpp 那个格式拼一帧。"""
    return ('return {n=%d,seq=%d,age=%d,flags=%d,ok=%d,armed=%d,hold=%d,calib=%d,'
            'roll=%d,pitch=%d,yaw=%d,throttle=%d,switches=%d,buttons=0,aux=%d,lost=0,fps=60}'
            % (seq, seq, age, flags, ok, armed, hold, calib, roll, pitch, yaw, throttle,
               switches, aux))


L = lupa.LuaRuntime()
# 游戏里的 Lua 是 5.1 血统，有 loadstring；lupa 自带的 5.5 没有，补一个（和
# Endfield-FirstPerson/tests/native_mock.lua 一个写法）。
L.execute('loadstring = load')
L.execute('LuaManagerInst = { last=0, n=0, LoadLua = function(self, path) self.last=path; self.n=self.n+1; return __SRC end }')

# 飞控要拿机体的上方向（rot * V(0,1,0)），而且手动模式那档是自己按体轴转姿态的，
# 所以这里得有个说得过去的 Vector3 和一个真能相乘的四元数。
# 旋转按 Unity 的 ZXY 顺序真的算一遍，别的都不管。
L.execute(r'''
local RAD=math.pi/180
local atan2=math.atan2 or math.atan
local function vec(x,y,z)
    local v={x=x,y=y,z=z}
    return setmetatable(v,{__index={sqrMagnitude=v.x*v.x+v.y*v.y+v.z*v.z,
                                   magnitude=math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)}})
end
local function rot(v,x,y,z)
    local rx,ry,rz=x*RAD,y*RAD,z*RAD
    local sx,sy,sz,cx,cy,cz=math.sin(rx),math.sin(ry),math.sin(rz),math.cos(rx),math.cos(ry),math.cos(rz)
    local ax,ay,az=v.x*cz-v.y*sz,v.x*sz+v.y*cz,v.z          -- Rz
    local bx,by,bz=ax,ay*cx-az*sx,ay*sx+az*cx               -- Rx
    return vec(bx*cy+bz*sy,by,-bx*sy+bz*cy)                 -- Ry
end
local function qmul(a,b)
    return {w=a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
            x=a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
            y=a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
            z=a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w}
end
local function qq(w,x,y,z)
    local q={w=w,x=x,y=y,z=z}
    local n=math.sqrt(w*w+x*x+y*y+z*z)
    q.w,q.x,q.y,q.z=w/n,x/n,y/n,z/n
    -- Unity 的 ZXY 欧拉分解，和游戏里 eulerAngles 一个结果
    local m13,m23,m33=2*(q.x*q.z+q.w*q.y),2*(q.y*q.z-q.w*q.x),1-2*(q.x*q.x+q.y*q.y)
    local m21,m22=2*(q.x*q.y+q.w*q.z),1-2*(q.x*q.x+q.z*q.z)
    q.eulerAngles=vec(atan2(-m23,math.sqrt(m13*m13+m33*m33))/RAD,atan2(m13,m33)/RAD,atan2(m21,m22)/RAD)
    return setmetatable(q,{__mul=function(a,b)
        if b.w~=nil then return qq(a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
                                   a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
                                   a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
                                   a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w) end
        return rot(b,a.eulerAngles.x,a.eulerAngles.y,a.eulerAngles.z)
    end})
end
local Q={}
Q.Euler=function(x,y,z)
    local q=qmul(qmul({w=math.cos(y*RAD/2),x=0,y=math.sin(y*RAD/2),z=0},
                      {w=math.cos(x*RAD/2),x=math.sin(x*RAD/2),y=0,z=0}),
                {w=math.cos(z*RAD/2),x=0,y=0,z=math.sin(z*RAD/2)})
    return qq(q.w,q.x,q.y,q.z)
end
Q.AngleAxis=function(deg,axis)
    local h=deg*RAD/2
    local n=math.sqrt(axis.x*axis.x+axis.y*axis.y+axis.z*axis.z)
    if n==0 then n=1 end
    local s=math.sin(h)/n
    return qq(math.cos(h),axis.x*s,axis.y*s,axis.z*s)
end
Q.LookRotation=function(f,u)
    local fx,fy,fz=f.x,f.y,f.z
    local n=math.sqrt(fx*fx+fy*fy+fz*fz); if n==0 then n=1 end
    fx,fy,fz=fx/n,fy/n,fz/n
    local rx,ry,rz=u.y*fz-u.z*fy,u.z*fx-u.x*fz,u.x*fy-u.y*fx      -- 右 = up × fwd
    n=math.sqrt(rx*rx+ry*ry+rz*rz); if n==0 then n=1 end
    rx,ry,rz=rx/n,ry/n,rz/n
    local ux,uy,uz=fy*rz-fz*ry,fz*rx-fx*rz,fx*ry-fy*rx            -- 再对齐一次 up = fwd × 右
    local m11,m12,m13=rx,ux,fx
    local m21,m22,m23=ry,uy,fy
    local m31,m32,m33=rz,uz,fz
    local w,x,y,z
    local tr=m11+m22+m33
    if tr>0 then local s=math.sqrt(tr+1)*2; w=.25*s; x=(m32-m23)/s; y=(m13-m31)/s; z=(m21-m12)/s
    elseif m11>m22 and m11>m33 then local s=math.sqrt(1+m11-m22-m33)*2; w=(m32-m23)/s; x=.25*s
        y=(m12+m21)/s; z=(m13+m31)/s
    elseif m22>m33 then local s=math.sqrt(1+m22-m11-m33)*2; w=(m13-m31)/s; x=(m12+m21)/s
        y=.25*s; z=(m23+m32)/s
    else local s=math.sqrt(1+m33-m11-m22)*2; w=(m21-m12)/s; x=(m13+m31)/s; y=(m23+m32)/s; z=.25*s end
    return qq(w,x,y,z)
end
CS={UnityEngine={Vector3=setmetatable({zero=vec(0,0,0)},
        {__call=function(_,x,y,z) return vec(x or 0,y or 0,z or 0) end}),Quaternion=Q}}
''')
_load = L.eval('function(s) local f,e=load(s, "@fpv_link"); if f==nil then error(e) end return f end')
F = _load(MOD.read_text())()()
DT = 0.02
Q = L.globals()['CS'].UnityEngine.Quaternion
_UP = L.eval('function(q) return q*CS.UnityEngine.Vector3(0,1,0) end')
_FWD = L.eval('function(q) return q*CS.UnityEngine.Vector3(0,0,1) end')


def fwd(q):
    v = _FWD(q)
    return float(v.x), float(v.y), float(v.z)


def up():
    """现在手动模式的姿态在飞控自己手里（F.q），拿机体的上方向看它翻到哪了。"""
    v = _UP(F.q)
    return float(v.x), float(v.y), float(v.z)


def state(**kw):
    L.globals()['__SRC'] = src(**kw)


CFG = dict(fpv=True, fpv_mode=0, fpv_rate_roll=400, fpv_rate_pitch=400, fpv_rate_yaw=500,
           fpv_expo=.35, fpv_deadzone=.02, fpv_tilt_max=60, fpv_angle_kp=6,
           fpv_angle_rate_limit=360, fpv_horizon_delay=.3, fpv_limit=60, fpv_thrust=24,
           fpv_gravity=9.81, fpv_drag_linear=.02, fpv_drag_quad=.02, fpv_cam_tilt=15)


# mkM 在循环里被调几百次，每回 L.eval 一遍会在 lupa 里堆出一堆包装，跑到一半
# 偶发段错误（30 次里崩 11 次，编译一次就 0/25）。所以这里只编译一次。
# settings 别跟着改：它每次传的是一个新 dict，复用同一个函数的话，lupa 会把旧
# dict 认成同一个对象、把上一次的配置表还回来（半杆测试当场变 0）。
_MK = L.eval('function(h) return {roll=nil,pitch=nil,yaw=0,holding=function() return h end} end')


def settings(**kw):
    base = dict(CFG)
    base.update(kw)
    return L.eval('function(t) return t end')(base)


def mkM(holding=True, settings_=None):
    M = _MK(bool(holding))
    M.settings = settings_ or settings()
    F.q = None       # 新一台相机：手动模式自己端着的姿态也别留着（游戏里松手就清）
    return M


def fly(M, n, dt=DT):
    """走真实的帧顺序：heartbeat -> pull -> 接管成功才 flight（和 freecam.lua 一致）。"""
    for _ in range(int(n)):
        F.heartbeat(M, dt)
        if F.pull(M):
            F.flight(M, dt, M.settings)


def vy(M):
    return 0.0 if M.velocity is None else float(M.velocity.y)


# 期望值按 Lua 里同一套算法算，免得手推错（死区重映射 + expo 这两步最容易漏）
DZ = .02


def stick(x):
    x = max(-1.0, min(1.0, x))
    m = abs(x)
    if m < DZ:
        return 0.0
    return (1.0 if x > 0 else -1.0) * ((m - DZ) / (1 - DZ))


def expo(x, a=.35):
    return a * x ** 3 + (1 - a) * x


print('拒绝路径（八条）')
cases = [
    ('off', dict(), dict(fpv=False)),
    ('no_camera', dict(), None),
    ('no_packet', dict(ok=0), {}),
    ('stale', dict(age=400), {}),
    ('hold', dict(hold=1), {}),
    ('calib', dict(calib=1), {}),
    ('disarmed', dict(armed=0, flags=ST_VALID), {}),
    ('not_valid', dict(flags=ST_ARMED), {}),
]
for name, kw, mkw in cases:
    state(**kw)
    if mkw is None:
        M = mkM(holding=False)
    elif mkw:
        M = mkM(settings_=settings(**mkw))
    else:
        M = mkM()
    M.roll = -5
    ok = F.pull(M)
    # 相机不在手上（off / no_camera）当场清掉横滚；
    # 其余是"包有问题"，横滚交给 heartbeat 收着退回 0，这里不该瞬间归零。
    if name in ('off', 'no_camera'):
        check(name + ' 当场清横滚', (not ok) and F.why == name and M.roll is None, '→ %s' % F.why)
    else:
        check(name, (not ok) and F.why == name and M.roll is not None, '→ %s' % F.why)
        F.heartbeat(M, DT)
        check(name + ' 横滚收着退', abs(float(M.roll) + 5) < 5 and float(M.roll) > -5,
              'roll=%.2f' % float(M.roll))
        for _ in range(10):
            F.heartbeat(M, DT)
        check(name + ' 收完归零', M.roll is None, 'roll=%s' % M.roll)
state()
M = mkM()
check('ok', F.pull(M) and F.why == 'ok' and F.on, '→ %s' % F.why)

print('角度模式（杆位 = 目标倾角，P 控；expo 不参与这一路）')
M = mkM()
state(roll=10000, pitch=10000, yaw=2000, switches=1 << BIT_ARM)
fly(M, 50)                                   # 1 秒，1/kp = 0.17s 时间常数
check('满杆右滚收到 -60 度', -60.2 < float(M.roll) < -59.5, 'roll=%.2f' % float(M.roll))
check('满杆推杆向前收到 +60 度（Unity 的 pitch 正是低头）', 59.5 < float(M.pitch) < 60.2,
      'pitch=%.2f' % float(M.pitch))
want_yaw = expo(stick(.2)) * 500
check('角度模式不锁偏航，1 秒走 %d 度' % round(want_yaw), abs(float(M.yaw) - want_yaw) < 1.5,
      'yaw=%.1f 期望 %.1f' % (float(M.yaw), want_yaw))
check('模式串是 angle', F.mode == 'angle', '→ %s' % F.mode)
M = mkM()
state(roll=-5000, pitch=-5000, switches=1 << BIT_ARM)   # 半杆左滚 + 半杆拉杆（抬头）
fly(M, 50)
# 半杆 = 死区重映射后的 0.4898，乘 tilt_max 60 就是 29.4 度。
# 包里正号是右滚/推杆向前；模组这边 Unity 的正 z 是左滚、正 x 是低头，所以横滚差个号、俯仰同号
half = stick(-.5) * 60
check('半杆左滚收到 %.1f 度' % -half, abs(float(M.roll) + half) < .3, 'roll=%.2f' % float(M.roll))
check('半杆拉杆抬头收到 %.1f 度' % half, abs(float(M.pitch) - half) < .3, 'pitch=%.2f' % float(M.pitch))
M = mkM()
state(roll=100)                               # 1% 满杆，落在 2% 死区里
fly(M, 30)
check('死区里当杆位 0', abs(float(M.roll or 0)) < .001, 'roll=%s' % M.roll)
M = mkM()
state(roll=10000)
M.roll = -50
fly(M, 50)
check('已经歪了也能被拉回目标', -60.2 < float(M.roll) < -59.5, 'roll=%.2f' % float(M.roll))

print('手动模式（模式开关拨到高位，或设置里选 2；不限姿态）')
M = mkM()
state(roll=5000, pitch=0, switches=(1 << BIT_ARM) | (1 << BIT_MODE))
fly(M, 10)                                   # 0.2 秒
acro_rate = expo(stick(.5)) * 400            # 143.8 度/秒
check('expo 后的角速度对得上', abs(-float(M.roll) - acro_rate * .2) < .3,
      'roll=%.2f 期望 %.2f' % (float(M.roll), -acro_rate * .2))
check('模式串是 acro', F.mode == 'acro', '→ %s' % F.mode)
state(roll=0, switches=(1 << BIT_ARM) | (1 << BIT_MODE))
fly(M, 50)
check('松杆不回平', abs(-float(M.roll) - acro_rate * .2) < .3, 'roll=%.2f' % float(M.roll))

# 包里三路就是杆量本身（±10000 = ±100%），满杆多少度每秒归模组设置管
M2 = mkM(settings_=settings(fpv_mode=2, fpv_rate_pitch=800))
state(pitch=5000, switches=1 << BIT_ARM)
fly(M2, 10)                                  # 0.2 秒
want_half = expo(stick(.5)) * 800
check('半杆杆量 × 设置里的满杆角速度（不用跟辅助程序对数字）',
      abs(float(M2.pitch) - want_half * .2) < .4,
      'pitch=%.2f 期望 %.2f' % (float(M2.pitch), want_half * .2))

# 真手动：满杆 400 度/秒，0.26 秒就低头过了 90 度——旧版这里被 fpv_limit 卡在 60 度
M = mkM()
state(pitch=10000, switches=(1 << BIT_ARM) | (1 << BIT_MODE))
fly(M, 13)
ux, uy, uz = up()
check('满杆推杆向前低头翻过 90 度，不再被 fpv_limit 卡住', uy < -.15 and uz > .9,
      'up=(%.2f, %.2f, %.2f)' % (ux, uy, uz))
M = mkM()
state(pitch=10000, switches=(1 << BIT_ARM) | (1 << BIT_MODE))
fly(M, 45)                                   # 0.9 秒 = 绕机体右轴整整一圈
ux, uy, uz = up()
check('翻满一圈能回到原朝向（四元数积分不跑偏）', uy > .99, 'up=(%.2f, %.2f, %.2f)' % (ux, uy, uz))
M = mkM()
state(roll=10000, switches=(1 << BIT_ARM) | (1 << BIT_MODE))
fly(M, 45)                                   # 一圈横滚，姿态全程不设限
ux, uy, uz = up()
check('横滚也能整圈翻（绕机体前轴）', uy > .99 and abs(uz) < .02,
      'up=(%.2f, %.2f, %.2f)' % (ux, uy, uz))
M = mkM(settings_=settings(fpv_mode=2))      # 不带模式开关也是手动模式
state(roll=0, switches=1 << BIT_ARM)
M.roll = -20
fly(M, 50)
check('设置里选 2 时松杆不回平', abs(float(M.roll) + 20) < .01, 'roll=%.2f' % float(M.roll))
# 偏航绕的是机体竖轴：机头朝上时打偏航，机头该在竖直平面里扫过去（真机手感），
# 而不是绕着机头自转、或者贴着水平面横着绕（0.1.27 之前是绕世界竖轴，机头基本不带动的）。
# 用 85 度而不是 90 度：欧拉角在正负 90 度那点解不开，测试里的方向辅助函数走的就是欧拉角。
M = mkM(settings_=settings(fpv_mode=2))
state(pitch=0, roll=0, yaw=10000, switches=1 << BIT_ARM)
F.q = Q.Euler(-85, 0, 0)                     # 机头仰 85 度，差一点朝天
M.pitch, M.roll, M.yaw = -85, 0, 0
ux0, uy0, uz0 = up()
fx0, fy0, fz0 = fwd(F.q)
fly(M, 5)                                    # 0.1 秒 = 偏航 50 度（expo(1)*500）
ux, uy, uz = up()
check('机头朝上时偏航轴是机体竖轴：机体上方向基本不动（绕世界竖轴的话它会甩开）',
      abs(ux) < .02 and abs(uy - uy0) < .02 and abs(uz - uz0) < .02,
      'up=(%.3f, %.3f, %.3f) 原样 %.3f, %.3f, %.3f' % (ux, uy, uz, ux0, uy0, uz0))
fx, fy, fz = fwd(F.q)
check('机头是在竖直平面里扫过去的（高度掉下来了，横向甩出去了）',
      fy < fy0 - .2 and fx > .5 and abs(fz - fz0) < .1,
      'fwd=(%.3f, %.3f, %.3f) 原来是 %.3f, %.3f, %.3f' % (fx, fy, fz, fx0, fy0, fz0))

print('半自稳（松杆撑够 horizon_delay 才回平）')
M = mkM(settings_=settings(fpv_mode=1))
state(switches=1 << BIT_ARM)
M.roll = -20
fly(M, 10)                                   # 0.2 秒 < 0.3
check('还没到时间就先保持', abs(float(M.roll) + 20) < .01, 'roll=%.2f' % float(M.roll))
check('没撑够时间时模式串是 rate', F.mode == 'rate', '→ %s' % F.mode)
fly(M, 60)                                   # 到 1.4 秒
check('撑够后自己回平', abs(float(M.roll)) < .1, 'roll=%.2f' % float(M.roll))
check('回平后模式串是 horizon', F.mode == 'horizon', '→ %s' % F.mode)
M = mkM(settings_=settings(fpv_mode=1))
state(roll=5000, switches=1 << BIT_ARM)
fly(M, 30)
check('杆一出来就切回速率', F.mode == 'rate' and float(M.roll) < -20, 'roll=%.2f' % float(M.roll))

print('三档模式开关（档位号走 aux 低两位，配 flags 的 ST_MODE_SEL）')
for aux, want, label in ((0, 'angle', '角度模式'), (1, 'horizon', '半自稳'), (2, 'acro', '手动模式')):
    M = mkM(settings_=settings(fpv_mode=0))      # 设置里选 0 也该被档位压过
    state(roll=0, switches=1 << BIT_ARM, flags=ST_VALID | ST_ARMED | ST_MODE_SEL, aux=aux)
    F.pull(M)
    fly(M, 30)                                   # 半自稳要给够 horizon_delay
    check('档位 %d → %s' % (aux, label), F.mode == want, '→ %s' % F.mode)

M = mkM(settings_=settings(fpv_mode=2))
state(roll=0, switches=1 << BIT_ARM, flags=ST_VALID | ST_ARMED | ST_MODE_SEL, aux=0)
F.pull(M)
fly(M, 10)
check('档位 0 压过设置里的 fpv_mode=2', F.mode == 'angle', '→ %s' % F.mode)

M = mkM(settings_=settings(fpv_mode=0))
state(roll=0, switches=1 << BIT_ARM, flags=ST_VALID | ST_ARMED, aux=2)
F.pull(M)
fly(M, 10)
check('没置 ST_MODE_SEL 就不看 aux', F.mode == 'angle', '→ %s' % F.mode)

M = mkM(settings_=settings(fpv_mode=0))
state(roll=0, switches=(1 << BIT_ARM) | (1 << BIT_MODE), flags=ST_VALID | ST_ARMED)
F.pull(M)
fly(M, 10)
check('两档开关还是老行为（bit1 = 手动模式）', F.mode == 'acro', '→ %s' % F.mode)

print('回平键 / 翻正键')
M = mkM()
state(roll=7500, pitch=5000, switches=(1 << BIT_ARM) | (1 << BIT_BUZZER))
fly(M, 30)
check('按住回平键无视杆位回平', abs(float(M.roll)) < .2 and abs(float(M.pitch)) < .2,
      'roll=%.2f pitch=%.2f' % (float(M.roll), float(M.pitch)))
check('回平键的模式串', F.mode == 'buzz', '→ %s' % F.mode)
M = mkM()
state(roll=0, yaw=4000, throttle=900, switches=(1 << BIT_ARM) | (1 << BIT_TURTLE))
F.pull(M)
M.roll, M.pitch, M.yaw = -50, 40, 12
for _ in range(int(.4 / DT)):
    F.flight(M, DT, M.settings)
check('翻正键收平（300 度/秒）', abs(float(M.roll)) < 1 and abs(float(M.pitch)) < 1,
      'roll=%.1f pitch=%.1f' % (float(M.roll), float(M.pitch)))
check('翻正键冻住偏航', abs(float(M.yaw) - 12) < .01, 'yaw=%.1f' % float(M.yaw))
check('翻正键油门切至悬停（不是切断，是停住）', abs(F.thr - F.hover) < .001,
      'thr=%.3f hover=%.3f' % (float(F.thr), float(F.hover)))
check('翻正键的模式串', F.mode == 'flip', '→ %s' % F.mode)
state(roll=0, yaw=4000, switches=1 << BIT_ARM)
fly(M, 25)
yaw_rate = expo(stick(.4)) * 500             # 包里 4000/10000 = 0.4 满杆
check('松开翻正键恢复控制', abs(float(M.yaw) - (12 + yaw_rate * .5)) < 1,
      'yaw=%.1f 期望 %.1f' % (float(M.yaw), 12 + yaw_rate * .5))

print('物理：推力 / 重力 / 阻力（抄 fpv.hpp 那几行）')
M = mkM()
state(throttle=1000, switches=1 << BIT_ARM)
fly(M, 50)                                   # 1 秒满油门
check('满油门往上飞', vy(M) > 8, 'vy=%.1f' % vy(M))
M = mkM()
state(throttle=0, switches=1 << BIT_ARM)
fly(M, 50)
check('油门到底就是掉下去（阻力拖着）', -9.5 < vy(M) < -4, 'vy=%.1f' % vy(M))
M = mkM()
state(throttle=408, switches=1 << BIT_ARM)   # 悬停油门 = 9.81/24 ≈ 0.41
fly(M, 50)
check('悬停油门基本不动', abs(vy(M)) < .5, 'vy=%.2f' % vy(M))
M = mkM(settings_=settings(fpv_mode=2))      # 手动模式：姿态稳得住，好单独量推力
state(throttle=1000, switches=1 << BIT_ARM)
F.pull(M)
for _ in range(30):
    F.flight(M, DT, M.settings)
level_vy, level_v = vy(M), M.velocity
F.q = Q.Euler(-60, 0, 0)                     # acro 的姿态在飞控手里，直接摆成抬头 60 度
M.pitch = -60                                # 推力斜着往后，竖直分量只剩 cos60
vy_before = vy(M)
for _ in range(10):
    F.flight(M, DT, M.settings)
gain_tilt = vy(M) - vy_before
M2 = mkM(settings_=M.settings)
M2.velocity = level_v
M2.pitch = 0
F.q = Q.Euler(0, 0, 0)
for _ in range(10):
    F.flight(M2, DT, M2.settings)
gain_level = vy(M2) - level_vy
check('推力跟着机体走：抬头后竖直分量按 cos60 打折',
      gain_tilt < gain_level * .6 and gain_tilt > 0,
      '抬头 %.2f vs 水平 %.2f（比值 %.2f）' % (gain_tilt, gain_level, gain_tilt / gain_level))

print('镜头角度（相机的固定安装角，只改画面不改飞控）')
M = mkM(settings_=settings(fpv_cam_tilt=20))
state(roll=0, pitch=0, switches=1 << BIT_ARM)
F.pull(M)
rot = F.flight(M, DT, M.settings)
body = fwd(rot)
check('不装镜头角时相机和机头一个朝向（低头 0 度就看正前方）',
      abs(body[1]) < .001 and abs(body[0]) < .001, 'fwd=(%.2f, %.2f, %.2f)' % body)
cam = fwd(F.camera(rot, M.settings))
check('镜头角 20 度是往上仰：画面朝向比机头高 20 度',
      abs(cam[1] - 0.342) < .01 and abs(cam[2] - 0.940) < .01,
      'fwd=(%.3f, %.3f, %.3f) 期望 (0.000, 0.342, 0.940)' % cam)
check('俯仰杆量一点没被镜头角碰过', abs(float(M.pitch)) < .001, 'pitch=%.3f' % float(M.pitch))
check('0 度就是把机头朝向原样还回来', abs(fwd(F.camera(rot, settings(fpv_cam_tilt=0)))[1]) < .001)
check('机头低头 30 度、镜头角 20 度，画面还剩 10 度低头',
      abs(fwd(F.camera(Q.Euler(30, 0, 0), M.settings))[1] + 0.174) < .01)

print('交回键鼠')
M = mkM(holding=True)
state(ok=0)                                  # 断链，但相机还在我们手上
M.roll = -20
fly(M, 6)                                    # 240 度/秒，0.084 秒收完
check('横滚叠加角收着退回 0', M.roll is None, 'roll=%s' % M.roll)
M = mkM()
state(roll=0)
fly(M, 10)
check('接管但杆位是 0 时不飘', M.roll is None or abs(float(M.roll)) < .001, 'roll=%s' % M.roll)
M = mkM(holding=False)
state(roll=0)
M.roll = -20
F.pull(M)
check('相机不在手上时直接清掉横滚', M.roll is None)

print('游戏内开关（Insert / Delete）')
M = mkM()
state()
check('默认开着', F.recv and F.pull(M) and F.why == 'ok')
M.roll = -5
F.toggleRecv()
check('关掉接收立刻不接管', (not F.pull(M)) and F.why == 'recv_off', '→ %s' % F.why)
check('关掉时当场交还横滚', M.roll is None, 'roll=%s' % M.roll)
F.toggleRecv()
check('再拨回来又能接管', F.pull(M) and F.why == 'ok')

print('强制接管（Delete）：只留"还有没有新包"这条底线')
bypass = [('hold', dict(hold=1)), ('calib', dict(calib=1)),
          ('disarmed', dict(armed=0, flags=ST_VALID)), ('not_valid', dict(flags=ST_ARMED))]
for name, kw in bypass:
    M = mkM()
    state(**kw)
    before, beforeWhy = F.pull(M), F.why
    F.toggleForce()
    after = F.pull(M)
    check('强制接管放过 ' + name, (not before) and after and F.on,
          '%s → 强制后 ok' % beforeWhy)
    F.toggleForce()
    state(**kw)
M = mkM()
state(age=400)
F.toggleForce()
check('强制接管也拦不住"包断了"', not F.pull(M) and F.why == 'stale', '→ %s' % F.why)
F.toggleForce()

print('自检串与日志通道')
state(seq=7, roll=1, pitch=2, yaw=3, throttle=4, switches=5)
M = mkM()
F.pull(M)
d = F.describe()
check('自检串是人话', '自检' in d and 'seq 7' in d and '横滚 1 俯仰 2 偏航 3' in d and '模式 角度模式' in d, d)
check('自检串里有悬停油门', '悬停' in d, d)
check('status 带接收开关状态', '_r0' in F.status() if not F.recv else '_ok_' in F.status(), F.status())
F.toggleRecv()
check('关掉后 status 标 r0', '_r0' in F.status(), F.status())
F.toggleRecv()
M = mkM()
state()
F.pull(M)
ok = F.log('fpv 自检：测试中文日志')
path = str(L.globals()['LuaManagerInst'].last)
check('日志走 log- 十六进制通道', ok and path.startswith('ZML/Mod/fpvfreecam/log-'), path[:40] + '...')
raw = bytes.fromhex(path.split('log-', 1)[1]).decode('utf-8')
check('十六进制解回中文', raw == 'fpv 自检：测试中文日志', raw)
check('路径字符集合法', all(c.isalnum() or c in '.-_/' for c in path), '长度 %d' % len(path))
long = F.log('很长的一句话' * 40)
check('超长自检串截断不报错', long and len(L.globals()['LuaManagerInst'].last) < 500,
      '长度 %d' % len(str(L.globals()['LuaManagerInst'].last)))

print('诊断串')
state(seq=42, roll=1, pitch=2, yaw=3, throttle=4, switches=5)
M = mkM()
F.pull(M)
s = F.status()
check('status 带模式和杆量', '_ok_' in s and '_angle_' in s and 'sw5' in s and '_v' in s, s)
check('status 塞得进 64 字符（api.report 会拒）', len('fpv_i1_' + s) <= 64,
      '%d 字符' % len('fpv_i1_' + s))
state(ok=0)
F.pull(M)
check('没包时 status 说原因', '_no_packet_' in F.status(), F.status())

print()
if fails:
    print('挂了 %d 项: %s' % (len(fails), ', '.join(fails)))
    sys.exit(1)
print('全过')
