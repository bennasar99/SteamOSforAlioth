#!/usr/bin/env bash
# Assert scripts/apply-alioth-desktop.sh installs the upstream Desktop Mode
# session correctly, including the Razer Kishi flip marker hook.
#
# Uses a fake rootfs with the Frame originals; no real image, no root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT}/scripts/apply-alioth-desktop.sh"
OVL="${ROOT}/steamos-overlay"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

R="$(mktemp -d)"
trap 'rm -rf "$R"' EXIT

mkdir -p "$R/usr/share/wayland-sessions" "$R/usr/bin" \
  "$R/etc/xdg/autostart" "$R/usr/share/xsessions" \
  "$R/var/lib/overlays/etc/upper"
printf '%s\n' '[Desktop Entry]' 'Exec=start-gamescope-session plasma-session.target' \
  >"$R/usr/share/wayland-sessions/plasma.desktop"
printf '%s\n' '#!/bin/bash' '# old Valve wrapper' >"$R/usr/bin/steamos-session-select"
printf '%s\n' '[Desktop Entry]' 'Exec=/usr/bin/steam -silent -vrdisable -deckard %U' \
  >"$R/etc/xdg/autostart/steam.desktop"
for s in plasmax11.desktop openbox.desktop openbox-kde.desktop; do
  echo old >"$R/usr/share/xsessions/$s"
done

if [[ ! -x "$APPLY" ]]; then
  fail "脚本存在" "没有可执行的 $APPLY"
  echo; echo "${fails} 条断言失败"; exit 1
fi

out="$("$APPLY" "$R" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || fail "首次运行" "退出码 $rc: ${out:0:300}"

# 1. Session entry and the scripts it calls.
PLASMA="$R/usr/share/wayland-sessions/plasma.desktop"
grep -q '^Exec=/usr/lib/steamos/sm8550-startplasma' "$PLASMA" \
  && pass "plasma.desktop" "Exec 指向 sm8550-startplasma" \
  || fail "plasma.desktop" "没有指向 sm8550-startplasma"
grep -q 'sm8550-prepare-plasma' "$R/usr/bin/steamos-session-select" \
  && pass "session-select" "切换前调用 sm8550-prepare-plasma" \
  || fail "session-select" "没有 prepare-plasma"

for f in \
  usr/lib/steamos/desktop-outputs \
  usr/lib/steamos/sm8550-prepare-plasma \
  usr/lib/steamos/sm8550-startplasma \
  usr/lib/steamos/desktop-steam \
  usr/lib/steamos-arm/desktop-fit \
  usr/lib/steamos-arm/desktop-portal-fix \
  usr/bin/steamos-session-select; do
  [[ -x "$R/$f" ]] && pass "可执行 $f" "存在且可执行" || fail "可执行 $f" "缺失或不可执行"
done

# 2. The manual desktop-outputs must know about the Kishi flip marker.
grep -q '99-orientation.conf' "$OVL/usr/lib/steamos/desktop-outputs" \
  && grep -q 'OPPOSITE' "$OVL/usr/lib/steamos/desktop-outputs" \
  && pass "Kishi 翻转" "desktop-outputs 会按 99-orientation.conf 反转 transform" \
  || fail "Kishi 翻转" "desktop-outputs 没有 flip marker 逻辑"
grep -q 'KISHI_TOUCH_MATRIX' "$OVL/usr/lib/steamos/desktop-outputs" \
  && grep -q 'BASE_TOUCH_MATRIX' "$OVL/usr/lib/steamos/desktop-outputs" \
  && grep -q 'CalibrationMatrix' "$OVL/usr/lib/steamos/desktop-outputs" \
  && pass "Kishi 触摸校准" "翻转=identity，无翻转=180°；Game Mode 仍用 udev" \
  || fail "Kishi 触摸校准" "desktop-outputs 没有两种 orientation 的 Desktop 触摸矩阵"

# 3. Plasma environment service and drop-ins.
[[ -f "$R/usr/lib/systemd/user/sm8550-plasma-env.service" ]] \
  && pass "plasma env service" "sm8550-plasma-env.service 已装" \
  || fail "plasma env service" "缺少 sm8550-plasma-env.service"
for t in plasma-core.target plasma-workspace.target plasma-workspace-wayland.target; do
  [[ -f "$R/usr/lib/systemd/user/$t.d/99-odin.conf" ]] \
    || fail "target drop-in $t" "缺少 99-odin.conf"
