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

# How the bar looks is the bar's own setting now; a test writes it here.
# shellcheck disable=SC1091
. "$HERE/contrib/lib/barconf.sh"
BAR_CONF="$(bar_conf_path)"
# Nothing on the bar: this suite is about the wallpaper behind it.
bar_conf "" "" ""

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
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
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
	# The line names the outputs it drew on between the mode and the depth
	# ("presented fill on every output as SDR"), so this matches around that
	# rather than pinning the whole sentence.
	if grep -qE "presented fill .*as $want" "$WORK/hdr.log"; then
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

# ── 5: one wallpaper per monitor ────────────────────────────────────────────
#
# A second output, so "per monitor" is a claim that can be checked rather than
# asserted on a machine with one screen. The compositor can make one:
# `create_virtual_output` adds a headless output at runtime, which is the same
# thing as far as the shell is concerned as plugging a monitor in.
#
# Two colours, one each, and BOTH are read. A test that only looked at the
# overridden monitor would pass just as happily if the override had gone to
# every screen -- which is the mistake this feature is most likely to make.
SDR3="$WORK/sdr3.png"
magick -size 640x480 xc:'#22cc44' "$SDR3" 2>/dev/null

per_conf() { # per_conf <scope>
	printf 'folder=%s\nwallpaper=%s\nmode=fill\nwallpaper-scope=%s\nwallpaper.%s=%s\n' \
		"$WORK" "$SDR" "$1" "$SECOND" "$SDR3" > "$WORK/wallpaper.conf"
}

hl_dispatch "create_virtual_output" 1
sleep 2
MONS="$(hl_get "get all-monitors" | jq -r '.monitors[].name' | sort)"
SECOND="$(printf '%s\n' "$MONS" | grep -v "^$HL_MON\$" | head -1)"

if [ -n "$SECOND" ]; then
	ok "a second output exists to test against ($SECOND)"

	# run_shell writes its own single-wallpaper config, so the real one is
	# written after it starts -- which is also the path under test: the shell
	# watches the file and picks the change up.
	QS="$(run_shell "$SDR" "$WORK/two.log")"
	sleep 6
	per_conf "per-monitor"
	sleep 5
	grim -o "$HL_MON" "$WORK/mon1.png" 2>/dev/null
	grim -o "$SECOND" "$WORK/mon2.png" 2>/dev/null
	kill "$QS" 2>/dev/null
	wait "$QS" 2>/dev/null

	one="$(magick "$WORK/mon1.png" -crop "${HL_WIDTH}x400+0+400" +repage \
		-resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"
	two="$(magick "$WORK/mon2.png" -crop "300x300+10+300" +repage \
		-resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"

	case "$two" in
	22CC44*) ok "the overridden monitor shows its own wallpaper (#$two)" ;;
	*) bad "the overridden monitor shows its own wallpaper (got #$two, wanted 22CC44)" ;;
	esac
	# The premise. Without it, the assertion above passes just as well when the
	# override has been applied to every screen.
	case "$one" in
	2244CC*) ok "...and the other one still shows the shared wallpaper (#$one)" ;;
	*) bad "...and the other one still shows the shared wallpaper (got #$one, wanted 2244CC)" ;;
	esac

	# Scope is a switch, not a consequence of having overrides: back to "all"
	# and the override stops applying WITHOUT being deleted, which is what makes
	# it survive a docking cycle.
	QS="$(run_shell "$SDR" "$WORK/all.log")"
	sleep 6
	per_conf "all"
	sleep 5
	grim -o "$SECOND" "$WORK/mon2all.png" 2>/dev/null
	kill "$QS" 2>/dev/null
	wait "$QS" 2>/dev/null

	twoall="$(magick "$WORK/mon2all.png" -crop "300x300+10+300" +repage \
		-resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"
	case "$twoall" in
	2244CC*) ok "...'one for all' puts the shared wallpaper back everywhere" ;;
	*) bad "...'one for all' puts the shared wallpaper back everywhere (got #$twoall, wanted 2244CC)" ;;
	esac
	if grep -q "^wallpaper\.$SECOND=" "$WORK/wallpaper.conf"; then
		ok "...without deleting the remembered per-monitor setting"
	else
		bad "...without deleting the remembered per-monitor setting"
	fi

	# ── the shared wallpaper must not touch an overridden monitor ───────────
	#
	# Changing the SHARED wallpaper used to draw it onto every output first,
	# including the ones with an image of their own, which then reverted a
	# decode later. Reported as "DP-1 changes briefly then goes back".
	#
	# Asserted on the COUNT the library logs, not by screenshotting for the
	# flash. A 64x64 fixture decodes in under a millisecond, so the wrong
	# behaviour is invisible to any sampling this test could do -- it is only
	# visible in real life because the override there is a 6016x6016 HEIC.
	# A screenshot version of this passed against the unfixed build.
	per_conf "per-monitor"
	QS="$(run_shell "$SDR" "$WORK/keep.log")"
	sleep 6
	per_conf "per-monitor"
	sleep 6
	kill "$QS" 2>/dev/null
	wait "$QS" 2>/dev/null

	# Two outputs exist and one is overridden, so the shared image belongs on
	# exactly one of them.
	if grep -q "on the shared set (1 output)" "$WORK/keep.log"; then
		ok "the shared wallpaper skips the monitor that has its own"
	else
		bad "the shared wallpaper skips the monitor that has its own"
		grep "presented" "$WORK/keep.log" | tail -3 | sed 's/^/       /'
	fi
	# The premise: there really were two outputs to choose between, so "1" is
	# a skip and not simply a single-monitor session.
	if [ "$(printf '%s\n' "$MONS" | grep -c .)" -ge 2 ]; then
		ok "...with two outputs present, so that 1 is a skip"
	else
		bad "...with two outputs present, so that 1 is a skip"
	fi

