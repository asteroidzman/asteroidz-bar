#!/usr/bin/env bash
# parity.sh — is the quickshell bar drawing the same thing the compositor's
# native bar draws?
#
# "Looks identical" is a claim, and a claim about pixels can be checked. This
# boots ONE headless asteroidz instance, puts the same windows and tags in
# front of both bars in turn, screenshots each, and reports how far apart they
# are. The native bar is the reference; the shell is the candidate.
#
# It runs both in the SAME instance rather than two, because two instances
# means two sets of clients, two tag states and two clocks -- differences that
# have nothing to do with drawing. The native bar is switched off with a
# config reload between the passes instead, which is also the switch a real
# migration would flip.
#
#   contrib/parity.sh [-k]      -k keeps the PNGs and prints where they are
#
# Exit status is 0 when every measured section is within tolerance.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../shell" && pwd)"
LAUNCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/asteroidz-bar"

KEEP=0
[ "${1:-}" = "-k" ] && KEEP=1

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

FAILURES=0
QS_PID=""

cleanup() {
	[ -n "$QS_PID" ] && kill "$QS_PID" 2>/dev/null
	hl_stop
	if [ "$KEEP" = "1" ]; then
		echo "artifacts: $HL_OUTDIR"
	fi
}

hl_start
trap cleanup EXIT

PRISTINE="$HL_OUTDIR/config.pristine.kdl"
cp "$HL_CONFIG" "$PRISTINE"

# Rewrite the shared config with a bar block and reload. Same mechanism the
# compositor's own bar tests use.
bar_set() {
	cp "$PRISTINE" "$HL_CONFIG"
	printf '%s\n' "$1" >> "$HL_CONFIG"
	hl_dispatch "reload_config" 1
}

# The bar config both passes share. Only the modules phase 2 implements: a
# section the shell cannot draw yet would fail as a difference rather than as
# the missing feature it is.
BAR_CFG='bar { enable true; height 48; position "top"; margin { x 8; y 9 }
	spacing 8; pill-inset 6; show-all-tags false; show-logo true
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left "tags,layout,title"; modules-center "clock"
	modules-right "cpu,memory,network,volume,notify,idle"
	clock { format "%H:%M" } }'

# The tray is deliberately NOT in this list. quickshell hosts
# StatusNotifierItem on the SESSION bus, which the headless instance shares
# with the real desktop -- so the shell would draw the tray of whatever is
# running outside the test while the native bar, which needs a watcher that
# is not there, draws nothing. That is a difference in what the two can SEE,
# not in how they draw. contrib/tray-test.sh exercises the tray on a private
# bus instead.

# Something to look at: two windows on two tags, so the tag row has an occupied
# pill, an active one and an empty one, and the title pill has a title.
hl_dispatch "view,1"
hl_spawn_kitty parity
sleep 1
hl_dispatch "view,2"
hl_spawn_kitty parity
sleep 1
hl_dispatch "view,1"
sleep 0.5

shot_native() {
	bar_set "$BAR_CFG"
	sleep 2
	hl_screenshot native
}

shot_shell() {
	# The native bar off, the shell on. Everything else -- tags, windows,
	# palette -- is untouched, which is the point of doing both in one
	# instance.
	bar_set "${BAR_CFG/enable true/enable false}"
	sleep 1
	# The signature is passed per-command, never exported: the harness keeps it
	# in a shell variable precisely so a stray tool cannot reach the user's
	# REAL session. Same rule here -- the shell gets it on its own command line
	# and nothing else in this script inherits it.
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_SHELL="$SHELL_DIR/shell.qml" "$LAUNCHER" \
		> "$HL_OUTDIR/qs.log" 2>&1 &
	QS_PID=$!
	sleep 5
	hl_screenshot shell
	kill "$QS_PID" 2>/dev/null
	QS_PID=""
}

# How different are two crops? Reported as the fraction of pixels that differ
# by more than a just-noticeable amount, because an exact match is not the
# goal: two text rasterisers agreeing to the last subpixel is not something to
# gate on, and antialiasing on a rounded corner will always differ a little.
compare() {
	local label="$1" x0="$2" y0="$3" x1="$4" y1="$5" tolerance="$6"
	python3 - "$HL_OUTDIR/native.png" "$HL_OUTDIR/shell.png" \
		"$x0" "$y0" "$x1" "$y1" "$tolerance" "$label" <<'PY'
import sys
from PIL import Image, ImageChops

a, b, x0, y0, x1, y1, tol, label = sys.argv[1:]
x0, y0, x1, y1, tol = int(x0), int(y0), int(x1), int(y1), float(tol)
box = (x0, y0, x1, y1)
ia = Image.open(a).convert('RGB').crop(box)
ib = Image.open(b).convert('RGB').crop(box)
diff = ImageChops.difference(ia, ib)
px = list(diff.getdata())
n = len(px)
bad = sum(1 for p in px if max(p) > 24)
frac = bad / n if n else 0.0
ok = frac <= tol
print(f"  {'ok  ' if ok else 'FAIL'} {label}: {frac*100:.1f}% of pixels differ "
      f"(tolerance {tol*100:.0f}%)")
sys.exit(0 if ok else 1)
PY
	return $?
}

