#!/usr/bin/env bash
# notify-test.sh — the shell IS the notification daemon.
#
# It used to watch swaync over `swaync-client --subscribe`, and this file
# faked that client. There is nothing to fake now: the shell owns
# org.freedesktop.Notifications itself, so the test sends a REAL notification
# over the bus and looks at what happens -- which is what an application does,
# and the only thing that proves the daemon is actually reachable.
#
# On the private bus the harness starts, so it cannot collide with the real
# session\'s daemon and cannot be answered by it either. A notification sent
# here has exactly one possible recipient.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "notify-test: not built -- meson setup build && meson compile -C build" >&2
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
mkdir -p "$QMLROOT/Asteroidz/Bar" "$WORK/bin"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

# A stand-in for the sound player, first on PATH.
#
# Audible notifications are asserted by what the shell ASKS to be played, not
# by listening: a test that needed a sound card would not run anywhere, and a
# real pw-play on a headless machine writes to a sink nobody can inspect.
# This records the argument and exits, which is the whole contract -- the shell
# resolves a themed name to a file and hands it over.
# It also checks the file OPENS. Logging the argument alone is not enough: the
# first version of this feature handed pw-play a `file://` URL, which the real
# player cannot open and which every "does it mention the right sound" pattern
# matches perfectly. The stub said yes, the desktop stayed silent.
cat > "$WORK/bin/pw-play" <<'STUB'
#!/bin/sh
for arg in "$@"; do
	case "$arg" in
		-*) continue ;;
	esac
	if [ -r "$arg" ]; then
		echo "$arg" >> "$SOUND_LOG"
	else
		echo "UNPLAYABLE $arg" >> "$SOUND_LOG"
	fi
done
STUB
chmod +x "$WORK/bin/pw-play"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "" "" "notify" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 1

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
elif isinstance(c, str):
    print(c)
' 2>/dev/null)"
echo "  ..   accent: ${ACCENT:-<unknown>}"

# The shell and the sender share ONE bus, which is the whole point: the sender
# has to be able to find the daemon by its well-known name.
cat > "$WORK/run.sh" <<'INNER'
#!/usr/bin/env bash
set -u
WORK="$1"; HERE="$2"; SIG="$3"; WL="$4"; XRD="$5"; QMLROOT="$6"; BAR_CONF="$7"
MON="$8"; VPTR="$9"; EW="${10}"; EH="${11}"

SOUND_LOG="$WORK/sounds.log"
: > "$SOUND_LOG"

env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WL" \
	PATH="$WORK/bin:$PATH" SOUND_LOG="$SOUND_LOG" \
	XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 10

shot() { grim -o "$MON" "$WORK/$1.png" 2>/dev/null; }

# Is the name even taken? Everything below is meaningless if it is not, and
# "nothing was drawn" would be the symptom either way.
busctl --user list 2>/dev/null | grep -q "org.freedesktop.Notifications" \
	&& echo yes > "$WORK/owned" || echo no > "$WORK/owned"

shot quiet

# A real notification, sent the way any application sends one.
notify() { # notify <summary> <body>
	# Bounded. gdbus blocks until the method returns, so a shell that died
	# mid-call leaves it waiting for ever -- which turned a crash into a test
	# that hung until its outer timeout and reported nothing at all.
	timeout 5 gdbus call --session \
		--dest org.freedesktop.Notifications \
		--object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.Notify \
		"notify-test" 0 "" "$1" "$2" "[]" "{}" 5000 >/dev/null 2>&1
}

notify "First" "the body of the first one"
sleep 3
shot one

notify "Second" "and a second"
notify "Third" "and a third"
sleep 3
shot three

# A sender WITHDRAWING its own notification while it is STILL ON SCREEN, which
# is the case that crashed the shell: the object is destroyed when it closes,
# the popup list held a plain reference, and the next reassignment of that list
# regenerated Repeater delegates over a dangling pointer -- segfault inside
# QQmlIncubator. Any application that closes its own notification does this.
#
# The timeout has to outlast the withdrawal. Closing one that has already
# expired proves nothing, because expiry took it out of the list first -- which
# is exactly how the first version of this case passed against the bug.
STICKY="$(gdbus call --session \
	--dest org.freedesktop.Notifications \
	--object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.Notify \
	"notify-test" 0 "" "Sticky" "withdrawn while on screen" "[]" "{}" 60000 \
	2>/dev/null | grep -oE '[0-9]+' | head -1)"
