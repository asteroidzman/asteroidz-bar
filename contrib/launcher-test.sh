#!/usr/bin/env bash
# launcher-test.sh — the launcher that replaced `rofi -show drun` / `-show run`.
#
# What the binds did, and therefore what this has to do:
#
#   Super+D, Super+space   rofi -show drun    desktop entries, with icons
#   Alt+space              rofi -show run     executables on PATH
#
# The assertions are about the two things a launcher is: it appears with the
# keyboard, and typing narrows it to the thing you meant. The second is the one
# worth testing, because "it opens" is obvious the first time anyone presses the
# bind and "dis matches Discord before Disk Usage Analyzer" is not obvious ever
# -- it is the difference between a launcher and a list, and it is invisible
# until the day it puts the wrong row first.
#
# The ranking is asserted through `ipc call launcher match`, which runs the same
# function the on-screen list is built from. Reading the order back off a
# screenshot was the first plan and it cannot work: the assertion is about
# WHICH NAME is first, and a picture of a list does not give names back.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "launcher-test: not built -- meson setup build && meson compile -C build" >&2
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

echo
echo "launcher"

# Desktop entries of our own, in the sandboxed XDG_DATA_HOME, so the test is
# not a test of whatever happens to be installed on the machine running it.
#
# The names are chosen so that ALPHABETICAL and CORRECT disagree, which is the
# only way this can catch a launcher that filters without ranking. For `man`,
# "Archive Manager" sorts first and "Manuals" is the one that starts with what
# was typed.
#
# "Discord" and "Disk Usage Analyzer" were the first pair here and they prove
# nothing: "Discord" is alphabetically first as well, so the test passed
# against a build whose ranking had been deliberately replaced by a plain
# substring filter. They are kept below only as extra population.
APPS="$BAR_XDG/../data/applications"
mkdir -p "$APPS"
mk_entry() { # mk_entry <file> <Name> <Exec> [NoDisplay]
	cat > "$APPS/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Icon=utilities-terminal
Comment=test entry
${4:+NoDisplay=true}
EOF
}
mk_entry manuals "Manuals" "true"
mk_entry archive-manager "Archive Manager" "true"
mk_entry discord "Discord" "true"
mk_entry disk-usage "Disk Usage Analyzer" "true"
mk_entry firefox "Firefox" "true"
mk_entry hidden-thing "Hidden Thing" "true" nodisplay

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#202020' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# Scale 1.5, deliberately. Icon artwork rasterised at the LOGICAL size and then
# multiplied by the output scale is soft, and at scale 1 there is no
# multiplication to expose it -- the icons were blurred on a real 1.5 display
# while every test here passed.
cat >> "$HL_CONFIG" <<EOF
animations 0
output $HL_MON { width ${HL_WIDTH}; height ${HL_HEIGHT}; refresh 60; x 0; y 0; scale 1.5 }
theme { font "Ubuntu 12"; border-width 0 }
EOF
bar_conf "tags" "" "clock" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1

setsid $(bar_limits) dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	XDG_DATA_HOME="$BAR_XDG/../data" \
	XDG_CACHE_HOME="$WORK/cache" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 9

if grep -qE 'is not a type|unavailable|Cannot override|set multiple times' "$WORK/qs.log"; then
	bad "the shell loads with no QML errors"
	grep -E 'is not a type|unavailable|Cannot override|set multiple times' "$WORK/qs.log" \
		| head -5 | sed 's/^/      /'
	echo; echo "  $PASS passed, $FAIL failed"; kill "$QS" 2>/dev/null; exit 1
fi
ok "the shell loads with no QML errors"

qsipc() { timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call launcher "$@" 2>&1; }

# The launcher is a layer surface, so it is not in the client list and the
# compositor cannot be asked about it. What can be asked is the screen.
ink_rows() { # ink_rows <shot> -> rows containing panel-bright pixels
	python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
W, H = im.size
rows = 0
for y in range(0, H, 2):
    lit = 0
    for x in range(0, W, 4):
        r, g, b = px[x, y]
        if abs(r - 32) > 14 or abs(g - 32) > 14 or abs(b - 32) > 14:
            lit += 1
    if lit > W // 40:
        rows += 1
print(rows)
PY
}

