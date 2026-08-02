#!/usr/bin/env bash
# look-test.sh — the three ways the bar's geometry went wrong, as assertions.
#
# All three were reported as one complaint ("the spacing is off"), and none of
# them are visible in the QML: they only exist once the thing is drawn. So this
# draws it, on a light wallpaper, and measures pixels.
#
#   1. A module with nothing to show costs nothing. Media hid itself but its
#      SLOT still measured 390px of transport controls, pinned title and
#      visualiser, so an idle centre panel drew three times wider than the
#      clock inside it.
#   2. A pinned pill keeps its icon. Three modules pinned themselves to their
#      LABEL's width and lost the icon's advance -- about 28px each. Content
#      overflows a pill rather than being clipped, so this showed up as the
#      next module having no space in front of it.
#   3. The panel has a shadow. It had none: MultiEffect was given a plain
#      Rectangle as its source, and a Rectangle is not a texture provider, so
#      it drew nothing at all.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

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

# The C++ module, laid out the way an import path expects. The launcher in
# bin/ is a TEMPLATE -- its @SHELLDIR@ is only substituted at install time --
# so running it from the tree means telling it where both halves live, or it
# looks for `Asteroidz.Bar` under a literal "@SHELLDIR@/qml" and the whole
# shell fails to load.
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/" 2>/dev/null || {
	echo "look-test: not built -- run: meson setup build && meson compile -C build" >&2
	exit 1
}
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

PRISTINE="$WORK/config.pristine.kdl"
cp "$HL_CONFIG" "$PRISTINE"

render() { # render <modules-center> <outfile>
	cp "$PRISTINE" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
	bar_conf "" "$1" "" <<EOF
$(bar_conf_panel)
idle { enable #true; dpms-timeout 600 }
EOF
	hl_dispatch "reload_config" 1
	sleep 1

	# On a PRIVATE bus, so "idle media" means what it says. The shell reads
	# MPRIS off whatever session bus it is given, and this test used to
	# inherit the user's -- where it passed only for as long as nobody
	# happened to be playing anything.
	setsid dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
	local pid=$!
	sleep 8
	grim -o "$HL_MON" "$2" 2>/dev/null
	bar_session_kill "$pid"
}

# There is no MPRIS player on this bus, so `media` is the idle case by
# construction -- nothing has to be arranged for it.
#
# `idle { enable true }` above is for the `idle` MODULE, which is the cup, and
# which hides itself when nothing in the session would ever idle -- a "keep
# awake" button in a session where the screen never sleeps is describing
# something that is not happening. Without it the scene below renders one pill
# where it means to render two, and measures a gap inside weather rather than
# the gap beside it: a pass or fail about nothing. Ten minutes so the timeout
# cannot fire during the eight seconds the bar is up.
render "clock" "$WORK/without.png"
render "media,clock" "$WORK/with.png"
render "weather,idle" "$WORK/pinned.png"

# ── 4. the ship ─────────────────────────────────────────────────────────────
#
# It has gone missing three times, and the last two were the same bug wearing
# different clothes: Logo.qml writes a recoloured copy of the SVG to
# XDG_RUNTIME_DIR and points the pill at it, and anything that lets the pill
# see that path before the bytes are on disk loses the artwork for the whole
# session. Image reports "Cannot open" ONCE, caches the failure against the
# URL, and never retries -- so a file that appears milliseconds later is never
# noticed. Nothing about it is visible in the QML, and it does not reproduce by
# reading the code, which is how it survived two fixes.
#
# There is no longer a `show-logo` option to turn off and compare against: the
# ship is how the settings window is opened, so a bar without it has no way
# into its own configuration and it is drawn unconditionally. That removes the
# old A/B reference, so the ship is measured where it actually IS -- the first
# pill of the tags panel, which it occupies with no horizontal padding. If the
# artwork fails to load the pill collapses and that leading strip is bare.
render_tags() { # render_tags <outfile> <logfile>
	cp "$PRISTINE" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
EOF
	bar_conf "" "tags" "" <<EOF
$(bar_conf_panel)
EOF
	hl_dispatch "reload_config" 1
	sleep 1
	setsid dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		"$HERE/bin/asteroidz-bar" > "$2" 2>&1 &
	local pid=$!
	sleep 8
	grim -o "$HL_MON" "$1" 2>/dev/null
	bar_session_kill "$pid"
}

render_tags "$WORK/logo-on.png" "$WORK/logo-on.log"

# The RE-generate, which is the one that actually broke. Starting up writes the
# copy before the pill has ever drawn; changing the palette rewrites it while
# the pill is on screen holding the previous one, and that is the moment the
# Image can be asked for a URL whose file is one statement away from existing.
# Both of the shots above pass against the broken build -- this is the case
# that fails -- so the accent is changed here with the bar RUNNING, exactly the
# way matugen changes it when the wallpaper does.
render_tags_recolour() { # render_tags_recolour <outfile> <logfile>
	cp "$PRISTINE" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 }
	focus-bg-color 0x2a6fd6ff }
