// 收包端的离线探针：把 fpvlink.cpp 单独编成一个 Windows 控制台程序，在 wine 里跑，
// 用真实的 fpvhelper/ipc.py 往它发状态包，看它收得对不对、回执对不对、生成给 Lua 的源码长什么样。
// 不参与打包，只用来验证协议层。构建见 tests/run_probe.sh
#include "fpvlink.hpp"
#include "zml_lua_service.h"
#include <windows.h>
#include <cstdio>
#include <string>

namespace {
ZmlLuaSource provider{};
void* providerData{};
ZmlSink probeSink{};
void* probeWriter{};

int register_source(void*, ZmlLuaSource source, void* data) {
    provider = source; providerData = data; return 1;
}

void host_log(void*, const char* message) { std::printf("[host] %s\n", message ? message : ""); }

int transform_stub(void*, const char*, ZmlLuaTransform, void*) { return 1; }

std::string readSource(const char* path) {
    std::string out;
    if (!provider) return "<provider 没注册>";
    auto sink = +[](void* data, const char* bytes, size_t length) {
        static_cast<std::string*>(data)->assign(bytes, length);
    };
    int accepted = provider(providerData, path, sink, &out);
    if (!accepted) return "<provider 拒了>";
    return out;
}
}

extern "C" __declspec(dllexport) const ZmlLuaServicesV1* ZML_GetLuaServicesV1() {
    static const ZmlLuaServicesV1 services{sizeof(ZmlLuaServicesV1), 1, &register_source};
    return &services;
}

int main(int argc, char** argv) {
    int seconds = argc > 1 ? std::atoi(argv[1]) : 3;
    ZmlHost host{};
    host.size = sizeof(ZmlHost);
    host.abi = 1;
    host.owner = &host;
    host.log = &host_log;
    host.transform_lua = &transform_stub;
    if (!freecam::fpv::start(&host)) { std::printf("start 失败\n"); return 1; }
    std::printf("收包端起来了，等 %d 秒\n", seconds);
    for (int i = 1; i <= seconds; ++i) {
        Sleep(1000);
        if (i == 1) {
            // 模拟 Lua 侧的回推：相机已接管 + 报帧率
            std::printf("[probe] push -> %s\n", readSource("push_cam-1_fps-57").c_str());
            // Lua 侧的中文日志通道：正文编成十六进制塞在路径里，C++ 解回来写进模组日志
            const char* sentence = "fpv 自检：状态包收到了，Lua 这一半也在跑";
            std::string hexPath = "log-";
            for (const char* at = sentence; *at; ++at) {
                char pair[3];
                std::snprintf(pair, sizeof(pair), "%02x", static_cast<unsigned char>(*at));
                hexPath += pair;
            }
            readSource(hexPath.c_str());
        }
        std::printf("[probe] t=%ds state: %s\n", i, readSource("state").c_str());
    }
    std::printf("[probe] 拒绝未知路径: %s\n", readSource("nope").c_str());
    Sleep(700);   // 等一次回执
    std::printf("[probe] 结束\n");
    return 0;
}
