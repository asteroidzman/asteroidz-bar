#!/usr/bin/env bash
# lock-test.sh — the lock screen covers the desktop, and only PAM opens it.
#
# HEADLESS ONLY, and that is not a preference. Locking the session you are
# sitting in front of means typing a real password into a screen this test just
# built; if any part of it is wrong, the way back is a TTY. Every instance here
# is the harness's own compositor, and hl_stop kills it whether the lock is
# still up or not.
#
# What is asserted, in the order it matters:
#
#   1. locking actually locks       -- the desktop is gone from the screen
#   2. the wallpaper is drawn on it -- which is the whole feature request
#   3. the clock is drawn on it
#   4. IPC cannot unlock            -- a socket any process on this user can
#                                      reach must not be able to open the lock
#   5. it stays locked                -- and the PAM stack it names exists
#
# The negative assertions are the point of the file. A lock screen that does not
# appear is obvious the first time anyone uses it; a lock screen that can be
# opened by something other than a password is not obvious at all, and is the
# only kind of bug here that matters.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "lock-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}


# ── the idle timeout, in a session of its own ───────────────────────────────
#
# `idle { lock-timeout }` used to be gated on `lock-command` being set, so with
# no locker named the timeout fired into nothing -- correct when a named locker
# was the only thing that could lock, and a silently ignored setting once the
# shell could do it itself.
#
# Its own harness, because it cannot share the one above: this leaves the
# session locked, and nothing in a test can put in a password.
if [ "${1:-}" = "--idle" ]; then
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
	magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#1e7a4b' "$WORK/wall.png"
	printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
		> "$WORK/wallpaper.conf"
	bar_conf "tags" "" "clock" <<EOF
