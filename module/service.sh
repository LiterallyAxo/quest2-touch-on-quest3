#!/system/bin/sh

MODDIR=${0%/*}
TAG=q2touch_on_q3
LOG="$MODDIR/run.log"
CLK=$(getconf CLK_TCK 2>/dev/null); CLK=${CLK:-100}

log_line() { echo "$(date '+%H:%M:%S') service: $1" >> "$LOG"; log -t $TAG "$1"; }
state()    { resetprop -n debug.q2touch.state "$1" 2>/dev/null || magisk resetprop -n debug.q2touch.state "$1"; log_line "$1"; }

finish() { rm -f "$MODDIR/boot_pending" "$MODDIR/boot_fail"; exit 0; }

[ -f "$MODDIR/disable" ] && exit 0

ARMED=$(cat "$MODDIR/armed_uptime" 2>/dev/null)
if [ -z "$ARMED" ]; then
  state "closed: no armed reference (post-fs-data did not run?)"
  finish
fi

proc_start() {
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  echo "${s##*") "}" | awk -v c="$CLK" '$20 != "" { printf "%.2f", $20 / c; ok = 1 } END { exit !ok }'
}

freshness() {
  local pid st
  pid=$(pidof "$1" 2>/dev/null) || { echo none; return; }
  pid=${pid%% *}
  st=$(proc_start "$pid") || { echo none; return; }
  if awk -v a="$st" -v b="$ARMED" 'BEGIN{exit !(a < b)}'; then echo stale; else echo fresh; fi
}

ensure_fresh() {
  local proc="$1" svc="$2" label="$3" restarted=0 i=0 s
  while :; do
    s=$(freshness "$proc")
    [ "$s" = fresh ] && { log_line "$label: running post-arm (ok)"; return 0; }
    if [ "$s" = stale ] && [ $restarted -eq 0 ]; then
      state "$label started before overlay/props; restarting it once"
      setprop ctl.restart "$svc"
      restarted=1
      i=0
      sleep 3
      continue
    fi
    i=$((i + 1))
    [ $i -ge 90 ] && { state "closed: $label could not be confirmed (state=$s)"; return 1; }
    sleep 1
  done
}

ensure_fresh vendor.oculus.hardware.sensors@1.0-service vendor.oculus.sensors-hal-1-0 "sensors HAL" || finish
ensure_fresh trackingservice trackingservice "trackingservice" || finish

resetprop -n persist.ovr.tracking.freepair 1 || magisk resetprop -n persist.ovr.tracking.freepair 1
state "armed: pairing gate open; sensors HAL + trackingservice confirmed running post-overlay"
finish
