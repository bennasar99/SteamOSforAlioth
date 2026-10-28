#!/usr/bin/env bash
# Put a SteamOS image on an alioth (Xiaomi Redmi K40 / POCO F3).
#
# This is the only script in the port that writes to flash, so the rules it
# enforces are narrow on purpose:
#
#   * It writes slot a and nothing else. Slot a is the spare; the phone's
#     working Android is in slot b and this script never names it.
#   * Before writing, it refuses if slot a is the active slot -- writing it
#     would then overwrite the slot the phone starts from. The value is read
#     from the phone on every run.
#   * It checks it is talking to an alioth. Several other phones' flash
#     scripts live in this same tree and an sm8250 boot image in any of
#     their boot partitions is a day of someone's life.
#   * It touches two partitions in the test path: boot_a and dtbo_a. Nothing
#     else, ever.
#   * It never marks a slot successful.
#   * It refuses to run unless scripts/assert-alioth-boot-image.sh passes,
#     so those rules are checked rather than remembered.
#
# Modes:
#
#   --boot   Hand the image straight to the bootloader (fastboot boot).
#            Writes NOTHING and changes no slot.
#
#            Measured on this phone on 2026-10-23: this mode cannot tell
#            you anything. ABL answered `Booting OKAY` and then stayed in
#            its fastboot command loop -- the host saw no USB disconnect
#            for the three minutes that followed, and `getvar` kept
#            answering, so the bootloader never jumped. In the fastboot
#            protocol the OKAY for `boot` is sent BEFORE the jump, so it
#            is not evidence of anything. Whether ABL rejected this
#            image's header or does not implement the command at all,
#            the outcome here is the same: no result.
#
#            Consistent with that, `fastboot boot` appears nowhere in
#            pmaports-alioth; its install guide is erase dtbo / flash boot
#            / set_active / reboot. The flash path is the proven one.
#
#            The mode is kept because it writes nothing and costs one
#            second. Do not read a failure here as a verdict on the
#            kernel, and do not spend a second attempt on it.
#
#   --test   Write slot a and start from it.
#
#   --install  Write the built kit to both slots. This is irreversible: it
#              replaces Android's /data with the SteamOS root filesystem.
#              It can also optionally erase Android's system partitions and
#              put static SteamOS data plus the disk swap file there. That
#              second step is asked for separately; saying yes means Android
#              will no longer be usable and can only be restored with a full
#              stock ROM.
#
# RECOVERY -- read this before running --test:
#
#   `fastboot --set-active=b` from fastboot is the way back, short of the
#   9008 EDL package. Hold volume-down + power to reach fastboot; that
#   works regardless of what is in the slot written here.
#
#   Go there directly. This bootloader does fall back by itself, but that
#   is not a recovery plan. Measured on this phone on 2026-10-23, with
#   nothing written to any partition: a stray `fastboot boot` crashed the
#   SoC, the boot attempts that followed failed, and the bootloader then
#   marked the active slot b unbootable and switched the active slot to a
#   on its own. `getvar all` afterwards read slot-unbootable:b:yes, and
#   slot-retry-count a:7 against b:4 -- it had been counting failures on b.
#
#   Two things that costs you. It spends boot attempts and lands on
#   whatever the other slot holds, which here was an Android that did not
#   start either: splash, black screen, repeat, for as long as you let it.
#   And it damages the flags of the slot it abandons -- getting back to a
#   working phone took `fastboot --set-active=b`, which is also what clears
#   slot-unbootable and resets the retry count. Watching the phone loop
#   buys nothing that command does not.
#
#   (The UART captures in pmaports-alioth log "A/B retry count NOT
#   decremented" on every boot, and this file previously cited that line to
#   claim the fallback did not exist here. The line is real; the conclusion
#   drawn from it was not.)
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-alioth"
# ALIOTH_ASSERT_BOOT_IMAGE is a test seam used by
# scripts/assert-alioth-flash.sh to run this script against fake images. When
# it is overridden, print it loudly: this is the gate in front of a flash and
# it must not be bypassed silently.
ASSERT="${ALIOTH_ASSERT_BOOT_IMAGE:-${PORT_ROOT}/scripts/assert-alioth-boot-image.sh}"

