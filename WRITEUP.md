# Technical Writeup

Why Quest 2 Touch (`jedi`) controllers do not work on a Quest 3 (`eureka`), and how the module fixes each issue.

## Summary

The Quest 3 tracking stack already recognizes `CONTROLLER_JEDI_LEFT` and `CONTROLLER_JEDI_RIGHT`. The controllers are blocked by four software checks, not by hardware.

| # | Blocker | Fix |
|---|---------|-----|
| 1 | Pairing is refused | `persist.ovr.tracking.freepair=1` |
| 2 | Missing controller firmware aborts the HAL | `persist.ovr.skipctrlfwupdate=1` |
| 3 | LED on-time cap aborts `trackingservice` | 4-byte patch to `libtrackingengines.so` |
| 4 | Controller data is dropped | `persist.vendor.syncbosshal.disable_fw_version_check=true` |

## Blockers

### 1. Pairing gate

`ControllerGlue` in `libcmsservice-headset.so` refuses jedi controllers on a Quest 3. A debug bypass skips the refusal when `persist.ovr.tracking.freepair` is true. With it set, logcat shows `Advertising controller details ... type: JEDI` and pairing completes.

### 2. Firmware update abort

After pairing, the stack tries to update the controller from `/odm/firmware/jedi_archive.bin`. The file does not exist on a Quest 3, so the sensors HAL aborts. `requiresFirmwareUpdate()` in the CMS service reads `persist.ovr.skipctrlfwupdate` once at startup, so the property must be set before the service starts.

### 3. LED on-time cap

`trackingservice` configures the controller IR LEDs through `libtrackingengines.so`. When the requested on-time exceeds the headset limit, it calls a fatal error path:

```text
Fatal error: Cannot set LED ontime 34us more than what headset allows (30us) ...
```

The check is one branch:

```asm
ldr   d1, [x8, #0x580]   ; headset limit (30.0)
fcmp  d1, d0             ; requested on-time (34.0)
b.mi  <over-limit block> ; taken when limit < requested
```

Replacing `b.mi` with `nop` sends execution to the normal path that applies the on-time. Quest 3 controllers request an on-time within the limit, so the branch is never taken for them and their behavior is unchanged.

### 4. Dropped controller data

With fixes 1 to 3 applied, the controller connects but reports no motion samples. The sensors HAL (`libsyncboss.so`) discards data from any controller whose firmware version cannot be matched against `/odm/firmware/<type>_archive.bin`, and `jedi_archive.bin` is absent.

`persist.vendor.syncbosshal.disable_fw_version_check=true` disables that match. The HAL reads it once at startup. With it set, IMU and button data are forwarded and tracking works.

## Systemless Design

- **OverlayFS.** The patched library lives in an ext4 image on `/data`, mounted over `/odm/lib64` by Magisk OverlayFS. The `/odm` partition is untouched.
- **Memory-only properties.** Set with `resetprop -n`, which bypasses `/data/property/persistent_properties`. They do not survive a boot without the module.
- **No partition writes.** No block device writes, remounts, fastboot flashing, or `vbmeta` changes. Verified boot is unaffected.

## Install-Time Patcher

A prebuilt library would only match one firmware build. Instead, `patcher/ledpatch` patches the device's own copy during install. It locates the guard as follows:

1. The string `Cannot set LED ontime` must appear exactly once.
2. The first instruction that loads its address (`adrp` + `add` or `adrp` + `ldr`) is found. The nearest call target at or before it is the fatal formatter `F`.
3. `F` must have exactly one call site, `C`.
4. Exactly one `b.mi` may follow `fcmp d1, d0` within three instructions and branch to a target `T` where `branch < T <= C <= T + 0x200`.

Zero or multiple matches at any step aborts the install.

The installer then verifies the output independently: identical file size and exactly four changed bytes. On the development firmware, the result is byte-identical to the manually verified patch. The input file is never modified.

## Boot Sequencing

Root is applied after `init` has started `trackingservice` and the sensors HAL. At that point the first `trackingservice` has loaded the stock library, and the HAL has cached the firmware check setting.

`post-fs-data.sh` records the uptime at which the module armed. `service.sh` compares each service's start time from `/proc/<pid>/stat` against it and restarts stale services once with `setprop ctl.restart`. The pairing gate opens only after both services are confirmed running post-arm. Otherwise it stays closed.

## Safety

- **OTA guard.** The firmware build ID is recorded at install. If it changes, the module disables itself at boot.
- **Crash-loop guard.** Two consecutive boots that do not finish arming disable the module.
- **Failure mode.** `trackingservice` is not a critical service. A bad patch breaks controllers, not boot.
- **Reversible.** Removing the module restores the stock state.

## Known Limitation

Paired Quest 2 controllers connect before root is applied, which triggers the LED cap abort until `service.sh` restarts the services. The workaround is described in the [README](README.md#known-issue-rebooting). Blocking these early connections without modifying system files is an open problem.

## Diagnostics

```bash
adb shell getprop debug.q2touch.state
adb shell cat /data/adb/modules/q2touch_on_q3/run.log
```

## Source Layout

| Path | Purpose |
|------|---------|
| `module/customize.sh` | Install: patches the device's library and builds the overlay image |
| `module/post-fs-data.sh` | Early boot: OTA and crash-loop guards, sets properties |
| `module/service.sh` | Late boot: restarts stale services, opens the pairing gate |
| `module/patcher/ledpatch.c` | Offset-free ELF patcher |
| `build.sh` | Builds the patcher and packages the zip |

## AI Disclosure

This writeup was written entirely by AI based on all my research and finalized build, because I did not trust myself to explain everything perfectly and I want it to be accurate. sorry pooks...
