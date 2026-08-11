#!/usr/bin/env bash
# ipc-reconnect-test.sh — the compositor connection, treated as the
# distributed-state boundary it is.
#
# The bar's subscriptions ride Quickshell's Socket, which redials exactly once
# when an ESTABLISHED connection closes -- an attempt usually made while the
# server is still restarting -- and when that attempt fails, nothing ever
# tried again: one compositor restart left the theme, the tags and the focus
# frozen at their last values until the shell was restarted by hand. Ipc.qml
# carries its own retry-with-backoff now, and this is the test that pins it.
#
# The compositor's half is a python stub (contrib/lib/ipc-stub.py) rather than
# asteroidz itself, because the assertion needs a server that can die and come
# back on demand -- and because the stub can deliberately FRAGMENT its writes,
# which exercises the newline framing the same way a busy real socket would.
#
#   1. the bar subscribes on startup (bar-config, all-monitors, all-clients,
#      idle) -- against a server that fragments every reply
#   2. fragmented and coalesced replies produce no "bad IPC line"
#   3. the server dies; a NEW server on the same path sees every subscription
#      arrive again, unprompted -- the reconnect
#   4. a malformed line on a live subscription is logged, dropped, and the
#      shell survives it still subscribed
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "ipc-reconnect-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

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
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# tags is what makes all-monitors matter; idle { enable } arms the idle watch.
bar_conf "tags" "clock" "" <<EOF
$(bar_conf_panel)
idle { enable #true; dpms-timeout 600 }
EOF

STUB_SOCK="$WORK/stub-ipc.sock"
STUB_LOG1="$WORK/stub-phase1.log"
STUB_LOG2="$WORK/stub-phase2.log"
STUB_LOG3="$WORK/stub-phase3.log"

python3 "$HERE/contrib/lib/ipc-stub.py" "$STUB_SOCK" "$STUB_LOG1" --fragment &
STUB=$!
sleep 1

# The bar rides the HEADLESS compositor's Wayland display, but its IPC is
# pointed at the stub: the two are separable, which is what makes a
# compositor "restart" a thing a test can stage.
setsid $(bar_limits) dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$STUB_SOCK" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > $WORK/qs.log 2>&1 &
QS=$!
sleep 10

wants="watch bar-config
watch all-monitors
watch all-clients
watch idle"

# 1. every subscription arrived, against a server fragmenting its replies
missing=""
while read -r w; do
	grep -q "$w" "$STUB_LOG1" || missing="$missing $w"
done <<< "$wants"
if [ -z "$missing" ]; then
	ok "all subscriptions installed at startup"
else
	bad "all subscriptions installed at startup (missing:$missing)"
fi

# 2. fragmented and coalesced replies parsed clean
if grep -q "bad IPC line" "$WORK/qs.log" 2>/dev/null; then
	bad "fragmented replies parsed without a bad-line warning"
else
	ok "fragmented replies parsed without a bad-line warning"
fi

# 3. kill the server; leave it down long enough for the bar to FAIL several
#    retries (the path that used to be terminal); then a new server, same path.
kill "$STUB" 2>/dev/null
wait "$STUB" 2>/dev/null
rm -f "$STUB_SOCK"
sleep 6

python3 "$HERE/contrib/lib/ipc-stub.py" "$STUB_SOCK" "$STUB_LOG2" &
STUB=$!
# The backoff caps at 5s; allow three intervals.
sleep 15

missing=""
while read -r w; do
	grep -q "$w" "$STUB_LOG2" 2>/dev/null || missing="$missing $w"
done <<< "$wants"
if [ -z "$missing" ]; then
	ok "every subscription re-installed after a server restart"
else
	bad "every subscription re-installed after a server restart (missing:$missing)"
fi

# 4. a third cycle, against a server that answers every watch with a garbage
#    line followed by a good one: the garbage is reported, the connection
#    survives, the shell survives.
kill "$STUB" 2>/dev/null
wait "$STUB" 2>/dev/null
rm -f "$STUB_SOCK"

python3 - "$STUB_SOCK" "$STUB_LOG3" <<'PY' &
import json, os, socket, sys, threading
path, logp = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(16)
log = open(logp, "a", buffering=1)
def serve(c):
    f = c.makefile("r")
    try:
        for line in f:
            cmd = line.strip()
            if not cmd: continue
            log.write("%s\n" % cmd)
            c.sendall(b"{this is not json\n")
            c.sendall((json.dumps({"theme": {}}) + "\n").encode())
    except OSError:
        pass
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
STUB=$!
sleep 15

if grep -q "bad IPC line" "$WORK/qs.log" 2>/dev/null; then
	ok "a malformed line is reported"
else
	bad "a malformed line is reported"
fi
if grep -q "watch bar-config" "$STUB_LOG3" 2>/dev/null && kill -0 "$QS" 2>/dev/null; then
	ok "the shell survives it, still subscribed"
else
	bad "the shell survives it, still subscribed"
fi

kill "$STUB" 2>/dev/null
bar_session_kill "$QS"

echo
echo "ipc-reconnect-test: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