sleep 2
gdbus call --session \
	--dest org.freedesktop.Notifications \
	--object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.CloseNotification "${STICKY:-1}" \
	>/dev/null 2>&1
sleep 1
# ...and then another arrives, which is what reassigns the list.
notify "Fourth" "after a withdrawal"
sleep 3
shot withdrawn

# With a PANEL OPEN, which is the state every crash report was taken in: each
# one has `Sending event "opened"` to a tray menu immediately before the fault.
# A popover has a Repeater of its own, so a notification arriving while one is
# incubating is the case where a second regenerate lands mid-incubation.
"$VPTR" $((EW - 30)) 33 "$EW" "$EH" >/dev/null 2>&1
sleep 1
"$VPTR" $((EW - 30)) 33 "$EW" "$EH" click >/dev/null 2>&1
sleep 2
for i in 1 2 3; do
	notify "WithPanel $i" "arriving while the centre is open" &
done
for _ in $(seq 1 30); do jobs -pr | grep -q . || break; sleep 0.5; done
sleep 3
if kill -0 "$QS" 2>/dev/null; then echo alive > "$WORK/panel-alive"; else echo dead > "$WORK/panel-alive"; fi
shot withpanel

# A BURST, which is what actually crashed the shell.
#
# `arrived` is emitted from inside the D-Bus Notify call, so building the popup
# list there reassigned a Repeater's model and made it incubate a delegate over
# a Notification the server had not finished setting up. Three crash reports,
# every one with Notify at the bottom of the stack and QQuickRepeater::setModel
# at the top. One notification at a time rarely hits it; several in the same
# turn do, which is why this sends them without pausing.
for i in 1 2 3 4 5 6 7 8; do
	notify "Burst $i" "arriving with no gap between them" &
done
# Bounded too: `wait` on a hung sender is the same trap one level up.
for _ in $(seq 1 40); do
	jobs -pr | grep -q . || break
	sleep 0.5
done
sleep 4
shot burst
if kill -0 "$QS" 2>/dev/null; then echo alive > "$WORK/burst-alive"; else echo dead > "$WORK/burst-alive"; fi

# ── the keybind's end of it ─────────────────────────────────────────────────
#
# swaync had `swaync-client -t`, so replacing swaync without an equivalent
# would leave every existing Super+n binding silently doing nothing. Last of
# all, because `clear` empties the list every assertion above measures.
qsipc() { timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call notify "$@" 2>/dev/null; }

# `quiet` is a TOGGLE, so a stage that wants a known state has to look first.
#
# Blind toggling couples every stage to the one before it: adding the
# fullscreen stage, which turns quiet off, silently inverted the sound stage
# below it and failed three assertions that had nothing to do with the change.
set_quiet() { # set_quiet on|off
	local want="$1" have
	case "$(qsipc state)" in *quiet*) have=on ;; *) have=off ;; esac
	[ "$have" = "$want" ] || qsipc quiet >/dev/null 2>&1
}

qsipc state | tr -d '\n' > "$WORK/ipc-state"
qsipc quiet | tr -d '\n' > "$WORK/ipc-quiet"
qsipc quiet | tr -d '\n' > "$WORK/ipc-quiet2"
qsipc clear | tr -d '\n' > "$WORK/ipc-clear"
sleep 2
qsipc state | tr -d '\n' > "$WORK/ipc-state2"

# Toggled TWICE, and the claim is that the screen differs between the two.
#
# Neither a single shot nor a before-and-after works here. A single shot cannot
# tell a panel from a leftover toast -- measured against a build with no
# `notify` target at all, that version reported 127009 px and passed, because
# `clear` had failed too and what it measured was the burst still on screen.
# And a before-and-after assumes the panel starts closed, which it does not:
# the click test above opened it and nothing closed it, so the first toggle
# CLOSED the centre and the ink went 20613 -> 0.
#
# Two toggles need no such assumption. Whichever way round the shell starts,
# one of these shots has a panel in it and the other does not.
qsipc toggle | tr -d '\n' > "$WORK/ipc-toggle"
sleep 2
shot ipctoggle1
qsipc toggle >/dev/null 2>&1
sleep 2
shot ipctoggle2

