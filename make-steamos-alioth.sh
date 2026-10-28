#!/usr/bin/env bash
# Build the boot image for alioth (Xiaomi Redmi K40 / POCO F3).
#
# Phase 1 has no rootfs at all, so --kernel-only is the only mode and what
# it makes is a debug image: work/steamos-alioth/boot-debug.img, holding the
# kernel, the single alioth DTB and the initramfs that is built into the
# Image (EMBED_INITRAMFS=1 in kernel-sm8250/soc.env).
#
# This does not reuse the kit's own boot/KERNEL, which is packed for the
# ROCKNIX ABL. Xiaomi's ABL is a different bootloader and gets the page size
# and load addresses that a boot image is actually known to have booted on
# this device with -- see PAGESIZE below.
#
# Flash it with ./flash-alioth.sh --test.
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer tools bundled under work/host-tools when present (dtc, img2simg,
# simg2img). Keeping img2simg here is what makes userdata.img sparse, which is
# what fastboot can flash within the device's 768 MiB download limit.
HOST_TOOLS="${STEAMOS_WORK:-${PORT_ROOT}/work}/host-tools/usr/bin"
if [[ -d "$HOST_TOOLS" ]]; then
  PATH="${HOST_TOOLS}:$PATH"
fi
KCOMMON="${PORT_ROOT}/external-and-mods/kernel-common"
SOC_DIR="${PORT_ROOT}/external-and-mods/kernel-sm8250"
DTB=sm8250-xiaomi-alioth

KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}" 2>/dev/null || true)"
OUT="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-alioth"

die() { echo "make-steamos-alioth: $*" >&2; exit 1; }

MODE="${1:-}"
shift || true
SKIP_COPY=0
SRC_ROOTFS="${STEAMOS_SRC_ROOTFS:-${STEAMOS_WORK:-${PORT_ROOT}/work}/rootfs}"
R="${STEAMOS_ROOTFS:-${STEAMOS_WORK:-${PORT_ROOT}/work}/rootfs-alioth}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-copy)    SKIP_COPY=1 ;;
    --from-rootfs)  SRC_ROOTFS="$2"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
case "$MODE" in
  --kernel-only|--install) ;;
  *) die "usage: $0 --kernel-only | --install [--from-rootfs DIR] [--skip-copy]" ;;
esac

# --install must not build without device-signed firmware.
#
# The 2026-10-24 review pointed out the asymmetry: the boot-image rules are
# wired into the write path (flash-alioth.sh runs
# assert-alioth-boot-image.sh before any write), while "is the firmware the
# phone's own signed copy?" relied on memory -- this script used to print
# four `!!` lines and keep going, still producing a complete 9 GB kit. What
# follows is: rsync runs for ten minutes, the warning scrolls off,
# `flash-alioth.sh --install` runs, the operator types ERASE, Android's /data
# is gone, and the installed system is a black screen with no sound because
# Xiaomi's TrustZone rejects linux-firmware's generically signed a650_zap.mbn.
# Recovering the firmware then requires an Android that has already been
# erased.
#
# So this check is first: before rsync, before anything slow. To build a test
# image that you know has no GPU and no sound, set ALIOTH_FW_GENERIC_OK=1 --
# it leaves a GENERIC-FIRMWARE marker in the kit, and flash-alioth.sh
# --install refuses that marker too (two opt-ins, and the artifact carries its
# own provenance).
if [[ "$MODE" == --install && "${ALIOTH_FW_GENERIC_OK:-}" != 1 ]]; then
  [[ -n "${ALIOTH_FW_DIR:-}" ]] \
    || die "--install requires ALIOTH_FW_DIR -- without device-signed firmware
     the installed system is a black screen with no sound. First run
     scripts/extract-alioth-firmware.sh (see its header) to pull this phone's
     own a650_zap.mbn and adsp.mbn, then rerun with
     ALIOTH_FW_DIR=<output-dir>. To deliberately build a test image with no
     GPU and no sound: ALIOTH_FW_GENERIC_OK=1"
  [[ -d "${ALIOTH_FW_DIR}" ]] \
    || die "ALIOTH_FW_DIR=${ALIOTH_FW_DIR} is not a directory"
fi

# Xiaomi's ABL. These are pmaports' deviceinfo values for this device
# (flash_pagesize 4096, offset_base 0 + kernel 0x8000 / ramdisk 0x1000000 /
# tags 0x100), which is the only set a boot image is known to have booted
# with here -- the kit's defaults (2048, 0x10000000) are the ROCKNIX ABL's.
# ABL relocates either way: its UART log puts RAM at 0x80000000, above all
# of these addresses. There is still no reason to deviate from the proven
# values on the one image we cannot test cheaply.
PAGESIZE=4096
KERNEL_ADDR=0x00008000
RAMDISK_ADDR=0x01000000
TAGS_ADDR=0x00000100
# second_size is 0, so nothing is loaded here -- but the whole point of the
# four values above is to not deviate from the set this phone is known to
# have started with, and mkbootimg-v0.py's own default is the ROCKNIX base.
SECOND_ADDR=0x00F00000