$(bar_conf_panel)
idle { enable #true; lock-timeout 2 }
EOF
	setsid $(bar_limits) dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
	QSI=$!
	# Long enough for the two-second timeout to elapse with nothing touching
	# the seat -- a headless instance has no input at all, so it is idle from
	# the moment it comes up.
	sleep 16
	timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call lock status 2>&1
	kill "$QSI" 2>/dev/null
	exit 0
fi

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

echo
echo "lock screen"

# A wallpaper with a colour nothing else in the scene has, so "the wallpaper is
# on the lock screen" is a question about one hue rather than about brightness.
# Flat, deliberately: what is being asked is whether this IMAGE reached the lock
# surface, and a flat field answers that with one sample per pixel.
magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#1e7a4b' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
animations 0
theme { font "Ubuntu 12"; border-width 0 }
EOF
bar_conf "tags" "" "clock" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1

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
sleep 9

# The whole-shell check first. A singleton that fails to parse takes every other
# singleton with it -- the shell comes up with no bar, no wallpaper and no lock,
# and every assertion below then fails for a reason that has nothing to do with
# what it is testing.
if grep -qE 'is not a type|unavailable|Cannot override|set multiple times' "$WORK/qs.log"; then
	bad "the shell loads with no QML errors"
	grep -E 'is not a type|unavailable|Cannot override|set multiple times' "$WORK/qs.log" \
		| head -5 | sed 's/^/      /'
	echo; echo "  $PASS passed, $FAIL failed"; kill "$QS" 2>/dev/null; exit 1
fi
ok "the shell loads with no QML errors"

# The same form the other suites use: the SHELL PATH is what selects the
# instance, and bin/asteroidz-bar is an uninstalled template whose @SHELLDIR@
# has not been substituted -- it answers every call with a config-file error
# that reads exactly like a broken feature.
qsipc() { timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call lock "$@" 2>&1; }

# A window with a colour of its own, so "the desktop is covered" is measurable
# rather than a judgement about a screenshot.
kitty --title LOCKME -o background_opacity=1.0 -o background='#c02020' \
	sh -c 'clear; exec sleep 300' > "$WORK/kitty.log" 2>&1 &
HL_SPAWNED_PIDS+=($!)
hl_wait_client_count 1
sleep 2

grim "$WORK/before.png" 2>/dev/null

count_hue() { # count_hue <shot> <r> <g> <b>  -> % of sampled pixels near it
	python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
tr, tg, tb = (int(v) for v in sys.argv[2:5])
px = im.load()
W, H = im.size
hit = n = 0
for y in range(0, H, 4):
    for x in range(0, W, 4):
        r, g, b = px[x, y]
        if abs(r - tr) < 24 and abs(g - tg) < 24 and abs(b - tb) < 24:
            hit += 1
        n += 1
print("%.1f" % (100.0 * hit / n))
PY
}

WIN_BEFORE="$(count_hue "$WORK/before.png" 192 32 32)"
if python3 -c "import sys; sys.exit(0 if $WIN_BEFORE > 20 else 1)"; then
	ok "the desktop is on screen before locking (window covers ${WIN_BEFORE}%)"
else
	bad "the desktop is on screen before locking (window covers ${WIN_BEFORE}% -- nothing below can fail)"
	echo; echo "  $PASS passed, $FAIL failed"; kill "$QS" 2>/dev/null; exit 1
fi

# ── lock ─────────────────────────────────────────────────────────────────────
LOCK_SAID="$(qsipc lock)"
sleep 3
grim "$WORK/locked.png" 2>/dev/null

if [ "$(qsipc status)" = "locked" ]; then
	ok "ipc call lock lock locks the session (said '$LOCK_SAID')"
else
	bad "ipc call lock lock locks the session (status says '$(qsipc status)')"
fi

WIN_AFTER="$(count_hue "$WORK/locked.png" 192 32 32)"
if python3 -c "import sys; sys.exit(0 if $WIN_AFTER < 1 else 1)"; then
	ok "...and the desktop is no longer visible (window down to ${WIN_AFTER}%)"
else
	bad "...and the desktop is no longer visible (window still ${WIN_AFTER}% of the screen)"
fi

# The feature as asked for: "when screen locked display whatever the current
# wallpaper is". The scrim darkens it, so the test looks for the wallpaper's
# HUE rather than its exact value -- a green that dark could not come from
# anywhere else in this scene.
WALL_ON_LOCK="$(python3 - "$WORK/locked.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
W, H = im.size
hit = n = 0
for y in range(0, H, 4):
    for x in range(0, W, 4):
        r, g, b = px[x, y]
        # green-dominant, and not grey: the wallpaper, at whatever the scrim
        # left of it
        if g > r + 12 and g > b + 4 and g > 20:
            hit += 1
        n += 1
print("%.1f" % (100.0 * hit / n))
PY
)"
if python3 -c "import sys; sys.exit(0 if $WALL_ON_LOCK > 50 else 1)"; then
	ok "...and the wallpaper is drawn on it (${WALL_ON_LOCK}% of the screen)"
else
	bad "...and the wallpaper is drawn on it (only ${WALL_ON_LOCK}% -- the lock screen is not showing it)"
fi

# The clock and date. Light pixels on a dark green field, in the middle band of
# the screen -- nothing else there is white.
TEXT="$(python3 - "$WORK/locked.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
W, H = im.size
hit = 0
for y in range(int(H * 0.25), int(H * 0.75)):
    for x in range(0, W, 2):
        r, g, b = px[x, y]
        if r > 170 and g > 170 and b > 170:
            hit += 1
print(hit)
PY
)"
if [ "$TEXT" -gt 400 ]; then
	ok "...with the clock and date on it ($TEXT light pixels in the middle band)"
else
	bad "...with the clock and date on it (only $TEXT light pixels -- nothing is drawn)"
fi

# ── and the ways it must NOT open ────────────────────────────────────────────
#
# There is deliberately no `unlock` function. quickshell answers an unknown
# function on a known target, so this asserts the shape of the reply rather than
# just "not empty" -- a target that grew an unlock method would still be a
# string, and would still be a hole.
UNLOCK_REPLY="$(qsipc unlock)"
if [ "$(qsipc status)" = "locked" ]; then
	ok "ipc call lock unlock does not open it (still locked)"
else
	bad "ipc call lock unlock OPENED THE SESSION -- the lock is bypassable over IPC"