# ── quiet suppresses the POPUP, and only the popup ──────────────────────────
#
# The contract the whole do-not-disturb design rests on: what arrives still
# arrives, still lands in the centre and is still counted. A notification
# dropped instead of quieted is one the person never finds out about.
#
# The centre is CLOSED first, and the baseline is asserted to be clear below.
#
# Both toggles above ran, so the panel is open again -- and the centre draws in
# exactly the region a toast does. Measuring without closing it does not measure
# quiet at all: the notification lands in the open centre, the list grows by a
# row, and the region gains 35000px that look precisely like a toast appearing.
# That is what the first version of this reported, as a confident failure of a
# feature that was working.
qsipc toggle >/dev/null 2>&1
sleep 2
qsipc quiet | tr -d '\n' > "$WORK/ipc-quiet3"
sleep 1
qsipc state | tr -d '\n' > "$WORK/ipc-dnd-before"
shot dndbefore
notify "Quiet" "this must not pop up"
sleep 4
shot dndafter
qsipc state | tr -d '\n' > "$WORK/ipc-dnd-after"

# ── clearing a lot of them at once ──────────────────────────────────────────
#
# `clear all` is pressed from the OPEN centre, and that is the expensive state:
# the centre's Repeater takes `list` as its model, `list` is rebuilt on every
# dismissal, and a Repeater given a fresh array destroys and recreates every
# delegate it has. Dismissing one at a time is therefore quadratic in cards --
# and a card is not cheap, it has an icon, styled text and a RectangularGlow.
#
# Measured rather than eyeballed, because "feels slow" does not bisect.
# 200, not 40. The cost is quadratic in cards, so 40 is comfortably under
# the knee: it measured 290ms on a real desktop with the bug fully present,
# while 200 measured 7790ms. A budget set against 40 would have watched this
# regression sail past.
#
# Sequential rather than 200 background jobs, which is a fork storm that
# measures the harness.
for i in $(seq 1 200); do
	notify "Bulk $i" "one of many"
done
sleep 3
qsipc state | tr -d '\n' > "$WORK/bulk-before"
qsipc toggle >/dev/null 2>&1     # open the centre: the state clear is used in
sleep 2

# Measured as CPU BURNT, not as how long the call took to return.
#
# The call returns as soon as clearAll's loop ends -- 302ms even with the
# quadratic rebuild in place -- because the delegate churn it causes happens on
# later frames. Timing the IPC round trip therefore reports a number that has
# nothing to do with the fifteen seconds a person sits through.
#
# The shell's own utime+stime does capture it: rebuilding every card in the
# centre once per dismissal is work, and work shows up here whichever frame it
# lands on.
cpu_ms() { awk '{print int(($14 + $15) * 10)}' "/proc/$QS/stat" 2>/dev/null || echo 0; }

CPU_BEFORE="$(cpu_ms)"
CLEAR_START="$(date +%s%N)"
qsipc clear >/dev/null 2>&1

# Until the shell goes quiet again: two consecutive half-seconds with no CPU
# moved, or 30s, whichever is first.
prev=-1; stable=0
for _ in $(seq 1 60); do
	sleep 0.5
	cur="$(cpu_ms)"
	if [ "$cur" = "$prev" ]; then stable=$((stable + 1)); else stable=0; fi
	[ "$stable" -ge 2 ] && break
	prev="$cur"
done
CLEAR_END="$(date +%s%N)"
CPU_AFTER="$(cpu_ms)"

echo $(( (CLEAR_END - CLEAR_START) / 1000000 - 1000 )) > "$WORK/clear-ms"
echo $(( CPU_AFTER - CPU_BEFORE )) > "$WORK/clear-cpu-ms"
qsipc state | tr -d '\n' > "$WORK/bulk-after"

# ── not over a fullscreen window ────────────────────────────────────────────
#
# The toasts are on the OVERLAY layer, so they draw above everything -- a
# fullscreen client included. Across a film or a game that is an intrusion with
# no way to dismiss it that does not leave what you are doing.
#
# Quiet OFF, explicitly. Without it this measures quiet and would pass just as
# well with the feature absent.
set_quiet off
sleep 1

