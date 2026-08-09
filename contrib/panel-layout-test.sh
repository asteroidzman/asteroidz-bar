#!/usr/bin/env bash
# panel-layout-test.sh — the settings window's boxes fit the text in them.
#
# settings-test.sh drives the window and checks what it DOES. Nothing checks what
# it looks like, and that is where its ancestor was broken: the display panel's
# tabs were `width: 100` with a centred Text that had no width, no elide and no
# clip, so at the shipped theme "Wallpaper" overflowed its pill on both sides, ate
# the 4px gap between the two tabs, and was then painted over by the neighbouring
# rect. One cause, two symptoms -- "text is cut off" and "the tabs touch each
# other".
#
# Those tabs are gone: both of them are pages in the settings window now, reached
# from the sidebar. The bug they were made of is not gone, because it is not about
# tabs -- it is a fixed pixel constant meeting a theme-sized glyph, and this
# window is full of places that could have one. So the subject moved with the UI:
#
#   1. the header's Close button is sized from its LABEL (SmallButton exists for
#      exactly this; its header comment names the `width: 84` buttons it replaced)
#   2. no glyph ink reaches that button's edge columns -- clipping IS the bug
#   3. the arrangement canvas does not sit on its own hint
#
# What is NOT here any more: the tab-row assertions. They are deleted rather than
# reworded because the row they measured does not exist, and a test kept alive by
# pointing it at something else is how a suite ends up reporting on pixels nobody
# chose.
#
# Run at a LARGE font on purpose. A test at the default font is a test of the one
# case that happened to fit. At "Ubuntu 24" a fixed-width button clips badly; at
# "Ubuntu 11" the boxes must still not collapse below their floors.
#
# Reading the QML is how the original bugs got shipped; see click-test.sh's
# header, which says the same thing about behaviour.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "panel-layout-test: not built -- meson setup build && meson compile -C build" >&2
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
BAR_XDG="$(bar_xdg_home)"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cp "$HL_CONFIG" "$WORK/config.pristine.kdl"

# The bar is started ONCE and re-themed between rounds by reload_config, which
# the compositor pushes to the bar over `watch bar-config`. Restarting it per
# font would cost 8s of settle each time and orphan the plugin children.
#
# Re-theming with the window OPEN is deliberate: everything measured here is
# bound to Cfg, so this is also the assertion that the window relays out rather
# than keeping the metrics it was built with.
apply_font() { # apply_font "Ubuntu 24"
	cp "$WORK/config.pristine.kdl" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "$1"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "tags" "" "" <<EOF
$(bar_conf_panel)
EOF
	hl_dispatch "reload_config" 2
}

apply_font "Ubuntu 16"
sleep 1

# A guard, not decoration. Every failure so far in developing this test was the
# bar coming up with no compositor to talk to -- it logs one WARN and then draws
# a window full of defaults, which looks close enough to a real one that the
# assertions fail for a reason that has nothing to do with the layout. Do NOT
# override HL_OUTDIR to keep the screenshots: a reused directory can hold a live
# gvfs mount, hl_start's rm -rf then fails, no socket is created, and this is
# exactly where you land. Set ASTEROIDZ_SHOT_DIR instead.
[ -S "${HL_SIG:-}" ] || {
	echo "panel-layout-test: no compositor socket (HL_SIG=${HL_SIG:-<unset>})" >&2
	exit 1
}

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

accent_of() {
	hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
elif isinstance(c, str):
    print(c)
' 2>/dev/null
}

# The window's frame, from the compositor rather than from the pixels. Every
# measurement below is relative to it, and it moves: the window is tiled, so a
# font change that resizes the bar can reflow the layout under it.
win_box() {
	hl_get "get all-clients" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("clients", []):
    if c.get("title") == "asteroidz settings":
        print(c["x"], c["y"], c["width"], c["height"]); break
else:
    print(0, 0, 0, 0)
'
}