# The slot this script is allowed to write, and the only one it will.
TARGET=a
# From this phone's own `fastboot getvar all`.
EXPECT_PRODUCT=alioth
BOOT_PART_SIZE=$((0xC000000))
MIGRATE_IMG="${IMG_DIR}/boot-migrate.img"

die() { echo "flash-alioth: $*" >&2; exit 1; }

mode="${1:-}"
case "$mode" in
  --boot|--test|--install) ;;
  *) die "usage: $0 --boot | --test | --install   (read the header first, especially RECOVERY)" ;;
esac

# --install flashes the production image; --boot/--test use the phase-1
# debug image.
if [[ "$mode" == --install ]]; then
  IMG="${IMG_DIR}/boot.img"
  CONFIRM_WORD=ERASE
else
  IMG="${IMG_DIR}/boot-debug.img"
  CONFIRM_WORD=YES
fi

# 1. Tools and image.
command -v fastboot >/dev/null || die "fastboot is not installed"
[[ -s "$IMG" ]] || die "missing $IMG -- run ./make-steamos-alioth.sh --kernel-only first"

# 2. The image has to fit. Better to say so here than have the transfer
#    stop halfway through.
size=$(stat -c %s "$IMG")
(( size <= BOOT_PART_SIZE )) \
  || die "image is $size bytes, larger than the $BOOT_PART_SIZE-byte partition"

# 3. The structural gate. These assertions are the only thing standing
#    between a typo in the packer and a boot image this phone cannot start,
#    so they run here rather than being something to remember to run.
[[ -x "$ASSERT" ]] || die "missing $ASSERT"
[[ -n "${ALIOTH_ASSERT_BOOT_IMAGE:-}" ]] \
  && echo "!! structural assertion overridden by ALIOTH_ASSERT_BOOT_IMAGE=$ASSERT -- tests only"
echo "=> $ASSERT"
ALIOTH_BOOT_IMAGE="$IMG" "$ASSERT" >"${IMG_DIR}/assert.log" 2>&1 || {
  tail -n 30 "${IMG_DIR}/assert.log" >&2
  die "assertion failed (full output in ${IMG_DIR}/assert.log); not flashing"
}
echo "   assertion passed"

# 4. The checksum the packer wrote. This catches a truncated or corrupt
#    copy. It cannot catch a stale image -- the packer rewrites SHA256SUMS
#    on every build, so an old image and its own sums agree. Step 3 is what
#    covers staleness, by checking the image's actual contents.
[[ -s "${IMG_DIR}/SHA256SUMS" ]] || die "missing ${IMG_DIR}/SHA256SUMS"
( cd "$IMG_DIR" && sha256sum -c --quiet SHA256SUMS ) || die "SHA256 check failed"

# 5. The phone has to be in fastboot.
[[ -n "$(fastboot devices 2>/dev/null)" ]] || die "no device in fastboot (put the phone in fastboot mode)"

# Read one bootloader variable.
#
# Pure shell on purpose: no sed script built from the variable name, and no
# pipeline, so `set -o pipefail` has no SIGPIPE to turn into a silent exit.
# Two output shapes are accepted -- "name: value", which host fastboot
# prints for a single getvar, and "(bootloader) name:value", the raw INFO
# line this bootloader produces (that is the shape in this phone's own
# `getvar all` capture, with no space after the colon). A failure returns
# non-zero so the caller reports it instead of dying with no message.
getvar() {
  local name="$1" out line val
  out="$(fastboot getvar "$name" 2>&1)" || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"(bootloader) "}"
    case "$line" in
      "$name":*)
        val="${line#"$name":}"
        val="${val#"${val%%[![:space:]]*}"}"   # trim leading whitespace
        val="${val%"${val##*[![:space:]]}"}"   # trim trailing whitespace
        if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
        ;;
    esac
  done <<<"$out"
  return 1
}

# >>> INSTALL-ONLY REGION (spec §6.5 physical isolation) >>>
#
# Only --install reaches this region. Code that writes the root filesystem,
# and any reference to slot b's partitions, is allowed only here.
# scripts/assert-alioth-boot-image.sh splits the source on these markers and
# checks that the --test/--boot paths cannot reach it. That is what spec §6.5
# means by physical isolation: while iterating on the kernel, the code that
# can erase the system does not exist on that path.
#
# There is no "mark slot successful" action here. fastboot has no such
# command -- per spec §6.3 that is done on-device by qbootctl or the port's
# own marker service after the system is actually up. Do not close the
# bootloader's automatic fallback before the system has proven it boots.

