#!/usr/bin/env python3
"""fpv_link.lua 的离线测试：不用进游戏，拿 lupa 跑 Lua 层。

它把 C++ 侧那个 Lua 源假掉——LuaManagerInst:LoadLua 直接返回我们拼的 `return {…}`，
和 fpvlink.cpp 生成的格式一致（见 tests/fpv_probe.cpp 里打印出来的样子）。
测的是接管判断的八条拒绝路径，加上遥控器四个开关的手感（自稳/回平/翻正/交回衰减）。

跑法：python3 tests/test_fpv_lua.py
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / 'mod' / 'fpv_link.lua'

ST_VALID, ST_ARMED, ST_HOLD, ST_CALIB = 1, 2, 4, 8
BIT_ARM, BIT_MODE, BIT_BUZZER, BIT_TURTLE = 0, 1, 2, 3

fails = []


def check(name, ok, detail=''):
    print(('  ok   ' if ok else '  FAIL ') + name + (('  ' + detail) if detail else ''))
    if not ok:
        fails.append(name)


def src(ok=1, armed=1, hold=0, calib=0, flags=ST_VALID | ST_ARMED,
        roll=0, pitch=0, yaw=0, throttle=0, switches=0, seq=1, age=0):
    """照 fpvlink.cpp 那个格式拼一帧。"""
    return ('return {n=%d,seq=%d,age=%d,flags=%d,ok=%d,armed=%d,hold=%d,calib=%d,'
            'roll=%d,pitch=%d,yaw=%d,throttle=%d,switches=%d,buttons=0,aux=0,lost=0,fps=60}'
            % (seq, seq, age, flags, ok, armed, hold, calib, roll, pitch, yaw, throttle, switches))


L = lupa.LuaRuntime()
# 游戏里的 Lua 是 5.1 血统，有 loadstring；lupa 自带的 5.5 没有，补一个（和
# Endfield-FirstPerson/tests/native_mock.lua 一个写法）。
L.execute('loadstring = load')
L.execute('LuaManagerInst = { LoadLua = function(self, path) return __SRC end }')
_load = L.eval('function(s) local f,e=load(s, "@fpv_link"); if f==nil then error(e) end return f end')
F = _load(MOD.read_text())()()
DT = 0.02


def state(**kw):
    L.globals()['__SRC'] = src(**kw)


def settings(**kw):
    base = dict(fpv=True, fpv_scale=1, fpv_limit=60, fpv_selflevel=True, fpv_level_speed=90)
    base.update(kw)
    return L.eval('function(t) return t end')(base)


def mkM(holding=True, settings_=None):
    M = L.eval('function(h) return {roll=nil,pitch=nil,yaw=0,holding=function() return h end} end')(
        bool(holding))
    base = settings_ or dict(fpv=True, fpv_scale=1, fpv_limit=60,
                             fpv_selflevel=True, fpv_level_speed=90)
    M.settings = L.eval('function(t) return t end')(base)
    return M


def fly(M, n, dt=DT):
    """走真实的帧顺序：heartbeat -> pull -> 接管成功才 attitude（和 freecam.lua 一致）。"""
    for _ in range(int(n)):
        F.heartbeat(M, dt)
        if F.pull(M):
            F.attitude(M, dt, M.settings)


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
        check(name + ' 横滚收着退', abs(float(M.roll) + 5) < 5 and abs(float(M.roll)) >= 0 and
              float(M.roll) > -5, 'roll=%.2f' % float(M.roll))
        for _ in range(10):
            F.heartbeat(M, DT)
        check(name + ' 收完归零', M.roll is None, 'roll=%s' % M.roll)
state()
M = mkM()
check('ok', F.pull(M) and F.why == 'ok' and F.on, '→ %s' % F.why)

print('角速率积分与限幅')
M = mkM()
state(roll=100, pitch=50, yaw=180, throttle=500)
fly(M, 25)                                   # 0.5 秒
check('0.5s 右滚 -50 度', 49 < -float(M.roll) < 51, 'roll=%.1f' % float(M.roll))
check('0.5s 抬头（Unity 的 pitch 是负的）', -26 < float(M.pitch) < -24, 'pitch=%.1f' % float(M.pitch))
check('0.5s 右偏航 +90 度', 89 < float(M.yaw) < 91, 'yaw=%.1f' % float(M.yaw))
state(roll=1000)
fly(M, 200)
check('横滚被限到 60', abs(abs(float(M.roll)) - 60) < .001, 'roll=%.1f' % float(M.roll))

print('mode 开关：自稳与纯速率')
M = mkM()
state(roll=0, switches=1 << BIT_MODE | 1 << BIT_ARM)   # mode 拨上去 = 纯速率
F.pull(M)
M.roll = -20
fly(M, 50)                                   # 1 秒松杆
check('纯速率松杆不回平', abs(float(M.roll) + 20) < .01, 'roll=%.1f' % float(M.roll))
state(roll=0, switches=1 << BIT_ARM)         # mode 拨下来 = 自稳
fly(M, 25)                                   # 90 度/秒，20 度 0.22 秒够
check('自稳松杆回平', abs(float(M.roll)) < .01, 'roll=%.2f' % float(M.roll))
M = mkM()
state(roll=200, switches=0)
fly(M, 25)
check('自稳有杆位照常积分', float(M.roll) < -30, 'roll=%.1f' % float(M.roll))
M = mkM(settings_=dict(fpv=True, fpv_scale=1, fpv_limit=60,
                       fpv_selflevel=False, fpv_level_speed=90))
state(roll=0, switches=0)
F.pull(M)
M.roll = -20
fly(M, 50)
check('自稳关掉后就是纯速率', abs(float(M.roll) + 20) < .01, 'roll=%.1f' % float(M.roll))

print('buzzer / turtle')
M = mkM()
state(roll=300, pitch=100, switches=(1 << BIT_ARM) | (1 << BIT_BUZZER))
fly(M, 25)
check('按住 buzzer 无视杆位回平', abs(float(M.roll)) < .01 and abs(float(M.pitch)) < .01,
      'roll=%.2f pitch=%.2f' % (float(M.roll), float(M.pitch)))
check('buzzer 时模式串', F.mode == 'buzz', '→ %s' % F.mode)
M = mkM()
state(roll=300, yaw=200, throttle=800, switches=(1 << BIT_ARM) | (1 << BIT_TURTLE))
F.pull(M)
M.roll, M.pitch, M.yaw = -50, 40, 12
thr = None
for _ in range(int(.4 / DT)):
    thr = F.attitude(M, DT, M.settings)
check('turtle 收平（300 度/秒）', abs(float(M.roll)) < 1 and abs(float(M.pitch)) < 1,
      'roll=%.1f pitch=%.1f' % (float(M.roll), float(M.pitch)))
check('turtle 冻住偏航', abs(float(M.yaw) - 12) < .01, 'yaw=%.1f' % float(M.yaw))
check('turtle 切掉油门', float(thr) == 0, 'thr=%.2f' % float(thr))
check('turtle 时模式串', F.mode == 'flip', '→ %s' % F.mode)
state(roll=0, yaw=200, switches=1 << BIT_ARM)
fly(M, 25)
check('松开 turtle 恢复控制', float(M.yaw) > 100, 'yaw=%.1f' % float(M.yaw))

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

print('诊断串')
state(seq=42, roll=1, pitch=2, yaw=3, throttle=4, switches=5)
M = mkM()
F.pull(M)
s = F.status()
check('status 带模式', '_ok_' in s and 'seq42' in s and 'sw5' in s, s)
state(ok=0)
F.pull(M)
check('没包时 status 说原因', '_no_packet_' in F.status(), F.status())

print()
if fails:
    print('挂了 %d 项: %s' % (len(fails), ', '.join(fails)))
    sys.exit(1)
print('全过')