fi
case "$UNLOCK_REPLY" in
*"not found"*|*"nknown"*|*"nvalid"*|*"o such"*)
	ok "...because there is no such function ($(printf '%s' "$UNLOCK_REPLY" | head -1))" ;;
*)
	bad "...but the target answered it: '$(printf '%s' "$UNLOCK_REPLY" | head -1)'" ;;
esac

# It stays locked on its own. A lock that drops after a few seconds because a
# binding re-evaluated, or because the surface was reconstructed, is worse than
# no lock: it looks like it worked.
sleep 4
if [ "$(qsipc status)" = "locked" ]; then
	ok "it is still locked several seconds later"
else
	bad "it UNLOCKED ITSELF after a few seconds"
fi

# Locking twice must not toggle. `lock()` is what a keybind calls, and a bind
# pressed twice is a bind pressed twice -- not an unlock.
qsipc lock >/dev/null
sleep 2
if [ "$(qsipc status)" = "locked" ]; then
	ok "locking again does not toggle it back off"
else
	bad "a second lock UNLOCKED the session"
fi

# The only way out is PAM, so the stack it names has to be one that exists.
#
# A static check, and the reason it is here rather than left to the packaging:
# if LockScreen.qml says `config: "asteroidz-bar"` and the file installed is
# called something else, every password is refused with "PAM error" -- on a
# locked screen, which is the one place a person cannot investigate. The two
# names are asserted against each other rather than against a hardcoded string.
PAM_NAME="$(sed -n 's/.*config: "\([^"]*\)".*/\1/p' "$HERE/shell/LockScreen.qml" | head -1)"
if [ -n "$PAM_NAME" ] && [ -f "$HERE/assets/pam/$PAM_NAME" ]; then
	ok "the PAM stack it names is one this package ships (assets/pam/$PAM_NAME)"
else
	bad "the PAM stack it names is one this package ships (LockScreen wants '$PAM_NAME')"
fi
if grep -q "assets/pam/asteroidz-bar" "$HERE/meson.build"; then
	ok "...and it is installed"
else
	bad "...and it is installed (nothing in meson.build installs it)"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

# ── one lock, however it is reached ─────────────────────────────────────────
#
# The power menu ran ~/.config/asteroidz/scripts/lock.sh, which exec'd
# swaylock. So "Lock" from the menu and `ipc call lock lock` locked the machine
# in two different ways, with two different appearances, and only one of them
# was this file's subject. Reported as "'Lock' from the power menu launches
# swaylock".
#
# Static, and honest about it: what it checks is that every entry point calls
# the same function. That function's behaviour is what everything above
# asserts.
# Code, not prose: the comments in LockScreen.qml explain at length why it does
# not borrow swaylock's PAM file, and a grep that counts those as offences
# reports the explanation as the bug.
spawns_locker() {
	grep -rn "swaylock\|scripts/lock.sh" "$HERE/shell" 2>/dev/null \
		| grep -vE ':[0-9]+:[[:space:]]*//'
}
if [ -n "$(spawns_locker)" ]; then
	bad "no lock action spawns another locker"
	spawns_locker | head -3 | sed 's/^/      /'
else
	ok "no lock action spawns another locker"
fi
if grep -q "LockScreen.lock()" "$HERE/shell/modules/Power.qml"; then
	ok "the power menu's Lock uses the shell's own lock screen"
else
	bad "the power menu's Lock uses the shell's own lock screen"
fi
if grep -q "LockScreen.lock()" "$HERE/shell/IdleService.qml"; then
	ok "...and so does the idle timeout"
else
	bad "...and so does the idle timeout"
fi

echo "  ..   locking on an idle timeout, in a session of its own"
IDLE_STATUS="$(bash "$0" --idle 2>/dev/null | tail -1)"
if [ "$IDLE_STATUS" = "locked" ]; then
	ok "an idle timeout locks with no lock-command set ($IDLE_STATUS)"
else
	bad "an idle timeout locks with no lock-command set (status '$IDLE_STATUS')"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
