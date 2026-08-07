#!/usr/bin/env bash
# picker-test.sh — an open dropdown is inside the window it belongs to.
#
# Picker reparents its list OUT of the scrolling pane and onto the window's
# content item, so that a list opened near the bottom of a long page is not
# clipped to the visible part of the pane. That solved the clipping and created
# a worse one: the list was placed BELOW the header unconditionally, so on a
# short window it was drawn past the window's own bottom edge and simply
# vanished. The row expanded, and there was nothing in the gap to click.
#
# Reported live on the Displays page, whose Scale row sits under a monitor
# arrangement and two other pickers -- the lowest control on the page, on the
# page most likely to be open while someone is changing display settings.
#
# ── why this runs at scale 1.75 ─────────────────────────────────────────────
#
# Not because the bug needs a fractional scale -- it reproduces on any window
# short enough -- but because that is the shape a real desktop has. A 4K output
# at 1.75 is 1234 logical rows, and the settings window is sized to that, so the
# whole list falls off the end rather than half of it.
#
# It also pins the harness detail that made this hard to see: hl_start seeds the
# virtual pointer's extent from the output's MODE, while wlvptr maps onto the
# layout's LOGICAL bounding box. At any scale but 1 the two disagree and every
# click is multiplied by the scale, so a first attempt at reproducing this
# reported twenty-four failures that were all the harness missing. Hence
# hl_sync_pointer_extent below, and device-to-logical conversion at every click.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCALE=1.75

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "picker-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

export HL_EXTRA_KDL="output HEADLESS-1 { scale $SCALE }
theme { font \"Ubuntu 12\"; border-width 0; corner-radius 8; padding { x 16; y 4 } }"

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

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#20242c' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

bar_conf "tags" "" "power" <<EOF
$(bar_conf_panel)
EOF

setsid dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
sleep 10

hl_sync_pointer_extent

# Clicks are given in the DEVICE pixels a screenshot is measured in, and
# converted here to the logical ones the pointer speaks.
tap() { # tap <device-x> <device-y>
	local lx ly
	lx="$(python3 -c "print(round($1 / $SCALE))")"
	ly="$(python3 -c "print(round($2 / $SCALE))")"
	hl_move "$lx" "$ly"; sleep 0.5
	hl_click "$lx" "$ly"; sleep 1.5
}

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# The ship chip opens the settings window; logical coordinates, as everywhere.
hl_move 38 33; sleep 1
hl_click 38 33; sleep 4

WIN="$(hl_get "get all-clients" | jq -c '.clients[] | select(.title=="asteroidz settings") | {x,y,width,height}')"
if [ -n "$WIN" ]; then
	ok "the settings window is open ($WIN)"
else
	bad "the settings window is open"
	echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# The window's bottom edge, in the screenshot's device pixels.
WIN_BOTTOM="$(python3 -c "
import json
w = json.loads('''$WIN''')
print(round((w['y'] + w['height']) * $SCALE))
")"

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print(" ".join(str(max(0, min(255, round(v * 255)))) for v in c[:3]))
')"

# Sidebar: Displays. Then the Scale control, the lowest row on that page.
tap 176 616
shot displays
tap 1289 856
shot opened

# The open list's current entry is painted in the accent colour across the
# WHOLE control column -- much wider than the sidebar's own selected item, which
# is why the scan starts to the right of the sidebar. Its row is what tells us
# the list is really on screen: it is the fifth of six, so it is the first thing
# to fall off a bottom edge.
# THICKNESS, not just presence. The first version of this asked only whether an
# accent row existed and whether its top edge was above the window's bottom,
# and it passed on the broken build: five pixels of the entry were showing over
# the window's last row. "There is one pixel of it on screen" is not the claim
# -- the claim is that the entry is there to be clicked.
accent_row() { # accent_row <shot> -> "y width thickness", or "" if none
	python3 - "$WORK/$1.png" "$ACCENT" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); W, H = im.size
want = tuple(int(v) for v in sys.argv[2].split())
x0 = int(W * 0.38)  # right of the sidebar, whose selected item is accent too


def near(c):
    return all(abs(a - b) <= 6 for a, b in zip(c, want))


# Wide enough to be a LIST ROW and not the monitor tile in the arrangement
# widget, which is drawn in the same accent and sits in the same pane. A row
# spans the whole control column; the tile is well under half the screen.
MIN_W = int(W * 0.4)


# COUNTED, not the longest contiguous run. The entry has its own label drawn
# across it in the contrasting foreground, so the longest unbroken stretch of
# accent in a row of text is about half the row -- which reported an eleven
# pixel "entry" for one that is drawn forty-two tall, on a build where it was
# perfectly visible.
def widest(y):
    return sum(1 for x in range(x0, W) if near(px[x, y]))


# The tallest band of consecutive rows that each carry a wide accent run.
best = (0, 0, 0)  # y, width, thickness
top = None
wide = 0
for y in range(H + 1):
    w = widest(y) if y < H else 0
    if w >= MIN_W:
        if top is None:
            top = y
        wide = max(wide, w)
    elif top is not None:
        if y - top > best[2]:
            best = (top, wide, y - top)
        top, wide = None, 0
print("%d %d %d" % best if best[2] else "")
PY
}

read -r AY AW AT <<< "$(accent_row opened)"
echo "  ..   window bottom at y=$WIN_BOTTOM, accent entry ${AW:-0}x${AT:-0} at y=${AY:-none}"

# It has to exist at all...
if [ -n "${AW:-}" ] && [ "${AW:-0}" -ge 200 ]; then
	ok "the open list draws its current entry (${AW}px wide)"
else
	bad "the open list draws its current entry -- nothing to click"
fi

# ...and be a WHOLE row of it, which is the assertion that carries this test.
# A row is Picker.rowHeight -- 24 logical pixels at this font, 42 real ones at
# scale 1.75. Thirty is comfortably below a full row and far above the sliver a
# clipped one leaves: the broken build draws two pixels of it over the window's
# last row, so "is any of it on screen" and "does it end inside the window" both
# pass there and neither is worth asserting.
if [ "${AT:-0}" -ge 30 ]; then
	ok "...as a full row, not a sliver (${AT}px tall)"
else
	bad "...as a full row, not a sliver (${AT:-0}px tall -- a row is ~42)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
