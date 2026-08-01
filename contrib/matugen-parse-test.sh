#!/usr/bin/env bash
# matugen-parse-test.sh — the config.toml reading and filtering, without a screen.
#
# palette-test.sh drives the page with a real pointer and is the right tool for
# "does Apply do the thing". It is a poor tool for this: the interesting inputs
# here are shapes of somebody's config.toml -- a comment between sections, a
# section with no output_path, every template switched off -- and reaching those
# through a pointer means nine clicks and a screenshot each.
#
# So this runs the two functions DIRECTLY, by pulling their source out of the
# .qml file and evaluating it. That matters more than it sounds: the alternative
# is a second implementation in the test, which agrees with what I meant rather
# than with what shipped, and stops agreeing the moment either drifts.
#
# Usage: matugen-parse-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QML="$HERE/shell/settings/Matugen.qml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v node >/dev/null 2>&1 || {
	echo "matugen-parse-test: needs node to evaluate the QML functions" >&2
	exit 77
}
[ -f "$QML" ] || { echo "matugen-parse-test: no $QML" >&2; exit 1; }

# A config shaped like a real one: a [config] block, a leading comment, sections
# whose keys are in different orders, one with no output_path, and a post_hook
# containing a bracket -- which a line-based section splitter can mistake for a
# section header if it is careless about where it anchors.
cat > "$WORK/config.toml" <<'TOML'
# my matugen config
[config]
reload_apps = true

# rofi: the launcher
[templates.rofi]
input_path = "~/.config/matugen/templates/rofi.rasi"
output_path = "~/.config/rofi/raf.rasi"

[templates.kitty]
output_path = "~/.config/kitty/theme.conf"
input_path = "~/.config/matugen/templates/kitty.conf"
post_hook = "kill -USR1 $(pgrep kitty) # [not a section]"

# btop: no live reload
[templates.btop]
input_path = "~/.config/matugen/templates/btop.theme"
output_path = "~/.config/btop/themes/matugen.theme"

[templates.noout]
input_path = "~/.config/matugen/templates/x"
TOML

node - "$QML" "$WORK/config.toml" "$WORK" <<'JS' > "$WORK/out" 2>"$WORK/err"
const fs = require("fs");
const [qmlPath, cfgPath, work] = process.argv.slice(2);
const src = fs.readFileSync(qmlPath, "utf8");

function extract(name) {
  const start = src.indexOf("    function " + name + "(");
  if (start < 0) throw new Error("not found: " + name);
  let i = src.indexOf("{", start), depth = 0, j = i;
  for (; j < src.length; j++) {
    if (src[j] === "{") depth++;
    else if (src[j] === "}") { depth--; if (depth === 0) break; }
  }
  return src.slice(start, j + 1).replace(/^\s*function /, "function ");
}

let disabled = new Set();
const templateEnabled = n => !disabled.has(n);
const parseTemplates = eval("(" + extract("parseTemplates") + ")");
const filteredToml   = eval("(" + extract("filteredToml") + ")");

// The default scheme, read out of the singleton rather than restated here, so
// this checks what ships rather than what I remember writing.
const schemeDefault = eval(
  "(" + /property var scheme:\s*\(\{([\s\S]*?)\}\)/.exec(src)[0]
          .replace(/^property var scheme:\s*/, "") + ")");
let scheme = schemeDefault;
const schemeArgs = eval("(" + extract("schemeArgs") + ")");

const text = fs.readFileSync(cfgPath, "utf8");
const t = parseTemplates(text);
const r = {};
r.names = t.map(x => x.name).join(",");
r.kittyOut = (t.find(x => x.name === "kitty") || {}).output;
r.nooutIsEmpty = (t.find(x => x.name === "noout") || {}).output === "";

