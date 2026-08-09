#!/usr/bin/env bash
# settings-test.sh — drive the settings window with a real pointer.
#
# The settings window is generated entirely from data the compositor publishes:
# which control appears comes from `type`, its range from `min`/`max`, its
# choices from `enum`, whether it is editable from the provenance of the current
# value. So there is nothing to read and check by eye -- the only question that
# matters is whether a click in here reaches the compositor and lands in the
# config file, and that is a question only a real pointer can answer.
#
# Every assertion below is a fact from OUTSIDE the bar: a toplevel in the
# compositor's client list, a value in `get config`, a line in the config file,
# `asteroidz -p` accepting the result. Screenshots are used only where the claim
# is about layout.
#
# Deliberately NOT a unit test of the QML. The three bugs this window could
# plausibly ship with are a control that shows a value it cannot write, a preview
# that is never undone, and an Apply that writes a file the parser then rejects.
# None of them are visible in QML and all three are visible here.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "settings-test: not built -- meson setup build && meson compile -C build" >&2
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
# The guard headless.sh cannot make for us: if the instance did not come up,
# every `hl_get` below answers nothing and every assertion "passes" against an
# empty string. An earlier run of the sibling script did exactly that -- a stale
# mount left the output directory undeletable, no socket was created, and the bar
# came up with defaults while the test reported success.
[ -S "$HL_SIG" ] || { echo "settings-test: no IPC socket at $HL_SIG" >&2; exit 1; }

QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# One module, at the left edge. Its first chip is the asteroidz ship, which is
# the way in to the settings window -- there is no settings pill any more -- and
# it sits at a position this script can compute rather than hunt for.
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
// A hand-written line the writer must leave exactly as it found it.
misc { border_radius 9 }
EOF
bar_conf "tags" "" "" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 1

# No window rule for the settings window here, deliberately.
#
# It comes up tiled, which is not how it is meant to be run -- the docs recommend
# floating it -- but every position below is taken from the compositor's own client
# list rather than assumed, so the layout it lands in does not matter. Adding a
# rule would test the rule instead of the window.
CONFIG_BEFORE="$(cat "$HL_CONFIG")"

setsid $(bar_limits) dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="${PROBE_SHELL:-$HERE/shell}/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 8

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

# Ink, not a row count. A group of options with an explanation each is a lot of
# text; an unpopulated pane is one sentence. The gap between those is enormous,
# so a coarse measure is a reliable one -- and the same measure is what makes the
# search assertion below meaningful, since narrowing must reduce it a long way.
# Pixels that are NOT the window's own background, measured against the
# background found in the shot itself.
#
# Not "brighter than a threshold". That is what this did first, and it reported
# 458684 of 459000 sampled pixels as ink for every shot -- the headless theme sets
# the surface to a bright colour, so the constant said "everything is text" and
# both the populated and the narrowed assertion were comparing noise. The
# dominant colour in a region is its surface by definition, whatever it is.
ink() { # ink <shot> <l> <t> <r> <b>
	python3 - "$WORK/$1.png" "$2" "$3" "$4" "$5" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
l, t, r, b = (int(v) for v in sys.argv[2:6])
l = max(0, l); t = max(0, t); r = min(w, r); b = min(h, b)
sample = [px[x, y] for y in range(t, b, 2) for x in range(l, r, 2)]
if not sample:
    print(0); raise SystemExit
bg = Counter(sample).most_common(1)[0][0]
# A tolerance, not equality: the surface is a flat fill, but a corner radius and
# the odd 4%-white block sit within a few levels of it and counting those as text
# would drown the signal.
print(sum(1 for c in sample if any(abs(a - b2) > 12 for a, b2 in zip(c, bg))))
PY
}


# ── 0. the QML loaded at all ────────────────────────────────────────────────
#
# First, because everything after it is meaningless otherwise -- and because the
# failure mode is quiet: a singleton that cannot be resolved reports as four
# levels of "Type X unavailable" and a bar that is simply not there, which looks
# like a compositor problem rather than a typo.
if grep -qE 'is not a type|unavailable|Cannot override|set multiple times' \
		"$WORK/qs.log"; then
	bad "the shell loads without QML errors"
	grep -E 'is not a type|unavailable|Cannot override|set multiple times' \
		"$WORK/qs.log" | head -8 | sed 's/^/       /'
else
	ok "the shell loads without QML errors"
fi

# ── 1. the way in ───────────────────────────────────────────────────────────
#
# One click, on the SHIP.
#
# This has moved twice. It was the display pill's popover with an "All settings…"
# button in it, so reaching the window meant testing a panel first; then it was
# the pill itself; now the pill is gone and the shell's own emblem -- the first
# chip in the tags module -- is the way in, the way a start button is.

# The ship, at the LEFT edge: margin_x + the panel's padding + half a chip.
# Mirrors the arithmetic the retired settings pill used at the right edge, and
# every module here is an icon-only pill of the same width.
PILL_X=$((8 + 12 + 18))
PILL_Y=$((9 + 24))

# Move before the first click. A press with no preceding motion does not
# hit-test, so the first click of a session lands nowhere while every later one
# works -- which reads as "the pill is dead".
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 3

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
' 2>/dev/null)"

win_json() {
	hl_get "get all-clients" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("clients", []):
    if c.get("title") == "asteroidz settings":
        print(json.dumps(c)); break
'
}

WIN="$(win_json)"
if [ -n "$WIN" ]; then
	ok "the ship opens a toplevel titled \"asteroidz settings\""
else
	bad "the ship opens a toplevel titled \"asteroidz settings\""
fi

read -r WX WY WW WH <<<"$(printf '%s' "$WIN" | python3 -c '
import json, sys
s = sys.stdin.read().strip()
if not s:
    print("0 0 0 0")
else:
    c = json.loads(s)
    print(c["x"], c["y"], c["width"], c["height"])
')"

if [ "$WW" -gt 300 ] && [ "$WH" -gt 300 ]; then
	ok "it has a usable size (${WW}x${WH} at ${WX},${WY})"
else
	bad "it has a usable size (${WW}x${WH} at ${WX},${WY})"
fi

# The window icon, through xdg-toplevel-icon-v1.
#
# Asserted from the COMPOSITOR's side, which is the only place the difference
# shows: the protocol carries an icon name and a set of pixel buffers, asteroidz
# records only the name, and a QIcon built from a file path has no name -- so the
# first version of this sent buffers, looked entirely correct from the shell, and
# left `get all-clients` reporting an empty string.
WIN_ICON="$(printf '%s' "$WIN" | jq -r '.icon // ""')"
if [ "$WIN_ICON" = "asteroidz-settings" ]; then
	ok "the window carries the ship as its icon name ($WIN_ICON)"
else
	bad "the window carries the ship as its icon name (got '$WIN_ICON')"
fi

# ── the sidebar, measured once ──────────────────────────────────────────────
#
# Every entry is the same height and the Column's spacing is 2, so one measured
# pill gives both the pitch and the origin: "All settings" is row 0 and is what a
# left click selects, so the accent pill this finds IS row 0.
shot opened

read -r SB_TOP SB_H <<<"$(python3 - "$WORK/opened.png" "${ACCENT:-#000000}" \
		"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# The sidebar is the left quarter or so, floored at fontPixelSize * 9.
r = wx + max(int(ww * 0.24), 190)
# A FRACTION of the sidebar's width, not a count.
#
# The header of that sidebar is the asteroidz ship, and the ship's exhaust burns
# in the accent -- Logo.qml recolours it to Cfg.focusBg on purpose. At a flat
# threshold of 40 pixels the flame is an accent run about as tall as a row, and
# "the largest run" picked it perfectly plausibly. A selected entry spans the
# whole sidebar minus its padding; the flame spans a couple of dozen pixels.
span = r - wx
rows = [y for y in range(wy, wy + wh)
        if sum(1 for x in range(wx, r)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want)))
           > span * 0.5]
if not rows:
    print("0 0"); raise SystemExit
# The LARGEST run, not the first.
#
# The window is tiled and the compositor draws a focused border around it in the
# same accent, so the first run of accent rows is two pixels of border at the very
# top of the frame -- which is what this found, and a 2px "row height" put every
# computed sidebar position off the end of the list. Exactly one entry is selected
# at a time and every entry is the same height, so the tallest run is the pill.
groups = []
for y in rows:
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
grp = max(groups, key=len)
print(grp[0], grp[-1] - grp[0] + 1)
PY
)"

# One row per option group, then the pages that are not options. The group count
# comes from the schema rather than being hard-coded, so adding a group does not
# silently start clicking the wrong row.
#
# There is no "All settings" row any more, so row 0 is the FIRST GROUP and that
# is also what a freshly opened window selects.
# Indices come from the SORTED label list, because the sidebar is sorted now.
#
# They were arithmetic over the schema order -- Displays at NGROUPS, Wallpaper
# at NGROUPS+1 and so on. Sorting the sidebar made every one of those point at
# a different page, and the damage did not surface as "wrong page": it surfaced
# thirteen assertions later as fields that would not commit and modules that
# would not move, because those pages were never open.
eval "$(hl_get "get config-schema" | python3 -c '
import json, sys
groups = [g["label"] for g in json.load(sys.stdin)["groups"]]
fixed = ["Displays", "Wallpaper", "Modules", "Tags", "Window rules",
         "Keybinds", "Palette", "Notifications", "Push-to-talk"]
rows = sorted(groups + fixed, key=lambda s: s.lower())
for name, label in [("DISPLAYS", "Displays"), ("WALLPAPER", "Wallpaper"),
                    ("MODULES", "Modules"), ("LAYOUTS", "Tags"),
                    ("RULES", "Window rules"), ("BINDS", "Keybinds")]:
    print("%s_ROW=%d" % (name, rows.index(label)))
# The row a freshly opened window selects is the first GROUP, which after
# sorting is no longer row 0 -- and it is the row the accent scan calibrates
# SB_TOP from, so every index below is measured against it.
print("FIRST_GROUP_ROW=%d" % rows.index(groups[0]))
')"

# SB_TOP is the top of the SELECTED row, not of the list.
SB0=$((SB_TOP - FIRST_GROUP_ROW * (SB_H + 2)))
SIDEBAR_X=$((WX + 60))