EOF
	bar_conf "" "tags" "" <<EOF
$(bar_conf_panel)
EOF
	hl_dispatch "reload_config" 1
	sleep 1
	setsid dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		"$HERE/bin/asteroidz-bar" > "$2" 2>&1 &
	local pid=$!
	sleep 8

	# Three, because the failure is a race and one roll of it proves little.
	# Each is a different accent, so each forces a real rewrite.
	local c
	for c in 0xd62a6fff 0x2ad66fff 0xd6a52aff; do
		sed -i "s/focus-bg-color 0x[0-9a-f]*/focus-bg-color $c/" "$HL_CONFIG"
		hl_dispatch "reload_config" 0.5
		sleep 2
	done

	grim -o "$HL_MON" "$1" 2>/dev/null
	bar_session_kill "$pid"
}

render_tags_recolour "$WORK/logo-recolour.png" "$WORK/logo-recolour.log"

# ── 5. an urgent pill has to be READABLE ────────────────────────────────────
#
# `urgent` is the one palette entry with no partner. focus_bg has focus_fg from
# a Material pair; urgent is a single colour chosen to read against the BAR, so
# anything painting it as a BACKGROUND has to work out its own foreground. On
# this desktop matugen makes it a light salmon while the theme foreground is
# near-white, so a plugin pill going urgent drew white on pale pink at 1.15:1 --
# a reminder coming due announced itself illegibly. An icon tinted `urgent` on
# the same pill was worse still, 1.00:1, and plugins send both together because
# both mean "this is due".
#
# The theme here sets a LIGHT urgent deliberately. With the built-in red
# (luminance 0.48) the old code picks white and is perfectly readable, so a
# test on the default would pass against the bug.
cat > "$WORK/urgent-stub.py" <<'STUB'
import sys, time
while True:
    sys.stdout.write('{"text":"Due","icon":"asteroidz-bar/reminders.svg",'
                     '"class":"urgent","tint":"urgent"}\n')
    sys.stdout.flush()
    time.sleep(5)
STUB

render_urgent() { # render_urgent <outfile>
	cp "$PRISTINE" "$HL_CONFIG"
	cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 }
	urgent-color 0xffb4abff }
EOF
bar_conf "" "custom/due" "" <<EOF
$(bar_conf_panel)
custom "due" {
	exec "python3 $WORK/urgent-stub.py"
	continuous #true
}
idle { enable #true; dpms-timeout 600 }
EOF
	hl_dispatch "reload_config" 1
	sleep 1
	setsid dbus-run-session -- \
		env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		HOME="$HOME" PATH="$PATH" \
		ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
		ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
		ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
		ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
		ASTEROIDZ_BAR_QML="$QMLROOT" \
		"$HERE/bin/asteroidz-bar" > "$WORK/urgent.log" 2>&1 &
	local pid=$!
	sleep 8
	grim -o "$HL_MON" "$1" 2>/dev/null
	bar_session_kill "$pid"
}

