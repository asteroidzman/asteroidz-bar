#!/usr/bin/env bash
# displays-dropdown-test.sh — a dropdown must be VISIBLE on a short window.
#
# settings-test.sh already opens the Scale picker and measures the accent row
# its current value is drawn in. It passes on the build this test was written
# against, and the feature was still unusable -- so the interesting part is why
# it passes, because that is the shape of blind spot worth naming.
#
# The list is meant to be reparented to the window's content item so it can hang
# outside the scrolling pane the row lives in. That reparenting silently did not
# happen: QsWindow.window is NULL inside the settings window, which is a
# FloatingWindow, so the list fell back to expanding INSIDE the row. Inside the
# row it is clipped by the pane -- but only VISUALLY. Qt clipping affects
# rendering, not hit-testing, so a click at the coordinate where an entry would
# be still picks that entry. Every assertion phrased as "pick a value and see
# that it took" therefore passed against a list nobody could see.
#
# And at the harness's normal output scale it is genuinely visible: the window
# is tall, the Scale row sits well above the bottom of the pane, and the clipped
# inline list falls inside the viewport anyway. The suite never ran this window
# SHORT, which is the whole condition.
#
# So this runs the output at scale 1.75 -- the scale it was reported at, where
# the logical window is 520px tall -- and asserts what a click cannot: that the
# list is drawn where a person could see it, and that opening it does not shove
# the rows underneath out of the pane.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"
SCALE="${DD_SCALE:-1.75}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "displays-dropdown-test: not built -- meson setup build && meson compile -C build" >&2
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
cp "$BAR_BUILD/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 12"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "tags" "" "clock" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1

# THE CONDITION. A high output scale is what makes the logical window short, and
# short is what puts the Scale row too close to the bottom for its list to fit
# under it. At the harness's usual scale this whole file passes on a build with
# the bug in it.
hl_dispatch "set_output_scale,$HL_MON,$SCALE" 2
hl_sync_pointer_extent

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
sleep 9

# Right-click the tags pill, which goes straight to Displays.
hl_move 38 33; sleep 1
hl_click 38 33 rclick; sleep 4

WINH="$(hl_get "get all-clients" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("clients", []):
    if c.get("title") == "asteroidz settings":
        print(c["height"]); break
else:
    print(0)
')"

echo
echo "displays dropdown (output scale $SCALE, window ${WINH}px tall)"

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# The form rows, as bands of the control fill in the control column. Returned
# top to bottom in PHYSICAL pixels; the caller divides by the scale to click.
rows() { # rows <shot>  ->  "<centre-y> <centre-x> <col-x0> <col-x1>" per row
	python3 - "$WORK/$1.png" <<'PY'
from PIL import Image
import sys
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
segs = []
for y in range(int(h * 0.6), h - 2):
    run = 0; start = None; seg = None
    for x in range(int(w * 0.38), w - 2):
        r, g, b = px[x, y]
        if abs(r - 42) < 14 and abs(g - 42) < 14 and abs(b - 46) < 16:
            if start is None: start = x
            run += 1
        else:
            if run > 300: seg = (start, x)
            run = 0; start = None
    if run > 300: seg = (start, w - 2)
    if seg: segs.append((y, seg[0], seg[1]))
bands = []
for y, x0, x1 in segs:
    if bands and y - bands[-1][-1][0] <= 2: bands[-1].append((y, x0, x1))
    else: bands.append([(y, x0, x1)])
for b in bands:
    print((b[0][0] + b[-1][0]) // 2, (b[0][1] + b[0][2]) // 2, b[0][1], b[0][2])
PY
}

# Accent-filled rows anywhere in a band ABOVE OR BELOW the picker.
#
# Both directions, and that is not thoroughness: a list that does not fit below
# its row is supposed to open ABOVE it, so a search that only looks down reports
# a correctly placed list as missing. settings-test.sh's version looks down only,
# which is right for the tall window it runs on and wrong here.
#
# The list's current entry is drawn in the accent, which is the highest-contrast
# thing in the window.
#
# Matched across the FULL WIDTH of the control column, not a window around its
# centre. The monitor tile is accent too and sits directly above these rows, so
# a narrow probe centred on the column lands INSIDE the tile and counts it: the
# first version of this reported ~70 accent rows against a build whose list was
# never drawn, and passed. The list spans the whole control column and the tile
# does not come close, so the width is what tells them apart.
list_accent() { # list_accent <shot> <col-x0> <col-x1> <row-y-physical>
	python3 - "$WORK/$1.png" "${ACCENT:-#000000}" "$2" "$3" "$4" <<'ACCPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
x0, x1, sy = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
if len(acc) != 6:
    print(0); raise SystemExit
want = tuple(int(acc[i:i+2], 16) for i in (0, 2, 4))
x0 = max(0, x0); x1 = min(im.size[0], x1)
y0 = max(0, sy - 320); y1 = min(im.size[1], sy + 320)
n = 0
for y in range(y0, y1):
    if abs(y - sy) <= 2:
        continue
    hits = sum(1 for x in range(x0, x1)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want)))
    if hits > (x1 - x0) * 0.9:
        n += 1
