#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

NDK="${ANDROID_NDK_HOME:-${NDK:-}}"
if [ -z "$NDK" ]; then
  for d in "$HOME"/Android/Sdk/ndk/* "${LOCALAPPDATA:-}"/Android/Sdk/ndk/* \
           "$HOME"/Library/Android/sdk/ndk/*; do
    [ -d "$d" ] && NDK="$d"
  done
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "Set ANDROID_NDK_HOME to your NDK path"; exit 1; }

HOSTTAG=""
case "$(uname -s)" in
  Linux*)  HOSTTAG=linux-x86_64 ;;
  Darwin*) HOSTTAG=darwin-x86_64 ;;
  MINGW*|MSYS*|CYGWIN*) HOSTTAG=windows-x86_64 ;;
esac
BIN="$NDK/toolchains/llvm/prebuilt/$HOSTTAG/bin"
CC="$BIN/aarch64-linux-android29-clang"
[ -x "$CC" ] || CC="$CC.cmd"
STRIP="$BIN/llvm-strip"
[ -x "$STRIP" ] || STRIP="$STRIP.exe"

echo "[*] Compiling patcher/ledpatch (arm64) ..."
CFLAGS=(-std=c11 -O2 -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Werror)
"$CC" "${CFLAGS[@]}" -fPIE -pie -o module/patcher/ledpatch module/patcher/ledpatch.c
"$STRIP" module/patcher/ledpatch 2>/dev/null || true

echo "[*] Packaging q2touch_on_q3.zip ..."
rm -f q2touch_on_q3.zip
if command -v zip >/dev/null 2>&1; then
  ( cd module && zip -rX ../q2touch_on_q3.zip . -x '*.DS_Store' )
else
  PY=""
  for c in python3 python; do "$c" -c "" 2>/dev/null && { PY=$c; break; }; done
  [ -n "$PY" ] || { echo "Need zip or python"; exit 1; }
  "$PY" - <<'PY'
import os, zipfile
with zipfile.ZipFile('q2touch_on_q3.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('module'):
        for f in sorted(files):
            if f == '.DS_Store':
                continue
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, 'module').replace(os.sep, '/'))
PY
fi

echo "[ok] q2touch_on_q3.zip"
