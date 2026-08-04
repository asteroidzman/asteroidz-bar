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
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar" "$WORK/bin"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

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

env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WL" \
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

# Still alive? That is the assertion. A crashed shell draws nothing, so every
# pixel check below would report zero and blame the wrong thing.
if kill -0 "$QS" 2>/dev/null; then echo alive > "$WORK/alive"; else echo dead > "$WORK/alive"; fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null
INNER
chmod +x "$WORK/run.sh"

setsid dbus-run-session -- "$WORK/run.sh" "$WORK" "$HERE" "$HL_SIG" \
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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
