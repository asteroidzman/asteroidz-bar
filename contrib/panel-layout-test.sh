#!/usr/bin/env bash
# panel-layout-test.sh — the display panel's boxes fit the text in them.
#
# click-test.sh drives the panel and checks what it DOES. Nothing checked what
# it looked like, and that is where it was broken: the tabs were `width: 100`
# with a centred Text that had no width, no elide and no clip, so at the shipped
# theme "Wallpaper" overflowed its pill on both sides, ate the 4px gap between
# the two tabs, and was then painted over by the neighbouring rect. One cause,
# two symptoms -- "text is cut off" and "the tabs touch each other".
#
# Run at a LARGE font on purpose. Every one of these bugs is a fixed pixel
# constant meeting a theme-sized glyph, so a test at the default font is a test
# of the one case that happened to fit. At "Ubuntu 24" the old code overflows by
# a wide margin and every assertion here fails; at "Ubuntu 11" the boxes must
# still not collapse below their floors.
#
# What is asserted, and why each is the pixels rather than the QML:
#   1. the selected tab pill has a gap after it -- tabs touching IS the bug
#   2. no glyph ink reaches the pill's edge columns -- clipping IS the bug
#   3. the same holds at a small font, where the floors take over
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
apply_font() { # apply_font "Ubuntu 24"
	cp "$WORK/config.pristine.kdl" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "$1"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "display" }
EOF
	hl_dispatch "reload_config" 2
}

apply_font "Ubuntu 16"
sleep 1

# A guard, not decoration. Every failure so far in developing this test was the
# bar coming up with no compositor to talk to -- it logs one WARN and then draws
# a panel full of defaults, which looks close enough to a real one that the
# assertions fail for a reason that has nothing to do with the layout. Do NOT
# override HL_OUTDIR to keep the screenshots: a reused directory can hold a live
# gvfs mount, hl_start's rm -rf then fails, no socket is created, and this is
# exactly where you land. Set ASTEROIDZ_SHOT_DIR instead.
[ -S "${HL_SIG:-}" ] || {
	echo "panel-layout-test: no compositor socket (HL_SIG=${HL_SIG:-<unset>})" >&2
	exit 1
}

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

# The display pill: the only module, so it is at the right edge of the right
# panel, one pill-height down. Same arithmetic as click-test.sh.
PILL_X=$((HL_WIDTH - 8 - 12 - 18))
PILL_Y=$((9 + 24))

# The selected tab: the accent-coloured block nearest the TOP of the panel.
#
# Not "the widest" and not "the only one" -- the Apply button and the Picker's
# selected row are accent too, and the Arrange widget paints the selected
# monitor in it. Topmost is the tab, because the tab row is the first thing in
# the panel.
measure_tab() { # measure_tab <shot> <accent-hex>
	python3 - "$WORK/$1.png" "$2" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
if len(acc) != 6:
    print("ERR no-accent"); raise SystemExit
want = tuple(int(acc[i:i+2], 16) for i in (0, 2, 4))

# TIGHT. The fill is flat, so it matches exactly; the tolerance only has to
# absorb the colour pipeline. It must NOT be loose: white text on a dark tab is
# subpixel-antialiased, and its blue fringe measures around (48,109,187) --
# within 30 of a (42,111,214) accent on every channel. A tolerance of 30
# therefore reported the far edge of the NEXT tab's label as the near tab's
# right edge, and the pill came out 160px wide instead of 98.
def near(c, ref=None, tol=14):
    return all(abs(a - b) <= tol for a, b in zip(c, ref if ref is not None else want))

def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]

# Accent runs below the bar, which ends well above y=60 at this geometry.
#
# NOT below y=120: the tab row is the first thing in the panel and at this
# geometry it lands around y=70..105, so a scan starting at 120 skips it
# entirely and returns the Arrange widget's selected monitor tile -- which is
# the same accent, is 126px tall, and reports a 0px gap and edge ink because it
# is a monitor rectangle with a label centred in it. That produced three
# convincing failures against a build whose tabs were correct.
rows = {}
for y in range(60, h):
    xs = [x for x in range(w) if near(px[x, y])]
    if len(xs) > 20:
        rows[y] = xs