render_urgent "$WORK/urgent.png"

if grep -q "Cannot open.*asteroidz-bar-logo" "$WORK/logo-recolour.log"; then
	bad "a palette change does not lose the ship ($(grep -m1 -o 'Cannot open.*' "$WORK/logo-recolour.log"))"
else
	ok "a palette change does not lose the ship"
fi

if grep -q "Cannot open.*asteroidz-bar-logo" "$WORK/logo-on.log"; then
	bad "the ship's recoloured copy was published before it was written ($(grep -m1 -o 'Cannot open.*' "$WORK/logo-on.log"))"
else
	ok "the ship's recoloured copy is written before anything looks at it"
fi

python3 - "$WORK" > "$WORK/verdicts" 2>&1 <<'PY'
import sys
from PIL import Image

work = sys.argv[1]
BG = None


def load(name):
    return Image.open(f"{work}/{name}").convert("RGB").load()


def panel_span(px, width, rows=range(14, 50)):
    """The run of columns belonging to the panel slab.

    A column counts when its DARKEST pixel is panel-dark, not when one
    sampled row is: sampling a single row through the middle cuts the panel
    into pieces wherever a glyph crosses it, and the panel then measures as
    a dozen 10px runs and is found as none.
    """
    runs, s = [], None
    for x in range(width):
        dark = min(sum(px[x, y]) for y in rows) < 300
        if dark and s is None:
            s = x
        elif not dark and s is not None:
            if x - s > 30:
                runs.append((s, x - 1))
            s = None
    return runs[0] if runs else None


im = Image.open(f"{work}/without.png")
W = im.size[0]

a = panel_span(load("without.png"), W)
b = panel_span(load("with.png"), W)
print(f"panel without media: {a}, with idle media: {b}")
if a and b and abs((b[1] - b[0]) - (a[1] - a[0])) <= 2:
    print("PASS an idle module costs no width")
else:
    print("FAIL an idle module costs no width")

# 2. pinned pills keep their icon: weather's temperature must not sit on top
#    of the idle glyph beside it. Measure the smallest gap between ink runs.
px = load("pinned.png")
span = panel_span(px, W)
rows = range(16, 50)
ink = []
s = None
for x in range(span[0], span[1] + 1):
    lit = max(sum(px[x, y]) for y in rows) > 330
    if lit and s is None:
        s = x
    elif not lit and s is not None:
        ink.append((s, x - 1))
        s = None
if s is not None:
    ink.append((s, span[1]))
merged = []
for s0, e0 in ink:
    if merged and s0 - merged[-1][1] <= 2:
        merged[-1] = (merged[-1][0], e0)
    else:
        merged.append((s0, e0))
# The widest gap inside the panel is the one between the two modules.
gaps = [merged[i][0] - merged[i - 1][1] - 1 for i in range(1, len(merged))]
biggest = max(gaps) if gaps else 0
print(f"module gap in 'weather,idle': {biggest}px (ink runs: {len(merged)})")
if biggest >= 8:
    print("PASS a pinned pill leaves room for its neighbour")
else:
    print("FAIL a pinned pill leaves room for its neighbour")

