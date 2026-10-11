#pragma once
#include "zml_plugin.h"

// 遥控接管（FPV）在游戏侧的一半。
//
// 职责只有两件：
//   1. 在本机 47800 端口收辅助程序的状态包（30 字节定长 UDP），顺手 2 Hz 回回执；
//   2. 通过 ModLoader 的 Lua 服务注册一个 Lua 源 ZML/Mod/freecam/state，
//      每次 LoadLua 现生成一小段 `return {…}`，把最新一包状态交给 Lua。
//
// 不在游戏侧做任何姿态解算——积分和相机写入都在 Lua 里，
// 因为拿相机、写位姿的判断逻辑已经全在 freecam.lua 那边了。
namespace freecam {
namespace fpv {
// 必须在模组 start() 里调用：Lua 源的注册只在初始化期间被接受。
bool start(const ZmlHost* host) noexcept;
void stop() noexcept;
}
}
