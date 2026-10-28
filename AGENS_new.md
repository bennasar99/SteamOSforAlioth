# AGENS_new — alioth handoff: changes done and tests pending

Date: 2026-10-27 (updated 2026-10-28)
Repo: `/home/toni/dev/SteamOSforAlioth`
Device: POCO F3 / Redmi K40 (`alioth`, 6 GB / 128 GB), postmarketOS replaced by SteamOS ARM.

This file records what was changed in the source tree, what is only in the
installed system, and what still has to be tested on the phone. It is not a
claim that any pending item works.

## Hard rules still apply

- Never write `abl_a` / `abl_b` or `vbmeta`. `super` is written only by the
  opt-in extra-storage migration (`boot-migrate.img` ->
  `alioth-super-migrate`); `flash-alioth.sh` itself never writes it.
- `userdata` is only written by `./flash-alioth.sh --install`, after the human
  types `ERASE`. Do not type it for them.
- Never raise the amplifier gains (`RCV` 4 / `LCV` 10).
- Test audio only with `scripts/alioth-speaker-test.sh`.
- Never commit firmware extracted from the phone.
- No rebuild or flash was done while making these changes. The existing
  `work/steamos-alioth` kit predates most of them.

## Current source vs installed phone

The source tree contains changes that are **not all installed** on the phone.
Do not confuse the two:

- The installed phone has the TDP + Manual GPU Clock power UI, the handheld
  `RUNSTEAM.sh`, the logind suspend drop-in, the **4 GiB LZ4** zram drop-in
  (measured 2026-10-28), the 2 GiB `/swapfile`, and the Refresh Rate removal.
  Profiles were removed from the service/remotes and are gone from the running
  UI; TDP and suspend are confirmed working.
- The installed phone now has the FPS session candidates (`vblank_mode=3` and
  `PROTON_ENABLE_WAYLAND=0`) but they do not cap Mirror's Edge in-game; A/B at
  `GAMESCOPE_FPS_LIMIT` 60 vs 30 both logged 62.0. The game config is 62 and no
  game file is modified.
- The source tree now installs the handheld `RUNSTEAM.sh` through
  `apply-alioth-devr.sh`, carries the full power UI, the VRR-off/FPS session
  fix, and the logind suspend drop-in; this is what the next build will use.
- Rebuilding/reflashing, or copying the files again, is required to make the
  installed system match the source exactly.
- The source tree now sets **3.5 GiB zram with lzo-rle** plus a **2 GiB
  `/swapfile`** (priority 50; zram priority 100). The running phone still
  reports **4G lz4** until it is rebooted with a rebuilt image (measured
  2026-10-28). The stock 2.7 GB `ram/2` lzo-rle value was a likely factor in
  the memory-pressure session crashes.
- The source tree also has the opt-in Set B migration to `super` (~4.5 GB of
  read-only system data + 2 GiB swap) through `boot-migrate.img` and
  `alioth-super-migrate`. It is not built or flashed yet; Android restore
  would then require a full stock ROM.
- `/opt/steamvr` is removed at build time. `gpu-trace`,
  `iris-driver-rebind`, and `steamos-log-submitter` are masked in the alioth
  layer; the log-submitter daemon was also masked manually on the running
  phone on 2026-10-28.
- `flash-alioth.sh` and `make-steamos-alioth.sh` are now fully English;
  `--install` asks separately whether to enable the extra-storage migration.
  `make-steamos-alioth.sh --install` also asks whether to apply the Razer
  Kishi 180-degree render+touch flip (`ALIOTH_ORIENTATION_FLIP=0/1`); the
  pair is installed or skipped together.
- The installed phone now also has the **Razer Kishi** orientation pair
  (`99-orientation.conf` + `71-alioth-flip.rules`); picture and touch are
  confirmed correct. Without a Razer Kishi, remove both and keep the
  unmodified orientation.
- The source tree now installs the SteamOS-ARM **Desktop Mode** session:
  `plasma.desktop -> sm8550-startplasma`, which runs `sm8550-prepare-plasma`
  (clears Game Mode xcb/env), `desktop-outputs`, `desktop-fit`, then
  `startplasma-wayland`. It also installs the new `steamos-session-select`,
  `desktop-steam` autostart redirect, portal-fix autostart and the plasma
  target/service drop-ins. The running phone still has Valve's old
  `plasma.desktop`/`steamos-session-select` until the next rebuild or manual
  deploy.
- The low-RAM per-game Steam mode is now in `alioth-overlay`: the watcher
  script, a `gamescope-session.target` user service, and the target drop-in.
  See "Low-RAM per-game Steam mode" below.

## Crash investigation (2026-10-27)

The phone was up when checked. No kernel panic/oops was found; the previous
boot ended with a Steam/session shutdown, and there is evidence of memory
pressure:

- `__vm_enough_memory: wine_threadpool ... bytes: 11727273984 not enough
  memory for the allocation` in the previous boot.
- `steam.service: Consumed ... 4.1G memory peak, 544.7M memory swap peak`.
- `steamwebhelper` SIGSEGV/SIGTRAP coredumps during the current boot.
- Current 6 GB phone at crash time: 5.4 GiB total, ~4.9 GiB used, ~115 MiB
  free, ~892 MiB zram used; load average ~11.7 while the game was running.
