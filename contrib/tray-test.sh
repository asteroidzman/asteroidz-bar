#!/usr/bin/env bash
# tray-test.sh — does the tray show items, and do their menus open?
#
# On a PRIVATE session bus, which is the whole point. quickshell hosts
# StatusNotifierItem on whatever bus it finds, so a test run against the real
# one would pick up Steam and Discord and whatever else the desktop is running
# -- it would pass whether or not this code works, and its results would change
# depending on what was open at the time.
#
# The fake item is contrib/snitem: it registers a StatusNotifierItem with a
# known icon and, with --menu, a DBusMenu with known entries.
#
# It lives HERE, in the bar's own tree. It used to be the compositor's, back
# when the compositor drew the bar and hosted the tray -- and when that all
# moved out (asteroidz 1877e95, "remove the native bar"), snitem went with the
# rest of the deleted tray code while this line went on pointing at where it
# had been. Every run since has exited 1 before its first assertion, which in a
# loop over a dozen suites looks exactly like a suite that passed quietly. A
# test helper belongs with the thing it tests.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNITEM="$HERE/contrib/snitem/snitem"
# Still the compositor's, and only for the headless harness below -- that one
# genuinely is the compositor's, since it boots a compositor.
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"

PASS=0
FAIL=0

ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -x "$SNITEM" ] || {
	echo "tray-test: $SNITEM not built -- run: cd $HERE/contrib/snitem && make" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT

WORK="$HL_OUTDIR"

# How the bar looks is the bar's own setting now; a test writes it here.
# shellcheck disable=SC1091
. "$HERE/contrib/lib/barconf.sh"
BAR_CONF="$(bar_conf_path)"

# The C++ plugin the shell imports as `Asteroidz.Bar`, staged where quickshell
# will find it. Without this the shell does not merely lose the plugin -- it
# fails to LOAD, because Icon.qml imports the module and every type above it
# then goes unavailable, so nothing draws and every pixel assertion measures an
# empty screen. This test ran for months without it, back when it could not run
# at all (see the snitem note above); the one assertion that survived was
# "no QML errors", which passed against a shell that had never started.
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

# One private bus for the compositor-side test, shared by the item and the
# shell. dbus-run-session gives us a bus that dies with the script.
cat > "$WORK/run.sh" <<'INNER'
#!/usr/bin/env bash
set -u
# Positionals, not inherited. This heredoc is QUOTED, so nothing in it expands
# when the file is written -- a name used below and not passed in here is
# unbound at run time, and under `set -u` that kills the backgrounded child
# while the parent screenshots a bar-less screen and blames the feature.
WORK="$1"; SNITEM="$2"; HERE="$3"; SIG="$4"; WL="$5"; XRD="$6"; BAR_CONF="$7"
QMLROOT="$8"

# The SHELL first, then the item.
#
# There is no StatusNotifierWatcher on a fresh bus until a host provides one,
# and an item that registers before the watcher exists is simply not seen --
# nothing re-announces it. That is also the real-world order: the bar is up
# before the applications are, and adopting an item that appears later is the
# case that matters.
WAYLAND_DISPLAY="$WL" XDG_RUNTIME_DIR="$XRD" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS_PID=$!
sleep 4

# Is there a watcher at all? An SNI host has to provide
# org.kde.StatusNotifierWatcher; without it an item has nobody to register
# with and the tray is empty for reasons that have nothing to do with drawing.
busctl --user list 2>/dev/null | grep -q "org.kde.StatusNotifierWatcher" \
	&& echo "watcher: yes" > "$WORK/watcher" \
	|| echo "watcher: no" > "$WORK/watcher"

"$SNITEM" --register --menu --log "$WORK/snitem.log" &
SNI_PID=$!
sleep 3

WAYLAND_DISPLAY="$WL" XDG_RUNTIME_DIR="$XRD" grim "$WORK/tray.png" 2>/dev/null

kill $QS_PID $SNI_PID 2>/dev/null
wait 2>/dev/null
INNER
chmod +x "$WORK/run.sh"

# The bar config for this test: the tray and nothing else, so anything drawn in
# the right section IS the tray.
PRISTINE="$WORK/config.pristine.kdl"
cp "$HL_CONFIG" "$PRISTINE"
cp "$PRISTINE" "$HL_CONFIG"
cat >> "$HL_CONFIG" <<'EOF'
EOF
bar_conf "" "" "tray" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1

dbus-run-session -- "$WORK/run.sh" "$WORK" "$SNITEM" "$HERE" "$HL_SIG" \
	"$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR" "$BAR_CONF" "$QMLROOT"

if [ ! -f "$WORK/tray.png" ]; then
	bad "a screenshot was taken"
else
	# Two numbers, because one was not enough to be sure of anything.
	#
	# "Bright pixels in the right-hand strip" was the first attempt, and it
	# passed with the tray switched off: the wallpaper is mid-grey, which is
	# bright. So measure the PANEL -- a near-black slab that is only drawn when
	# the section has content at all -- and the icon's ink sitting on it.
	read -r PANEL ICON <<< "$(python3 - "$WORK/tray.png" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert('RGB')
w = im.size[0]

# The panel: a near-black slab, drawn only when the section has content.
panel = [x for x in range(w - 300, w)
         if sum(im.getpixel((x, 30))) < 120]
if not panel:
    print(0, 0)
    raise SystemExit

x0, x1 = min(panel), max(panel)
area = sum(1 for x in range(x0, x1 + 1) for y in range(10, 56)
           if sum(im.getpixel((x, y))) < 120)

# Artwork: anything inside the pill that is not the slab. Counting only
# NEAR-WHITE pixels was the second wrong answer -- the fixture's icon is a
# blue disc, so a correctly drawn tray reported 28px of "ink" and failed.
ink = sum(1 for x in range(x0 + 12, x1 - 11) for y in range(16, 50)
          if sum(im.getpixel((x, y))) > 200)

print(area, ink)
PY
)"

	if [ "${PANEL:-0}" -gt 500 ]; then
		ok "the tray section draws a panel ($PANEL px)"
	else
		bad "the tray section draws a panel (only ${PANEL:-0} px)"
	fi
	if [ "${ICON:-0}" -gt 50 ]; then
		ok "with the item's artwork on it ($ICON px)"
	else
		bad "with the item's artwork on it (only ${ICON:-0} px)"
	fi
