#!/system/bin/sh

MODDIR=${0%/*}
TAG=q2touch_on_q3
LOG="$MODDIR/run.log"
TARGET=/odm/lib64/libtrackingengines.so
PATCHER="$MODDIR/patcher/ledpatch"
WORK=/dev/.q2touch
PATCHED="$WORK/libtrackingengines.so"

log_line() { echo "$(date '+%H:%M:%S') post-fs-data: $1" >> "$LOG"; log -t $TAG "$1"; }
state()    { resetprop -n debug.q2touch.state "$1" 2>/dev/null; log_line "$1"; }
fail()     { state "closed: $1"; rm -f "$PATCHED"; exit 0; }

: > "$LOG"
rm -f "$MODDIR/armed_uptime"
log_line "start (build=$(getprop ro.build.version.incremental))"

# Boot-loop guard: service.sh clears boot_pending once boot completes.
if [ -f "$MODDIR/boot_pending" ]; then
  N=$(cat "$MODDIR/boot_fail" 2>/dev/null); N=${N:-0}; N=$((N + 1))
  echo "$N" > "$MODDIR/boot_fail"
  log_line "previous boot did not complete (fail count=$N)"
  if [ "$N" -ge 2 ]; then
    log_line "two incomplete boots in a row; disabling module for safety"
    touch "$MODDIR/disable"
    exit 0
  fi
else
  rm -f "$MODDIR/boot_fail"
fi
touch "$MODDIR/boot_pending"

# Patch the live library into tmpfs (adapts to OTAs automatically).
if grep -q " $TARGET " /proc/self/mountinfo; then
  log_line "$TARGET already bind-mounted; skipping patch"
else
  mkdir -p "$WORK"; chmod 0755 "$WORK"
  chmod 0755 "$PATCHER"
  PMSG=$("$PATCHER" "$TARGET" "$PATCHED" 2>&1) || fail "ledpatch failed: $PMSG"
  [ "$(wc -c < "$TARGET")" = "$(wc -c < "$PATCHED")" ] || fail "size mismatch"
  NDIFF=$(cmp -l "$TARGET" "$PATCHED" 2>/dev/null | wc -l)
  [ "$NDIFF" = "4" ] || fail "expected 4 changed bytes, got $NDIFF"

  chown 0:0 "$PATCHED"; chmod 0644 "$PATCHED"
  TCON=$(ls -Zd "$TARGET" | awk '{ print $1 }')
  chcon "${TCON:-u:object_r:vendor_file:s0}" "$PATCHED" || fail "chcon failed"

  mount -o bind "$PATCHED" "$TARGET" || fail "bind mount failed"
  log_line "bind-mounted patched library ($TCON)"
fi

resetprop -n persist.ovr.skipctrlfwupdate 1
resetprop -n persist.vendor.syncbosshal.disable_fw_version_check true

awk '{print $1; exit}' /proc/uptime > "$MODDIR/armed_uptime"

state "post-fs-data: lib mounted, props set; waiting for service.sh"