- `udisksd` was spamming `g_variant_new_string(): requires valid UTF-8` and
  using ~78% CPU; this is additional load, not a kernel crash.

The TDP service itself was healthy: it logged the user's rapid TDP changes
(3–10 W) without errors. The crash looks like a Steam UI/session memory
problem, not a TDP or kernel regression. The source zram drop-in now sets
3.5 GiB lzo-rle; the running phone still reports 4G lz4 until it is rebooted
with a rebuilt/reinstalled drop-in. The benchmark below was measured on the
earlier 4 GiB LZ4 device.

## Done: Steam power UI (TDP + Manual GPU Clock; profiles removed)

After the handheld `RUNSTEAM.sh` was installed and tested, Steam renders the
Performance page on alioth: TDP slider and Manual GPU Clock. The TDP limiter
was confirmed working on the phone.

Performance Profiles are now deliberately removed from both the service and
remotes because the Silent/Balanced/Turbo presets fought the TDP slider.
TDP is the control we keep.

### Source files

```text
alioth-overlay/usr/lib/steamos-arm/steamos-arm-power
alioth-overlay/usr/lib/steamos-arm/power_limits.py
alioth-overlay/usr/lib/systemd/system/steamos-arm-power.service
alioth-overlay/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-power.service
alioth-overlay/usr/share/steamos-manager/remotes.d/50-steamos-arm.toml
alioth-overlay/usr/share/steamos-manager/devices/xiaomi-alioth.toml
alioth-overlay/usr/share/dbus-1/system.d/org.steamos_arm.Power.conf
```

The service:

- owns `org.steamos_arm.Power` on the system bus;
- exposes `TdpLimit1` and `GpuPerformanceLevel1`; it no longer exposes
  `PerformanceProfile1`;
- applies the TDP-to-clock model itself (`power_limits.apply()`); alioth has no
  konkrd/odin3d daemon;
- Manual GPU Clock overrides the TDP GPU cap;
- persists state in `/var/lib/steamos-arm/performance.json`;
- the GPU cap logic can raise as well as lower the ceiling, and TDP 10 W
  restores the full GPU clock.
- The useless **Refresh Rate** option is removed: alioth is on the 60-only
  path in `gamescope-session` and clears `STEAM_DISPLAY_REFRESH_LIMITS`;
  `gamescope-onready` also clears a stale value from the user manager.

The device TOML matches `xiaomi,alioth` and uses the same SM8250 handheld class
(`retroid_pocket`/`RP5`) while keeping `friendly_name = "Xiaomi Poco F3"`.
That is what makes the handheld client show the Performance page.

### On-device status

- More Performance options appeared after installing the handheld
  `RUNSTEAM.sh`.
- TDP limiter confirmed working.
- Manual GPU Clock was already visible and usable; the user selected manual
  clocks around 305–405 MHz.
- The installed phone now has the TDP/GPU back end with profiles removed;
  the source overlay matches it.

### Deployment archive

The archive is regenerated after this documentation update; see
`work/alioth-power-ui.tar` and `work/alioth-power-ui-install.sh`. It installs
the TDP/GPU power UI, including `power_limits.py` and the device TOML, and
does not install a Performance Profile interface.

## zram benchmark (2026-10-27)

Raw zram block-device benchmark on the phone, 4 GiB device, 4 KiB writes.
Datasets: 128 MiB zeros, 128 MiB real `/usr/lib`+`/usr/share` payload, 32 MiB
urandom. Run-to-run variance is about 5–10% on this phone; treat the close
numbers as ties.

| algorithm | dataset | write | read | ratio |
|---|---|---|---:|---:|---:|
| lzo-rle | zero | 762 MB/s | 2612 MB/s | inf |
| lzo-rle | real | 311 MB/s | 1164 MB/s | 1.47 |
| lzo-rle | random | 395 MB/s | 1391 MB/s | 1.00 |
| lz4 | zero | 800 MB/s | 2723 MB/s | inf |
| lz4 | real | 290 MB/s | 1280 MB/s | 1.48 |
| lz4 | random | 427 MB/s | 667–1455 MB/s | 1.00 |
| zstd | zero | 800 MB/s | 1455 MB/s | inf |
| zstd | real | 130 MB/s | 409 MB/s | 1.72 |
| zstd | random | 241 MB/s | 1231 MB/s | 1.00 |

Conclusions:

- **lzo-rle and LZ4 are effectively tied** on this phone. LZO-RLE was slightly
  faster writing the real payload; LZ4 was slightly faster reading it; the
  compression ratios are identical within noise (1.47 vs 1.48).
- **zstd** gives a ~16% better ratio (1.72) but is ~2.4x slower to write and
  ~3x slower to read. Use it only if effective swap capacity matters more than
  latency.
- lzo-rle and LZ4 are tied within measurement noise; the drop-in now uses a
  fixed 3.5 GiB lzo-rle configuration. The stock config was lzo-rle, ram/2
  (2.7 GiB on this phone).

During the benchmark the live phone zram0 was 4 GiB LZ4. The drop-in now sets
3.5 GiB lzo-rle; a reboot applies it on the device.

## Done: Razer Kishi 180° screen orientation (picture and touch confirmed)

