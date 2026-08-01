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

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
elif isinstance(c, str):
    print(c)
' 2>/dev/null)"

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

# Text lines inside the panel, top to bottom: "<top> <bottom>" each. A menu row
# is text with no control beside it, so form_rows cannot find one.
text_lines() { # text_lines <shot> <panel-left> <panel-right>
	python3 - "$WORK/$1.png" "$2" "$3" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
x0 = max(0, int(sys.argv[2]))
x1 = min(w, int(sys.argv[3]) + 1)
ys = [y for y in range(60, h) if any(sum(px[x, y]) > 460 for x in range(x0, x1))]
groups = []
for y in ys:
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
for g in groups:
    if len(g) > 4:
        print(g[0], g[-1])
PY
}

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


# ── a text field in a panel can actually be typed into ──────────────────────
#
# It could not. Keys go to whatever holds keyboard focus, which is the BAR's
# layer surface (Bar.qml raises WlrKeyboardFocus.Exclusive while a popover is
# up); the popup deliberately never grabs focus, because Qt refuses to create a
# grabbing popup here and falls back silently; and Bar.qml routed every key to
# Popover.handleKey, which only knew about the MENU ROWS model. For a panel
# `rows` is empty, focusedRow stayed -1, and every keystroke past Escape was
# dropped. Folder, Cycle and the Display tab's ICC path were all inert.
#
# Bar.qml now forwards to Popover.keyTarget, which a Field claims for itself when
# clicked -- via QsWindow.window, because the visual parent chain does not reach
# the window at all and a walk up `parent` silently set nothing.
#
# Asserted through the FILE the field writes as well as the pixels: text
# appearing in a box proves the keyboard arrived, and only the file proves the
# commit path behind it works too.

hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200)); sleep 2
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 3
shot wp_open
read -r WL WT WR WB <<<"$(panel_box wp_open)"