notify "Windowed" "visible with no fullscreen client"
sleep 3
shot fs_windowed

# A real client, made fullscreen through the compositor's own dispatch -- the
# module reads is_fullscreen off `watch all-clients`, so nothing short of an
# actual fullscreen window exercises it.
if command -v kitty >/dev/null 2>&1; then
	kitty --title fsclient -o background_opacity=1.0 -o background=#202030 \
		sh -c 'echo fs; exec sleep 120' > "$WORK/fsclient.log" 2>&1 &
	FSPID=$!
	sleep 4
	env ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" amsg dispatch toggle_fullscreen >/dev/null 2>&1
	sleep 2
	env ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" amsg get all-clients 2>/dev/null \
		| grep -o '"is_fullscreen":true' | head -1 > "$WORK/fs-state"

	# A baseline WITH the fullscreen window up and no new notification.
	#
	# Against zero this reads 211200 -- the whole region, because the window is
	# dark and fills the screen. That is the client, not a toast, and measuring
	# it as one reported the feature broken while it worked.
	shot fs_base

	notify "Fullscreened" "must not be drawn over a fullscreen window"
	sleep 3
	shot fs_full

	kill "$FSPID" 2>/dev/null
	sleep 2
else
	echo skipped > "$WORK/fs-state"
fi

# ── audible notifications ───────────────────────────────────────────────────
#
# Asserted by what the shell asks to be PLAYED. See the stub pw-play, first on
# this process's PATH.
#
# Last, and after the bulk clear on purpose: with sound on, 200 notifications
# would be 200 spawned players.
notify_hint() { # notify_hint <summary> <hints-dict>
	timeout 5 gdbus call --session \
		--dest org.freedesktop.Notifications \
		--object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.Notify \
		"notify-test" 0 "" "$1" "sound" "[]" "$2" 3000 >/dev/null 2>&1
}

# Audible, explicitly: a quieted notification makes no sound whatever the
# sound setting says, so this stage would prove nothing with quiet left on.
set_quiet off

# Off by default: nothing is played until it is asked for.
notify "Silent" "sound is not configured"
sleep 2
wc -l < "$SOUND_LOG" | tr -d ' ' > "$WORK/sound-off"

