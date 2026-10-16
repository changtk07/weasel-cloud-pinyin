#!/bin/sh
# Install rime-ice + Google cloud pinyin into Weasel's user folder and redeploy.
# If Yunpin isn't installed there yet, first backs up the folder (without
# build/) to backups/Rime-<time>.tar.gz. Restore: stop Weasel, empty the
# folder, extract the backup into it, redeploy.
set -eu
. "$(dirname "$0")/common.sh"

RIME_USER=$(rime_user_dir)
[ -f "$BUILD/cloudhttp.dll" ] || { echo "run scripts/build.sh first" >&2; exit 1; }

weasel_running() { (cd /mnt/c && tasklist.exe /FI "IMAGENAME eq WeaselServer.exe" | grep -qi weaselserver); }

# Stop the server so cloudhttp.dll isn't locked and Lua scripts reload.
(cd "$WEASEL" && ./WeaselServer.exe /q) || true
for _ in 1 2 3 4 5 6 7 8 9 10; do weasel_running || break; sleep 0.5; done
if weasel_running; then echo "WeaselServer.exe didn't stop" >&2; exit 1; fi

# cloud_pinyin.lua is ours alone, so its absence means a first install, even
# for someone who already uses rime-ice.
if [ ! -f "$RIME_USER/lua/cloud_pinyin.lua" ]; then
  mkdir -p "$ROOT/backups"
  backup="$ROOT/backups/Rime-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$backup" -C "$RIME_USER" --exclude=./build .
  echo "backup: $backup"
  for f in default.yaml rime_ice.custom.yaml weasel.custom.yaml; do
    [ ! -f "$RIME_USER/$f" ] || echo "replacing your $f (a copy is in the backup)"
  done
fi

install_rime_files "$RIME_USER"

# Put rime_ice first in the schema list, keeping the schemas already there.
# Only adds to default.custom.yaml, which may hold other settings. Weasel
# writes it with CRLF line endings; keep them.
f="$RIME_USER/default.custom.yaml"
if ! grep -q 'schema: rime_ice' "$f" 2>/dev/null; then
  cr=$(grep -q "$(printf '\r')" "$f" 2>/dev/null && printf '\r' || true)
  if grep -q '^  schema_list:' "$f" 2>/dev/null; then
    sed -i 's/^\(  schema_list:\)\(\r\?\)$/\1\2\n    - {schema: rime_ice}\2/' "$f"
  elif grep -q 'schema_list' "$f" 2>/dev/null; then
    echo "add {schema: rime_ice} to the schema list in $f yourself" >&2
  else
    # No schema_list patch: the list came from default.yaml, which
    # install_rime_files just replaced. The last deploy's result still has it.
    list=$(mktemp)
    printf '  schema_list:%s\n    - {schema: rime_ice}%s\n' "$cr" "$cr" >"$list"
    sed -n '/^schema_list:/,/^[^ ]/s/^  - schema: *//p' "$RIME_USER/build/default.yaml" 2>/dev/null |
      tr -d '\r"' | grep -vx rime_ice | while read -r s; do printf '    - {schema: %s}%s\n' "$s" "$cr"; done >>"$list"
    if grep -q '^patch:' "$f" 2>/dev/null; then
      sed -i "/^patch:\\r\\?\$/r $list" "$f"
    else
      { [ ! -s "$f" ] || [ -z "$(tail -c1 "$f")" ] || printf '%s\n' "$cr"
        printf 'patch:%s\n' "$cr"; cat "$list"; } >>"$f"
    fi
    rm -f "$list"
  fi
fi

echo "deploying (rime-ice takes about a minute the first time)..."
(cd "$WEASEL" && ./WeaselDeployer.exe /deploy)
# Start-Process, not cmd's start: a server started via cmd inherits WSL's
# output pipe, and this script would wait for it to exit.
(cd /mnt/c && powershell.exe -NoProfile -Command "Start-Process -FilePath '$(wslpath -w "$WEASEL/WeaselServer.exe")'")
grep -q 'schema: rime_ice' "$f" || { echo "rime_ice is not in $f" >&2; exit 1; }
echo "done"