# The Wallpaper tab, found by COLOUR rather than by arithmetic from the panel
# edge. The selected tab is the topmost accent-coloured block in the panel, and
# the other tab sits immediately to its right past Cfg.spacing. Guessing an
# offset from the panel box does not work: panel_box here reports a top edge that
# excludes the shadow, a standalone probe's did not, and the same "+22" landed
# inside the tab row in one and above the panel in the other -- so the tab never
# switched, WROWS[0] was the DISPLAY tab's Resolution picker, and the assertions
# below failed against a build where the field worked perfectly.
tab_pill() { # tab_pill <shot> <accent-hex>  ->  "left right top bottom"
	python3 - "$WORK/$1.png" "$2" <<'__PY__'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
if len(acc) != 6:
    print("0 0 0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
def near(c, tol=14):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
rows = {}
for y in range(60, h):
    xs = [x for x in range(w) if near(px[x, y])]
    if len(xs) > 20:
        rows[y] = xs
if not rows:
    print("0 0 0 0"); raise SystemExit
groups = []
for y in sorted(rows):
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
g = groups[0]
mid = max(g, key=lambda y: len(rows[y]))
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
print(best[0], best[-1], g[0], g[-1])
__PY__
}

read -r TBL TBR TBT TBB <<<"$(tab_pill wp_open "${ACCENT:-#000000}")"
if [ "${TBR:-0}" -le 0 ]; then
	bad "the panel's tab row is on screen"
fi
# Just past the selected pill's right edge, plus half the next pill.
hl_click $((TBR + 40)) $(((TBT + TBB) / 2)); sleep 2
shot wp_tab

# It really switched: the accent pill moved right, because the selection did.
read -r NBL _ _ _ <<<"$(tab_pill wp_tab "${ACCENT:-#000000}")"
if [ "${NBL:-0}" -gt "${TBL:-0}" ]; then
	ok "clicking the second tab switches to it (accent moved $TBL -> $NBL)"
else
	bad "clicking the second tab switches to it (accent still at ${NBL:-0})"
fi

# The Folder field, positioned from the TAB ROW rather than from form_rows.
#
# form_rows was built for the Display tab: it takes the widest dark run on a
# scanline as the control, and consensus over the rows to find the column. In the
# wallpaper tab the Folder field holds a long path, whose glyphs fragment that
# run, and it reported one row where there are three. Rather than teach it a
# second shape, this anchors off the tab pill measured above -- the first form row
# sits Cfg.spacing below the tab row, one row-height tall.
#
# The arithmetic is self-validating: the assertion below is that wallpaper.conf
# changed, and nothing else in the panel writes `folder=`. A mis-aimed click can
# only make this FAIL, never falsely pass.
FY=$((TBB + 8 + 17))
FCX=$((WL + 300))
BEFORE_CONF="$(grep '^folder=' "$WORK/wallpaper.conf" 2>/dev/null)"

hl_move "$FCX" "$FY"; sleep 1
hl_click "$FCX" "$FY"; sleep 1
shot wp_focus
for k in Q Q Q; do "$HL_WLVKBD" press "$k" >/dev/null 2>&1; sleep 0.3; done
sleep 0.5
shot wp_typed

# The field has to LOOK focused. "You can type stuff in but it is not clear
# you're actually focused on the field" was reported separately from the keys not
# arriving, and it is a different bug: TextInput draws its own caret from
# activeFocus, which here depends on whether the POPUP's window is active and so
# has nothing to do with where keys are going. Field now draws an accent outline
# and forces the caret on, both keyed to being the popover's keyTarget -- the one
# signal that actually decides.
#
# Measured as accent pixels gained in the panel, which is what an outline is.
FOCUS_ACCENT="$(python3 - "$WORK/wp_tab.png" "$WORK/wp_focus.png" "${ACCENT:-#000000}" "$WL" "$WT" "$WR" "$WB" <<'__PY__'
import sys
from PIL import Image
a = Image.open(sys.argv[1]).convert("RGB").load()
b = Image.open(sys.argv[2]).convert("RGB").load()
acc = sys.argv[3].lstrip("#")
l, t, r, bo = (int(v) for v in sys.argv[4:8])
if len(acc) != 6:
    print(0); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
def near(c, tol=20):
    return all(abs(x - y) <= tol for x, y in zip(c, want))
before = sum(1 for y in range(t, bo) for x in range(l, r) if near(a[x, y]))
after = sum(1 for y in range(t, bo) for x in range(l, r) if near(b[x, y]))
print(after - before)
__PY__
)"
if [ "${FOCUS_ACCENT:-0}" -gt 100 ]; then
	ok "a focused field is outlined in the accent (+${FOCUS_ACCENT}px)"
else
	bad "a focused field is outlined in the accent (+${FOCUS_ACCENT}px)"
fi

TYPED_DIFF="$(python3 - "$WORK/wp_focus.png" "$WORK/wp_typed.png" "$WL" "$WT" "$WR" "$WB" <<'__PY__'
import sys
from PIL import Image
a = Image.open(sys.argv[1]).convert("RGB").load()
b = Image.open(sys.argv[2]).convert("RGB").load()
l, t, r, bo = (int(v) for v in sys.argv[3:7])
print(sum(1 for y in range(t, bo) for x in range(l, r) if a[x, y] != b[x, y]))
__PY__
)"
if [ "${TYPED_DIFF:-0}" -gt 300 ]; then
	ok "typing into a panel's text field reaches it (${TYPED_DIFF}px changed)"
else
	bad "typing into a panel's text field reaches it (${TYPED_DIFF}px changed)"
fi

# And the file. A field that shows keystrokes and writes nothing is the same bug
# one layer further on -- and this is the assertion that proves the click landed
# on the Folder field specifically.
"$HL_WLVKBD" press ENTER >/dev/null 2>&1
sleep 1
AFTER_CONF="$(grep '^folder=' "$WORK/wallpaper.conf" 2>/dev/null)"
if [ -n "$AFTER_CONF" ] && [ "$AFTER_CONF" != "$BEFORE_CONF" ]; then
	ok "Enter commits it to wallpaper.conf"
else
	bad "Enter commits it to wallpaper.conf (still '$AFTER_CONF')"
fi

hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200)); sleep 2

