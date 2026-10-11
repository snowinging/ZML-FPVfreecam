# FPV/自由镜头 (FreeCam)

给《明日方舟：终末地》的自由飞行观察相机模组。基于 [sakevel/Endfield-ModTemplate](https://github.com/sakevel/Endfield-ModTemplate) 脚手架。

## 原理

沿用第一人称模组验证过的相机接管路径：

- Native 插件只做两件事：把 `freecam_core.lua` + `freecam.lua` 拼成一段 helper，注入到 `UI/Panels/BattleAction/BattleActionCtrl` 的类声明之前，并挂钩它的 `OnShow/OnHide/OnClose`；再往 `UI/Panels/LevelCamera/LevelCameraCtrl._MoveCamera` 和 `ZoomCamera` 里插桩。
- Lua 侧从 `GameInstance.cameraManager` 取 `mainCamera` 与 `cinemachineBrainCpt`，自己建一个 `CinemachineVirtualCamera` 挂到 `manager.virtualCamsRoot`，用 `brain:SetCameraOverride(-1,nil,virtual,1,0)` 拿到 override。
- 每帧两个写入点：`LuaUpdate` 的 `Tick` 解算位姿并 `ForceCameraPosition`；`TailTick` 是最后写入点，直接 `camera.transform:SetPositionAndRotation` + `fieldOfView`/`nearClipPlane` 硬盖，绕过 Cinemachine 混合。
- 鼠标增量走 `LevelCameraCtrl._MoveCamera` 拦截（和第一人称同一条路）。平移/升降/加速七路输入注册进 `ZMLKeybinds`，走游戏原生按键绑定。

## 遥控接管（FPV）

接上遥控器以后不用键鼠也能飞，做法和真穿越机一样是**速率模式**：杆位给的是角速率（度/秒），
不是直接角度。

数据通路：

- Native 插件（`src/fpvlink.cpp`）在本机 `47800` 端口收状态包（32 字节定长 UDP，协议见
  `Endfield-FpvHelper/fpvhelper/ipc.py`），顺手 2 Hz 回一个回执（心跳 + 延迟 + 它数出来的缺号）。
- 同一个插件用 ModLoader 的 Lua 服务（`ZML_GetLuaServicesV1` → `register_source`）注册一个 Lua 源
  `ZML/Mod/fpvfreecam/state`：每次 `LoadLua` 它现生成一小段 `return {seq=…,roll=…,throttle=…}`，
  所以 Lua 拿到的永远是最新一包，不用落文件，也不用两边时钟对齐。
- Lua 侧（`mod/fpv_link.lua`）每帧取包，跑的是我们自己那套 EEfpv 的飞控（`renodx-Endfield-Enhancer` 里的
  `fpv.hpp`）：杆量 → 角速度 → 姿态 → 沿机体上方的推力 + 重力 + 阻力，最后落到 `M.pitch/M.roll/M.yaw`
  和 `M.velocity`，位置积分和写入还是走 `Tick`/`TailTick` 老路子；同时每 0.5 秒把「相机是不是被遥控接管着 +
  Lua 帧率」用 `LoadLua('ZML/Mod/fpvfreecam/push_cam-1_fps-60')` 回推给插件，辅助程序那栏就能显示出来。

接管条件（任何一条不满足就还给键鼠，不会卡在半接管状态）：自由镜头开着并已拿到相机、
遥控映射标定过并解锁、包在 250 ms 内、辅助程序没在标定、遥控器没有打急停。

遥控器上的四个开关。辅助程序「映射」那栏里对应 arm / mode / buzzer / turtle 四行（键名是英文，
   界面显示为解锁 / 模式 / 回平 / 翻正），按位进 `switches`：

- `arm` 解锁：拨到高位才接管；拨回去立刻交回键鼠。
- `mode` 模式：两档开关时拨到高位＝手动模式（杆位即角速度，姿态不设限，翻得过去也倒得过来，全靠自己回杆），
  拨到低位＝用模组设置里选的那个模式（默认 0 角度模式：杆位就是目标倾角，松杆自动回平）。
  三档拨杆（`switches` 的 bit1 不够用）：把辅助程序「映射」里的模式行类型改成「多档」，
  点「校准」逐档标定一遍，档位号走状态包的 `aux` 低两位（0 角度模式 / 1 半自稳 / 2 手动模式），
  同时置 flags 的 `ST_MODE_SEL`（bit4）表示 aux 有效；哪一档算哪个模式在「档位顺序」那栏排（默认 0,1,2）。
  设置页里的 `fpv_mode` 可以选 0 角度模式 / 1 半自稳 / 2 手动模式，半自稳是"双杆回中撑够 `fpv_horizon_delay` 秒才回平"。
  手动模式的姿态是用四元数按体轴角速度积的，所以能整圈翻；`fpv_limit` 只管半自稳里杆一出来那段，管不着它。
- `buzzer` 回平键：按住＝忽略杆位，按松杆自稳回平（横滚与俯仰拉平，偏航仍随杆），用来"找平"最快。
- `turtle` 翻正键：按住＝收平姿态、冻结偏航、油门切至悬停（不是掉下去，是停在半空，0.3 秒内收完）。

断链或收杆交回键鼠时，叠加的横滚角是收着退回 0 的（240 度/秒），俯仰偏航不动——视线停在哪就是哪。

镜头角度（`fpv_cam_tilt`，默认 15 度）：相机在机身上斜着装的那点仰角，真穿越机的相机都这么装，
平飞时前方才落在画面中间；填 0 就是相机和机头一样平。它是绕机体右轴转的固定安装角，
姿态转画面跟着转（低头 30 度装 20 度的镜头，画面就还剩 10 度低头），飞控那边一点没动——
真机上镜头歪不歪，机也不会因此改变姿态。

游戏内另有三个键（同样注册进 设置→按键），用来开关和查问题：

- `Insert` 遥控接收开关：关掉就完全不认遥控器，立刻交回键鼠（设置页里的 `fpv` 是总闸，这个是一次性的旁路）。
- `Delete` 强制接管：排障用，忽略 arm、校准、映射是否标全，只要包还在就接管；「包断了」这条底线不放过。
- `End` 链路自检：按一下把整条链路的状态说清楚——为什么没接管、seq、包龄、游戏共收到几包、几个坏包——
  写进 `%LOCALAPPDATA%\ZML\runtime.log`（正文走 `ZML/Mod/fpvfreecam/log-<十六进制>` 这条 Lua 回推通道，
  C++ 侧解回来写日志），同时尽力在游戏里弹一下提示。

游戏侧自己的日志（`runtime.log`）每秒会有一条：收到了多少包、缺多少、包龄多少；一个包都没收到时每 5 秒
提醒一次，若反而收到过坏包会点明"八成是版本对不上"。

协议与正负约定：辅助程序发过来的 `roll/pitch/yaw` 就是**杆量**本身（-10000..10000 = -100%..100%），
正号 = 右滚 / 推杆向前（对机体就是低头）/ 右偏航；模组这边不再反推、也不翻号，
`M.pitch>0` 就是低头、`M.roll>0` 左滚、`M.yaw>0` 右偏航，原样喂给 Unity 的 ZXY 欧拉角
（Unity 的 x 越大越低头、右压杆是负 z）。哪个方向反了，就在 `fpv_link.lua` 的 `stick()` 里改那一路的正负。

姿态积分分两套：角度那几档（角度模式 / 半自稳）算的是欧拉角，杆位就是"相对地平线的倾角"，P 控也是
照着欧拉角修的，两边对得上；手动模式那一档三个轴一律按**机体轴**转——俯仰绕机体右轴、横滚绕机体前轴、
偏航绕机体竖轴。偏航这里最要紧：要是绕世界竖轴，机头拉朝天之后打偏航就变成绕着机头自转，画面几乎
不动，而真机那时候是在竖直平面里翻过去（0.1.27 之前就是这个毛病）。

多少度每秒（`fpv_rate_*`）、曲线多陡（`fpv_expo`）、姿态上限、镜头角度这些全在模组设置的「遥控」那一栏，
辅助程序那边不用再对齐任何数字——协议 v2 起两边就没有共用参数了（老版本辅助程序会被判成"版本对不上"）。

## 操作

七个动作全部注册进游戏 设置→按键，可各自单独绑：

| 操作 | 默认键位 |
|---|---|
| 开关自由镜头 | `\` |
| 前后左右 | `↑` `↓` `←` `→` |
| 上升 / 下降 | `.` `/` |
| 加速 | `RightShift` |

键位全在右手区（方向键 + `Insert`/`Delete`/`End`），一个字母键都不占，跟游戏自己的快捷键错开；
所以自由镜头飞的时候角色也会按自己的键走动，互不抢键。
原生绑定读取失败时回退到同一套硬编码键位（`M.actsBroken` 一次性降级）。

## 不做的事

- **不冻结角色输入**。「冻结角色」选项已废弃（v0.1.16 移除）：`playerController.blockPlayerInput` /
  `cameraEnabled` 都是只读属性，Lua 写不进去；`movementComponent.input.moveVector` 同样写不进去。
  改角色 `Transform.position` 硬钉能实现，但要每帧抢写引擎状态，反作弊面明显变大，不值得。

## 构建

- Windows：`tools/build.ps1`（MSVC，发布用）。
- Linux 本机交叉验证：`tools/build-linux.sh`（mingw-w64，产物在 `build/package/Release/fpvfreecam`）。

## 状态与下一步

- 已验证：进出自由镜头、按键绑定、鼠标转视角、退出后相机复位。
- 与 `first-person-remix` 同时开启会互抢主相机。仲裁方案（`_G` 上放 claim/每帧持有权检查/`forceClose` 回调注册表，
  freecam 侧已备好 `M.isActive` / `M.forceClose`）还等两边都稳定后再实施。
- 已验证：遥控收包端在 wine 里跑通过真 `ipc.py` 发的 250 Hz 状态包（1250 包、缺号数只认故意漏的 4 个、
  回执 2 Hz、延迟 0.3~4.2 ms），定值包原样进到生成的 Lua 源码里；Lua 侧整层有脚本化测试
  `python3 tests/test_fpv_lua.py`（八条拒绝路径、积分与缠绕限幅、角度模式/回平/翻正、交回衰减，共 41 项）。
- 还没在真游戏里跑过：进游戏后的手感、以及游戏自己有没有缓存 `LoadLua`（真缓存了就得给 path 加序号）。
- 下一步计划：进游戏实测手感；再看速度联动 FOV、混控（真穿越机的 roll/pitch 联动）、HUD。


## 署名与鸣谢

- 作者：snowinging、DeepSeek（AI 协作，参与协议设计、Lua 侧实现、遥控辅助程序与文档）
- 永动接线器 —— ZML 模组「第一人称」的作者，本项目的相机接管路径与面板结构参考了那套写法
- sakevel —— ZML 加载器、按键绑定模组，以及起项目用的模组模板 `Endfield-ModTemplate`
- 飞控部分（角度/半自稳/手动三模式、串级 PID 与姿态解算）沿用自己在 EEfpv 里的那套实现
