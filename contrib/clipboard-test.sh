#!/usr/bin/env bash
# clipboard-test.sh — the clipboard module, end to end.
#
# What this covers that a unit test cannot: the history is read off
# ext-data-control-v1 on the shell's own Wayland connection, so "does it
# record a copy" is a question about a compositor, a protocol and a Qt event
# loop at the same time. There is nothing to mock that would still be the
# thing under test.
#
# The pointer is wlvptr (zwlr_virtual_pointer_v1) against the headless
# compositor, exactly as click-test.sh drives it.
#
# The strongest assertion here is `ipc call clipboard clear`, which answers
# "cleared N". That N is the backend's own count of what it captured, so it
# proves the protocol round trip without needing to read pixels or OCR a
# panel.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
# Which tree's plugin to test. The default is the dev build; an install check
# points this at build-install, because an optimised build is a different
# binary and "it worked in build/" is not evidence about the one being shipped.
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "clipboard-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}
command -v wl-copy >/dev/null || { echo "clipboard-test: needs wl-clipboard" >&2; exit 1; }

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

# The icon this module draws lives in the bar's datadir, which is not installed
# in a test tree -- so point the search path at the source copy. Without this
# the pill draws empty and "is the pill there" measures nothing.
mkdir -p "$WORK/icons/asteroidz-bar"
cp "$HERE/assets/clipboard.svg" "$WORK/icons/asteroidz-bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "" "" "clipboard" <<EOF
$(bar_conf_panel)
bar { icon-dir "$WORK/icons:/usr/share/asteroidz/bar-icons:/usr/share" }
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

# How much of the screen below the bar is not wallpaper. A popover is the only
# thing that can be there, so this is "is a panel open", as a number.
panel_pixels() {
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
        if r + g + b < 400:   # wallpaper is #9db8d8; a panel is much darker
            n += 1
print(n)
PY
}

qsipc() { timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call clipboard "$@" 2>/dev/null; }

# The pill is the only module, so it sits at the right edge of the right panel.
PILL_X=$((HL_WIDTH - 8 - 12 - 18))
PILL_Y=$((9 + 24))

# ── the backend records a copy ──────────────────────────────────────────────
#
# Asserted through the module's own IPC rather than the panel, so a failure
# here means "the protocol did not deliver" and not "the list did not draw".
printf 'clipboard test alpha' | wl-copy
sleep 2
printf 'clipboard test beta' | wl-copy
sleep 2

# Matched against the ANSWER, not merely against "something came back". The
# first version of this checked non-empty, and quickshell's own
# "No running instances" error is non-empty -- so it reported a pass while the
# bar had failed to start at all.
STATE="$(qsipc pause)"   # flips to paused
qsipc pause >/dev/null    # flip back
if [ "$STATE" = "paused" ]; then
	ok "the clipboard IPC handler answers ($STATE)"
else
	bad "the clipboard IPC handler answers (got '$STATE', want 'paused')"
fi

# Wake the keyboard up before anything depends on it.
#
# wlvkbd is a one-shot client: it connects, creates a virtual keyboard, sends
# and exits. On the FIRST press the bar is still binding wl_keyboard in
# response to wl_seat.capabilities and sees only the release -- so the first
# invocation of a session is swallowed whole. click-test.sh presses ESC twice
# for the same reason. Done here, with nothing open, so the throwaway cannot
# type into the panel the later assertion is measuring.
"$HL_WLVKBD" press LEFTSHIFT >/dev/null 2>&1
sleep 1

# ── the pill opens its panel ────────────────────────────────────────────────
shot idle
IDLE="$(panel_pixels idle)"

# Move first: a press with no preceding motion does not hit-test, so the very
# first click of a session lands nowhere while every later one works.
hl_move "$PILL_X" "$PILL_Y"
sleep 1
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot opened
OPENED="$(panel_pixels opened)"

if [ "$OPENED" -gt $((IDLE + 400)) ]; then
	ok "clicking the pill opens the clipboard ($IDLE -> $OPENED px)"
