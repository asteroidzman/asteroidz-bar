#!/usr/bin/env bash
# idle-test.sh — the bar blanks the screen on idle, and brings it back.
#
# This is the whole chain in one assertion: the compositor's ext-idle-notify-v1
# fires, the bar's IdleMonitor sees it, the bar dispatches dpms_off_monitor, and
# the monitor reports itself asleep. Then input, and the same in reverse. Every
# link is somebody else's code except the middle one, which is exactly why the
# ends are what get measured.
#
# It replaces swayidle, so the thing worth proving is that nothing else is
# needed: no daemon is started here, and the timeouts come from the compositor's
# own config over `watch bar-config`.
#
# Three seconds rather than ten minutes. The timeout is a config value, so a
# short one exercises the same code an hour-long one would, and a test that
# waited out a realistic timeout would never be run.
#
# Activity is a KEYPRESS, not pointer motion, and that is not a stylistic
# choice. A virtual pointer sends time_msec 0 (wlvptr, and anything else driving
# zwlr_virtual_pointer_v1), and asteroidz's motionnotify does its
# idle-activity notify and wake_sleeping_monitors inside `if (time)` -- so
# synthetic pointer motion neither wakes an output nor counts as activity, while
# every keyboard path reports both unconditionally. Real hardware sends real
# timestamps and is unaffected; a test driving a virtual pointer is not.
#
# Every check below is timed against that three seconds, and the first version
# of this file was not: it waited five seconds before asserting "awake to begin
# with" (it had already slept), and checked three seconds after the wake-up
# input (it had slept AGAIN). Both read as the feature being broken while it was
# working. With a short timeout, when you look is part of the test.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "idle-test: not built -- meson setup build && meson compile -C build" >&2
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

asleep() { # asleep -> true/false for the harness monitor
	hl_get "get all-monitors" \
		| jq -r --arg m "$HL_MON" '.monitors[] | select(.name==$m) | .asleep'
}

cat >> "$HL_CONFIG" <<'EOF'
bar { enable false
	idle { enable true; dpms-timeout 3 } }
EOF
hl_dispatch "reload_config" 1

# The bar, with nothing else running: no swayidle, no session daemon.
dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	"$HERE/bin/asteroidz-bar" > "$WORK/bar.log" 2>&1 &
BAR=$!
sleep 5

# Awake to begin with, or nothing below means anything. Input FIRST: five
# seconds have passed while the bar started, which is longer than the timeout.
"$HL_WLVKBD" press SPACE >/dev/null 2>&1
sleep 1
if [ "$(asleep)" = "false" ]; then
	ok "the monitor is awake before the timeout"
else
	bad "the monitor is awake before the timeout (got '$(asleep)')"
fi

# Nothing touches the input devices for longer than the timeout.
sleep 6
if [ "$(asleep)" = "true" ]; then
	ok "the bar powers the output down on idle"
else
	bad "the bar powers the output down on idle (got '$(asleep)')"
fi

# Any input at all is activity.
# Checked well inside the timeout, or it simply falls asleep again and the
# wake-up is invisible.
"$HL_WLVKBD" press SPACE >/dev/null 2>&1
sleep 1
if [ "$(asleep)" = "false" ]; then
	ok "and brings it back on input"
else
	bad "and brings it back on input (got '$(asleep)')"
fi

# Turning it off is a reload, not a restart: the same running bar must stop
# acting on the timeout. This is the half that a "does it fire" test misses,
# and the half a person hits first when they try the setting out.
cp "$HL_CONFIG" "$WORK/config.idle.kdl"
sed -i 's/idle { enable true; dpms-timeout 3 }/idle { enable false; dpms-timeout 3 }/' \
	"$HL_CONFIG"
hl_dispatch "reload_config" 1
"$HL_WLVKBD" press SPACE >/dev/null 2>&1
sleep 6
if [ "$(asleep)" = "false" ]; then
	ok "disabling idle takes effect on reload, without restarting the bar"
else
	bad "disabling idle takes effect on reload, without restarting the bar (got '$(asleep)')"
fi

# ── the cup ─────────────────────────────────────────────────────────────────
#
# The bar's idle pill flips the compositor's manual inhibit
# (`toggle_idle_inhibit`), and the whole reason that dispatch exists is to stop
# the screen going off. Until this file it was never checked that it does: the
# pill dispatched, the compositor set a flag, and nothing tied the flag to the
# outcome. The state was not even readable, so the pill kept its own copy of
# what it had last done -- a copy that a bar restart resets to "off" over a
# compositor that is still holding sleep off.
#
# Driven through `amsg dispatch`, which is the same dispatch the pill sends.
# Clicking the actual pixel is click-test.sh's job; what is at stake here is
# whether the flag reaches the timeout.
sed -i 's/idle { enable false; dpms-timeout 3 }/idle { enable true; dpms-timeout 3 }/' \
	"$HL_CONFIG"
hl_dispatch "reload_config" 1

hl_dispatch "toggle_idle_inhibit,1" 0.3
"$HL_WLVKBD" press SPACE >/dev/null 2>&1
sleep 6
if [ "$(asleep)" = "false" ]; then
	ok "the idle pill's inhibit stops the bar powering the output down"
else
	bad "the idle pill's inhibit stops the bar powering the output down (got '$(asleep)')"
fi

# And giving it back starts the clock again, without touching anything else.
hl_dispatch "toggle_idle_inhibit,0" 0.3
sleep 6
if [ "$(asleep)" = "true" ]; then
	ok "and releasing it lets the timeout happen again"
else
	bad "and releasing it lets the timeout happen again (got '$(asleep)')"
fi
"$HL_WLVKBD" press SPACE >/dev/null 2>&1
sleep 1

# respect-inhibitors OFF must not disable the USER's own toggle.
#
# A CONTRACT check, not a check of the line that implements it, and the
# difference is worth stating because this assertion passes with the bar-side
# gate removed. That was measured, not assumed: the compositor's
# wlr_idle_notifier_v1_set_inhibited suppresses idle even for a client that
# asked to ignore inhibitors, so the guarantee is currently kept a layer below
# the bar. It is here because the guarantee is what a person depends on --
# turning off inhibitors to stop a browser holding the screen awake must not
# quietly take their own keep-awake button with it -- and because if either
# layer stops keeping it, this fails.
sed -i 's/idle { enable true; dpms-timeout 3 }/idle { enable true; dpms-timeout 3; respect-inhibitors false }/' \
	"$HL_CONFIG"
hl_dispatch "reload_config" 1
hl_dispatch "toggle_idle_inhibit,1" 0.3
"$HL_WLVKBD" press SPACE >/dev/null 2>&1
sleep 6
if [ "$(asleep)" = "false" ]; then
	ok "respect-inhibitors false does not disable the user's own keep-awake"
else
	bad "respect-inhibitors false does not disable the user's own keep-awake (got '$(asleep)')"
fi
hl_dispatch "toggle_idle_inhibit,0" 0.3

kill "$BAR" 2>/dev/null
wait "$BAR" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