# Now switch it on, through the config file the settings page writes.
cat >> "$BAR_CONF" <<'CONF'
notify { sound #true }
CONF
sleep 3

notify "Audible" "the configured default"
sleep 2
cp "$SOUND_LOG" "$WORK/sound-default"

# A sender naming its own sound gets that one, not the default.
notify_hint "Named" "{'sound-name': <'bell'>}"
sleep 2
cp "$SOUND_LOG" "$WORK/sound-named"

# ...and a sender asking for silence is given it.
notify_hint "Hushed" "{'suppress-sound': <true>}"
sleep 2
wc -l < "$SOUND_LOG" | tr -d ' ' > "$WORK/sound-after-suppress"

# Quiet silences it too, which is the point of quiet.
set_quiet on
sleep 1
notify "Quieted" "while do-not-disturb is on"
sleep 2
wc -l < "$SOUND_LOG" | tr -d ' ' > "$WORK/sound-after-quiet"
cp "$SOUND_LOG" "$WORK/sound-after-quiet-log"

# Still alive? That is the assertion. A crashed shell draws nothing, so every
# pixel check below would report zero and blame the wrong thing.
if kill -0 "$QS" 2>/dev/null; then echo alive > "$WORK/alive"; else echo dead > "$WORK/alive"; fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null
INNER
chmod +x "$WORK/run.sh"

setsid $(bar_limits) dbus-run-session -- "$WORK/run.sh" "$WORK" "$HERE" "$HL_SIG" \
	"$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR" "$QMLROOT" "$BAR_CONF" "$HL_MON" \
	"$HL_WLVPTR" "$HL_PTR_EXTENT_W" "$HL_PTR_EXTENT_H"

# How much of the bell is drawn in the accent? That is the whole state: the
# glyph is tinted with the accent when something is unread and with the
# foreground when nothing is.
accent_px() { # accent_px <shot> [ymin] [ymax]
	python3 - "$WORK/$1.png" "${ACCENT:-#000000}" "${2:-10}" "${3:-80}" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
if len(acc) != 6:
    print(0); raise SystemExit
y0, y1 = int(sys.argv[3]), min(int(sys.argv[4]), h)
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
print(sum(1 for y in range(y0, y1) for x in range(w)
          if all(abs(a - b) <= 30 for a, b in zip(px[x, y], want))))
PY
}

# Ink anywhere BELOW the bar, in the right-hand third: the toast area. Nothing
# else draws there at all, so its presence is the measurement.
below_bar_px() { # below_bar_px <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
print(sum(1 for y in range(90, min(420, h)) for x in range(w * 2 // 3, w)
          if sum(px[x, y]) < 260))
PY
}

# The notify pill's WIDTH, not its area.
#
# This bar has one module in its right section, so the dark run across the bar
# strip is that pill's panel, and the panel is sized by what is in it: a bell
# alone, or a bell plus a digit and the padding before it.
#
# Area does not work, and passed vacuously when it was tried. Turning quiet on
# ALSO swaps the filled bell for the crossed-out one and drops the accent tint,
# and those alone take the dark-pixel count from 4996 to 2853 -- so the area
# shrank convincingly on a build that was still drawing the number.
bell_pill_w() { # bell_pill_w <shot>
	python3 - "$WORK/$1.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
# 12..54 is the bar's panel and nothing else. NOT 10..80: the toasts start at
# y=75 now, so a taller window measured the CARD's 427px width in the shots
# that have one and the pill's 53px in the shots that do not -- which is a
# beautifully consistent reading of whether a toast exists, and says nothing
# whatever about the bell.
xs = [x for y in range(12, min(54, h)) for x in range(w * 2 // 3, w)
      if sum(px[x, y]) < 260]
print(max(xs) - min(xs) + 1 if xs else 0)
PY
}

if [ "$(cat "$WORK/owned" 2>/dev/null)" = "yes" ]; then
	ok "the shell owns org.freedesktop.Notifications"
else
	bad "the shell owns org.freedesktop.Notifications"
fi

if [ "$(cat "$WORK/alive" 2>/dev/null)" = "alive" ]; then
	ok "a sender withdrawing its own notification does not crash the shell"
else
	bad "a sender withdrawing its own notification does not crash the shell"
fi

if [ "$(cat "$WORK/panel-alive" 2>/dev/null)" = "alive" ]; then
	ok "a notification arriving with the centre open does not crash the shell"
else
	bad "a notification arriving with the centre open does not crash the shell"
fi

if [ "$(cat "$WORK/burst-alive" 2>/dev/null)" = "alive" ]; then
	ok "a burst of notifications does not crash the shell"
else
	bad "a burst of notifications does not crash the shell"
fi

QUIET="$(accent_px quiet)"
ONE="$(accent_px one)"
POPUP_QUIET="$(below_bar_px quiet)"
POPUP_ONE="$(below_bar_px one)"
POPUP_THREE="$(below_bar_px three)"

if [ "$QUIET" -lt 40 ]; then
	ok "nothing unread leaves the bell untinted ($QUIET accent px)"
else
	bad "nothing unread leaves the bell untinted ($QUIET accent px)"
fi

# The count has to REACH the pill -- this is the assertion the swaync-era bug
# failed, and it is still the one that matters.
if [ "$ONE" -gt $((QUIET + 60)) ]; then
	ok "a notification arriving tints the bell ($QUIET -> $ONE accent px)"
else
	bad "a notification arriving tints the bell ($QUIET -> $ONE accent px)"
fi

# Measured on the STACK, not on the bell.
#
# The obvious assertion is that the pill grows -- it carries the count -- and
# it does, by two pixels: "1" and "3" are the same width in this font, so the
# margin was noise and would have flaked on a hinting change. Three popups
# against one is a whole card of difference, and it is the claim that actually
# matters: each notification gets its own, rather than the newest replacing
# the last.
if [ "$POPUP_THREE" -gt $((POPUP_ONE + 5000)) ]; then
	ok "...and each one gets its own popup ($POPUP_ONE -> $POPUP_THREE px)"
else
	bad "...and each one gets its own popup ($POPUP_ONE -> $POPUP_THREE px)"
fi

# The toast itself. Nothing draws below the bar until one arrives.
if [ "$POPUP_QUIET" -lt 200 ]; then
	ok "nothing is drawn below the bar with no notifications ($POPUP_QUIET px)"
else
	bad "nothing is drawn below the bar with no notifications ($POPUP_QUIET px)"
fi
if [ "$POPUP_ONE" -gt $((POPUP_QUIET + 2000)) ]; then
	ok "a notification puts a popup on screen ($POPUP_QUIET -> $POPUP_ONE px)"
else
	bad "a notification puts a popup on screen ($POPUP_QUIET -> $POPUP_ONE px)"
fi

# ── what a keybind can ask for ──────────────────────────────────────────────
IPC_STATE="$(cat "$WORK/ipc-state" 2>/dev/null)"
IPC_QUIET="$(cat "$WORK/ipc-quiet" 2>/dev/null)"
IPC_QUIET2="$(cat "$WORK/ipc-quiet2" 2>/dev/null)"
IPC_CLEAR="$(cat "$WORK/ipc-clear" 2>/dev/null)"
IPC_STATE2="$(cat "$WORK/ipc-state2" 2>/dev/null)"
IPC_TOGGLE="$(cat "$WORK/ipc-toggle" 2>/dev/null)"

case "$IPC_STATE" in
	''|*[!0-9]*) bad "the unread count is readable over IPC (got '${IPC_STATE:-<nothing>}')" ;;
	0) bad "the unread count is readable over IPC (got 0 with notifications present)" ;;
	*) ok "the unread count is readable over IPC ($IPC_STATE unread)" ;;
