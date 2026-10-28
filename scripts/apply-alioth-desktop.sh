#!/usr/bin/env bash
# Install the SteamOS-ARM Desktop Mode session into an alioth rootfs.
#
# The Frame image's plasma.desktop starts Plasma through
# start-gamescope-session with Game Mode's QT_QPA_PLATFORM=xcb still in the
# user manager. plasmashell then tries X11, fails, and the panel stays black.
# The upstream SM8550/SM8250 port fixes this with a small set of files:
#
#   plasma.desktop -> sm8550-startplasma
#   sm8550-startplasma -> sm8550-prepare-plasma + desktop-outputs + desktop-fit
#   sm8550-prepare-plasma clears the Game Mode environment and starts a clean
#     Wayland session
#   steamos-session-select calls prepare before steamosctl switches
#   desktop-steam is the Desktop Mode Steam autostart
#
# Those files already exist in this repository's steamos-overlay; this script
# only installs/backs them up in the same order as upstream apply-overlays.sh.
# The Razer Kishi flip is handled in desktop-outputs by checking for
# 99-orientation.conf, so Desktop Mode picture and touch agree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVL="${ROOT}/steamos-overlay"
R="${1:-}"

log() { echo "apply-alioth-desktop: $*" >&2; }
die() { echo "apply-alioth-desktop: $*" >&2; exit 1; }

[[ -n "$R" ]] || die "usage: $0 <rootfs-dir>"
[[ -d "$R" ]] || die "rootfs directory does not exist: $R"
[[ -d "$OVL" ]] || die "missing $OVL"

STOCK="$R/var/lib/steamos-arm-stock"
UPPER="$R/var/lib/overlays/etc/upper"

# Keep the stock copy for the files this script replaces. Backup only once:
# a rerun must not overwrite the real original with our version.
backup() {  # backup <relative-path> <new-source>
  local rel="$1" src="$2" dst="$STOCK/$1"
  [[ -f "$R/$rel" ]] || return 0
  [[ -e "$dst" ]] && return 0
  cmp -s "$R/$rel" "$src" && return 0
  install -D -m0644 "$R/$rel" "$dst"
}

stock_original() {  # stock_original <relative-path>
  local rel="$1" dst="$STOCK/$1"
  [[ -e "$R/$rel" ]] || return 0
  [[ -e "$dst" ]] && return 0
  install -D -m0644 "$R/$rel" "$dst"
}

install_as() {  # install_as <source> <relative-path> <mode>
  local src="$1" rel="$2" mode="$3"
  [[ -f "$src" ]] || die "missing $src"
  backup "$rel" "$src"
  install -D -m "$mode" "$src" "$R/$rel"
}

install_rel() {  # install_rel <relative-path> <mode>
  local rel="$1" mode="$2"
  install_as "$OVL/$rel" "$rel" "$mode"
}

# Scripts and the Wayland session.
install_rel usr/lib/steamos/desktop-outputs 0755
install_rel usr/lib/steamos/sm8550-prepare-plasma 0755
install_rel usr/lib/steamos/sm8550-startplasma 0755
install_rel usr/lib/steamos/desktop-steam 0755
install_rel usr/lib/steamos-arm/desktop-fit 0755
install_rel usr/lib/steamos-arm/desktop-portal-fix 0755
install_rel usr/bin/steamos-session-select 0755
install_rel usr/share/wayland-sessions/plasma.desktop 0644

# The layout fallback desktop-outputs uses when it has to replace an old
# fixed file.
install_as "$OVL/etc/xdg/kwinoutputconfig.json" \
  usr/share/steamos-arm/kwinoutputconfig.legacy.json 0644

# Prepare the user-manager environment before Plasma's targets start, even
# when Plasma is not launched through sm8550-startplasma.
install_rel usr/lib/systemd/user/sm8550-plasma-env.service 0644
for tgt in plasma-core.target plasma-workspace.target plasma-workspace-wayland.target; do
  install_rel "usr/lib/systemd/user/${tgt}.d/99-odin.conf" 0644
