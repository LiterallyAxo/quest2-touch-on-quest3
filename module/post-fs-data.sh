#!/system/bin/sh

MODDIR=${0%/*}
TAG=q2touch_on_q3
LOG="$MODDIR/run.log"

log_line() { echo "$(date '+%H:%M:%S') post-fs-data: $1" >> "$LOG"; log -t $TAG "$1"; }

: > "$LOG"
log_line "start (build=$(getprop ro.build.version.incremental))"

EXPECT_BUILD=$(cat "$MODDIR/build_id" 2>/dev/null)
NOW=$(getprop ro.build.version.incremental)
if [ -n "$EXPECT_BUILD" ] && [ "$NOW" != "$EXPECT_BUILD" ]; then
  log_line "build changed ($EXPECT_BUILD -> $NOW); disabling module (reinstall to re-patch)"
  touch "$MODDIR/disable"
  exit 0
fi

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

resetprop -n persist.ovr.skipctrlfwupdate 1 || magisk resetprop -n persist.ovr.skipctrlfwupdate 1

resetprop -n persist.vendor.syncbosshal.disable_fw_version_check true || \
  magisk resetprop -n persist.vendor.syncbosshal.disable_fw_version_check true

awk '{print $1; exit}' /proc/uptime > "$MODDIR/armed_uptime"

resetprop -n debug.q2touch.state "post-fs-data: props set; waiting for service.sh" 2>/dev/null
log_line "skipctrlfwupdate=1, syncbosshal fw-version check off (memory-only); freepair deferred"
