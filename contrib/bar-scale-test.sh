#!/usr/bin/env bash
# bar-scale-test.sh — the bar is the same FRACTION of every screen.
#
# A size that is one number for the whole desktop is right only while every
# output is the same shape. Put a 3840x2160 output beside a 1920x1080 at scale
# 0.75 — logical 2560x1440 — and a 48px bar is 2.2% of the first screen's
# height and 3.3% of the second's: the same pixels, half again as much screen,
# and it reads as a bar that is too big on the smaller monitor.
#
# So the bar is measured on two outputs of different heights and the two
# fractions are compared. Not the pixel heights: a bar that is the same number
# of pixels everywhere is precisely the bug.
#
# Two outputs of 1080 and 720 rather than a scale difference, because the
# arithmetic is the same — Sizes.factor is logical height over the tallest
# logical height, and a scale is only one of the things that changes it — and a
# headless output takes a height without needing the scale plumbing to work
# first. The factor here is 720/1080, the same 0.667 that a 0.75-scaled 1080p
# panel produces beside a 4K one.
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

# The short one. 720 against 1080 is a factor of 0.667.
cat >> "$HL_CONFIG" <<CONF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8 }
output $SECOND { width 1280; height 720; refresh 60; x 2400; y 0 }
CONF
hl_dispatch "reload_config" 1
sleep 2

TALL_H="$(hl_get "get all-monitors" | jq -r --arg m "$HL_MON" '.monitors[] | select(.name==$m) | .height')"
SHORT_H="$(hl_get "get all-monitors" | jq -r --arg m "$SECOND" '.monitors[] | select(.name==$m) | .height')"
echo "  ..   $HL_MON is ${TALL_H}px tall, $SECOND is ${SHORT_H}px"

if [ "${SHORT_H:-0}" -lt "${TALL_H:-0}" ]; then
	ok "the second output really is shorter ($SHORT_H < $TALL_H)"
else
	bad "the second output really is shorter ($SHORT_H vs $TALL_H)"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# A clock on the right of both, so there is ink to find on each screen.
bar_conf "" "" "clock" <<EOF
$(bar_conf_panel)
bar { height 48; margin-x 8; margin-y 9 }
EOF

setsid env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
BARPID=$!
sleep 10

grim -o "$HL_MON" "$WORK/tall.png" 2>/dev/null
grim -o "$SECOND" "$WORK/short.png" 2>/dev/null

# The bar's panel height, in that screenshot's own pixels.
#
# Measured as the contiguous band of panel-coloured rows at the top, found
# rather than assumed: the margin above the panel is transparent, so counting
# from row zero would measure the margin as bar.
bar_height() { # bar_height <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); W, H = im.size
# The right-hand fifth, because that is where this test puts its one module
# and the rest of the bar surface is transparent. Scanning the FULL width for
# any dark row measured a window's shadow on one screen and the panel on the
# other, and the two disagreed for a reason that had nothing to do with
# scaling.
# An absolute width, not a fraction of the scan window. The pill is about
# 105px wide on the tall screen and the fraction threshold worked out at 106,
# so it failed by a single column and reported no bar at all.
x0 = int(W * 0.70)
def panelish(y):
    n = sum(1 for x in range(x0, W) if sum(px[x, y]) < 300)
    return n >= 30
run = best = 0
for y in range(0, min(200, H)):
    if panelish(y):
        run += 1
        best = max(best, run)
    else:
        run = 0
print(best)
PY
}

TALL_BAR="$(bar_height tall)"
SHORT_BAR="$(bar_height short)"
echo "  ..   bar is ${TALL_BAR}px on $HL_MON, ${SHORT_BAR}px on $SECOND"

kill "$BARPID" 2>/dev/null

if [ "${TALL_BAR:-0}" -gt 20 ] && [ "${SHORT_BAR:-0}" -gt 10 ]; then
	ok "a bar is drawn on both outputs"
else
	bad "a bar is drawn on both outputs (${TALL_BAR}px and ${SHORT_BAR}px)"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# The claim. Same fraction of the screen, within a pixel of rounding either way.
#
# Expressed in tenths of a percent so shell arithmetic can compare it.
TALL_FRAC=$(( TALL_BAR * 1000 / TALL_H ))
SHORT_FRAC=$(( SHORT_BAR * 1000 / SHORT_H ))
DELTA=$(( TALL_FRAC - SHORT_FRAC )); [ "$DELTA" -lt 0 ] && DELTA=$(( -DELTA ))

if [ "$DELTA" -le 3 ]; then
	ok "the bar is the same fraction of both screens (${TALL_FRAC}‰ vs ${SHORT_FRAC}‰)"
else
	bad "the bar is the same fraction of both screens (${TALL_FRAC}‰ vs ${SHORT_FRAC}‰)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
