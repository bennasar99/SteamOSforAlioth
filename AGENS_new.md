# AGENS_new — alioth handoff: changes done and tests pending

Date: 2026-10-27
Repo: `/home/toni/dev/SteamOSforAlioth`
Device: POCO F3 / Redmi K40 (`alioth`, 6 GB / 128 GB), postmarketOS replaced by SteamOS ARM.

This file records what was changed in the source tree, what is only in the
installed system, and what still has to be tested on the phone. It is not a
claim that any pending item works.

## Hard rules still apply

- Never write `abl_a` / `abl_b`, `super`, or `vbmeta`.
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
  `RUNSTEAM.sh`, the logind suspend drop-in, the 4 GiB LZ4 zram drop-in, the
  2 GiB `/swapfile`, and the Refresh Rate removal. Profiles were removed from
  the service/remotes and are gone from the running UI; TDP and suspend are
  confirmed working.
- The installed phone still does **not** limit FPS; the handheld launcher made
  the Performance page and TDP work but did not make the FPS limiter work.
- The source tree now installs the handheld `RUNSTEAM.sh` through
  `apply-alioth-devr.sh`, carries the full power UI, the VRR-off/FPS-limiter
  patch, and the logind suspend drop-in; this is what the next build will use.
- Rebuilding/reflashing, or copying the files again, is required to make the
  installed system match the source exactly.
- The installed phone now has **4 GiB zram with LZ4** plus a **2 GiB
  `/swapfile`** (priority 50; zram priority 100). The stock 2.7 GB `ram/2`
  lzo-rle value was a likely factor in the memory-pressure session crashes.
- The installed phone now also has the **Razer Kishi** orientation pair
  (`99-orientation.conf` + `71-alioth-flip.rules`); picture and touch are
  confirmed correct. Without a Razer Kishi, remove both and keep the
  unmodified orientation.

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
problem, not a TDP or kernel regression. The zram drop-in is now installed;
zram is 4 GiB LZ4 (see benchmark below).

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
- LZ4 remains the current 4 GiB choice; there is no measured reason to switch
  to lzo-rle. The stock config was lzo-rle, ram/2 (2.7 GiB on this phone).

The live phone zram0 is 4 GiB LZ4, and the drop-in has the same values. A reboot
is not required for the live device; the drop-in is authoritative on next boot.

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

## Failed / unverified: FPS limiter

Symptom: Steam's **Framerate Limit** does not appear to do anything.

### Source change made

In `steamos-overlay/usr/lib/steamos/gamescope-session`:

```text
STEAM_GAMESCOPE_VRR_SUPPORTED=0
```

and `--adaptive-sync` was removed from `GAMESCOPE_ARGS`.

`STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER=1` is still set.

Reason: the panel is a fixed 60 Hz DSI panel with no VRR. Advertising VRR puts
Steam on the variable-refresh limiter path; the frame limit may then be a
no-op on this panel. `assert-alioth-overlay.py` now asserts this as
`FPS limiter 不走 VRR`; the assertion passes.

### Root cause found (2026-10-27): the Frame Steam launcher

The installed Steam process runs with:

```text
steam -cef-enable-debugging -deckard -gamepadui -steamdeck -steamos3 -vrgamepadui
```

That is the **Frame** launcher. Gamescope's frame limiter explicitly exempts
windows that carry a VR overlay target:

```cpp
// gamescope src/steamcompmgr.cpp
if ( w->isSteamStreamingClientVideo ) return false;
return window_is_steam( w ) || w->oulTargetVROverlay.has_value() ||
       w->isOverlay || w->isExternalOverlay || window_is_vr_scene_app( w );
```

The repo already carries a handheld launcher at
`steamos-overlay/usr/share/deckard/RUNSTEAM.sh`. Its header says:

```text
Do not pass -deckard / -vrgamepadui: those switch the client beta to the
internal Steam Frame build and wait on SteamVR.
```

