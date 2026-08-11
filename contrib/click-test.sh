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

# A bar with exactly one module in it, on the right, so its pill is at a
# position this script can compute rather than hunt for.
cp "$HL_CONFIG" "$WORK/config.pristine.kdl"
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "" "" "power" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 1

setsid $(bar_limits) dbus-run-session -- \
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

# How much of the screen below the bar is not wallpaper? A popover is the only
# thing that can be there, so this is "is a panel open", as a number.
right_glyph_x() { # right_glyph_x <shot> <x0> <x1> <y0> <y1> -> centre x of the
	# rightmost run of lit pixels in that band. Used to find a stepper's "âº"
	# rather than guessing at it from the panel edge: the arrow is small, the
	# margin is a theme value, and a click aimed by arithmetic landed just
	# beside it and silently did nothing.
	python3 - "$WORK/$1.png" "$2" "$3" "$4" "$5" <<'GLYPHPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
x0, x1, y0, y1 = (int(v) for v in sys.argv[2:6])
x1 = min(x1, im.size[0] - 1)
y1 = min(y1, im.size[1] - 1)
runs, start = [], None
for x in range(x0, x1 + 1):
    lit = any(sum(px[x, y]) > 450 for y in range(y0, y1 + 1))
    if lit and start is None:
        start = x
    elif not lit and start is not None:
        runs.append((start, x - 1))
        start = None
if start is not None:
    runs.append((start, x1))
print((runs[-1][0] + runs[-1][1]) // 2 if runs else 0)
GLYPHPY
}

row_ink() { # row_ink <shot> <x0> <x1> <y0> <y1> -- lit pixels in one row band
	python3 - "$WORK/$1.png" "$2" "$3" "$4" "$5" <<'ROWPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
x0, x1, y0, y1 = (int(v) for v in sys.argv[2:6])
x1 = min(x1, im.size[0] - 1)
y1 = min(y1, im.size[1] - 1)
# Glyphs on a dark panel: bright, and nothing else in this band is.
print(sum(1 for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)
          if sum(px[x, y]) > 450))
ROWPY
}

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

# ── a popover opens, and can be dismissed ───────────────────────────────────
#
# Driven through the POWER pill, which is a pill with a menu on it and nothing
# more. It used to be the display pill, and that was never about displays: what
# is measured here is Popover.qml -- opening, Escape, the pill toggling its own
# panel, a click landing outside. The display pill stopped having a popover when
# its two tabs became pages in the settings window, so the test moved to a pill
# that still has one rather than following the module that no longer does.
#
# The pill is the only module, so it is at the right edge of the right panel, one
# pill-height down. Every module here is an icon-only pill of the same width.
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
	ok "clicking a pill opens its panel ($IDLE -> $OPENED px)"
else
	bad "clicking a pill opens its panel ($IDLE -> $OPENED px)"
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

# Text lines inside the panel, top to bottom: "<top> <bottom>" each.
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

