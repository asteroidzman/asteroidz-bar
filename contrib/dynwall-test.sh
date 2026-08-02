#!/usr/bin/env bash
# dynwall-test.sh — Apple dynamic wallpapers: the schedule, and the frames.
#
# No Wayland and no compositor. Both halves of plugin/dynwall.c are ordinary
# functions: one parses an XMP document, the other pulls an image out of a HEIC
# container. Neither needs a shell running to be wrong.
#
# Every fixture is BUILT here rather than taken from the machine. The point of
# the feature is that it works for any dynamic wallpaper, so a test pinned to
# the two files that happen to be in ~/Pictures would be testing those two
# files. The schedules are synthesised with python's plistlib -- a reference
# implementation of the format, which is also what caught that the parser here
# agrees with it -- and the multi-image HEIC is built with heif-enc.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

command -v heif-enc >/dev/null 2>&1 || {
	echo "dynwall-test: heif-enc not installed (libheif) -- cannot build a fixture" >&2
	exit 1
}

# ── the harness ─────────────────────────────────────────────────────────────
#
# Compiled against the real translation unit, not a copy of it.
cat > "$WORK/harness.c" <<'EOF'
#include "dynwall.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* schedule <xmp-file>            -- parse and print it
 * at <xmp-file> <fraction>       -- which frame, and when it next changes
 * extract <heic> <index> <png>   -- pull one image out
 */
static char *slurp(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *buf = malloc((size_t)n + 1);
	if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); buf = NULL; }
	fclose(f);
	if (buf) { buf[n] = 0; *len = (size_t)n; }
	return buf;
}

int main(int argc, char **argv) {
	if (argc < 3) return 2;

	if (strcmp(argv[1], "sun") == 0) {
		double alt, az;
		azbar_sun_position(atof(argv[2]), atof(argv[3]), atoll(argv[4]), &alt, &az);
		printf("%.2f %.2f\n", alt, az);
		return 0;
	}

	if (strcmp(argv[1], "extract") == 0) {
		char *err = NULL;
		bool ok = azbar_dyn_extract(argv[2], atoi(argv[3]), argv[4], &err);
		printf("%s%s%s\n", ok ? "ok" : "fail", err ? ": " : "", err ? err : "");
		free(err);
		return ok ? 0 : 1;
	}

	size_t len = 0;
	char *xmp = slurp(argv[2], &len);
	if (!xmp) return 2;

	struct azbar_dyn_schedule s;
	if (!azbar_dyn_parse_xmp(xmp, len, &s)) {
		printf("none\n");
		free(xmp);
		return 1;
	}

	if (strcmp(argv[1], "schedule") == 0) {
		printf("frames=%zu solar=%d light=%d dark=%d\n",
			s.n_frames, s.solar ? 1 : 0, s.light_index, s.dark_index);
		for (size_t i = 0; i < s.n_frames; i++)
			printf("%.6f %d\n", s.frames[i].t, s.frames[i].index);
	} else if (strcmp(argv[1], "at") == 0) {
		double f = atof(argv[3]);
		printf("%d %.6f\n", azbar_dyn_frame_at(&s, f), azbar_dyn_next_change(&s, f));
	} else if (strcmp(argv[1], "atsun") == 0) {
		printf("%d\n", azbar_dyn_frame_at_sun(&s, atof(argv[3]), atof(argv[4])));
	}

	azbar_dyn_schedule_free(&s);
	free(xmp);
	return 0;
}
EOF

gcc -o "$WORK/harness" "$WORK/harness.c" "$HERE/plugin/dynwall.c" \
	-I"$HERE/plugin" $(pkg-config --cflags --libs libheif libpng) -lm 2>"$WORK/cc.log" || {
	echo "dynwall-test: harness did not build" >&2
	sed 's/^/       /' "$WORK/cc.log" >&2
	exit 1
}
H="$WORK/harness"

