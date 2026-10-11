# FPV/自由镜头 (FreeCam)

给《明日方舟：终末地》的自由飞行观察相机模组。基于 [sakevel/Endfield-ModTemplate](https://github.com/sakevel/Endfield-ModTemplate) 脚手架。

## 遥控接管（FPV）
链接遥控器以使用遥控器操控相机。


接管条件：自由镜头开着并已拿到相机、
遥控映射标定过并解锁、包在 250 ms 内、辅助程序没在标定、遥控器未急停。

 arm / mode / buzzer / turtle
解锁 / 模式 / 回平 / 翻正）， 
- `arm` 解锁：拨到高位接管相机
- `mode` 模式：两档开关
- 拨到高位＝手动模式（acro），
  低位＝模组设置。
- `buzzer` 回平键：按住＝忽略杆位，按松杆自稳回平（横滚与俯仰拉平，偏航仍随杆），可用"找平"。
- `turtle` 翻正键：按住＝收平姿态、冻结偏航、油门切至悬停。。

镜头角度（`fpv_cam_tilt`，默认 15 度）

游戏内另有三个键（同样注册进 设置→按键），用于排查：

- `Insert` 遥控接收开关：不再接受发射端信号
- `Delete` 强制接管：排障用
- `End` 链路自检：LOG： `%LOCALAPPDATA%\ZML\runtime.log`LOG： `ZML/Mod/fpvfreecam/log-<十六进制>`

游戏侧LOG（`runtime.log`）每秒一条。
（`fpv_rate_*`）、曲线多陡（`fpv_expo`）、姿态上限、镜头角度可在配置页面调节
## 操作
默认freecam操作
设置→按键，可各自单独绑：

| 操作 | 默认键位 |
|---|---|
| 开关自由镜头 | `\` |
| 前后左右 | `↑` `↓` `←` `→` |
| 上升 / 下降 | `.` `/` |
| 加速 | `RightShift` |



## 构建
- Windows：`tools/build.ps1`。
- Linux 本机交叉验证：`tools/build-linux.sh`（mingw-w64，产物在 `build/package/Release/fpvfreecam`）。

## 署名与鸣谢

- 作者：snowinging、DeepSeek（AI 协作，参与协议设计、Lua 侧实现、遥控辅助程序与文档）
- 永动接线器 —— ZML 模组「第一人称」的作者，本项目的相机接管路径与面板结构参考了那套写法
- sakevel —— ZML 加载器、按键绑定模组，以及起项目用的模组模板 `Endfield-ModTemplate`
- 飞控部分（角度/半自稳/手动三模式、串级 PID 与姿态解算）沿用EE-FPV项目的思路