sidebar_entry_y() { # sidebar_entry_y <index>  ->  the row's vertical centre
	echo $((SB0 + $1 * (SB_H + 2) + SB_H / 2))
}

go_to() { # go_to <row index>
	local y
	y="$(sidebar_entry_y "$1")"
	hl_move "$SIDEBAR_X" "$y"; sleep 1
	hl_click "$SIDEBAR_X" "$y"; sleep 2
}

if [ "${SB_H:-0}" -gt 10 ] && [ "$SB0" -gt "$WY" ]; then
	ok "the sidebar was located (row 0 at $SB0, ${SB_H}px rows)"
else
	bad "the sidebar was located (row 0 at $SB0, ${SB_H}px rows, window at $WY)"
fi

# ── 1b. right click goes straight to Displays ───────────────────────────────
#
# A left click on the ship opens the window as such and lands on All settings --
# the emblem means "this shell", not one page of six. Right click is the shortcut
# to Displays, the page the retired pill's icon used to promise, and it
# has to work on an already-open window, which is the case that is easy to get
# wrong: `open()` sets the page before `visible`, and a window that is already
# visible would keep whatever it was showing if the order were the other way
# round.
#
# Asserted from the page's CONTENT rather than from which sidebar row is lit. The
# highlight only says what the window thinks it is showing; the arrangement canvas
# is the page.
#
# Found by the SELECTED MONITOR'S TILE, which the canvas paints in the accent. The
# canvas fill itself is not usable for this: it is rgba(0,0,0,0.25) over the
# window colour, and the window colour here is already nearly black, so the band
# that looks unmistakable on paper is a delta of about three levels. The tile is
# the accent -- the highest-contrast thing on the page -- and it is tall, which is
# what separates it from the Apply button, the only other accent block that can
# appear in this pane.
accent_block() { # accent_block <shot>  ->  "<top> <height>" of the tallest one
	python3 - "$WORK/$1.png" "${ACCENT:-#000000}" "$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# The content pane only: the sidebar's selected entry is accent too.
l = wx + 12 + max(int(ww * 0.24), 190) + 12
r = min(im.size[0], wx + ww - 4)
top, bot = wy + 2, min(im.size[1], wy + wh - 2)
rows = [y for y in range(top, bot)
        if sum(1 for x in range(l, r)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))) > 20]
if not rows:
    print("0 0"); raise SystemExit
groups = []
for y in rows:
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
grp = max(groups, key=len)
print(grp[0], len(grp))
PY
}

hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y" rclick; sleep 3
shot rightclicked

read -r ARR_TOP ARR_H <<<"$(accent_block rightclicked)"
if [ "${ARR_H:-0}" -gt 40 ]; then
	ok "right click goes straight to Displays (monitor tile ${ARR_H}px at y $ARR_TOP)"
else
	bad "right click goes straight to Displays (monitor tile ${ARR_H}px at y $ARR_TOP)"
fi

# ── 1c. the Displays page stages, and Apply commits ─────────────────────────
#
# The one assertion this page cannot do without. Every other control in this
# window previews live, and this page deliberately does not: passing THROUGH a
# resolution on the way to the one you wanted would mode-set to each, and a mode
# set is a black screen for a moment. A picker that applied per click was the
# original bug, and it is invisible from the QML.
#
# Scale, not resolution: the harness output has one mode, so a resolution picker
# has one entry and picking it changes nothing measurable. Scale is a free number
# the compositor applies to any output.
mon_scale() {
	hl_get "get all-monitors" \
		| jq -r --arg m "$HL_MON" '.monitors[] | select(.name==$m) | .scale'
}

# The page's form rows: "<top> <bottom> <control-centre-x>" each, top to bottom.
#
# Found in the pixels rather than computed, and that is not caution. Above the
# first row sit an intro paragraph that wraps to a font-dependent number of
# lines, a canvas whose height is font-derived, and a summary line -- so an
# offset from the top of the pane is wrong by a different amount at every theme.
#
# Everything here is measured against the pane's own background rather than
# against a brightness threshold. The sibling version of this in click-test.sh
# assumed a dark panel on a light wallpaper, which was true of a popover over the
# desktop and is not true of a toplevel: this window is drawn on panelColor,
# whatever the theme made that, and the headless theme makes it bright.
#
# A row is a run of label text with a filled control rect on the same scanline.
# The controls share one column, so the rows are the lines whose widest non-
# background run starts at the column most of them agree on -- which is what
# separates a FormRow from the arrangement hint, a line of text crossing a widget
# that would otherwise read as a row and shift every index by one.
form_rows() { # form_rows <shot>
	python3 - "$WORK/$1.png" "$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
wx, wy, ww, wh = (int(v) for v in sys.argv[2:6])
# The content pane: right of the sidebar, below the header, above the footer.
# The page inset, the sidebar, and the card's own padding. The cards are inset
# from the window now, so the pane no longer starts a fraction of the way across
# the frame.
x0 = wx + 12 + max(int(ww * 0.24), 190) + 12 + 8
x1 = min(im.size[0], wx + ww - 20)
y0, y1 = wy + 75, min(im.size[1], wy + wh - 20)

sample = [px[x, y] for y in range(y0, y1, 2) for x in range(x0, x1, 2)]
if not sample:
    raise SystemExit
bg = Counter(sample).most_common(1)[0][0]

def near(c, other, tol):
    return all(abs(a - b) <= tol for a, b in zip(c, other))

def text(c):
    # Glyphs are drawn in the foreground colour, which is as far from the
    # surface as anything on the page gets.
    return not near(c, bg, 40)

def runs(y):
    out, start = [], None
    for x in range(x0, x1):
        if not near(px[x, y], bg, 3):
            if start is None:
                start = x
        else:
            if start is not None and x - start > 40:
                out.append((start, x))
            start = None
    if start is not None and x1 - start > 40:
        out.append((start, x1))
    return out

ys = [y for y in range(y0, y1) if sum(1 for x in range(x0, x1) if text(px[x, y])) > 3]
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

BEFORE_SCALE="$(mon_scale)"
mapfile -t DROWS < <(form_rows rightclicked)

# Resolution, Refresh, Scale, VRR, [HDR,] ICC profile. Scale is the one to
# drive: it is the only picker guaranteed to have more than one value on a
# virtual output, whose mode list the compositor may report as a single entry.
# Counted from the TOP and stopping at Scale, because the HDR row is present only
# on an output that reports itself capable -- so every index after it is
# conditional and the first three are not.
if [ "${#DROWS[@]}" -ge 3 ]; then
	read -r SY0 SY1 CTRL_X <<<"${DROWS[2]}"
	SCALE_Y=$(((SY0 + SY1) / 2))
	ROW_H=$((SY1 - SY0 + 18))
	echo "  ..   Scale row at y=$SCALE_Y, control at x=$CTRL_X"

	hl_move "$CTRL_X" "$SCALE_Y"; sleep 1
	hl_click "$CTRL_X" "$SCALE_Y"; sleep 2
	shot listopen

	# The FIRST row of the open list, positioned from the picker's own header.
	#
	# "Two rows down" is what this did first, and it picked the value that was
	# already current: the list opens four pixels under a header whose height is
	# font-derived, so an offset built from the label's glyph extent lands a row
	# out. Nothing failed -- the staging assertion below passes just as happily
	# when nothing was staged at all, which is precisely why the value that
	# followed it could not be applied and the Apply assertion failed instead,
	# one step removed from the cause.
	#
	# So the header is measured instead. It is the first run of non-background
	# rows in the control column at the picker's own y, and the list rows are the
	# same height as it -- `Picker.rowHeight` draws both -- so the first row's
	# centre is one header-height plus the 4px gap below the header's bottom edge.
	# Scale's values start at 0.75 and the current value is 1, so row 0 is always
	# a change. It is put back afterwards.
	read -r HDR_TOP HDR_BOT <<<"$(python3 - "$WORK/listopen.png" "$CTRL_X" "$SCALE_Y" \
			"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
cx, sy = int(sys.argv[2]), int(sys.argv[3])
wx, wy, ww, wh = (int(v) for v in sys.argv[4:8])
l = wx + 12 + max(int(ww * 0.24), 190) + 12 + 8
r = min(im.size[0], wx + ww - 20)
top, bot = wy + 75, min(im.size[1], wy + wh - 10)
bg = Counter(px[x, y] for y in range(top, bot, 2)
             for x in range(l, r, 2)).most_common(1)[0][0]
def isbg(c):
    return all(abs(a - b) <= 3 for a, b in zip(c, bg))
# sy is inside the header (it is the row's text centre); walk both ways.
a = sy
while a > top and not isbg(px[cx, a - 1]):
    a -= 1
b = sy
while b < bot - 1 and not isbg(px[cx, b + 1]):
    b += 1
print(a, b)
PY
)"
	HDR_H=$((HDR_BOT - HDR_TOP + 1))

	# ── Escape closes an open list ──────────────────────────────────────
	#
	# Reported live: "when pressing escape while a dropdown is open the dropdown
	# is not closed". It is a gap this window CREATED. In the bar a Picker was
	# always inside a popover, and Bar.qml forwarded Escape to Popover.handleKey,
	# which closed the whole panel and took the list with it. A toplevel has no
	# surrounding popover, so the key reached nothing at all.
	#
	# Measured by the list's ACCENT ROW, not by its fill.
	#
	# The fill cannot be used. It is Cfg.popoverColor, and the window under it is
	# Cfg.panelColor forced opaque -- the same three channels at a different
	# alpha, so composited they land about two levels apart and any tolerance
	# loose enough to survive dithering swallows the difference. A first version
	# counted "rows that are not the pane background" and reported 61 with the
	# list open and 61 with it closed, which is a test that cannot fail.
	#
	# An open list always draws its CURRENT value in the accent, which is the
	# highest-contrast thing in the window and appears nowhere else in this band:
	# the monitor tile is above the picker and the Apply button below it.
	list_accent() { # list_accent <shot>  ->  accent rows just under the picker
		python3 - "$WORK/$1.png" "${ACCENT:-#000000}" "$CTRL_X" "$SCALE_Y" \
				"$WX" "$WW" <<'ACCPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
cx, sy = int(sys.argv[3]), int(sys.argv[4])
wx, ww = int(sys.argv[5]), int(sys.argv[6])
if len(acc) != 6:
    print(0); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
x0 = max(0, cx - 40)
x1 = min(im.size[0], cx + 40)
y1 = min(im.size[1], sy + 220)
n = 0
for y in range(sy, y1):
    hits = sum(1 for x in range(x0, x1)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want)))
    if hits > (x1 - x0) * 0.6:
        n += 1
