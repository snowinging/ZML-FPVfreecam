#!/usr/bin/env bash
# 收包端离线探针：mingw 编成控制台程序，wine 里跑，配合同目录的 send_test.py 用真 ipc.py 发状态包。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
x86_64-w64-mingw32-g++ -std=c++20 -O2 -o "$root/build/fpv_probe.exe" \
  "$root/tests/fpv_probe.cpp" "$root/src/fpvlink.cpp" \
  -lws2_32 -static-libgcc -static-libstdc++ \
  -I"$root/sdk/include" -I"$root/src"
echo "编好了: $root/build/fpv_probe.exe"
