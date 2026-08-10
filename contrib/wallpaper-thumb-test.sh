#!/usr/bin/env bash
# wallpaper-thumb-test.sh — an HDR wallpaper's tile looks like the picture.
#
# The picker drew its tiles from the file (`source: "file://" + path`). Qt reads
# JPEG XL and AVIF, and for an HDR file it hands back the code values untouched
# -- which under PQ are an encoding of absolute luminance, not colours. Drawn as
# sRGB, a 1000-nit sunset is a flat grey rectangle. Reported as "jxl files are
# not shown in the wallpaper picker": they were in the model and they were on
# screen, they just did not look like anything.
#
# tests/test_tonemap.cpp covers the curve. This covers the two things it cannot:
# that the provider is REACHABLE from QML at all -- the failure mode that
# actually happened to the tray's provider, where a correctly written one was
# never installed and every icon silently fell back -- and that a real PQ file
# put through it comes out looking different from the raw file.
#
# BOTH tiles are drawn, side by side, in one window. A test that only measured
# the tone-mapped tile would pass on the broken build for any file whose raw PQ
# happened to be bright enough, and there is no threshold that is right for
# every image. The comparison is the assertion: same file, same size, same
# frame, one through the provider and one not.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
BAR_BUILD="${BAR_BUILD:-$HERE/build}"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$BAR_BUILD/libasteroidzbarplugin.so" ] || {
	echo "wallpaper-thumb-test: not built -- meson setup build && meson compile -C build" >&2
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
echo "hdr wallpaper thumbnails"

# ── the subject ──────────────────────────────────────────────────────────────
#
# avifenc rather than a checked-in file: a binary blob in the tree cannot be
# read, and the whole point is that this one's COLORIMETRY is known. --cicp
# 9/16/9 is BT.2020 primaries, ST 2084 transfer, BT.2020 matrix -- the tags
# hdr_image_load() reads to decide an image is HDR at all.
#
# The content is a mid-grey ramp with a small bright patch: mid-grey so the
# naive reading has something to be wrong ABOUT (a black image looks identical
# either way), and a patch above reference white so the roll-off has work to do.
HDR="$WORK/hdr.avif"
if ! command -v avifenc >/dev/null 2>&1; then
	echo "  skip avifenc not installed -- nothing to thumbnail"
	echo
	echo "  $PASS passed, $FAIL failed"
	exit 0
fi

# 10-bit PNG source. The values are PQ code values, written directly: 0.58 of
# full scale is reference white, 0.75 is about a thousand nits.
magick -size 480x270 \
	-define png:color-type=2 -depth 16 \
	gradient:'#949494-#252525' "$WORK/ramp.png"
magick "$WORK/ramp.png" -fill '#c0c0c0' -draw 'rectangle 380,20 460,90' "$WORK/src.png"
avifenc --cicp 9/16/9 -d 10 -y 444 --speed 8 "$WORK/src.png" "$HDR" >/dev/null 2>&1 || {
	echo "  skip avifenc could not produce a PQ file"
	echo
	echo "  $PASS passed, $FAIL failed"
	exit 0
}

magick -size 480x270 gradient:'#c07838-#182840' "$WORK/csrc.png"
avifenc --cicp 9/16/9 -d 10 -y 444 --speed 8 "$WORK/csrc.png" "$WORK/chdr.avif" \
	>/dev/null 2>&1

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#000000' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# ── the two tiles ────────────────────────────────────────────────────────────
#
# A probe shell rather than the settings window: the window is reached through
# a sidebar whose row arithmetic belongs to settings-test.sh, and what is being
# measured here is one Image source, not a navigation path.
PSHELL="$WORK/probeshell"
mkdir -p "$PSHELL"
cat > "$PSHELL/shell.qml" <<'EOF'
import Quickshell
import QtQuick
import Asteroidz.Bar

ShellRoot {
    PanelWindow {
        anchors { top: true; left: true; right: true; bottom: true }
        color: "#000000"
        Row {
            spacing: 0
            // LEFT: through the provider. RIGHT: the way the picker used to do
            // it. Identical in every other respect, so the difference between
            // the halves is the feature and nothing else.
            Image {
                width: 400; height: 225
                source: Paths.wallpaperThumb(Quickshell.env("PROBE_HDR_FILE"), 320)
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
                onStatusChanged: if (status === Image.Error)
                    console.warn("PROBE provider tile FAILED to load");
            }
            Image {
                width: 400; height: 225
                source: "file://" + Quickshell.env("PROBE_HDR_FILE")
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
                onStatusChanged: if (status === Image.Error)
                    console.warn("PROBE raw tile FAILED to load");
            }
        }
    }
}
EOF