done
WAYLAND_DROPIN="$OVL/usr/lib/systemd/user/plasma-plasmashell.service.d/99-odin-wayland.conf"
for svc in plasma-plasmashell plasma-ksplash plasma-ksmserver \
  plasma-kcminit plasma-kcminit-phase1 plasma-kded6 plasma-kwin_wayland \
  plasma-gmenudbusmenuproxy plasma-xembedsniproxy plasma-kaccess \
  plasma-powerdevil plasma-polkit-agent plasma-kglobalaccel plasma-kscreen \
  plasma-xdg-desktop-portal-kde plasma-krunner plasma-kactivitymanagerd \
  plasma-dolphin plasma-ksystemstats plasma-restoresession plasma-baloorunner
do
  install_as "$WAYLAND_DROPIN" \
    "usr/lib/systemd/user/${svc}.service.d/99-odin-wayland.conf" 0644
done

# Desktop Mode's Steam autostart: the wrapper fixes Xft.dpi for the on-screen
# keyboard before exec'ing the same /usr/bin/steam with the original args.
STEAM_DESKTOP="$R/etc/xdg/autostart/steam.desktop"
if [[ -f "$STEAM_DESKTOP" ]]; then
  stock_original etc/xdg/autostart/steam.desktop
  sed -i 's|^Exec=/usr/bin/steam |Exec=/usr/lib/steamos/desktop-steam |' "$STEAM_DESKTOP"
  grep -q '^Exec=/usr/lib/steamos/desktop-steam ' "$STEAM_DESKTOP" \
    || die "could not redirect $STEAM_DESKTOP to desktop-steam"
  install -D -m0644 "$STEAM_DESKTOP" "$UPPER/xdg/autostart/steam.desktop"
else
  log "no /etc/xdg/autostart/steam.desktop; skipping the Desktop Mode redirect"
fi

# "Return to Gaming Mode" shortcut. The Frame image only puts it on the
# desktop for Jupiter/Galileo; alioth needs it always. The plasma-workspace
# env script copies it for the current user on each Desktop start.
install_rel etc/skel/Desktop/Return.desktop 0644
install_rel etc/xdg/plasma-workspace/env/set-return-icon.sh 0755
install_rel usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg 0644
install_as "$OVL/etc/skel/Desktop/Return.desktop" \
  usr/share/applications/steamos-gamemode.desktop 0644
install -D -m0644 "$OVL/etc/skel/Desktop/Return.desktop" \
  "$UPPER/skel/Desktop/Return.desktop"
install -D -m0755 "$OVL/etc/xdg/plasma-workspace/env/set-return-icon.sh" \
  "$UPPER/xdg/plasma-workspace/env/set-return-icon.sh"

# Portal fix: Steam's right-stick mouse needs the KDE portal backend, which
# can start too early during the Game Mode -> Desktop switch.
install_rel etc/xdg/autostart/steamos-arm-desktop-portal-fix.desktop 0644
install -D -m0644 "$OVL/etc/xdg/autostart/steamos-arm-desktop-portal-fix.desktop" \
  "$UPPER/xdg/autostart/steamos-arm-desktop-portal-fix.desktop"

# Steam's "Switch to Desktop" must not offer the Frame's X11 sessions: they
# inherit the wrong environment and leave the panel black.
mkdir -p "$R/usr/share/steamos/hidden-xsessions"
for s in plasmax11.desktop openbox.desktop openbox-kde.desktop; do
  [[ -f "$R/usr/share/xsessions/$s" ]] \
    && mv -f "$R/usr/share/xsessions/$s" "$R/usr/share/steamos/hidden-xsessions/$s"
done

log "installed Desktop Mode session (plasma.desktop -> sm8550-startplasma)"