grim "$WORK/closed.png" 2>/dev/null
CLOSED="$(ink_rows "$WORK/closed.png")"

qsipc drun >/dev/null
sleep 2
grim "$WORK/drun.png" 2>/dev/null
OPENED="$(ink_rows "$WORK/drun.png")"

if [ "$OPENED" -gt $((CLOSED + 40)) ]; then
	ok "ipc call launcher drun puts it on screen ($CLOSED -> $OPENED lit rows)"
else
	bad "ipc call launcher drun puts it on screen ($CLOSED -> $OPENED lit rows)"
	echo; echo "  $PASS passed, $FAIL failed"; kill "$QS" 2>/dev/null; exit 1
fi

if [ "$(qsipc toggle drun)" = "hidden" ]; then
	ok "...and toggling the same mode closes it"
else
	bad "...and toggling the same mode closes it"
fi
sleep 1
CLOSED_AGAIN="$(ink_rows "$(grim "$WORK/closed2.png" 2>/dev/null; echo "$WORK/closed2.png")")"
if [ "$CLOSED_AGAIN" -le $((CLOSED + 40)) ]; then
	ok "...and it really is gone from the screen ($CLOSED_AGAIN lit rows)"
else
	bad "...and it really is gone from the screen ($CLOSED_AGAIN lit rows, was $CLOSED closed)"
fi

# ── the ranking ─────────────────────────────────────────────────────────────
#
# `match` answers what the list would show, best first, without opening
# anything. It is the same function the list is built from, which is the point:
# a test that re-implemented the ranking would assert its own copy.
first_for() { qsipc match "$1" | head -1; }

qsipc drun >/dev/null
sleep 1

# The premise: the entries this test wrote are the ones being ranked. Without
# it, an empty pool ranks nothing and every ordering assertion below is
# vacuously true.
ALL="$(qsipc match "")"
if printf '%s' "$ALL" | grep -q "Discord" && printf '%s' "$ALL" | grep -q "Disk Usage Analyzer"; then
	ok "the sandbox's own desktop entries are what is being ranked"
else
	bad "the sandbox's own desktop entries are what is being ranked (got: $(printf '%s' "$ALL" | tr '\n' ' '))"
	echo; echo "  $PASS passed, $FAIL failed"; kill "$QS" 2>/dev/null; exit 1
fi

# NoDisplay entries are not applications a person can pick. rofi hides them and
# so must this, or every hidden .desktop on the machine turns up in the list.
if printf '%s' "$ALL" | grep -q "Hidden Thing"; then
	bad "a NoDisplay entry is hidden"
else
	ok "a NoDisplay entry is hidden"
fi

# The one that matters, and the only pair here that can fail: a plain filter
# sorts these alphabetically and answers "Archive Manager".
GOT="$(first_for man)"
if [ "$GOT" = "Manuals" ]; then
	ok "'man' ranks the name that STARTS with it first ('$GOT')"
else
	bad "'man' ranks the name that STARTS with it first (got '$GOT' -- ranking is not being applied)"
fi

# ...and the one that starts with it at a word boundary still beats anything
# that merely contains it, so the middle of a multi-word name is reachable
# without typing the whole thing.
SECOND="$(qsipc match man | sed -n 2p)"
if [ "$SECOND" = "Archive Manager" ]; then
	ok "...with the word-boundary match second ('$SECOND')"
else
	bad "...with the word-boundary match second (got '$SECOND')"
fi

GOT="$(first_for usage)"
if [ "$GOT" = "Disk Usage Analyzer" ]; then
	ok "'usage' finds it by its second word ('$GOT')"
else
	bad "'usage' finds it by its second word (got '$GOT')"
fi

GOT="$(first_for fire)"
if [ "$GOT" = "Firefox" ]; then
	ok "'fire' finds Firefox"