# ── the display panel stages, and Apply commits ─────────────────────────────
#
# The panel used to act on every pick. Choosing 2560x1440 from a list of a
# dozen modes therefore mode-set to everything scrolled past on the way, and a
# mode set is a black screen for a moment. Edits now collect and go together.
#
# Both halves are asserted, because either alone passes on a broken build: a
# panel that applies nothing ever would pass "picking does not apply", and the
# old immediate-apply panel would pass "the scale changed after Apply".

hl_dispatch "set_output_scale,$HL_MON,1" 1
BEFORE_SCALE="$(hl_get "get all-monitors" | python3 -c '
import json, sys
n = sys.argv[1]
for m in json.load(sys.stdin)["monitors"]:
    if m["name"] == n: print(m.get("scale")); break
' "$HL_MON")"

# The dropdown test above leaves the panel OPEN, so open it blind and this
# click CLOSES it -- and every measurement below then reads bare wallpaper.
hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200))
sleep 2
hl_click "$PILL_X" "$PILL_Y"
sleep 3
shot stage_open
read -r AL AT AR AB <<<"$(panel_box stage_open)"
mapfile -t AROWS < <(form_rows stage_open "$AL" "$AR")

if [ "${#AROWS[@]}" -ge 3 ]; then
	read -r AY0 AY1 ACX <<<"${AROWS[2]}"          # Scale
	SY=$(((AY0 + AY1) / 2))
	hl_move "$ACX" "$SY"; sleep 1
	hl_click "$ACX" "$SY"                          # open the list
	sleep 3
	shot stage_list
	# The FIRST row of the open list, which for Scale is 0.75 -- deliberately
	# not the row for the current value. Picker only emits `picked` when the
	# value actually changes, so landing on the current one stages nothing and
	# this test would pass while proving nothing. Rows are Cfg.fontPixelSize *
	# 1.5 tall and the list starts just under the header.
	PICKROW=$((SY + 38))
	hl_click "$ACX" "$PICKROW"
	sleep 3

	AFTER_PICK="$(hl_get "get all-monitors" | python3 -c '
import json, sys
n = sys.argv[1]
for m in json.load(sys.stdin)["monitors"]:
    if m["name"] == n: print(m.get("scale")); break