bar_conf "tags" "" "" <<EOF
$(bar_conf_panel)
EOF
hl_dispatch "reload_config" 1

setsid $(bar_limits) dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$PSHELL/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	PROBE_HDR_FILE="$HDR" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 9

grim -o "$HL_MON" "$WORK/tiles.png" 2>/dev/null

# The provider is installed from the Paths singleton's factory, exactly like
# the tray's -- and the tray's was written correctly and never installed for
# months, because a missing provider does not fail, it falls back. "Invalid
# image provider" in the log is that failure, and it is worth its own line.
if grep -qa "Invalid image provider" "$WORK/qs.log"; then
	bad "the wallthumb provider is reachable from QML (engine says invalid)"
else
	ok "the wallthumb provider is reachable from QML"
fi
if grep -qa "PROBE provider tile FAILED" "$WORK/qs.log"; then
	bad "the provider returns an image for a PQ AVIF"
else
	ok "the provider returns an image for a PQ AVIF"
fi

# Both ENDS of the picture, not its average.
#
# The average was the first thing measured here and it is the wrong measure:
# tone mapping lifts the highlight AND drops the shadow, so on this file the
# two halves came out 96.4 against 96.0 -- a difference of 0.4 on a conversion
# that changes every pixel in the frame. What moves is the SPREAD.
#
# The tile is 400x225 drawn from a 480x270 source, so source coordinates scale
# by exactly 5/6 and the boxes below are that arithmetic, not a hunt: the
# 1000-nit patch at 380,20 lands at 316,16, and the dark end of the ramp is the
# bottom strip.
read -r HI_L HI_R LO_L LO_R <<<"$(python3 - "$WORK/tiles.png" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
def mean(box):
    px = list(im.crop(box).getdata())
    return sum(sum(p) / 3 for p in px) / len(px)

# highlight patch, then the shadow strip; provider tile first, raw tile second
print(round(mean((325, 25, 375, 70)), 1), round(mean((725, 25, 775, 70)), 1),
      round(mean((20, 200, 300, 218)), 1), round(mean((420, 200, 700, 218)), 1))
PY
)"

# The premise. Both halves must have drawn SOMETHING -- two black rectangles
# would satisfy any "they differ" test by differing not at all, and would look
# exactly like a window that never came up.
if [ "${HI_R%.*}" -gt 5 ]; then
	ok "the raw tile drew (highlight $HI_R, shadow $LO_R)"
else
	bad "the raw tile drew (highlight $HI_R) -- nothing below can mean anything"
	echo; echo "  $PASS passed, $FAIL failed"; kill "$QS" 2>/dev/null; exit 1
fi

# A 1000-nit patch is the brightest thing in this file, so it must end up at or
# near white. Read as sRGB its code value is 0.75 -- a light grey, in between
# nothing in particular. 30 levels out of 255 is far outside what resampling or
# the compositor's blending could account for, and on the build this fixes the
# two halves are the same image and the difference is 0.
if python3 -c "import sys; sys.exit(0 if $HI_L > $HI_R + 30 else 1)"; then
	ok "the 1000-nit patch comes out near white ($HI_L vs $HI_R raw)"
else
	bad "the 1000-nit patch comes out near white ($HI_L vs $HI_R raw)"
fi

# And the other end: under a nit of light is nearly black, where the naive
# reading puts it at a fifth of full scale. This is the half of the error that
# makes an HDR file look like a grey wash rather than merely a dim one.
if python3 -c "import sys; sys.exit(0 if $LO_L < $LO_R - 10 else 1)"; then
	ok "...and the sub-nit shadow comes out dark ($LO_L vs $LO_R raw)"
else
	bad "...and the sub-nit shadow comes out dark ($LO_L vs $LO_R raw)"
fi

# Not a wash, either. The naive reading flattens contrast as well as darkening
# it -- that is what makes an HDR file read as a grey rectangle -- so the
# tone-mapped tile must have a WIDER spread of values, not just a shifted one.
read -r LSD RSD <<<"$(python3 - "$WORK/tiles.png" <<'PY'
import sys, statistics
from PIL import Image

im = Image.open(sys.argv[1]).convert("L")
def sd(box):
    return statistics.pstdev(list(im.crop(box).getdata()))
print(round(sd((20, 20, 380, 205)), 2), round(sd((420, 20, 780, 205)), 2))
PY
)"
if python3 -c "import sys; sys.exit(0 if $LSD > $RSD * 1.15 else 1)"; then
	ok "...and carries more contrast, not just more brightness ($LSD vs $RSD)"
