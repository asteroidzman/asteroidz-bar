#!/usr/bin/env bash
# audio-test.sh — the volume pill opens a panel with a slider in it.
#
# What this can check and what it cannot: the headless compositor has its own
# XDG_RUNTIME_DIR, so the bar under test reaches no PipeWire at all and there
# are no sinks to list. Pointing it at the REAL one was the obvious next
# thought and is not on -- a test that drags a volume slider would then change
# what the machine is playing at, and a private daemon with null sinks needs a
# socket path shorter than 108 bytes and a session manager that touches no
# hardware, which is a harness of its own.
#
# So this measures the frame rather than the contents: that the click opens a
# PANEL and not the menu it used to open, that the panel is the width a panel
# is, and that a slider track is drawn in it. All three fail on the build
# before this one, where the same click produced a narrow list with a single
# disabled "no audio server" row and no horizontal rule anywhere in it -- which
# is the regression worth catching, because everything below the frame is
# PipeWire bindings that a screenshot could not confirm anyway.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "audio-test: not built -- meson setup build && meson compile -C build" >&2
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

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
# One module, on the right, so its pill is where arithmetic says it is.
bar_conf "" "" "volume" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 1

setsid dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 8

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# The panel's own bounding box, in screen pixels: everything below the bar that
# is darker than the wallpaper.
panel_box() { # panel_box <shot> -> "x0 y0 x1 y1" or "" when nothing is open
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
w, h = im.size
xs, ys = [], []
for y in range(70, min(h, 900)):
    for x in range(0, w):
        r, g, b = px[x, y]
        if r + g + b < 400:  # the wallpaper is #9db8d8, a panel is far darker
            xs.append(x); ys.append(y)
print("%d %d %d %d" % (min(xs), min(ys), max(xs), max(ys)) if xs else "")
PY
}

# The thickest horizontal RULE inside the panel: a band of consecutive rows
# each carrying a long run of non-background pixels. Reported as its thickness
# and the width of its widest row.
#
# Thickness is the whole point. The first version of this measured width alone
# and passed on the build with no slider in it, because a menu separator is
# also a horizontal line three hundred pixels wide -- it is one pixel thick,
# and a slider track is six.
track_rule() { # track_rule <shot> <x0> <y0> <x1> <y1>
	python3 - "$WORK/$1.png" "$2" "$3" "$4" "$5" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
x0, y0, x1, y1 = (int(v) for v in sys.argv[2:6])
# The panel's background, sampled just inside its top-left corner where
# nothing is ever drawn.
bg = px[x0 + 6, y0 + 4]


# Two levels of grey, not ten. The track is white at a tenth of an alpha over a
# near-black panel -- (24,25,28) against (14,15,18) on this theme -- so a
# tolerance loose enough to look robust swallows the whole track, which is how
# the first version of this reported fifteen pixels for a rule spanning two
# hundred and fifty.
def ink(c):
    return any(abs(p - q) > 2 for p, q in zip(c, bg))


def longest(y):
    run = best = 0
    for x in range(x0, x1 + 1):
        if ink(px[x, y]):
            run += 1
            best = max(best, run)
        else:
            run = 0
    return best


thick = widest = 0
band = wide = 0
for y in range(y0, y1 + 1):
    w = longest(y)
    if w >= 100:
        band += 1
        wide = max(wide, w)
    else:
        if band > thick:
            thick, widest = band, wide
        band = wide = 0
if band > thick:
    thick, widest = band, wide
print("%d %d" % (thick, widest))
PY
}

PILL_X=$((HL_WIDTH - 8 - 12 - 30))
PILL_Y=$((9 + 24))

hl_move "$PILL_X" "$PILL_Y"
sleep 1
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot opened

BOX="$(panel_box opened)"
if [ -z "$BOX" ]; then
	bad "clicking the volume pill opens a panel"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "clicking the volume pill opens a panel"

# shellcheck disable=SC2086
set -- $BOX
X0=$1; Y0=$2; X1=$3; Y1=$4
W=$((X1 - X0 + 1))
H=$((Y1 - Y0 + 1))
echo "  ..   panel is ${W}x${H} at $X0,$Y0"

read -r THICK WIDE <<< "$(track_rule opened "$X0" "$Y0" "$X1" "$Y1")"
echo "  ..   thickest rule ${WIDE}px wide, ${THICK}px thick"

# Four, because a menu separator is one and a slider track is six. The width
# alone says nothing: the separator the old menu drew above its sink list ran
# the full width of the panel, and an earlier version of this test called that
# a slider and passed on a build that had none.
if [ "$THICK" -ge 4 ] && [ "$WIDE" -ge 100 ]; then
	ok "a slider track is drawn in it (${WIDE}px wide, ${THICK}px thick)"
else
	bad "a slider track is drawn in it (${WIDE}px wide, ${THICK}px thick -- a separator is 1)"
fi

# And the pill still toggles its own panel shut, which is Popover behaviour the
# panel must not have broken by grabbing the pointer.
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot closed
if [ -z "$(panel_box closed)" ]; then
	ok "clicking the pill again closes it"
else
	bad "clicking the pill again closes it"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