The panel DTS uses `rotation = <90>`, which mainline maps to `RIGHT_UP`
(gamescope auto = `right`/270). The correct 180° flip for the **Razer Kishi**
used on this phone is therefore **`left`/90**, not `right` and not
`upsidedown`.

The Kishi's USB-C connector holds the phone with its USB-C edge on the
controller side; in the default `right` orientation the picture is upside
down. The 180° flip fixes the picture for that controller. **This is not a
universal default.** With a Bluetooth controller, a different USB-C
controller, or no controller, use the unmodified `right` orientation: do not
install `99-orientation.conf` or `71-alioth-flip.rules`. The two files are a
pair; installing only one leaves either the picture or touch rotated 180°.

### Source files

```text
alioth-overlay/etc/systemd/user/gamescope-session.service.d/99-orientation.conf
alioth-overlay/usr/lib/udev/rules.d/71-alioth-flip.rules
```

`GAMESCOPE_ORIENTATION=left`.

Touch matrix for the flipped picture:

```text
LIBINPUT_CALIBRATION_MATRIX="0 -1 1 1 0 0"
```

The base rule `70-alioth.rules` still carries the unmodified orientation's
`0 1 0 -1 0 1`; the `71-` file overrides it only for the Razer Kishi flip.
Both files must be installed or removed together. The touch matrix must be
reloaded (`udevadm control --reload-rules`, `udevadm trigger --action=change
--subsystem-match=input`) and the gamescope session restarted, or the phone
rebooted, so libinput reopens the touchscreen.

### Status

- Picture orientation: **confirmed** by the user with `left` and a Razer Kishi.
- Touch: **confirmed** after installing `71-alioth-flip.rules`, reloading
  udev, and rebooting. The installed phone had only the base `70` matrix, so
  touch was 180° off until the pair was installed.
- Without a Razer Kishi: remove both files and keep the unmodified `right`
  orientation with `70-alioth.rules`; picture and touch are then both correct.
  This is the configuration to use with a Bluetooth controller, a different
  USB-C controller, or no controller.

## FPS limiter: root cause found upstream, fix not applied (2026-10-27)

The exact bug is in gamescope 3.16.30's non-VRR limiter path. It computes the
vblank divisor from `--nested-refresh` (60 in this session) while `vblank_idx`
counts the panel's real 120 Hz vblanks. A 30 FPS target becomes every second
vblank = 60 FPS; a 60 FPS target is not limited. That matches the A/B:

| `GAMESCOPE_FPS_LIMIT` | MangoHud average | GPU |
|---|---:|---:|
| 60 | 62.0 | 67.8% |
| 30 | 62.0 | 74.0% |

The earlier 29.9 was the intro/loading scene (GPU 16.7%), not a cap. The game
config is `MaxSmoothedFrameRate=62`; no game file is modified.

`hashtagbasit/SteamOS-ARM-Port` has the exact fix:

- `59136805b7254c0ce3ffa36c55ca5e0d68e89005` — divide by the real output
  refresh, not `--nested-refresh`.
- `f56b551b730b203210407cc2a2588dfa3cf50c04` — pace by elapsed time, not
  counted vblank wakeups; cap against the panel refresh.
- `96888ffe3fb0c7b17792a1b1b3d2218f6e3f9445` — the duplicate
  `systemctl --user import-environment` bug that kept Steam's gamescope flags
  away. This one is already fixed in our `gamescope-onready` source.

Their `external-and-mods/gamescope` source contains the two limiter patches.
This port still runs the stock gamescope 3.16.30 binary, so the fix is **not
applied**. The `vblank_mode=3` / `PROTON_ENABLE_WAYLAND=0` session candidates
are not the real fix and can be reverted. A patched gamescope must be built
and installed before claiming the FPS limiter works.

## Done: Wi-Fi after warm reboot (confirmed 2026-10-28)

Symptom: after a normal reboot, Steam shows no Wi-Fi adapter and it cannot be
enabled; a full shutdown and cold boot brings it back. This is **not** a PCIe
or QCA6390 failure.

The failed-boot journal shows the PCIe link and ath11k coming up normally:

```text
qcom-pcie 1c00000.pcie: PCIe Gen.2 x1 link up
ath11k_pci 0000:01:00.0: qca6390 hw2.0
ath11k_pci 0000:01:00.0: MAC_ADDR set to ...
```

But `NetworkManager` and `iwd` were inactive, and there was only:

```text
NetworkManager.service: Unit cannot be reloaded because it is inactive
```

The cold-boot journal has both services active and `wlan0` connected. The
warm-reboot failure is a userspace startup race after `steamos-manager`, not a
kernel/PCIe failure.

### Fix

`alioth-overlay/etc/systemd/system/alioth-wifi-recover.service` runs after
`steamos-manager.service` and starts `NetworkManager` and `iwd` if either is
inactive. It is enabled through `multi-user.target.wants/`.

Verified with a warm reboot:

```text
wlan0: connected: MIWIFI_AARG
NetworkManager: active
iwd: active
alioth-wifi-recover: active (exited)
```

## Done: suspend via power button (confirmed working)

### Source change

```text
alioth-overlay/etc/systemd/logind.conf.d/99-alioth-suspend.conf
alioth-overlay/etc/systemd/system/alioth-wifi-recover.service
alioth-overlay/etc/systemd/system/multi-user.target.wants/alioth-wifi-recover.service

[Login]
HandlePowerKey=suspend
```