# Before the irreversible step, prove the kit's firmware came from this
# phone.
#
# The 2026-10-24 review pointed out the asymmetry: the boot-image rules were
# wired into the write path (the assertion gate above), while "the firmware
# is the phone's own signed copy" relied on memory -- make-steamos-alioth.sh
# used to print a warning and keep going when ALIOTH_FW_DIR was absent, and
# still produced a complete kit. So this could happen: the warning scrolls
# off, ten minutes later this script runs, the operator types ERASE, the
# root filesystem is gone, and the installed system is a black screen with
# no sound (Xiaomi's TrustZone rejects linux-firmware's generically signed
# a650_zap.mbn). Recovering the firmware then requires an Android that has
# already been erased.
#
# What is wanted is positive evidence: the DEVICE-FIRMWARE marker written at
# build time. Not "no GENERIC marker, so allow it" -- that would accept kits
# built before this check existed and hand-copied kits too. An irreversible
# step needs someone to sign for it, not the absence of an objection.
check_firmware_provenance() {
  if [[ "${ALIOTH_FW_GENERIC_OK:-}" == 1 ]]; then
    echo "!! ALIOTH_FW_GENERIC_OK=1 -- skipping the firmware provenance check."
    echo "!! If this kit uses generically signed firmware, the result is a black screen and no sound."
    return 0
  fi
  if [[ -f "${IMG_DIR}/GENERIC-FIRMWARE" ]]; then
    die "this kit was built with linux-firmware's generically signed firmware (see
     ${IMG_DIR}/GENERIC-FIRMWARE). Flashing it loses Android's /data and produces
     a black screen with no sound. Rebuild from the phone's own firmware first:
       scripts/extract-alioth-firmware.sh <modem-dir> <vendor-dir> <output-dir>
       ALIOTH_FW_DIR=<output-dir> ./make-steamos-alioth.sh --install"
  fi
  [[ -f "${IMG_DIR}/DEVICE-FIRMWARE" ]] \
    || die "${IMG_DIR} has no DEVICE-FIRMWARE -- this kit does not prove its
     firmware came from this phone, so it cannot be distinguished from a
     black-screen image. Rerun ./make-steamos-alioth.sh --install with
     ALIOTH_FW_DIR set to write that marker.
     If you know it uses generically signed firmware and still want to flash:
     ALIOTH_FW_GENERIC_OK=1"
}

install_summary() {
  local u="${IMG_DIR}/userdata.img"
  [[ -s "$u" ]] || die "missing $u -- run ./make-steamos-alioth.sh --install first"
  check_firmware_provenance
  cat <<EOF
  rootfs  $u ($(stat -c %s "$u") bytes)
  actions erase dtbo_a + dtbo_b
          flash boot_a + boot_b (same image to both slots, spec §6.5)
          flash the root filesystem   <-- irreversible, Android's /data is gone
          --set-active=${active} (clears any stale unbootable flag and retry count)
  keep    Android's system partitions by default. The optional migration
          below erases them and puts static SteamOS data plus a 2 GiB swap
          file there. Saying yes means Android will no longer be usable.
EOF
}