`apply-alioth-devr.sh` did not install it, so the phone kept the Frame
launcher. The source now installs it and `assert-alioth-devr.sh` asserts that
`STEAM_ARGS` does not contain `-deckard` or `-vrgamepadui`.

The manual atom test is consistent with this: setting
`GAMESCOPE_FPS_LIMIT=30` on `:0` and on the game's `:1` did not drop the game
FPS, because the game window is exempt rather than because the atom is missing.

### Status after installing the handheld launcher: FPS still does not work

The user installed the handheld `RUNSTEAM.sh` and restarted Steam. The result:

- more Performance-tab options appeared;
- the TDP limiter works;
- the FPS limiter still does not work;
- the meaningless Refresh Rate option was removed from the source (60-only
  panel, `STEAM_DISPLAY_REFRESH_LIMITS` unset).

So the Frame launcher was necessary for the Performance UI and TDP, but it was
not sufficient for the FPS limiter. The remaining FPS causes are not yet
identified. Do not claim the FPS limiter is fixed.

Possible next directions (not yet tested):

- `DXVK_FRAME_RATE=30` in the game's Steam launch options; this caps DXVK
  presents and is independent of gamescope's limiter.
- MangoHud `fps_limit=30` through the active `MANGOHUD_CONFIG`/`MANGOHUD_CONFIGFILE`.
- A nested per-game `gamescope --framerate-limit 30`.
- `libstrangle`/an LD_PRELOAD limiter for OpenGL/Vulkan titles.

### Pending tests

1. Confirm the patch is in the installed session and reboot:

   ```sh
   grep -n 'VRR_SUPPORTED\|adaptive-sync' /usr/lib/steamos/gamescope-session
   ```

   Expect `VRR_SUPPORTED=0` and no `--adaptive-sync` argument.

2. Use **Framerate Limit**, not **Refresh Rate**. The panel is fixed 60 Hz, so
   the refresh-rate slider cannot change anything.

3. Test gamescope's limiter directly from a Konsole launched inside Game Mode
   (SSH has no display):

   ```sh
   xprop -root -f GAMESCOPE_FPS_LIMIT 32c -set GAMESCOPE_FPS_LIMIT 30
   xprop -root GAMESCOPE_FPS_LIMIT
   ```

   Over SSH, first find Steam's environment and use
   `DISPLAY=:0 XAUTHORITY=<path>`.

4. Check that Steam received the limiter environment:

   ```sh
   systemctl --user show-environment | grep -E 'STEAM_GAMESCOPE|GAMESCOPE_LIMITER'
   cat /run/user/1000/gamescope-steam.env | grep -E 'STEAM_GAMESCOPE|GAMESCOPE_LIMITER'
   ```

   `STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER=1` and
   `GAMESCOPE_LIMITER_FILE=...` must be present.

5. Interpret:

   - manual `GAMESCOPE_FPS_LIMIT=30` drops the game to 30 but the Steam slider
     does nothing: gamescope works; the Frame Steam client UI is not applying
     the limiter. This is the same class of UI limitation as the missing
     profile selector.
   - manual atom also does nothing: the limiter path is broken or the game
     window is exempt. Record the game type and `xprop` output before changing
     more code.

Do not describe the FPS limiter as fixed until step 3 or 4 produces evidence.

## Done: suspend via power button (confirmed working)

### Source change

