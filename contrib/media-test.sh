#!/usr/bin/env bash
# media-test.sh — the media module, with a player and without a sound.
#
# The module needs an MPRIS player before it draws anything at all: no player
# means `have` is false and the whole thing drops off the bar. So on a test
# machine every question about how it LOOKS was unanswerable, which is how the
# visualiser vanishing on silence stayed unnoticed until it was reported.
# contrib/mprisstub supplies one, on a private bus so the answer does not
# depend on what happens to be playing.
#
# The case under test is exactly the awkward one: something is "playing", there
# is nothing audible (a headless box has no audio at all), and the meter has to
# read ZERO -- a row of flat bars -- rather than disappear and take the pill's
# layout with it.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "media-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null

WORK="$HL_OUTDIR"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

BARS=6
cat >> "$HL_CONFIG" <<EOF
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center "media"; modules-right ""
	media { bars $BARS } }
EOF
hl_dispatch "reload_config" 1
sleep 1

# The accent the bars are drawn in, straight from the compositor rather than
# guessed: the harness cannot resolve the real colours.kdl, so whatever the
# defaults come out as is what will be on screen.
ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = (d.get("theme") or {}).get("focus_bg")
# Served as normalised RGBA floats, not as a hex string.
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
elif isinstance(c, str):
    print(c)
' 2>/dev/null)"
echo "  ..   accent: ${ACCENT:-<unknown>}"

cat > "$WORK/run.sh" <<'INNER'
#!/usr/bin/env bash
set -u
WORK="$1"; HERE="$2"; SIG="$3"; WL="$4"; XRD="$5"; QMLROOT="$6"; REPO="$7"
PROBE_SHELL="${PROBE_SHELL:-}"

"$HERE/contrib/mprisstub" --title "Silent Track" --artist "Nobody" \
	> "$WORK/stub.log" 2>&1 &
STUB=$!
# Wait for the name, rather than sleeping and hoping.
for _ in $(seq 1 40); do
	grep -q ready "$WORK/stub.log" 2>/dev/null && break
	sleep 0.25
done

# Proof the stub is reachable on THIS bus before blaming the bar for not
# seeing it -- the two are only the same question when the bus is the same.
playerctl -l > "$WORK/players.txt" 2>&1 || true

WAYLAND_DISPLAY="$WL" XDG_RUNTIME_DIR="$XRD" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="${PROBE_SHELL:-$HERE/shell}/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 10
grim -o "$MON" "$WORK/media.png" 2>/dev/null
kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null
kill "$STUB" 2>/dev/null; wait "$STUB" 2>/dev/null
INNER
chmod +x "$WORK/run.sh"

MON="$HL_MON" dbus-run-session -- env MON="$HL_MON" "$WORK/run.sh" \
	"$WORK" "$HERE" "$HL_SIG" "$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR" \
	"$QMLROOT" "$REPO"

if [ ! -f "$WORK/media.png" ]; then
	bad "the bar drew anything at all (no screenshot)"
	echo
	echo "$PASS passed, $((FAIL)) failed"
	exit 1
fi

# Is the module there? With a player on the bus it must be.
PANEL="$(python3 - "$WORK/media.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
print(sum(1 for y in range(10, 80, 2) for x in range(0, w, 2)
          if sum(px[x, y]) < 400))
PY
)"
if [ "$PANEL" -gt 200 ]; then
	ok "a player on the bus puts the media module on the bar ($PANEL px)"
else
	bad "a player on the bus puts the media module on the bar ($PANEL px)"
fi

# The bars. Counted as runs of the accent on the scanline through the middle of
# the bar -- flat bars are only a couple of pixels tall, so the count is taken
# across a few rows and the best answer wins rather than betting on one line.
COUNT="$(python3 - "$WORK/media.png" "${ACCENT:-#000000}" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4)) if len(acc) == 6 else None

def near(c, t, tol=26):
    return all(abs(a - b) <= tol for a, b in zip(c, t))

# Flat bars are only a couple of pixels tall, so every scanline across the bar
# is tried and the best answer wins rather than betting on one line. Runs under
# 3px wide are antialiasing on the title's glyphs rather than bars, and real
# bars are all one width -- which is what tells them apart from anything else
# the accent gets used for.
best = 0
for y in range(20, 70):
    runs, start = [], None
    for x in range(w):
        if want is not None and near(px[x, y], want):
            if start is None:
                start = x
        else:
            if start is not None:
                runs.append(x - start)
            start = None
    if start is not None:
        runs.append(w - start)
    runs = [r for r in runs if r >= 3]
    if len(runs) >= 2 and len(set(runs)) == 1:
        best = max(best, len(runs))
print(best)
PY
)"

if [ "$COUNT" -eq "$BARS" ]; then
	ok "the spectrum draws all $BARS bars with nothing audible (found $COUNT)"
else
	bad "the spectrum draws all $BARS bars with nothing audible (found $COUNT)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