# Ask whether to put static SteamOS data and the swap file on Android's
# system partitions. Default is no. This is deliberately a second question:
# the ERASE confirmation guards the root filesystem, and this guards the
# Android system images. They are different irreversible actions.
ask_extra_storage() {
  cat <<'EOF'

  Optional extra storage:
    Move a fixed set of read-only SteamOS system files (about 4.5 GB: FEX
    guest root, Steam client runtime, fonts, icons, locales, docs and
    toolchain) to Android's system partitions, and put the 2 GiB disk swap
    file there too. The root filesystem then has more room for games.

    This erases Android's system images. Android is already unbootable after
    this install, but with this option it also cannot be restored by erasing
    data -- you will need the full stock ROM.

EOF
  printf '  Enable the extra-storage migration? [y/N] '
  local answer
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES)
      [[ -s "$MIGRATE_IMG" ]] \
        || die "missing $MIGRATE_IMG -- rebuild with ./make-steamos-alioth.sh --install"
      grep -q 'boot-migrate\.img' "${IMG_DIR}/SHA256SUMS" \
        || die "SHA256SUMS does not cover boot-migrate.img -- rebuild the kit"
      size=$(stat -c %s "$MIGRATE_IMG")
      (( size <= BOOT_PART_SIZE )) \
        || die "boot-migrate.img is $size bytes, larger than the $BOOT_PART_SIZE-byte partition"
      ALIOTH_BOOT_IMAGE="$MIGRATE_IMG" "$ASSERT" >"${IMG_DIR}/assert.log" 2>&1 || {
        tail -n 30 "${IMG_DIR}/assert.log" >&2
        die "boot-migrate.img failed the structural assertion; not flashing"
      }
      IMG="$MIGRATE_IMG"
      echo "  -> enabled: Android's system images will be erased; Android will be unusable."
      echo "     boot image: $(basename "$IMG")"
      ;;
    *)
      echo "  -> disabled: Android's system partitions stay untouched."
      ;;
  esac
}

do_install() {
  local u="${IMG_DIR}/userdata.img"
  [[ -s "$u" ]] || die "missing $u"

  # Erase dtbo first. A valid vendor overlay left in place is merged onto
  # our mainline tree by the bootloader and fails; an empty partition is
  # simply skipped (this phone's own bootloader log says "Dtbo hdr magic
  # mismatch 0" and continues booting).
  local sl
  for sl in a b; do
    echo "=> fastboot erase dtbo_${sl}"
    fastboot erase "dtbo_${sl}"
  done

  # Flash the same boot image to both slots (spec §6.5). Flashing only one
  # means a bootloader fallback lands on the other slot, which holds either
  # the phase-1 debug kernel or an old Android -- neither boots.
  for sl in a b; do
    echo "=> fastboot flash boot_${sl} ($IMG)"
    fastboot flash "boot_${sl}" "$IMG"
  done

  echo "=> fastboot flash userdata"
  fastboot flash userdata "$u"

  # Do not change the active slot; just re-declare it. This clears
  # slot-unbootable and the retry counters spent during phase-1 testing.
  # Both slots have the same contents, so either one is fine.
  echo "=> fastboot --set-active=${active}"
  fastboot --set-active="${active}"

  echo "=> fastboot reboot"
  fastboot reboot
}
# <<< INSTALL-ONLY REGION <<<

# 6. The right phone. This tree also holds flash scripts for the REDMAGIC 6
#    and several other handhelds; any of them sitting in fastboot would pass
#    every other check here.
product="$(getvar product)" || die "cannot read product; refusing to continue"
[[ "$product" == "$EXPECT_PRODUCT" ]] \
  || die "connected device is '$product', not $EXPECT_PRODUCT -- refusing"

# 7. An unlocked bootloader. A locked one rejects the image anyway, but it
#    is better to stop before changing which slot the phone starts from.
unlocked="$(getvar unlocked)" || die "cannot read unlocked; refusing to continue"
[[ "$unlocked" == yes ]] || die "bootloader is locked (unlocked=$unlocked)"

# 8. Which slot the phone starts from. Read live: the value changes every
#    time anyone runs --set-active, including this script on its last run.
active="$(getvar current-slot)" || die "cannot read current-slot; refusing to continue"
# Treating unexpected output as a default is how you irreversibly write the
# wrong partition. This phone has only a and b.
case "$active" in
  a|b) ;;
  *) die "current-slot read as '$active', not a or b -- refusing" ;;
esac

# 9. The check this whole script exists for. Only --test writes to a spare
#    slot, so only --test is gated here: --boot changes nothing and is
#    exactly what you want when slot a is already active.
if [[ "$mode" == --test && "$active" == "$TARGET" ]]; then
  cat >&2 <<EOF
flash-alioth: refusing to run.

  The active slot is already $TARGET, and this script only writes $TARGET --
  writing now would overwrite the slot the phone boots from, with no fallback.

  Switch back first, then try again:

      fastboot --set-active=b
      $0 $mode

  (Or use $0 --boot, which writes nothing and works in this state.)
EOF
  exit 1
fi

