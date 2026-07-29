#!/usr/bin/env bash
# click-test.sh — drive the real bar with a real pointer.
#
# Everything else in contrib/ checks what the bar DRAWS. This checks what it
# does when clicked, which is the half that kept shipping broken: a popover
# that could not be dismissed, a picker that applied a mode per click, a
# wallpaper that was written to disk and never put up. Each of those was
# "verified" by reading the QML, and each was wrong.
#
# The pointer is wlvptr (zwlr_virtual_pointer_v1) against the headless
# compositor, so these are ordinary pointer events as far as the bar knows.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "click-test: not built -- meson setup build && meson compile -C build" >&2
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

# A bar with exactly one module in it, on the right, so its pill is at a
# position this script can compute rather than hunt for.
cp "$HL_CONFIG" "$WORK/config.pristine.kdl"
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "display" }
EOF
hl_dispatch "reload_config" 1
sleep 1

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

# How much of the screen below the bar is not wallpaper? A popover is the only
# thing that can be there, so this is "is a panel open", as a number.
panel_pixels() { # panel_pixels <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
w, h = im.size
n = 0
for y in range(120, min(h, 700), 4):
    for x in range(0, w, 4):
        r, g, b = px[x, y]
        # the wallpaper is #9db8d8; a panel is much darker
        if r + g + b < 400:
            n += 1
print(n)
PY
}

# The display pill: the only module, so it is at the right edge of the right
# panel, one pill-height down.
PILL_X=$((HL_WIDTH - 8 - 12 - 18))
PILL_Y=$((9 + 24))

shot idle
IDLE="$(panel_pixels idle)"

# Move first. A press delivered without a preceding motion event does not
# hit-test -- the very first click of the session was landing nowhere while
# every later one worked, which reads as "the pill is dead" rather than "the
# pointer had never entered the surface".
hl_move "$PILL_X" "$PILL_Y"
sleep 1
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot opened
OPENED="$(panel_pixels opened)"

if [ "$OPENED" -gt $((IDLE + 400)) ]; then
	ok "clicking the display pill opens its panel ($IDLE -> $OPENED px)"
else
	bad "clicking the display pill opens its panel ($IDLE -> $OPENED px)"
fi

# Escape closes it.
#
# Pressed TWICE, for the same reason hl_move precedes the first hl_click.
# wlvkbd is a one-shot client: it connects, creates a virtual keyboard, sends
# the key and exits, so the seat only advertises a keyboard while it is alive.
# On the first press the bar is still binding wl_keyboard in response to
# wl_seat.capabilities and receives only the RELEASE -- the press itself is
# gone. That read as "Escape is broken in the bar" for a whole round of
# debugging; the protocol trace showed wl_keyboard.enter arriving 30ms AFTER
# the key. The second press lands on a client that already has the keyboard,
# and if the first did get through it is a no-op on an already-closed panel.
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 1
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 2
shot escaped
ESCAPED="$(panel_pixels escaped)"
if [ "$ESCAPED" -lt $((IDLE + 400)) ]; then
	ok "Escape closes it ($OPENED -> $ESCAPED px)"
else
	bad "Escape closes it ($OPENED -> $ESCAPED px)"
fi

# Open it again, then click the pill a second time: that must close it.
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot reopened
REOPENED="$(panel_pixels reopened)"
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot toggled
TOGGLED="$(panel_pixels toggled)"
if [ "$REOPENED" -gt $((IDLE + 400)) ] && [ "$TOGGLED" -lt $((IDLE + 400)) ]; then
	ok "clicking the same pill closes it ($REOPENED -> $TOGGLED px)"
else
	bad "clicking the same pill closes it ($REOPENED -> $TOGGLED px)"
fi

# And a click well away from everything closes it.
hl_click "$PILL_X" "$PILL_Y"
sleep 2
hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200))
sleep 2
shot away
AWAY="$(panel_pixels away)"
if [ "$AWAY" -lt $((IDLE + 400)) ]; then
	ok "clicking away closes it ($AWAY px)"
else
	bad "clicking away closes it ($AWAY px)"
fi

# ── the dropdowns inside the panel ──────────────────────────────────────────
#
# A Picker opening its list makes the panel taller, and a popup that resizes
# itself while it is mapped USED TO HANG THE WHOLE CLIENT: Qt and quickshell
# each send an xdg_popup.reposition, the compositor is entitled to answer only
# the last one ("the compositor may skip all but the last one" -- xdg-shell),
# Qt's token goes unanswered and it never paints again. The give-away was that
# the panel still LOOKED alive: the old frame stayed on screen stretched to the
# new surface size, so the text simply got taller. That is what the glyph-height
# check below is for -- "the panel grew" alone passes on the broken build.