# The ship: the first chip of the only module, and the way in to the window.
# The ship, at the LEFT edge: margin_x + the panel's padding + half a chip.
# Mirrors the arithmetic the retired settings pill used at the right edge, and
# every module here is an icon-only pill of the same width.
PILL_X=$((8 + 12 + 18))
PILL_Y=$((9 + 24))

# RIGHT click, which opens the settings window straight on the Displays page.
# A left click opens it on All settings, and the arrangement canvas measured
# below is only on Displays.
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y" rclick; sleep 4

read -r WX WY WW WH <<<"$(win_box)"
if [ "${WW:-0}" -gt 300 ]; then
	ok "the settings window is open (${WW}x${WH} at ${WX},${WY})"
else
	bad "the settings window is open (${WW}x${WH} at ${WX},${WY})"
	kill "$QS" 2>/dev/null
	echo; echo "$PASS passed, $FAIL failed"
	exit 1
fi

# The Close button in the header: "<left> <right> <top> <bot> <width> <edge-ink>".
#
# Found as the topmost filled box in the RIGHT END of the header band, which is
# what it is: the header holds a search field on the left and this button hard
# right, and on the Displays page the search field is hidden -- so the button is
# the only thing at that end. Its fill is rgba(1,1,1,0.08) over the window colour,
# a small delta, so this works against the SURFACE rather than against a
# brightness threshold.
#
# Both bounds are load-bearing and neither was there first. A band 16% of the
# window tall reaches past the header into the page, and the tallest box in THAT
# is the arrangement canvas -- duly reported as a 323x55 "button" with ink at its
# edges, which failed at two fonts out of three and passed at the third for no
# reason at all. Topmost-in-the-right-end is the description that only fits the
# button.
measure_close() { # measure_close <shot> <wx> <wy> <ww> <wh>
	python3 - "$WORK/$1.png" "$2" "$3" "$4" "$5" <<'PY'
import sys
from collections import Counter
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
wx, wy, ww, wh = (int(v) for v in sys.argv[2:6])

x0 = max(wx + 12 + max(int(ww * 0.24), 190),
         wx + ww - max(200, int(ww * 0.20)))
x1 = min(w, wx + ww - 2)
# From below the compositor's 2px focus border to past the tallest header a
# theme can produce.
y0 = wy + 8
y1 = min(h, wy + 8 + 90)
if x1 <= x0 or y1 <= y0:
    print("ERR empty-band"); raise SystemExit

sample = [px[x, y] for y in range(y0, y1) for x in range(x0, x1, 2)]
bg = Counter(sample).most_common(1)[0][0]

def isbg(c, tol=4):
    return all(abs(a - b) <= tol for a, b in zip(c, bg))

def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]

# Rows carrying a wide non-background run; the button is the widest such run on
# each of its own rows.
# Two filters, and the restyle is why both are needed.
#
# A run spanning the band is the CONTENT CARD'S OWN TOP BORDER, which now sits
# above the button -- and being topmost and widest it won every test, reporting
# the Close button as 378x7. "The button grew with its text" then passed against
# a 378-pixel-wide box, which is a test that cannot fail. A button is a fraction
# of the band; an edge is all of it.
#
# And a block at least twelve rows tall, because that border is eight.
band = x1 - x0
rows = {}
for y in range(y0, y1):
    runs, start = [], None
    for x in range(x0, x1 + 1):
        solid = x < x1 and not isbg(px[x, y])
        if solid and start is None:
            start = x
        elif not solid and start is not None:
            n = x - start
            if 20 < n < band * 0.6:
                runs.append((start, x - 1))
            start = None
    if runs:
        rows[y] = max(runs, key=lambda r: r[1] - r[0])
if not rows:
    print("ERR no-button"); raise SystemExit

groups = []
for y in sorted(rows):
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
groups = [g for g in groups if len(g) >= 12]
if not groups:
    print("ERR no-button-block"); raise SystemExit
g = groups[0]                       # the header sits above everything else
top, bot = g[0], g[-1]

# The row with the widest run is one clear of both the corner radius and the
# glyphs, so its width IS the button's width.
mid = max(g, key=lambda y: rows[y][1] - rows[y][0])
left, right = rows[mid]

