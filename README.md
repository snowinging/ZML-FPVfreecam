# 自由镜头 (FreeCam)

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
  `ZML/Mod/freecam/state`：每次 `LoadLua` 它现生成一小段 `return {seq=…,roll=…,throttle=…}`，
  所以 Lua 拿到的永远是最新一包，不用落文件，也不用两边时钟对齐。
- Lua 侧（`mod/fpv_link.lua`）每帧取包，把 roll/pitch/yaw 角速率积分成相机姿态、油门当推力，
  再交给原有的 `Tick`/`TailTick` 写入路径；同时每 0.5 秒把「相机是不是被遥控接管着 + Lua 帧率」
  用 `LoadLua('ZML/Mod/freecam/push_cam-1_fps-60')` 回推给插件，辅助程序那栏就能显示出来。

接管条件（任何一条不满足就还给键鼠，不会卡在半接管状态）：自由镜头开着并已拿到相机、
遥控映射标定过并解锁、包在 250 ms 内、辅助程序没在标定、遥控器没有打急停。

遥控器上的四个开关（辅助程序「映射」那栏的 arm / mode / buzzer / turtle，按位进 `switches`）：

- `arm` 拨上来才接管；拨回去立刻交回键鼠。
- `mode` 拨上去是纯速率（穿越机手感），拨下来是自稳：松杆后俯仰横滚自动回水平，偏航不受影响。
  不想要自稳就在模组设置里把 `fpv_selflevel` 关掉，那样一律纯速率。回平快慢是 `fpv_level_speed`。
- `buzzer` 按住 = 强制回平：无视杆位把俯仰横滚往水平收，用来"找平"最快。
- `turtle` 按住 = 翻正：立刻收平、偏航冻住、油门切掉（0.3 秒内收完，不会一巴掌甩过去）。

断链或收杆交回键鼠时，叠加的横滚角是收着退回 0 的（240 度/秒），俯仰偏航不动——视线停在哪就是哪。

游戏内另有三个键（同样注册进 设置→按键），用来开关和查问题：

- `Ctrl+F7` 遥控接收开关：关掉就完全不认遥控器，立刻交回键鼠（设置页里的 `fpv` 是总闸，这个是一次性的旁路）。
- `Ctrl+F8` 强制接管：排障用，忽略 arm、校准、映射是否标全，只要包还在就接管；「包断了」这条底线不放过。
- `Ctrl+F9` 链路自检：按一下把整条链路的状态说清楚——为什么没接管、seq、包龄、游戏共收到几包、几个坏包——
  写进 `%LOCALAPPDATA%\ZML\runtime.log`（正文走 `ZML/Mod/freecam/log-<十六进制>` 这条 Lua 回推通道，
  C++ 侧解回来写日志），同时尽力在游戏里弹一下提示。

游戏侧自己的日志（`runtime.log`）每秒会有一条：收到了多少包、缺多少、包龄多少；一个包都没收到时每 5 秒
提醒一次，若反而收到过坏包会点明"八成是版本对不上"。

正负约定：`roll>0` 右滚、`pitch>0` 抬头、`yaw>0` 右偏航；转成 Unity 欧拉角时俯仰和横滚都取负
（Unity 的 x 越小越抬头、横滚右压是负 z）。手感倍率和角度上限在模组设置里（`fpv_scale` / `fpv_limit`）。

## 操作

七个动作全部注册进游戏 设置→按键，可各自单独绑：

| 操作 | 默认键位 |
|---|---|
| 开关自由镜头 | `Ctrl+F6` |
| 前后左右 | `I` `K` `J` `L` |
| 升降 | `U` `O` |
| 加速 | `LeftShift` |

键位故意和角色的 `WASD` 错开，所以自由镜头飞的时候角色也会按自己的键走动，互不抢键。
原生绑定读取失败时回退到同一套硬编码键位（`M.actsBroken` 一次性降级）。

## 不做的事

- **不冻结角色输入**。「冻结角色」选项已废弃（v0.1.16 移除）：`playerController.blockPlayerInput` /
  `cameraEnabled` 都是只读属性，Lua 写不进去；`movementComponent.input.moveVector` 同样写不进去。
  改角色 `Transform.position` 硬钉能实现，但要每帧抢写引擎状态，反作弊面明显变大，不值得。

## 构建

- Windows：`tools/build.ps1`（MSVC，发布用）。
- Linux 本机交叉验证：`tools/build-linux.sh`（mingw-w64，产物在 `build/package/Release/freecam`）。

## 状态与下一步

- 已验证：进出自由镜头、按键绑定、鼠标转视角、退出后相机复位。
- 与 `first-person-remix` 同时开启会互抢主相机。仲裁方案（`_G` 上放 claim/每帧持有权检查/`forceClose` 回调注册表，
  freecam 侧已备好 `M.isActive` / `M.forceClose`）还等两边都稳定后再实施。
- 已验证：遥控收包端在 wine 里跑通过真 `ipc.py` 发的 250 Hz 状态包（1250 包、缺号数只认故意漏的 4 个、
  回执 2 Hz、延迟 0.3~4.2 ms），定值包原样进到生成的 Lua 源码里；Lua 侧整层有脚本化测试
  `python3 tests/test_fpv_lua.py`（八条拒绝路径、积分与缠绕限幅、自稳/回平/翻正、交回衰减，共 41 项）。
- 还没在真游戏里跑过：进游戏后的手感、以及游戏自己有没有缓存 `LoadLua`（真缓存了就得给 path 加序号）。
- 下一步计划：进游戏实测手感；再看速度联动 FOV、混控（真穿越机的 roll/pitch 联动）、HUD。