print(n)
ACCPY
	}

	OPEN_EXTENT="$(list_accent listopen)"
	# Pressed TWICE, for the reason click-test.sh gives at length: wlvkbd is a
	# one-shot client, so the seat advertises a keyboard only while it lives and
	# the first press can arrive as a release alone. The second is a no-op on an
	# already-closed list.
	"$HL_WLVKBD" press ESC >/dev/null 2>&1; sleep 1
	"$HL_WLVKBD" press ESC >/dev/null 2>&1; sleep 2
	shot escaped
	ESC_EXTENT="$(list_accent escaped)"

	# The premise first: if the list was not open, the assertion below is
	# meaningless however it lands.
	if [ "${OPEN_EXTENT:-0}" -gt 10 ]; then
		ok "the dropdown is open to begin with (${OPEN_EXTENT}px of accent)"
	else
		bad "the dropdown is open to begin with (${OPEN_EXTENT}px of accent)"
	fi

	if [ "${OPEN_EXTENT:-0}" -gt 10 ] && [ "${ESC_EXTENT:-999}" -eq 0 ]; then
		ok "Escape closes an open dropdown ($OPEN_EXTENT -> $ESC_EXTENT px accent)"
	else
		bad "Escape closes an open dropdown ($OPEN_EXTENT -> $ESC_EXTENT px accent)"
	fi

	# Open it again for the pick below, which is what the rest of this section is
	# about.
	hl_click "$CTRL_X" "$SCALE_Y"; sleep 2
	hl_click "$CTRL_X" $((HDR_BOT + 4 + HDR_H / 2)); sleep 3

	AFTER_PICK="$(mon_scale)"
	if [ "$AFTER_PICK" = "$BEFORE_SCALE" ]; then
		ok "picking a scale stages it instead of applying ($BEFORE_SCALE unchanged)"
	else
		bad "picking a scale stages it instead of applying ($BEFORE_SCALE -> $AFTER_PICK)"
	fi

	# Apply. The accent-filled button at the foot of the page.
	#
	# It is drawn in the accent ONLY while something is staged, so finding it is
	# the assertion the check above cannot make: "the value did not change" is
	# also true of a pick that never registered, and this is what tells the two
	# apart before the click that depends on it.
	#
	# The LOWEST accent run in the pane, not any of them -- the monitor tile above
	# is accent too, and is much bigger.
	shot staged
	read -r AP_X AP_Y <<<"$(python3 - "$WORK/staged.png" "${ACCENT:-#000000}" \
			"$WX" "$WY" "$WW" "$WH" "$ARR_TOP" "$ARR_H" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
arr_top, arr_h = (int(v) for v in sys.argv[7:9])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# The content pane only: the sidebar's selected entry is accent too. And below
# the arrangement canvas, whose selected tile is the largest accent block here.
# The page inset, the sidebar, and the card's own padding. The cards are inset
# from the window now, so the pane no longer starts a fraction of the way across
# the frame.
x0 = wx + 12 + max(int(ww * 0.24), 190) + 12 + 8
x1 = min(im.size[0], wx + ww - 20)
y0 = max(wy + 75, arr_top + arr_h + 4)
y1 = min(im.size[1], wy + wh - 10)
best = None
for y in range(y0, y1):
    start = None
    for x in range(x0, x1 + 1):
        hit = x < x1 and all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))
        if hit and start is None:
            start = x
        elif not hit and start is not None:
            if x - start > 30:
                best = (y, (start + x) // 2)
            start = None
print(best[1], best[0]) if best else print("0 0")
PY
)"

	if [ "${AP_X:-0}" -gt 0 ]; then
		hl_move "$AP_X" "$AP_Y"; sleep 1
		hl_click "$AP_X" "$AP_Y"; sleep 3
		AFTER_APPLY="$(mon_scale)"
		if [ "$AFTER_APPLY" != "$BEFORE_SCALE" ]; then
			ok "Apply commits the staged scale ($BEFORE_SCALE -> $AFTER_APPLY)"
		else
			bad "Apply commits the staged scale (still $AFTER_APPLY)"
		fi
	else
		bad "the pick registered and lit Apply (no accent button in the pane)"
	fi
else
	bad "the Displays page shows its form rows (found ${#DROWS[@]})"
fi

# Put the output back, or every later screenshot is measured on a rescaled
# monitor and the window coordinates read from `get all-clients` stop agreeing
# with the pixels.
hl_dispatch "set_output_scale,$HL_MON,$BEFORE_SCALE" 2

# ── 1d. the Wallpaper page applies as you type ──────────────────────────────
#
# The opposite model to the page beside it, and the assertion is that it really
# is the opposite: no Apply, the value lands when the field is committed. The
# proof is outside the bar -- a line in wallpaper.conf, which is the file the
# shell's own wallpaper reads.
go_to "$WALLPAPER_ROW"
shot wallpaperpage

BEFORE_CONF="$(grep '^folder=' "$WORK/wallpaper.conf" 2>/dev/null)"
mapfile -t WROWS < <(form_rows wallpaperpage)
if [ "${#WROWS[@]}" -ge 1 ]; then
	read -r WY0 WY1 WCTRL <<<"${WROWS[0]}"
	FLD_Y=$(((WY0 + WY1) / 2))
	hl_move "$WCTRL" "$FLD_Y"; sleep 1
	hl_click "$WCTRL" "$FLD_Y"; sleep 1
	shot wpfocus

	# A focused field has to LOOK focused.
	#
	# "You can type stuff in but it is not clear you're actually focused on the
	# field" was reported separately from keys not arriving, and it is a different
	# bug: TextInput draws its own caret from activeFocus, and in a popover that
	# depends on whether the popup's window is active rather than on where the
	# keys are going. Field draws an accent outline and forces the caret on, keyed
	# to `keysHere` -- which answers with the popover's keyTarget in a popover and
	# with Qt's own focus in an ordinary window. This is the ordinary-window half,
	# and it is the only half left: every Field in this shell is in this window.
	#
	# Measured as accent pixels gained in the FIELD'S OWN ROW, not in the pane.
	# The pair of shots straddles nothing but the click, but the pane below holds
	# the wallpaper browser, whose selected tile carries an accent border -- and
	# whose model is this very directory, which every `shot` in this file adds a
	# PNG to. A pane-wide count would move with the thumbnails and could pass on a
	# newly-arrived tile instead of on an outline.
	FOCUS_ACCENT="$(python3 - "$WORK/wallpaperpage.png" "$WORK/wpfocus.png" \
			"${ACCENT:-#000000}" "$WX" "$((WY0 - 8))" "$WW" \
			"$((WY1 - WY0 + 17))" <<'PY'
import sys
from PIL import Image
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
pa, pb = a.load(), b.load()
acc = sys.argv[3].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[4:8])
if len(acc) != 6:
    print(0); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
def near(c, tol=20):
    return all(abs(x - y) <= tol for x, y in zip(c, want))
x0 = wx + 12 + max(int(ww * 0.24), 190) + 12
x1 = min(a.size[0], b.size[0], wx + ww - 4)
y0, y1 = wy + 2, min(a.size[1], b.size[1], wy + wh - 2)
before = sum(1 for y in range(y0, y1) for x in range(x0, x1) if near(pa[x, y]))
after = sum(1 for y in range(y0, y1) for x in range(x0, x1) if near(pb[x, y]))
print(after - before)
PY
)"
	if [ "${FOCUS_ACCENT:-0}" -gt 100 ]; then
		ok "a focused field is outlined in the accent (+${FOCUS_ACCENT}px)"
	else
		bad "a focused field is outlined in the accent (+${FOCUS_ACCENT}px)"
	fi

	for k in Q Q Q; do "$HL_WLVKBD" press "$k" >/dev/null 2>&1; sleep 0.3; done
	"$HL_WLVKBD" press ENTER >/dev/null 2>&1
	sleep 2
	AFTER_CONF="$(grep '^folder=' "$WORK/wallpaper.conf" 2>/dev/null)"
	if [ "$AFTER_CONF" != "$BEFORE_CONF" ]; then
		ok "committing the Folder field writes wallpaper.conf ($AFTER_CONF)"
	else
		bad "committing the Folder field writes wallpaper.conf (still '$AFTER_CONF')"
	fi
	# Back, so the browser below still has this run's images in it.
	printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
		> "$WORK/wallpaper.conf"

	# ── the folder is watched ───────────────────────────────────────────
	#
	# A file appearing while the page is OPEN has to show up. Nothing polls and
	# nothing rescans on its own; an inotify watcher does, debounced so a burst
	# is one scan.
	#
	# In a folder of its OWN, which the first version of this got wrong. The
	# harness's wallpaper folder is $WORK -- where every screenshot in this file
	# is written -- so the browser was already full of its own shots, the grid
	# overflowed the pane, and one more tile landed below the fold: 3511 ink
	# before and 3511 after, with the watcher working perfectly.
	WATCHDIR="$WORK/watched"
	mkdir -p "$WATCHDIR"
	printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WATCHDIR" "$WORK/wall.png" \
		> "$WORK/wallpaper.conf"
	sleep 3
	shot beforenewfile

	# The empty folder is the baseline, and it is asserted rather than assumed:
	# if the page were still showing the old folder the count below would move
	# for the wrong reason.
	# The CONTENT PANE below the form rows, which is where the grid is.
	#
	# "The bottom half of the window" was the first try and it measured the
	# SIDEBAR -- whose row labels never change -- so it reported 3511 before and
	# 3511 after, twice, against a watcher that was working. The page is short
	# when the folder is empty, so the grid sits high; the sidebar is the only
	# thing down there at all.
	PANE_L=$((WX + 12 + 450 + 12))
	GRID_T=$((WY + 260))
	EMPTY_INK="$(ink beforenewfile "$PANE_L" "$GRID_T" \
		"$((WX + WW))" "$((WY + WH))")"

	magick -size 320x180 xc:'#e04040' "$WATCHDIR/zz-watched.png"
	sleep 3
	shot afternewfile
	FULL_INK="$(ink afternewfile "$PANE_L" "$GRID_T" \
		"$((WX + WW))" "$((WY + WH))")"

	if [ "${FULL_INK:-0}" -gt "$((EMPTY_INK + 200))" ]; then
		ok "a file added to the folder appears without reopening the page ($EMPTY_INK -> $FULL_INK ink)"
	else
		bad "a file added to the folder appears without reopening the page ($EMPTY_INK -> $FULL_INK ink)"
	fi

	printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
		> "$WORK/wallpaper.conf"
	rm -rf "$WATCHDIR"