The Frame image ships
`/etc/systemd/logind.conf.d/10-logind-no-powerbutton.conf` with
`HandlePowerKey=ignore`; the `99-` drop-in sorts later and overrides it.

Background:

- s2idle suspend is supported and was measured working with
  `rtcwake -m freeze` on this port.
- `steamos-powerbuttond` takes the key and sends `steam://powerpress`, which
  should open Steam's power menu, not suspend directly.
- With the Frame Steam menu unreliable, the button appeared dead.
- `10-logind-no-powerbutton.conf` made sure logind ignored it.

### Status: confirmed working on the phone

The user installed the `99-` drop-in manually, rebooted, and confirmed:

- pressing Power suspends immediately, without waiting for idle;
- pressing Power again wakes the phone;
- the idle-suspend path already worked before the change.

The source file is part of `alioth-overlay`, so the next
`make-steamos-alioth.sh --install` includes it built-in. No runtime-only file
is required after that.

### Verification commands

```sh
systemd-analyze cat-config systemd/logind.conf | grep -A2 -B2 HandlePowerKey
cat /sys/power/mem_sleep        # expect [s2idle]
journalctl -b -g 'PM: suspend|Restarting tasks'
```

If it ever regresses, check whether `steamos-powerbuttond` is consuming the
key:

```sh
systemctl --user status steamos-powerbuttond
journalctl --user -u steamos-powerbuttond -b
udevadm info /dev/input/event0 | grep STEAMOS_POWER_BUTTON
```

If the daemon is grabbing the key, mask it so logind receives it. In the
tested build it did not need masking.

Caveat: with USB attached, the USB gadget/ttyGS0 are wake sources and s2idle
may wake immediately. The confirmed suspend test was on battery.

## Charger boot / `androidboot.mode` (implemented)

Plugging in USB while the phone is off makes the bootloader add
`androidboot.mode=charger`. Without a hold, Linux boots all the way into
SteamOS and the phone cannot sit dark while charging.

`alioth-overlay` now ships the charger hold:

- `usr/lib/steamos-arm/tablet-charger-hold` reads `/proc/cmdline`,
  `/proc/bootconfig`, and
  `/sys/firmware/devicetree/base/chosen/bootargs`, looking for
  `androidboot.mode=charger` or `androidboot.mode=offmode_charging`;
- `usr/lib/systemd/system/steamos-arm-tablet-charger.service` runs before
  `display-manager.service`, is gated on `xiaomi,alioth`, and is enabled via
  `usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-charger.service`;
- the script blanks the backlights, quiets the kernel console, and shows a
  large battery/charge screen for 10 seconds on a short Power press at the
  panel's normal saved brightness. The `CHARGING` and
  `HOLD POWER TO START STEAMOS` labels use a 5x5 block font (five rows high,
  about 161 columns wide for the hold line);
- while held, CPU scaling_max_freq and the GPU min/max are clamped to the
  lowest available clocks (rechecked every 5 s); the original limits are
  restored on release, unplug, or display-manager start;
- holding Power for 1.5 seconds releases the hold and starts SteamOS;
- unplugging the charger powers off after 5 seconds;
- if a SteamOS session/display manager starts while the hold is still up, a
  watchdog restores the console/backlight and exits, so no Python process is
  left behind. The service itself is `Type=oneshot`, `RemainAfterExit=yes`;
  after a normal start there is no process and no RAM used.

`scripts/apply-alioth-overlay.sh` installs these files into the rootfs, so a
normal `make-steamos-alioth.sh --install` plus flash includes the feature.
`scripts/assert-alioth-overlay.py` checks the script, the alioth condition,
the enable link, and the watchdog.

Limits: this only applies to a charger-insertion boot. A warm reboot with the
charger attached does not carry `androidboot.mode=charger`, and the hold is a
dark pre-display-manager state, not true hardware-off charging.

### Check result (2026-10-27)

The previous boot's kernel command line in `journalctl -b -1 -k` contains:

```text
androidboot.mode=charger
```

The current (normal) boot does not carry it. To re-check:

```sh
tr ' ' '\n' < /proc/cmdline | grep -iE 'androidboot.mode|offmode'
cat /proc/bootconfig 2>/dev/null | grep -iE 'androidboot.mode|offmode'
```

## Dropped: battery temperature in MangoHud

Checked but not implemented. MangoHud in this image has no native
`battery_temp`; the no-build route is `exec=`, which runs a command on every
HUD update. That costs a process spawn per update. The user said no if it
costs performance, so the source was not changed.

Relevant facts if it is revisited:

- battery temp: `/sys/class/power_supply/battery/temp` in 0.1 °C;
- `gamescope-session` sets `MANGOHUD_CONFIGFILE` to the Steam-written preset,
  so `/etc/MangoHud.conf` and `~/.config/MangoHud/MangoHud.conf` are ignored
  while that variable is set;
- a working no-build route would need
  `MANGOHUD_CONFIG="read_cfg,exec=/path/to/battery-temp"` for alioth;
- a native MangoHud patch would be needed to avoid the per-update command.

## Test / assertion status at handoff

Run from the repo root:

```sh
python3 scripts/assert-alioth-overlay.py
scripts/assert-alioth-overlay-applied.sh
```