# An XMP document carrying a schedule, built the way Apple's is.
mk_xmp() { # mk_xmp <out> <property> <python-dict>
	python3 - "$1" "$2" "$3" <<'PY'
import base64, plistlib, sys
out, prop, expr = sys.argv[1], sys.argv[2], sys.argv[3]
blob = base64.b64encode(plistlib.dumps(eval(expr), fmt=plistlib.FMT_BINARY)).decode()
open(out, "w").write(
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"> <rdf:RDF '
    'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"> '
    '<rdf:Description rdf:about="" '
    'xmlns:apple_desktop="http://ns.apple.com/namespace/1.0/" '
    'apple_desktop:%s="%s"/> </rdf:RDF> </x:xmpmeta>' % (prop, blob))
PY
}

# ── the schedule, parsed ────────────────────────────────────────────────────

mk_xmp "$WORK/two.xmp" h24 "{'ti':[{'t':0.0,'i':1},{'t':0.5,'i':0}],'ap':{'l':0,'d':1}}"
got="$("$H" schedule "$WORK/two.xmp" | head -1)"
if [ "$got" = "frames=2 solar=0 light=0 dark=1" ]; then
	ok "a two-frame h24 schedule is read, with its light/dark pair"
else
	bad "a two-frame h24 schedule is read, with its light/dark pair (got '$got')"
fi

# Out of order on purpose. Nothing promises the file is sorted, and every
# lookup is "the last entry at or before now" -- which is only meaningful once
# it is.
mk_xmp "$WORK/three.xmp" h24 \
	"{'ti':[{'t':0.7292,'i':0},{'t':0.0,'i':1},{'t':0.2708,'i':2}],'ap':{'l':2,'d':1}}"
got="$("$H" schedule "$WORK/three.xmp" | tail -3 | tr '\n' ' ')"
if [ "$got" = "0.000000 1 0.270800 2 0.729200 0 " ]; then
	ok "an out-of-order table is sorted into time order"
else
	bad "an out-of-order table is sorted into time order (got '$got')"
fi

# ── which frame, at what time ───────────────────────────────────────────────
#
# `t` counts from LOCAL MIDNIGHT. That is the convention every other
# implementation uses, and the files bear it out: a three-frame wallpaper in
# the wild switches at 0.2708 and 0.7292, which are 06:30 and 17:30 -- sunrise
# and sunset. Read as fractions from noon they would be 18:30 and 05:30, which
# would put the daylight frame on all night.
at() { "$H" at "$1" "$2"; }

check_at() { # check_at <xmp> <fraction> <frame> <next> <what>
	got="$(at "$1" "$2")"
	want="$3 $4"
	if [ "$got" = "$want" ]; then
		ok "$5"
	else
		bad "$5 (got '$got', wanted '$want')"
	fi
}

check_at "$WORK/three.xmp" 0.000000 1 0.270800 "at midnight, the frame scheduled for midnight"
check_at "$WORK/three.xmp" 0.200000 1 0.270800 "...still it at 04:48"
check_at "$WORK/three.xmp" 0.300000 2 0.729200 "the 06:30 frame once past 06:30"
check_at "$WORK/three.xmp" 0.729200 0 1.000000 "the 17:30 frame exactly on its boundary"
check_at "$WORK/three.xmp" 0.900000 0 1.000000 "...and through the evening"

# Before the first entry there is no earlier one, so it wraps: the frame that
# started last night is the one still showing.
mk_xmp "$WORK/late.xmp" h24 "{'ti':[{'t':0.25,'i':0},{'t':0.75,'i':1}]}"
check_at "$WORK/late.xmp" 0.100000 1 0.250000 "before the first entry it wraps to the last"

# ── the sun-position variant ────────────────────────────────────────────────
#
# Its table is keyed by solar altitude. With a location that is read as written
# (below); with none -- nothing has asked for one, or the lookup failed -- it
# falls back to the file's own light/dark pair rather than inventing a latitude.
mk_xmp "$WORK/solar.xmp" solar \
	"{'si':[{'a':-20.0,'z':0.0,'i':0},{'a':40.0,'z':180.0,'i':1}],'ap':{'l':1,'d':0}}"
