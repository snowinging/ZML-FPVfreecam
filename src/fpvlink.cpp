#include "fpvlink.hpp"
#include "zml_lua_service.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <tlhelp32.h>
#include <atomic>
#include <cstring>
#include <string>

namespace freecam {
namespace fpv {
namespace {

// ---- 协议常量，与 Endfield-FpvHelper/fpvhelper/ipc.py 一一对应 ----
constexpr unsigned short kPort = 47800;
constexpr int kTypeState = 1, kTypeStatus = 2;
constexpr unsigned short ST_ARMED = 1 << 1, ST_HOLD = 1 << 2, ST_CALIB = 1 << 3;
constexpr unsigned short SG_RUNNING = 1 << 0, SG_TAKEOVER = 1 << 1, SG_WANT_RESET = 1 << 2;
constexpr DWORD kReplyMs = 500;      // 回执 2 Hz 够算了：辅助程序只用它判在线和算 RTT
constexpr DWORD kStaleMs = 250;      // 超过这个没新包就当作断了
constexpr size_t kMaxPacket = 64;

#pragma pack(push, 1)
struct WireState {
    char magic[4]; unsigned char ver, type;
    unsigned short seq; unsigned int t_ms;
    short roll, pitch, yaw;
    unsigned short throttle, switches, buttons, aux, flags;
    unsigned int crc;
};
struct WireStatus {
    char magic[4]; unsigned char ver, type;
    unsigned short ack_seq; unsigned int echo_t;
    unsigned short flags, lost; unsigned int game_ms;
    unsigned short fps; unsigned int crc;
};
#pragma pack(pop)
static_assert(sizeof(WireState) == 32, "状态包必须是 32 字节");
static_assert(sizeof(WireStatus) == 26, "回执包必须是 26 字节");

unsigned int crc32(const unsigned char* data, size_t length) {
    unsigned int crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xEDB88320u & (~(crc & 1) + 1));
    }
    return ~crc;
}

// 收包线程和 Lua 源之间共享的那一份"最新状态"。
struct Snapshot {
    unsigned short seq{};
    unsigned int t_ms{};
    short roll{}, pitch{}, yaw{};
    unsigned short throttle{}, switches{}, buttons{}, aux{};
    unsigned short flags{};
    unsigned long long recvAt{};      // GetTickCount64，用来算 age
    bool have{};
    unsigned int lost{};
    // Lua 侧推回来的（用 LoadLua 走 push_ 路径）
    bool camera{};
    unsigned int gameFps{};
    bool wantReset{};
    unsigned long long notified{};    // 上次收到 push 的时间
};

CRITICAL_SECTION lock;
bool lockReady{};
Snapshot snapshot;
std::atomic<bool> running{false};
std::atomic<unsigned long long> generation{0};
SOCKET sock{INVALID_SOCKET};
const ZmlHost* hostApi{};
HANDLE threadHandle{};

void setText(std::string& out, const char* name, long long value) {
    out += name; out += '='; out += std::to_string(value); out += ',';
}

// 现生成给 Lua 的那一小段源码。字段和 fpv_link.lua 里读的一一对应。
std::string stateSource() {
    Snapshot copy;
    unsigned long long now = GetTickCount64();
    EnterCriticalSection(&lock);
    copy = snapshot;
    LeaveCriticalSection(&lock);
    long long age = copy.have ? static_cast<long long>(now - copy.recvAt) : 999999;
    bool ok = copy.have && age <= static_cast<long long>(kStaleMs);
    std::string out = "return {";
    setText(out, "n", static_cast<long long>(generation.fetch_add(1) + 1));
    setText(out, "seq", copy.seq);
    setText(out, "age", age);
    setText(out, "flags", copy.flags);
    setText(out, "ok", ok ? 1 : 0);
    setText(out, "armed", (copy.have && (copy.flags & ST_ARMED)) ? 1 : 0);
    setText(out, "hold", (copy.flags & ST_HOLD) ? 1 : 0);
    setText(out, "calib", (copy.flags & ST_CALIB) ? 1 : 0);
    setText(out, "roll", copy.have ? copy.roll : 0);
    setText(out, "pitch", copy.have ? copy.pitch : 0);
    setText(out, "yaw", copy.have ? copy.yaw : 0);
    setText(out, "throttle", copy.have ? copy.throttle : 0);
    setText(out, "switches", copy.switches);
    setText(out, "buttons", copy.buttons);
    setText(out, "aux", copy.aux);
    setText(out, "lost", copy.lost);
    setText(out, "fps", copy.gameFps);
    if (!out.empty() && out.back() == ',') out.pop_back();
    out += "}";
    return out;
}

// Lua 侧回推：路径形如 push_cam-1_fps-60。字符集只允许 [A-Za-z0-9.-_/]，
// 所以用 '-' 当分隔符，不能用 '=' ':'。
void applyPush(const char* path) {
    std::string text(path);
    bool camera = snapshot.camera, reset = false;
    unsigned int fps = 0;
    for (size_t at = 0; at < text.size();) {
        size_t end = text.find('_', at);
        if (end == std::string::npos) end = text.size();
        std::string item = text.substr(at, end - at);
        at = end + 1;
        size_t dash = item.find('-');
        if (dash == std::string::npos) continue;
        std::string key = item.substr(0, dash), value = item.substr(dash + 1);
        if (key == "cam") camera = value == "1";
        else if (key == "fps") { try { fps = static_cast<unsigned int>(std::stoul(value)); } catch (...) {} }
        else if (key == "reset") reset = true;
    }
    EnterCriticalSection(&lock);
    snapshot.camera = camera;
    if (fps) snapshot.gameFps = fps;
    if (reset) snapshot.wantReset = true;
    snapshot.notified = GetTickCount64();
    LeaveCriticalSection(&lock);
}

int luaSource(void*, const char* relativePath, ZmlSink sink, void* writer) {
    if (!relativePath || !sink) return 0;
    std::string path(relativePath);
    if (path == "state" || path.rfind("state/", 0) == 0) {
        std::string text = stateSource();
        sink(writer, text.data(), text.size());
        return 1;
    }
    if (path.rfind("push", 0) == 0) {
        applyPush(path.c_str());
        static const char answer[] = "return true";
        sink(writer, answer, sizeof(answer) - 1);
        return 1;
    }
    return 0;
}

void reply(const sockaddr_in& to, unsigned int now) {
    Snapshot copy;
    EnterCriticalSection(&lock);
    copy = snapshot;
    LeaveCriticalSection(&lock);
    WireStatus packet{};
    std::memcpy(packet.magic, "EFPV", 4);
    packet.ver = 1; packet.type = static_cast<unsigned char>(kTypeStatus);
    packet.ack_seq = copy.seq;
    packet.echo_t = copy.t_ms;
    packet.flags = SG_RUNNING;
    if (copy.camera) packet.flags |= SG_TAKEOVER;
    if (copy.wantReset) packet.flags |= SG_WANT_RESET;
    packet.lost = static_cast<unsigned short>(copy.lost > 0xFFFF ? 0xFFFF : copy.lost);
    packet.game_ms = now;
    packet.fps = static_cast<unsigned short>(copy.gameFps > 0xFFFF ? 0xFFFF : copy.gameFps);
    packet.crc = crc32(reinterpret_cast<const unsigned char*>(&packet), sizeof(packet) - 4);
    if (copy.wantReset) {
        EnterCriticalSection(&lock);
        snapshot.wantReset = false;
        LeaveCriticalSection(&lock);
    }
    sendto(sock, reinterpret_cast<const char*>(&packet), sizeof(packet), 0,
        reinterpret_cast<const sockaddr*>(&to), sizeof(to));
}

// 收包线程每隔一秒往模组日志里写一行，方便在游戏里出问题时定位：
// 是压根没收到包，还是收到了却没被接管。日志在 %LOCALAPPDATA%\ZML\runtime.log。
void logLine(const std::string& text) {
    if (hostApi && hostApi->log) hostApi->log(hostApi->owner, text.c_str());
}

DWORD WINAPI receiveLoop(void*) {
    sockaddr_in from{};
    int fromSize = sizeof(from);
    unsigned long long lastRecv = 0;
    unsigned int lastReply = 0;
    unsigned long long received = 0;
    unsigned long long lastReported = 0;
    unsigned int lastLog = 0;
    unsigned int lastEmptyLog = 0;
    bool announced = false;
    while (running.load(std::memory_order_relaxed)) {
        fd_set set;
        FD_ZERO(&set);
        FD_SET(sock, &set);
        timeval wait{0, 25000};
        int ready = select(0, &set, nullptr, nullptr, &wait);
        unsigned int now = static_cast<unsigned int>(GetTickCount64());
        if (ready > 0 && FD_ISSET(sock, &set)) {
            char buffer[kMaxPacket];
            fromSize = sizeof(from);
            int got = recvfrom(sock, buffer, sizeof(buffer), 0, reinterpret_cast<sockaddr*>(&from), &fromSize);
            if (got > 0) {
                if (got == static_cast<int>(sizeof(WireState))) {
                    WireState packet{};
                    std::memcpy(&packet, buffer, sizeof(packet));
                    bool good = std::memcmp(packet.magic, "EFPV", 4) == 0 && packet.ver == 1 &&
                        packet.type == kTypeState &&
                        packet.crc == crc32(reinterpret_cast<const unsigned char*>(buffer), sizeof(packet) - 4);
                    if (good) {
                        EnterCriticalSection(&lock);
                        if (snapshot.have) {
                            // 只认"顺着往前跳"的缺口：乱序、重复、辅助程序重启（seq 归零）都不算丢包。
                            int delta = static_cast<int>(
                                static_cast<unsigned short>(packet.seq - snapshot.seq)) - 1;
                            if (delta > 0 && delta < 0x4000) snapshot.lost += delta;
                        }
                        snapshot.seq = packet.seq; snapshot.t_ms = packet.t_ms;
                        snapshot.roll = packet.roll; snapshot.pitch = packet.pitch; snapshot.yaw = packet.yaw;
                        snapshot.throttle = packet.throttle; snapshot.switches = packet.switches;
                        snapshot.buttons = packet.buttons; snapshot.aux = packet.aux;
                        snapshot.flags = packet.flags;
                        snapshot.recvAt = GetTickCount64();
                        snapshot.have = true;
                        lastRecv = snapshot.recvAt;
                        ++received;
                        LeaveCriticalSection(&lock);
                    }
                }
            }
        }
        if (now - lastReply >= kReplyMs && lastRecv != 0) { reply(from, now); lastReply = now; }
        if (now - lastLog >= 1000) {
            lastLog = now;
            EnterCriticalSection(&lock);
            bool have = snapshot.have;
            unsigned short seq = snapshot.seq;
            unsigned int lost = snapshot.lost;
            unsigned int age = have ? (now - static_cast<unsigned int>(snapshot.recvAt)) : 0;
            LeaveCriticalSection(&lock);
            if (have && !announced) {
                announced = true;
                logLine("fpv 收到第一包，seq " + std::to_string(seq));
            }
            if (!have) {
                if (now - lastEmptyLog >= 5000) {
                    lastEmptyLog = now;
                    logLine("fpv 还没收到状态包（端口 " + std::to_string(kPort) +
                        "），辅助程序那头的「发给游戏」开了吗");
                }
            } else if (received != lastReported) {
                lastReported = received;
                logLine("fpv 收 " + std::to_string(received) + " 包，最新 seq " + std::to_string(seq) +
                    "，缺 " + std::to_string(lost) + "，age " + std::to_string(age) + "ms");
            }
        }
    }
    return 0;
}

// 找 ZML_GetLuaServicesV1：挨个模块问一遍，找不到就说明 loader 太老，不影响收包。
const ZmlLuaServicesV1* findServices() {
    auto probe = [](HMODULE module) -> const ZmlLuaServicesV1* {
        auto entry = reinterpret_cast<ZmlLuaServicesEntry>(reinterpret_cast<void*>(
            GetProcAddress(module, "ZML_GetLuaServicesV1")));
        if (!entry) return nullptr;
        const ZmlLuaServicesV1* services = entry();
        if (!services || services->abi != 1 || services->size < sizeof(ZmlLuaServicesV1)) return nullptr;
        return services;
    };
    if (const ZmlLuaServicesV1* services = probe(GetModuleHandleW(L"ZMLRuntime.dll"))) return services;
    HANDLE snapshotHandle = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (snapshotHandle == INVALID_HANDLE_VALUE) return nullptr;
    MODULEENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    const ZmlLuaServicesV1* found = nullptr;
    if (Module32FirstW(snapshotHandle, &entry)) {
        do {
            if (HMODULE module = entry.hModule) {
                found = probe(module);
                if (found) break;
            }
            entry.dwSize = sizeof(entry);
        } while (Module32NextW(snapshotHandle, &entry));
    }
    CloseHandle(snapshotHandle);
    return found;
}

}
bool start(const ZmlHost* host) noexcept {
    try {
        if (!host || !host->log || running.load()) return false;
        hostApi = host;
        if (!lockReady) { InitializeCriticalSection(&lock); lockReady = true; }
        WSADATA data{};
        WSAStartup(MAKEWORD(2, 2), &data);
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock == INVALID_SOCKET) return false;
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(kPort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(sock, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
            closesocket(sock); sock = INVALID_SOCKET; return false;
        }
        u_long nonBlocking = 1;
        ioctlsocket(sock, FIONBIO, &nonBlocking);
        running.store(true);
        threadHandle = CreateThread(nullptr, 0, &receiveLoop, nullptr, 0, nullptr);
        const ZmlLuaServicesV1* services = findServices();
        bool registered = false;
        if (services) registered = services->register_source(host->owner, &luaSource, nullptr) == 1;
        std::string message = "fpv link: udp " + std::to_string(kPort) +
            (registered ? " + lua source" : (services ? " lua source rejected" : " lua service missing"));
        hostApi->log(hostApi->owner, message.c_str());
        return true;
    } catch (...) { return false; }
}
void stop() noexcept {
    running.store(false);
    if (sock != INVALID_SOCKET) { closesocket(sock); sock = INVALID_SOCKET; }
    if (threadHandle) { CloseHandle(threadHandle); threadHandle = nullptr; }
}
}
}
