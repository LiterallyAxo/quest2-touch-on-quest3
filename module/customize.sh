#!/system/bin/sh

TARGET=/odm/lib64/libtrackingengines.so
PATCHER="$MODPATH/patcher/ledpatch"

say()  { ui_print "  $1"; }
line() { ui_print "=================================================="; }

line
ui_print "  Quest 2 Touch on Quest 3"
line

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
say "[ok] Firmware build $(getprop ro.build.version.incremental)"

if [ ! -f "$PATCHER" ]; then
  say "[!!] Patcher missing from package. Aborting."
  abort
fi
chmod 0755 "$PATCHER"

# If an older version of this module is active, $TARGET may currently be our
# patched copy; ledpatch would then (correctly) refuse it. Read the real file.
SRC="$TARGET"
if grep -q " $TARGET " /proc/self/mountinfo 2>/dev/null; then
  say "[*] Existing patch mounted; testing against stock file"
  STOCKDIR="$TMPDIR/odm_stock"; mkdir -p "$STOCKDIR"
  # A private bind of /odm shows the underlying stock file
  if mount -o bind /odm "$STOCKDIR" 2>/dev/null; then
    cp -f "$STOCKDIR/lib64/libtrackingengines.so" "$TMPDIR/stock.so"
    umount "$STOCKDIR"
    SRC="$TMPDIR/stock.so"
  fi
fi

OUT="$TMPDIR/libtrackingengines.test.so"
say "[*] Dry-run patching libtrackingengines.so ..."
PMSG=$("$PATCHER" "$SRC" "$OUT" 2>&1)
if [ $? -ne 0 ]; then
  say "[!!] Patch could not be verified on this firmware:"
  say "     ${PMSG#ledpatch: }"
  say "     Please open an issue on GitHub. Aborting."
  abort
fi

SZ_IN=$(wc -c < "$SRC"); SZ_OUT=$(wc -c < "$OUT")
NDIFF=$(cmp -l "$SRC" "$OUT" 2>/dev/null | wc -l)
rm -f "$OUT" "$TMPDIR/stock.so"
if [ "$SZ_IN" != "$SZ_OUT" ] || [ "$NDIFF" != "4" ]; then
  say "[!!] Unexpected patch result (size $SZ_IN->$SZ_OUT, $NDIFF bytes). Aborting."
  abort
fi
say "[ok] Verified: same size, 4 bytes changed"

set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0755 "$PATCHER"

line
say "Installed. Reboot to apply."
say "The library is re-patched in RAM on every boot,"
say "so system updates are picked up automatically."
line
