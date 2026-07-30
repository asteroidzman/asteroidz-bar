#!/usr/bin/env bash
# plugin-lifecycle-test.sh — a plugin dies with the bar that started it.
#
# No compositor and no bar: the contract is entirely about a pipe, so the test
# is a pipe. That also makes it the only test here that runs in a second.
#
# The bug it pins: a continuous plugin polls forever after the bar goes away.
# 27 of them were found running across five previous bar sessions, the oldest a
# day old, still asking nordvpn for its status every few seconds. Nothing was
# going to stop them --
#
#   * the reader thread DOES see stdin close (`for line in sys.stdin` ends), but
#     it is a daemon thread, so its return means nothing and main()'s
#     `while True: poll; emit; sleep` carried on;
#   * the obvious backstop, BrokenPipeError from writing to the closed stdout,
#     never fires, because emit() DEDUPLICATES. A plugin whose state has not
#     changed writes nothing at all, so it never touches the broken pipe and
#     never finds out. That is the whole reason this was invisible.
#
# So each plugin now calls exit_with_the_bar() when stdin ends, and Custom.qml
# stops its children on destruction as well.
#
# Asserted per plugin: it starts, it survives while stdin is open (a plugin that
# exits immediately would pass a naive "did it die" check), and it is gone
# within a couple of seconds of stdin closing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check_plugin() { # check_plugin <name>
	local name="$1"
	local bin="$HERE/plugins/asteroidz-bar-$name"
	[ -x "$bin" ] || { bad "[$name] plugin is executable"; return; }

	local fifo="$WORK/$name.in"
	mkfifo "$fifo"

	# Hold the write end open from a background sleep, so stdin stays open until
	# we choose to close it -- the whole point of the test.
	( exec 9>"$fifo"; sleep 30 ) &
	local holder=$!

	"$bin" < "$fifo" > "$WORK/$name.out" 2> "$WORK/$name.err" &
	local pid=$!
	sleep 2

	if ! kill -0 "$pid" 2>/dev/null; then
		bad "[$name] stays up while stdin is open (exited early; stderr: $(tr '\n' ' ' < "$WORK/$name.err" | cut -c1-90))"
		kill "$holder" 2>/dev/null
		return
	fi
	ok "[$name] stays up while stdin is open"

	# Close stdin by dropping the holder. The plugin's `for line in sys.stdin`
	# then ends and exit_with_the_bar() runs.
	kill "$holder" 2>/dev/null
	wait "$holder" 2>/dev/null

	local waited=0
	while [ "$waited" -lt 30 ]; do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.2
		waited=$((waited + 1))
	done

	if kill -0 "$pid" 2>/dev/null; then
		bad "[$name] exits when stdin closes (still alive after $((waited / 5))s)"
		# Do not leave the very thing this test is about lying around.
		kill -KILL "$pid" 2>/dev/null
	else
		ok "[$name] exits when stdin closes (after $((waited * 200))ms)"
	fi
	wait "$pid" 2>/dev/null
}

echo "=== a plugin dies with the bar that started it ==="
for p in nordvpn discord medication; do
	check_plugin "$p"
done

# The daemon guard. asteroidz-bar-discord spawns discord-voiced when it cannot
# reach the socket, which is right -- but it did so even when a socket FILE was
# already present, and a second daemon cannot bind a path that is taken. It just
# sits there. Sixteen were found, the socket dated to the first one and never
# replaced, fifteen accumulated over one afternoon of bar restarts.
echo
echo "=== discord does not pile up daemons behind an existing socket ==="
DAEMON_COUNT_BEFORE=$(pgrep -c -f 'discord-voiced' 2>/dev/null || echo 0)
FAKE_RUNTIME="$WORK/runtime"
mkdir -p "$FAKE_RUNTIME"
# A socket file that nothing is listening on: exactly the wedged/stale case.
python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
" "$FAKE_RUNTIME/discord-voiced.sock"
[ -S "$FAKE_RUNTIME/discord-voiced.sock" ] \
	&& ok "a dead socket file is in place for the plugin to find" \
	|| bad "a dead socket file is in place for the plugin to find"

fifo="$WORK/dg.in"
mkfifo "$fifo"
( exec 9>"$fifo"; sleep 12 ) &
holder=$!
XDG_RUNTIME_DIR="$FAKE_RUNTIME" "$HERE/plugins/asteroidz-bar-discord" \
	< "$fifo" > "$WORK/dg.out" 2> "$WORK/dg.err" &
dpid=$!
sleep 5
DAEMON_COUNT_AFTER=$(pgrep -c -f 'discord-voiced' 2>/dev/null || echo 0)
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
sleep 1
kill -0 "$dpid" 2>/dev/null && kill -KILL "$dpid" 2>/dev/null
wait "$dpid" 2>/dev/null

if [ "$DAEMON_COUNT_AFTER" -le "$DAEMON_COUNT_BEFORE" ]; then
	ok "no daemon spawned behind a dead socket ($DAEMON_COUNT_BEFORE -> $DAEMON_COUNT_AFTER)"
else
	bad "no daemon spawned behind a dead socket ($DAEMON_COUNT_BEFORE -> $DAEMON_COUNT_AFTER)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