# Ink at the button's edges. The label is drawn in the foreground colour, which
# is far from both the button fill and the surface; the corner antialiasing is a
# mid-tone between the two and stays under the threshold.
fill = px[(left + right) // 2, top + 1]
def has_ink(x):
    if not (0 <= x < w):
        return False
    return any(abs(lum(px[x, y]) - lum(fill)) > 60 for y in range(top, bot + 1))

edge_ink = [x for x in (left, left + 1, right - 1, right) if has_ink(x)]

print("OK", left, right, top, bot, right - left + 1, len(edge_ink))
PY
}

# The monitor tile and the hint beneath it: "<tile-top> <tile-bot> <hint-top>
# <hint-rows>".
#
# Inside the CONTENT PANE only. There are two accent blocks in this window -- the
# selected sidebar entry and the selected monitor's tile -- and the sidebar one is
# higher up, so a whole-window scan taking the topmost would measure a sidebar row
# and call it a monitor. The pane starts right of the sidebar.
#
# The hint is found in the columns to the LEFT of the tile, which is the only
# place it can be told apart from anything else.
#
# Distinguishing it by BRIGHTNESS does not work. The obvious idea -- the hint is
# dim, the monitor name is focus-fg bright -- ignores that the name is
# antialiased, so its glyph edges pass any "dim" test you can write. Scanning
# from the tile's top with a 55..190 luminance window duly reported the hint as
# starting mid-tile, exactly where the name is, and the assertion failed on the
# FIXED build as loudly as on the broken one.
#
# The hint is left-aligned in the canvas and the tiles are centred in it, so the
# strip between the canvas edge and the tile's left edge holds hint ink and
# nothing else. Geometry, not colour.
measure_hint() { # measure_hint <shot> <accent-hex> <wx> <wy> <ww> <wh>
	python3 - "$WORK/$1.png" "$2" "$3" "$4" "$5" "$6" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("ERR no-accent"); raise SystemExit
want = tuple(int(acc[i:i+2], 16) for i in (0, 2, 4))

def near(c, tol=14):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]

x0 = wx + 12 + max(int(ww * 0.24), 190) + 12
x1 = min(w, wx + ww - 4)
y0, y1 = wy + 2, min(h, wy + wh - 2)

rows = {}
for y in range(y0, y1):
    xs = [x for x in range(x0, x1) if near(px[x, y])]
    if len(xs) > 20:
        rows[y] = xs
if not rows:
    print("ERR no-tile"); raise SystemExit

groups = []
for y in sorted(rows):
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])

# The tallest accent block in the pane is the monitor tile: the only other one
# that can appear here is the Apply button, which is a single row high and is not
# even accent-filled while nothing is staged.
tile = max(groups, key=len)
tile_top, tile_bot = tile[0], tile[-1]
tile_xs = rows[max(tile, key=lambda y: len(rows[y]))]
tx0 = min(tile_xs)

# The strip left of the tile, inside the canvas. The canvas background is the
# darkest thing on the page (rgba(0,0,0,0.25) over the window colour), so any ink
# here is the hint.
#
# The WHOLE width left of the tile, not a fixed 130px window. That constant came
# from the popover, where the canvas was barely wider than the tiles; here the
# canvas spans a pane several times as wide, the tiles are centred in it, and the
# hint is left-aligned at the canvas edge -- hundreds of pixels outside a window
# anchored to the tile. It reported "no text found under the tile" at every font,
# on a build drawing the hint correctly.
strip0 = x0 + 16
strip1 = max(strip0 + 1, tx0 - 5)
if strip1 - strip0 < 10:
    print("ERR no-strip"); raise SystemExit
bg = px[strip0 + 2, tile_top + 4]   # canvas background, beside the tile's top

def is_ink(c):
    return lum(c) > lum(bg) + 22

# Scanned from the tile's TOP, not its bottom: pre-fix the hint begins ABOVE the
# tile's bottom edge, so a scan starting below it would never see the overlap it
# exists to catch.
first = -1
count = 0
for y in range(tile_top, min(y1, tile_bot + 90)):
    n = sum(1 for x in range(strip0, strip1) if is_ink(px[x, y]))
    if n > 6:
        count += 1
        if first < 0:
            first = y