else
	bad "clicking the pill opens the clipboard ($IDLE -> $OPENED px)"
fi

# ── the search box actually receives keys ───────────────────────────────────
#
# Reported as "the search input is not focusable", and invisible to every
# assertion above: the panel opened, drew a search box, and swallowed nothing,
# because `focus: true` on a TextInput means nothing in a popup that never
# holds the keyboard. The bar does, and forwards to whatever the popover names
# as its keyTarget -- so this types and checks the LIST NARROWED, which is only
# possible if the keystrokes arrived.
#
# "beta" matches one of the two entries. If the keys go nowhere the list stays
# at two rows and the panel keeps its height.
"$HL_WLVKBD" press B E T A 2>/dev/null
sleep 2
shot filtered
FILTERED="$(panel_pixels filtered)"
if [ "$FILTERED" -lt "$OPENED" ] && [ "$FILTERED" -gt 0 ]; then
	ok "typing in the search box filters the list ($OPENED -> $FILTERED px)"
else
	bad "typing in the search box filters the list ($OPENED -> $FILTERED px)"
fi

# Clear the query so the later assertions see the whole list again.
"$HL_WLVKBD" press BACKSPACE BACKSPACE BACKSPACE BACKSPACE 2>/dev/null
sleep 1

# Clicking it again closes it: showPanel is itself a toggle.
hl_click "$PILL_X" "$PILL_Y"
sleep 2
shot toggled
TOGGLED="$(panel_pixels toggled)"
if [ "$TOGGLED" -lt $((OPENED - 400)) ]; then
	ok "clicking it again closes the panel ($OPENED -> $TOGGLED px)"
else
	bad "clicking it again closes the panel ($OPENED -> $TOGGLED px)"
fi

# ── the keybind's end of it ─────────────────────────────────────────────────
#
# This is the path that will actually be used, and it is the one a click test
# cannot reach: no pointer is involved at all.
qsipc toggle >/dev/null
sleep 2
shot ipcopened
IPC_OPENED="$(panel_pixels ipcopened)"
if [ "$IPC_OPENED" -gt $((TOGGLED + 400)) ]; then
	ok "ipc call clipboard toggle opens the panel ($TOGGLED -> $IPC_OPENED px)"
else
	bad "ipc call clipboard toggle opens the panel ($TOGGLED -> $IPC_OPENED px)"
fi
qsipc toggle >/dev/null
sleep 1

# ── what the backend actually captured ──────────────────────────────────────
#
# The premise assertion for everything above: if this is 0, the panel that
# opened was an empty one and the pixel deltas measured chrome.
CLEARED="$(qsipc clear)"
# Matched against the whole "cleared N" shape, not just "a number appears
# somewhere". Pulling the first [0-9]+ out of the reply passed against
# quickshell's error text, because the path in it contains digits -- the same
# way the handler check above once passed against "No running instances".
COUNT="$(echo "$CLEARED" | sed -nE 's/^cleared ([0-9]+)$/\1/p')"
if [ -n "$COUNT" ] && [ "$COUNT" -ge 2 ]; then
	ok "the backend captured both copies ($CLEARED)"
else
	bad "the backend captured both copies (got '$CLEARED', want >= 2)"
fi

# ── the panel drew without complaining ──────────────────────────────────────
#
# Same check calendar-test.sh carries, and here for the same reason rather than
# by symmetry: pixel deltas say a panel appeared, not what it did on the way.
# The calendar spent hours throwing 80 TypeErrors an open while every one of
# its assertions passed, because a binding that throws still leaves the item
# drawn in its default state. Nothing was reading the log.
QML_ERRORS="$(grep -cE "TypeError|ReferenceError|is not a function" "$WORK/qs.log" 2>/dev/null || true)"
if [ "${QML_ERRORS:-0}" -eq 0 ]; then
	ok "the panel drew with no QML errors"
else
	bad "the panel drew with no QML errors ($QML_ERRORS logged)"
	grep -oE "@[A-Za-z]+\.qml\[[0-9]+.*" "$WORK/qs.log" | sort -u | head -5
fi

kill "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
