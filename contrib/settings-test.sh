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

# One module, at the right edge, so its pill is at a position this script can
# compute rather than hunt for -- the same arrangement click-test.sh uses.
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "display" }
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

PILL_X=$((HL_WIDTH - 8 - 12 - 18))
PILL_Y=$((9 + 24))

# Move before the first click. A press with no preceding motion does not
# hit-test, so the first click of a session lands nowhere while every later one
# works -- which reads as "the pill is dead".
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 2
shot popover

# The popover's box, and the tab row inside it.
#
# The tab row is located from the SELECTED TAB, which is the accent colour --
# not by offsetting from the popover's top edge. That offset is what an earlier
# version of this test did and it was wrong by seven pixels: the scan for the
# panel started below the bar at a fixed y, so the "top" it reported was the scan
# floor rather than the surface, and the click landed under the button. The
# accent block is the row itself, measured.
#
# The bar's surface is height + 2 * margin_y tall (48 + 18 = 66) and the popover
# sits `gap` below it, so 68 is the first row that can only be popover.
read -r PL PT PR PB <<<"$(python3 - "$WORK/popover.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
xs = []; ys = []
for y in range(68, h):
    for x in range(w):
        r, g, b = px[x, y]
        # darker than the #9db8d8 wallpaper: only a panel can be here
        if r + g + b < 400:
            xs.append(x); ys.append(y)
if not xs:
    print("0 0 0 0")
else:
    print(min(xs), min(ys), max(xs), max(ys))
PY
)"

if [ "$PR" -gt 0 ]; then
	ok "the display popover is up (${PL},${PT}..${PR},${PB})"
else
	bad "the display popover is up"
fi

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
' 2>/dev/null)"

# The selected tab: the topmost run of accent-coloured pixels wide enough to be a
# pill rather than a glyph's antialiased fringe.
read -r TBT TBB <<<"$(python3 - "$WORK/popover.png" "${ACCENT:-#000000}" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# Tight tolerance: at 30 this matched the blue fringe of antialiased WHITE text
# and found a row of glyphs instead of the pill.
rows = [y for y in range(68, h)
        if sum(1 for x in range(w)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))) > 20]
if not rows:
    print("0 0"); raise SystemExit
grp = [rows[0]]
for y in rows[1:]:
    if y - grp[-1] <= 2:
        grp.append(y)
    else:
        break
print(grp[0], grp[-1])
PY
)"

if [ "${TBB:-0}" -gt "${TBT:-0}" ]; then
	ok "the tab row is at y ${TBT}..${TBB}"
else
	bad "the tab row is at y ${TBT}..${TBB}"
fi

# The button's right edge is one panel-padding in from the panel's, and its width
# comes from its label at 78% of the theme font -- so 45px in from the right edge
# is inside it for any font this theme can produce.
SET_X=$((PR - 45))
SET_Y=$(((TBT + TBB) / 2))
hl_move "$SET_X" "$SET_Y"; sleep 1
hl_click "$SET_X" "$SET_Y"; sleep 3

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
	ok "\"All settings…\" opens a toplevel titled \"asteroidz settings\""
else
	bad "\"All settings…\" opens a toplevel titled \"asteroidz settings\""
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

# ── 2. it is populated ──────────────────────────────────────────────────────
#
# Ink, not a row count. Ninety-five options with an explanation each is a lot of
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
SEARCH_X=$((WX + WW / 2))
SEARCH_Y=$((WY + 12 + 14))
hl_move "$SEARCH_X" "$SEARCH_Y"; sleep 1
hl_click "$SEARCH_X" "$SEARCH_Y"; sleep 1

# wlvkbd is a one-shot client: it connects, makes a virtual keyboard, sends the
# key and exits, so the seat only advertises a keyboard while it is alive. On the
# very first press the client is still binding wl_keyboard and receives only the
# release. Hence a throwaway press before the real ones.
"$HL_WLVKBD" press A >/dev/null 2>&1; sleep 0.4
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
# The right-hand third: the control column. Searching the whole width would also
# find the sidebar's selected-group pill, which is just as flat a block.
l = wx + int(ww * 0.62)
r = wx + ww
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
APPLY_X=$((WX + WW - 12 - 40))
APPLY_Y=$((WY + WH - 20))
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

# A hand-written comment above a setting is the reason the writer edits bytes
# instead of round-tripping the document, so check one survived.
if grep -q 'modules-right "display"' "$HL_CONFIG"; then
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

hl_move "$APPLY_X" "$APPLY_Y"; sleep 1
hl_click "$APPLY_X" "$APPLY_Y"; sleep 3
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

CLOSE_X=$((WX + WW - 12 - 30))
CLOSE_Y=$((WY + 12 + 14))
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

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