else
	bad "...and carries more contrast, not just more brightness ($LSD vs $RSD)"
fi

# An ordinary file must be untouched by any of this. The provider is on the
# path for EVERY tile now, so a regression here would break a folder of jpegs
# in order to fix two jxls.
kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

cat > "$PSHELL/shell.qml" <<'EOF'
import Quickshell
import QtQuick
import Asteroidz.Bar

ShellRoot {
    PanelWindow {
        anchors { top: true; left: true; right: true; bottom: true }
        color: "#000000"
        Row {
            spacing: 0
            Image {
                width: 400; height: 225
                source: Paths.wallpaperThumb(Quickshell.env("PROBE_SDR_FILE"), 320)
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
            }
            Image {
                width: 400; height: 225
                source: "file://" + Quickshell.env("PROBE_SDR_FILE")
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
            }
        }
    }

    // The themer reads the wallpaper too, and it read it the same wrong way:
    // QImage on a PQ file hands back the encoding, so the desktop was themed
    // from washed-out mid-grey while the wallpaper on screen was a sunset.
    //
    // The two files here carry the SAME code values -- avifenc --cicp only
    // tags them -- so a themer that ignores the tag produces one seed for
    // both. That identity is the assertion: after the fix they must differ,
    // because one of them is PQ and means something else.
    Timer {
        interval: 2500; running: true
        onTriggered: {
            ColorEngine.source = Quickshell.env("PROBE_HDR_COLOUR");
            const hdr = ColorEngine.seed + " " + ColorEngine.error;
            ColorEngine.source = Quickshell.env("PROBE_SDR_COLOUR");
            console.warn("PROBE seed hdr=" + hdr
                + " sdr=" + ColorEngine.seed + " " + ColorEngine.error);
        }
    }
}
EOF
magick -size 480x270 gradient:'#e0c090-#203040' "$WORK/sdr.png"
setsid $(bar_limits) dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$BAR_XDG" GSETTINGS_BACKEND=memory \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$PSHELL/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	ASTEROIDZ_BAR_CONFIG="$BAR_CONF" \
	PROBE_SDR_FILE="$WORK/sdr.png" \
	PROBE_HDR_COLOUR="$WORK/chdr.avif" \
	PROBE_SDR_COLOUR="$WORK/csrc.png" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs2.log" 2>&1 &
QS2=$!
sleep 9
grim -o "$HL_MON" "$WORK/sdrtiles.png" 2>/dev/null
kill "$QS2" 2>/dev/null
wait "$QS2" 2>/dev/null

read -r SDRDIFF <<<"$(python3 - "$WORK/sdrtiles.png" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
def mean(box):
    px = im.crop(box).getdata()
    return sum(sum(p) / 3 for p in px) / len(px)
print(round(abs(mean((20, 20, 380, 205)) - mean((420, 20, 780, 205))), 2))
PY
)"
if python3 -c "import sys; sys.exit(0 if $SDRDIFF < 2.0 else 1)"; then
	ok "an SDR file is unchanged by the provider (difference $SDRDIFF)"
else
	bad "an SDR file is unchanged by the provider (difference $SDRDIFF)"
fi

# The themer, which reads the wallpaper for its own reasons and read it the
# same wrong way.
SEEDS="$(grep -a "PROBE seed" "$WORK/qs2.log" | tail -1)"
HDR_SEED="$(printf '%s' "$SEEDS" | sed -n 's/.*hdr=\(#[0-9a-fA-F]*\).*/\1/p')"
SDR_SEED="$(printf '%s' "$SEEDS" | sed -n 's/.*sdr=\(#[0-9a-fA-F]*\).*/\1/p')"
echo "  ..   seed colour from the same picture: PQ $HDR_SEED, sRGB $SDR_SEED"

if [ -n "$HDR_SEED" ] && [ -n "$SDR_SEED" ]; then
	ok "the themer produced a seed colour from both encodings"
else
	bad "the themer produced a seed colour from both encodings (got '$SEEDS')"
fi
# The two files hold IDENTICAL code values -- avifenc --cicp tags, it does not
# convert -- so a themer that ignores the tag answers the same colour twice.
# Equality here is the old bug exactly.
if [ -n "$HDR_SEED" ] && [ "$HDR_SEED" != "$SDR_SEED" ]; then
	ok "...and reads the PQ one as a different colour, not the same numbers"
else
	bad "...and reads the PQ one as a different colour, not the same numbers (both $HDR_SEED -- the themer is quantising the encoding)"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
