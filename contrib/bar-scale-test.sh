#!/usr/bin/env bash
# bar-scale-test.sh — the bar honours DISPLAY scaling, and nothing else.
#
# Every size in this shell is a Wayland LOGICAL pixel. The compositor
# multiplies a layer surface by its output's `scale`, so a bar that is the same
# number of logical pixels everywhere is a bar that is physically the size the
# user's own scale setting asked for on every screen -- and the same size as
# the compositor's titlebars beside it, because those are scaled by the same
# number.
#
# This file used to assert the opposite: the bar carried a factor of its own,
# each output's logical height over the tallest output's, so it was a fixed
# FRACTION of every screen. Two things were wrong with that. It measured
# logical heights, which already contain the scale, so it partly undid the
# scaling it sat on top of; and the reference was the whole desktop's, so
# changing ONE monitor's scale resized the bar on every other monitor -- put
# DP-1 on 1.75 and the bar on an untouched HDMI-A-1 grew by half.
#
# So: same logical height on outputs of different shapes, unaffected by a
# neighbour's scale, and sized from the theme font. All three fail on the build
# before this one, and the second one is the bug that was reported.
#
# Measured in grim's pixels, which are the output's REAL ones -- the test
# asserts that first rather than assuming it, because the whole argument rests
# on which units the capture is in. Real pixels are the useful ones here: they
# are what the eye gets, so "honours the scale" becomes an arithmetic claim
# about the capture rather than something inferred.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "bar-scale-test: not built -- meson setup build && meson compile -C build" >&2
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
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

hl_dispatch "create_virtual_output" 1
sleep 2
MONS="$(hl_get "get all-monitors" | jq -r '.monitors[].name' | sort)"
SECOND="$(printf '%s\n' "$MONS" | grep -v "^$HL_MON\$" | head -1)"
if [ -z "$SECOND" ]; then
	echo "  ..   skipped: no second output"
	exit 0
fi

CONF_BASE="$(cat "$HL_CONFIG")"

# Reconfigure both outputs and reload. The second one's SCALE is the variable
# this test moves; its mode never changes, so any difference downstream is the
# scale and nothing else.
set_outputs() { # set_outputs <second-scale> <theme-font>
	{
		printf '%s\n' "$CONF_BASE"
		printf 'theme { font "%s"; border-width 0; corner-radius 8 }\n' "$2"
		printf 'output %s { width 1920; height 1080; refresh 60; x 0; y 0; scale 1 }\n' "$HL_MON"
		printf 'output %s { width 1920; height 1080; refresh 60; x 2400; y 0; scale %s }\n' "$SECOND" "$1"
	} > "$HL_CONFIG"
	hl_dispatch "reload_config" 2
	sleep 2
}

mon_field() { # mon_field <name> <jq field>
	hl_get "get all-monitors" | jq -r --arg m "$1" ".monitors[] | select(.name==\$m) | .$2"
}

shot() { grim -o "$1" "$WORK/$2.png" 2>/dev/null; }

# The bar's panel height in that capture, found rather than assumed: the margin
# above the panel is transparent, so counting from row zero measures margin as
# bar. Only the right-hand fifth is scanned, which is where this test's one
# module sits; the rest of the bar surface is transparent and a full-width scan
# once measured a window shadow on one screen and the panel on the other.
bar_height() { # bar_height <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); W, H = im.size
x0 = int(W * 0.70)
def panelish(y):
    return sum(1 for x in range(x0, W) if sum(px[x, y]) < 300) >= 30
run = best = 0
for y in range(0, min(240, H)):
    if panelish(y):
        run += 1
        best = max(best, run)
    else:
        run = 0
print(best)
PY
}

shot_size() { python3 -c "from PIL import Image;i=Image.open('$WORK/$1.png');print('%d %d'%i.size)"; }