esac

# Both directions. A toggle that only ever reports "quiet" is a toggle that
# does not toggle, and one call cannot tell the difference.
if [ "$IPC_QUIET" = "quiet" ] && [ "$IPC_QUIET2" = "audible" ]; then
	ok "quiet toggles both ways over IPC ($IPC_QUIET -> $IPC_QUIET2)"
else
	bad "quiet toggles both ways over IPC (got '$IPC_QUIET' then '$IPC_QUIET2')"
fi

if [ "$IPC_CLEAR" = "$IPC_STATE" ] && [ "$IPC_STATE2" = "0" ]; then
	ok "clear empties the centre and says how many ($IPC_CLEAR cleared)"
else
	bad "clear empties the centre and says how many (cleared '$IPC_CLEAR' of '$IPC_STATE', left '$IPC_STATE2')"
fi

# The monitor it names is the one that answered, which is what makes this
# work on more than one screen.
if [ "$IPC_TOGGLE" = "$HL_MON" ]; then
	ok "toggle names the monitor that answered ($IPC_TOGGLE)"
else
	bad "toggle names the monitor that answered (got '$IPC_TOGGLE', wanted '$HL_MON')"
fi

# And it actually moves the centre: one of the two shots has a panel in it and
# the other does not. See the note beside the toggles for why this is not a
# before-and-after.
T1="$(below_bar_px ipctoggle1)"
T2="$(below_bar_px ipctoggle2)"
if [ "$T1" -gt $((T2 + 2000)) ] || [ "$T2" -gt $((T1 + 2000)) ]; then
	ok "toggle opens and closes the notification centre ($T1 <-> $T2 px)"
else
	bad "toggle opens and closes the notification centre ($T1 <-> $T2 px)"
fi

# ── quiet ───────────────────────────────────────────────────────────────────
DND_BEFORE_N="$(cat "$WORK/ipc-dnd-before" 2>/dev/null)"
DND_AFTER_N="$(cat "$WORK/ipc-dnd-after" 2>/dev/null)"
DND_BEFORE_PX="$(below_bar_px dndbefore)"
DND_AFTER_PX="$(below_bar_px dndafter)"
DND_DELTA=$((DND_AFTER_PX - DND_BEFORE_PX))
[ "$DND_DELTA" -lt 0 ] && DND_DELTA=$((-DND_DELTA))

# The premise, checked rather than assumed: nothing is already drawn there.
# Without this the delta below is measuring an open notification centre growing
# by a row, which looks exactly like a toast arriving.
if [ "$DND_BEFORE_PX" -lt 2000 ]; then
	ok "the toast area is clear before the quiet test ($DND_BEFORE_PX px)"
else
	bad "the toast area is clear before the quiet test ($DND_BEFORE_PX px)"
