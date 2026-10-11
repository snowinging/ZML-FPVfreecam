#!/usr/bin/env bash
# 本机（Linux）交叉编译，使用 mingw-w64；产物目录与 CMake 的 package/Release/freecam 一致。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/package/Release/freecam"
mkdir -p "$root/build" "$out"
x86_64-w64-mingw32-g++ -std=c++20 -O2 -shared -static-libgcc -static-libstdc++ \
  -o "$root/build/FreeCam.dll" "$root/src/plugin.cpp" "$root/src/fpvlink.cpp" \
  -lws2_32 \
  -I"$root/sdk/include" -I"$root/src"
cp "$root/build/FreeCam.dll" "$out/FreeCam.dll"
for f in mod.ini config.ini icon.png freecam.lua freecam_core.lua fpv_link.lua zml-package.json; do
  cp "$root/mod/$f" "$out/$f"
done
ls -la "$out"