# ── a plugin's menu ─────────────────────────────────────────────────────────
#
# Plugin rows did nothing at all. The popover raised `activated`, the bar
# checked the row for a PipeWire node and a tray entry, found neither, and fell
# through to closing the panel -- so every row in the reminders, discord and
# nordvpn menus looked live, dismissed itself and told the plugin nothing.
#
# Driven by a stub rather than by a real plugin: this is the bar's half of the
# protocol, and a test needing a reminder schedule on disk to exercise it
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
    {"text": "Dose", "value": "dose", "input": True, "edit": ""},
    # A label longer than the menu that opened this form. A popover latches
    # its width when it opens, so this row cannot fit -- and what does not fit
    # is cut from the RIGHT, which is where the typed text is.
    {"text": "Times (HH:MM, comma separated)", "value": "times",
     "input": True, "edit": ""},
    # A stepper: chosen with arrows, never typed.
    {"text": "Hour", "value": "hour",
     "spin": {"min": 0, "max": 23, "pad": 2}, "edit": "8"},
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
EOF
bar_conf "" "" "custom/probe" <<EOF
$(bar_conf_panel)
custom "probe" {
	exec "python3 $WORK/stub.py $PLOG"
	continuous #true
}
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
	if [ "${#SROWS[@]}" -ge 6 ]; then
		# No focus-outline assertion here, and that is not an omission.
		# `Field.qml` draws one, and a plugin form row is not a Field -- it
		# is a label and a value Text with a "▌" appended, because a row is
		# a plain object a module hands the popover. The outline moved to
		# settings-test.sh, which drives a real Field. Measuring it here
		# reported +4px of accent for a focused row: the caret.
		#
		# The SECOND field, typed into after clicking it. Every keystroke
		# rebuilds the rows array (that is how a row's text changes), and
		# the popover used to re-aim at the first field whenever that
		# happened -- so a character went into field two and the caret
		# jumped back to field one, and only the first field of any form
		# could be filled in at all. Reported on the reminders form.
		read -r DY0 DY1 <<<"${SROWS[2]}"
		hl_click $(((SL + SR) / 2)) $(((DY0 + DY1) / 2))
		sleep 1
		for k in A B C; do "$HL_WLVKBD" press "$k" >/dev/null 2>&1; sleep 0.4; done
		sleep 1

		# The long-labelled field: typing into it has to CHANGE THE PIXELS.
		# It did not. The label and the value were one string with
		# ElideRight over the lot, so a row too wide for the latched popover
		# lost its value and its caret and kept its label: the keystrokes
		# arrived, the plugin got them, and the screen showed nothing at all.
		# Reported as "can't input time, start date" -- the two fields whose
		# labels are longest -- while Name, which is short, was fine.
		read -r TY0 TY1 <<<"${SROWS[3]}"
		hl_click $(((SL + SR) / 2)) $(((TY0 + TY1) / 2))
		sleep 1
		shot ptimes_before

		for k in 2 0 8 8; do "$HL_WLVKBD" press "$k" >/dev/null 2>&1; sleep 0.3; done
		sleep 1
		shot ptimes_after
		# Ink in the RIGHT-HAND third of that row, which is where a value
		# goes -- not the whole row and not the panel.
		#
		# Two earlier versions of this measured the wrong thing and said the
		# fix had failed while a screenshot showed it working. The panel's
		# pixel count moves by ~4 for four digits, which is noise; and the
		# whole row's ink goes DOWN, because the label eliding away sheds more
		# glyphs than the value adds. Only the part of the row the value lives
		# in answers the question being asked.
		TVX=$(( SL + (SR - SL) * 2 / 3 ))
		TBEFORE="$(row_ink ptimes_before "$TVX" "$SR" "$TY0" "$TY1")"
		TAFTER="$(row_ink ptimes_after "$TVX" "$SR" "$TY0" "$TY1")"
		if [ "$TAFTER" -gt "$((TBEFORE + 15))" ]; then
			ok "a field with a long label still shows what is typed ($TBEFORE -> $TAFTER ink)"
		else
			bad "a field with a long label shows nothing typed ($TBEFORE -> $TAFTER ink)"
		fi

		# The stepper. Focused by clicking its row, moved with the arrow
		# keys, and moved once more by clicking the ‹ › arrow itself -- the
		# two ways it can be driven, and the arrows are their own hit
		# targets rather than part of the row.
		read -r HY0 HY1 <<<"${SROWS[4]}"
		hl_click $(((SL + SR) / 2)) $(((HY0 + HY1) / 2))
		sleep 1
		for _ in 1 2; do "$HL_WLVKBD" press RIGHT >/dev/null 2>&1; sleep 0.3; done
		sleep 0.5
		# The right arrow, found rather than guessed: it is the rightmost
		# lit thing in that row.
		shot phour
		AX="$(right_glyph_x phour "$SL" "$SR" "$HY0" "$HY1")"
		hl_click "$AX" $(((HY0 + HY1) / 2))
		sleep 1

		read -r SY0 SY1 <<<"${SROWS[5]}"
		hl_click $(((SL + SR) / 2)) $(((SY0 + SY1) / 2))
		sleep 3
		# Exact, closing quote included: this is also what says the typing
		# above did not leak into field one. The broken build reported
		# "prefilledbc" -- the first character reached field two and the
		# caret snapped back for the rest.
		if grep -q '"name": "prefilled"' "$PLOG"; then
			ok "a form row carries the plugin's prefill back as a field"
		else
			bad "a form row carries the plugin's prefill back as a field (log: $(tr '\n' ' ' < "$PLOG"))"
		fi
		# Lowercase: the keyboard sends the keys unshifted.
		if grep -q '"dose": "abc"' "$PLOG"; then
			ok "the second field of a form takes text too"
		else
			bad "the second field of a form takes text too (log: $(tr '\n' ' ' < "$PLOG"))"
		fi
		# 8, two arrow keys and one arrow click: 11. A stepper's value
		# travels back in `fields` exactly like a typed one.
		if grep -q '"hour": "11"' "$PLOG"; then
			ok "a stepper answers to the arrow keys and to its own arrows"
		else
			bad "a stepper answers to the arrow keys and to its own arrows (log: $(tr '\n' ' ' < "$PLOG"))"
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
EOF
bar_conf "" "" "power" <<EOF
$(bar_conf_panel)
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