# 3. the shadow: above the panel's top edge, darker than the open wallpaper.
far = px[4, 4]
near = px[(span[0] + span[1]) // 2, 5]
print(f"above the panel: {near}, open wallpaper: {far}")
if sum(near) < sum(far) - 30:
    print("PASS the panel casts a shadow")
else:
    print("FAIL the panel casts a shadow")

# 4. the ship is PAINTED -- a presence check, not the race detector.
#
# Ink inside the panel, not the panel's width: a chip whose artwork failed to
# load still takes its width (the pill sizes from the bar height, not from
# whether the Image resolved), so width proves only that the chip was laid out.
#
# What this does NOT catch is the publish-before-write race itself. Measured
# against a build with that bug reintroduced, these two still pass: the Image
# holds the pixmap it already had, so the shot can look right in the very run
# whose log records the failure -- and the ship then disappears later, or on
# the next start, which is exactly why it took three attempts to pin down. The
# "Cannot open" assertions above are the detector; these say the artwork
# resolves and is drawn at all, which is a different way to lose it.
def panel_ink(name):
    im = Image.open(f"{work}/{name}")
    p = im.convert("RGB").load()
    span = panel_span(p, im.size[0])
    if not span:
        return None
    return sum(1 for y in range(14, 50) for x in range(span[0], span[1])
               if sum(p[x, y]) > 380)


# 5. the urgent pill: ink ON it, against its own background.
#
# The pill is the only thing on that bar and the only salmon-coloured region,
# so it finds itself: take the colour filling it, then count the pixels inside
# that differ from it by a lot. Text and an icon are hundreds; a pill drawn in
# one flat colour with invisible contents is single digits.
try:
    up = Image.open(f"{work}/urgent.png")
except OSError as e:
    print(f"FAIL the urgent pill was rendered at all ({e})")
    up = None
upx = up.convert("RGB").load() if up else None
uw, uh = up.size if up else (0, 0)
hits = [] if up is None else [
        (x, y) for y in range(10, min(uh, 70))
        for x in range(0, uw, 2)
        if upx[x, y][0] > 200 and 140 < upx[x, y][1] < 210
        and 130 < upx[x, y][2] < 200]
if up is None:
    pass
elif len(hits) < 200:
    print(f"FAIL the urgent pill is on screen (found {len(hits)} px of it)")
else:
    xs = [p[0] for p in hits]
    ys = [p[1] for p in hits]
    bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
    base = upx[(bx0 + bx1) // 2, by0 + 2]
    ink = sum(1 for y in range(by0, by1 + 1) for x in range(bx0, bx1 + 1)
              if abs(upx[x, y][0] - base[0]) + abs(upx[x, y][1] - base[1])
                 + abs(upx[x, y][2] - base[2]) > 150)
    print(f"urgent pill {bx1 - bx0}x{by1 - by0}px, contrasting pixels: {ink}")
    if ink > 150:
        print("PASS an urgent pill's text and icon are legible on it")
    else:
        print("FAIL an urgent pill's text and icon are legible on it")

# The ship occupies the FIRST pill of the tags panel, drawn with no horizontal
# padding of its own. So the leading strip of the panel is either artwork or
# nothing: if the SVG fails to load, the pill collapses and the tag chips start
# at the panel's edge instead.
#
# Measured on both shots, because the bug that keeps coming back is not "the
# ship never draws" -- it is "the ship stops drawing once the accent is
# rewritten", and only the second shot has been through three rewrites.
def ship_ink(name, width=46):
    im = Image.open(f"{work}/{name}")
    p = im.convert("RGB").load()
    span = panel_span(p, im.size[0])
    if not span:
        return None
    return sum(1 for y in range(14, 50) for x in range(span[0], span[0] + width)
               if sum(p[x, y]) > 380)

ship_first = ship_ink("logo-on.png")
ship_after = ship_ink("logo-recolour.png")
print(f"ship ink -- first draw: {ship_first}, after three recolours: {ship_after}")
if ship_first is None or ship_after is None:
    print("FAIL the tags panel was found in both shots")
else:
    # A wireframe triangle with a flame, at 1.25 scale in a 48px bar. Tens of
    # lit pixels, not hundreds -- it is an outline, not a filled glyph.
    if ship_first > 30:
        print("PASS the ship is painted in the tags panel")
    else:
        print("FAIL the ship is painted in the tags panel")
    if ship_after > 30:
        print("PASS the ship is still painted after a palette change")
    else:
        print("FAIL the ship is still painted after a palette change")
PY

# The measurements are printed by the python above; this turns them into the
# script's own tally, so a caller only has to look at the exit status.
while IFS= read -r line; do
	case "$line" in
	PASS*) ok "${line#PASS }" ;;
	FAIL*) bad "${line#FAIL }" ;;
	*) echo "  ..   $line" ;;
	esac
done < "$WORK/verdicts"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