else
	bad "'fire' finds Firefox (got '$GOT')"
fi

# Not "returns nothing" any more. A query matching no application is still a
# command somebody might mean to run, so it comes back as exactly one entry:
# itself.
NOMATCH="$(qsipc match zzzznotathing)"
if [ "$NOMATCH" = "zzzznotathing" ]; then
	ok "a query that matches no application is offered as a command"
else
	bad "a query that matches no application is offered as a command (got '$NOMATCH')"
fi

# The gap the pool cannot express: PATH and desktop entries are lists of NAMES,
# so a command with arguments matches nothing at all and used to be unrunnable.
ARGS="$(qsipc match "grim -o HEADLESS-1 /tmp/x.png")"
if [ "$ARGS" = "grim -o HEADLESS-1 /tmp/x.png" ]; then
	ok "...and so is a command with arguments"
else
	bad "...and so is a command with arguments (got '$ARGS')"
fi

# It must never be FIRST. One keystroke separates `man` from a command called
# `man`, and if the free-form entry outranked the application then Enter would
# run a shell command instead of launching what was matched.
if [ "$(first_for man)" = "Manuals" ] && qsipc match man | tail -1 | grep -qx "man"; then
	ok "...and it sorts last, never ahead of a matched application"
else
	bad "...and it sorts last, never ahead of a matched application"
fi

# ── run mode ────────────────────────────────────────────────────────────────
#
# A different pool entirely: PATH, not desktop entries. `sh` is on every PATH
# this can run on, and it is short enough that a substring rule would drown it.
qsipc run >/dev/null
sleep 3
RUN_ALL="$(qsipc match "")"
if [ -n "$RUN_ALL" ]; then
	ok "run mode offers what is on PATH ($(printf '%s' "$RUN_ALL" | wc -l) entries)"
else
	bad "run mode offers what is on PATH (nothing)"
fi
GOT="$(first_for grim)"
if [ "$GOT" = "grim" ]; then
	ok "...and 'grim' ranks the binary of that name first"
else
	bad "...and 'grim' ranks the binary of that name first (got '$GOT')"
fi
if printf '%s' "$RUN_ALL" | grep -qx "Discord"; then
	bad "run mode does not leak desktop entries into the list"
else
	ok "run mode does not leak desktop entries into the list"
fi

# ── the icons ───────────────────────────────────────────────────────────────────────────
#
# Sharpness, measured as edge energy over the icon column. A blurred icon is
# still an icon -- it draws, it is the right size, it is in the right place --
# so nothing about its PRESENCE can catch this. What changes is the gradient:
# rasterised at the box and scaled up by 1.5 it measured 12.8; drawn through
# the shell's own Icon component, which asks for twice the box in both
# dimensions, it measures 17.2.
qsipc drun >/dev/null
sleep 3
grim "$WORK/icons.png" 2>/dev/null

read -r ICON_EDGES ICON_INK <<<"$(python3 - "$WORK/icons.png" <<'MEASURE'
import sys
from PIL import Image, ImageFilter, ImageStat
im = Image.open(sys.argv[1]).convert("L")
W, H = im.size
# The icon column: just inside the panel's left edge, over the rows.
# The icon column, at the panel's NEW geometry: it is 34% of the screen wide
# now rather than 50%, so the old box at 26-30% sampled bare wallpaper and
# reported, correctly, that nothing was drawn there.
crop = im.crop((int(W * 0.335), int(H * 0.21), int(W * 0.365), int(H * 0.45)))
print("%.2f %.2f" % (ImageStat.Stat(crop.filter(ImageFilter.FIND_EDGES)).mean[0],
                     ImageStat.Stat(crop).stddev[0]))
MEASURE
)"

# The premise: there is artwork in that column at all. A column of flat panel
# background has almost no edge energy AND almost no spread, so it would sail
# under any sharpness threshold from below rather than failing.
if python3 -c "import sys; sys.exit(0 if $ICON_INK > 12 else 1)"; then
	ok "there are icons in the icon column (spread $ICON_INK)"
