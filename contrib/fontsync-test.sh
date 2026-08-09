#!/usr/bin/env bash
# fontsync-test.sh — a test bar must not rewrite the real desktop's font.
#
# This is a regression test for something that already shipped, ran, and was
# noticed only because a desktop looked different afterwards.
#
# The shell pushes the configured font out to GTK, Qt and gsettings when it
# starts. A bar launched by a test is a real bar and reaches that code like any
# other, and the fixtures in this directory declare fonts of their own --
# process-test.sh says `theme { font "Ubuntu 16" }`. The first version of
# FontSync wrote to a hard-coded $HOME/.config, so running the suite replaced
# the developer's actual font with the fixture's, in all five targets at once.
# No test failed. Nothing was logged. The desktop simply changed.
#
# So this asserts the property that was missing rather than the code that was
# wrong: after a full bar startup with a deliberately absurd font, the real
# files are byte-for-byte what they were.
#
# THE PREMISE IS ASSERTED FIRST, and that is not ceremony. Every assertion
# below passes trivially if the font is never pushed at all -- if the shell
# breaks, if the singleton stops being referenced, if apply() returns early.
# A green run has to mean "it wrote, and it wrote somewhere harmless", so the
# sandbox is checked for the fixture font before the real files are checked for
# the absence of it.
#
# This test restores the real files from a snapshot on the way out, in a trap,
# unconditionally. That is deliberate: the whole point is to be runnable
# against a BROKEN build, where the bar under test does damage the real
# settings, and a regression test that leaves the damage behind on failure is
# not one anybody will run twice.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "fontsync-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

REAL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
TARGETS="gtk-3.0/settings.ini gtk-4.0/settings.ini qt6ct/qt6ct.conf qt5ct/qt5ct.conf"

# A font no desktop is plausibly set to, so a stray match is a real match and
# not a coincidence. The family has a space in it on purpose -- the parser
# splits family from size at the LAST token, and a one-word family would not
# exercise that.
FIXTURE_FAMILY="DejaVu Serif"
FIXTURE="$FIXTURE_FAMILY 21"

# ---------------------------------------------------------------------------
# Snapshot the real settings BEFORE anything starts, and put them back on the
# way out no matter how this exits.
# ---------------------------------------------------------------------------
SNAP="$(mktemp -d)"
for t in $TARGETS; do
	[ -f "$REAL_CFG/$t" ] || continue
	mkdir -p "$SNAP/$(dirname "$t")"
	cp "$REAL_CFG/$t" "$SNAP/$t"
done
SNAP_GSETTINGS="$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null || echo)"

restore_real() {
	for t in $TARGETS; do
		[ -f "$SNAP/$t" ] || continue
		cp "$SNAP/$t" "$REAL_CFG/$t"
	done
	if [ -n "$SNAP_GSETTINGS" ]; then
		gsettings set org.gnome.desktop.interface font-name \
			"$(printf '%s' "$SNAP_GSETTINGS" | sed "s/^'//; s/'$//")" 2>/dev/null
	fi
	rm -rf "$SNAP"
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'restore_real; hl_stop' EXIT
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

cat >> "$HL_CONFIG" <<EOF
theme { font "$FIXTURE"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
bar_conf "" "" "clock" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1
sleep 1

setsid dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 8

echo
echo "fontsync"

# --- the premise ----------------------------------------------------------
# Without this, every assertion below is satisfied by a shell that crashed on
# startup.
if grep -q "gtk-font-name=$FIXTURE\$" "$BAR_XDG/gtk-3.0/settings.ini" 2>/dev/null; then
	ok "the font was actually pushed (sandbox got \"$FIXTURE\")"
else
	bad "the font was never pushed -- nothing below proves anything"
	echo "      sandbox gtk-3.0 says: $(grep gtk-font-name "$BAR_XDG/gtk-3.0/settings.ini" 2>/dev/null || echo '<no file>')"
fi

if grep -q "^general=\"$FIXTURE_FAMILY,21," "$BAR_XDG/qt6ct/qt6ct.conf" 2>/dev/null; then
	ok "the Qt half was pushed too (sandbox qt6ct at 21)"
else
	bad "sandbox qt6ct did not get the fixture font"
	echo "      sandbox qt6ct says: $(grep '^general=' "$BAR_XDG/qt6ct/qt6ct.conf" 2>/dev/null || echo '<no file>')"
fi

# --- the property ---------------------------------------------------------
for t in $TARGETS; do
	[ -f "$SNAP/$t" ] || continue
	if cmp -s "$SNAP/$t" "$REAL_CFG/$t"; then
		ok "the real $t is untouched"
	else
		bad "the real $t was MODIFIED by a test bar"
		diff "$SNAP/$t" "$REAL_CFG/$t" | head -6 | sed 's/^/      /'
	fi
done

NOW_GSETTINGS="$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null || echo)"
if [ "$NOW_GSETTINGS" = "$SNAP_GSETTINGS" ]; then
	ok "the real gsettings font-name is untouched"
else
	bad "the real gsettings font-name was MODIFIED by a test bar"
	echo "      was $SNAP_GSETTINGS, now $NOW_GSETTINGS"
fi

# The parse itself, checked against the sandbox rather than by calling into the
# plugin: "DejaVu Serif 21" must come apart as family "DejaVu Serif" and size
# 21, and a family that keeps its trailing number would show up here as
# gtk-font-name=DejaVu Serif 21 21.
if [ "$(grep -c 'gtk-font-name' "$BAR_XDG/gtk-3.0/settings.ini" 2>/dev/null || echo 0)" = "1" ]; then
	ok "one font line, not an appended duplicate"
else
	bad "expected exactly one gtk-font-name line in the sandbox"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
