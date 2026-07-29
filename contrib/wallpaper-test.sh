#!/usr/bin/env bash
# wallpaper-test.sh — does the SHELL draw the wallpaper?
#
# The question this answers is not "is there a wallpaper on screen" but "did
# this process put it there". Nothing here starts a wallpaper program, and the
# test fails if one appears: the whole point of the C++ module is that the bar
# and the wallpaper are one process on one connection.
#
# Three things are checked, in the order they can break:
#
#   1. the module loads at all         (a plugin that fails to dlopen takes
#                                       the entire shell down with it, which
#                                       is how `undefined symbol:
#                                       xdg_popup_interface` was found)
#   2. an ordinary image reaches the screen
#   3. an HDR image takes the HDR decoder, and the 10-bit path is chosen if
#      and only if the compositor says it can represent it
#
# Point 3 is why this test synthesises its own AVIF rather than looking for
# one: an HDR wallpaper is not something a machine reliably has lying about,
# and a test that skips itself when it cannot find its input is a test that
# passes for the wrong reason.
#
# WHAT IS STILL NOT COVERED, and cannot be from here: the wp_color_manager_v1
# TAGGING itself. A headless output is not HDR-capable, so the compositor never
# advertises BT.2020/PQ, cm_can_represent() is false, and the branch that builds
# an image description and puts it on the surface is never entered -- which is
# exactly where two protocol bugs lived unnoticed (the description was set
# before it was ready, and the colour-management surface was destroyed straight
# after setting it, which "does the same as unset_image_description" and threw
# the tag away). "presented as SDR" below is the honest answer for this
# compositor, not evidence that the HDR path works. Verifying that needs a real
# HDR-capable output.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "wallpaper-test: not built -- run: meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

# What is already running, so the "no wallpaper process" check cannot blame
# this test for the user's own session.
BEFORE="$(pgrep -x asteroidzbg 2>/dev/null | sort)"

hl_start
trap 'hl_stop' EXIT

WORK="$HL_OUTDIR"

# The module, laid out the way an import path expects.
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

# ── inputs ───────────────────────────────────────────────────────────────────

# A flat colour, so "did it reach the screen" is one histogram away.
SDR="$WORK/sdr.png"
magick -size 640x480 xc:'#2244cc' "$SDR" 2>/dev/null

# A real HDR10 file: BT.2020 primaries, PQ transfer, 10 bits (CICP 9/16/9).
# avifenc rather than ffmpeg -- ffmpeg's AVIF muxer drops the CICP tags, and
# an untagged file takes the SDR path, which would make this test agree with
# a broken build.
HDR="$WORK/hdr.avif"
HAVE_HDR=0
if command -v avifenc >/dev/null 2>&1; then
	magick -size 640x480 gradient:'#ffffff-#101010' "$WORK/grad.png" 2>/dev/null
	avifenc --cicp 9/16/9 -d 10 -y 420 --speed 8 "$WORK/grad.png" "$HDR" \
		>/dev/null 2>&1 && HAVE_HDR=1
fi

run_shell() { # run_shell <image> <logfile>
	local image="$1" log="$2"
	local conf="$WORK/wallpaper.conf"
	printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$(dirname "$image")" "$image" > "$conf"

	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		QT_QPA_PLATFORM=wayland QT_FONT_DPI=96 \
		QML2_IMPORT_PATH="$QMLROOT" QML_IMPORT_PATH="$QMLROOT" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$conf" \
		ASTEROIDZ_BAR_BG_DEBUG=1 \
		quickshell -p "$HERE/shell/shell.qml" > "$log" 2>&1 &
	echo $!
}

# The harness puts up a grey swaybg wallpaper of its own; that is exactly what
# is under test, so it goes. By recorded PID -- never by name.
kill "$HL_SWAYBG_PID" 2>/dev/null
sleep 0.3

# ── 1 + 2: the module loads, and an SDR image reaches the screen ─────────────