if not rows:
    print("ERR no-accent-block"); raise SystemExit

groups = []
for y in sorted(rows):
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])

g = groups[0]                       # topmost accent block = the selected tab
top, bot = g[0], g[-1]

# Probe on the row carrying the MOST accent, not the middle one. The middle row
# runs straight through the label, so the fill is interrupted by every glyph and
# the longest unbroken run is the space between two letters -- which measured
# the pill at 17px. The fullest row is one clear of both the corner radius and
# the text, which is exactly the row whose width IS the pill's width.
mid = max(g, key=lambda y: len(rows[y]))

# The LONGEST CONTIGUOUS run, not min..max of every accent pixel on the line.
# A stray match anywhere to the right -- a fringe pixel, the Arrange tile on a
# line that happens to overlap -- silently swallows the gap into the pill.
xs = sorted(rows[mid])
best = cur = [xs[0]]
for x in xs[1:]:
    if x - cur[-1] <= 1:
        cur.append(x)
    else:
        if len(cur) > len(best):
            best = cur
        cur = [x]
if len(cur) > len(best):
    best = cur
left, right = best[0], best[-1]

# The panel background, sampled directly BELOW the pill: above it is the panel's
# top edge, only a few pixels away, where a sample lands in the shadow or the
# wallpaper.
slab = px[left, min(h - 1, bot + 6)]

# The gap: how many columns of bare panel background sit between this pill and
# the next. COUNTED over a fixed window rather than walked until something else
# appears -- the first column past the fill is the pill's own antialiased edge,
# which is neither the fill nor the background, so a walk that stops at the
# first non-background pixel always reports zero. The unselected tab's fill is
# rgba(1,1,1,0.06) over the popover colour and is not background either, so it
# contributes nothing and the window may safely overshoot into it.
gap = sum(1 for x in range(right + 1, min(w, right + 17))
          if near(px[x, mid], slab, 10))

# Ink at the pill's edges. A glyph is far brighter than either the accent fill
# or the panel background (the label is focus-fg, near white; accent luminance
# is about 100 and background about 15), so brightness alone separates them
# without needing to know the foreground colour. The pill's own rounded-corner
# antialiasing is a mid-tone and stays well under the threshold.
INK = 170
def has_ink(x):
    if not (0 <= x < w):
        return False
    return any(lum(px[x, y]) > INK for y in range(top, bot + 1))

edge_ink = [x for x in (left, left + 1, right - 1, right,
                        left - 2, left - 1, right + 1, right + 2)
            if has_ink(x)]

print("OK", left, right, top, bot, right - left + 1, gap, len(edge_ink))
PY
}

# The monitor tile and the hint beneath it: "<tile-top> <tile-bot> <hint-top>
# <hint-rows>".
#
# The tile is the SECOND accent block from the top -- the first is the selected
# tab pill. With one output that output is selected, so its tile carries the
# accent and is the only thing in the canvas findable by colour.
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
measure_hint() { # measure_hint <shot> <accent-hex>
	python3 - "$WORK/$1.png" "$2" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
if len(acc) != 6:
    print("ERR no-accent"); raise SystemExit
want = tuple(int(acc[i:i+2], 16) for i in (0, 2, 4))

def near(c, tol=14):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]

rows = {}
for y in range(60, h):
    xs = [x for x in range(w) if near(px[x, y])]
    if len(xs) > 20:
        rows[y] = xs
groups = []
for y in sorted(rows):
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
if len(groups) < 2:
    print("ERR only-%d-accent-blocks" % len(groups)); raise SystemExit

tile = groups[1]
tile_top, tile_bot = tile[0], tile[-1]
tile_xs = rows[max(tile, key=lambda y: len(rows[y]))]
tx0, tx1 = min(tile_xs), max(tile_xs)