' "$HL_MON")"

	if [ "$AFTER_PICK" = "$BEFORE_SCALE" ]; then
		ok "picking a value stages it instead of applying ($BEFORE_SCALE unchanged)"
	else
		bad "picking a value stages it instead of applying ($BEFORE_SCALE -> $AFTER_PICK)"
	fi

	# The Apply button: accent-coloured while there are staged changes, and the
	# LOWEST accent block in the panel -- the tab pill and the picker's selected
	# row share that colour.
	shot staged
	read -r SL ST SR SB <<<"$(panel_box staged)"
	read -r APX APY <<<"$(python3 - "$WORK/staged.png" "${ACCENT:-#000000}" "$SL" "$SR" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
x0, x1 = int(sys.argv[3]), min(w, int(sys.argv[4]) + 1)
if len(acc) != 6:
    print(0, 0); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
def near(c):
    return all(abs(a - b) <= 30 for a, b in zip(c, want))
rows = {}
for y in range(60, h):
    xs = [x for x in range(x0, x1) if near(px[x, y])]
    if len(xs) > 30:
        rows[y] = (min(xs), max(xs))
if not rows:
    print(0, 0); raise SystemExit
groups = []
for y in sorted(rows):
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
g = groups[-1]                      # lowest accent block = Apply
a, b = rows[g[0]][0], rows[g[0]][1]
print((a + b) // 2, (g[0] + g[-1]) // 2)
PY
)"

	if [ "${APY:-0}" -gt 0 ]; then
		hl_move "$APX" "$APY"; sleep 1
		hl_click "$APX" "$APY"
		sleep 3
		AFTER_APPLY="$(hl_get "get all-monitors" | python3 -c '
import json, sys
n = sys.argv[1]
for m in json.load(sys.stdin)["monitors"]:
    if m["name"] == n: print(m.get("scale")); break
' "$HL_MON")"
		if [ "$AFTER_APPLY" != "$BEFORE_SCALE" ]; then
			ok "Apply commits the staged change ($BEFORE_SCALE -> $AFTER_APPLY)"
		else
			bad "Apply commits the staged change (still $AFTER_APPLY)"
		fi
	else
		bad "the Apply button is on screen (no accent block found)"
	fi
else
	bad "the display panel shows its form rows for the Apply test"
fi

# Put the output back. Applying a scale really does rescale the layout, so
# every pill below moves -- leaving 0.75 in place made the plugin tests click
# empty wallpaper and fail for reasons that had nothing to do with plugins.
hl_dispatch "set_output_scale,$HL_MON,1" 2
hl_click $((HL_WIDTH / 4)) $((HL_HEIGHT - 200))
sleep 2

# ── a plugin's menu ─────────────────────────────────────────────────────────
#
# Plugin rows did nothing at all. The popover raised `activated`, the bar
# checked the row for a PipeWire node and a tray entry, found neither, and fell
# through to closing the panel -- so every row in the medication, discord and
# nordvpn menus looked live, dismissed itself and told the plugin nothing.
#
# Driven by a stub rather than by a real plugin: this is the bar's half of the
# protocol, and a test needing a medication schedule on disk to exercise it
# would be testing the wrong thing -- and would answer differently on a machine
# that has one.

cat > "$WORK/stub.py" <<'STUB'
import json, sys, threading, time

LOG = sys.argv[1]

def emit(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()

TOP = {"menu": {"item": "", "rows": [
    {"text": "Alpha", "value": "a"},
    {"text": "More", "value": "more", "submenu": True},
]}}
SUB = {"menu": {"item": "", "rows": [
    {"text": "Beta", "value": "b"},
    {"text": "Name", "value": "name", "input": True, "edit": "prefilled"},
    {"text": "Save", "value": "save"},
]}}

def reader():
    for line in sys.stdin:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("event") == "click":
            emit(TOP)
        elif ev.get("event") == "menu":
            v = ev.get("value") or ""
            with open(LOG, "a") as f:
                f.write("GOT %s %s\n" % (
                    v, json.dumps(ev.get("fields") or {}, sort_keys=True)))
            if v == "more":
                emit(SUB)
            else:
                emit({"menu": {"item": "", "rows": []}})

threading.Thread(target=reader, daemon=True).start()
while True:
    emit({"text": "PROBE"})
    time.sleep(5)
STUB

PLOG="$WORK/plugin-events.log"
: > "$PLOG"

cp "$WORK/config.pristine.kdl" "$HL_CONFIG"
cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "custom/probe"
	custom "probe" { exec "python3 $WORK/stub.py $PLOG"; continuous true } }
EOF
hl_dispatch "reload_config" 1
sleep 5

hl_move "$PILL_X" "$PILL_Y"
sleep 1
hl_click "$PILL_X" "$PILL_Y"
sleep 3
shot pmenu
PMENU="$(panel_pixels pmenu)"
if [ "$PMENU" -gt 400 ]; then
	ok "a plugin's pill opens its menu ($PMENU px)"
else
	bad "a plugin's pill opens its menu ($PMENU px)"
fi

read -r ML _ MR _ <<<"$(panel_box pmenu)"
mapfile -t ROWS < <(text_lines pmenu "$ML" "$MR")
ROW_X=$(((ML + MR) / 2))

if [ "${#ROWS[@]}" -ge 2 ]; then
	# Row two is "More", a submenu: it has to swap the rows in place rather
	# than dismiss, which is what showMenu's toggle would have done.
	read -r MY0 MY1 <<<"${ROWS[1]}"
	hl_click "$ROW_X" $(((MY0 + MY1) / 2))
	sleep 3
	shot psub
	PSUB="$(panel_pixels psub)"
	if grep -q "GOT more" "$PLOG"; then
		ok "picking a row reaches the plugin"
	else
		bad "picking a row reaches the plugin (log: $(tr '\n' ' ' < "$PLOG"))"
	fi
	if [ "$PSUB" -gt 400 ]; then
		ok "a submenu replaces the rows instead of closing the panel"
	else
		bad "a submenu replaces the rows instead of closing the panel ($PSUB px)"
	fi

	# The form that submenu put up. Its editable row has to show what the
	# plugin PREFILLED, not the field's own name: `value` is the row id to a
	# plugin and the field's text to the popover, and conflating them printed
	# "Name: name" where "Name: prefilled" belonged. Picking Save must carry
	# that text back as a field -- Save is a row like any other and the plugin
	# has no other way to see what is in the form above it.
	read -r SL _ SR _ <<<"$(panel_box psub)"
	mapfile -t SROWS < <(text_lines psub "$SL" "$SR")
	if [ "${#SROWS[@]}" -ge 3 ]; then
		read -r SY0 SY1 <<<"${SROWS[2]}"
		hl_click $(((SL + SR) / 2)) $(((SY0 + SY1) / 2))
		sleep 3
		if grep -q '"name": "prefilled"' "$PLOG"; then
			ok "a form row carries the plugin's prefill back as a field"
		else
			bad "a form row carries the plugin's prefill back as a field (log: $(tr '\n' ' ' < "$PLOG"))"
		fi
	else
		bad "the submenu form has its rows (found ${#SROWS[@]})"
	fi
else
	bad "the plugin menu has its rows (found ${#ROWS[@]})"
fi

# ── the power menu ──────────────────────────────────────────────────────────
#
# Every entry here except Lock ends the session or the machine, so the claim
# worth testing is the one that keeps a misclick from doing that: picking a
# destructive entry must ASK rather than act.
#
# Asserted on the panel, because that is where the difference shows. Acting
# would close it (and, in a test, reboot the machine); asking replaces the rows
# and leaves it open. Nothing here ever clicks the confirmation itself -- there
# is no safe way to assert "Yes, power off" works, and a test that found out
# would be the last thing this suite ever ran.
cp "$WORK/config.pristine.kdl" "$HL_CONFIG"
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "power" }
EOF
hl_dispatch "reload_config" 1
sleep 4

hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 3
shot power
POWER="$(panel_pixels power)"
if [ "$POWER" -gt 400 ]; then
	ok "the power pill opens its menu ($POWER px)"
else
	bad "the power pill opens its menu ($POWER px)"
fi

read -r WL _ WR _ <<<"$(panel_box power)"
mapfile -t WROWS < <(text_lines power "$WL" "$WR")
WROW_X=$(((WL + WR) / 2))

# Rows are Lock, Log out, then the destructive four. Index 5 is Power off --
# the last one, and the one whose confirmation matters most.
if [ "${#WROWS[@]}" -ge 6 ]; then
	ok "the power menu has its entries (${#WROWS[@]} rows)"
	read -r WY0 WY1 <<<"${WROWS[5]}"
	hl_click "$WROW_X" $(((WY0 + WY1) / 2))
	sleep 3
	shot pconfirm
	PCONF="$(panel_pixels pconfirm)"
	if [ "$PCONF" -gt 400 ]; then
		ok "picking Power off asks instead of acting (panel still up, $PCONF px)"
	else
		bad "picking Power off closed the panel ($PCONF px) -- it acted"
	fi

	# Deliberately NOT clicking inside the confirmation.
	#
	# The rows there are "Yes, power off" and "Cancel", this suite locates rows
	# by pixel analysis, and it cannot read them -- so clicking the one it
	# believes is Cancel is a bet that, lost, powers the machine off in the
	# middle of a test run. An earlier version of this case took that bet and
	# hit the wrong row.
	#
	# What CAN be checked safely is that the menu rebuilds: close it from the
	# pill and open it again, and the full list has to come back. That covers
	# menuRows() being reusable, which is what Cancel depends on -- Cancel calls
	# exactly this, from inside the confirmation.
	hl_click "$PILL_X" "$PILL_Y"; sleep 2
	hl_click "$PILL_X" "$PILL_Y"; sleep 3
	shot pagain
	read -r AL _ AR _ <<<"$(panel_box pagain)"
	mapfile -t AROWS < <(text_lines pagain "$AL" "$AR")
	if [ "${#AROWS[@]}" -ge "${#WROWS[@]}" ]; then
		ok "the menu rebuilds in full after being dismissed (${#AROWS[@]} rows)"
	else
		bad "the menu came back short (${#AROWS[@]} of ${#WROWS[@]} rows)"
	fi
else
	bad "the power menu has its entries (found ${#WROWS[@]})"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"

[ "$FAIL" = 0 ]