QS="$(run_shell "$SDR" "$WORK/sdr.log")"
sleep 8
grim -o "$HL_MON" "$WORK/sdr.png.shot" 2>/dev/null
kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

if grep -q "Failed to load configuration" "$WORK/sdr.log"; then
	bad "the shell loads with the module on its import path"
	sed -n '1,12p' "$WORK/sdr.log"
else
	ok "the shell loads with the module on its import path"
fi

# The bar occupies the top ~70px; sample well below it.
if [ -f "$WORK/sdr.png.shot" ]; then
	got="$(magick "$WORK/sdr.png.shot" -crop "${HL_WIDTH}x400+0+400" +repage \
		-resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"
	case "$got" in
	2244CC*) ok "the wallpaper is on screen (#$got)" ;;
	*) bad "the wallpaper is on screen (got #$got, wanted 2244CC)" ;;
	esac
else
	bad "the wallpaper is on screen (no screenshot)"
fi

# ── 3: the HDR decoder, and the 10-bit decision ──────────────────────────────

if [ "$HAVE_HDR" = 1 ]; then
	QS="$(run_shell "$HDR" "$WORK/hdr.log")"
	sleep 8
	kill "$QS" 2>/dev/null
	wait "$QS" 2>/dev/null

	if grep -q "HDR AVIF (PQ, BT.2020)" "$WORK/hdr.log"; then
		ok "an HDR10 AVIF takes the HDR decoder"
	else
		bad "an HDR10 AVIF takes the HDR decoder"
	fi

	# What the compositor said it can accept decides which of these is
	# correct -- the fallback is not a failure, it is the required
	# behaviour when BT.2020/PQ are not advertised. Asserting one outcome
	# unconditionally would fail on every SDR-only compositor.
	if grep -q "BT.2020=1 PQ=1" "$WORK/hdr.log"; then
		want="HDR10"
	else
		want="SDR"
	fi
	if grep -q "presented fill as $want" "$WORK/hdr.log"; then
		ok "presented as $want, which is what this compositor advertises"
	else
		bad "presented as $want, which is what this compositor advertises"
		grep "presented\|wp-color-management" "$WORK/hdr.log" | head -4
	fi
else
	echo "  skip avifenc not installed -- the HDR path is not covered"
fi

# ── 4: changing it changes it ───────────────────────────────────────────────
#
# The shell watches wallpaper.conf, and everything that sets a wallpaper on
# this desktop -- the cycle daemon, the hotkey, the settings panel -- does it
# by writing that file. So "does a new value reach the screen" is the whole
# contract, and it is the one that broke: the settings panel wrote the file
# correctly and the picture never changed.

SDR2="$WORK/sdr2.png"
magick -size 640x480 xc:'#cc7722' "$SDR2" 2>/dev/null

QS="$(run_shell "$SDR" "$WORK/change.log")"
sleep 8
grim -o "$HL_MON" "$WORK/before.png" 2>/dev/null

# Rewritten under the running shell, exactly as the cycle daemon does it.
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$(dirname "$SDR2")" "$SDR2" \
	> "$WORK/wallpaper.conf"
sleep 4
grim -o "$HL_MON" "$WORK/after.png" 2>/dev/null

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

got_before="$(magick "$WORK/before.png" -crop "${HL_WIDTH}x400+0+400" +repage \
	-resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"
got_after="$(magick "$WORK/after.png" -crop "${HL_WIDTH}x400+0+400" +repage \
	-resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"
case "$got_before/$got_after" in
2244CC*/CC7722*) ok "a new wallpaper in the config reaches the screen" ;;
*) bad "a new wallpaper in the config reaches the screen (#$got_before -> #$got_after, wanted 2244CC -> CC7722)" ;;
esac

# ── and nothing was spawned to do it ─────────────────────────────────────────

NOW="$(pgrep -x asteroidzbg 2>/dev/null | sort)"
NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$NOW"))"
if [ -z "$NEW" ]; then
	ok "no wallpaper process was started"
else
	bad "no wallpaper process was started (appeared: $NEW)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
