#!/usr/bin/env bash
# look-test.sh — the three ways the bar's geometry went wrong, as assertions.
#
# All three were reported as one complaint ("the spacing is off"), and none of
# them are visible in the QML: they only exist once the thing is drawn. So this
# draws it, on a light wallpaper, and measures pixels.
#
#   1. A module with nothing to show costs nothing. Media hid itself but its
#      SLOT still measured 390px of transport controls, pinned title and
#      visualiser, so an idle centre panel drew three times wider than the
#      clock inside it.
#   2. A pinned pill keeps its icon. Three modules pinned themselves to their
#      LABEL's width and lost the icon's advance -- about 28px each. Content
#      overflows a pill rather than being clipped, so this showed up as the
#      next module having no space in front of it.
#   3. The panel has a shadow. It had none: MultiEffect was given a plain
#      Rectangle as its source, and a Rectangle is not a texture provider, so
#      it drew nothing at all.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null

WORK="$HL_OUTDIR"

# The C++ module, laid out the way an import path expects. The launcher in
# bin/ is a TEMPLATE -- its @SHELLDIR@ is only substituted at install time --
# so running it from the tree means telling it where both halves live, or it
# looks for `Asteroidz.Bar` under a literal "@SHELLDIR@/qml" and the whole
# shell fails to load.
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/" 2>/dev/null || {
	echo "look-test: not built -- run: meson setup build && meson compile -C build" >&2
	exit 1
}
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

PRISTINE="$WORK/config.pristine.kdl"
cp "$HL_CONFIG" "$PRISTINE"

render() { # render <modules-center> <outfile>
	cp "$PRISTINE" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center "$1"; modules-right "" }
EOF
	hl_dispatch "reload_config" 1
	sleep 1

	# On a PRIVATE bus, so "idle media" means what it says. The shell reads
	# MPRIS off whatever session bus it is given, and this test used to
	# inherit the user's -- where it passed only for as long as nobody
	# happened to be playing anything.
	dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
	local pid=$!
	sleep 8
	grim -o "$HL_MON" "$2" 2>/dev/null
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
}

# There is no MPRIS player on this bus, so `media` is the idle case by
# construction -- nothing has to be arranged for it.
render "clock" "$WORK/without.png"
render "media,clock" "$WORK/with.png"
render "weather,idle" "$WORK/pinned.png"

python3 - "$WORK" > "$WORK/verdicts" 2>&1 <<'PY'
import sys
from PIL import Image

work = sys.argv[1]
BG = None


def load(name):
    return Image.open(f"{work}/{name}").convert("RGB").load()


def panel_span(px, width, rows=range(14, 50)):
    """The run of columns belonging to the panel slab.

    A column counts when its DARKEST pixel is panel-dark, not when one
    sampled row is: sampling a single row through the middle cuts the panel
    into pieces wherever a glyph crosses it, and the panel then measures as
    a dozen 10px runs and is found as none.
    """
    runs, s = [], None
    for x in range(width):
        dark = min(sum(px[x, y]) for y in rows) < 300
        if dark and s is None:
            s = x
        elif not dark and s is not None:
            if x - s > 30:
                runs.append((s, x - 1))
            s = None
    return runs[0] if runs else None


im = Image.open(f"{work}/without.png")
W = im.size[0]

a = panel_span(load("without.png"), W)
b = panel_span(load("with.png"), W)
print(f"panel without media: {a}, with idle media: {b}")
if a and b and abs((b[1] - b[0]) - (a[1] - a[0])) <= 2:
    print("PASS an idle module costs no width")
else:
    print("FAIL an idle module costs no width")

# 2. pinned pills keep their icon: weather's temperature must not sit on top
#    of the idle glyph beside it. Measure the smallest gap between ink runs.
px = load("pinned.png")
span = panel_span(px, W)
rows = range(16, 50)
ink = []
s = None
for x in range(span[0], span[1] + 1):
    lit = max(sum(px[x, y]) for y in rows) > 330
    if lit and s is None:
        s = x
    elif not lit and s is not None:
        ink.append((s, x - 1))
        s = None
if s is not None:
    ink.append((s, span[1]))
merged = []
for s0, e0 in ink:
    if merged and s0 - merged[-1][1] <= 2:
        merged[-1] = (merged[-1][0], e0)
    else:
        merged.append((s0, e0))
# The widest gap inside the panel is the one between the two modules.
gaps = [merged[i][0] - merged[i - 1][1] - 1 for i in range(1, len(merged))]
biggest = max(gaps) if gaps else 0
print(f"module gap in 'weather,idle': {biggest}px (ink runs: {len(merged)})")
if biggest >= 8:
    print("PASS a pinned pill leaves room for its neighbour")
else:
    print("FAIL a pinned pill leaves room for its neighbour")

# 3. the shadow: above the panel's top edge, darker than the open wallpaper.
far = px[4, 4]
near = px[(span[0] + span[1]) // 2, 5]
print(f"above the panel: {near}, open wallpaper: {far}")
if sum(near) < sum(far) - 30:
    print("PASS the panel casts a shadow")
else:
    print("FAIL the panel casts a shadow")
PY

# The measurements are printed by the python above; this turns them into the
# script's own tally, so a caller only has to look at the exit status.
while IFS= read -r line; do
	case "$line" in
	PASS*) ok "${line#PASS }" ;;
	FAIL*) bad "${line#FAIL }" ;;
	*) echo "  ..   $line" ;;
	esac
done < "$WORK/verdicts"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
