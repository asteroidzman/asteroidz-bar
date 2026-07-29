#!/usr/bin/env bash
# click-test.sh — drive the real bar with a real pointer.
#
# Everything else in contrib/ checks what the bar DRAWS. This checks what it
# does when clicked, which is the half that kept shipping broken: a popover
# that could not be dismissed, a picker that applied a mode per click, a
# wallpaper that was written to disk and never put up. Each of those was
# "verified" by reading the QML, and each was wrong.
#
# The pointer is wlvptr (zwlr_virtual_pointer_v1) against the headless
# compositor, so these are ordinary pointer events as far as the bar knows.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "click-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null

WORK="$HL_OUTDIR"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# A bar with exactly one module in it, on the right, so its pill is at a
# position this script can compute rather than hunt for.
cp "$HL_CONFIG" "$WORK/config.pristine.kdl"
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "display" }
EOF
hl_dispatch "reload_config" 1
sleep 1

dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 8

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# How much of the screen below the bar is not wallpaper? A popover is the only
# thing that can be there, so this is "is a panel open", as a number.
panel_pixels() { # panel_pixels <shot>
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
        # the wallpaper is #9db8d8; a panel is much darker
        if r + g + b < 400:
            n += 1
print(n)
PY
}

# The display pill: the only module, so it is at the right edge of the right
# panel, one pill-height down.
PILL_X=$((HL_WIDTH - 8 - 12 - 18))
PILL_Y=$((9 + 24))

shot idle
IDLE="$(panel_pixels idle)"

# Move first. A press delivered without a preceding motion event does not
# hit-test -- the very first click of the session was landing nowhere while
# every later one worked, which reads as "the pill is dead" rather than "the
# pointer had never entered the surface".
hl_move "$PILL_X" "$PILL_Y"
sleep 1
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot opened
OPENED="$(panel_pixels opened)"

if [ "$OPENED" -gt $((IDLE + 400)) ]; then
	ok "clicking the display pill opens its panel ($IDLE -> $OPENED px)"
else
	bad "clicking the display pill opens its panel ($IDLE -> $OPENED px)"
fi

# Escape closes it.
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 2
shot escaped
ESCAPED="$(panel_pixels escaped)"
if [ "$ESCAPED" -lt $((IDLE + 400)) ]; then
	ok "Escape closes it ($OPENED -> $ESCAPED px)"
else
	bad "Escape closes it ($OPENED -> $ESCAPED px)"
fi

# Open it again, then click the pill a second time: that must close it.
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot reopened
REOPENED="$(panel_pixels reopened)"
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot toggled
TOGGLED="$(panel_pixels toggled)"
if [ "$REOPENED" -gt $((IDLE + 400)) ] && [ "$TOGGLED" -lt $((IDLE + 400)) ]; then
	ok "clicking the same pill closes it ($REOPENED -> $TOGGLED px)"
else
	bad "clicking the same pill closes it ($REOPENED -> $TOGGLED px)"
fi

# And a click well away from everything closes it.
hl_click "$PILL_X" "$PILL_Y"
sleep 2
hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200))
sleep 2
shot away
AWAY="$(panel_pixels away)"
if [ "$AWAY" -lt $((IDLE + 400)) ]; then
	ok "clicking away closes it ($AWAY px)"
else
	bad "clicking away closes it ($AWAY px)"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