img="${KOUT}/boot/Image"
dtb="${KOUT}/dtbs/${DTB}.dtb"
[[ -n "$KOUT" && -d "$KOUT" ]] || die "no kernel output directory (KERNEL_OUT=${KERNEL_OUT:-default})"
[[ -s "$img" ]] || die "missing $img -- kernel-sm8250/soc.env needs KEEP_IMAGE=1"
[[ -s "$dtb" ]] || die "missing $dtb -- soc.env DTBS must contain $DTB"

mkdir -p "$OUT"

# The payload ABL gets: a gzip stream, with the DTB appended after it.
#
# gzip is what this bootloader is known to take: pmaports' APKBUILD installs
# the kernel with `make zinstall` (i.e. Image.gz) and sets append_dtb, and
# ABL's own log then reports `Best match DTB tags 356/0000002C/...` -- 0x2C
# is 44, alioth's qcom,board-id. Note this gzips the raw Image, never the
# kernel's own Image.gz: with CONFIG_EFI_ZBOOT=y (which this config has)
# that file is an EFI PE wrapper, not a gzip stream, and a bootloader
# without EFI never unpacks it. That is the one bug pmaports' README calls
# "THE IMPOSTOR".
#
# Only alioth's DTB goes in. The kit's 11-DTB KERNEL would also match
# correctly -- board-id <44 0> is unique among them -- but there is no
# reason to hand this bootloader ten other boards' device trees.
pack_boot() {   # pack_boot <output-file> [extra cmdline token]
local extra="${2:-}"
payload="${OUT}/payload.gz"
gzip -9 -n -c "$img" >"$payload"
cat "$dtb" >>"$payload"

# CMDLINE_QUIET=0: the console on the panel is one of the only two log
# channels in phase 1, and the default cmdline's `quiet loglevel=0` would
# silence exactly that.
# No fbcon=rotate: the panel driver now reports its rotation = <270> to DRM
# (.get_orientation), and DRM's fbdev emulation already turns the console
# by itself. A fbcon=rotate on top of that composes with it, and which way
# up the result lands is not something that can be settled away from the
# device -- on the one channel phase 1 depends on, guessing is the wrong
# trade. Reading a boot log on a phone held upright is fine; landscape is
# Game Mode's requirement, i.e. phase 2's.
# steamos.bootlabel= is set to a GPT name that cannot exist here. Left at
# its default the initramfs looks for a partition called ROCKNIX and, if it
# found one, would mount it read-write and write a boot log into it. No
# alioth partition carries that name, so today nothing is written -- but
# "no writes" is a hard constraint, and this turns it from a coincidence
# into a guarantee.
# steamos.usbshell=1 is the single switch that starts the USB gadget shell
# (ACM serial + a root shell on 172.16.42.1:23) -- initramfs/init does
# nothing of the sort without it, and that is the other log channel. The
# network half is nc, not telnetd: this busybox has no telnetd applet, so
# every image before this one answered RST on port 23.
# ft8756.poll= is gone: the probe-time power cycle (patch 0024) fixed the
# chip, the ID check now passes on its own and IRQ 152 counted 7398
# interrupts on the last boot, so the 20Hz poll fallback is pure overhead.
# ft8756.ignore_id=1 stays as a one-line safety net -- it still logs
# "unknown chip id, continuing" when the ID read fails, so a regression is
# visible either way, and a warning plus a working panel beats no touch.
# panic=120: CONFIG_PANIC_TIMEOUT=0 in this config, so a panicking kernel
# hangs forever. That is the worst possible behaviour for the crash-log
# channel this image depends on -- pstore writes the record on panic, but
# the only way out of the hang is a long press on power, which is exactly
# the reset that does not preserve DRAM, so the record is destroyed before
# it can be read. Any non-zero value fixes that: the kernel reboots warm,
# DRAM survives, and the record is there to read on the next boot.
#
# 120s rather than a few seconds, because a reproducible panic at boot
# turns this into a loop, and every iteration spends one A/B boot attempt
# -- this port never marks a slot successful, so once they run out the
# bootloader marks the slot unbootable and falls back to the other one,
# which carries stock Android (slot b is never written here). At 120s
# that takes about a quarter of an hour and the panic sits on the panel
# the whole time, which is room to hold volume-down + power and go to
# fastboot instead. At 10s it would be over in a minute.
# No sysrq_always_enabled here, and the reason is worth writing down
# because it reads the other way at first glance: sysrq is ALREADY fully
# enabled. CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1 looks like a bitmask
# allowing only loglevel control (SYSRQ_ENABLE_LOG), but sysrq_on_mask()
# is `sysrq_always_enabled || sysrq_enabled == 1 || (sysrq_enabled & mask)`
# -- the value 1 is special-cased to mean every function, and the bitmask
# reading only applies above 1. So reboot and crash work as shipped.
#
# That matters because it is the escape hatch when userspace wedges, which
# is not hypothetical: the debug shell and the network listener both died
# across a host-mode test and left no way into a live kernel. It is reachable
# from the panel only -- u_serial.c has no sysrq handling at all, so the ACM
# console cannot deliver one -- but CONFIG_VT=y, VT_CONSOLE=y and a USB-C
# keyboard enumerating in host mode make Alt+SysRq+B a warm reboot that
# keeps DRAM.
# steamos.root= is used rather than relying on root=, because this ABL
# appends its own arguments after ours and init takes the last root= it
# sees; steamos.root= always wins over root= (initramfs/init).
# PARTLABEL=userdata is a partition that exists but holds Android's
# encrypted f2fs, so init resolves it at once and the ext4 mount then fails
# on the read-only superblock probe, without writing anything, and drops to
# a shell. That failure IS the expected phase-1 outcome.
# initcall_blacklist=simpledrm_platform_driver_init: lets msm get DRM minor 0.
#
# The image's MangoHud hardcodes the GPU-usage source path as
# /sys/kernel/debug/dri/0/perf_now (upstream master now walks
# /sys/class/drm/<node>/device/drm to find card*, but this version does not).
# On this phone card0 does not exist: simpledrm registers for
# /chosen/framebuffer early and takes minor 0; after msm takes over via the
# aperture simpledrm leaves, but the minor number is not recycled -- so msm
# lands on dri/1, MangoHud reads a nonexistent file, and the panel always
# shows 0. On the Frame msm is card0, which is why Valve could hardcode it.
#
# CONFIG_DRM_SIMPLEDRM remains y in the config; the mask is only at the
# cmdline layer -- removing this token restores everything. The cost is
# losing the framebuffer console for the few seconds before msm binds (the
# channel phase 1 depends on). After msm binds, fbcon goes through
# CONFIG_DRM_MSM_KMS_FBDEV and the console on the panel is unchanged. To
# really debug early boot, remove this token and rebuild.
cmdline="$(
  CMDLINE_QUIET=0 \
  KERNEL_CMDLINE_EXTRA="ft8756.ignore_id=1 panic=120 steamos.usbshell=1 steamos.root=PARTLABEL=userdata steamos.bootlabel=steamos-arm-no-boot-partition initcall_blacklist=simpledrm_platform_driver_init" \
  bash -c "source '${SOC_DIR}/soc.env'; source '${KCOMMON}/cmdline.sh'; build_cmdline PARTLABEL=userdata"
)"
# boot-migrate.img carries this token so the first-boot migration service
# knows the operator opted into putting static SteamOS data on the Android
# system partition. The normal boot.img has no token.
if [[ -n "$extra" ]]; then
  cmdline="$cmdline $extra"
