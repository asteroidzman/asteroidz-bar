#!/usr/bin/env bash
# palette-test.sh — the matugen palette page, driven with a real pointer.
#
# SANDBOXED, and that is the first thing to understand about this file. Applying
# on that page rewrites a template in ~/.config/matugen and then runs matugen for
# real, which re-renders every template on the machine and fires every post-hook
# -- waybar, kitty, and a compositor reload. A test that did that would re-theme
# the desktop it is running beside.
#
# So all three of the page's outside connections are redirected:
#
#   ASTEROIDZ_MATUGEN_CONF      the mapping file      -> the harness directory
#   ASTEROIDZ_MATUGEN_TEMPLATE  the template          -> the harness directory
#   ASTEROIDZ_MATUGEN_BIN       the matugen binary    -> a stub that records
#                                                        its arguments
#
# The stub is what makes "Apply re-renders the palette" checkable at all: the
# assertion is that matugen was invoked with the current wallpaper, which is a
# fact about a file the stub writes rather than about anything on screen.
set -u

REPO="${ASTEROIDZ_REPO:-$HOME/asteroidz}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[ -f "$HERE/build/libasteroidzbarplugin.so" ] || {
	echo "palette-test: not built -- meson setup build && meson compile -C build" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$REPO/contrib/lib/headless.sh"

hl_start
trap 'hl_stop' EXIT
kill "$HL_SWAYBG_PID" 2>/dev/null
[ -S "$HL_SIG" ] || { echo "palette-test: no IPC socket at $HL_SIG" >&2; exit 1; }

WORK="$HL_OUTDIR"
QMLROOT="$WORK/qml"
mkdir -p "$QMLROOT/Asteroidz/Bar"
cp "$HERE/build/libasteroidzbarplugin.so" "$QMLROOT/Asteroidz/Bar/"
cp "$HERE/plugin/qmldir" "$QMLROOT/Asteroidz/Bar/"

magick -size "${HL_WIDTH}x${HL_HEIGHT}" xc:'#9db8d8' "$WORK/wall.png"
printf 'folder=%s\nwallpaper=%s\nmode=fill\n' "$WORK" "$WORK/wall.png" \
	> "$WORK/wallpaper.conf"

# ── the sandbox ─────────────────────────────────────────────────────────────
MG_CONF="$WORK/matugen.conf"
MG_TEMPLATE="$WORK/asteroidz-colors.kdl"
MG_BIN="$WORK/matugen-stub"
MG_CALLS="$WORK/matugen-calls"
MG_TOML="$WORK/matugen-config.toml"
MG_OUT="$WORK/colors-out.kdl"

# A matugen config with somebody else's templates in it, because that is what the
# page will meet: this file themes rofi and kitty and waybar too, and a page that
# regenerated it would be a settings window that can lose your whole desktop
# theme.
cat > "$MG_TOML" <<'EOF'
[config]

[templates.rofi]
input_path = "/home/somebody/.config/matugen/templates/rofi.rasi"
output_path = "/home/somebody/.config/rofi/colors.rasi"
EOF
TOML_BEFORE="$(cat "$MG_TOML")"

# A template with a KNOWN mapping, so "seeded from the existing template" is
# checkable: `secondary` is not the default for any of the nine, so finding it in
# the mapping afterwards can only have come from here.
cat > "$MG_TEMPLATE" <<'EOF'
// ! Auto-generated file. Do not edit directly.
layout {
    border {
        color 0x{{colors.surface_container_high.default.hex | to_color | grayscale | format: "hex_stripped"}}ff
        focus-color 0x{{colors.secondary.default.hex_stripped}}ff
        urgent-color 0x{{colors.error.default.hex_stripped}}ff
        gradient { color2 0x{{colors.tertiary.default.hex_stripped}}ff }
    }
}
theme {
    bg-color 0x{{colors.surface_container_high.default.hex | to_color | grayscale | format: "hex_stripped"}}ff
    fg-color 0x{{colors.on_surface.default.hex_stripped}}ff
    focus-bg-color 0x{{colors.secondary.default.hex_stripped}}ff
    focus-fg-color 0x{{colors.on_secondary.default.hex_stripped}}ff
    urgent-color 0x{{colors.error.default.hex_stripped}}ff
}
EOF
TEMPLATE_BEFORE="$(md5sum "$MG_TEMPLATE" | cut -d' ' -f1)"