else
	bad "there are icons in the icon column (spread $ICON_INK -- nothing is drawn there)"
fi
if python3 -c "import sys; sys.exit(0 if $ICON_EDGES > 15 else 1)"; then
	ok "...and they are sharp at scale 1.5 (edge energy $ICON_EDGES)"
else
	bad "...and they are sharp at scale 1.5 (edge energy $ICON_EDGES -- rasterised at the box and upscaled)"
fi
# ── the screen dims behind it ───────────────────────────────────────────────
#
# Measured OUTSIDE the panel, on the desktop the launcher is covering. Two
# claims, and the second is the one that stops this being a black rectangle:
# the desktop must get darker, and it must still be there.
# Over a TEXTURED wallpaper. "It dims without blacking the desktop out" is a
# claim about detail surviving, and a flat field has no detail to survive --
# measured over the plain one, both spreads were 0.00 and the check could
# neither pass nor mean anything.
magick -size 64x64 xc:'#000000' -fill '#ffffff' \
	-draw 'rectangle 0,0 31,31' -draw 'rectangle 32,32 63,63' "$WORK/tex-tile.png"
magick -size "${HL_WIDTH}x${HL_HEIGHT}" "tile:$WORK/tex-tile.png" "$WORK/tex.png"
magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#808080' "$WORK/flat.png"
timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call wallpaper set "$WORK/tex.png" >/dev/null 2>&1
sleep 3

# CLOSED first. The icon phase above leaves the launcher open, so without this
# the "before" frame is taken through the very scrim being measured -- both
# shots come back identical and the dim looks broken while working perfectly.
qsipc hide >/dev/null
sleep 2
grim "$WORK/dim-off.png" 2>/dev/null
qsipc drun >/dev/null
sleep 3
grim "$WORK/dim-on.png" 2>/dev/null

desktop_stats() { # desktop_stats <shot> -> "<mean> <spread>" clear of the panel
	python3 - "$1" <<'MEASURE'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L")
W, H = im.size
# Left of the panel and below the bar: the launcher never draws here, so what
# changes is the scrim and nothing else.
crop = im.crop((int(W * 0.03), int(H * 0.30), int(W * 0.28), int(H * 0.70)))
st = ImageStat.Stat(crop)
print("%.2f %.2f" % (st.mean[0], st.stddev[0]))
MEASURE
}
read -r OFF_MEAN OFF_SPREAD <<<"$(desktop_stats "$WORK/dim-off.png")"
read -r ON_MEAN ON_SPREAD <<<"$(desktop_stats "$WORK/dim-on.png")"
echo "  ..   desktop outside the panel: closed $OFF_MEAN, launcher open $ON_MEAN"

if python3 -c "import sys; sys.exit(0 if $ON_MEAN < $OFF_MEAN * 0.75 else 1)"; then
	ok "the screen dims when the launcher opens ($OFF_MEAN -> $ON_MEAN)"
else
	bad "the screen dims when the launcher opens ($OFF_MEAN -> $ON_MEAN)"
fi

# ...and is still there underneath. A scrim that took the wallpaper to black
# would pass the check above and be a worse thing to look at than no dim.
#
# ABSOLUTE, not a fraction of the undimmed spread. The relative form was
# `spread > OFF_SPREAD * 0.3`, which is not a legibility bound at all -- it is
# a bound on how deep the dim may be configured, and it fails at anything past
# 70 however good the result looks. The claim worth defending is "the desktop
# is still visible", and a flat black sheet is spread 0 while a fifth-strength
# checkerboard is 25: an absolute floor says that and says nothing about taste.
if python3 -c "import sys; sys.exit(0 if $ON_MEAN > 4 and $ON_SPREAD > 10 else 1)"; then
	ok "...without blacking it out (mean $ON_MEAN, spread $ON_SPREAD of $OFF_SPREAD)"
else
	bad "...without blacking it out (mean $ON_MEAN, spread $ON_SPREAD of $OFF_SPREAD)"
