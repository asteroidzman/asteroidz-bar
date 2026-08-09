#!/usr/bin/env bash
# toast-shadow-test.sh — a toast's shadow fades out instead of being cut off.
#
# A notification popup is a layer-shell surface, and a layer surface can only
# paint inside itself. So the surface has to be bigger than the cards by however
# far the shadow reaches, or the outer part of the shadow is simply not drawn
# and the toast sits in a hard-edged dark rectangle.
#
# `NotificationPopups.shadowRoom` reserved `shadow-size + blur`. The shadow
# reaches `shadow-size + 2 * blur` -- solid out to the size, then a gaussian
# falloff spent by about two sigma, which is the arithmetic `Panel.qml`'s own
# `reach` uses and the room `Bar.qml` and `Popover.qml` reserve. One sigma
# short means the outer half of the falloff is clipped, and the half that
# survives is the half still dark enough to see the edge of.
#
# Measured as the biggest single-pixel STEP along a row running out of the
# card's left side across the shadow. A shadow that fades has no step -- it is
# a gaussian, so the largest change between neighbouring pixels is small. A
# shadow cut off at the surface edge has exactly one big one, at the cut.
#
# The wallpaper is flat and dark on purpose: a striped or photographic backdrop
# has steps of its own everywhere and the measurement means nothing.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "toast-shadow-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# The COMPOSITOR's shadow on layer surfaces is turned off, so what is measured
# here is the shell's own card shadow and nothing else. With it on there are two
# shadows -- one around the whole surface, one around each card -- and they meet
# at the surface edge with a step of their own, which swamps this measurement
# and is a separate matter. It is off in the live config too.
export HL_EXTRA_KDL="${HL_EXTRA_KDL:-}
layer_shadows 0"

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

# Flat, and dark enough that a black shadow over it still has somewhere to go.
magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#3c4654' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

CARD_W=380
bar_conf "" "" "notify" <<EOF
panel { enable #true; radius 9; padding 12; blur #false; shadow #true }
bar { height 48; margin-x 8; margin-y 9 }
notify { width $CARD_W }
EOF

# The bar and the Notify call have to share ONE bus. Launching the bar under
# `dbus-run-session` and then calling gdbus from out here talks to a different
# bus entirely: the toast is never delivered, nothing is drawn, and the
# measurement reads bare wallpaper. Same inner-script shape as
# notify-blur-test.sh, for the same reason.
cat > "$WORK/run.sh" <<'INNER'
#!/usr/bin/env bash
WORK="$1"; HERE="$2"; SIG="$3"; WD="$4"; XRD="$5"; QMLROOT="$6"; BAR_CONF="$7"; MON="$8"; BAR_XDG="$9"
env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WD" HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 10
timeout 5 gdbus call --session \
	--dest org.freedesktop.Notifications \
	--object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.Notify \
	"shadow-test" 0 "" "Shadow" "a toast with a shadow under it" "[]" "{}" 60000 \
	>/dev/null 2>&1
sleep 3
grim -o "$MON" "$WORK/toast.png" 2>/dev/null
kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null
INNER
chmod +x "$WORK/run.sh"
setsid dbus-run-session -- "$WORK/run.sh" "$WORK" "$HERE" "$HL_SIG" \
	"$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR" "$QMLROOT" "$BAR_CONF" "$HL_MON" "$BAR_XDG"

MARGIN_X=8
RESULT="$(python3 - "$WORK/toast.png" "$CARD_W" "$MARGIN_X" <<'MEASURE'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("L")
px = im.load()
W, H = im.size
card_w, margin_x = int(sys.argv[2]), int(sys.argv[3])

# COMPUTED, not detected. The card is right-aligned at `notify { width }` plus
# `bar { margin-x }`, both written by this test -- so this checks the shell
# against numbers it set rather than agreeing with whatever it drew. Detecting
# the edge instead found the steps between the card's own text and icons and
# profiled the card's flat interior, which passed on a build with the bug.
card_left = W - margin_x - card_w
row = 120
if row >= H or card_left < 140:
    print("SKIP no room to measure")
    raise SystemExit

# The wallpaper, well clear of the toast.
bg = px[40, row]

# Strictly OUTSIDE the card: out of its left side, across the shadow, into the
# wallpaper. Three pixels of clearance so the card's own edge is not the step.
prof = [px[x, row] for x in range(card_left - 120, card_left - 3)]
steps = [abs(prof[i + 1] - prof[i]) for i in range(len(prof) - 1)]
print("OK %d %d %d %d" % (card_left, bg, min(prof), max(steps) if steps else 0))
MEASURE
)"

set -- $RESULT
if [ "${1:-SKIP}" != "OK" ]; then
	bad "a toast with a shadow is on screen ($RESULT)"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
CARD_LEFT=$2; BG=$3; DARKEST=$4; MAXSTEP=$5
ok "a toast with a shadow is on screen (card edge x=$CARD_LEFT)"
echo "  ..   wallpaper $BG, darkest point under the shadow $DARKEST, biggest step $MAXSTEP"

# The shadow has to actually be there, or "no step" is trivially true.
if [ "$((BG - DARKEST))" -ge 6 ]; then
	ok "the shadow darkens the wallpaper beside the card ($BG -> $DARKEST)"
else
	bad "the shadow darkens the wallpaper beside the card ($BG -> $DARKEST)"
fi

# Two, because the real numbers are 1 and 4. A gaussian spread over forty
# pixels moves about a level at a time; clipping its outer half leaves a step of
# four where the surface ends. Six was the first threshold here and passed on
# both builds -- the clipped shadow is subtle, not dramatic, and a threshold
# has to sit between the two measurements to be worth writing.
if [ "$MAXSTEP" -le 2 ]; then
	ok "...and fades out rather than being cut off (biggest step $MAXSTEP)"
else
	bad "...and fades out rather than being cut off (biggest step $MAXSTEP -- a shadow clipped at the surface edge steps by ~4)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