# A clock on the right of both, and NO bar { height } anywhere: the height under
# test is the one the shell derives from the theme font.
bar_conf "" "" "clock" <<EOF
$(bar_conf_panel)
EOF

set_outputs 1.5 "Ubuntu 16"

setsid env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
BARPID=$!
trap 'kill "$BARPID" 2>/dev/null; hl_stop' EXIT
sleep 10

A_LOG_H="$(mon_field "$HL_MON" height)"
B_LOG_H="$(mon_field "$SECOND" height)"
echo "  ..   $HL_MON scale 1 -> ${A_LOG_H} logical rows, $SECOND scale 1.5 -> ${B_LOG_H}"

if [ "${B_LOG_H:-0}" -lt "${A_LOG_H:-0}" ]; then
	ok "the second output's scale really shrank its logical size ($B_LOG_H < $A_LOG_H)"
else
	bad "the second output's scale really shrank its logical size ($B_LOG_H vs $A_LOG_H)"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

shot "$HL_MON" a1
shot "$SECOND" b1
read -r SW SH <<< "$(shot_size b1)"
# The units the rest of this test is stated in. Both outputs run the same
# 1920x1080 mode, so a capture the size of the MODE rather than of the logical
# extent is a capture in real pixels.
B_MODE_H=1080  # what set_outputs asked both outputs for
if [ "$SH" = "$B_MODE_H" ] && [ "$SH" != "$B_LOG_H" ]; then
	ok "captures are in real pixels (${SW}x${SH} for a ${B_LOG_H}-row logical output)"
else
	bad "captures are in real pixels (${SW}x${SH}, mode ${B_MODE_H}, logical ${B_LOG_H})"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

A1="$(bar_height a1)"
B1="$(bar_height b1)"
echo "  ..   bar is ${A1} real rows on $HL_MON (scale 1), ${B1} on $SECOND (scale 1.5)"

if [ "${A1:-0}" -gt 12 ] && [ "${B1:-0}" -gt 12 ]; then
	ok "a bar is drawn on both outputs"
else
	bad "a bar is drawn on both outputs (${A1} and ${B1})"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# The claim, in the plainest form it has. The two outputs run the same mode and
# differ only in scale, so the bar's real height has to differ by exactly that
# scale: 1.5x, within a pixel of rounding.
#
# The old build failed this by landing on 1.0x -- its own factor cancelled the
# scale almost exactly, which is the whole complaint.
WANT=$(( A1 * 3 / 2 ))
D=$(( B1 - WANT )); [ "$D" -lt 0 ] && D=$(( -D ))
if [ "$D" -le 2 ]; then
	ok "a 1.5x output draws a 1.5x bar (${A1} -> ${B1}, wanted ~${WANT})"
else
	bad "a 1.5x output draws a 1.5x bar (${A1} -> ${B1}, wanted ~${WANT})"
fi

# The reported bug. Nothing about the first output changes here; only the
# second one's scale does. The old per-desktop reference made this move.
set_outputs 0.5 "Ubuntu 16"
shot "$HL_MON" a2
A2="$(bar_height a2)"
echo "  ..   after putting $SECOND on scale 0.5, $HL_MON's bar is ${A2} (was ${A1})"

if [ "${A2:-0}" = "${A1:-0}" ]; then
	ok "changing one output's scale leaves the other's bar alone (${A1} -> ${A2})"
else
	bad "changing one output's scale leaves the other's bar alone (${A1} -> ${A2})"
fi

# And the one knob that IS meant to resize it.
set_outputs 1.5 "Ubuntu 28"
shot "$HL_MON" a3
A3="$(bar_height a3)"
echo "  ..   at Ubuntu 28 the bar is ${A3} (was ${A1} at Ubuntu 16)"

if [ "${A3:-0}" -gt "$(( A1 + 8 ))" ]; then
	ok "a bigger theme font makes a taller bar (${A1} -> ${A3})"
else
	bad "a bigger theme font makes a taller bar (${A1} -> ${A3})"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