fi

# A toast is tens of thousands of pixels; 1000 is slack for the clock and the
# bell's own count changing between the two shots.
if [ "$DND_DELTA" -lt 1000 ]; then
	ok "quiet suppresses the popup ($DND_BEFORE_PX -> $DND_AFTER_PX px)"
else
	bad "quiet suppresses the popup ($DND_BEFORE_PX -> $DND_AFTER_PX px)"
fi

# The other half, and the one that makes quiet different from dropping it.
# `state` reports "<n>" or "<n> quiet", so the count is the first field.
DND_B="${DND_BEFORE_N%% *}"
DND_A="${DND_AFTER_N%% *}"
case "${DND_A:-x}${DND_B:-x}" in
	*[!0-9]*) bad "...and the notification still arrives (got '$DND_BEFORE_N' -> '$DND_AFTER_N')" ;;
	*)
		if [ "$DND_A" -eq $((DND_B + 1)) ]; then
			ok "...and the notification still arrives ($DND_B -> $DND_A in the centre)"
		else
			bad "...and the notification still arrives ($DND_B -> $DND_A in the centre)"
		fi
		;;
esac

# The count is not shown while quiet.
#
# Compared against `one`, which is the same situation in every respect that
# matters -- exactly ONE notification held, the same bar, the same single
# module in the right section -- differing only in whether quiet is on. So the
# pill is narrower by precisely the digit and its padding.
#
# The crossed-out bell already says the state; a count beside it turns "I have
# silenced these" back into "you have one waiting", which is the interruption
# in another form.
BELL_LOUD="$(bell_pill_w one)"
BELL_QUIET="$(bell_pill_w dndafter)"
# A digit plus its padding is a good fraction of the pill. 10px of margin keeps
# this clear of a hinting difference between two glyphs.
if [ "${BELL_QUIET:-99999}" -lt $((BELL_LOUD - 10)) ]; then
	ok "quiet drops the count from the bell (${BELL_LOUD}px -> ${BELL_QUIET}px wide)"
else
	bad "quiet drops the count from the bell (${BELL_LOUD}px -> ${BELL_QUIET}px wide)"
fi

# ── clearing in bulk ────────────────────────────────────────────────────────
BULK_BEFORE="$(cat "$WORK/bulk-before" 2>/dev/null)"
BULK_AFTER="$(cat "$WORK/bulk-after" 2>/dev/null)"
CLEAR_MS="$(cat "$WORK/clear-ms" 2>/dev/null)"
BULK_B="${BULK_BEFORE%% *}"
BULK_A="${BULK_AFTER%% *}"

if [ "${BULK_B:-0}" -ge 200 ] 2>/dev/null; then
	ok "200 notifications are waiting to be cleared ($BULK_B)"
else
	bad "200 notifications are waiting to be cleared (got '$BULK_BEFORE')"
fi

if [ "${BULK_A:-x}" = "0" ]; then
	ok "...and clear empties every one of them"
else
	bad "...and clear empties every one of them (left '$BULK_AFTER')"
fi

# A budget, not a benchmark, and measured in CPU rather than wall clock.
#
# Dismissing one at a time rebuilds the centre's whole delegate list per
# notification, which is quadratic in cards -- fifteen seconds for a few dozen
# on a real desktop. 2000ms of CPU is far above what a batched clear of 40
# needs and far below the 7790ms the quadratic cost at this count, so it does
# not flake on a loaded machine but still fails if the quadratic comes back.
CLEAR_CPU="$(cat "$WORK/clear-cpu-ms" 2>/dev/null)"
if [ "${CLEAR_CPU:-99999}" -lt 2000 ]; then
	ok "...in one batch, not one rebuild each (${CLEAR_CPU}ms cpu, settled in ${CLEAR_MS}ms)"
else
	bad "...in one batch, not one rebuild each (${CLEAR_CPU}ms cpu, settled in ${CLEAR_MS}ms)"
fi

# ── not over a fullscreen window ────────────────────────────────────────────
FS_STATE="$(cat "$WORK/fs-state" 2>/dev/null)"
if [ "$FS_STATE" = "skipped" ]; then
	echo "  ..   skipped the fullscreen case: no kitty to make a window with"
