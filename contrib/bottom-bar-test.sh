#!/usr/bin/env bash
# bottom-bar-test.sh — a popover hangs off its pill on BOTH bar positions.
#
# Bar.qml anchored every popup Edges.Bottom/Edges.Bottom unconditionally --
# top-bar arithmetic -- and Popover.qml pinned the panel to the top of its
# fixed-height surface. On `bar { position "bottom" }` the popup therefore
# opened downward into the screen edge, the compositor's constraint adjustment
# relocated the surface, and the panel ended up floating mid-screen, a whole
# surface-height away from the pill that opened it.
#
# So this drives the power pill on both positions and asserts GEOMETRY, not
# just presence: the panel must sit adjacent to the bar it belongs to, on the
# correct side.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "bottom-bar-test: not built -- meson setup build && meson compile -C build" >&2
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
BAR_XDG="$(bar_xdg_home)"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cp "$HL_CONFIG" "$WORK/config.pristine.kdl"
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
hl_dispatch "reload_config" 1
sleep 1

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# The bounding box of dark (panel) pixels inside a vertical band, excluding
# both possible bar strips. Prints "ymin ymax count".
panel_box() { # panel_box <shot> <y0> <y1>
	python3 - "$WORK/$1.png" "$2" "$3" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
w, h = im.size
y0, y1 = int(sys.argv[2]), int(sys.argv[3])
ys = []
n = 0
for y in range(y0, min(y1, h)):
    row = 0
    for x in range(0, w, 2):
        r, g, b = px[x, y]
        if r + g + b < 400:
            row += 1
    if row > 10:
        ys.append(y)
        n += row
print(ys[0] if ys else -1, ys[-1] if ys else -1, n)
PY
}

launch_bar() {
	setsid $(bar_limits) dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		"$HERE/bin/asteroidz-bar" > "$WORK/qs-$1.log" 2>&1 &
	QS=$!
	sleep 8
}

# The power pill is the only module, on the right -- same arithmetic as
# click-test.sh. The bar strip is ~48px tall with a 9px margin.
PILL_X=$((HL_WIDTH - 8 - 12 - 18))
BAR_BAND=110   # everything at y<110 (top) / y>H-110 (bottom) is bar territory

# ── top bar ─────────────────────────────────────────────────────────────────
bar_conf "" "" "power" <<EOF
$(bar_conf_panel)
EOF
launch_bar top

PILL_Y=$((9 + 24))
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 2
shot top-open
read -r YMIN YMAX COUNT <<< "$(panel_box top-open "$BAR_BAND" $((HL_HEIGHT - BAR_BAND)))"

if [ "$COUNT" -gt 400 ]; then
	ok "top bar: the menu opened ($COUNT px)"
else
	bad "top bar: the menu opened ($COUNT px)"
fi
# Adjacent below the bar: the panel's top edge is within the shadow's reach of
# the strip, and the whole panel sits in the top half of the screen.
if [ "$YMIN" -ge "$BAR_BAND" ] && [ "$YMIN" -le 220 ] \
	&& [ "$YMAX" -le $((HL_HEIGHT / 2)) ]; then
	ok "top bar: the panel hangs just below the bar (y $YMIN..$YMAX)"
else
	bad "top bar: the panel hangs just below the bar (y $YMIN..$YMAX)"
fi

bar_session_kill "$QS"
sleep 2

# ── bottom bar ──────────────────────────────────────────────────────────────
bar_conf "" "" "power" <<EOF
$(bar_conf_panel)
bar { position "bottom" }
EOF
launch_bar bottom

PILL_Y=$((HL_HEIGHT - 9 - 24))
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 2
shot bottom-open
read -r YMIN YMAX COUNT <<< "$(panel_box bottom-open "$BAR_BAND" $((HL_HEIGHT - BAR_BAND)))"

if [ "$COUNT" -gt 400 ]; then
	ok "bottom bar: the menu opened ($COUNT px)"
else
	bad "bottom bar: the menu opened ($COUNT px)"
fi
# Adjacent ABOVE the bar: the panel's bottom edge is within the shadow's reach
# of the strip, and the whole panel sits in the bottom half of the screen --
# which is exactly what the unconditional top-bar anchor failed: the panel
# came out pinned to the top of a screen-tall surface, mid-air.
if [ "$YMAX" -le $((HL_HEIGHT - BAR_BAND)) ] \
	&& [ "$YMAX" -ge $((HL_HEIGHT - 220)) ] \
	&& [ "$YMIN" -ge $((HL_HEIGHT / 2)) ]; then
	ok "bottom bar: the panel stands just above the bar (y $YMIN..$YMAX)"
else
	bad "bottom bar: the panel stands just above the bar (y $YMIN..$YMAX)"
fi

# Escape still works down there.
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 1
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 2
shot bottom-escaped
read -r _ _ AFTER <<< "$(panel_box bottom-escaped "$BAR_BAND" $((HL_HEIGHT - BAR_BAND)))"
if [ "$AFTER" -lt 400 ]; then
	ok "bottom bar: Escape closes it ($COUNT -> $AFTER px)"
else
	bad "bottom bar: Escape closes it ($COUNT -> $AFTER px)"
fi

bar_session_kill "$QS"

echo
echo "bottom-bar-test: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