Both passed at the end of these changes. They cover:

- the `TdpLimit1` / `GpuPerformanceLevel1` back end and remotes, with no `PerformanceProfile1`;
- the orientation `left` drop-in and touch matrix;
- the FPS session candidates (`vblank_mode=3`, `PROTON_ENABLE_WAYLAND=0`) and
  the VRR-off source change; they do not yet cap the app;
- the 60-only Refresh Rate removal;
- the logind `HandlePowerKey=suspend` drop-in;
- the warm-reboot Wi-Fi recovery service and its enable link.

`python3 -m py_compile` on the changed Python files passed.
`git diff --check` passed.

Suspend, Razer Kishi touch orientation, and warm-reboot Wi-Fi recovery are
confirmed working. The FPS limiter is **not**; A/B showed 62 FPS at both
limits. Charger hold and the FPS limiter remain pending.

## Files changed (source)

The orientation/power/system code is committed in `31e0ca6`. The unproven FPS
session candidates and the documentation edits are uncommitted.

```text
alioth-overlay/README.md
alioth-overlay/etc/systemd/logind.conf.d/99-alioth-suspend.conf
alioth-overlay/etc/systemd/system/alioth-wifi-recover.service
alioth-overlay/etc/systemd/system/multi-user.target.wants/alioth-wifi-recover.service
alioth-overlay/etc/systemd/user/gamescope-session.service.d/99-orientation.conf
alioth-overlay/usr/lib/steamos-arm/steamos-arm-power
alioth-overlay/usr/lib/systemd/system/steamos-arm-power.service
alioth-overlay/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-power.service
alioth-overlay/usr/lib/udev/rules.d/71-alioth-flip.rules
alioth-overlay/usr/share/dbus-1/system.d/org.steamos_arm.Power.conf
alioth-overlay/usr/share/steamos-manager/remotes.d/50-steamos-arm.toml
steamos-overlay/usr/lib/steamos/gamescope-session    # VRR off, vblank_mode=3, PROTON_ENABLE_WAYLAND=0, no Refresh Rate
steamos-overlay/usr/lib/steamos/gamescope-onready    # clears stale STEAM_DISPLAY_REFRESH_LIMITS
steamos-overlay/usr/share/deckard/RUNSTEAM.sh         # handheld launcher, now installed
scripts/apply-alioth-devr.sh                          # install RUNSTEAM.sh
scripts/apply-alioth-overlay.sh                       # optional Kishi flip (ALIOTH_ORIENTATION_FLIP)
scripts/assert-alioth-overlay.py
scripts/assert-alioth-devr.sh                         # no -deckard/-vrgamepadui
alioth-overlay/usr/lib/steamos-arm/power_limits.py
alioth-overlay/usr/lib/steamos-arm/alioth-swapfile-setup
alioth-overlay/usr/lib/systemd/system/alioth-swapfile-setup.service
alioth-overlay/usr/lib/systemd/system/swapfile.swap
alioth-overlay/usr/share/steamos-manager/devices/xiaomi-alioth.toml
flash-alioth.sh                                      # English, migration prompt
make-steamos-alioth.sh                               # English, boot-migrate, SteamVR removal
alioth-overlay/usr/lib/steamos-arm/alioth-super-migrate
alioth-overlay/usr/lib/systemd/system/alioth-super-migrate.service
alioth-overlay/usr/lib/systemd/system/basic.target.wants/alioth-super-migrate.service
steamos-overlay/usr/lib/systemd/zram-generator.conf.d/60-steamos-arm-zram.conf
scripts/assert-alioth-flash.sh
scripts/assert-alioth-kit.sh
scripts/assert-alioth-overlay-applied.sh              # both Kishi flip modes
scripts/apply-alioth-desktop.sh                       # Desktop Mode session
scripts/assert-alioth-desktop.sh                      # Desktop Mode session checks
steamos-overlay/usr/lib/steamos/desktop-outputs       # Kishi-aware KWin transform
```

Untracked deployment artifacts (git-ignored under `work/`):

```text
work/alioth-power-ui.tar
work/alioth-power-ui-install.sh
work/host-tools/usr/bin/img2simg
work/host-tools/usr/bin/simg2img
work/host-tools/usr/bin/simg_dump
```

Do not commit the extracted firmware or the installed system's device-unique
identifiers. Do not claim the pending tests passed without measuring them.

## 2026-10-28: RAM reduction, zram source change, extra storage

### Source changes

- zram: `steamos-overlay/usr/lib/systemd/zram-generator.conf.d/60-steamos-arm-zram.conf`
  now sets `zram-size = 3584` (3584 MiB = 3.5 GiB) and
  `compression-algorithm = lzo-rle`. `scripts/assert-alioth-devr.sh` checks
  those values. The live phone still reports 4G lz4 because the image was not
  rebuilt/reflashed.
- Frame/SM8550 leftovers are masked in `scripts/apply-alioth-devr.sh`:
  `gpu-trace.service`, `iris-driver-rebind.service`,
  `steamos-log-submitter.service`. `steamos-manager.service` only `Wants=`
  the log submitter (weak, not `Requires=`); the `steamos_log_submitter`
  Python module and the GPU-reset/devcoredump udev hooks are kept, so only
  the idle daemon is removed.
