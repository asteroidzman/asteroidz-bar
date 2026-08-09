#!/usr/bin/env bash
# notify-blur-test.sh — do the notification toasts get the bar's frost?
#
# The toasts are a layer surface of their own, so nothing about the bar's blur
# applies to them: they were flat translucent cards over whatever was behind
# them while every other panel in the shell was frosted.
#
# Measured over a STRIPED wallpaper, because blur is only visible as the loss
# of detail. On the flat backdrop notify-test.sh uses, a blurred region and an
# unblurred one are the same pixels -- which is why this is a separate file
# rather than another assertion there.
#
# Two runs, identical but for `panel { blur }` in the bar's own config. A
# control is essential: the card is 85% opaque, so it flattens the stripes
# considerably on its own, and a single blurred-looking screenshot proves
# nothing.
#
# The compositor is configured with `blur { enable #true; layer #false }` on
# purpose. That is the shape of a real desktop's config, and it is the case
# that matters: the shell asks for blur through ext-background-effect-v1, and
# asteroidz treats a client region as an explicit opt-in that OVERRIDES the
# global layer switch ("a client region is an explicit opt-in, an empty one an
# opt-out", asteroidz.c). If that ever stopped being true the toasts would go
# flat on every machine that leaves `layer` alone, and this is what would say
# so.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "notify-blur-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}
command -v magick >/dev/null 2>&1 || {
	echo "notify-blur-test: needs imagemagick for the striped wallpaper" >&2
	exit 77
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

# 20px bands. Sharper than anything the card's own colour does, so the loss of
# contrast can only be the blur.
magick -size 40x40 xc:white -fill black -draw "rectangle 0,0 40,19" \
	-write mpr:t +delete \
	-size "${HL_WIDTH}x${HL_HEIGHT}" tile:mpr:t "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
effects { blur { enable #true; layer #false; passes 3; radius 8 } }
EOF
hl_dispatch "reload_config" 1
sleep 1

cat > "$WORK/run.sh" <<'INNER'
#!/usr/bin/env bash
set -u
WORK="$1"; HERE="$2"; SIG="$3"; WL="$4"; XRD="$5"; QMLROOT="$6"; BAR_CONF="$7"
MON="$8"; SHOT="$9"; BAR_XDG="${10}"

env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WL" \
	XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs-$SHOT.log" 2>&1 &
QS=$!
sleep 10

# Long-lived deliberately: a toast that expires mid-screenshot measures the
# wallpaper and calls it a blur failure.
timeout 5 gdbus call --session \
	--dest org.freedesktop.Notifications \
	--object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.Notify \
	"blur-test" 0 "" "Frost" "a toast over stripes" "[]" "{}" 60000 \
	>/dev/null 2>&1
sleep 3
grim -o "$MON" "$WORK/$SHOT.png" 2>/dev/null

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null
INNER
chmod +x "$WORK/run.sh"

# Every number the toast's position is derived from, written here rather than
# left to the defaults, so the arithmetic in the python below is checking the
# shell rather than agreeing with it by coincidence.
#
# BAR_GAP is min(shadowRoom, margin-y), and shadowRoom -- shadow-size plus
# TWICE shadow-blur, the distance the shadow actually reaches -- is 42 with the
# panel settings used here, so it comes out as margin-y either way.
CARD_W=380
BAR_H=48
MARGIN_X=8
MARGIN_Y=9
BAR_GAP=$MARGIN_Y

run_with_blur() { # run_with_blur <#true|#false> <shot>
	# The panel block is spelled out rather than taken from bar_conf_panel,
	# which hardcodes `blur #true`. Repeating a block is safe -- BarConfig
	# accumulates keys into a group rather than replacing it -- but saying it
	# once is clearer than relying on that.
	bar_conf "" "" "notify" <<EOF
panel { enable #true; radius 9; padding 12; blur $1; shadow #true }
bar { height $BAR_H; margin-x $MARGIN_X; margin-y $MARGIN_Y }
notify { width $CARD_W }
EOF
	setsid $(bar_limits) dbus-run-session -- "$WORK/run.sh" "$WORK" "$HERE" "$HL_SIG" \
		"$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR" "$QMLROOT" "$BAR_CONF" \
		"$HL_MON" "$2" "$BAR_XDG"
}

run_with_blur "#true" frosted
run_with_blur "#false" flat

# The toast is top-right under the bar. Found rather than assumed: on a row
# crossing a white band, the columns the card covers are darker.
python3 - "$WORK/frosted.png" "$WORK/flat.png" \
	"$CARD_W" "$BAR_H" "$MARGIN_X" "$MARGIN_Y" "$BAR_GAP" \
	> "$WORK/verdict" 2>&1 <<'PY'
import sys
from PIL import Image

frosted, flat = sys.argv[1], sys.argv[2]
CARD_W, BAR_H, MARGIN_X, MARGIN_Y, BAR_GAP = (int(a) for a in sys.argv[3:8])


def load(path):
    im = Image.open(path).convert("RGB")
    return im.load(), im.size


fpx, (W, H) = load(frosted)
gpx, _ = load(flat)

# Where the card MUST be, computed rather than detected.
#
# Three detectors were tried and all three found something other than the
# card -- the wallpaper's own black stripes, then the shadow below the card,
# then nothing at all once white text was excluded. Each one passed or failed
# for a reason that had nothing to do with blur.
#
# There is nothing to detect. This test writes the bar's height, its margins
# and the card's width itself, and the shell derives the position from exactly
# those numbers: the toast surface sits below the bar's exclusive zone
# (height + 2*margin-y), the first card sits `bar-gap` into it, and the card's
# right edge is `margin-x` from the screen edge. So the box is arithmetic, and
# a card that is NOT there fails the control assertion below -- which is what
# that assertion is for.
card_right = W - MARGIN_X
card_left = card_right - CARD_W
card_top = BAR_H + 2 * MARGIN_Y + BAR_GAP

# Inset past the rounded corners and the border. 20..90 below the card's top
# stays inside it (the card runs about 105px for a one-line body) and spans
# several 20px stripe periods.
x0, x1 = card_left + 24, card_right - 24
y0, y1 = card_top + 20, card_top + 90


def contrast(px):
    """Peak-to-trough down each column, at the 20th percentile of columns.

    Down, because the stripes are horizontal.

    A low percentile rather than the worst column or the median, because the
    card is mostly TEXT: white glyphs on a dark panel swing further than any
    stripe does, so the worst column measures the typography. The median was
    no better once the icon and the full-size body arrived -- the text then
    covered more than half the width, so the middle column was a text column
    too, and a blurred card measured 371 against an unblurred 393.

    The 20th percentile lands on the quiet part of the card, which is the only
    place the backdrop is visible at all.
    """
    runs = []
    for x in range(x0, x1):
        col = [sum(px[x, y]) for y in range(y0, y1)]
        runs.append(max(col) - min(col))
    runs.sort()
    return runs[len(runs) // 5]


def card_top_edge(px):
    """The first row of a long run of DARK card pixels, just inside the edge.

    Read at card_left + 6: inside the card but outside its 12px padding, so
    there is no text or icon in this column and the card reads as one flat
    colour all the way down.

    Dark as well as card-coloured, and 60 rows of it. "Neither black nor
    white" alone finds the BAR's shadow, which starts 3px below the bar and
    runs continuously into the card -- it reported the toast at y=60 when the
    card begins at 75. The shadow cannot hold 60 unbroken dark rows, because
    the 20px white stripes show through it; the card can.
    """
    x = card_left + 6
    run = None
    for y in range(BAR_H + 4, min(H, card_top + 200)):
        v = sum(px[x, y]) / 3
        if 8 < v < 120:
            if run is None:
                run = y
        else:
            if run is not None and y - run > 60:
                return run
            run = None
    return run if run is not None else None


print(f"BOX {x0} {x1} {y0} {y1}")
print(f"EXPECT_TOP {card_top}")
print(f"ACTUAL_TOP {card_top_edge(fpx)}")
print(f"FROSTED {contrast(fpx)}")
print(f"FLAT {contrast(gpx)}")
PY

cat "$WORK/verdict"

FROSTED="$(awk '/^FROSTED/{print $2}' "$WORK/verdict")"
FLAT="$(awk '/^FLAT/{print $2}' "$WORK/verdict")"
EXPECT_TOP="$(awk '/^EXPECT_TOP/{print $2}' "$WORK/verdict")"
ACTUAL_TOP="$(awk '/^ACTUAL_TOP/{print $2}' "$WORK/verdict")"

# Where the toast sits, which is its own bug and not a detail of the blur.
#
# `exclusiveZone: 0` does not mean "ignore the bar": the surface reserves
# nothing while still respecting what the bar reserved, so the compositor has
# already placed it below the bar. Adding the bar's height to the margin as
# well put the toasts a second bar's worth down the screen -- 131px on this
# 48px bar, when they should start at 75.
if [ -n "$ACTUAL_TOP" ] && [ "$ACTUAL_TOP" != "None" ] \
	&& [ "$ACTUAL_TOP" -ge $((EXPECT_TOP - 2)) ] \
	&& [ "$ACTUAL_TOP" -le $((EXPECT_TOP + 2)) ]; then
	ok "the toast starts just under the bar (y=$ACTUAL_TOP, wanted $EXPECT_TOP)"
else
	bad "the toast starts just under the bar (y=${ACTUAL_TOP:-none}, wanted $EXPECT_TOP)"
fi

# The control first. If the unblurred card did not keep its stripes, the
# measurement is not measuring blur and the comparison below means nothing.
#
# The threshold is measured, not derived. An 85%-opaque card over black/white
# bands should let through about 115 of the 765 possible, and it does not --
# it comes through at about 39, so the panel is effectively more opaque than
# its colour suggests. 20 is comfortably above the noise floor and well under
# the observed value; the ratio test below is what carries the real claim.
if [ "${FLAT:-0}" -gt 20 ]; then
	ok "with blur off the stripes survive behind the card ($FLAT)"
else
	bad "with blur off the stripes survive behind the card ($FLAT)"
fi

if [ "${FROSTED:-9999}" -lt $((FLAT / 2)) ]; then
	ok "a toast asks for blur and gets it ($FROSTED vs $FLAT)"
else
	bad "a toast asks for blur and gets it ($FROSTED vs $FLAT)"
fi

# The same numbers read the other way: this is the only thing that turns the
# switch off, and it was dead config until now.
if [ "${FLAT:-0}" -gt $((FROSTED * 2)) ]; then
	ok "panel { blur #false } turns it off ($FLAT vs $FROSTED)"
else
	bad "panel { blur #false } turns it off ($FLAT vs $FROSTED)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