# The stub. It answers `--dry-run … --json` with a role list so the picker has
# something to offer, and records every other invocation.
cat > "$MG_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MG_CALLS"
for a in "\$@"; do
	if [ "\$a" = "--dry-run" ]; then
		printf '{"colors":{'
		first=1
		for r in primary on_primary secondary on_secondary tertiary error \\
		         on_surface surface_container_high surface_container_low \\
		         outline scrim; do
			[ \$first -eq 1 ] || printf ','
			first=0
			printf '"%s":{"default":"#112233"}' "\$r"
		done
		printf '}}\n'
		exit 0
	fi
done
exit 0
EOF
chmod +x "$MG_BIN"
: > "$MG_CALLS"

cat >> "$HL_CONFIG" <<'EOF'
theme { font "Ubuntu 16"; border-width 0; corner-radius 8; padding { x 16; y 4 } }
bar { enable false; height 48; position "top"; margin { x 8; y 9 }
	panel { enable true; radius 9; padding 12; blur true; shadow true }
	modules-left ""; modules-center ""; modules-right "display" }
EOF
hl_dispatch "reload_config" 1
sleep 1

dbus-run-session -- \
	env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
	HOME="$HOME" PATH="$PATH" \
	ASTEROIDZ_INSTANCE_SIGNATURE="$HL_SIG" \
	ASTEROIDZ_BAR_WALLPAPER_CONF="$WORK/wallpaper.conf" \
	ASTEROIDZ_MATUGEN_CONF="$MG_CONF" \
	ASTEROIDZ_MATUGEN_TEMPLATE="$MG_TEMPLATE" \
	ASTEROIDZ_MATUGEN_BIN="$MG_BIN" \
	ASTEROIDZ_MATUGEN_TOML="$MG_TOML" \
	ASTEROIDZ_COLORS_OUT="$MG_OUT" \
	ASTEROIDZ_BAR_SHELL="$HERE/shell/shell.qml" \
	ASTEROIDZ_BAR_QML="$QMLROOT" \
	"$HERE/bin/asteroidz-bar" > "$WORK/qs.log" 2>&1 &
QS=$!
sleep 8

shot() { grim -o "$HL_MON" "$WORK/$1.png" 2>/dev/null; }

if grep -qE 'is not a type|unavailable|Cannot override|set multiple times' \
		"$WORK/qs.log"; then
	bad "the shell loads without QML errors"
	grep -E 'is not a type|unavailable|Cannot override|set multiple times' \
		"$WORK/qs.log" | head -5 | sed 's/^/       /'
else
	ok "the shell loads without QML errors"
fi

# ── open the settings window and reach the palette page ─────────────────────
PILL_X=$((HL_WIDTH - 8 - 12 - 18))
PILL_Y=$((9 + 24))
hl_move "$PILL_X" "$PILL_Y"; sleep 1
hl_click "$PILL_X" "$PILL_Y"; sleep 3

ACCENT="$(hl_get "get bar-config" | python3 -c '
import json, sys
c = (json.load(sys.stdin).get("theme") or {}).get("focus_bg")
if isinstance(c, list) and len(c) >= 3:
    print("#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c[:3]))
' 2>/dev/null)"

WIN="$(hl_get "get all-clients" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("clients", []):
    if c.get("title") == "asteroidz settings":
        print(c["x"], c["y"], c["width"], c["height"]); break
')"
read -r WX WY WW WH <<<"${WIN:-0 0 0 0}"
if [ "${WW:-0}" -gt 300 ]; then
	ok "the settings window is open (${WW}x${WH})"
else
	bad "the settings window is open"
fi
shot settings

# The sidebar row pitch, from the one accent pill.
read -r SB_TOP SB_H <<<"$(python3 - "$WORK/settings.png" "${ACCENT:-#000000}" \
		"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
r = wx + max(int(ww * 0.22), 170)
rows = [y for y in range(wy, wy + wh)
        if sum(1 for x in range(wx, r)
               if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))) > 40]
if not rows:
    print("0 0"); raise SystemExit
groups = []
for y in rows:
    if groups and y - groups[-1][-1] <= 2:
        groups[-1].append(y)
    else:
        groups.append([y])
grp = max(groups, key=len)
print(grp[0], grp[-1] - grp[0] + 1)
PY
)"

# All settings, one row per option group, then Displays, Wallpaper, rules,
# binds, palette. A left click on the pill selects "All settings", so the accent
# pill the scan above found is row 0.
NGROUPS="$(hl_get "get config-schema" | jq '.groups | length')"
PALETTE_ROW=$((5 + NGROUPS))
PALETTE_Y=$((SB_TOP + PALETTE_ROW * (SB_H + 2) + SB_H / 2))
hl_move $((WX + 60)) "$PALETTE_Y"; sleep 1
hl_click $((WX + 60)) "$PALETTE_Y"; sleep 3
shot palette