print("OK", tile_top, tile_bot, first, count)
PY
}

round() { # round "<font>"
	local font="$1" tag
	tag="$(echo "$font" | tr ' ' '_')"

	apply_font "$font"
	sleep 4
	local acc; acc="$(accent_of)"

	read -r WX WY WW WH <<<"$(win_box)"
	if [ "${WW:-0}" -lt 300 ]; then
		bad "[$font] the settings window is still up (${WW}x${WH})"
		return
	fi
	shot "panel_$tag"

	# ── the Close button is sized from its label ─────────────────────────
	local out; out="$(measure_close "panel_$tag" "$WX" "$WY" "$WW" "$WH")"
	# shellcheck disable=SC2086
	set -- $out
	if [ "${1:-ERR}" != "OK" ]; then
		bad "[$font] the header button is on screen (${out})"
	else
		local left=$2 right=$3 top=$4 bot=$5 width=$6 ink=$7
		local height=$((bot - top + 1))
		echo "  ..   [$font] Close button ${width}x${height} at x=$left..$right, edge-ink=$ink"

		if [ "$ink" -eq 0 ]; then
			ok "[$font] the button label is not clipped (no ink at the edge)"
		else
			bad "[$font] the button label is not clipped ($ink edge columns carry ink)"
		fi

		# "Close" is wider than it is tall at any font, so a button that
		# collapsed to its height floor while the text grew -- which is what
		# a fixed width produces -- fails here. The ink check alone cannot
		# catch that: a clipped label can elide away to nothing and leave a
		# clean edge.
		if [ "$width" -gt "$height" ]; then
			ok "[$font] the button grew with its text (${width}px wide, ${height}px tall)"
		else
			bad "[$font] the button grew with its text (${width}px wide, ${height}px tall)"
		fi
	fi

	# ── the arrangement canvas does not sit on its own hint ──────────────
	#
	# Reported live: "the 'drag to arrange' text is partially covered by the DP-1
	# rectangle and is very small". Both true, one cause -- the tiles and the
	# hint shared the whole canvas.
	#
	# `zoom` is min(width/bounds, height/bounds), so whenever the layout's
	# bounding box is proportionally NARROWER than the canvas the zoom is
	# height-limited and the tiles use every vertical pixel there is. That
	# reproduces on the ordinary one-output harness -- 7px of overlap, pre-fix.
	local hout; hout="$(measure_hint "panel_$tag" "$acc" "$WX" "$WY" "$WW" "$WH")"
	# shellcheck disable=SC2086
	set -- $hout
	if [ "${1:-ERR}" != "OK" ]; then
		bad "[$font] the arrangement canvas is measurable (${hout})"
	else
		local tile_top=$2 tile_bot=$3 hint_top=$4 hint_rows=$5
		echo "  ..   [$font] monitor tile y=$tile_top..$tile_bot, hint text starts y=$hint_top (${hint_rows} rows)"
		if [ "$hint_rows" -eq 0 ]; then
			bad "[$font] the hint is drawn at all (no text found under the tile)"
		elif [ "$hint_top" -gt "$tile_bot" ]; then
			ok "[$font] the hint sits below the tiles, not under them"
		else
			bad "[$font] the hint sits below the tiles, not under them (hint $hint_top, tile ends $tile_bot)"
		fi
	fi
}

round "Ubuntu 16"
round "Ubuntu 24"
round "Ubuntu 11"

kill "$QS" 2>/dev/null

# Screenshots survive the run only if asked for. hl_stop deletes HL_OUTDIR.
if [ -n "${ASTEROIDZ_SHOT_DIR:-}" ]; then
	mkdir -p "$ASTEROIDZ_SHOT_DIR"
	cp "$WORK"/panel_*.png "$ASTEROIDZ_SHOT_DIR/" 2>/dev/null
	echo "  ..   shots in $ASTEROIDZ_SHOT_DIR"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