else
	FS_WINDOWED="$(below_bar_px fs_windowed)"
	FS_BASE="$(below_bar_px fs_base)"
	FS_FULL="$(below_bar_px fs_full)"
	FS_DELTA=$((FS_FULL - FS_BASE))
	[ "$FS_DELTA" -lt 0 ] && FS_DELTA=$((-FS_DELTA))

	# The premise. Without a client that actually went fullscreen, "no toast
	# was drawn" below is true for the wrong reason.
	if [ -n "$FS_STATE" ]; then
		ok "a client really is fullscreen for the second shot"
	else
		bad "a client really is fullscreen for the second shot"
	fi

	if [ "${FS_WINDOWED:-0}" -gt 2000 ]; then
		ok "a toast is drawn with no fullscreen client ($FS_WINDOWED px)"
	else
		bad "a toast is drawn with no fullscreen client ($FS_WINDOWED px)"
	fi

	# The DIFFERENCE the notification made, not the absolute ink: a fullscreen
	# window is itself dark and fills the region being measured.
	if [ "${FS_DELTA:-99999}" -lt 2000 ]; then
		ok "...and none over a fullscreen one ($FS_BASE -> $FS_FULL px)"
	else
		bad "...and none over a fullscreen one ($FS_BASE -> $FS_FULL px)"
	fi
fi

# ── audible notifications ───────────────────────────────────────────────────
SND_OFF="$(cat "$WORK/sound-off" 2>/dev/null)"
SND_DEFAULT="$(tail -1 "$WORK/sound-default" 2>/dev/null)"
SND_NAMED="$(tail -1 "$WORK/sound-named" 2>/dev/null)"
SND_AFTER_SUPPRESS="$(cat "$WORK/sound-after-suppress" 2>/dev/null)"
SND_AFTER_QUIET="$(cat "$WORK/sound-after-quiet" 2>/dev/null)"
SND_DEFAULT_N="$(wc -l < "$WORK/sound-default" 2>/dev/null | tr -d ' ')"
SND_NAMED_N="$(wc -l < "$WORK/sound-named" 2>/dev/null | tr -d ' ')"

if [ "${SND_OFF:-1}" = "0" ]; then
	ok "nothing is played until sound is turned on"
else
	bad "nothing is played until sound is turned on (${SND_OFF} plays)"
fi

# The configured default, resolved from a NAME through the sound theme to a
# real file -- which is the part worth asserting, since a name that resolves to
# nothing would play silence and look identical from the outside.
case "$SND_DEFAULT" in
	/*/sounds/*message-new-instant.*)
		ok "a notification plays the configured sound ($(basename "$SND_DEFAULT"))" ;;
	*) bad "a notification plays the configured sound (got '${SND_DEFAULT:-nothing}')" ;;
esac

case "$SND_NAMED" in
	/*/sounds/*bell.*)
		ok "...and a sender's own sound-name wins over it ($(basename "$SND_NAMED"))" ;;
	*) bad "...and a sender's own sound-name wins over it (got '${SND_NAMED:-nothing}')" ;;
esac

if [ "${SND_AFTER_SUPPRESS:-0}" = "${SND_NAMED_N:-x}" ]; then
	ok "...and suppress-sound is honoured (still $SND_AFTER_SUPPRESS plays)"
else
	bad "...and suppress-sound is honoured ($SND_NAMED_N -> $SND_AFTER_SUPPRESS plays)"
fi

if [ "${SND_AFTER_QUIET:-0}" = "${SND_AFTER_SUPPRESS:-x}" ]; then
	ok "...and quiet silences it too (still $SND_AFTER_QUIET plays)"
else
	bad "...and quiet silences it too ($SND_AFTER_SUPPRESS -> $SND_AFTER_QUIET plays)"
fi

# Nothing was handed to the player that it could not open. This is the
# assertion the `file://` bug walked straight past: the shell asked for the
# right SOUND by the wrong kind of NAME.
if ! grep -q UNPLAYABLE "$WORK/sound-after-quiet-log" 2>/dev/null; then
	ok "...and every path handed to the player can actually be opened"
else
	bad "...and every path handed to the player can actually be opened"
	grep UNPLAYABLE "$WORK/sound-after-quiet-log" | head -3 | sed 's/^/       /'
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