# ── the assertions ──────────────────────────────────────────────────────────

# Seeding. The template says `secondary` for the focused colours, which is not
# the default for any of the nine -- so the page can only know it by having read
# the template that was already there. Without this, a first Apply would replace
# a tuned template with defaults.
if grep -q "colors.secondary" "$MG_TEMPLATE"; then
	ok "the sandboxed template is the one in play"
else
	bad "the sandboxed template is the one in play"
fi

# Nothing is written before Apply. A settings page that rewrites a file on open
# is one you cannot open to look at.
if [ "$(md5sum "$MG_TEMPLATE" | cut -d' ' -f1)" = "$TEMPLATE_BEFORE" ]; then
	ok "opening the page writes nothing"
else
	bad "opening the page writes nothing"
fi
if [ ! -s "$MG_CALLS" ] || ! grep -qv -- "--dry-run" "$MG_CALLS"; then
	ok "...and runs matugen only to ask for the role list"
else
	bad "...and runs matugen only to ask for the role list"
	sed 's/^/       /' "$MG_CALLS"
fi

# The page is populated: nine rows, each with a role picker. Measured as ink,
# the same way settings-test does, against the page's own background.
INK="$(python3 - "$WORK/palette.png" "$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from collections import Counter
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
wx, wy, ww, wh = (int(v) for v in sys.argv[2:6])
sample = [px[x, y] for y in range(wy, wy + wh, 2) for x in range(wx, wx + ww, 2)]
bg = Counter(sample).most_common(1)[0][0]
print(sum(1 for c in sample if any(abs(a - b) > 12 for a, b in zip(c, bg))))
PY
)"
if [ "${INK:-0}" -gt 3000 ]; then
	ok "the palette page is populated (${INK} ink px)"
else
	bad "the palette page is populated (${INK} ink px)"
fi

# ── Apply ───────────────────────────────────────────────────────────────────
#
# The button is the lowest small control on the page.
# NO speculative Apply click before making a change.
#
# There was one, asserting that Apply is inert when nothing is dirty. It could
# never fail usefully -- a click that misses looks identical to a button that
# refuses -- and it did worse than nothing: the locator found a role PICKER,
# the click opened its dropdown, and every position measured afterwards was
# displaced by the open list. Three runs went into reading that as "Apply is
# broken". The gating is visible instead: Apply is drawn accent only when there is
# something to apply, which the assertion below depends on.

# Change something: the first row's ownership toggle. Turning a colour OFF is the
# interesting direction -- it has to disappear from the template, which is what
# hands it back to the user's own config.
#
# Found by COLOUR, not by arithmetic over the page's layout. All nine ownership
# toggles start on, so they are accent-coloured, and the topmost one in the
# right-hand column is the first row's. Computing it as "header height plus an
# intro paragraph" was 21 pixels high and clicked nothing -- and a missed toggle
# looks exactly like an Apply that refused, which cost a run to tell apart.
read -r TOGGLE_X TOGGLE_Y <<<"$(python3 - "$WORK/palette.png" "${ACCENT:-#000000}" \
		"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# The right-hand edge of the content area, past every picker and label.
l = wx + int(ww * 0.90)
r = wx + ww - 4
best = None
for y in range(wy + 60, wy + wh - 60):
    xs = [x for x in range(l, r)
          if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))]
    if len(xs) >= 20:
        best = (y, sum(xs) // len(xs))
        break
print(f"{best[1]} {best[0] + 10}" if best else "0 0")
PY
)"
if [ "${TOGGLE_X:-0}" -gt 0 ]; then
	ok "the first row's ownership toggle was located (${TOGGLE_X},${TOGGLE_Y})"
else
	bad "the first row's ownership toggle was located"
fi
hl_move "$TOGGLE_X" "$TOGGLE_Y"; sleep 1
hl_click "$TOGGLE_X" "$TOGGLE_Y"; sleep 2

