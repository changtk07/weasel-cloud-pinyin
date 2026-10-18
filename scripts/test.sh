#!/bin/sh
# Run the tests on Windows (from WSL), in a scratch folder (%LOCALAPPDATA%\ime-dev).
#   scripts/test.sh http   cloudhttp.dll: latency, cache, timeout, offline
#   scripts/test.sh rime   the real RIME engine with rime-ice + cloud_pinyin, no UI
# Neither touches Weasel or your RIME user folder. Needs network access to Google;
# expected candidates are Google's answers as of 2026-10.
set -eu
. "$(dirname "$0")/common.sh"

win() { wslpath -w "$1"; }

mkdir -p "$DEV/bin"
chmod -f u+w "$DEV"/bin/* || true # rime.dll comes read-only from Program Files
cp "$BUILD/cloudhttp.dll" "$BUILD/luarun.exe" "$BUILD/rimetest.exe" "$WEASEL/rime.dll" "$DEV/bin/"
chmod u+w "$DEV"/bin/*
cd "$DEV"

# rimetest against a test user folder; first deploy compiles rime-ice (~1 min).
rime() {
  ./bin/rimetest.exe "$(win "$WEASEL/data")" "$(win "$DEV/user")" "$(win "$DEV/log")" "$@" | tr -d '\r'
}

fails=0
# check <exact output line> <rimetest commands...>
check() {
  want=$1
  shift
  out=$(rime "$@")
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -qxF -- "$want"; then
    echo "PASS: $want"
  else
    echo "FAIL: expected line '$want'"
    fails=$((fails + 1))
  fi
}

# Change the cloud endpoint, e.g. to a host that doesn't resolve to simulate no
# network. Run rime with "deploy" afterwards. RIME compares file times in whole
# seconds, so an edit in the same second as the last one looks like no change:
# wait a second first.
set_endpoint() {
  sleep 1
  sed -i "/endpoint:/d; s|^  cloud_pinyin:\$|  cloud_pinyin:\n    endpoint: $1|" "$DEV/user/rime_ice.custom.yaml"
}
GOOGLE=https://inputtools.google.com/request
NOWHERE=https://nonexistent.invalid/request

case "${1:-all}" in
http | all)
  cp "$ROOT/test/http_test.lua" "$DEV/"
  ./bin/luarun.exe "$(win "$DEV/http_test.lua")" "$(win "$DEV/bin")"
  ;;
esac

case "${1:-all}" in
rime | all)
  mkdir -p "$DEV/log"
  install_rime_files "$DEV/user"
  printf 'patch:\n  schema_list:\n    - schema: rime_ice\n' >"$DEV/user/default.custom.yaml"
  set_endpoint $GOOGLE
  rime deploy >/dev/null

  echo "== online: Google's sentence first"
  check '*1. 我们去公园 ☁' schema rime_ice type womenqugongyuan show select 1
  echo "== 繁 via Ctrl+Shift+4: Taiwan character forms"
  check '*1. 我們去公園 ☁' schema rime_ice keys '{Control+Shift+dollar}' type womenqugongyuan show select 1
  echo "== partial pick, then Google for the rest"
  check '*1. 公园 ☁' schema rime_ice type womenqugongyuan select 2 show select 1
  echo "== the input box shows what you typed, split like Google's pinyin, with '"
  check 'preedit: w' schema rime_ice type w show
  check "preedit: w'l'j'h" schema rime_ice type wljh show
  check "preedit: wo'men" schema rime_ice type women show
  check "preedit: xi'an" schema rime_ice type "xi'an" show
  echo "== Google first when other translators match too (English completions of lan)"
  check '*1. 蓝 ☁' schema rime_ice type lan show
  echo "== rime-ice's own picks stay ahead of Google: the date for rq, English for hello"
  check "*1. $(date +%Y-%m-%d)" schema rime_ice type rq show
  check '*1. hello' schema rime_ice type hello show

  echo "== offline: local only, no waiting"
  set_endpoint $NOWHERE
  check '*1. 我们去公园' deploy schema rime_ice type womenqugongyuan show
  echo "== the dictionary's candidates get ' too"
  check "preedit: w'm" schema rime_ice type wm show

  echo "== learning: pick Google's 元神 online, then it's first offline too"
  rm -rf "$DEV/user/rime_ice.userdb" # the test folder's, starts empty
  check '*1. 原神' schema rime_ice type yuanshen show
  set_endpoint $GOOGLE
  check '*1. 元神 ☁' deploy schema rime_ice type yuanshen show select 1
  set_endpoint $NOWHERE
  check '*1. 元神' deploy schema rime_ice type yuanshen show
  echo "== learning a word neither has: 泥 ☁ + 好 ☁ online, then 泥好 is first offline"
  set_endpoint $GOOGLE
  check 'commit: 泥好' deploy schema rime_ice type nihao select 6 select 1
  set_endpoint $NOWHERE
  check '*1. 泥好' deploy schema rime_ice type nihao show
  echo "== a local pick typed as an abbreviation keeps its pinyin: 未来机会 (wljh) + 奥 ☁"
  set_endpoint $GOOGLE
  check 'commit: 未来机会奥' deploy schema rime_ice type wljhao select 6 select 1
  set_endpoint $NOWHERE
  check '*1. 未来机会奥' deploy schema rime_ice type weilaijihuiao show

  set_endpoint $GOOGLE
  rime deploy >/dev/null
  echo "rime: $fails failed"
  [ "$fails" -eq 0 ]
  ;;
esac
