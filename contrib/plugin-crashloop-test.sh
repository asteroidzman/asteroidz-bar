#!/usr/bin/env bash
# plugin-crashloop-test.sh — a broken plugin costs its own pill, not a core.
#
# quickshell restarts a Process whose `running` still evaluates true the
# moment it exits, with no delay. Custom.qml now gates that restart behind a
# capped exponential backoff, and this test measures both halves of the
# contract:
#
#   1. a plugin that dies on arrival is respawned a BOUNDED number of times --
#      without the gate this is a fork loop at whatever rate the machine
#      manages, and twenty seconds of it is thousands of starts
#   2. a healthy plugin that crashes once is back within seconds, because a
#      crash after a healthy stretch resets the backoff
#
# Each plugin start appends one line to a log, so the assertion is a line
# count -- nothing here reads the screen.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "plugin-crashloop-test: not built -- meson setup build && meson compile -C build" >&2
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

CRASH_LOG="$WORK/crashy-starts.log"
HEALTHY_LOG="$WORK/healthy-starts.log"

cat > "$WORK/crashy" <<EOF
#!/bin/sh
date +%s.%N >> "$CRASH_LOG"
echo '{"text":"x"}'
exit 1
EOF

# NOT `exec sleep`: exec would replace the command line, and the kill below
# matches on the script's own unique path so it cannot reach anything else.
cat > "$WORK/healthy" <<EOF
#!/bin/sh
date +%s.%N >> "$HEALTHY_LOG"
echo '{"text":"ok"}'
while :; do sleep 1; done
EOF
chmod +x "$WORK/crashy" "$WORK/healthy"

# Multi-line custom blocks: the one-line `custom "x" { ... }` spelling is not
# in the parser's narrow subset (the one-line form matches bare group names
# only), and it is also not a form the shell's own writer ever produces.
bar_conf "custom/crashy,custom/healthy" "clock" "" <<EOF
$(bar_conf_panel)
custom "crashy" {
	exec "$WORK/crashy"
	continuous #true
}
custom "healthy" {
	exec "$WORK/healthy"
	continuous #true
}
EOF

setsid $(bar_limits) dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > $WORK/qs.log 2>&1 &
QS=$!

# 25 seconds of a plugin that dies on arrival. With the backoff (250ms
# doubling, capped) that is at most ~8 starts; without it, thousands.
sleep 25

CRASHES="$(wc -l < "$CRASH_LOG" 2>/dev/null || echo 0)"
if [ "$CRASHES" -ge 2 ] && [ "$CRASHES" -le 12 ]; then
	ok "a crash-looping plugin is retried, bounded ($CRASHES starts in 25s)"
else
	bad "a crash-looping plugin is retried, bounded ($CRASHES starts in 25s)"
fi

# The healthy plugin started exactly once in all that time.
HSTART="$(wc -l < "$HEALTHY_LOG" 2>/dev/null || echo 0)"
if [ "$HSTART" -eq 1 ]; then
	ok "a healthy plugin started once ($HSTART)"
else
	bad "a healthy plugin started once ($HSTART)"
fi

# Kill the healthy plugin once. Matched by its own unique path under $WORK --
# never by name -- so this cannot reach anything else on the machine.
pkill -f "$WORK/healthy" 2>/dev/null
sleep 8

HAFTER="$(wc -l < "$HEALTHY_LOG" 2>/dev/null || echo 0)"
if [ "$HAFTER" -ge 2 ]; then
	ok "a crashed healthy plugin is restarted within seconds ($HSTART -> $HAFTER starts)"
else
	bad "a crashed healthy plugin is restarted within seconds ($HSTART -> $HAFTER starts)"
fi

# And the shell itself never went down.
if kill -0 "$QS" 2>/dev/null; then
	ok "the shell survived all of it"
else
	bad "the shell survived all of it"
fi

# Teardown: the bar exits, and BOTH plugins' processes go with it.
bar_session_kill "$QS"
sleep 2
LEFT="$(pgrep -f "$WORK/crashy|$WORK/healthy" | wc -l)"
if [ "$LEFT" -eq 0 ]; then
	ok "no plugin processes outlive the bar"
else
	bad "no plugin processes outlive the bar ($LEFT left)"
	pkill -f "$WORK/crashy" 2>/dev/null
	pkill -f "$WORK/healthy" 2>/dev/null
fi

echo
echo "plugin-crashloop-test: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