# Apply MOVED, and is now findable by COLOUR instead of by shape. Two things
# happened at once: turning a colour off hides its role picker, so the page is a
# row shorter and everything below slides up; and Apply became accent-coloured,
# because SmallButton draws itself accent when `active` and Apply is active
# exactly when there is something to apply.
#
# That second fact is the better locator. Hunting for "the lowest flat block of a
# plausible button width" found a picker instead and clicked nothing, which reads
# exactly like an Apply that refused -- three runs of looking at the wrong half of
# the problem.
shot palette_changed
read -r AP_X AP_Y <<<"$(python3 - "$WORK/palette_changed.png" "${ACCENT:-#000000}" \
		"$WX" "$WY" "$WW" "$WH" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.load()
acc = sys.argv[2].lstrip("#")
wx, wy, ww, wh = (int(v) for v in sys.argv[3:7])
if len(acc) != 6:
    print("0 0"); raise SystemExit
want = tuple(int(acc[i:i + 2], 16) for i in (0, 2, 4))
# The LEFT part of the content area only. Apply is accent when there is something
# to apply -- and so is every ownership toggle that is on, but those sit hard
# against the right edge while the button row is left-aligned. The side is what
# tells them apart; "lowest accent block" alone finds a toggle.
content_l = wx + max(int(ww * 0.22), 170) + 10
l = content_l
r = content_l + int((wx + ww - content_l) * 0.35)
runs = []
for y in range(wy + 60, wy + wh - 10):
    xs = [x for x in range(l, r)
          if all(abs(a - b) <= 14 for a, b in zip(px[x, y], want))]
    if len(xs) >= 40:
        runs.append((y, sum(xs) // len(xs)))
if not runs:
    print("0 0"); raise SystemExit
groups = []
for y, cx in runs:
    if groups and y - groups[-1][-1][0] <= 3:
        groups[-1].append((y, cx))
    else:
        groups.append([(y, cx)])
grp = groups[-1]
mid = grp[len(grp) // 2]
print(mid[1], mid[0])
PY
)"
if [ "${AP_X:-0}" -gt 0 ]; then
	ok "Apply turned accent once there was something to apply (${AP_X},${AP_Y})"
else
	bad "Apply turned accent once there was something to apply"
fi
hl_move "$AP_X" "$AP_Y"; sleep 1
hl_click "$AP_X" "$AP_Y"; sleep 3

if [ "$(md5sum "$MG_TEMPLATE" | cut -d' ' -f1)" != "$TEMPLATE_BEFORE" ]; then
	ok "Apply rewrites the template"
else
	bad "Apply rewrites the template"
fi
if [ -f "$MG_TEMPLATE.bak" ] && grep -q "colors.secondary" "$MG_TEMPLATE.bak"; then
	ok "...keeping the previous one as .bak"
else
	bad "...keeping the previous one as .bak"
fi
# The mapping file records the choice, so it survives a restart even if matugen
# itself was missing.
if [ -f "$MG_CONF" ] && grep -q "=off" "$MG_CONF"; then
	ok "...and the mapping records the colour as hand-set"
else
	bad "...and the mapping records the colour as hand-set"
	[ -f "$MG_CONF" ] && sed 's/^/       /' "$MG_CONF"
fi
# The template's STRUCTURE has to be valid KDL, with the expressions standing in
# for the colours they will become. asteroidz sources the rendered file
# unconditionally, so a template whose braces do not balance takes the user's
# whole config down at the next wallpaper change -- and that failure lands at a
# moment with nothing to do with this page.
#
# The template itself is not KDL and never will be: `{{ ... }}` is not a value.
# Substituting a literal is what makes the question askable at all.
sed -E 's/0x\{\{[^}]*\}\}ff/0x000000ff/g' "$MG_TEMPLATE" > "$WORK/rendered.kdl"
if "$REPO/build/asteroidz" -p -c "$WORK/rendered.kdl" 2>&1 | grep -q 'config OK'; then
	ok "...and what it renders to is valid KDL"
else
	bad "...and what it renders to is valid KDL"
	"$REPO/build/asteroidz" -p -c "$WORK/rendered.kdl" 2>&1 | head -4 | sed 's/^/       /'
fi
# And matugen was actually asked to re-render, with the current wallpaper.
if grep -q "image $WORK/wall.png" "$MG_CALLS"; then
	ok "...and matugen was re-run against the current wallpaper"
else
	bad "...and matugen was re-run against the current wallpaper"
	sed 's/^/       /' "$MG_CALLS"
fi

# ── the generation settings ─────────────────────────────────────────────────
#
# The scheme flags have to be ON that invocation. They are CLI-only: matugen
# accepts `type`/`mode` under [config] in config.toml WITHOUT ERROR and then
# ignores them, so a caller that omits them silently gets scheme-tonal-spot.
#
# Which is exactly what this page used to do. A wallpaper script running
# `-t scheme-fidelity` and an Apply running bare disagree on 39 of matugen's 50
# roles, so pressing Apply retoned every themed application on the machine and
# the next wallpaper change put them all back -- with nothing on screen, in
# either direction, to say so.
RENDER_CALL="$(grep "image $WORK/wall.png" "$MG_CALLS" | tail -1)"
for flag in "-t" "-m" "--contrast" "--prefer"; do
	if printf '%s ' "$RENDER_CALL" | grep -q -- " $flag "; then
		ok "...carrying $flag, so the scheme is not silently the default"
	else
		bad "...carrying $flag, so the scheme is not silently the default"
		printf '       %s\n' "$RENDER_CALL"
	fi
done

# --prefer is the one flag that is not a preference at all. Given an image with
# several candidate source colours matugen ASKS which to use, and with nothing on
# a terminal it exits 1 instead of choosing:
#
#   Multiple source colors found, no preference was inputted, and a terminal was
#   not detected. Use --prefer=PREFERENCE to find suitable colors without needing
#   user input.
#
# A settings window never has a terminal, so leaving it out is not a default, it
# is a guaranteed failure -- and not only on busy photographs: a 64x64 flat PNG
# fails identically. The page shipped with "(default)" in that dropdown, which
# meant "omit the flag", so changing the scheme type and pressing Apply reported
# `matugen failed (exit 1)`.
if printf '%s ' "$RENDER_CALL" | grep -qE -- ' --prefer +[a-z]'; then
	ok "...with a real --prefer value, never an omitted one"
else
	bad "...with a real --prefer value, never an omitted one"
	printf '       %s\n' "$RENDER_CALL"
fi

# Recorded in the mapping file too, because the wallpaper script reads it to
# pass the same values. Two callers, one source of truth.
if grep -q '^scheme\.type=' "$MG_CONF" && grep -q '^scheme\.mode=' "$MG_CONF"; then
	ok "...and recorded for the wallpaper script to read back"
else
	bad "...and recorded for the wallpaper script to read back"
	sed 's/^/       /' "$MG_CONF"
fi

# ── the wiring ──────────────────────────────────────────────────────────────
#
# A template matugen has not been told about renders nothing, so Apply also adds
# the entry. That write is into the user's own matugen config -- the file that
# themes every other application on the machine -- so what it must NOT do matters
# as much as what it must.
if grep -q "asteroidz-colors.kdl" "$MG_TOML"; then
	ok "Apply wires the template into matugen's config"
else
	bad "Apply wires the template into matugen's config"
fi
if grep -q "post_hook" "$MG_TOML"; then
	ok "...with the reload hook, without which nothing reaches the screen"
else
	bad "...with the reload hook, without which nothing reaches the screen"
fi
# The rest of the file survives. APPENDED, never regenerated.
if grep -q "templates.rofi" "$MG_TOML" && grep -q "somebody/.config/rofi" "$MG_TOML"; then
	ok "...leaving the templates that were already there alone"
else
	bad "...leaving the templates that were already there alone"
	sed 's/^/       /' "$MG_TOML"
fi
if [ -f "$MG_TOML.bak" ] && [ "$(cat "$MG_TOML.bak")" = "$TOML_BEFORE" ]; then
	ok "...and keeping the previous contents as .bak"
else
	bad "...and keeping the previous contents as .bak"
fi
# It is still TOML. A settings page that corrupts matugen's config breaks every
# themed application at once, and the next wallpaper change is where you find out.
if command -v python3 >/dev/null && python3 -c "
import sys, tomllib
tomllib.load(open('$MG_TOML','rb'))
" 2>/dev/null; then
	ok "...and the result still parses as TOML"
else
	bad "...and the result still parses as TOML"
	sed 's/^/       /' "$MG_TOML"
fi
# Idempotent: a second Apply must not add a second entry rendering the same
# template twice.
BEFORE_N="$(grep -c "asteroidz-colors.kdl" "$MG_TOML")"
hl_move "$TOGGLE_X" "$TOGGLE_Y"; sleep 1
hl_click "$TOGGLE_X" "$TOGGLE_Y"; sleep 1
shot palette_again
hl_move "$AP_X" "$AP_Y"; sleep 1
hl_click "$AP_X" "$AP_Y"; sleep 3
if [ "$(grep -c "asteroidz-colors.kdl" "$MG_TOML")" = "$BEFORE_N" ]; then
	ok "...and a second Apply does not add it twice"
else
	bad "...and a second Apply does not add it twice ($BEFORE_N -> $(grep -c "asteroidz-colors.kdl" "$MG_TOML"))"
fi

cp "$WORK"/palette*.png "${ASTEROIDZ_SHOT_DIR:-/tmp}"/ 2>/dev/null || true
kill "$QS" 2>/dev/null
wait "$QS" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