else
	bad "the Wallpaper page shows its form rows (found ${#WROWS[@]})"
fi

# ── on to the options ───────────────────────────────────────────────────────
#
# Everything below is about the schema-driven half of the window.
go_to "$FIRST_GROUP_ROW"

# ── 2. it is populated ──────────────────────────────────────────────────────
#
shot settings
FULL_INK="$(ink settings "$WX" "$WY" $((WX + WW)) $((WY + WH)))"
if [ "${FULL_INK:-0}" -gt 2000 ]; then
	ok "the pane is populated (${FULL_INK} ink px)"
else
	bad "the pane is populated (${FULL_INK} ink px)"
fi

# ── 3. search narrows it ────────────────────────────────────────────────────
#
# The search field spans the header from the sidebar to the Close button, so it
# is the widest target in the window; clicking a third of the way across it is
# inside it for any sidebar width.
# A control in the page heading, counted from the RIGHT: 0 is Close, 1 is the
# search box beside it.
#
# Found by its TEXT, not by its fill, and that is the second time this window has
# taught the same lesson. A field is rgba(1,1,1,0.06) and a button
# rgba(1,1,1,0.08) over a card that is nearly black, so both sit four or five
# levels from their background -- inside any tolerance loose enough to survive
# dithering, which is why a fill-based scan returned nothing at all and the
# search click went to 0,0. Glyphs are drawn in the foreground colour and are
# unmistakable.
#
# The topmost y-run of the cluster, because the rightmost column of the pane also
# holds the scroll indicator, which is bright enough to join the button's cluster
# and drag its centre down past the bottom of the button.
heading_box() { # heading_box <shot> <nth-from-right>  ->  "x y"
	python3 - "$WORK/$1.png" "$2" "$WX" "$WY" "$WW" "$WH" <<'HEADPY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
nth = int(sys.argv[2])
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
x0 = max(wx + 12 + max(int(ww * 0.24), 190),
         wx + ww - max(260, int(ww * 0.26)))
x1 = min(im.size[0], wx + ww - 2)
y0, y1 = wy + 8, min(im.size[1], wy + 8 + 110)
if x1 <= x0 or y1 <= y0:
    print(0, 0); raise SystemExit
sample = [px[x, y] for y in range(y0, y1) for x in range(x0, x1, 2)]
bg = Counter(sample).most_common(1)[0][0]
def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
thr = lum(bg) + 40
xs = sorted({x for y in range(y0, y1) for x in range(x0, x1)
             if lum(px[x, y]) > thr})
# 12, not 25. The search box is OUTLINED IN THE ACCENT while it is focused, and
# that outline is bright: at 25 the field's right edge and Close's first letter
# are one cluster, whose centre is the empty space between them. Close was duly
# "found" at 1734 and the click went nowhere. Letters within a word are two or
# three pixels apart, so 12 keeps a word together and keeps two controls apart.
clusters = []
for x in xs:
    if clusters and x - clusters[-1][-1] <= 12:
        clusters[-1].append(x)
    else:
        clusters.append([x])
if len(clusters) <= nth:
    print(0, 0); raise SystemExit
c = clusters[len(clusters) - 1 - nth]
ys = [y for y in range(y0, y1)
      if any(lum(px[x, y]) > thr for x in range(c[0], c[-1] + 1))]
grp = [ys[0]]
for y in ys[1:]:
    if y - grp[-1] <= 3:
        grp.append(y)
    else:
        break
print((c[0] + c[-1]) // 2, (grp[0] + grp[-1]) // 2)
HEADPY
}

# The search box is in the page heading now, at the top right beside Close --
# not a full-width bar across the pane, which is what "half way across, one
# header-row down" assumed. Clicking there landed on the heading's title text,
# the query never arrived, the pane never narrowed, and the toggle that was then
# located belonged to whichever option happened to be first in the group.
#
# Measured: the second box from the right in the heading band. Close is the
# rightmost; this is the one beside it.
read -r SEARCH_X SEARCH_Y <<<"$(heading_box settings 1)"
echo "  ..   search box located at ${SEARCH_X},${SEARCH_Y}"
hl_move "$SEARCH_X" "$SEARCH_Y"; sleep 1
hl_click "$SEARCH_X" "$SEARCH_Y"; sleep 1

# wlvkbd is a one-shot client: it connects, makes a virtual keyboard, sends the
# key and exits, so the seat only advertises a keyboard while it is alive. On the
# very first press the client is still binding wl_keyboard and receives only the
# release. Hence a throwaway press before the real ones.
#
# And a BACKSPACE after it, which is the part that took three runs to work out.
# Whether the throwaway lands is a race, so sometimes the search box already held
# an "a" and the query became "asmartgaps" -- which matches nothing, so the pane
# was empty, so the control locator found nothing, so six assertions failed
# together roughly one run in three. Backspace is a no-op on an empty field and
# undoes the stray character on a non-empty one, which makes the starting state
# the same either way.
"$HL_WLVKBD" press A >/dev/null 2>&1; sleep 0.4
"$HL_WLVKBD" press BACKSPACE >/dev/null 2>&1; sleep 0.4
for k in S M A R T G A P S; do
	"$HL_WLVKBD" press "$k" >/dev/null 2>&1
	sleep 0.25
done
sleep 1
shot searched
NARROW_INK="$(ink searched "$WX" "$WY" $((WX + WW)) $((WY + WH)))"

# A single option and its one-line explanation, against ninety-five of them.
if [ "${NARROW_INK:-0}" -lt $((FULL_INK / 2)) ] && [ "${NARROW_INK:-0}" -gt 100 ]
then
	ok "searching narrows the pane (${FULL_INK} -> ${NARROW_INK} ink px)"
else
	bad "searching narrows the pane (${FULL_INK} -> ${NARROW_INK} ink px)"
fi

value_of() { # value_of <key>  ->  "<value> <source-kind>"
	hl_get "get config" | python3 -c '
import json, sys
k = sys.argv[1]
v = json.load(sys.stdin).get("values", {}).get(k)
if v is None:
    print("MISSING none")
else:
    print(v.get("value"), (v.get("source") or {}).get("kind"))
' "$1"
}

read -r SG_VAL SG_KIND <<<"$(value_of smartgaps)"
if [ "$SG_VAL" = "0" ]; then
	ok "smartgaps starts off (value=$SG_VAL from $SG_KIND)"
else
	bad "smartgaps starts off (value=$SG_VAL from $SG_KIND)"
fi

# ── 4. a control reaches the compositor ─────────────────────────────────────
#
# Located by its own colour, not by arithmetic over row heights. A Toggle that is
# off is a flat 10%-white pill on an opaque background, which is the widest
# contiguous run of one non-background colour anywhere in the pane -- glyphs are
# thin and antialiased, so nothing else comes close. Getting this wrong can only
# make the assertion below FAIL: nothing else in this window writes smartgaps.
# A control in the pane, located by its own shape rather than by arithmetic over
# row heights.
#
# `which` is "first" or "last": with the pane narrowed to one option there is one
# row, whose control sits on its first line and whose Reset sits on its third. So
# the topmost candidate is the control and the bottommost is Reset, and neither has
# to be told how tall a row is.
#
# Getting either wrong can only make the assertion that follows FAIL -- nothing
# else in this window writes smartgaps.
control_at() { # control_at <shot> <which>  ->  "x y"
	python3 - "$WORK/$1.png" "$2" "$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
which = sys.argv[2]
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
# The control column: right of the label column, which is right of the sidebar.
#
# It used to be "the right-hand third", because controls were flush to the pane's
# right edge. They start at one x now -- the label column is 30% of the pane and
# every control begins just past it -- so a scan of the right-hand third finds
# the empty space beside a toggle and calls it background. That is the whole of
# why eleven assertions failed after the restyle while the window worked: the
# toggle click landed on nothing, so nothing staged, and every claim about a
# staged value followed it down.
pane = wx + 12 + max(int(ww * 0.24), 190) + 12
l = pane + 8
r = wx + ww - 12
# Below the HEADER, not from the top of the window. The search field is a flat
# non-background block spanning almost the full width, so a scan that includes it
# finds it every time -- the first run of this located the "toggle" at wy + 40,
# which is the search box, and the click went there.
#
# panelPadding + one header row + panelPadding again.
top = wy + 75
bot = wy + wh - 60
bg = Counter(px[x, y] for y in range(top, bot, 2)
             for x in range(l, r, 2)).most_common(1)[0][0]
def isbg(c):
    return all(abs(a - b) <= 12 for a, b in zip(c, bg))
found = []
for y in range(top, bot):
    cur = None
    x0 = l
    for x in range(l, r + 1):
        c = px[x, y] if x < r else None
        if c is not None and cur is not None \
                and all(abs(a - b) <= 3 for a, b in zip(c, cur)):
            continue
        # Bounded, not just "widest".
        #
        # A Toggle is implicitWidth 44, a Reset button is about 60, and a glyph
        # stroke is two or three pixels -- so 20 to 90 is a control and nothing
        # else is. The upper bound is what keeps a full-width block (a field, the
        # apply bar) from winning by being enormous.
        n = x - x0
        if cur is not None and not isbg(cur) and 20 <= n <= 90:
            found.append((y, (x0 + x) // 2, n))
        cur = c
        x0 = x
if not found:
    print("0 0"); raise SystemExit
# Group by row: a control is many scanlines tall, and every one of them is a hit.
rows = []
for y, cx, n in found:
    if rows and y - rows[-1][-1][0] <= 3:
        rows[-1].append((y, cx, n))
    else:
        rows.append([(y, cx, n)])
grp = rows[0] if which == "first" else rows[-1]
mid = grp[len(grp) // 2]
print(mid[1], mid[0])
PY
}

read -r TG_X TG_Y <<<"$(control_at searched first)"

if [ "${TG_X:-0}" -gt 0 ]; then
	ok "the toggle was located (${TG_X},${TG_Y})"
else
	bad "the toggle was located"
fi

# The baseline for "a preview does not touch the config file", taken HERE rather
# than before the bar started.
#
# The Displays page above legitimately writes to it: an output setting is applied
# by a dispatch, and the compositor persists that itself, rewriting the `output`
# block in whichever file declares it -- which in this harness is this file. That
# is the documented behaviour of output_persist and it is not what this assertion
# is about. Comparing against the file as it was at startup made a correct write
# on one page fail an assertion about a different page's preview path.
CONFIG_BEFORE="$(cat "$HL_CONFIG")"

hl_move "$TG_X" "$TG_Y"; sleep 1
hl_click "$TG_X" "$TG_Y"; sleep 2

read -r SG_VAL SG_KIND <<<"$(value_of smartgaps)"
# `runtime`, not `file`: a preview is memory only. Asserting the KIND as well as
# the value is what distinguishes "the click worked" from "the click worked and
# wrote to disk without being asked", which is the one outcome that would be
# worse than nothing happening.
if [ "$SG_VAL" = "1" ] && [ "$SG_KIND" = "runtime" ]; then
	ok "clicking the toggle previews it in memory (value=$SG_VAL from $SG_KIND)"
else
	bad "clicking the toggle previews it in memory (value=$SG_VAL from $SG_KIND)"
fi

if [ "$(cat "$HL_CONFIG")" = "$CONFIG_BEFORE" ]; then
	ok "a preview does not touch the config file"
else
	bad "a preview does not touch the config file"
fi

# ── 5. Apply persists ───────────────────────────────────────────────────────
#
# Bottom-right of the window, in the apply bar. Apply is the rightmost of the two
# buttons, one panel-padding in from the edge.
# Apply is the accent-filled button in the bar at the foot of the content card,
# and it is only accent while something is staged -- which is the state this is
# clicked in. Measured, for the same reason Close is: the bar is inside the card
# now, so an offset from the window's bottom-right corner lands on the page
# behind it.
apply_button() { # apply_button <shot>  ->  "x y" of the lowest accent block
	python3 - "$WORK/$1.png" "${ACCENT:-#000000}" "$WX" "$WY" "$WW" "$WH" <<'APPLYPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print(0, 0); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
x0 = wx + max(int(ww * 0.24), 190) + 10
x1 = min(im.size[0], wx + ww - 14)
y0, y1 = wy + 60, min(im.size[1], wy + wh - 14)
# Rows carrying a wide accent run, grouped into blocks.
#
# "The lowest such row" is what this did first, and the lowest accent row in the
# window is not the button: asteroidz draws a FOCUSED BORDER around the window in
# the accent, so the bottom edge of the frame is a full-width accent run a couple
# of pixels tall. It measured 1058 for a button that ends at 1047, and the click
# landed on the border. A block at least ten rows tall is a button; two rows is a
# frame.
rows = []
for y in range(y0, y1):
    start, best = None, None
    for x in range(x0, x1 + 1):
        hit = x < x1 and all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))
        if hit and start is None:
            start = x
        elif not hit and start is not None:
            if x - start > 30 and (best is None or x - start > best[1] - best[0]):
                best = (start, x)
            start = None
    if best is not None:
        rows.append((y, (best[0] + best[1]) // 2))
groups = []
for y, cx in rows:
    if groups and y - groups[-1][-1][0] <= 2:
        groups[-1].append((y, cx))
    else:
        groups.append([(y, cx)])
groups = [g for g in groups if len(g) >= 10]
if not groups:
    print(0, 0); raise SystemExit
g = groups[-1]
mid = g[len(g) // 2]
print(mid[1], mid[0])
APPLYPY
}

shot staging
read -r APPLY_X APPLY_Y <<<"$(apply_button staging)"
echo "  ..   Apply button at ${APPLY_X},${APPLY_Y}"
hl_move "$APPLY_X" "$APPLY_Y"; sleep 1
hl_click "$APPLY_X" "$APPLY_Y"; sleep 3

read -r SG_VAL SG_KIND <<<"$(value_of smartgaps)"
if [ "$SG_VAL" = "1" ] && [ "$SG_KIND" = "file" ]; then
	ok "Apply moves it into a file (value=$SG_VAL from $SG_KIND)"
else
	bad "Apply moves it into a file (value=$SG_VAL from $SG_KIND)"
fi

if grep -q 'smartgaps' "$HL_CONFIG"; then
	ok "the key is in the config file"
else
	bad "the key is in the config file"
fi

# The free oracle: the compositor's own config checker on the file its writer
# just produced. "Apply must never leave me with a config that does not load" is
# what a settings app owes this file, and this is the one assertion that proves
# it.
if "$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | grep -q 'config OK'; then
	ok "the written config still parses"
else
	bad "the written config still parses"
	"$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | head -5 | sed 's/^/       /'
fi

# A hand-written line, and the comment above it, are the reason the writer edits
# bytes instead of round-tripping the document -- so check they survived. It is
# also at a NON-canonical path (`misc { border_radius }`, whose canonical
# spelling is a bare top-level node), which is the shape that a writer assuming
# canonical paths would silently duplicate rather than edit in place.
if grep -q 'misc { border_radius 9 }' "$HL_CONFIG" \
   && grep -q 'the writer must leave exactly as it found it' "$HL_CONFIG"; then
	ok "the rest of the file is intact"
else
	bad "the rest of the file is intact"
fi

# ── 6. Reset removes the declaration ────────────────────────────────────────
#
# A distinct path, not "apply the default": `value: null` asks the compositor to
# delete the line and fall back, which is a different edit to the file and a
# different provenance afterwards. Writing the default in instead would leave the
# key in the config as an explicit setting that happens to match the default --
# indistinguishable to read, and it comes back the moment the default changes.
shot applied
read -r RS_X RS_Y <<<"$(control_at applied last)"
if [ "${RS_X:-0}" -gt 0 ] && [ "${RS_Y:-0}" -gt "${TG_Y:-0}" ]; then
	ok "the Reset button appeared below the control (${RS_X},${RS_Y})"
else
	bad "the Reset button appeared below the control (${RS_X},${RS_Y} vs toggle y ${TG_Y})"
fi

hl_move "$RS_X" "$RS_Y"; sleep 1
hl_click "$RS_X" "$RS_Y"; sleep 2
read -r SG_VAL SG_KIND <<<"$(value_of smartgaps)"
if [ "$SG_VAL" = "0" ]; then
	ok "Reset previews the default (value=$SG_VAL from $SG_KIND)"
else
	bad "Reset previews the default (value=$SG_VAL from $SG_KIND)"
fi

shot beforesecondapply
hl_move "$APPLY_X" "$APPLY_Y"; sleep 1
hl_click "$APPLY_X" "$APPLY_Y"; sleep 3
shot aftersecondapply
if ! grep -q 'smartgaps' "$HL_CONFIG"; then
	ok "Apply removes the line from the config file"
else
	bad "Apply removes the line from the config file"
	grep -n smartgaps "$HL_CONFIG" | sed 's/^/       /'
fi
read -r SG_VAL SG_KIND <<<"$(value_of smartgaps)"
if [ "$SG_VAL" = "0" ] && [ "$SG_KIND" = "default" ]; then
	ok "and the value goes back to being the default (from $SG_KIND)"
else
	bad "and the value goes back to being the default (value=$SG_VAL from $SG_KIND)"
fi
if "$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | grep -q 'config OK'; then
	ok "the config still parses after a removal"
else
	bad "the config still parses after a removal"
fi

# ── 7. closing undoes an unapplied preview ──────────────────────────────────
#
# The trap this window would otherwise ship with: a preview is memory-only, so a
# value previewed and not applied is in no file and reverts at the next reload.
# Leaving it running looks like settings that forget themselves an hour later.
# The declaration is gone now, so this previews AWAY from the default and closing
# has to put the default back.
hl_move "$TG_X" "$TG_Y"; sleep 1
hl_click "$TG_X" "$TG_Y"; sleep 2
read -r SG_VAL _ <<<"$(value_of smartgaps)"
PREVIEWED_ON="$SG_VAL"

# Measured rather than computed from the window corner. The button sits inside
# the content card now, so its offset is the page inset plus the card's own
# padding plus its height -- three theme values, each of which a restyle moves.
# It is the topmost filled box at the right-hand end of the pane, which is a
# description the layout cannot invalidate.
read -r CLOSE_X CLOSE_Y <<<"$(heading_box applied 0)"
echo "  ..   Close button at ${CLOSE_X},${CLOSE_Y}"
hl_move "$CLOSE_X" "$CLOSE_Y"; sleep 1
hl_click "$CLOSE_X" "$CLOSE_Y"; sleep 3

if [ -z "$(win_json)" ]; then
	ok "Close closes the window"
else
	bad "Close closes the window"
fi

read -r SG_VAL SG_KIND <<<"$(value_of smartgaps)"
# The KIND matters as much as the value.
#
# An earlier version reverted by writing the old value back with persist:false,
# which restored the number and left the provenance reading `runtime` -- so a key
# sitting in config.kdl reported itself as "changed in memory, not saved" from then
# on. The value assertion passed and the bug was real; only asserting the source
# caught it.
if [ "$PREVIEWED_ON" = "1" ] && [ "$SG_VAL" = "0" ] \
		&& [ "$SG_KIND" = "default" ]; then
	ok "closing undoes an unapplied preview (1 -> $SG_VAL/$SG_KIND)"
else
	bad "closing undoes an unapplied preview (previewed=$PREVIEWED_ON now=$SG_VAL/$SG_KIND)"
fi

# ── 8. the rule and bind editors ────────────────────────────────────────────
#
# Their Loaders start inactive, so "the shell loads without QML errors" says
# nothing about them: a broken type in RulesPage would never be instantiated and
# would never report. Getting there is the point of these.

# Reopened, because section 7 closed it. Deliberately by the same route rather
# than by leaving the window up: this is also the assertion that a second open
# works at all, which is a real question -- the window object is kept and reused,
# and `discardPending` ran on the way out.
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 3

WIN="$(win_json)"
if [ -n "$WIN" ]; then
	ok "the settings window reopens"
else
	bad "the settings window reopens"
fi
read -r WX WY WW WH <<<"$(printf '%s' "$WIN" | python3 -c '
import json, sys
s = sys.stdin.read().strip()
if not s:
    print("0 0 0 0")
else:
    c = json.loads(s)
    print(c["x"], c["y"], c["width"], c["height"])
')"
shot reopened

# Measured again rather than reused: the window was unmapped and remapped, and
# nothing promises the compositor put it back at the same coordinates. Same scan
# as section 1: a left click reopens on the page that was showing when it closed,
# which was All settings, so this is row 0 again.
read -r SB_TOP SB_H <<<"$(python3 - "$WORK/reopened.png" "${ACCENT:-#000000}" \
		"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# The sidebar is the left quarter or so, floored at fontPixelSize * 9.
r = wx + max(int(ww * 0.24), 190)
# A FRACTION of the sidebar's width, not a count.
#
# The header of that sidebar is the asteroidz ship, and the ship's exhaust burns
# in the accent -- Logo.qml recolours it to Cfg.focusBg on purpose. At a flat
# threshold of 40 pixels the flame is an accent run about as tall as a row, and
# "the largest run" picked it perfectly plausibly. A selected entry spans the
# whole sidebar minus its padding; the flame spans a couple of dozen pixels.
span = r - wx
rows = [y for y in range(wy, wy + wh)
        if sum(1 for x in range(wx, r)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want)))
           > span * 0.5]
if not rows:
    print("0 0"); raise SystemExit
# The LARGEST run, not the first.
#
# The window is tiled and the compositor draws a focused border around it in the
# same accent, so the first run of accent rows is two pixels of border at the very
# top of the frame -- which is what this found, and a 2px "row height" put every
# computed sidebar position off the end of the list. Exactly one entry is selected
# at a time and every entry is the same height, so the tallest run is the pill.
groups = []
for y in rows:
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
grp = max(groups, key=len)
print(grp[0], grp[-1] - grp[0] + 1)
PY
)"

# Same correction as the first calibration: the accent pill is the SELECTED
# row, which the sort moved off row 0.
SB0=$((SB_TOP - FIRST_GROUP_ROW * (SB_H + 2)))
SIDEBAR_X=$((WX + 60))

if [ "${SB_H:-0}" -gt 10 ] && [ "$SB0" -gt "$WY" ]; then
	ok "the sidebar selection was located (row 0 at $SB0, ${SB_H}px rows)"
else
	bad "the sidebar selection was located (row 0 at $SB0, ${SB_H}px rows)"
fi

# The lowest small control in the content area. On an empty rules page that is
# "New rule": the intro paragraph is above it and a status line may appear
# between the two, so "lowest" is the stable description and "first" is not.
lowest_button() { # lowest_button <shot> [row index, default -1]  ->  "x y"
	python3 - "$WORK/$1.png" "$WX" "$WY" "$WW" "$WH" "${2:--1}" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
wx, wy, ww, wh = (int(v) for v in sys.argv[2:6])
l = wx + 12 + max(int(ww * 0.24), 190) + 12 + 8
r = wx + ww - 20
top = wy + 75
bot = wy + wh - 20
bg = Counter(px[x, y] for y in range(top, bot, 2)
             for x in range(l, r, 2)).most_common(1)[0][0]
def isbg(c):
    return all(abs(a - b) <= 12 for a, b in zip(c, bg))
found = []
for y in range(top, bot):
    cur = None
    x0 = l
    for x in range(l, r + 1):
        c = px[x, y] if x < r else None
        if c is not None and cur is not None \
                and all(abs(a - b) <= 3 for a, b in zip(c, cur)):
            continue
        n = x - x0
        # Bounded above as well as below: the bind page carries a filter field
        # that spans the whole pane, and an unbounded "widest run" would find
        # that every time.
        if cur is not None and not isbg(cur) and 30 <= n <= 160:
            found.append((y, (x0 + x) // 2))
        cur = c
        x0 = x
if not found:
    print("0 0"); raise SystemExit
rows = []
for y, cx in found:
    if rows and y - rows[-1][-1][0] <= 3:
        rows[-1].append((y, cx))
    else:
        rows.append([(y, cx)])
# WHICH run of controls to report. "Lowest" was the whole answer while every
# page had exactly one button; the push-to-talk page has two (Rebind... above,
# Capture... below) and taking the lowest silently clicked the wrong one -- and
# passed, because both are buttons and both do something.
idx = int(sys.argv[6]) if len(sys.argv) > 6 else -1
grp = rows[idx]
mid = grp[len(grp) // 2]
print(mid[1], mid[0])
PY
}

# ── the Modules page ────────────────────────────────────────────────────────
#
# What the bar draws, where, and on which screen. The bar's OWN config, written
# to the bar's own file -- the compositor draws none of it.
#
# Every page in this window sits behind `active: win.page === "..."`, so a page
# nothing ever selects is a page nothing ever BUILDS. This one shipped with a
# `for...of` over Compositor.monitors, which is a map keyed by output name and
# not iterable that way: the picker threw on construction and offered nothing,
# and no test went near it. Visiting the page at all is most of the value here.
go_to "$MODULES_ROW"
shot modules

MODULES_INK="$(ink modules "$((WX + 12 + 450 + 12))" "$((WY + 120))" \
	"$((WX + WW))" "$((WY + WH))")"
if [ "${MODULES_INK:-0}" -gt 2000 ]; then
	ok "the modules page is populated (${MODULES_INK} ink px)"
else
	bad "the modules page is populated (${MODULES_INK} ink px)"
fi

# A throw inside a function is not a blank page -- the Loader keeps whatever it
# managed to build -- so the log is the only place monitorValues() failing shows
# up at all.
if grep -qE "TypeError|is not iterable|is not a function" "$WORK/qs.log"; then
	bad "the modules page builds without a QML error"
	grep -m3 -E "TypeError|is not iterable|is not a function" "$WORK/qs.log" \
		| sed 's/^/       /'
else
	ok "the modules page builds without a QML error"
fi

# ── the page actually DOES something ────────────────────────────────────────
#
# Rendering was the only thing checked here, and rendering is the half that was
# never broken. Every control on this page was dead on arrival: the monitor row
# was a FormRow, which does `control.parent = root` -- fine at the top level, a
# trap in a delegate, because the control is reparented out of the delegate that
# made it and outlives it with a dead JS context. It drew on top of the section
# heading, its handler never fired, and it took the rest of the delegate with
# it. An "is it populated" assertion passes through all of that.
#
# So: click something, and look at the FILE. That is the only evidence that
# survives -- the page applies as you change it, so a write is the whole of what
# a click is supposed to do.
#
# The chips under "Not shown" are the lowest controls on the page and the
# easiest to hit without pixel-hunting for a glyph. Clicking one places that
# module in the right section.
BEFORE_RIGHT="$(grep -E '^\s*right ' "$BAR_CONF" | head -1)"
read -r CHIP_X CHIP_Y <<<"$(lowest_button modules)"
if [ "${CHIP_X:-0}" -gt 0 ]; then
	hl_move "$CHIP_X" "$CHIP_Y"; sleep 1
	hl_click "$CHIP_X" "$CHIP_Y"; sleep 2
	AFTER_RIGHT="$(grep -E '^\s*right ' "$BAR_CONF" | head -1)"
	if [ "$AFTER_RIGHT" != "$BEFORE_RIGHT" ]; then
		ok "clicking an unplaced module writes it into the config"
	else
		bad "clicking an unplaced module writes it into the config (still $AFTER_RIGHT)"
	fi
	# TWICE. One click proved the write path and nothing else -- and the bug
	# this file missed was that the SECOND action did nothing: every mutation
	# starts from a clone of the current sections, and those were only refreshed
	# when the filesystem watcher got round to reporting our own write back to
	# us. Until then a second click cloned stale state and wrote the first
	# change out again. "It works once" is invisible to any test that clicks
	# once.
	SECOND_BEFORE="$(grep -E '^\s*right ' "$BAR_CONF" | head -1)"
	read -r CHIP2_X CHIP2_Y <<<"$(shot modules-mid; lowest_button modules-mid)"
	if [ "${CHIP2_X:-0}" -gt 0 ]; then
		hl_move "$CHIP2_X" "$CHIP2_Y"; sleep 1
		hl_click "$CHIP2_X" "$CHIP2_Y"; sleep 2
		SECOND_AFTER="$(grep -E '^\s*right ' "$BAR_CONF" | head -1)"
		if [ "$SECOND_AFTER" != "$SECOND_BEFORE" ]; then
			ok "...and a second click works too, not just the first"
		else
			bad "...and a second click works too, not just the first (stuck at $SECOND_AFTER)"
		fi
	else
		bad "a second unplaced chip was found to click"
	fi

	# And the page redraws from the file rather than from a copy beside it.
	shot modules-after
	MOD_INK2="$(ink modules-after "$((WX + 12 + 450 + 12))" "$((WY + 120))" \
		"$((WX + WW))" "$((WY + WH))")"
	if [ "${MOD_INK2:-0}" -gt 2000 ]; then
		ok "...and the page is still drawn afterwards (${MOD_INK2} ink px)"
	else
		bad "...and the page is still drawn afterwards (${MOD_INK2} ink px)"
	fi
else
	bad "an unplaced module chip was found to click"
fi

# ── dragging a module reorders it ───────────────────────────────────────────
#
# The arrows move one place at a time; a drag is the direct way and the only one
# that crosses sections in a single motion. It is also the one that cannot be
# judged from a screenshot: the dragged row deliberately does NOT move, because
# reflowing the Column under the pointer would move the drop target while you
# are aiming at it. What moves is the config.
#
# Rows are located through lowest_button, which finds the accent-coloured
# control clusters -- the ▲▼ pair on each row. Hunting for the row slab itself
# does not work: it is rgba(1,1,1,0.05) over the panel, which is within a
# rounding error of the panel.
shot modules-drag
read -r B0_X B0_Y <<<"$(lowest_button modules-drag 0)"
read -r B1_X B1_Y <<<"$(lowest_button modules-drag 1)"

if [ "${B0_Y:-0}" -gt 0 ] && [ "${B1_Y:-0}" -gt "$B0_Y" ]; then
	# Grab by the module NAME, well left of the buttons: a press that lands on
	# ▲ is a click on ▲, not the start of a drag.
	GRAB_X=$((WX + 12 + 450 + 40))
	DRAG_BEFORE="$(grep -E '^\s*(left|center|right) ' "$BAR_CONF" | md5sum)"
	cp "$BAR_CONF" "$WORK/bar-config.predrag"
	# Past the NEXT row's midpoint: the drop index flips at a row's middle, not
	# its edge, so a drag that stops short of it is a no-op by design.
	hl_drag "$GRAB_X" "$B0_Y" "$GRAB_X" "$((B1_Y + 6))"
	sleep 2
	DRAG_AFTER="$(grep -E '^\s*(left|center|right) ' "$BAR_CONF" | md5sum)"
	if [ "$DRAG_BEFORE" != "$DRAG_AFTER" ]; then
		ok "dragging a module past its neighbour reorders the config"
	else
		bad "dragging a module past its neighbour reorders the config (unchanged)"
	fi
	# ── and ACROSS sections ─────────────────────────────────────────────────
	#
	# The reorder above stays inside one section, which is the easy half: the
	# drop index comes from one Column's own rows. Crossing sections is what
	# the arrows cannot do in one motion and is the whole reason drag exists,
	# and it is a different code path -- updateDrop has to pick the section
	# first and then the index within it.
	#
	# Aimed at the LAST section's rows, from the first, so the drag has to
	# travel past at least one section boundary to land.
	cp "$WORK/bar-config.predrag" "$BAR_CONF"
	sleep 2
	shot modules-cross
	CROSS_N="$(grep -cE '^\s*(left|center|right) items="[^"]' "$BAR_CONF")"
	read -r C0_X C0_Y <<<"$(lowest_button modules-cross 0)"
	read -r CL_X CL_Y <<<"$(lowest_button modules-cross -1)"
	# The lowest control run is a "Not shown" chip, not a row; step up to the
	# last run that is still a module row by asking for the one before it.
	read -r CP_X CP_Y <<<"$(lowest_button modules-cross -2)"
	SECT_BEFORE="$(grep -E '^\s*left ' "$BAR_CONF" | head -1)"
	if [ "${C0_Y:-0}" -gt 0 ] && [ "${CP_Y:-0}" -gt "$C0_Y" ]; then
		hl_drag "$GRAB_X" "$C0_Y" "$GRAB_X" "$((CP_Y + 6))"
		sleep 2
		SECT_AFTER="$(grep -E '^\s*left ' "$BAR_CONF" | head -1)"
		if [ "$SECT_AFTER" != "$SECT_BEFORE" ]; then
			ok "dragging a module into another section moves it there"
		else
			bad "dragging a module into another section moves it there (left unchanged)"
		fi
	else
		bad "a row in a later section was found to drag onto (got ${C0_Y:-0}, ${CP_Y:-0})"
	fi

	# Put it back. The ship lives in the left section, so a reorder can move it
	# -- and the cases after this one press it at a position measured before.
	cp "$WORK/bar-config.predrag" "$BAR_CONF"
	sleep 2
else
	bad "two module rows were found to drag between (got ${B0_Y:-0}, ${B1_Y:-0})"
fi

# ── the offered module names agree with what can be drawn ───────────────────
#
# BarConfig.builtins is what the page OFFERS; ModuleLoader's switch is what a
# name actually resolves to. Two hand-written lists that have to say the same
# thing, and when they disagree it fails in the worst direction: the page offers
# a name, the user adds it, the loader returns null, and nothing appears --
# indistinguishable from a module hiding itself because it has nothing to show.
# `spectrum` sat in the offered list exactly that way; it is a child of the media
# pill, not a module of its own.
#
# Compared as text, because the alternative is placing all fifteen on a bar and
# counting pills -- and half of them legitimately draw nothing on a headless
# machine with no battery, no player and no tray.
OFFERED="$(sed -n '/readonly property var builtins:/,/\]/p' "$HERE/shell/BarConfig.qml" \
	| grep -oE '"[a-z/]+"' | tr -d '"' | sort -u)"
RESOLVES="$(grep -oE 'case "[a-z/]+":' "$HERE/shell/modules/ModuleLoader.qml" \
	| grep -oE '"[a-z/]+"' | tr -d '"' | sort -u)"
UNRESOLVED="$(comm -23 <(echo "$OFFERED") <(echo "$RESOLVES") | tr '\n' ' ')"
UNOFFERED="$(comm -13 <(echo "$OFFERED") <(echo "$RESOLVES") | tr '\n' ' ')"

if [ -z "${UNRESOLVED// /}" ]; then
	ok "every module the settings page offers can actually be drawn"
else
	bad "every module the settings page offers can actually be drawn (dead: $UNRESOLVED)"
fi
if [ -z "${UNOFFERED// /}" ]; then
	ok "...and every module that can be drawn is offered"
else
	bad "...and every module that can be drawn is offered (missing: $UNOFFERED)"
fi

# ── the Layouts page ────────────────────────────────────────────────────────
#
# The per-tag layout rules, which until recently were config-only: `set-config`
# writes options and a tag rule is not one, so nothing served them and no editor
# could show them.
go_to "$LAYOUTS_ROW"
shot layouts

TAGS_BEFORE="$(hl_get "get tag-rules" | jq '.count')"
if [ "${TAGS_BEFORE:-0}" -gt 0 ]; then
	ok "the compositor has tag rules to show ($TAGS_BEFORE)"
else
	bad "the compositor has tag rules to show ($TAGS_BEFORE)"
fi

# The page draws a card per rule, so the pane carries ink proportional to them.
LAYOUT_INK="$(ink layouts "$((WX + 12 + 450 + 12))" "$((WY + 120))" \
	"$((WX + WW))" "$((WY + WH))")"
if [ "${LAYOUT_INK:-0}" -gt 2000 ]; then
	ok "the layouts page is populated (${LAYOUT_INK} ink px)"
else
	bad "the layouts page is populated (${LAYOUT_INK} ink px)"
fi

# "New tag rule" is the lowest control on the page.
read -r NEWTAG_X NEWTAG_Y <<<"$(lowest_button layouts)"
if [ "${NEWTAG_X:-0}" -gt 0 ]; then
	hl_move "$NEWTAG_X" "$NEWTAG_Y"; sleep 1
	hl_click "$NEWTAG_X" "$NEWTAG_Y"; sleep 3
	TAGS_AFTER="$(hl_get "get tag-rules" | jq '.count')"
	if [ "${TAGS_AFTER:-0}" -eq $((TAGS_BEFORE + 1)) ]; then
		ok "New tag rule adds one ($TAGS_BEFORE -> $TAGS_AFTER)"
	else
		bad "New tag rule adds one ($TAGS_BEFORE -> $TAGS_AFTER)"
	fi
	if grep -qE '^tag 1 \{' "$HL_CONFIG"; then
		ok "...written as a \`tag\` block with its id as the argument"
	else
		bad "...written as a \`tag\` block with its id as the argument"
	fi
	if "$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | grep -q 'config OK'; then
		ok "...and the config still parses"
	else
		bad "...and the config still parses"
	fi
else
	bad "the layouts page shows its New tag rule button"
fi

RULES_Y="$(sidebar_entry_y "$RULES_ROW")"
hl_move "$SIDEBAR_X" "$RULES_Y"; sleep 1
hl_click "$SIDEBAR_X" "$RULES_Y"; sleep 2
shot rules

RULES_BEFORE="$(hl_get "get window-rules" | jq '.count')"
read -r NEW_X NEW_Y <<<"$(lowest_button rules)"
if [ "${NEW_X:-0}" -gt 0 ]; then
	ok "the rules page is showing, with its New rule button (${NEW_X},${NEW_Y})"
else
	bad "the rules page is showing, with its New rule button"
fi

hl_move "$NEW_X" "$NEW_Y"; sleep 1
hl_click "$NEW_X" "$NEW_Y"; sleep 3

RULES_AFTER="$(hl_get "get window-rules" | jq '.count')"
if [ "${RULES_AFTER:-0}" -eq $((RULES_BEFORE + 1)) ]; then
	ok "New rule adds one ($RULES_BEFORE -> $RULES_AFTER)"
else
	bad "New rule adds one ($RULES_BEFORE -> $RULES_AFTER)"
fi

# A BLOCK, not a legacy line -- the writer's whole contract.
if grep -q 'window-rule {' "$HL_CONFIG"; then
	ok "...written as a window-rule block"
else
	bad "...written as a window-rule block"
fi

# The new rule opens EXPANDED, and its editor has to show the field it was
# created with.
#
# A card's draft used to be seeded only by the tap that expands it, and a tap is
# one of three ways a card ends up open -- the page expands a new rule itself, and
# every save rebuilds the delegates, so a card could be constructed already open
# with an empty draft. It then printed "This rule has no fields" under a header
# listing them. Reported from a live session, not caught here, because nothing was
# looking at the card after it opened.
#
# Measured as the WARNING's colour: that sentence is the only urgent-coloured text
# either page can produce, so counting those pixels is counting the bug.
shot rule_added
URGENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("urgent")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
' 2>/dev/null)"
WARN_PX="$(python3 - "$WORK/rule_added.png" "${URGENT:-#000000}" \
		"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print(-1); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
print(sum(1 for y in range(wy, wy + wh, 2) for x in range(wx, wx + ww, 2)
          if all(abs(a - b) <= 24 for a, b in zip(px[x, y], want))))
PY
)"
if [ "${WARN_PX:-0}" -lt 40 ]; then
	ok "...and its editor is populated, not warning that it is empty (${WARN_PX}px)"
else
	bad "...and its editor is populated, not warning that it is empty (${WARN_PX}px)"
fi
if "$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | grep -q 'config OK'; then
	ok "...and the config still parses"
else
	bad "...and the config still parses"
fi

BINDS_Y="$(sidebar_entry_y "$BINDS_ROW")"
hl_move "$SIDEBAR_X" "$BINDS_Y"; sleep 1
hl_click "$SIDEBAR_X" "$BINDS_Y"; sleep 2
shot binds

BINDS_BEFORE="$(hl_get "get binds" | jq '.count')"
read -r BNEW_X BNEW_Y <<<"$(lowest_button binds)"
if [ "${BNEW_X:-0}" -gt 0 ]; then
	ok "the binds page is showing, with its New bind button (${BNEW_X},${BNEW_Y})"
else
	bad "the binds page is showing, with its New bind button"
fi

hl_move "$BNEW_X" "$BNEW_Y"; sleep 1
hl_click "$BNEW_X" "$BNEW_Y"; sleep 3

BINDS_AFTER="$(hl_get "get binds" | jq '.count')"
if [ "${BINDS_AFTER:-0}" -eq $((BINDS_BEFORE + 1)) ]; then
	ok "New bind adds one ($BINDS_BEFORE -> $BINDS_AFTER)"
else
	bad "New bind adds one ($BINDS_BEFORE -> $BINDS_AFTER)"
fi
if hl_get "get binds" | jq -e '[.binds[] | select(.chord=="Super+F1")] | length > 0' >/dev/null 2>&1; then
	ok "...and it is the one the page creates"
else
	bad "...and it is the one the page creates"
fi
if "$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | grep -q 'config OK'; then
	ok "...and the config still parses"
else
	bad "...and the config still parses"
	"$REPO/build/asteroidz" -p -c "$HL_CONFIG" 2>&1 | head -4 | sed 's/^/       /'
fi

# ── the push-to-talk page ───────────────────────────────────────────────────
#
# One assertion, and it is the only one worth making from here: does "Rebind…"
# reach the bridge. It reaches it as a FILE -- the bridge owns the portal session
# and a mirror on another monitor has none, so the request travels through
# XDG_RUNTIME_DIR rather than down anybody's pipe. That indirection is exactly
# the kind that looks right in QML and connects to nothing, and the file either
# appears or it does not.
#
# What the page WRITES is deliberately not driven here: the conf lives under the
# real XDG_CONFIG_HOME, which this harness does not isolate, and a settings test
# has no business editing the machine's push-to-talk key. save_conf, the menu and
# the field are covered as units in contrib/discord-ptt-test.sh.
# ── the notifications page ──────────────────────────────────────────────────
#
# Visited before Push-to-talk because it now sits above it in the sidebar, and
# because visiting is the only way its QML is compiled at all: the page is
# behind a Loader that stays inactive until selected, so a missing type or a
# bad binding in it cannot show up at startup.
NOTIFY_ROW="$(hl_get "get config-schema" | python3 -c '
import json, sys
groups = [g["label"] for g in json.load(sys.stdin)["groups"]]
fixed = ["Displays", "Wallpaper", "Modules", "Tags", "Window rules",
         "Keybinds", "Palette", "Notifications", "Push-to-talk"]
print(sorted(groups + fixed, key=lambda s: s.lower()).index("Notifications"))
')"
NOTIFY_Y="$(sidebar_entry_y "$NOTIFY_ROW")"
hl_move "$SIDEBAR_X" "$NOTIFY_Y"; sleep 1
hl_click "$SIDEBAR_X" "$NOTIFY_Y"; sleep 2
shot notifications

NOTIFY_INK="$(ink notifications "$((WX + 12 + 450 + 12))" "$((WY + 120))" \
	"$((WX + WW))" "$((WY + WH))")"
if [ "${NOTIFY_INK:-0}" -gt 2000 ]; then
	ok "the notifications page is populated (${NOTIFY_INK} ink px)"
else
	bad "the notifications page is populated (${NOTIFY_INK} ink px)"
fi

# Its controls are Sliders and a Toggle inside FormRows, and FormRow reparents
# its control -- the trap that left every control on the modules page dead
# while the page still rendered perfectly. A throw there does not blank the
# page, so the log is the only place it appears.
if grep -qE "TypeError|is not iterable|is not a function|Unable to assign" \
	"$WORK/qs.log"; then
	bad "the notifications page builds without a QML error"
	grep -m3 -E "TypeError|is not iterable|is not a function|Unable to assign" \
		"$WORK/qs.log" | sed 's/^/       /'
else
	ok "the notifications page builds without a QML error"
fi

PTT_ROW="$(hl_get "get config-schema" | python3 -c '
import json, sys
groups = [g["label"] for g in json.load(sys.stdin)["groups"]]
fixed = ["Displays", "Wallpaper", "Modules", "Tags", "Window rules",
         "Keybinds", "Palette", "Notifications", "Push-to-talk"]
print(sorted(groups + fixed, key=lambda s: s.lower()).index("Push-to-talk"))
')"
PTT_Y="$(sidebar_entry_y "$PTT_ROW")"
hl_move "$SIDEBAR_X" "$PTT_Y"; sleep 1
hl_click "$SIDEBAR_X" "$PTT_Y"; sleep 2
shot ptt

PICK_FILE="$XDG_RUNTIME_DIR/asteroidz-discord-ptt.state.pick"
rm -f "$PICK_FILE"

# Index 0: Rebind... is the FIRST run of controls on this page, Capture...
# the last. Addressed rather than assumed, since "the only button" stopped
# being true the moment the page grew a second one.
read -r PTT_X PTT_BY <<<"$(lowest_button ptt 0)"
if [ "${PTT_X:-0}" -gt 0 ]; then
	ok "the push-to-talk page is showing, with its Rebind button (${PTT_X},${PTT_BY})"
else
	bad "the push-to-talk page is showing, with its Rebind button"
fi

hl_move "$PTT_X" "$PTT_BY"; sleep 1
hl_click "$PTT_X" "$PTT_BY"; sleep 2
if [ -e "$PICK_FILE" ]; then
	ok "Rebind… asks the bridge for the interactive picker"
else
	bad "Rebind… asks the bridge for the interactive picker (no $PICK_FILE)"
fi
rm -f "$PICK_FILE"

# Capture… for the INJECTED key. Not the same mechanism as Rebind…, and it
# cannot be: that one goes through the portal's picker, this one through the
# compositor's capture-chord, because a keysym name is what the injector needs
# and only the compositor can name the key that was pressed.
#
# Asserted through the compositor rather than by looking at the page: while a
# capture is running the compositor swallows keys wholesale, so `capture-chord`
# being in flight is observable as a keypress NOT doing its usual job.
read -r CAP_X CAP_Y <<<"$(lowest_button ptt -1)"
hl_move "$CAP_X" "$CAP_Y"; sleep 1
hl_click "$CAP_X" "$CAP_Y"; sleep 1

if command -v wtype >/dev/null 2>&1; then
	# Escape is capture-chord's documented way out, so this both proves a
	# capture was running and leaves nothing behind.
	CAP_TAG_BEFORE="$(hl_current_tag_index)"
	WAYLAND_DISPLAY="$HL_SOCK" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		wtype -k Escape 2>/dev/null
	sleep 1
	hl_dispatch "view,2" 0.4
	if [ "$(hl_current_tag_index)" = "2" ]; then
		ok "Capture… runs a capture and Escape ends it (tag $CAP_TAG_BEFORE -> 2)"
	else
		bad "Capture… left the compositor swallowing keys"
	fi
	hl_dispatch "view,1" 0.3
else
	echo "  --   wtype not installed; skipped the capture case"
fi

# ── reopening it ────────────────────────────────────────────────────────────
#
# Pressing it a second time did nothing, and the reason was not a bug in the
# window: it was still open, on the tag it was opened from. A client cannot
# raise itself on Wayland -- there is no protocol for it -- so the press
# correctly reused the existing window, from the far side of a tag switch, which
# is indistinguishable from nothing happening.
#
# The bar has the compositor's IPC and can ask for it back. Asserted on
# active_tags rather than on focus: the window never lost focus in the compositor
# sense, so `is_focused` was already true and an assertion on it passed against
# the broken build.
acttags() { hl_get "get all-monitors" | python3 -c '
import json, sys
print(json.load(sys.stdin)["monitors"][0]["active_tags"])'; }

hl_dispatch "view,2" 1
T_AWAY="$(acttags)"
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 3
T_BACK="$(acttags)"
if [ "$T_AWAY" = "[2]" ] && [ "$T_BACK" = "[1]" ]; then
	ok "a second press of the ship summons the window back from another tag"
else
	bad "a second press of the ship summons the window back (away=$T_AWAY back=$T_BACK)"
fi

# ── closed by the COMPOSITOR, and opened again ──────────────────────────────
#
# The close path this file did not have, and the one a person actually uses. The
# window opens tiled unless a rule floats it, so it has no titlebar -- it gets
# closed with whatever keybind closes windows, which is an xdg_toplevel.close from
# the compositor, not the Close button inside it.
#
# Those two are not the same event. The button sets `visible = false` and the
# object survives; a toplevel close DESTROYS it, and the singleton that cached it
# is then holding a reference to a dead object. Reported live as "the settings
# panel will launch only one time, any subsequent clicks don't launch it" --
# against a build where every other assertion in this file passed, because every
# other assertion closed it with the button.
WINID="$(win_json | jq -r '.id // empty')"
if [ -n "$WINID" ]; then
	hl_dispatch "client,$WINID,kill_client" 2
	sleep 2
	if [ -z "$(win_json)" ]; then
		ok "the compositor can close the settings window"
	else
		bad "the compositor can close the settings window"
	fi

	hl_move "$PILL_X" "$PILL_Y"; sleep 1
	hl_click "$PILL_X" "$PILL_Y"; sleep 4
	if [ -n "$(win_json)" ]; then
		ok "and the ship opens it again afterwards"
	else
		bad "and the ship opens it again afterwards"
	fi
else
	bad "the settings window was there to close"
fi

if [ -n "${ASTEROIDZ_SHOT_DIR:-}" ]; then
	mkdir -p "$ASTEROIDZ_SHOT_DIR"
	cp "$WORK"/*.png "$ASTEROIDZ_SHOT_DIR/" 2>/dev/null
	echo "  ..   shots in $ASTEROIDZ_SHOT_DIR"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