cat <<EOF

  image    $IMG ($size bytes)
  device   $product
  active   $active
  mode     $mode
EOF
[[ "$mode" == --install ]] || echo "  target slot  $TARGET   (active slot $active is not touched)"
case "$mode" in
  --boot) echo "  action   hand the image to the bootloader; no partition is written, no slot is changed" ;;
  --test) echo "  action   erase dtbo_${TARGET}; flash boot_${TARGET}; --set-active=${TARGET}" ;;
  --install) install_summary ;;
esac
if [[ "$mode" == --test ]]; then
  cat <<'EOF'

  Recovery: hold volume-down + power to enter fastboot, then run
  `fastboot --set-active=b`.

  Do not treat the bootloader's automatic fallback as a recovery path. It
  spends boot attempts, lands on whatever the other slot holds (which here
  was an Android that did not start: splash, black screen, repeat), and marks
  the slot it abandons unbootable. Getting back still needs the command
  above. Going straight to fastboot is faster.
EOF
fi
echo

# A human has to be here for the modes that write. Without this,
# `echo YES | ./flash-alioth.sh --test` flashes unattended, and this prompt
# is the last gate in front of the only writes in the project.
#
# --boot is exempt, and only --boot: it is `fastboot boot`, which writes no
# partition and does not touch the slot flags. The tty requirement exists to
# guard writes, so applying it here buys nothing and costs a hand-typed YES
# on every kernel iteration -- the loop this project spends most of its time
# in. The confirmation word is still required, so a bare
# `./flash-alioth.sh --boot </dev/null` still refuses.
# scripts/assert-alioth-flash.sh 6b pins both halves: piped input works for
# --boot and is refused for --test and --install.
if [[ "$mode" != --boot ]]; then
  [[ -t 0 ]] || die "confirmation must come from an interactive terminal; pipes and redirects are refused (--boot is the exception because it writes nothing)"
fi

# The optional migration is asked before the ERASE word: it is a different
# irreversible decision, and the operator should make it while the plan is
# still on screen.
if [[ "$mode" == --install ]]; then
  ask_extra_storage
fi

printf 'Type %s in capitals to continue: ' "$CONFIRM_WORD"
read -r confirm
[[ "$confirm" == "$CONFIRM_WORD" ]] || die "not confirmed; exiting"

if [[ "$mode" == --install ]]; then
  do_install
elif [[ "$mode" == --boot ]]; then
  echo "=> fastboot boot (no writes)"
  fastboot boot "$IMG"
else
  echo "=> fastboot erase dtbo_${TARGET}"
  fastboot erase "dtbo_${TARGET}"
  echo "=> fastboot flash boot_${TARGET}"
  fastboot flash "boot_${TARGET}" "$IMG"
  # No vbmeta write: this bootloader logs
  # "avb_slot_verify.c:577: ERROR: vbmeta_... OK_NOT_SIGNED", sets the boot
  # state to orange and starts anyway, so the kit's vbmeta step for other
  # phones would be a write with nothing to show for it. (The captured logs
  # only ever show the active slot's vbmeta being checked, never the one
  # written here -- but on an unlocked phone a mismatch is non-fatal either
  # way, which is what makes skipping it safe rather than lucky.)
  echo "=> fastboot --set-active=${TARGET}"
  fastboot --set-active="${TARGET}"
  # Deliberately no "mark successful". It would be a write we do not need,
  # and it would throw away the ability to tell a tested slot from an
  # untested one.
  echo "=> fastboot reboot"
  fastboot reboot
fi

cat <<'EOF'

Now watch two channels:

  display  Kernel logs should appear on the panel directly (simpledrm takes
           over the bootloader's splash framebuffer, then the real panel
           driver does).
  USB      Plug it into a PC; two ttyACM serial ports and a network
           interface should appear. ttyACM0 is the kernel console
           (console=ttyGS0 on the cmdline), ttyACM1 is an interactive shell;
           the network root shell uses scripts/alioth-shell.sh (not telnet --
           the phone side is nc, and the PC-side address is often removed by
           NetworkManager, so the script adds it back).

Mounting the root will fail. That is expected in phase 1: there is no root
filesystem yet, and init drops to a shell.

Coming back to fastboot within about 15 seconds means the bootloader
rejected this image, not that the kernel is broken.
EOF
