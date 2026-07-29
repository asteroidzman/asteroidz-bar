#!/usr/bin/env bash
# notify-test.sh — does the bell show that something is unread?
#
# It did not. The module asked swaync's bus name for three PROPERTIES called
# count, dnd and inhibited; swaync has no properties by those names, only
# METHODS (NotificationCount, GetDnd, IsInhibited), so every poll came back
# `No such property "count"`, the parse gave up, and the count stayed at zero
# for ever. The bell drew "nothing unread" with fifty notifications waiting.
#
# Nothing about that is visible in the QML -- it reads perfectly well -- and it
# needs a daemon to catch. So the daemon is faked: a stub `swaync-client` early
# on PATH, which is what the module actually runs.
#
# The stub CHANGES its answer partway through, because a subscription that is
# read once and then ignored would pass a single-screenshot test while being
# just as broken as polling that never parses.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "notify-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null

WORK="$HL_OUTDIR"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar" "$WORK/bin"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# The fake daemon. Nothing unread for the first stretch, then seven.
cat > "$WORK/bin/swaync-client" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
--subscribe)
	# One line on connect, as the real client does, then a line per change.
	echo '{ "count": 0, "dnd": false, "visible": false, "inhibited": false }'
	sleep 14
	echo '{ "count": 7, "dnd": false, "visible": false, "inhibited": false }'
	sleep 3600
	;;
*)
	exit 0
	;;
esac
STUB
chmod +x "$WORK/bin/swaync-client"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "notify" }
EOF
hl_dispatch "reload_config" 1
sleep 1

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
elif isinstance(c, str):
    print(c)
' 2>/dev/null)"
echo "  ..   accent: ${ACCENT:-<unknown>}"

PATH="$WORK/bin:$PATH" dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$WORK/bin:$PATH" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!

# How much of the bell is drawn in the accent? That is the whole state: the
# glyph is tinted with the accent when something is unread and with the
# foreground when nothing is.
accent_px() { # accent_px <shot>
	python3 - "$WORK/$1.png" "${ACCENT:-#000000}" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load(); w, h = im.size
acc = sys.argv[2].lstrip("#")
if len(acc) != 6:
    print(0); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
print(sum(1 for y in range(10, 80) for x in range(w)
          if all(abs(a - b) <= 30 for a, b in zip(px[x, y], want))))
PY
}

sleep 10
grim -o "$HL_MON" "$WORK/quiet.png" 2>/dev/null
QUIET="$(accent_px quiet)"

# ...and now seven arrive, on the same subscription.
sleep 10
grim -o "$HL_MON" "$WORK/unread.png" 2>/dev/null
UNREAD="$(accent_px unread)"

kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

if [ "$QUIET" -lt 40 ]; then
	ok "nothing unread leaves the bell untinted ($QUIET accent px)"
else
	bad "nothing unread leaves the bell untinted ($QUIET accent px)"
fi

# The bug drew exactly the quiet bell no matter what the daemon said, so this
# is the assertion that failed before: the count has to REACH the pill.
if [ "$UNREAD" -gt $((QUIET + 60)) ]; then
	ok "an unread count tints the bell ($QUIET -> $UNREAD accent px)"
else
	bad "an unread count tints the bell ($QUIET -> $UNREAD accent px)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