got="$("$H" schedule "$WORK/solar.xmp" | head -1)"
case "$got" in
"frames=2 solar=1 light=1 dark=0") ok "a solar schedule is recognised as one" ;;
*) bad "a solar schedule is recognised as one (got '$got')" ;;
esac
got="$(at "$WORK/solar.xmp" 0.500000 | cut -d' ' -f1)"
[ "$got" = "1" ] && ok "...and takes the light frame in the middle of the day" \
	|| bad "...and takes the light frame in the middle of the day (got '$got')"
got="$(at "$WORK/solar.xmp" 0.050000 | cut -d' ' -f1)"
[ "$got" = "0" ] && ok "...and the dark one at night" \
	|| bad "...and the dark one at night (got '$got')"

# ── where the sun is ────────────────────────────────────────────────────────
#
# Checked against geometry that is true by definition rather than against a
# table of numbers from somewhere else: at an equinox, local solar noon puts
# the sun due south at an altitude of 90 minus the latitude, and twelve hours
# later it is the same angle below the horizon due north. If the arithmetic is
# wrong, those do not come out.
sun_check() { # sun_check <lat> <lon> <iso-utc> <alt> <az> <what>
	ts="$(date -u -d "$3" +%s)"
	read -r alt az <<<"$("$H" sun "$1" "$2" "$ts")"
	if python3 -c "
import sys
alt, az = float('$alt'), float('$az')
d_alt = abs(alt - $4)
d_az = min(abs(az - $5), 360 - abs(az - $5))
sys.exit(0 if d_alt < 2.5 and d_az < 3.0 else 1)
"; then
		ok "$6 (alt $alt, az $az)"
	else
		bad "$6 (alt $alt az $az, wanted ~$4 / ~$5)"
	fi
}
sun_check 51.4779 0.0 "2026-03-20 12:07:00" 38.5 180.0 \
	"at the equinox the noon sun is due south, 90 minus the latitude up"
sun_check 51.4779 0.0 "2026-03-21 00:07:00" -38.5 0.0 \
	"...and twelve hours later the same angle below the horizon, due north"
# Sydney at its solar noon, which is 01:53 UTC and not 12:00 anything: the
# longitude is 151.2 degrees east, so the meridian passage is ten hours ahead of
# Greenwich. Solstice altitude is 90 minus the gap between latitude and the
# sun's declination -- 90 - |-33.87 - (-23.44)| = 79.6 -- and it is due NORTH,
# which is the half of this a northern-hemisphere assumption gets wrong.
sun_check -33.8688 151.2093 "2026-12-21 01:53:00" 79.6 0.0 \
	"south of the equator the solstice sun is high and due NORTH"

# The tie azimuth breaks. A solar table passes through every altitude twice --
# once climbing, once falling -- so altitude alone cannot say which frame is
# meant, and a wallpaper that ran its sunset picture at dawn would be the
# result.
mk_xmp "$WORK/twice.xmp" solar \
	"{'si':[{'a':10.0,'z':90.0,'i':0},{'a':10.0,'z':270.0,'i':1}],'ap':{'l':0,'d':1}}"
got="$("$H" atsun "$WORK/twice.xmp" 10.0 95.0)"
[ "$got" = "0" ] && ok "the same altitude in the morning takes the morning frame" \
	|| bad "the same altitude in the morning takes the morning frame (got '$got')"
got="$("$H" atsun "$WORK/twice.xmp" 10.0 265.0)"
[ "$got" = "1" ] && ok "...and in the evening the evening one" \
	|| bad "...and in the evening the evening one (got '$got')"

# ── documents that are not schedules ────────────────────────────────────────
#
# The ordinary case is an image with no such property at all, and it must be
# cheap and quiet rather than an error.
printf '<x:xmpmeta><rdf:RDF/></x:xmpmeta>' > "$WORK/plain.xmp"
[ "$("$H" schedule "$WORK/plain.xmp")" = "none" ] \
	&& ok "an XMP with no apple_desktop property is not a dynamic wallpaper" \
	|| bad "an XMP with no apple_desktop property is not a dynamic wallpaper"