# ── the cursor ──────────────────────────────────────────────────────────────
#
# Read from the COMPOSITOR, not from a screenshot. The pointer is drawn by the
# compositor and does not appear in a capture, so there is nothing on screen to
# measure. `get cursorpos` reports the shape the focused client last asked for
# over wp_cursor_shape_v1, which is what a QML `cursorShape` becomes.
cp "$WORK/config.pristine.kdl" "$HL_CONFIG"
cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "" "" "clock,power" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 5
# The power menu is still open from the section above, and an open popover is a
# second surface for the pointer to be over.
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 1
"$HL_WLVKBD" press ESC >/dev/null 2>&1
sleep 2
shot cursorbar

# The bar's own panel, left and right edges. Its band only -- everything below
# is wallpaper or a popover, and panel_box is the one that wants those.
bar_box() { # bar_box <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
# margin y 9, height 48: inside the bar, clear of its rounded corners.
xs = [x for y in range(16, min(52, h), 2) for x in range(0, w, 2)
      if sum(px[x, y]) < 400]
print(min(xs), max(xs)) if xs else print(0, 0)
PY
}

cursor_shape() {
	hl_get "get cursorpos" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
print("surface" if d.get("cursor-surface") else (d.get("cursor-shape") or "?"))
'
}

if [ "$(cursor_shape)" = "?" ]; then
	bad "the compositor reports a cursor shape (no cursor-shape field -- too old?)"
else
	ok "the compositor reports a cursor shape"

	# Two pills, and the second is the point: "pointer everywhere" would satisfy
	# the first assertion and mean nothing. Power acts on a click; the clock is a
	# readout and says so with `interactive: false`. They must not feel the same.
	#
	# `panel_box` is no use here -- it starts at y=100 so that it finds an open
	# POPOVER and not the bar above it, and against a shot with no menu open it
	# returns nothing, which sent both probes off the screen and reported
	# 'default' for each. The bar's own band is what is wanted.
	# PILL_X, not the band's right edge: `bar_box` measures the PANEL, whose
	# padding and rounded corner extend about 15px past the last pill, so a
	# probe aimed at the edge lands on panel background and reads 'default'.
	#
	# And park the pointer somewhere else first. What is read back is the last
	# shape a client ASKED for, so it only changes when the pointer crosses into
	# a different item -- and the pointer is still sitting on this very pill from
	# the menu clicks above, which makes the move below a no-op and leaves the
	# stale value in place. That read as "the pill does not set a cursor".
	read -r CL CR <<<"$(bar_box cursorbar)"
	hl_move $((HL_WIDTH / 2)) $((HL_HEIGHT / 2)); sleep 1
	hl_move "$PILL_X" "$PILL_Y"; sleep 1
	ON_PILL="$(cursor_shape)"
	if [ "$ON_PILL" = "pointer" ]; then
		ok "...and a pill that acts on a click asks for the pointer"
	else
		bad "...and a pill that acts on a click asks for the pointer (got '$ON_PILL', bar $CL..$CR)"
	fi
	# The clock used to be the counter-example here -- the one readout pill,
	# asserting that `interactive: false` keeps the plain arrow. It is a
	# BUTTON now: the calendar lives under it, `interactive: root.bar !==
	# null` is true on any real bar, and this assertion went stale the day
	# that landed -- it had been failing against correct behaviour ever
	# since. There is no readout-only module left on a bar to point it at
	# (the readout case survives only in Clock instances with no bar, which
	# cannot appear here), so the assertion now checks the clock claims the
	# click it takes.
	hl_move $((CL + 20)) "$PILL_Y"; sleep 1
	ON_CLOCK="$(cursor_shape)"
	if [ "$ON_CLOCK" = "pointer" ]; then
		ok "...and the clock, which opens the calendar, asks for it too"
	else
		bad "...and the clock, which opens the calendar, asks for it too (got '$ON_CLOCK')"
	fi
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"

[ "$FAIL" = 0 ]
