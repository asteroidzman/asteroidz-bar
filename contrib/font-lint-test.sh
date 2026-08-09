#!/usr/bin/env bash
# font-lint-test.sh — every piece of text in the shell uses the configured font.
#
# There is no application-wide font here. The shell takes its font from the
# compositor's `theme { font }` and applies it per item, so an element that does
# not set a font property does not fall back to the configured one -- it falls
# back to whatever Qt picks, which is a different typeface, or a different
# weight, from everything beside it.
#
# Reported as "all bar popovers, menus etc. should use the configured font, some
# do, some don't", and again as "font problems in the 'top' like display,
# clipboard module, calendar".
#
# The family was already set nearly everywhere. The WEIGHT was not: `theme {
# font "Ubuntu Bold 12" }` is parsed into Cfg.fontWeight and only four of a
# hundred and fifty-four elements read it, so configuring a bold font left
# almost the whole interface at Normal while a handful of hardcoded DemiBold
# headings stayed heavy. That is exactly "some do, some don't".
#
# A STATIC check, not a rendered one. The alternative is screenshotting each
# panel and comparing glyph shapes, which is fragile and blind to anything not
# currently on screen -- a menu row that only appears when a download fails is
# exactly where this drifts, and exactly where a screenshot never reaches.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

echo
echo "font lint"

report() { # report <property>
	python3 - "$HERE" "$1" <<'PY'
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location(
    "qmlscan", str(pathlib.Path(sys.argv[1], "contrib", "lib", "qmlscan.py")))
qs = importlib.util.module_from_spec(spec); spec.loader.exec_module(qs)
off, total = qs.scan(sys.argv[1], sys.argv[2])
print(total)
for f, line, kind, _, _ in off:
    print("%s:%d: %s" % (pathlib.Path(f).relative_to(sys.argv[1]), line, kind))
PY
}

for prop in font.family font.weight; do
	OUT="$(report "$prop")"
	TOTAL="$(printf '%s' "$OUT" | head -1)"
	MISSING="$(printf '%s\n' "$OUT" | tail -n +2 | sed '/^$/d')"

	# The premise, once per property. A scanner that matches nothing reports a
	# clean tree, and a clean tree is exactly what a broken scanner looks like --
	# which is not hypothetical here: the first version of this counted 47
	# offenders that were not offenders at all, and a later one counted zero
	# because a nested element's property satisfied its parent's check.
	if [ "${TOTAL:-0}" -gt 100 ]; then
		ok "the scanner sees the shell's text elements ($TOTAL, checking $prop)"
	else
		bad "the scanner found only $TOTAL text elements -- it is broken, not the tree"
	fi

	if [ -z "$MISSING" ]; then
		ok "every text element sets $prop itself"
	else
		bad "$(printf '%s\n' "$MISSING" | wc -l) text elements do not set $prop"
		printf '%s\n' "$MISSING" | sed 's/^/      /' | head -12
	fi
done

# Emphasis has to be relative to the configured weight, not a fixed DemiBold.
# A hardcoded heading weight is emphasis only while the body is lighter than it:
# configure a bold font and every heading comes out LIGHTER than the text under
# it, which is the opposite of what the constant was for.
HARDCODED="$(grep -rn 'font\.weight\s*:\s*Font\.' "$HERE/shell" 2>/dev/null || true)"
if [ -z "$HARDCODED" ]; then
	ok "no hardcoded font weights; emphasis is relative to the configured one"
else
	bad "$(printf '%s\n' "$HARDCODED" | wc -l) hardcoded font weights"
	printf '%s\n' "$HARDCODED" | sed "s|$HERE/||" | sed 's/^/      /' | head -10
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
