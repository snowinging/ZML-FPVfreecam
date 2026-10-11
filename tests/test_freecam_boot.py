#!/usr/bin/env python3
"""freecam 整体冒烟测试：不开游戏，把三个 lua 按 plugin.cpp 的拼法拼成 helper，
塞进一个最小的"游戏环境"里真的跑一遍 show + 几帧 Tick。

为什么要这个：helper 是整段内联进 BattleActionCtrl 那个 chunk 的，
所以 lua 侧出的错在 runtime.log 里长成
`UI/Panels/BattleAction/BattleActionCtrl:738: attempt to index a function value`
——看不出是哪一行、更看不到变量名。这里在本地用同样的拼法跑一遍，出错直接炸在脸上。

拼法必须和 Endfield-Freecam/src/plugin.cpp 的 start() 一致：
    "local ZMLFCFactory=(function()\n" + freecam_core.lua + "\nend)()\n"
    "local ZMLFCFpv=(function()\n" + fpv_link.lua + "\nend)()\n" + freecam.lua
注意 FPV 那边：C++ 只等于调掉了外壳一层，ZMLFCFpv 还是工厂，freecam.lua 得自己再叫一声。

跑法：python3 tests/test_freecam_boot.py
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / 'mod'

fails = []


def check(name, ok, detail=''):
    print(('  ok   ' if ok else '  FAIL ') + name + (('  ' + detail) if detail else ''))
    if not ok:
        fails.append(name)


GAME = r'''
loadstring = load

-- ── 够用就好的 Unity / 游戏环境替身 ──────────────────────────────
local function vec(x,y,z)
    local v={x=x or 0,y=y or 0,z=z or 0}
    return setmetatable(v,{
        __index={sqrMagnitude=v.x*v.x+v.y*v.y+v.z*v.z,magnitude=math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z),normalized=v},
        __add=function(a,b) return vec(a.x+b.x,a.y+b.y,a.z+b.z) end,
        __sub=function(a,b) return vec(a.x-b.x,a.y-b.y,a.z-b.z) end,
        __mul=function(a,b)
            if type(a)=='number' then a,b=b,a end
            if type(b)=='number' then return vec(a.x*b,a.y*b,a.z*b) end
            return vec(a.x*b.x,a.y*b.y,a.z*b.z)
        end,
    })
end
local Q={}
Q.Euler=function(x,y,z)
    return setmetatable({__q=true,x=x,y=y,z=z},{__mul=function(a,b) return b end})
end
Q.identity=Q.Euler(0,0,0)
CS={UnityEngine={
    Vector3=setmetatable({zero=vec(0,0,0)},{__call=function(_,x,y,z) return vec(x,y,z) end}),
    Quaternion=Q,KeyCode={I=1,K=2,J=3,L=4,U=5,O=6,LeftShift=7,RightShift=8},
    Time={realtimeSinceStartup=0,frameCount=1,deltaTime=.02},
    Input={GetKey=function() return false end,GetAxis=function() return 0 end},
    Application={isFocused=true},GameObject=function() return nil end,Object={Destroy=function() end},
},Cinemachine={CinemachineVirtualCamera={}}}

REPORTS={}
local apiSrc=[==[
return {report=function(id,event) REPORTS[#REPORTS+1]=event end,
    get=function() return {fov=90,sensitivity=2,speed=8,boost=4,smoothing=.12,pitch_limit=89,
        invert_y=false,enabled=true,fpv=true,fpv_scale=1,fpv_limit=60,fpv_selflevel=true,
        fpv_level_speed=90} end,
    subscribe=function() return function() end end}
]==]
local stateSrc='return {n=1,seq=7,age=0,flags=3,ok=1,armed=1,hold=0,calib=0,roll=0,pitch=0,'..
    'yaw=0,throttle=0,switches=0,buttons=0,aux=0,lost=0,fps=60,rx=7,bad=0,bind=1}'
LuaManagerInst={LoadLua=function(self,path)
    if path=='ZML/Api' then return apiSrc end
    if path=='ZML/Mod/freecam/state' then return stateSrc end
    return 'return {}'
end}
logger={info=function() end,error=function() end}
require_ex=function() return nil end
DeviceInfo={usingController=false}
InputManagerInst={GetAxis=function() return 0 end}
UIUtils={IsPhaseLevelOnTop=function() return true end}
-- PRESS=true 时除"开关"以外的键都算按下去，用来走一遍按键那条路
PRESS=false
ZMLKeybinds={api=1,
    find=function(id,key)
        return {pressed=function() return PRESS==true and key~='toggle' end,
            down=function() return false end}
    end,
    register=function(id,def) error('不该走到注册：键位应该已经存在') end}
TICK,TAIL=nil,nil
LOADFN=function(s) local f,e=load(s,'@probe'); if f==nil then error(e) end return f end
LuaUpdate={Add=function(self,kind,fn)
    if kind=='Tick' then TICK=fn elseif kind=='TailTick' then TAIL=fn end
    return 1
end,Remove=function() end}
'''

core = (MOD / 'freecam_core.lua').read_text()
fpv = (MOD / 'fpv_link.lua').read_text()
freecam = (MOD / 'freecam.lua').read_text()
HELPER = ('local ZMLFCFactory=(function()\n' + core + '\nend)()\n'
          'local ZMLFCFpv=(function()\n' + fpv + '\nend)()\n' + freecam)


def boot(with_fpv=True):
    """照 C++ 的拼法起一遍，返回 (LuaRuntime, 错误文本)。"""
    L = lupa.LuaRuntime()
    L.execute(GAME)
    src = HELPER if with_fpv else ('local ZMLFCFactory=(function()\n' + core + '\nend)()\n' + freecam)
    try:
        L.eval('function(s) local f,e=load(s,"@freecam-helper"); if f==nil then error(e) end return f end')(src)()
    except Exception as e:  # noqa: BLE001 - 就是想看 Lua 报什么
        return L, str(e)
    return L, ''


def lua(L, expr):
    return L.eval('function() return %s end' % expr)()


def reports(L):
    return [str(v) for v in lua(L, 'REPORTS').values()]


L, err = boot()
print('helper 组装与模块落地（和 plugin.cpp 同一种拼法）')
check('helper 能编能跑', not err, err)
if err:
    print('\n%d 项失败' % len(fails))
    sys.exit(1)
L.globals()['__FPVSRC'] = fpv
L.execute('FPVFACT=LOADFN(__FPVSRC)')
check('C++ 调掉一层外壳后，ZMLFCFpv 还是函数（freecam.lua 得自己再叫一声）', lua(L, 'type(FPVFACT())') == 'function')
check('再叫一声才是模块表', lua(L, 'type(FPVFACT()())') == 'table')
check('模块里有 heartbeat / pull / attitude / describe / log',
      lua(L, "(function() local m=FPVFACT()() local n=0 "
             "for _,k in ipairs({'heartbeat','pull','attitude','describe','log','toggleRecv','toggleForce'}) do "
             "if type(m[k])=='function' then n=n+1 end end return n end)()") == 7)
check('freecam 模块挂上 _G.ZMLFreecam', lua(L, 'type(ZMLFreecam)') == 'table')

print('走一遍 show + 几帧 Tick（跟着游戏里的调用顺序）')
L.execute('ZMLFreecam.show(nil)')
check('show 没炸', lua(L, 'not ZMLFreecam.failed'), 'reports=%s' % reports(L))
check('七个移动键 + 三个 FPV 键都注册上了',
      lua(L, "(function() local n=0 for k in pairs(ZMLFreecam.acts or {}) do n=n+1 end return n end)()") == 7 and
      lua(L, "(function() local n=0 for k in pairs(ZMLFreecam.fpvKeys or {}) do n=n+1 end return n end)()") == 3)
check('Tick 回调挂上了', lua(L, 'type(TICK)') == 'function')
L.execute('TICK(0.02)')
check('跑一帧不会死（FPV 那半炸了也不能把自由镜头带走）', lua(L, 'not ZMLFreecam.failed'),
      'reports=%s' % reports(L))
check('没有 freecam_failed / fpv_fail', not {'freecam_failed', 'fpv_fail'} & set(reports(L)),
      'reports=%s' % reports(L))
L.execute('PRESS=true')
L.execute('TICK(0.02)')
check('三个 FPV 键按下去走到 announce，也没把模块带崩', lua(L, 'not ZMLFreecam.failed'),
      'reports=%s' % reports(L))
check('按键说了话（say_ 事件）', any(r.startswith('say_') for r in reports(L)), 'reports=%s' % reports(L))
# announce 里的 FPV 必须真的是那个模块：它是 local 声明在后面的（在旧稿里就漏了这一步，
# 于是中文日志通道一直是关的，只有 toast 能看到）
check('announce 认得出 FPV，走了中文日志通道（say_l*）',
      any(r.startswith('say_l') for r in reports(L)), 'reports=%s' % reports(L))
L.execute('PRESS=false')

print('旧 DLL（根本没有 fpv 模块）的情况')
L2, err2 = boot(with_fpv=False)
check('没有 fpv 模块也能起来', not err2, err2)
L2.execute('ZMLFreecam.show(nil)')
check('三个 FPV 键照旧注册（按键列表里能看见 = 模组加载上了）',
      lua(L2, "(function() local n=0 for k in pairs(ZMLFreecam.fpvKeys or {}) do n=n+1 end return n end)()") == 3)
L2.execute('PRESS=true')
L2.execute('TICK(0.02)')
check('没有模块时按键只是说清楚，自由镜头本身照常活着',
      lua(L2, 'not ZMLFreecam.failed') and any(r.startswith('say_') for r in reports(L2)),
      'reports=%s' % reports(L2))
check('没有模块时不碰日志通道（say_n*）', any(r.startswith('say_n') for r in reports(L2)),
      'reports=%s' % reports(L2))

print()
if fails:
    print('%d 项失败：%s' % (len(fails), fails))
    sys.exit(1)
print('全部通过')