fi

if [ "$(cat "$WORK/watcher" 2>/dev/null)" = "watcher: yes" ]; then
	ok "the shell provides a StatusNotifierWatcher"
else
	bad "the shell provides a StatusNotifierWatcher"
fi

# "Failed to load configuration" is in here for a reason. This used to look for
# ReferenceError only, which is a run-time fault -- so a shell that never
# reached run time reported no errors and this passed. It did exactly that for
# months: the plugin was not staged, Icon.qml's `import Asteroidz.Bar` failed,
# every type above it went unavailable, and the one assertion still standing
# said the tray was fine. An assertion about errors has to see the error that
# stops the program before it starts.
# "Invalid image provider" is in here because it happened. The optical icon
# provider was registered from QQmlExtensionPlugin::initializeEngine, which
# quickshell's engine never calls -- so every tray icon logged that line, drew
# unnormalised, and every assertion here passed. A warning that means "the
# artwork you asked for was not produced" is an error for a tray test.
_TRAY_ERRS="ReferenceError\|is not defined\|Failed to load configuration\|unavailable\|is not installed\|Invalid image provider"
if grep -q "$_TRAY_ERRS" "$WORK/qs.log" 2>/dev/null; then
	bad "no QML errors while hosting the tray"
	grep -m3 "$_TRAY_ERRS" "$WORK/qs.log" | sed 's/^/       /'
else
	ok "no QML errors while hosting the tray"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
