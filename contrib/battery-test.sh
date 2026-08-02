#!/usr/bin/env bash
# battery-test.sh — the battery module, on a machine with no battery.
#
# This desktop has none: /sys/class/power_supply is empty and upower exposes only
# its synthetic DisplayDevice. A module that can only be exercised on other
# hardware is a module nobody checks, so Battery.qml takes its base directory
# from ASTEROIDZ_BAR_BATTERY_DIR and this writes one.
#
# Two claims, and the first matters more:
#
#   1. with no battery the pill is ABSENT -- not empty, not 0%, not a full cell.
#      A desktop drawing a permanently full battery is saying something false
#      about hardware it does not have.
#   2. with a battery it draws the level, and follows it up and down.
#
# Sysfs is two small files (`capacity`, `status`) and the module reloads them on
# the bar's own tick, so a plain directory of plain files is a faithful stand-in:
# nothing here fakes an interface the kernel does not have.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "battery-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null

WORK="$HL_OUTDIR"

# How the bar looks is the bar's own setting now; a test writes it here.
# shellcheck disable=SC1091
. "$HERE/contrib/lib/barconf.sh"
BAR_CONF="$(bar_conf_path)"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# One module, at the right edge, so its pill is where this script can compute it.
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "" "" "battery" <<EOF
$(bar_conf_panel)
bar { interval 1 }
EOF
hl_dispatch "reload_config" 1

# An EMPTY power-supply directory: a desktop, exactly as this machine is.
BATDIR="$WORK/power_supply"
mkdir -p "$BATDIR"

start_bar() {
	setsid dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_BATTERY_DIR="$BATDIR" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		"$HERE/bin/asteroidz-bar" > "$WORK/qs$1.log" 2>&1 &
	echo $!
}

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# The pill's INK: its glyphs and its artwork, in the right-hand end of the bar.
#
# Not "everything that is not the wallpaper", which is what this counted first.
# The shell draws its panel whether or not there is a pill in it, so an empty
# panel measured 2910 px and "the pill is absent" failed against a bar that was
# correctly showing nothing. The panel is a flat dark fill; a pill's label and
# icon are near-white. Brightness is the difference between a container and
# something in it.
bar_ink() { # bar_ink <shot>
	python3 - "$WORK/$1.png" "$HL_WIDTH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
w = int(sys.argv[2])
# The right third of the bar strip. The bar is height + 2 * margin_y tall
# (48 + 18) and everything below it is wallpaper.
x0, x1 = int(w * 0.66), min(w, im.size[0])
n = 0
for y in range(9, 66):
    for x in range(x0, x1):
        r, g, b = px[x, y]
        # Brighter than the panel and than the wallpaper both: only a glyph or a
        # tinted icon is up here.
        if 0.299 * r + 0.587 * g + 0.114 * b > 200:
            n += 1
print(n)
PY
}

QS="$(start_bar 1)"
sleep 8

if grep -qE 'is not a type|unavailable|Cannot override|set multiple times' \
		"$WORK/qs1.log"; then
	bad "the shell loads without QML errors"
	grep -E 'is not a type|unavailable|Cannot override|set multiple times' \
		"$WORK/qs1.log" | head -5 | sed 's/^/       /'
else
	ok "the shell loads without QML errors"
fi

shot nobattery
NONE_INK="$(bar_ink nobattery)"
if [ "${NONE_INK:-0}" -lt 40 ]; then
	ok "with no battery the pill is absent (${NONE_INK} px)"
else
	bad "with no battery the pill is absent (${NONE_INK} px)"
fi

bar_session_kill "$QS"

# ── now give the machine a battery ──────────────────────────────────────────
#
# The bar is RESTARTED rather than left running, and that is the module's own
# documented limit rather than a convenience: Paths.resolve caches its answer,
# misses included, so a battery that appears after startup is not noticed. A
# laptop having its cell replaced is not worth a filesystem scan every tick.
mkdir -p "$BATDIR/BAT0"
echo 64 > "$BATDIR/BAT0/capacity"
echo "Discharging" > "$BATDIR/BAT0/status"

QS="$(start_bar 2)"
sleep 8

shot discharging
SOME_INK="$(bar_ink discharging)"
if [ "${SOME_INK:-0}" -gt $((NONE_INK + 100)) ]; then
	ok "with a battery the pill appears (${NONE_INK} -> ${SOME_INK} px)"
else
	bad "with a battery the pill appears (${NONE_INK} -> ${SOME_INK} px)"
fi

# The reading, not just the presence. 64% and 8% are different numbers of glyphs
# and different icons, so the pill's ink changes -- and the direction is known:
# fewer digits and a shorter fill bar is less ink.
echo 8 > "$BATDIR/BAT0/capacity"
sleep 4
shot low
LOW_INK="$(bar_ink low)"
if [ "${LOW_INK:-0}" -gt 40 ] && [ "${LOW_INK}" -ne "${SOME_INK}" ]; then
	ok "the pill follows the reading (${SOME_INK} -> ${LOW_INK} px at 8%)"
else
	bad "the pill follows the reading (${SOME_INK} -> ${LOW_INK} px at 8%)"
fi

# Charging is a different glyph again, at the same percentage -- so this isolates
# the status from the level.
echo "Charging" > "$BATDIR/BAT0/status"
sleep 4
shot charging
CHG_INK="$(bar_ink charging)"
if [ "${CHG_INK:-0}" -gt 40 ] && [ "${CHG_INK}" -ne "${LOW_INK}" ]; then
	ok "charging draws differently from discharging (${LOW_INK} -> ${CHG_INK} px)"
else
	bad "charging draws differently from discharging (${LOW_INK} -> ${CHG_INK} px)"
fi

bar_session_kill "$QS"

if [ -n "${ASTEROIDZ_SHOT_DIR:-}" ]; then
	mkdir -p "$ASTEROIDZ_SHOT_DIR"
	cp "$WORK"/*.png "$ASTEROIDZ_SHOT_DIR/" 2>/dev/null
	echo "  ..   shots in $ASTEROIDZ_SHOT_DIR"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