print(n)
ACCPY
}

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
' 2>/dev/null)"

shot closed
mapfile -t ROWS < <(rows closed)

# Resolution, Refresh, Scale, ICC -- the VRR row is a toggle and has no control
# fill, so it is not a band. Scale is index 2.
if [ "${#ROWS[@]}" -ge 3 ]; then
	ok "the Displays form rows are drawn (${#ROWS[@]} control rows)"
else
	bad "the Displays form rows are drawn (found ${#ROWS[@]}, need 3)"
	echo "  $PASS passed, $((FAIL)) failed"
	kill "$QS" 2>/dev/null
	exit 1
fi

read -r SCALE_PY SCALE_PX COL_X0 COL_X1 <<<"${ROWS[2]}"
LAST_PY="$(echo "${ROWS[-1]}" | cut -d" " -f1)"
CLICK_X=$(python3 -c "print(int($SCALE_PX/$SCALE))")
CLICK_Y=$(python3 -c "print(int($SCALE_PY/$SCALE))")

hl_move "$CLICK_X" "$CLICK_Y"; sleep 1
hl_click "$CLICK_X" "$CLICK_Y"; sleep 3
shot opened

# THE PREMISE. "No accent off the row" is equally true of a list that opened
# invisibly and of a click that missed the control entirely, and those are not
# the same result -- the second says nothing about the bug at all. An open
# picker lightens its own header fill (0.12 white over the pane against 0.06),
# so the row itself reports whether the click landed.
row_fill() { # row_fill <shot> <col-x0> <col-x1> <row-y>
	python3 - "$WORK/$1.png" "$2" "$3" "$4" <<'FILLPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
x0, x1, y = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
vals = [sum(px[x, y]) / 3.0 for x in range(max(0, x0), min(im.size[0], x1))]
print(round(sum(vals) / max(1, len(vals)), 1))
FILLPY
}
FILL_CLOSED="$(row_fill closed "$COL_X0" "$COL_X1" "$SCALE_PY")"
FILL_OPEN="$(row_fill opened "$COL_X0" "$COL_X1" "$SCALE_PY")"
if python3 -c "import sys; sys.exit(0 if $FILL_OPEN > $FILL_CLOSED + 2 else 1)"; then
	ok "the click opened the picker (row fill $FILL_CLOSED -> $FILL_OPEN)"
else
	bad "the click did not open the picker (row fill $FILL_CLOSED -> $FILL_OPEN)"
fi

EXTENT="$(list_accent opened "$COL_X0" "$COL_X1" "$SCALE_PY")"
if [ "${EXTENT:-0}" -gt 10 ]; then
	ok "the open list is VISIBLE (${EXTENT}px of accent off the row)"
else
	bad "the open list is invisible (${EXTENT}px of accent off the row)"
fi

# The rows underneath must stay where they are. The picker's implicitHeight used
# to grow by the list's height whether or not the list was actually drawn inside
# it, so even a correctly reparented list displaced everything below it.
#
# Stated plainly: this one did NOT discriminate on this fixture -- it reports the
# same last-row position on both builds, because the rows it would have pushed
# down go outside the pane and stop being found either way. It is kept as a
# guard on the implicitHeight change rather than as evidence for it; the
# assertion above is the one that fails on the broken build.
mapfile -t ROWS2 < <(rows opened)
LAST2_PY="$(echo "${ROWS2[-1]}" | cut -d" " -f1)"
if [ "${#ROWS2[@]}" -ge 3 ] && [ "$((LAST2_PY - LAST_PY))" -lt 8 ] \
	&& [ "$((LAST_PY - LAST2_PY))" -lt 8 ]; then
	ok "opening it does not displace the rows below (last row $LAST_PY -> $LAST2_PY)"
else
	bad "opening it displaced the rows below ($LAST_PY -> $LAST2_PY, ${#ROWS2[@]} rows)"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