# Rubbish in the property. A file can be truncated, hand-edited or simply not
# what it claims; none of that may crash the shell that reads it.
printf '<x:xmpmeta apple_desktop:h24="bm90IGEgcGxpc3Q="/>' > "$WORK/junk.xmp"
if "$H" schedule "$WORK/junk.xmp" >/dev/null 2>&1; then
	bad "a property holding something that is not a plist is refused"
else
	ok "a property holding something that is not a plist is refused"
fi

# A real plist, truncated. This is the one that walks off the end if the
# offset table is trusted rather than checked.
python3 - "$WORK/trunc.xmp" <<'PY'
import base64, plistlib, sys
blob = plistlib.dumps({'ti': [{'t': 0.0, 'i': 0}]}, fmt=plistlib.FMT_BINARY)
cut = base64.b64encode(blob[:len(blob) // 2]).decode()
open(sys.argv[1], "w").write('<x apple_desktop:h24="%s"/>' % cut)
PY
if "$H" schedule "$WORK/trunc.xmp" >/dev/null 2>&1; then
	bad "a truncated plist is refused rather than read off the end"
else
	ok "a truncated plist is refused rather than read off the end"
fi

# ── pulling a frame out of a real container ─────────────────────────────────
#
# Any HEIC with several images in it, built here: three flat colours, so
# "did the right one come out" is one pixel.
magick -size 64x64 xc:'#ff0000' "$WORK/f0.png" 2>/dev/null
magick -size 64x64 xc:'#00ff00' "$WORK/f1.png" 2>/dev/null
magick -size 64x64 xc:'#0000ff' "$WORK/f2.png" 2>/dev/null
if heif-enc -q 100 "$WORK/f0.png" "$WORK/f1.png" "$WORK/f2.png" \
		-o "$WORK/multi.heic" >/dev/null 2>&1 \
		&& [ -f "$WORK/multi.heic" ]; then
	ok "a multi-image HEIC can be built to test against"

	allgood=1
	for i in 0 1 2; do
		"$H" extract "$WORK/multi.heic" "$i" "$WORK/out$i.png" >/dev/null 2>&1
		if [ ! -f "$WORK/out$i.png" ]; then
			allgood=0
			continue
		fi
		got="$(magick "$WORK/out$i.png" -resize 1x1 -format '%[hex:p{0,0}]' info: 2>/dev/null)"
		# Compared with a tolerance, not matched exactly: HEIC stores YCbCr
		# 4:2:0, so pure red comes back as #FE0000. An exact match here would
		# be a test of the codec's rounding rather than of the extraction.
		want=$(case $i in 0) echo "255 0 0";; 1) echo "0 255 0";; *) echo "0 0 255";; esac)
		if ! python3 -c "
import sys
got='$got'[:6]; want=[int(v) for v in '$want'.split()]
rgb=[int(got[i:i+2],16) for i in (0,2,4)]
sys.exit(0 if all(abs(a-b)<=8 for a,b in zip(rgb,want)) else 1)
" 2>/dev/null; then
			allgood=0
			echo "       frame $i came out #$got, wanted $want"
		fi
	done
	# Compared as "each index gave a DIFFERENT image" as well, because three
	# extractions that all quietly returned the primary image would each be a
	# plausible colour on their own.
	n_distinct="$(md5sum "$WORK"/out?.png 2>/dev/null | awk '{print $1}' | sort -u | wc -l)"
	if [ "$allgood" = 1 ]; then
		ok "each index pulls out its own image"
	else
		bad "each index pulls out its own image"
	fi
	if [ "$n_distinct" = 3 ]; then
		ok "...and the three are actually different files"
	else
		bad "...and the three are actually different files (got $n_distinct distinct)"
	fi

	# Past the end is the file disagreeing with its own schedule, which happens
	# and must not be decoded from whatever is at that offset.
	if "$H" extract "$WORK/multi.heic" 9 "$WORK/nope.png" >/dev/null 2>&1; then
		bad "an index the file does not have is refused"
	else
		ok "an index the file does not have is refused"
	fi
else
	bad "a multi-image HEIC can be built to test against"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
