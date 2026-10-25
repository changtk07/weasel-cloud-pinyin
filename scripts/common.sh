# Paths shared by the build, test and deploy scripts. Source it, don't run it.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG=$ROOT/.tools/zig/zig
LUA_INC=$ROOT/.tools/lua/lua-5.4.7/src
RIME_INC=$ROOT/.tools/librime
RIME_ICE=$ROOT/.tools/rime-ice-dl/x
BUILD=$ROOT/build

WEASEL=$(ls -d "/mnt/c/Program Files/Rime"/weasel-* | sort -V | tail -1)

win_env() { (cd /mnt/c && cmd.exe /c "echo %$1%" | tr -d '\r'); }

# Weasel's user folder: the registry setting if present, else %APPDATA%\Rime.
rime_user_dir() {
  dir=$(cd /mnt/c && reg.exe query 'HKCU\Software\Rime\Weasel' /v RimeUserDir 2>/dev/null |
    tr -d '\r' | sed -n 's/.*RimeUserDir *REG_SZ *//p')
  [ -n "$dir" ] || dir="$(win_env APPDATA)\\Rime"
  wslpath "$dir"
}

# Windows-side scratch area for tests (a Windows path, so DLLs load normally).
DEV=$(wslpath "$(win_env LOCALAPPDATA)")/ime-dev

# Copy rime-ice and our files into a RIME user folder.
# Leaves out rime-ice's weasel.yaml/squirrel.yaml (they would replace the
# user's own window style) and the schemas we don't use.
install_rime_files() {
  dest=$1
  mkdir -p "$dest/lua"
  (cd "$RIME_ICE" && cp -r cn_dicts en_dicts opencc lua custom_phrase.txt default.yaml \
    melt_eng.dict.yaml melt_eng.schema.yaml radical_pinyin.dict.yaml radical_pinyin.schema.yaml \
    rime_ice.dict.yaml rime_ice.schema.yaml symbols_caps_v.yaml symbols_v.yaml "$dest/")
  # Leave the schema menu on F4 only: VS Code and Zed open a terminal with
  # Ctrl+` and Ctrl+Shift+`. A switcher/hotkeys in default.custom.yaml still wins.
  sed -i '/^ *- Control+\(Shift+\)\?grave\r\?$/d' "$dest/default.yaml"
  cp "$ROOT/rime/lua/cloud_pinyin.lua" "$dest/lua/"
  cp "$ROOT/rime/rime_ice.custom.yaml" "$ROOT/rime/weasel.custom.yaml" "$dest/"
  chmod -f u+w "$dest/lua/cloudhttp.dll" || true
  cp "$BUILD/cloudhttp.dll" "$dest/lua/"
}
