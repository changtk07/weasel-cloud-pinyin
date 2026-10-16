#!/bin/sh
# Cross-compile the Windows binaries with zig:
#   build/cloudhttp.dll                    HTTP module for lua/cloud_pinyin.lua (deployed)
#   build/luarun.exe, build/rimetest.exe   test tools
set -eu
. "$(dirname "$0")/common.sh"
mkdir -p "$BUILD"

# Import library for the Lua C API and rime_get_api, both exported by Weasel's rime.dll.
{
  echo "LIBRARY rime.dll"
  echo "EXPORTS"
  objdump -p "$WEASEL/rime.dll" | sed -n '/\[Ordinal\/Name Pointer\] Table/,/^$/p' |
    grep -oE ' (lua|luaL|luaopen|rime)_[A-Za-z0-9_]+$'
} >"$BUILD/rime.def"
"$ZIG" dlltool -d "$BUILD/rime.def" -l "$BUILD/librime.a" -m i386:x86-64

wincc() { "$ZIG" cc -target x86_64-windows-gnu -O2 -Wall -Wextra -I"$LUA_INC" "$@"; }
wincc -shared -o "$BUILD/cloudhttp.dll" "$ROOT/src/cloudhttp.c" -L"$BUILD" -lrime -lwinhttp
wincc -o "$BUILD/luarun.exe" "$ROOT/test/luarun.c" -L"$BUILD" -lrime
wincc -I"$RIME_INC" -o "$BUILD/rimetest.exe" "$ROOT/test/rimetest.c" -L"$BUILD" -lrime