- `steamos-log-submitter` automatic uploads are off. `gpu-trace`'s manual
  binary remains; only the daemon is stopped. `iris-driver-rebind` is
  SM8550/Iris-only; alioth is SM8250 and the condition path is absent.
- `/opt/steamvr` is deleted at build time. SteamVR units, `dsp_service`,
  `steamvr-plasma`, and `steamvr-web-debug-portforward` are masked.
- Opt-in extra storage: `make-steamos-alioth.sh` builds `boot-migrate.img`
  with `alioth.supermigrate=1`; `flash-alioth.sh --install` asks whether to
  use it, with an explicit warning that Android's system images are erased.
  On first boot `alioth-super-migrate` formats `super`, copies the Set B list
  (~4.5 GB), creates the 2 GiB swap file, writes fstab + bind mounts, and
  deletes the originals. It is one-time via `/var/lib/alioth-super-migrated`,
  idempotent, and swap is `/swapfile -> /var/lib/steamos-extra/swapfile`;
  the setup fails closed if the mount is missing.
- `flash-alioth.sh` and `make-steamos-alioth.sh` are fully English. The build
  uses `work/host-tools/usr/bin/img2simg`/`simg2img` when present so
  `userdata.img` is sparse.
- The Razer Kishi 180-degree flip is optional. `make --install` asks
  `Apply the Razer Kishi 180-degree render+touch flip? [Y/n]`; automation can
  set `ALIOTH_ORIENTATION_FLIP=0` (skip both files) or `1` (include both).
  `apply-alioth-overlay.sh` defaults to 1 for direct callers.
- Assertions/checks updated: `assert-alioth-flash.sh` covers the migration
  prompt; `assert-alioth-devr.sh` checks 31 masks; `assert-alioth-overlay.py`
  checks the migration/swap; `assert-alioth-kit.sh` checks masks,
  `boot-migrate.img`, and SteamVR absence.

### Live phone test (2026-10-28, 192.168.1.33)

Baseline: `MemTotal` 5548 MB, used 2122 MB, available 3425 MB; zram0 4G lz4;
`/swapfile` 2G; `gpu-trace` active ~25 MB RSS (110.4 MB peak),
`steamos-log-submitter` active ~42 MB RSS, `iris-driver-rebind` inactive.

Applied:

```sh
sudo systemctl mask --now gpu-trace.service iris-driver-rebind.service \
  steamos-log-submitter.service
```

Result: all three `inactive`/`masked`; `steamos-manager` still active; Steam
and gamescope still active; user session 0 failed units; used 2066 MB,
available 3481 MB (~+56 MB). No new failed units; `rauc.service` and
`usb-gadget.service` were already failed. Masks exist in
`/etc/systemd/system/` and `/var/lib/overlays/etc/upper/systemd/system/`, so
they should persist. No reboot was done. The Steam UI GPU-trace feature and
automatic Valve log uploads are off; manual `gpu-trace` and the udev hooks
remain.

Revert:

```sh
sudo systemctl unmask gpu-trace.service iris-driver-rebind.service \
  steamos-log-submitter.service
sudo systemctl start gpu-trace.service steamos-log-submitter.service
```

### Pending

- Rebuild: `ALIOTH_FW_DIR="$PWD/work/alioth-fw" ./make-steamos-alioth.sh --install`
  (needs sudo). The old kit predates zram 3.5 GiB/lzo-rle, SteamVR removal,
  the new masks, and `boot-migrate.img`.
- Flash with `./flash-alioth.sh --install`; answer the extra-storage prompt
  only if Android's system images may be erased.
- After reboot: confirm `zramctl` shows 3584 MiB/lzo-rle; confirm the three
  masks persist; run the assertion suite (kit/firstboot need sudo); play a
  game and watch `free -m`, `zramctl`, and `/proc/pressure/memory`.
- Non-root tests on 2026-10-28: `assert-alioth-flash.sh`,
  `assert-alioth-devr.sh`, `assert-alioth-overlay-applied.sh`, and
  `assert-alioth-overlay.py` pass. The overlay-applied test runs both the
  default orientation pair and `ALIOTH_ORIENTATION_FLIP=0` (both files
  skipped, base `70-alioth.rules` kept).

## Done: low-RAM per-game Steam mode (2026-10-28)

Confirmed on the phone with **Tomb Raider** (AppID 203160). This is a
per-game opt-in: only games with the marker in Steam's launch options unload
Steam's CEF helper. The mode is now part of `alioth-overlay`, so a normal
image build includes it.

Launch option:

```text
ALIOTH_UNLOAD_STEAMWEBHELPER=1 %command%
```

Mechanism:

- A user watcher scans `/proc/*/environ` for
  `ALIOTH_UNLOAD_STEAMWEBHELPER=1`.
- It waits **20 seconds** after the marked game starts. Three seconds was too
  early: the game exited while it was still initialising.
- It then backs up and replaces
  `~/.local/share/Steam/steamrtarm64/steamwebhelper.sh` with a dummy, and
  terminates the running `steamwebhelper` processes.
- When the marked game exits, it restores the original `steamwebhelper.sh`.
  Steam does not always recreate the helper by itself; the watcher waits two
  seconds and, if no helper appeared, runs
  `systemctl --user restart steam.service`.