else
	bad "a second output exists to test against (monitors: $(printf '%s' "$MONS" | tr '\n' ' '))"
fi

# ── 6: cycling, which used to be two shell scripts ──────────────────────────
#
# `wallpaper-cycle-daemon.sh` slept for the interval and `cycle-wallpaper.sh`
# advanced the file; both read this same config and wrote the same key. The
# shell does it now, off a folder listing it already maintains.
#
# Driven through the IPC handler rather than by waiting out a timer: the
# question is whether advancing works and honours `order`, and a test that
# sleeps for a cycle interval to find out is a test nobody runs.
CYCDIR="$WORK/cyc"
mkdir -p "$CYCDIR"
magick -size 64x64 xc:'#111111' "$CYCDIR/a.png" 2>/dev/null
magick -size 64x64 xc:'#222222' "$CYCDIR/b.png" 2>/dev/null
magick -size 64x64 xc:'#333333' "$CYCDIR/c.png" 2>/dev/null

cyc_conf() { # cyc_conf <order> <current>
	printf 'folder=%s\nwallpaper=%s\nmode=fill\norder=%s\ninterval=0\nretheme=0\n' \
		"$CYCDIR" "$2" "$1" > "$WORK/wallpaper.conf"
}

QS="$(run_shell "$CYCDIR/a.png" "$WORK/cycle.log")"
sleep 6
cyc_conf sequential "$CYCDIR/a.png"
sleep 3

qs_ipc() {
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		quickshell -p "$HERE/shell/shell.qml" ipc call wallpaper "$@" 2>/dev/null
}

got="$(qs_ipc next)"
if [ "$got" = "$CYCDIR/b.png" ]; then
	ok "sequential advances to the next file in the folder"
else
	bad "sequential advances to the next file in the folder (got '$got')"
fi
got="$(qs_ipc next)"
if [ "$got" = "$CYCDIR/c.png" ]; then
	ok "...and again to the one after that"
else
	bad "...and again to the one after that (got '$got')"
fi
# Wraps rather than stopping at the end, which is the whole point of a cycle.
got="$(qs_ipc next)"
if [ "$got" = "$CYCDIR/a.png" ]; then
	ok "...and wraps back to the first"
else
	bad "...and wraps back to the first (got '$got')"
fi

