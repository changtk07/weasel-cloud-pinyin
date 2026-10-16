#!/bin/sh
# Install rime-ice + Google cloud pinyin into Weasel's user folder and redeploy.
# Before the first install, backs up the folder (without build/) to
# backups/Rime-<time>.tar.gz. Restore: stop Weasel, empty the folder, extract
# the backup into it, redeploy.
set -eu
. "$(dirname "$0")/common.sh"

RIME_USER=$(rime_user_dir)
[ -f "$BUILD/cloudhttp.dll" ] || { echo "run scripts/build.sh first" >&2; exit 1; }

weasel_running() { (cd /mnt/c && tasklist.exe /FI "IMAGENAME eq WeaselServer.exe" | grep -qi weaselserver); }

# Stop the server so cloudhttp.dll isn't locked and Lua scripts reload.
(cd "$WEASEL" && ./WeaselServer.exe /q) || true
for _ in 1 2 3 4 5 6 7 8 9 10; do weasel_running || break; sleep 0.5; done
if weasel_running; then echo "WeaselServer.exe didn't stop" >&2; exit 1; fi

if [ ! -f "$RIME_USER/rime_ice.custom.yaml" ]; then
  mkdir -p "$ROOT/backups"
  backup="$ROOT/backups/Rime-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$backup" -C "$RIME_USER" --exclude=./build .
  echo "backup: $backup"
fi

install_rime_files "$RIME_USER"

# Put rime_ice first in the schema list, keeping the existing schemas.
# Weasel writes this file with CRLF line endings; keep them.
f="$RIME_USER/default.custom.yaml"
if ! grep -q 'schema: rime_ice' "$f" 2>/dev/null; then
  if grep -q '^  schema_list:' "$f" 2>/dev/null; then
    sed -i 's/^\(  schema_list:\)\(\r\?\)$/\1\2\n    - {schema: rime_ice}\2/' "$f"
  else
    printf 'patch:\n  schema_list:\n    - {schema: rime_ice}\n' >"$f"
  fi
fi

echo "deploying (rime-ice takes about a minute the first time)..."
(cd "$WEASEL" && ./WeaselDeployer.exe /deploy)
# Start-Process, not cmd's start: a server started via cmd inherits WSL's
# output pipe, and this script would wait for it to exit.
(cd /mnt/c && powershell.exe -NoProfile -Command "Start-Process -FilePath '$(wslpath -w "$WEASEL/WeaselServer.exe")'")
grep -q 'schema: rime_ice' "$f" || { echo "rime_ice is not in $f" >&2; exit 1; }
echo "done"
