#!/system/bin/sh

TARGET=/odm/lib64/libtrackingengines.so
REL=system/odm/lib64
OUT="$MODPATH/$REL/libtrackingengines.so"
PATCHER="$MODPATH/patcher/ledpatch"

say()  { ui_print "  $1"; }
line() { ui_print "=================================================="; }

line
ui_print "  Quest 2 Touch on Quest 3"
line

OVF=/data/adb/modules/magisk_overlayfs
if [ ! -f "$OVF/util_functions.sh" ] || ! "$OVF/overlayfs_system" --test; then
  say "[!!] Magisk OverlayFS is not installed / not working."
  say "     Install 'magisk_overlayfs' first, then reinstall this."
  abort
fi
say "[ok] Magisk OverlayFS present"

DEV=$(getprop ro.product.device)
if [ "$DEV" != "eureka" ]; then
  say "[!!] This build is for Quest 3 (eureka) only. Aborting."
  abort
fi
say "[ok] Device is Quest 3 (eureka)"

if [ ! -f "$TARGET" ]; then
  say "[!!] $TARGET not found - wrong device/firmware. Aborting."
  abort
fi

BUILD=$(getprop ro.build.version.incremental)
say "[ok] Firmware build $BUILD"

if [ ! -f "$PATCHER" ]; then
  say "[!!] Patcher missing from package. Aborting."
  abort
fi
chmod 0755 "$PATCHER"

STOCK="$TMPDIR/libtrackingengines.stock.so"
cp -f "$TARGET" "$STOCK" || { say "[!!] Could not read the system library."; abort; }
mkdir -p "$MODPATH/$REL"

say "[*] Analysing libtrackingengines.so ..."
PMSG=$("$PATCHER" "$STOCK" "$OUT" 2>&1)
PRC=$?
if [ $PRC -ne 0 ]; then
  say "[!!] Patch could not be verified on this firmware:"
  say "     ${PMSG#ledpatch: }"
  say "     This usually means the firmware differs too"
  say "     much from what is tested. Please open an issue on GitHub. Aborting."
  abort
fi
say "[ok] Guard removed"

SZ_IN=$(wc -c < "$STOCK")
SZ_OUT=$(wc -c < "$OUT")
if [ "$SZ_IN" != "$SZ_OUT" ]; then
  say "[!!] Patched library changed size ($SZ_IN -> $SZ_OUT). Aborting."
  abort
fi
NDIFF=$(cmp -l "$STOCK" "$OUT" 2>/dev/null | wc -l)
if [ "$NDIFF" != "4" ]; then
  say "[!!] Expected exactly 4 changed bytes, got $NDIFF. Aborting."
  abort
fi
say "[ok] Verified: same size"

echo "$BUILD" > "$MODPATH/build_id"

TCON=$(ls -Zd "$TARGET" 2>/dev/null | awk '{ print $1 }')
set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0755 "$PATCHER"
chown 0:0 "$OUT"; chmod 0644 "$OUT"
[ -n "$TCON" ] && chcon "$TCON" "$OUT"

. "$OVF/util_functions.sh"
OVERLAY_IMAGE_EXTRA=0
OVERLAY_IMAGE_SHRINK=true

build_overlay() {
  [ -d "$MODPATH/system" ] || return 1
  OVERLAY_IMAGE_SIZE="$(sizeof "$MODPATH/system" "$OVERLAY_IMAGE_EXTRA")"
  rm -rf "$MODPATH/overlay.img"
  create_ext4_image "$MODPATH/overlay.img" || return 1
  resize_img "$MODPATH/overlay.img" "${OVERLAY_IMAGE_SIZE}M" || return 1
  loop_setup "$MODPATH/overlay.img"
  [ -n "$LOOPDEV" ] || return 1
  rm -rf "$MODPATH/overlay"; mkdir "$MODPATH/overlay"
  mount -t ext4 -o rw "$LOOPDEV" "$MODPATH/overlay" || return 1
  chcon u:object_r:system_file:s0 "$MODPATH/overlay"
  cp -afT "$MODPATH/system" "$MODPATH/overlay/system"
  ( cd "$MODPATH" || exit
    find "system" | while read -r p; do
      chcon "$(ls -Zd "$p" | awk '{ print $1 }')" "$MODPATH/overlay/$p"
      [ -e "$p/.replace" ] && setfattr -n trusted.overlay.opaque -v y "$MODPATH/overlay/$p"
    done )
  handle vendor; handle product; handle system_ext; handle odm
  umount -l "$MODPATH/overlay"
  [ "$OVERLAY_IMAGE_SHRINK" = "false" ] || resize_img "$MODPATH/overlay.img"
  rm -rf "$MODPATH/overlay"
  return 0
}

say "[*] Building OverlayFS image ..."
if build_overlay; then
  say "[ok] OverlayFS image built"
  rm -rf "$MODPATH/system"
else
  say "[!!] Failed to build overlay image. Aborting."
  abort
fi

line
say "Installed. Reboot to apply."
say "Reinstall after any system update."
line