- The Steam restart is what fixed the observed post-game freeze: without it,
  the Steam main process stayed alive with no CEF UI, leaving Game Mode
  frozen.

Measured with Tomb Raider:

- Normal helper state: `steamwebhelper` roughly 1.4-1.5 GB total RSS; free
  memory around 150-190 MB with the game running.
- With the helper unloaded: roughly 1.0-1.2 GB free; Tomb Raider continued
  running.
- The watcher itself uses about 12 MB RSS.

Important limitation: **Steam overlay and Quick Access/Performance tabs are
not available while the helper is unloaded.** The game still runs, but the
Steam UI, performance tab, and related overlay panels cannot be used in this
mode. This is acceptable only for games where the extra RAM matters more than
the overlay.

Source files:

```text
alioth-overlay/usr/lib/steamos-arm/alioth-steam-webhelper-offload
alioth-overlay/usr/lib/systemd/user/alioth-steam-webhelper-offload.service
alioth-overlay/etc/systemd/user/gamescope-session.target.d/99-zz-alioth-steam-webhelper-offload.conf
```

The marker is stored in `localconfig.vdf` per game; no game files are changed.
The user service starts with `gamescope-session.target`, waits 20 s, swaps
`steamwebhelper.sh` with a dummy, and unloads CEF. On game exit it restores
the wrapper and restarts `steam.service` if Steam did not recreate the helper.

`scripts/assert-alioth-overlay.py` checks the script, unit, target drop-in,
20 s delay, wrapper restore, and Steam recovery. `scripts/apply-alioth-overlay.sh`
installs all three files, and `make-steamos-alioth.sh --install` calls that
script.

Do not make it global. It remains per-game because the loss of Steam overlay
and Quick Access is a real trade-off, not a free improvement.

## 2026-10-28: Desktop Mode fix applied (source)

The upstream `hashtagbasit/SteamOS-ARM-Port` SD865/SM8250 image does not use
the Frame's `plasma.desktop -> start-gamescope-session plasma-session.target`.
It installs the generic Desktop Mode set from `steamos-overlay` and
`apply-overlays.sh`:

- `usr/share/wayland-sessions/plasma.desktop` -> `sm8550-startplasma`
- `sm8550-startplasma` -> `sm8550-prepare-plasma` + `desktop-outputs` +
  `desktop-fit` + `startplasma-wayland`
- `sm8550-prepare-plasma` clears `QT_QPA_PLATFORM=xcb`,
  `ENABLE_GAMESCOPE_WSI` and the other Game Mode variables; without it
  plasmashell dies and the panel stays black.
- `steamos-session-select` now calls `sm8550-prepare-plasma` before
  `steamosctl switch-to-desktop-mode`.
- `desktop-steam` redirects the Desktop Steam autostart; `desktop-fit`
  sizes the desktop for the panel; `desktop-portal-fix` starts after Plasma.
- `sm8550-plasma-env.service` and the `plasma-*` target/service drop-ins
  prepare the user manager.
- "Return to Gaming Mode" is installed as `/etc/skel/Desktop/Return.desktop`,
  copied to `~/Desktop` by the plasma-workspace env script, and also exposed
  as an application-menu entry. Its Exec tries `steamosctl`, then
  `steamos-session-select gamescope`, then a KDE logout.

The files were already present in `steamos-overlay` and were byte-identical
to upstream. The missing piece was installation: `scripts/apply-alioth-desktop.sh`
now installs them, backs up the Frame originals under
`/var/lib/steamos-arm-stock`, redirects `steam.desktop`, hides the X11
`plasmax11`/`openbox` sessions, and installs the legacy KWin layout.

Alioth adaptation: `desktop-outputs` now reads
`/etc/systemd/user/gamescope-session.service.d/99-orientation.conf`. When the
opt-in Razer Kishi flip is installed, it rotates the KWin transform 180
(`Rotated270` <-> `Rotated90`) so the picture agrees with the global
`71-alioth-flip.rules` touch matrix. Without the marker it uses the normal
panel orientation.

Touch needed a second fix: KWin does not read the udev matrix in Desktop
Mode; it reads its own `CalibrationMatrix` from `~/.config/kcminputrc`. With
the flipped picture the udev 270-degree matrix mirrored the 2400 axis, so
`desktop-outputs` now writes a KWin-only `CalibrationMatrix` for this panel:
identity (`1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1`) when the Kishi marker is
present, and the 180-degree counterpart
(`-1,0,1,0,0,-1,1,0,0,0,1,0,0,0,0,1`) without it. That follows the optional
orientation: KWin is Rotated90 with the flip and Rotated270 without it. An
existing user calibration is kept. The udev rule is unchanged, so Game Mode
touch is untouched.

Source files:

```text
scripts/apply-alioth-desktop.sh
scripts/assert-alioth-desktop.sh
steamos-overlay/usr/lib/steamos/desktop-outputs     # Kishi flip + touch calibration
steamos-overlay/etc/skel/Desktop/Return.desktop    # Return to Game Mode shortcut
steamos-overlay/etc/xdg/plasma-workspace/env/set-return-icon.sh
steamos-overlay/usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg
make-steamos-alioth.sh                             # calls apply-alioth-desktop.sh
scripts/assert-alioth-kit.sh                       # installed-image checks
```

### Live verification (2026-10-28, 192.168.1.33)