disabled = new Set(["btop"]);
const one = filteredToml(text);
fs.writeFileSync(work + "/one.toml", one);
r.oneHasConfig = /^\s*\[config\]/m.test(one);
r.oneCount = (one.match(/^\s*\[templates\./gm) || []).length;
r.oneDroppedBtop = !/\[templates\.btop\]/.test(one);
r.oneKeptPostHook = /post_hook/.test(one);

disabled = new Set(t.map(x => x.name));
const none = filteredToml(text);
fs.writeFileSync(work + "/none.toml", none);
r.noneCount = (none.match(/^\s*\[templates\./gm) || []).length;

// The flags, written out for the shell to hand to a real matugen.
fs.writeFileSync(work + "/args", schemeArgs().join("\n") + "\n");
// And with prefer emptied, which is what a hand-edited matugen.conf can produce.
scheme = Object.assign({}, schemeDefault, { prefer: "" });
fs.writeFileSync(work + "/args-noprefer", schemeArgs().join("\n") + "\n");
scheme = schemeDefault;

console.log(JSON.stringify(r));
JS

if [ ! -s "$WORK/out" ]; then
	bad "the QML functions could be evaluated"
	sed 's/^/       /' "$WORK/err" | head -5
	echo; echo "  $PASS passed, $((FAIL+1)) failed"; exit 1
fi
ok "the QML functions could be evaluated"

get() { python3 -c "import json,sys; print(json.load(open('$WORK/out')).get('$1'))"; }

[ "$(get names)" = "rofi,kitty,btop,noout" ] \
	&& ok "every [templates.*] section is found, in order" \
	|| bad "every [templates.*] section is found, in order (got $(get names))"

# The bracket inside a post_hook must not be read as a section header. If it is,
# every key after it lands in the wrong section and the filter drops the wrong
# lines -- silently, because the result is still valid TOML.
[ "$(get kittyOut)" = "~/.config/kitty/theme.conf" ] \
	&& ok "...with output_path read regardless of key order" \
	|| bad "...with output_path read regardless of key order (got $(get kittyOut))"

[ "$(get nooutIsEmpty)" = "True" ] \
	&& ok "...and a section with no output_path is still listed" \
	|| bad "...and a section with no output_path is still listed"

[ "$(get oneHasConfig)" = "True" ] \
	&& ok "filtering keeps [config], which matugen requires" \
	|| bad "filtering keeps [config], which matugen requires"

[ "$(get oneCount)" = "3" ] \
	&& ok "...and the three still-enabled templates" \
	|| bad "...and the three still-enabled templates (got $(get oneCount))"

[ "$(get oneDroppedBtop)" = "True" ] \
	&& ok "...while the disabled one is gone" \
	|| bad "...while the disabled one is gone"

[ "$(get oneKeptPostHook)" = "True" ] \
	&& ok "...and a surviving section keeps all of its keys" \
	|| bad "...and a surviving section keeps all of its keys"

# The filtered file is fed to a real matugen, because "valid TOML" is not the
# bar -- matugen has its own required fields and rejects a config that has none
# of them with a parse error pointing at line 1.
if command -v matugen >/dev/null 2>&1; then
	if matugen -c "$WORK/one.toml" --dry-run -q color hex "#3f6ded" \
			--json hex >/dev/null 2>&1; then
		ok "...and matugen accepts the result"
	else
		bad "...and matugen accepts the result"
		matugen -c "$WORK/one.toml" --dry-run color hex "#3f6ded" 2>&1 \
			| head -4 | sed 's/^/       /'
	fi

	# The degenerate case, asserted from the other side: this config is REJECTED,
	# which is why Matugen.qml must catch "everything off" itself instead of
	# handing it over and reporting matugen's TOML error as the outcome.
	if matugen -c "$WORK/none.toml" --dry-run -q color hex "#3f6ded" \
			--json hex >/dev/null 2>&1; then
		bad "a config with no templates is rejected by matugen (it was accepted)"
	else
		ok "a config with no templates is rejected by matugen"
	fi
else
	echo "  --   matugen not installed; skipped the two acceptance checks"
fi

[ "$(get noneCount)" = "0" ] \
	&& ok "...and switching everything off is what produces it" \
	|| bad "...and switching everything off is what produces it"

# So the page must refuse that case before it runs anything.
if grep -q "off.length === templates.length" "$QML"; then
	ok "Matugen.qml refuses to render when everything is off"
else
	bad "Matugen.qml refuses to render when everything is off"
fi

# ── the flags, against a real matugen ───────────────────────────────────────
#
# This is the check palette-test.sh structurally cannot make. It drives a STUB
# matugen -- it has to, since a real one would re-theme the machine the test runs
# on -- so it can assert which flags were passed and nothing about whether they
# work. They did not: the page shipped with "(default)" in the Prefer dropdown,
# meaning "omit --prefer", and matugen answers that by trying to ASK which source
# colour to use. With no terminal it exits 1. Changing the scheme type and
# pressing Apply reported `matugen failed (exit 1)` and nothing else.
#
# Run against a flat single-colour PNG on purpose. The obvious guess is that this
# needs a busy photograph to reproduce; it does not, which is why the smallest
# possible image is the right fixture.
if command -v matugen >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
	python3 -c "
from PIL import Image
Image.new('RGB', (64, 64), (63, 109, 237)).save('$WORK/flat.png')
" 2>/dev/null
	if [ -f "$WORK/flat.png" ]; then
		mapfile -t ARGS < "$WORK/args"
		if matugen -c "$WORK/one.toml" --dry-run image "$WORK/flat.png" \
				"${ARGS[@]}" >/dev/null 2>&1; then
			ok "the flags the page builds are accepted by a real matugen"
		else
			bad "the flags the page builds are accepted by a real matugen"
			printf '       args: %s\n' "${ARGS[*]}"
			matugen -c "$WORK/one.toml" --dry-run image "$WORK/flat.png" \
				"${ARGS[@]}" 2>&1 | sed 's/^/       /' | head -5
		fi

		# The other half: an empty prefer must not become an omitted flag. If it
		# does this fails, which is the regression that shipped.
		mapfile -t NOPREF < "$WORK/args-noprefer"
		if matugen -c "$WORK/one.toml" --dry-run image "$WORK/flat.png" \
				"${NOPREF[@]}" >/dev/null 2>&1; then
			ok "...and an empty prefer falls back rather than dropping the flag"
		else
			bad "...and an empty prefer falls back rather than dropping the flag"
			printf '       args: %s\n' "${NOPREF[*]}"
		fi
	else
		echo "  --   no PIL; skipped the real-matugen flag checks"
	fi
else
	echo "  --   matugen or python3 missing; skipped the real-matugen flag checks"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