```text
alioth-overlay/etc/systemd/logind.conf.d/99-alioth-suspend.conf

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

## Pending: charger boot / `androidboot.mode`

Symptom: plugging in USB while the phone is off boots straight into SteamOS
instead of staying dark and charging.

This is bootloader behavior, not something the kernel can simply turn off.
The repo already has `steamos-overlay/usr/lib/steamos-arm/tablet-charger-hold`
for Lenovo tablets. It:

- checks `/proc/cmdline`, `/proc/bootconfig`, and
  `/sys/firmware/devicetree/base/chosen/bootargs` for
  `androidboot.mode=charger` or `androidboot.mode=offmode_charging`;
- holds before `display-manager`, dims the panel, and charges;
- starts SteamOS when Power is held for one second;
- powers off when the charger is removed.

It is not enabled for alioth (`ConditionFirmware` lists only Lenovo devices),
and the script is not installed in the alioth rootfs.

### Check result (2026-10-27)

The previous boot's kernel command line in `journalctl -b -1 -k` contains:

```text
androidboot.mode=charger
```

So the flag is present on a charger-insertion boot; the dark charger-hold
feature is implementable. The current (normal) boot does not carry it.

### How to re-check

Boot the phone with the charger and inspect the bootloader arguments:

```sh
tr ' ' '\n' < /proc/cmdline | grep -iE 'androidboot.mode|offmode'
cat /proc/bootconfig 2>/dev/null | grep -iE 'androidboot.mode|offmode'
```

- If `androidboot.mode=charger` or `offmode_charging` is present, adapt the
  charger-hold script/service for `xiaomi,alioth`. It needs to run before
  `display-manager.service`, and must grab the power key (or otherwise avoid a
  conflict with `HandlePowerKey=suspend`) while it is in charger mode.
- If neither argument is present, there is no reliable way to tell a
  charger-insertion boot from a normal boot that already has a charger
  connected. In that case do not promise a dark charging mode; the phone will
  keep booting SteamOS.

Record the exact command-line/bootconfig output in this file before changing
the source.

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
- the FPS VRR-off source change;
- the 60-only Refresh Rate removal;
- the logind `HandlePowerKey=suspend` drop-in.

`python3 -m py_compile` on the changed Python files passed.
`git diff --check` passed.

Suspend via the power button and Razer Kishi touch orientation are now
confirmed working on the phone and are built into the source. No on-device
test has proved the FPS limiter or charger hold; those remain the pending
items above.

## Files changed (source)

The orientation/power/system code is committed in `31e0ca6`. The documentation
edits in this file and the READMEs are uncommitted at handoff.

```text
alioth-overlay/README.md
alioth-overlay/etc/systemd/logind.conf.d/99-alioth-suspend.conf
alioth-overlay/etc/systemd/user/gamescope-session.service.d/99-orientation.conf
alioth-overlay/usr/lib/steamos-arm/steamos-arm-power
alioth-overlay/usr/lib/systemd/system/steamos-arm-power.service
alioth-overlay/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-power.service
alioth-overlay/usr/lib/udev/rules.d/71-alioth-flip.rules
alioth-overlay/usr/share/dbus-1/system.d/org.steamos_arm.Power.conf
alioth-overlay/usr/share/steamos-manager/remotes.d/50-steamos-arm.toml
steamos-overlay/usr/lib/steamos/gamescope-session    # VRR off, no --adaptive-sync, no Refresh Rate
steamos-overlay/usr/lib/steamos/gamescope-onready    # clears stale STEAM_DISPLAY_REFRESH_LIMITS
steamos-overlay/usr/share/deckard/RUNSTEAM.sh         # handheld launcher, now installed
scripts/apply-alioth-devr.sh                          # install RUNSTEAM.sh
scripts/assert-alioth-overlay.py
scripts/assert-alioth-devr.sh                         # no -deckard/-vrgamepadui
alioth-overlay/usr/lib/steamos-arm/power_limits.py
alioth-overlay/usr/lib/steamos-arm/alioth-swapfile-setup
alioth-overlay/usr/lib/systemd/system/alioth-swapfile-setup.service
alioth-overlay/usr/lib/systemd/system/swapfile.swap
alioth-overlay/usr/share/steamos-manager/devices/xiaomi-alioth.toml
```

Untracked deployment artifacts (git-ignored under `work/`):

```text
work/alioth-power-ui.tar
work/alioth-power-ui-install.sh
```

Do not commit the extracted firmware or the installed system's device-unique
identifiers. Do not claim the pending tests passed without measuring them.

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