The working-tree files were deployed to the running phone and
`steamos-session-select plasma` was run. `sddm-helper` launched
`sm8550-startplasma`; `startplasma-wayland`, `kwin_wayland` and `plasmashell`
are running. `gamescope-session.service` is inactive;
`plasma-core/workspace/plasmashell` targets are active. Desktop Mode reaches
the Plasma workspace and the `desktop-steam` autostart starts Steam.

`~/.config/kwinoutputconfig.json` reports DSI-1 1080x2400@120,
`transform: "Rotated90"` (the Razer Kishi flip marker was present), and
`scale: 2`.

For the desktop-only touch correction, KWin's `CalibrationMatrix` was set to
identity (`1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1`) through its D-Bus property; KWin
persisted it in `~/.config/kcminputrc`. The user confirmed center and all four
directions are correct in Desktop Mode. The udev
`LIBINPUT_CALIBRATION_MATRIX` remains the Kishi matrix, so Game Mode is
unchanged.

The "Return to Gaming Mode" shortcut was deployed to `/etc/skel`, the
plasma-workspace env directory, and the running user's `~/Desktop`; the icon
is linked into the user's hicolor theme. It is clickable in Desktop Mode.

Non-fatal noise: `firewall-applet` lacks PyQt6/PyQt5; `desktop-steam` logs
XOpenIM/XRRGetOutputInfo warnings; `udisksd` emits two
`g_variant_ref_sink` assertions. None of them stopped Plasma or Steam.

### Pending

- Rebuild/flash so the source changes are in the install image; the live
  phone currently has the files copied in, not a rebuilt userdata image.
- The Razer Kishi Desktop touch is confirmed correct. Check the no-flip
  Desktop path too: the source expects the 180-degree `BASE_TOUCH_MATRIX`
  when `99-orientation.conf` is absent. Game Mode continues to use the udev
  `70`/`71` matrices.
- `desktop-fit` chose scale 2.0 (logical 1200x540) and 120 Hz on this panel;
  change in System Settings if it is too large or too power-hungry.
- Plasma extras such as `plasma-nm`, `kscreen` and the touch keyboard may
  still be missing; they affect Desktop settings, not the session start.

## Pending investigation: volume buttons as volume + power chords

User request: volume up/down should change volume normally; Steam menu and
Quick Access/recents should open only when volume is held with Power. Today
volume up/down map directly to `Guide`/`QuickAccess` and the power button is
not an InputPlumber source.

Findings:

- `alioth-overlay/etc/inputplumber/devices.d/02-xiaomi-alioth.yaml` claims two
  separate evdev devices: `gpio-keys` (volume up) and `pm8941_resin` (volume
  down). It deliberately does not claim `pm8941_pwrkey`.
- `alioth-overlay/etc/inputplumber/capability_maps.d/alioth_keys.yaml` maps
  volume up -> `Gamepad:Button:Guide`, volume down ->
  `Gamepad:Button:QuickAccess`.
- InputPlumber supports `evdev: chord` / `delayed_chord` mappings, but the
  chord translator is **per source device** (`EventTranslator` in
  InputPlumber's `src/input/event/evdev/translator.rs`). The existing chord
  examples put all keys on one keyboard/evdev device. Volume up, volume down
  and power are on three different evdev devices, so a config-only
  volume+power chord is not expected to match.
- InputPlumber does expose a D-Bus
  `org.shadowblip.Input.CompositeDevice.SendButtonChord` method taking
  capability strings such as `"Gamepad:Button:Guide"`; a custom daemon could
  use that to inject the menus. The polkit rule allows `wheel`
  (`steamos` is in wheel).
- A user-space daemon would have to grab the three physical devices to own
  them. That conflicts with InputPlumber, which grabs its sources, and with
  `steamos-powerbuttond`/logind for the power key. The volume sources would
  have to be removed from the alioth InputPlumber profile; then the
  `deck-uhid` target for the built-in device may disappear, so a dummy source
  or another way to keep a target alive is needed.
- Volume alone can be done with `wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+/-`
  as `steamos`; this will not necessarily show Steam's volume OSD.
- A merged virtual evdev device (uinput) fed into InputPlumber would make the
  chord a same-source mapping, but requires the same custom daemon and a new
  InputPlumber source/profile.

Feasible design if implemented later:

1. A `steamos` user systemd input daemon with `uaccess` udev rules for
   `gpio-keys`, `pm8941_resin`, and `pm8941_pwrkey`.
2. Remove the two volume keys from the alioth InputPlumber composite (or keep
   a dummy source so the deck target still exists).
3. Daemon behavior:
   - volume alone -> `wpctl` volume step;
   - Power+VolumeUp -> `SendButtonChord` with `Gamepad:Button:Guide`;
   - Power+VolumeDown -> `SendButtonChord` with
     `Gamepad:Button:QuickAccess`;
   - Power alone -> suspend (or Steam power menu), decided by the user.
4. Chord window and key-repeat handling; power must not suspend when it is
   part of a chord.
5. Test on device: `busctl tree org.shadowblip.InputPlumber`, the
   `SendButtonChord` call, `wpctl status`, `/proc/bus/input/devices`, and the
   actual Steam menu/QAM behavior.

This is not implemented. It is a custom input daemon, not an InputPlumber
config-only change.
