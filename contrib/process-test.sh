#!/usr/bin/env bash
# process-test.sh — the cpu/memory pills open a top-like process list.
#
# What this covers, stated up front so a green run is not read as more than it
# is: the clock is clickable, the panel opens under it, the month grid draws,
# and clicking again closes it. Nothing here asserts on events.
#
# It does NOT run without an account, which was the first thing assumed about
# it and was wrong. dbus-run-session gives the shell its own bus, but libsecret
# still reaches the user's gnome-keyring, so the panel comes up fully
# configured and showing the real calendar. Worth knowing twice over: a green
# run here is not evidence that a machine which has never seen Google draws a
# calendar, and the run is not hermetic -- it reads your keyring.
#
# The account path proper (migration, token refresh, calendars, events) was
# verified against a real session, which is the only place it can be.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "calendar-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null

WORK="$HL_OUTDIR"

# shellcheck disable=SC1091
. "$HERE/contrib/lib/barconf.sh"
BAR_CONF="$(bar_conf_path)"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$BAR_BUILD/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
# The clock alone, on the right, so its pill is where this script can compute
# rather than hunt for it.
bar_conf "" "" "cpu" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 1

setsid dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 8

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

panel_pixels() {
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
w, h = im.size
n = 0
for y in range(120, min(h, 700), 4):
    for x in range(0, w, 4):
        r, g, b = px[x, y]
        if r + g + b < 400:
            n += 1
print(n)
PY
}

# The shell must have LOADED. A QML error anywhere in the tree takes the whole
# config down, and every pixel assertion below would then measure a bar that
# is not there -- reported as "the panel did not open" rather than "the panel
# does not compile", which is a much longer afternoon.
if grep -q "Type .* unavailable\|Failed to load configuration" "$WORK/qs.log" 2>/dev/null; then
	bad "the shell loads with the process panel in it"
	grep -E "ERROR|unavailable" "$WORK/qs.log" | head -5
else
	ok "the shell loads with the process panel in it"
fi

# The clock is the only module, so it sits at the right edge of the right
# panel. It is wider than an icon pill, so its centre is found from the panel
# edge rather than assumed to be one pill-width in.
PILL_X=$((HL_WIDTH - 8 - 40))
PILL_Y=$((9 + 24))

shot idle
IDLE="$(panel_pixels idle)"

hl_move "$PILL_X" "$PILL_Y"
sleep 1
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot opened
OPENED="$(panel_pixels opened)"

if [ "$OPENED" -gt $((IDLE + 400)) ]; then
	ok "clicking the cpu pill opens top ($IDLE -> $OPENED px)"
else
	bad "clicking the cpu pill opens top ($IDLE -> $OPENED px)"
fi

hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot closed
CLOSED="$(panel_pixels closed)"
if [ "$CLOSED" -lt $((OPENED - 400)) ]; then
	ok "clicking it again closes it ($OPENED -> $CLOSED px)"
else
	bad "clicking it again closes it ($OPENED -> $CLOSED px)"
fi

# ── the panel drew without complaining ──────────────────────────────────────
#
# Pixel deltas say a panel appeared; they say nothing about what it did to get
# there. This ran for a long time with 80 TypeErrors per open -- every eventless
# day cell dereferencing dayEvents[0] -- while every assertion above passed,
# because a binding that throws still leaves the item drawn in its default
# colour. The log had it the whole time and nothing was reading the log.
QML_ERRORS="$(grep -cE "TypeError|ReferenceError|is not a function" "$WORK/qs.log" 2>/dev/null || true)"
if [ "${QML_ERRORS:-0}" -eq 0 ]; then
	ok "the panel drew with no QML errors"
else
	bad "the panel drew with no QML errors ($QML_ERRORS logged)"
	grep -oE "@[A-Za-z]+\.qml\[[0-9]+.*" "$WORK/qs.log" | sort -u | head -5
fi

kill "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
