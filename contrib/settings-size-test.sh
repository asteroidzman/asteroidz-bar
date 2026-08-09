#!/usr/bin/env bash
# settings-size-test.sh — the settings window reopens at the size it was left.
#
# Resizing it and closing it used to throw the size away: every reopen came back
# at the font-derived default, so anyone who wanted it bigger dragged it bigger
# again, every time.
#
# Both halves are asserted, because either one alone passes against a broken
# build. A window that never saves still opens at whatever the cache happens to
# say; a window that saves but ignores the cache still writes a correct file.
#
#   1. open, resize, close      -> the cache holds the new size
#   2. reopen                   -> the window comes back at it
#
# The size is written to the CACHE, not the config: nobody edits it, nothing
# else reads it, and losing it costs one drag.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "settings-size-test: not built -- meson setup build && meson compile -C build" >&2
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
cp "$BAR_BUILD/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 12"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "tags" "" "clock" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1

# The cache lives under XDG_CACHE_HOME, which the sandbox does not redirect --
# it redirects XDG_CONFIG_HOME. Pointed at the run's own directory here so the
# test cannot read or write the developer's real one.
CACHE="$WORK/cache"
mkdir -p "$CACHE/asteroidz-bar"
SIZE_FILE="$CACHE/asteroidz-bar/settings-window.json"

start_bar() {
	setsid $(bar_limits) dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" \
		XDG_CACHE_HOME="$CACHE" GSETTINGS_BACKEND=memory \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		"$HERE/bin/asteroidz-bar" >> "$WORK/qs.log" 2>&1 &
	QS=$!
	sleep 9
}
start_bar

win_size() { # -> "W H", or "0 0" when the window is not up
	hl_get "get all-clients" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("clients", []):
    if c.get("title") == "asteroidz settings":
        print(c["width"], c["height"]); break
else:
    print(0, 0)
'
}

open_settings() { hl_move 38 33; sleep 1; hl_click 38 33; sleep 3; }

echo
echo "settings window size"

open_settings
read -r W0 H0 <<<"$(win_size)"
if [ "${W0:-0}" -gt 0 ]; then
	ok "the settings window opens (${W0}x${H0})"
else
	bad "the settings window opens"
	echo; echo "  $PASS passed, $((FAIL)) failed"; kill "$QS" 2>/dev/null; exit 1
fi

# Floated first. The window opens TILED -- it filled the output at 1900x983 --
# and resize_window only moves a floating one, so without this the resize is a
# no-op and the premise below stops the run.
hl_dispatch "toggle_floating" 2

# A size it would never pick on its own, so a pass cannot be the default
# happening to match.
NEW_W=$((W0 - 420))
NEW_H=$((H0 - 260))
hl_dispatch "resize_window,$NEW_W,$NEW_H" 2
read -r W1 H1 <<<"$(win_size)"
if [ "$W1" != "$W0" ] || [ "$H1" != "$H0" ]; then
	ok "...and can be resized (${W0}x${H0} -> ${W1}x${H1})"
else
	bad "...and can be resized (still ${W1}x${H1}) -- nothing below can fail"
	echo; echo "  $PASS passed, $((FAIL)) failed"; kill "$QS" 2>/dev/null; exit 1
fi

# Closed by the COMPOSITOR, which is how this window actually gets closed --
# it opens tiled with no titlebar, so you use whatever keybind closes windows.
#
# It is also the only close that proves anything. Quickshell does not destroy
# the window when it is merely hidden, so the object keeps its own size and the
# compositor keeps its geometry: a "reopen" after a hide comes back at the right
# size on a build that remembers nothing at all. Settings.open() destroys and
# rebuilds the window after a compositor close, which is the case the cache
# exists for.
hl_dispatch "killclient" 3

if [ -s "$SIZE_FILE" ]; then
	ok "closing it writes the size to the cache"
else
	bad "closing it writes the size to the cache (no $SIZE_FILE)"
fi
SAVED_W="$(python3 -c "
import json
try:
    print(json.load(open('$SIZE_FILE'))['width'])
except Exception:
    print(0)" 2>/dev/null)"
# Within a few pixels, not equal. The compositor reports the window's OUTER
# geometry and the shell saves what its own surface is -- 1476 against 1480 on
# this build. Demanding equality would be demanding that two different
# measurements of two different rectangles agree.
DIFF=$(( SAVED_W > W1 ? SAVED_W - W1 : W1 - SAVED_W ))
if [ "${SAVED_W:-0}" -gt 0 ] && [ "$DIFF" -le 8 ]; then
	ok "...and it is the size it was left at ($SAVED_W vs $W1 outer)"
else
	bad "...and it is the size it was left at (saved $SAVED_W, was $W1)"
fi

# And back -- after RESTARTING THE BAR.
#
# Stated plainly: this assertion does NOT discriminate, and it is kept anyway.
# It passes on a build with no cache at all, even across a bar restart, because
# the COMPOSITOR remembers a floating window's geometry and hands the same
# rectangle to the replacement. Reopening in the same process is weaker still --
# there quickshell had also kept the window object.
#
# So the two cache assertions above are the evidence for this feature (2 fail
# without it, 0 with it). This one is the end-to-end sanity check: whatever else
# is true, the window a person sees comes back the size they left it. Making it
# discriminate would mean measuring the size the shell REQUESTED rather than the
# one the compositor granted, which is not visible from out here.
kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null
sleep 2
start_bar

open_settings
read -r W2 H2 <<<"$(win_size)"
if [ "$W2" = "$W1" ] && [ "$H2" = "$H1" ]; then
	ok "reopening comes back at that size (${W2}x${H2})"
else
	bad "reopening comes back at that size (got ${W2}x${H2}, wanted ${W1}x${H1})"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