check() {
	if ! compare "$@"; then
		FAILURES=$((FAILURES + 1))
	fi
}

echo "=== parity: native bar vs asteroidz-bar ==="
shot_native
shot_shell

# GEOMETRY first, and strictly.
#
# This is the check that means something. Two text rasterisers will never agree
# to the last subpixel -- Pango hints advances differently from Qt, so a label
# lands a pixel wide and every glyph after it is antialiased against a slightly
# different background -- and a pixel gate strict enough to catch a real layout
# bug would fail forever on that alone.
#
# What CAN be identical is the layout: where each panel starts and ends, and
# where every pill's border begins. Those are integers, they are what the eye
# reads as "the same bar", and they are what breaks when a padding rule or a
# width formula is ported wrong -- which happened five times over while getting
# here.
geometry_check() {
	python3 - "$HL_OUTDIR/native.png" "$HL_OUTDIR/shell.png" <<'PY'
import sys
from PIL import Image


def panel(img, y=12):
    im = Image.open(img).convert('RGB')
    xs = [x for x in range(im.size[0]) if sum(im.getpixel((x, y))) < 120]
    return (min(xs), max(xs)) if xs else (0, 0)


def edges(img, y=33):
    """Where every pill border begins.

    The border colour is read from the image rather than hardcoded -- it comes
    from the theme, and a parity harness that only works with one palette is
    not much of a harness.
    """
    im = Image.open(img).convert('RGB')
    w = im.size[0]
    border = None
    for x in range(10, w):
        p = im.getpixel((x, y))
        if sum(p) > 200 and p[1] > p[2]:
            border = p
            break
    if border is None:
        return []
    out, prev = [], False
    for x in range(w):
        cur = im.getpixel((x, y)) == border
        if cur and not prev:
            out.append(x)
        prev = cur
    return out


fails = 0
na, nb = panel(sys.argv[1]), panel(sys.argv[2])
# One pixel, because a centred panel of odd width has to land on one side of
# the centre line or the other and the two renderers need not choose the same
# one. Two would start hiding real padding errors.
skew = max(abs(na[0] - nb[0]), abs(na[1] - nb[1]))
if skew <= 1:
    print(f"  ok   panel extents within {skew}px ({na[0]}..{na[1]})")
else:
    print(f"  FAIL panel extents: native {na}, shell {nb}")
    fails += 1

ea, eb = edges(sys.argv[1]), edges(sys.argv[2])
if len(ea) != len(eb):
    print(f"  FAIL pill count: native {len(ea)}, shell {len(eb)} edges")
    fails += 1
else:
    off = [abs(a - b) for a, b in zip(ea, eb)]
    worst = max(off) if off else 0
    # Four pixels, and the extra two are not slop.
    #
    # The compositor CROPS every icon to its alpha bounding box before
    # measuring it (text-node.c: applications ship artwork with wildly
    # different transparent margins, and centring an uncropped surface put
    # tray icons visibly off the line). QML has no pixel access, so an
    # icon-only pill here reserves the artwork's declared box instead of its
    # ink -- a bell with a 3px transparent margin makes a 3px wider pill.
    #
    # It is bounded and it is invisible: the artwork lands in the same place,
    # the box around it is slightly roomier. Anything past this is a real
    # layout bug, and every one of them so far has been 8px or more.
    if worst <= 4:
        print(f"  ok   all {len(ea)} pill edges within {worst}px")
    else:
        print(f"  FAIL pill edges drift up to {worst}px:")
        print(f"       native {ea[:8]}")
        print(f"       shell  {eb[:8]}")
        fails += 1

sys.exit(fails)
PY
	return $?
}

echo "-- geometry"
if ! geometry_check; then
	FAILURES=$((FAILURES + 1))
fi

echo "-- pixels"
# Loose, and deliberately so: this catches a section that is blank, a colour
# that is wrong, or artwork that failed to load -- not glyph antialiasing.
check "left section (tags, layout, title)"   0    0 700  70 0.35
check "centre section (clock)"             800    0 1120 70 0.15
check "right section (cpu, memory, network, volume, idle)" \
                                          1500    0 1920 70 0.35
check "the gap between sections"           700    0 800  70 0.02
check "below the bar (nothing drawn there)"  0   70 1920 200 0.01

if [ "$FAILURES" -eq 0 ]; then
	echo "=== parity: all sections within tolerance ==="
else
	echo "=== parity: $FAILURES section(s) out of tolerance ==="
	echo "    compare: $HL_OUTDIR/native.png $HL_OUTDIR/shell.png"
	KEEP=1
fi
exit "$FAILURES"