fi

# No --ramdisk: EMBED_INITRAMFS=1 puts the initramfs inside the Image, and
# mkbootimg-v0.py then writes the same dummy ramdisk ROCKNIX does.
# Reproducible: without SOURCE_DATE_EPOCH the header's os_version carries
# today's date, so an unchanged kernel yields a different image and a
# different checksum tomorrow -- which also makes SHA256SUMS useless for
# telling two builds apart. The Image's own mtime makes the output a
# function of its input.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -c %Y "$img")}"

python3 "${KCOMMON}/mkbootimg-v0.py" \
  --kernel "$payload" \
  --cmdline "$cmdline" \
  --pagesize "$PAGESIZE" \
  --kernel-addr "$KERNEL_ADDR" \
  --ramdisk-addr "$RAMDISK_ADDR" \
  --tags-addr "$TAGS_ADDR" \
  --second-addr "$SECOND_ADDR" \
  --out "${OUT}/$1"
rm -f "$payload"
echo "cmdline: $cmdline"
}

# SHA256SUMS covers every image currently in OUT. Both modes share this
# directory, and flash-alioth.sh runs `sha256sum -c` on it -- writing only
# this mode's image would make the other mode's image disappear from the
# check.
sums() { (cd "$OUT" && sha256sum ./*.img >SHA256SUMS); }

if [[ "$MODE" == --kernel-only ]]; then
  pack_boot boot-debug.img
  sums
  echo "kernel:  $(basename "$KOUT") ($(readlink -f "$KOUT"))"
  ls -l "${OUT}/boot-debug.img"
  echo
  echo "flash: ./flash-alioth.sh --test"
  exit 0
fi

# ---------------------------------------------------------------------------
# --install: full system image
#
# This does not call upstream scripts/apply-overlays.sh (this repository no
# longer carries it, see below). That script requires a compiled gamescope
# (it dies at line 37), while alioth uses Valve's rootfs unchanged per spec
# §4 -- its gamescope, Steam, FEX, Turnip and InputPlumber are already
# present. There is no reason to compile a replacement just to satisfy a
# prerequisite check. This is exactly what REDMAGIC 6 does:
# make-steamos-sm8350.sh calls apply-overlays-sm8350.sh at line 177 and also
# avoids the big script.
#
# So this mode does the three things apply-overlays-sm8350.sh does:
#   1. kernel modules + firmware
#   2. sm8250-overlay (mainly steamos-powerbuttond.service -- spec §7.1 names
#      it; the Frame's own unit depends on SteamVR)
#   3. alioth-overlay (scripts/apply-alioth-overlay.sh)
# ---------------------------------------------------------------------------

KREL="$(basename "$KOUT")"
KIT="$OUT"
S8250_OVL="${PORT_ROOT}/sm8250-overlay"

for c in rsync mkfs.ext4 losetup uuidgen; do
  command -v "$c" >/dev/null || die "missing $c"
done
[[ -d "$KOUT/modules/$KREL" ]] || die "missing $KOUT/modules/$KREL"
[[ -d "$KOUT/firmware" ]] || die "missing $KOUT/firmware"

# The Razer Kishi needs a paired 180-degree flip of both render and touch.
# It is optional: the base orientation is correct for Bluetooth/other USB-C
# controllers or no controller. Ask before the long rootfs copy; automation
# can set ALIOTH_ORIENTATION_FLIP=0/1 instead.
if [[ -n "${ALIOTH_ORIENTATION_FLIP:-}" ]]; then
  case "$ALIOTH_ORIENTATION_FLIP" in
    0|1) ORIENTATION_FLIP="$ALIOTH_ORIENTATION_FLIP" ;;
    *) die "ALIOTH_ORIENTATION_FLIP must be 0 or 1, got '$ALIOTH_ORIENTATION_FLIP'" ;;
  esac
elif [[ -t 0 ]]; then
  printf 'Apply the Razer Kishi 180-degree render+touch flip? [Y/n] '
  read -r answer || answer=""
  case "$answer" in
    n|N|no|NO) ORIENTATION_FLIP=0 ;;
    *) ORIENTATION_FLIP=1 ;;
  esac
else
  ORIENTATION_FLIP=1
  echo "!! no terminal for the orientation prompt; defaulting to the Razer Kishi flip (set ALIOTH_ORIENTATION_FLIP=0 or 1 to choose)"
fi
echo "==> Razer Kishi orientation flip: $([[ "$ORIENTATION_FLIP" == 1 ]] && echo enabled || echo disabled)"

# 1. Copy the shared rootfs. The source is never modified -- the next build
#    starts from the same clean tree.
if [[ "$SKIP_COPY" -eq 1 ]]; then
  [[ -x "$R/usr/bin/bash" ]] || die "--skip-copy but $R has no rootfs"
  echo "==> skipping copy; reusing $R"
else
  [[ -x "${SRC_ROOTFS}/usr/bin/bash" ]] \
    || die "no source rootfs ${SRC_ROOTFS} -- run scripts/fetch-steamos-rootfs.sh first"
  [[ "$(readlink -f "$SRC_ROOTFS")" != "$(readlink -f "$R")" ]] \
    || die "source and destination must differ (this mode modifies the destination)"
  echo "==> copying rootfs ${SRC_ROOTFS} -> ${R}"
  sudo mkdir -p "$R"
  sudo rsync -aHAX --numeric-ids --delete "${SRC_ROOTFS}/" "${R}/"
fi

# 2. Kernel modules and firmware.
echo "==> installing kernel modules and firmware ($KREL)"
sudo mkdir -p "$R/usr/lib/modules" "$R/usr/lib/firmware"
sudo rm -rf "$R"/usr/lib/modules/*
sudo cp -a "$KOUT/modules/$KREL" "$R/usr/lib/modules/$KREL"
sudo rsync -a "$KOUT/firmware/" "$R/usr/lib/firmware/"
sudo mkdir -p "$R/opt/steamos-alioth/$KREL"
sudo cp -a "$KOUT/config-$KREL" "$KOUT/dtbs" "$R/opt/steamos-alioth/$KREL/"

# 2a. Device-signed firmware. It must overwrite linux-firmware -- the file
#     names are identical and the later write is the one that wins.
#
#     alioth's TrustZone rejects every generically signed PAS image in
#     linux-firmware (qcom_scm_pas_init_image -> -EINVAL; the kernel only says
#     "error -22 initializing firmware"). The two files even have the same
#     size as linux-firmware's; only the signature differs, so "is the file
#     present?" checks cannot detect this. Without them:
#       a650_zap -> GPU hw init failed -110 -> gamescope finds no physical
#                device -> sddm loops -> a black screen
#       adsp     -> q6afe never comes up -> PipeWire has only Dummy Output
#
#     The firmware is Xiaomi-signed and not redistributable, so it is not in
#     the repository: scripts/extract-alioth-firmware.sh pulls it from the
#     device's own modem_a and super.
if [[ -n "${ALIOTH_FW_DIR:-}" && -d "${ALIOTH_FW_DIR}" ]]; then
  "${PORT_ROOT}/scripts/assert-alioth-firmware.sh" "${ALIOTH_FW_DIR}" \
    || die "ALIOTH_FW_DIR=${ALIOTH_FW_DIR} failed assert-alioth-firmware.sh"
  echo "==> overlaying device-signed firmware (${ALIOTH_FW_DIR})"
  sudo rsync -a "${ALIOTH_FW_DIR}/" "$R/usr/lib/firmware/"
  # Leave positive provenance in the artifact: flash-alioth.sh --install
  # requires DEVICE-FIRMWARE before it will write userdata. Why not "no
  # GENERIC marker, so allow it"? That would accept a kit built before this
  # check existed, or a hand-copied kit. An irreversible step wants someone
  # to sign for it, not the absence of an objection.
  mkdir -p "$OUT"
  rm -f "$OUT/GENERIC-FIRMWARE"
  {
    echo "device-signed firmware from ALIOTH_FW_DIR=${ALIOTH_FW_DIR}"
    echo "built $(date -Is)"
    (cd "${ALIOTH_FW_DIR}" && find . -type f -print0 | sort -z \
      | xargs -0 sha256sum) 2>/dev/null || true
  } >"$OUT/DEVICE-FIRMWARE"
else
  echo "!! no ALIOTH_FW_DIR -- the image uses linux-firmware's generically"
  echo "!! signed firmware. alioth's TrustZone rejects it: black screen and"
  echo "!! no sound. Run scripts/extract-alioth-firmware.sh first (see its"
  echo "!! header), then rerun with ALIOTH_FW_DIR=<output-dir>."
  # Leave provenance in the artifact. Warnings scroll off the screen; files
  # do not -- flash-alioth.sh --install reads this file, not the operator's
  # memory.
  if [[ "$MODE" == --install ]]; then
    mkdir -p "$OUT"
    rm -f "$OUT/DEVICE-FIRMWARE"
    cat >"$OUT/GENERIC-FIRMWARE" <<'FWEOF'
This kit was built without ALIOTH_FW_DIR. a650_zap.mbn and adsp.mbn are
linux-firmware's generically signed versions. alioth's TrustZone rejects them:

  a650_zap -> GPU hw init failed -110 -> gamescope finds no physical device
           -> sddm loops -> a black screen
  adsp     -> q6afe never comes up -> PipeWire has only Dummy Output, no sound

flash-alioth.sh --install refuses to run when it sees this file. To flash it
anyway (knowing it is a black screen with no sound), also set
ALIOTH_FW_GENERIC_OK=1 at flash time.
FWEOF
  fi
fi

# 2b. InputPlumber. Valve's Frame image does not include this daemon -- only
#     Steam's own udev rule (90-steam-inputplumber.rules). Spec §7.1's whole
#     input design depends on it: Bluetooth controllers and volume keys become
#     a virtual Deck pad through it. The upstream port installs an official
#     prebuilt aarch64 release with install-inputplumber-sm8550.sh; reuse that,
#     but skip its SM8550 composite-device profile (ours is in alioth-overlay,
#     and its ext-hid services and udev rules are not inert on other boards).
#     Do this before sm8250-overlay: its tarball lays files into $R/etc.
echo "==> installing InputPlumber (daemon only)"
sudo env INPUTPLUMBER_SKIP_DEVICE_COMPOSITE=1 \
  "${PORT_ROOT}/scripts/install-inputplumber-sm8550.sh" "$R"

# 3. sm8250-overlay. Same loop and permission bits as upstream
#    apply-overlays.sh's SOC=sm8250 branch. The handheld InputPlumber profiles
#    are inert on alioth (each is gated on its own DT model), while
#    steamos-powerbuttond.service is what we need; see alioth-overlay/README.md.
echo "==> installing sm8250-overlay"
while IFS= read -r f; do
  sudo install -D -m0644 "$S8250_OVL/$f" "$R/$f"
done < <(cd "$S8250_OVL" && find etc usr -type f)

# 4. alioth-overlay.
echo "==> installing alioth-overlay"
sudo env ALIOTH_ORIENTATION_FLIP="$ORIENTATION_FLIP" \
  "${PORT_ROOT}/scripts/apply-alioth-overlay.sh" "$R"

# 4a2. De-VR. The Frame is a VR headset: gamescope-session.target's
#      Description is "Gamescope VR Session" and gamescope starts with
#      --backend openvr --vr-session-manager by default, so it exits at once
#      when SteamVR is absent -- the symptom is a black screen all the way.
#      The earlier "do not call apply-overlays.sh" decision accidentally
#      dropped this whole layer too; Task 8 measured it on the device and
#      added it back. It runs after both overlays so the backup under
#      /var/lib/steamos-arm-stock is always the Frame original, not something
#      an overlay just wrote; this step creates the upper directories itself.
echo "==> de-VR (session scripts + unit masks)"
sudo "${PORT_ROOT}/scripts/apply-alioth-devr.sh" "$R"

# 4a1. Desktop Mode. The Frame image starts Plasma through
#      start-gamescope-session with Game Mode's xcb environment still set;
#      plasmashell dies and the screen stays black. Install the upstream
#      SM8550/SM8250 session (plasma.desktop -> sm8550-startplasma, prepare +
#      desktop-outputs + desktop-fit) instead.
echo "==> installing Desktop Mode session"
sudo "${PORT_ROOT}/scripts/apply-alioth-desktop.sh" "$R"

# 4a3. alioth has no DP alt mode and no VR headset; the de-VR layer masks
#      every SteamVR unit, and no normal boot path calls /opt/steamvr. Keeping
#      it is 1.37 GiB of dead weight, so drop it from the image. Keep
#      /usr/bin/steamvr and /usr/share/deckard/openvrpaths.vrpath -- the
#      former prints "no installation found" if a repair path names it, and
#      the latter is only copied by masked units.
echo "==> removing unused /opt/steamvr"
sudo rm -rf "$R/opt/steamvr"

# 4b. /etc overlayfs. etc.mount is
#     lowerdir=/etc,upperdir=/var/lib/overlays/etc/upper,workdir=.../work,
#     and overlayfs requires upperdir and workdir to exist -- systemd's mount
#     unit does not create them. Valve's rootfs.img has neither, so create
#     both here. Creating only upperdir makes etc.mount fail, /etc falls back
#     to the lower layer, and every configuration mirrored into upper is
#     ineffective.
sudo mkdir -p "$R/var/lib/overlays/etc/upper" "$R/var/lib/overlays/etc/work"

# 4c. Enable inputplumber.service. The prebuilt release ships the unit but not
#     the enable link, and without it InputPlumber never starts -- the symptom
#     is "the controller still shows Xbox icons in Steam".
for u in inputplumber.service; do
  if [[ -f "$R/usr/lib/systemd/system/$u" ]]; then
    sudo mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
    sudo ln -sfn "../$u" "$R/usr/lib/systemd/system/multi-user.target.wants/$u"
    echo "==> enabled $u"
  else
    echo "!! missing $u -- did InputPlumber fail to install?"
  fi
done

# 4d. Steam client seed (spec §6.4). Optional, because it needs a complete
#     ARM client tree (STEAM_ARM_SEED) or vendor install-steam-arm, neither of
#     which is on this build host.
#
#     The image ships /usr/lib/steam/steam.tar.zst as a bootstrap and
#     self-bootstraps on first online boot. Upstream
#     install-complete-steam-client.sh says the Frame's tarball is "version 0,
#     missing package zip, spinning" -- that is their environment; whether it
#     is true on alioth needs a Task 8 measurement. Do not pretend it is
#     solved here.
STEAM_HOME="$R/home/steamos/.local/share/Steam"
if [[ -n "${STEAM_ARM_SEED:-}" && -d "${STEAM_ARM_SEED}" ]]; then
  echo "==> seeding Steam ARM client (from ${STEAM_ARM_SEED})"
  sudo mkdir -p "$STEAM_HOME"
  sudo env STEAM_ARM_SEED="${STEAM_ARM_SEED}" \
    "${PORT_ROOT}/scripts/install-complete-steam-client.sh" "$STEAM_HOME"
  sudo chown -R 1000:1000 "$R/home/steamos"
else
  echo "!! no STEAM_ARM_SEED -- the image does not pre-seed the Steam client."
  echo "!! First boot will bootstrap from /usr/lib/steam/steam.tar.zst over the"
  echo "!! network (about 2.5 GB). spec §6.4 asks for a seed; to provide one,"
  echo "!! set STEAM_ARM_SEED=<a complete Steam tree> and rerun."
fi

# 4e. Developer SSH entry (optional, off by default).
#
#     Why off by default: this step produces the root filesystem of a device
#     that will join the home WiFi. A public key in the image plus an sshd
#     that starts at boot is a backdoor -- and one that someone who "just
#     followed the README" cannot see. So it is explicitly enabled by
#     ALIOTH_SSH_PUBKEY; without it, not a byte is written.
#     scripts/assert-alioth-kit.sh A.1b checks this statically.
#
#     What it enables: scripts/alioth-ssh.sh reaches the system over USB NCM
#     (device 10.86.200.233). Game Mode has no terminal, and most on-device
#     fixes (/usr and /etc are writable) can be done over ssh without
#     reflashing -- phase 2's black screen, touch, power key and audio were
#     all diagnosed this way.
#
#     Usage: ALIOTH_SSH_PUBKEY=~/.ssh/id_ed25519.pub ./make-steamos-alioth.sh --install
if [[ -n "${ALIOTH_SSH_PUBKEY:-}" ]]; then
  pub="${ALIOTH_SSH_PUBKEY}"
  [[ -f "$pub" ]] || die "ALIOTH_SSH_PUBKEY=$pub is not a file"
  grep -qE '^(ssh|ecdsa)-' "$pub" \
    || die "ALIOTH_SSH_PUBKEY=$pub does not look like a public key (first line
     does not start with ssh- or ecdsa-); do not put a private key in the image."
  echo "==> installing developer SSH entry (public key $pub)"

  # Public key goes into the steamos user's home. /home is on the root
  # filesystem on alioth (the Frame's home.mount points at a partition this
  # device does not have and was masked by the de-VR step).
  sudo install -d -m0700 -o 1000 -g 1000 "$R/home/steamos/.ssh"
  sudo install -m0600 -o 1000 -g 1000 "$pub" "$R/home/steamos/.ssh/authorized_keys"

  # Enable the daemon. The image's unit says WantedBy=multi-user.target, but
  # the prebuilt image has no enable link, and you cannot run
  # `systemctl enable` against someone else's rootfs on the build host (it
  # would write to this host's /etc), so create the link by hand.
  # Two copies: the image's /etc is the overlayfs lowerdir; what actually
  # takes effect at boot is the upperdir -- writing only the lowerdir means
  # the link does not exist after boot.
  for d in "$R/etc/systemd/system" "$R/var/lib/overlays/etc/upper/systemd/system"; do
    sudo mkdir -p "$d/multi-user.target.wants"
    sudo ln -sfn /usr/lib/systemd/system/sshd.service \
      "$d/multi-user.target.wants/sshd.service"
  done
  # Host keys are generated by sshdgenkeys.service on first boot (sshd.service
  # Wants= it). Do not pre-generate them here -- every device must have its
  # own.

  # Self-flash authorization. alioth-write-boot needs root (it writes
  # boot_a/boot_b), and steamos has no passwordless sudo in the installed
  # system -- measured on the device, `sudo -n true` asks for a password, and
  # Game Mode has nowhere to type it. Only this one command is allowed, and
  # only inside this opt-in block: an image built without ALIOTH_SSH_PUBKEY
  # gets no sudoers rule at all.
  #
  # Why it is worth allowing: changing the kernel is the most repeated loop in
  # this project, and every round used to require holding volume-down + power
  # to enter fastboot. With this, a round is "send the file + a normal reboot".
  # The command can be allowed because the script guards its own boundary --
  # it only accepts block devices whose PARTLABEL is boot_a/boot_b and never
  # writes a byte to any other partition (super, userdata, especially abl),
  # and after writing it reads back and compares sha256.
  #
  # The name must start with zz-. @includedir reads files in filename order,
  # and in sudoers the later rule wins -- the image's /etc/sudoers.d/wheel
  # says
  #   %wheel ALL=(ALL) ALL
  # and steamos is in the wheel group (measured groups=...,998(wheel),...).
  # A file named 50-alioth-write-boot would sort before wheel, so wheel's
  # password-requiring rule would win and `sudo -n` would still ask for a
  # password (measured). zz- sorts after wheel.
  #
  # The second command is alioth-install-modules: the boot image has only the
  # kernel and device tree, while modules live on userdata and half of this
  # port is `=m`. Replacing only boot leaves the device loading the old module
  # files under an identical version string, so nothing reports an error --
  # that cost a round on 2026-10-24. Its boundary is also inside itself: it
  # verifies every archive member's path, type and link target before writing
  # only under /usr/lib/modules/<version>.
  #
  # The third command is `systemctl reboot`. Writing the boot slot takes effect
  # only after a reboot, and steamos cannot reboot itself -- measured:
  # `systemctl reboot` returns
  #   Call to Reboot failed: Interactive authentication required.
  # (an ssh session with no local seat, so polkit denies it). Without it the
  # "do not touch the phone" loop breaks at the last step. Allowing it does not
  # widen anything: anyone who can log in can already make the device reboot.
  sudo install -d -m0750 "$R/etc/sudoers.d"
  printf '%s\n' \
    'steamos ALL=(root) NOPASSWD: /usr/lib/steamos-arm/alioth-write-boot' \
    'steamos ALL=(root) NOPASSWD: /usr/lib/steamos-arm/alioth-install-modules' \
    'steamos ALL=(root) NOPASSWD: /usr/bin/systemctl reboot' \
    | sudo install -m0440 /dev/stdin "$R/etc/sudoers.d/zz-alioth-write-boot"
  # It also has to go into the overlay upperdir, otherwise the rule does not
  # exist after boot (see the comment above).
  sudo install -d -m0750 "$R/var/lib/overlays/etc/upper/sudoers.d"
  sudo install -m0440 "$R/etc/sudoers.d/zz-alioth-write-boot" \
    "$R/var/lib/overlays/etc/upper/sudoers.d/zz-alioth-write-boot"
  echo "!! this image allows ssh steamos@ login at boot. Use it only on your own device."
else
  echo "!! no ALIOTH_SSH_PUBKEY -- the image gets no ssh key and no sshd."
  echo "!! For a developer entry point set ALIOTH_SSH_PUBKEY=<your .pub> and rerun; see scripts/alioth-ssh.sh."
fi

# 5. First-boot sentinel. alioth-firstboot does nothing without it, and the
#    root filesystem stays at a few GB -- Steam only reports an error when it
#    first tries to install a game.
sudo mkdir -p "$R/var/lib"
sudo touch "$R/var/lib/alioth-firstboot-pending"

# 6. Every machine needs its own D-Bus / network identity.
sudo truncate -s 0 "$R/etc/machine-id"
[[ -f "$R/var/lib/overlays/etc/upper/machine-id" ]] \
  && sudo truncate -s 0 "$R/var/lib/overlays/etc/upper/machine-id"

# 7. Create the ext4 image. The image holds only the content plus a little
#    headroom; first boot grows it to the whole partition.
root_uuid="$(uuidgen)"
used_mib="$(sudo du -sm --exclude=proc --exclude=sys --exclude=dev \
  --exclude=tmp --exclude=run "$R" | awk '{print $1}')"
root_mib=$((used_mib + 1024 + used_mib / 50 + 128))
raw="${STEAMOS_WORK:-${PORT_ROOT}/work}/.userdata-alioth.img"
echo "==> userdata: ${root_mib} MiB ext4 UUID=${root_uuid} (content ${used_mib} MiB; first boot grows to 106 GiB)"

rm -f "$raw"
truncate -s "${root_mib}M" "$raw"
sudo mkfs.ext4 -q -F -L steamos -U "$root_uuid" -m 1 "$raw"

MNT="${STEAMOS_WORK:-${PORT_ROOT}/work}/.alioth-img-mnt"
LOOPDEV=""
cleanup_img() {
  mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT"
  [[ -n "$LOOPDEV" ]] && sudo losetup -d "$LOOPDEV" 2>/dev/null
  LOOPDEV=""
}
trap cleanup_img EXIT
sudo mkdir -p "$MNT"
LOOPDEV="$(sudo losetup -f --show "$raw")"
[[ -n "$LOOPDEV" ]] || die "losetup failed"
sudo mount "$LOOPDEV" "$MNT"

echo "==> copying root filesystem into the image"
sudo rsync -aHAX --numeric-ids \
  --exclude='/dev/**' --exclude='/proc/**' --exclude='/sys/**' \
  --exclude='/tmp/**' --exclude='/run/**' \
  "${R}/" "${MNT}/"
sudo mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/run"

# fstab uses a UUID rather than a hardcoded /dev/sd*: UFS enumeration order is
# not guaranteed. x-systemd.growfs grows the filesystem at mount time;
# alioth-firstboot's resize2fs is the fallback (a no-op exit 0 if already
# grown), and what only alioth-firstboot does is mark the slot successful
# after the growth succeeds.
printf '%s\n' \
  "# SteamOS ARM (sm8250, Xiaomi alioth): one ext4 on userdata is /," \
  "# and /home is inside it. No boot partition -- the kernel is in boot_a/boot_b." \
  "UUID=${root_uuid}  /  ext4  defaults,noatime,commit=30,x-systemd.growfs  0 1" \
  | sudo tee "$MNT/etc/fstab" >/dev/null
sudo mkdir -p "$MNT/var/lib/overlays/etc/upper"
sudo cp -a "$MNT/etc/fstab" "$MNT/var/lib/overlays/etc/upper/fstab"

sudo mkdir -p "$MNT/opt/steamos-alioth"
printf '%s\n' \
  "soc=sm8250" "device=Xiaomi Redmi K40 / POCO F3 (alioth)" \
  "kernel=${KREL}" "built=$(date -Iseconds)" \
  "root_uuid=${root_uuid}" "root=PARTLABEL=userdata" \
  "layout=ext4 userdata (root + home), kernel in boot_a/boot_b" \
  | sudo tee "$MNT/opt/steamos-alioth/IMAGE.txt" >/dev/null

sync
cleanup_img
trap - EXIT
sudo e2fsck -fy "$raw" >/dev/null || true
sudo chown "$(id -u):$(id -g)" "$raw"

# 8. boot.img. Same cmdline as boot-debug.img: steamos.root=PARTLABEL=userdata
#    already pointed here in the phase-1 cmdline; it failed to mount only
#    because the partition still held Android's encrypted f2fs. Keep usbshell
#    -- if first boot really goes wrong, it is the only observation channel
#    (the phase-1 lesson).
pack_boot boot.img
# Same kernel, one extra token. flash-alioth.sh --install flashes this image
# only when the operator agrees to move static system files to the Android
# system partition; on first boot alioth-super-migrate.service reads the token
# from /proc/cmdline.
pack_boot boot-migrate.img alioth.supermigrate=1

if command -v img2simg >/dev/null; then
  echo "==> sparse (img2simg)"
  img2simg "$raw" "${KIT}/userdata.img"
  rm -f "$raw"
else
  echo "==> no img2simg; writing raw userdata.img. Install android-sdk-libsparse-utils"
  echo "    (or android-tools-fsutils) and rebuild if fastboot rejects the raw file."
  mv "$raw" "${KIT}/userdata.img"
fi

sums
echo
ls -lh "${KIT}"
echo
echo "flash: ./flash-alioth.sh --install   (will erase Android's /data)"
