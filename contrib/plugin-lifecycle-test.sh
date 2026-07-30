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

# NOT tested here: the daemon.
#
# An assertion that the plugin declines to spawn discord-voiced when a socket
# file already exists was written, passed, and was wrong. It came from finding
# 16 discord-voiced processes and concluding the plugin was piling them up --
# but thirteen were bound to /tmp/asteroidz-hl-*/xdg/discord-voiced.sock, litter
# from headless test runs with their own XDG_RUNTIME_DIR, and one was left by
# THIS test's own pre-fix run. And discord-voiced unlinks a stale socket and
# rebinds it, so "a socket file exists" is the case where spawning is the
# correct recovery. The guard was reverted; see spawn_daemon().
#
# The lesson is about the test, not the daemon: a process census on a machine
# that has been running headless tests all day is mostly a census of the tests.

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