done
[[ -f "$R/usr/lib/systemd/user/plasma-plasmashell.service.d/99-odin-wayland.conf" ]] \
  && grep -q 'QT_QPA_PLATFORM=wayland' \
       "$R/usr/lib/systemd/user/plasma-plasmashell.service.d/99-odin-wayland.conf" \
  && pass "plasmashell drop-in" "Wayland 环境已设置" \
  || fail "plasmashell drop-in" "缺少或内容不对"

# 4. Desktop Steam autostart and portal fix.
grep -q '^Exec=/usr/lib/steamos/desktop-steam ' "$R/etc/xdg/autostart/steam.desktop" \
  && pass "Steam autostart" "Exec 改为 desktop-steam" \
  || fail "Steam autostart" "没有改为 desktop-steam"
[[ -f "$R/etc/xdg/autostart/steamos-arm-desktop-portal-fix.desktop" ]] \
  && [[ -f "$R/var/lib/overlays/etc/upper/xdg/autostart/steamos-arm-desktop-portal-fix.desktop" ]] \
  && pass "portal fix" "lower 与 upper 都有" \
  || fail "portal fix" "缺少 autostart 文件"

# 4b. Return to Gaming Mode shortcut.
RETURN="$R/etc/skel/Desktop/Return.desktop"
if grep -q 'Return to Gaming Mode' "$RETURN" 2>/dev/null \
   && grep -q 'steamosctl switch-to-game-mode' "$RETURN" \
   && grep -q 'steamos-session-select gamescope' "$RETURN"; then
  pass "返回 Game Mode 快捷方式" "Return.desktop 有两条切换路径"
else
  fail "返回 Game Mode 快捷方式" "Return.desktop 缺失或内容不对"
fi
[[ -x "$R/etc/xdg/plasma-workspace/env/set-return-icon.sh" ]] \
  && grep -q '/etc/skel/Desktop/Return.desktop' \
       "$R/etc/xdg/plasma-workspace/env/set-return-icon.sh" \
  && pass "桌面图标脚本" "set-return-icon.sh 可执行并复制 Return.desktop" \
  || fail "桌面图标脚本" "set-return-icon.sh 缺失或不可执行"
[[ -f "$R/usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg" ]] \
  && pass "返回图标" "steamos-gamemode.svg 已装" \
  || fail "返回图标" "缺少 steamos-gamemode.svg"
[[ -f "$R/usr/share/applications/steamos-gamemode.desktop" ]] \
  && pass "应用菜单项" "steamos-gamemode.desktop 已装" \
  || fail "应用菜单项" "缺少 applications/steamos-gamemode.desktop"
[[ -f "$R/var/lib/overlays/etc/upper/skel/Desktop/Return.desktop" \
   && -f "$R/var/lib/overlays/etc/upper/xdg/plasma-workspace/env/set-return-icon.sh" ]] \
  && pass "快捷方式进 upper" "skel + plasma env 都镜像到 /etc upper" \
  || fail "快捷方式进 upper" "upper 缺少 Return.desktop 或 set-return-icon.sh"

# 5. X11 sessions hidden.
for s in plasmax11.desktop openbox.desktop openbox-kde.desktop; do
  [[ ! -e "$R/usr/share/xsessions/$s" && -e "$R/usr/share/steamos/hidden-xsessions/$s" ]] \
    || fail "隐藏 X11 $s" "仍在 xsessions 或没进 hidden-xsessions"
done
pass "隐藏 X11 会话" "plasmax11/openbox 已移出 xsessions"

# 6. Legacy layout and backups.
[[ -f "$R/usr/share/steamos-arm/kwinoutputconfig.legacy.json" ]] \
  && pass "KWin legacy layout" "kwinoutputconfig.legacy.json 已装" \
  || fail "KWin legacy layout" "缺少 legacy json"
for f in \
  usr/share/wayland-sessions/plasma.desktop \
  usr/bin/steamos-session-select \
  etc/xdg/autostart/steam.desktop; do
  [[ -f "$R/var/lib/steamos-arm-stock/$f" ]] \
    || fail "原件备份 $f" "没有备份"
done
pass "原件备份" "plasma.desktop / session-select / steam.desktop 都在 stock"

# 7. Idempotency.
before="$(cd "$R" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"
out2="$("$APPLY" "$R" 2>&1)"; rc2=$?
after="$(cd "$R" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"
if [[ $rc2 -eq 0 && "$before" == "$after" ]]; then
  pass "幂等" "第二次运行退出 0，文件内容不变"
else
  fail "幂等" "第二次退出 $rc2，内容变了: ${out2:0:200}"
fi

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