# ── cycling with every screen overridden ────────────────────────────────────
#
# The case the cycle timer did nothing in, and it is the normal one: set each
# screen's wallpaper from the settings page and BOTH monitors have an override,
# so the shared wallpaper is on no screen at all. `advance()` moved only that
# one, so the timer fired on schedule for a whole hour and changed nothing
# anybody could see.
#
# Driven through `next`, which is the function the timer calls -- see the note
# above about not waiting out an interval to find out.
if [ -n "$SECOND" ]; then
	printf 'folder=%s\nwallpaper=%s\nmode=fill\nwallpaper-scope=per-monitor\nwallpaper.%s=%s\nwallpaper.%s=%s\norder=sequential\ninterval=0\nretheme=0\n' \
		"$CYCDIR" "$CYCDIR/a.png" \
		"$HL_MON" "$CYCDIR/a.png" \
		"$SECOND" "$CYCDIR/b.png" > "$WORK/wallpaper.conf"
	sleep 3
	qs_ipc next >/dev/null
	sleep 2

	got1="$(grep "^wallpaper\.$HL_MON=" "$WORK/wallpaper.conf" | cut -d= -f2-)"
	got2="$(grep "^wallpaper\.$SECOND=" "$WORK/wallpaper.conf" | cut -d= -f2-)"
	shared="$(grep '^wallpaper=' "$WORK/wallpaper.conf" | cut -d= -f2-)"

	if [ "$got1" = "$CYCDIR/b.png" ] && [ "$got2" = "$CYCDIR/c.png" ]; then
		ok "cycling advances every overridden screen, not just the shared one"
	else
		bad "cycling advances every overridden screen (got '$got1' and '$got2')"
	fi

	# And leaves the shared one alone, because nothing is showing it. Moving it
	# would re-theme the desktop from a picture on no screen -- apply()
	# re-themes on any shared change -- and burn a matugen run per tick.
	if [ "$shared" = "$CYCDIR/a.png" ]; then
		ok "...and leaves the shared wallpaper alone when no screen shows it"
	else
		bad "...and leaves the shared wallpaper alone when no screen shows it (got '$shared')"
	fi
else
	echo "  ..   skipped the overridden-cycle case: no second output"
fi

# ── nextFocused: the one a keybind can actually use ─────────────────────────
#
# A key press has no idea which screen you are looking at, and the compositor
# cannot tell it: the bind spawns a command line, and by the time that runs it
# is a separate process with no notion of focus. So `next` was the only thing a
# bind could call -- and in per-monitor scope `next` changes the SHARED
# wallpaper, which is deliberately not drawn on a monitor that has its own.
# Pressing the key with a per-monitor override on the focused screen therefore
# did nothing at all, correctly and uselessly.
#
# In "one for all" scope it has to fall back to `next`, or the bind stops
# working the moment the scope changes.
got="$(qs_ipc nextFocused)"
if [ -n "$got" ] && [ "${got#/}" != "$got" ]; then
	ok "nextFocused answers with a file in one-for-all scope ($(basename "$got"))"
else
	bad "nextFocused answers with a file in one-for-all scope (got '$got')"
fi

# Random must not pick the one already showing -- a rotation that repeats the
# current wallpaper looks like it has stopped working.
cyc_conf random "$CYCDIR/a.png"
sleep 2
same=0
for _ in 1 2 3 4 5 6; do
	before="$(qs_ipc current)"
	after="$(qs_ipc next)"
	[ "$before" = "$after" ] && same=$((same + 1))
done
if [ "$same" = 0 ]; then
	ok "random never picks the wallpaper already up (6 draws)"
else
	bad "random never picks the wallpaper already up ($same of 6 repeated)"
fi

# static is the third setting, and it means the TIMER never fires -- not that
# the wallpaper can never change. An explicit "next" still acts.
cyc_conf static "$CYCDIR/a.png"
sleep 2
if grep -q "^order=static" "$WORK/wallpaper.conf"; then
	ok "static is written and read back as an order"
else
	bad "static is written and read back as an order"
fi

# And it advances IN SEQUENCE, not at random. Static is the mode someone picks
# because they do not want the wallpaper moving on its own; answering a
# deliberate keypress with a random jump is the opposite of that. It used to,
# because pick() treated everything that was not "sequential" as random.
got="$(qs_ipc next)"
if [ "$got" = "$CYCDIR/b.png" ]; then
	ok "...and an explicit next still advances, in sequence"
else
	bad "...and an explicit next still advances, in sequence (got '$(basename "$got")', wanted b.png)"
fi
got="$(qs_ipc next)"
if [ "$got" = "$CYCDIR/c.png" ]; then
	ok "...and again, so it is a sequence and not one step"
else
	bad "...and again, so it is a sequence and not one step (got '$(basename "$got")')"
fi

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

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
