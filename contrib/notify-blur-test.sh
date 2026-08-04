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
MON="$8"; SHOT="$9"

env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WL" \
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

run_with_blur() { # run_with_blur <#true|#false> <shot>
	# The panel block is spelled out rather than taken from bar_conf_panel,
	# which hardcodes `blur #true` -- appending a second `panel` block to
	# override it would depend on how BarConfig resolves a duplicated block,
	# which is not what this test is about.
	bar_conf "" "" "notify" <<EOF
panel { enable #true; radius 9; padding 12; blur $1; shadow #true }
EOF
	setsid dbus-run-session -- "$WORK/run.sh" "$WORK" "$HERE" "$HL_SIG" \
		"$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR" "$QMLROOT" "$BAR_CONF" \
		"$HL_MON" "$2"
}

run_with_blur "#true" frosted
run_with_blur "#false" flat

# The toast is top-right under the bar. Found rather than assumed: on a row
# crossing a white band, the columns the card covers are darker.
python3 - "$WORK/frosted.png" "$WORK/flat.png" > "$WORK/verdict" 2>&1 <<'PY'
import sys
from PIL import Image


def load(path):
    im = Image.open(path).convert("RGB")
    return im.load(), im.size


def card_box(px, W, H):
    """The toast, found by the one thing that separates it from the backdrop.

    The wallpaper is pure black or pure white and nothing else, so any pixel
    that is NEITHER is the card or its shadow. Darkness alone does not work:
    the stripes run horizontally, so an all-black row reads as a card spanning
    the whole scan -- which is exactly what the first version of this did, and
    it duly measured the wallpaper twice and reported the blur as a no-op.
    """
    def longest_mid(y):
        run, best = None, None
        for x in range(W // 2, W):
            mid = 8 < sum(px[x, y]) / 3 < 240
            if mid and run is None:
                run = x
            elif not mid and run is not None:
                if best is None or x - run > best[1] - best[0]:
                    best = (run, x - 1)
                run = None
        if run is not None and (best is None or W - 1 - run > best[1] - best[0]):
            best = (run, W - 1)
        return best

    # The card's x-range, from whichever row has the widest such run.
    widest = None
    for y in range(60, min(500, H)):
        got = longest_mid(y)
        if got and (widest is None or got[1] - got[0] > widest[1] - widest[0]):
            widest = got
    if not widest or widest[1] - widest[0] <= 300:
        return None
    x0, x1 = widest[0] + 8, widest[1] - 8

    # Then the rows the card COVERS COMPLETELY: every pixel across that whole
    # x-range is the card's own, neither wallpaper black nor wallpaper white.
    #
    # "Long dark run" is not enough on its own, and this is where two earlier
    # versions went wrong. The shadow is also neither black nor white, and
    # where it falls across a black stripe it is also dark -- so the box ran
    # past the bottom of the card into bare wallpaper. A handful of
    # full-contrast rows then appear in EVERY column, so the median column is
    # poisoned just as thoroughly as the worst one, and both shots read high.
    #
    # Under the shadow the wallpaper still reaches 0, so requiring the entire
    # width to be card-valued excludes it.
    # 90% of the width, not all of it: the card has WHITE text on it, and
    # "every pixel is neither black nor white" therefore excluded every row
    # carrying the summary or the close button. A row below the card, over a
    # black stripe, is under a weak shadow and mostly reads as wallpaper -- so
    # it fails a 90% test comfortably, which is the distinction being drawn.
    rows = []
    for y in range(60, min(500, H)):
        vals = [sum(px[x, y]) / 3 for x in range(x0, x1)]
        covered = sum(1 for v in vals if 8 < v < 240) / len(vals)
        if covered > 0.9 and sum(vals) / len(vals) < 100:
            rows.append(y)
    if len(rows) < 40:
        return None

    # The longest CONTIGUOUS block of them, then trimmed clear of the rounded
    # ends.
    best = cur = [rows[0], rows[0]]
    for y in rows[1:]:
        if y == cur[1] + 1:
            cur[1] = y
        else:
            cur = [y, y]
        if cur[1] - cur[0] > best[1] - best[0]:
            best = cur[:]
    trim = max(4, int((best[1] - best[0]) * 0.15))
    return [x0, x1, best[0] + trim, best[1] - trim]


def contrast(px, x0, x1, y0, y1):
    """Peak-to-trough down each column; the MEDIAN column, not the worst.

    Down, because the stripes are horizontal. Median, because the card has
    text on it and the worst column is whichever one crosses a glyph -- which
    measures the typography, not the backdrop.
    """
    runs = []
    for x in range(x0, x1):
        col = [sum(px[x, y]) for y in range(y0, y1)]
        runs.append(max(col) - min(col))
    if not runs:
        return 0
    runs.sort()
    return runs[len(runs) // 2]


fpx, (W, H) = load(sys.argv[1])
gpx, _ = load(sys.argv[2])

box = card_box(fpx, W, H)
if not box:
    print("NOCARD")
    raise SystemExit(0)

x0, x1, y0, y1 = box
# Inset past the rounded corners and the border. The vertical span is already
# trimmed by card_box and still has to cover several 20px stripe periods.
x0, x1 = x0 + 24, x1 - 24
if y1 - y0 < 40 or x1 - x0 < 40:
    print("NOCARD")
    raise SystemExit(0)

frosted = contrast(fpx, x0, x1, y0, y1)
flat = contrast(gpx, x0, x1, y0, y1)
print(f"BOX {x0} {x1} {y0} {y1}")
print(f"FROSTED {frosted}")
print(f"FLAT {flat}")
PY

cat "$WORK/verdict"

if grep -q NOCARD "$WORK/verdict"; then
	bad "a toast is on screen to measure"
	echo
	echo "$PASS passed, $((FAIL + 1)) failed"
	exit 1
fi
ok "a toast is on screen to measure"

FROSTED="$(awk '/^FROSTED/{print $2}' "$WORK/verdict")"
FLAT="$(awk '/^FLAT/{print $2}' "$WORK/verdict")"

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