# The form rows of an open panel: "<label-top> <label-bottom> <control-centre-x>"
# per row, top to bottom.
#
# Found in the pixels rather than computed from the layout, because a popup that
# does not fit centred under its pill gets slid sideways by the compositor -- so
# arithmetic from the pill's position lands somewhere else entirely.
#
# A row is a run of label text with a filled control rect on the same scanline.
# The controls all share one column, so the rows are the lines whose run starts
# at the column most of them agree on: that is what separates a FormRow from the
# "drag to arrange" hint, which sits on a scanline crossing the whole arrangement
# widget and would otherwise read as a row and shift every index by one.
form_rows() { # form_rows <shot> <panel-left> <panel-right>
	python3 - "$WORK/$1.png" "$2" "$3" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
# Inside the panel only. The wallpaper is lighter than any text threshold, so
# a full-width scan calls every scanline a line of text.
x0 = max(0, int(sys.argv[2]))
x1 = min(w, int(sys.argv[3]) + 1)
y0, y1 = 60, h

# The slab colour, taken over the WHOLE panel rather than per scanline. On a
# form row the control rect is wider than the label column beside it, so the
# most common colour on that one line is the CONTROL -- which inverted the
# search and returned the label column as the thing to click.
alldark = [px[x, y] for y in range(y0, y1, 2) for x in range(x0, x1, 2)
           if sum(px[x, y]) < 400]
slab = Counter(alldark).most_common(1)[0][0] if alldark else (0, 0, 0)

def isslab(c):
    return all(abs(a - b) <= 6 for a, b in zip(c, slab))

def runs(y):
    out, start = [], None
    for x in range(x0, x1):
        c = px[x, y]
        if (not isslab(c)) and sum(c) < 400:
            if start is None:
                start = x
        else:
            if start is not None and x - start > 40:
                out.append((start, x))
            start = None
    if start is not None and x1 - start > 40:
        out.append((start, x1))
    return out

# text lines anywhere in the panel
ys = [y for y in range(60, h) if any(sum(px[x, y]) > 460 for x in range(x0, x1))]
groups = []
for y in ys:
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
groups = [g for g in groups if len(g) > 4]

cand = []
for g in groups:
    mid = (g[0] + g[-1]) // 2
    rs = runs(mid)
    if rs:
        # the widest run on the line is the control
        s, e = max(rs, key=lambda r: r[1] - r[0])
        cand.append((g[0], g[-1], s, e))

if cand:
    col = Counter(s for _, _, s, _ in cand).most_common(1)[0][0]
    for a, b, s, e in cand:
        if abs(s - col) <= 4:
            print(a, b, (s + e) // 2)
PY
}

# The panel's own bounding box, so nothing here depends on where the compositor
# decided to put a popup that does not fit centred under its pill.
panel_box() { # panel_box <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
xs, ys = [], []
for y in range(100, h, 2):
    for x in range(0, w, 2):
        r, g, b = px[x, y]
        if r + g + b < 400:
            xs.append(x); ys.append(y)
print(min(xs), min(ys), max(xs), max(ys)) if xs else print(0, 0, 0, 0)
PY
}

hl_click "$PILL_X" "$PILL_Y"
sleep 3
shot panel
read -r PL PT PR PB <<<"$(panel_box panel)"
BEFORE_PX="$(panel_pixels panel)"

mapfile -t LINES < <(form_rows panel "$PL" "$PR")
# Resolution, Refresh, Scale, VRR, ICC profile. Scale is the one to drive: it
# is the only picker guaranteed to have more than one value on a virtual
# output, whose mode list the compositor may report as a single entry.
if [ "${#LINES[@]}" -ge 3 ]; then
	read -r SY0 SY1 CTRL_X <<<"${LINES[2]}"
	SCALE_Y=$(((SY0 + SY1) / 2))
	echo "  ..   Scale row at y=$SCALE_Y, control at x=$CTRL_X (panel $PL,$PT-$PR,$PB)"

	# how tall is a label glyph run before anything is clicked
	read -r RY0 RY1 _ <<<"${LINES[0]}"
	H_BEFORE=$((RY1 - RY0 + 1))

	hl_move "$CTRL_X" "$SCALE_Y"
	sleep 1
	hl_click "$CTRL_X" "$SCALE_Y"
	sleep 3
	shot dropdown
	AFTER_PX="$(panel_pixels dropdown)"

	if [ "$AFTER_PX" -gt $((BEFORE_PX + 1500)) ]; then
		ok "the Scale dropdown opens ($BEFORE_PX -> $AFTER_PX px)"
	else
		bad "the Scale dropdown opens ($BEFORE_PX -> $AFTER_PX px)"
	fi

	# ...and the panel REDREW rather than being stretched to the new size.
	read -r QL _ QR _ <<<"$(panel_box dropdown)"
	mapfile -t LINES2 < <(form_rows dropdown "$QL" "$QR")
	if [ "${#LINES2[@]}" -ge 1 ]; then
		read -r AY0 AY1 _ <<<"${LINES2[0]}"
		H_AFTER=$((AY1 - AY0 + 1))
	else
		H_AFTER=0
	fi
	if [ "$H_AFTER" -gt 0 ] &&
		[ $((H_AFTER > H_BEFORE ? H_AFTER - H_BEFORE : H_BEFORE - H_AFTER)) -le 2 ]; then
		ok "the panel repaints instead of stretching (${H_BEFORE}px -> ${H_AFTER}px text)"
	else
		bad "the panel repaints instead of stretching (${H_BEFORE}px -> ${H_AFTER}px text)"
	fi

	# Picking a value closes the list again, which is the other half of the
	# widget and the half that needs the popup to redraw a SECOND time.
	ROW_H=$((SY1 - SY0 + 18))
	hl_click "$CTRL_X" $((SCALE_Y + ROW_H * 2))
	sleep 3
	shot picked
	PICKED_PX="$(panel_pixels picked)"
	if [ "$PICKED_PX" -lt $((AFTER_PX - 1000)) ]; then
		ok "picking a value closes the list ($AFTER_PX -> $PICKED_PX px)"
	else
		bad "picking a value closes the list ($AFTER_PX -> $PICKED_PX px)"
	fi
else
	bad "the display panel shows its form rows (found ${#LINES[@]} labels)"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