# The strip left of the tile, inside the canvas. The canvas background is the
# darkest thing in the panel (rgba(0,0,0,0.25) over the popover colour), so any
# ink here is the hint.
strip0 = max(0, tx0 - 130)
strip1 = max(0, tx0 - 5)
bg = px[strip0 + 2, tile_top + 4]   # canvas background, beside the tile's top

def is_ink(c):
    return lum(c) > lum(bg) + 22

# Scanned from the tile's TOP, not its bottom: pre-fix the hint begins ABOVE the
# tile's bottom edge, so a scan starting below it would never see the overlap it
# exists to catch.
first = -1
count = 0
for y in range(tile_top, min(h, tile_bot + 90)):
    n = sum(1 for x in range(strip0, strip1) if is_ink(px[x, y]))
    if n > 6:
        count += 1
        if first < 0:
            first = y

print("OK", tile_top, tile_bot, first, count)
PY
}

round() { # round "<font>" <expected-min-gap>
	local font="$1" mingap="$2" tag
	tag="$(echo "$font" | tr ' ' '_')"

	apply_font "$font"
	sleep 3
	local acc; acc="$(accent_of)"

	hl_move "$PILL_X" "$PILL_Y"; sleep 1
	hl_click "$PILL_X" "$PILL_Y"
	sleep 3
	shot "panel_$tag"

	local out; out="$(measure_tab "panel_$tag" "$acc")"
	# shellcheck disable=SC2086
	set -- $out
	if [ "${1:-ERR}" != "OK" ]; then
		bad "[$font] the tab row is on screen (${out})"
		hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200)); sleep 2
		return
	fi
	local __round_shot="panel_$tag"
	local left=$2 right=$3 top=$4 bot=$5 width=$6 gap=$7 ink=$8
	echo "  ..   [$font] tab pill ${width}x$((bot - top + 1)) at x=$left..$right, gap=${gap}px, edge-ink=$ink"

	if [ "$gap" -ge "$mingap" ]; then
		ok "[$font] the tabs do not touch (${gap}px gap, want >= $mingap)"
	else
		bad "[$font] the tabs do not touch (${gap}px gap, want >= $mingap)"
	fi

	if [ "$ink" -eq 0 ]; then
		ok "[$font] the tab label is not clipped (no ink at the pill edge)"
	else
		bad "[$font] the tab label is not clipped ($ink edge columns carry ink)"
	fi

	# The pill has to be wider than it is tall for these two words at any
	# font. A pill that collapsed to its height floor while the text grew is
	# exactly the state the fixed 100 produced, and it can pass the ink check
	# by eliding everything away.
	local height=$((bot - top + 1))
	if [ "$width" -gt "$height" ]; then
		ok "[$font] the tab pill grew with the text (${width}px wide, ${height}px tall)"
	else
		bad "[$font] the tab pill grew with the text (${width}px wide, ${height}px tall)"
	fi

	# ── the arrangement canvas does not sit on its own hint ──────────────
	#
	# Reported live: "the 'drag to arrange' text is partially covered by the DP-1
	# rectangle and is very small". Both true, one cause -- the tiles and the
	# hint shared the whole canvas.
	#
	# `zoom` is min(width/bounds, height/bounds), so whenever the layout's
	# bounding box is proportionally NARROWER than the canvas the zoom is
	# height-limited and the tiles use every vertical pixel there is. The canvas
	# aspect is ~3.0 and a single 1920x1080 output is 1.78, so this reproduces on
	# the ordinary one-output harness -- 7px of overlap, pre-fix. (I first built
	# this with a second virtual output stacked below, on the assumption that one
	# output was too wide to trigger it. That was wrong, and the extra machinery
	# failed on both builds for reasons of its own.)
	local hout; hout="$(measure_hint "$__round_shot" "$acc")"
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

	hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200)); sleep 2
}

# Cfg.spacing defaults to 8 and the config above does not override it, so the
# gap is 8px at every font -- it is a token, not a proportion. Want 4 of those 8
# to read as bare background: one column at each end is the antialiased edge of
# the pill beside it, and the panel is composited over a blur.
round "Ubuntu 16" 4
round "Ubuntu 24" 4
round "Ubuntu 11" 4



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