fi

qsipc hide >/dev/null
sleep 1

# ── opaque, and unaffected by what is behind it ─────────────────────────────
#
# The panel was translucent and blurred, the way the popovers are. It is
# neither now, on purpose: a launcher is READ rather than glanced at, and what
# comes through a translucent panel is whatever the wallpaper happens to be
# under those rows.
#
# So this is the inverse of the assertion it replaces. Change the wallpaper
# underneath and the panel's fill must not move at all -- a claim no amount of
# alpha or blur can satisfy, and one that a future "let's frost it again" fails
# immediately.
qsipc hide >/dev/null
sleep 1

# The panel's own fill, between the search field and the first row: the rows
# carry text and the text is identical in both frames, so measuring over them
# would dilute the very difference being looked for.
panel_stats() { # panel_stats <shot> -> "<mean> <spread>"
	python3 - "$1" <<'MEASURE'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L")
W, H = im.size
crop = im.crop((int(W * 0.36), int(H * 0.185), int(W * 0.62), int(H * 0.20)))
st = ImageStat.Stat(crop)
print("%.2f %.2f" % (st.mean[0], st.stddev[0]))
MEASURE
}

timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call wallpaper set "$WORK/tex.png" >/dev/null 2>&1
sleep 2
qsipc drun >/dev/null
sleep 3
grim "$WORK/over-checker.png" 2>/dev/null
read -r CHK_MEAN CHK_SPREAD <<<"$(panel_stats "$WORK/over-checker.png")"

timeout 5 quickshell -p "$HERE/shell/shell.qml" ipc call wallpaper set "$WORK/flat.png" >/dev/null 2>&1
sleep 3
grim "$WORK/over-flat.png" 2>/dev/null
read -r FLT_MEAN FLT_SPREAD <<<"$(panel_stats "$WORK/over-flat.png")"
echo "  ..   panel fill over a checkerboard $CHK_MEAN/$CHK_SPREAD, over flat grey $FLT_MEAN/$FLT_SPREAD"

# The premise: the two wallpapers really are different, measured where the
# panel is not. Two identical wallpapers would make the panel look admirably
# opaque.
BG_DIFF="$(python3 - "$WORK/over-checker.png" "$WORK/over-flat.png" <<'BG'
import sys
from PIL import Image, ImageStat
a = Image.open(sys.argv[1]).convert("L").crop((20, 400, 260, 560))
b = Image.open(sys.argv[2]).convert("L").crop((20, 400, 260, 560))
print("%.2f" % abs(ImageStat.Stat(a).stddev[0] - ImageStat.Stat(b).stddev[0]))
BG
)"
if python3 -c "import sys; sys.exit(0 if $BG_DIFF > 20 else 1)"; then
	ok "the two wallpapers differ where the panel is not ($BG_DIFF)"
else
	bad "the two wallpapers differ where the panel is not ($BG_DIFF -- the next check proves nothing)"
fi

DELTA="$(python3 -c "print(round(abs($CHK_MEAN - $FLT_MEAN), 2))")"
if python3 -c "import sys; sys.exit(0 if $DELTA < 1.0 else 1)"; then
	ok "the panel is opaque -- the wallpaper does not reach it (delta $DELTA)"
else
	bad "the panel is opaque -- the wallpaper does not reach it (delta $DELTA)"
fi
# 4, not 2. The box catches a pixel or two of the panel's rounded edge, which
# is antialiasing rather than backdrop -- it measures 2.3 on a flat fill. The
# thing this guards against is a blurred wallpaper showing through, and that
# measured 30 to 42 on the translucent version, so the margin is an order of
# magnitude either side.
if python3 -c "import sys; sys.exit(0 if $CHK_SPREAD < 4.0 else 1)"; then
	ok "...and its fill is flat, with no blurred backdrop in it (spread $CHK_SPREAD)"
else
	bad "...and its fill is flat, with no blurred backdrop in it (spread $CHK_SPREAD)"
fi

qsipc hide >/dev/null

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
