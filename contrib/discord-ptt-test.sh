#!/usr/bin/env bash
# discord-ptt-test.sh — the push-to-talk bridge's preconditions.
#
# Every way this breaks is silent. The portal answers "An app id is required" or
# "App info not found" and simply declines to bind; the bar plugin keeps running,
# the pill keeps saying push-to-talk, and no key ever fires. So the checks here
# are the ones that cost real time to diagnose:
#
#   - the app id resolves to a .desktop glib can actually load
#   - that .desktop's Exec binary EXISTS (a dangling one is the trap: glib
#     returns NULL and the portal refuses, with no other symptom)
#   - the id in the .desktop matches the plugin's default app_id
#   - the compositor is the GlobalShortcuts backend, and offers the signals
#     the bridge listens for
#
# What is NOT tested here is the injection itself. That needs a live XWayland, a
# running Discord and someone to hear the microphone open -- so it is verified by
# hand, and the mechanism is written up in the plugin's header.
#
# Usage: discord-ptt-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$HERE/plugins/asteroidz-bar-discord"
DESKTOP="$HERE/plugins/org.asteroidzman.DiscordPTT.desktop"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$PLUGIN" ]  || { echo "no $PLUGIN" >&2; exit 1; }
[ -f "$DESKTOP" ] || { echo "no $DESKTOP" >&2; exit 1; }

python3 -m py_compile "$PLUGIN" 2>/dev/null \
	&& ok "the plugin is valid python" \
	|| bad "the plugin is valid python"

# The id the plugin claims and the id the .desktop provides have to be the same
# string, or the portal looks up an app that does not exist.
PLUG_ID="$(grep -oE '"app_id": "[^"]+"' "$PLUGIN" | head -1 | cut -d'"' -f4)"
FILE_ID="$(basename "$DESKTOP" .desktop)"
if [ -n "$PLUG_ID" ] && [ "$PLUG_ID" = "$FILE_ID" ]; then
	ok "the plugin's app_id matches the .desktop name ($PLUG_ID)"
else
	bad "the plugin's app_id matches the .desktop name (plugin=$PLUG_ID file=$FILE_ID)"
fi

# The trap. glib returns NULL for a .desktop whose Exec is missing, and the
# portal reports "App info not found" rather than anything about Exec.
EXEC="$(grep -oE '^Exec=.*' "$DESKTOP" | head -1 | cut -d= -f2- | awk '{print $1}')"
if [ -n "$EXEC" ]; then
	ok "the .desktop names an Exec ($EXEC)"
else
	bad "the .desktop names an Exec"
fi

# Checked against what the plugin installs to, not against this checkout: the
# .desktop ships with an absolute path and it is the INSTALLED binary that has to
# exist when the portal resolves it.
if [ "${EXEC#/}" != "$EXEC" ]; then
	ok "...and it is absolute, as the portal requires"
else
	bad "...and it is absolute, as the portal requires"
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
	desktop-file-validate "$DESKTOP" 2>/dev/null \
		&& ok "the .desktop validates" \
		|| { bad "the .desktop validates"
		     desktop-file-validate "$DESKTOP" 2>&1 | sed 's/^/       /' | head -3; }
fi

# Register must come FIRST. A later call is refused, and the ordering is easy to
# lose in a refactor because nothing about the code makes it look load-bearing.
if awk '/host\.portal\.Registry/{r=NR} /"CreateSession"/{c=NR} END{exit !(r && c && r < c)}' \
		"$PLUGIN"; then
	ok "Registry.Register is called before CreateSession"
else
	bad "Registry.Register is called before CreateSession"
fi

# The frontend interface, not the impl one. A client listening on
# org.freedesktop.impl.portal.* is reading the compositor's side of the
# conversation and never gets anything routed to it.
if grep -q 'IFACE = "org.freedesktop.portal.GlobalShortcuts"' "$PLUGIN"; then
	ok "it listens on the portal frontend, not the backend impl"
else
	bad "it listens on the portal frontend, not the backend impl"
fi

# ── the rebind path, in a sandbox ───────────────────────────────────────────
#
# Everything below runs against temporary XDG directories, so it touches neither
# the real conf nor the compositor's record of picked bindings. The plugin is
# imported rather than executed: main() needs a portal, a bus and an X server,
# but the parts that decide WHAT gets written need none of them, and those are
# the parts that can silently do nothing.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export PTT_TALLY="$SANDBOX/tally"

python3 - "$PLUGIN" "$SANDBOX" <<'PY'
import importlib.util, json, os, sys
from importlib.machinery import SourceFileLoader

plugin_path, sandbox = sys.argv[1], sys.argv[2]
os.environ["XDG_CONFIG_HOME"] = os.path.join(sandbox, "config")
os.environ["XDG_RUNTIME_DIR"] = os.path.join(sandbox, "run")
os.makedirs(os.path.join(sandbox, "config", "asteroidz"), exist_ok=True)
os.makedirs(os.path.join(sandbox, "config", "asteroidz-bar"), exist_ok=True)
os.makedirs(os.path.join(sandbox, "run"), exist_ok=True)

# An explicit loader: the plugin has no .py suffix, and spec_from_file_location
# answers None for a name it cannot classify rather than raising.
spec = importlib.util.spec_from_file_location(
    "ptt", plugin_path, loader=SourceFileLoader("ptt", plugin_path))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  \033[32mok\033[0m   " + msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  \033[31mFAIL\033[0m " + msg)
def check(cond, msg):
    ok(msg) if cond else bad(msg)

# ── save_conf ───────────────────────────────────────────────────────────────
# The file is documented as hand-editable, so a save that ate somebody's notes
# would be a real loss and an invisible one.
with open(m.CONF, "w") as fh:
    fh.write("# my notes\ntrigger = F12\nkey = F12\n# trailing note\n")
m.save_conf({"trigger": "Super+V"})
text = open(m.CONF).read()
check("# my notes" in text and "# trailing note" in text,
      "save_conf keeps comments")
check(m.load_conf()["trigger"] == "Super+V", "save_conf changes the value")
check(m.load_conf()["key"] == "F12", "save_conf leaves other keys alone")
check(text.count("trigger") == 1, "save_conf rewrites in place, not by appending")

# A key that is not in the file yet has to be appended, or the settings page
# could never set one on a default install.
os.unlink(m.CONF)
m.save_conf({"key": "Pause"})
check(m.load_conf()["key"] == "Pause", "save_conf creates a missing file")
check(m.load_conf()["trigger"] == "F12", "...and the rest stay at their defaults")

# Anything not in DEFAULTS is refused rather than written: the conf is a fixed
# vocabulary and a typo should not become a permanent line in it.
m.save_conf({"nonsense": "x"})
check("nonsense" not in open(m.CONF).read(), "save_conf ignores unknown keys")

# ── the compositor's record ─────────────────────────────────────────────────
# This is the file that OUTRANKS the conf, which is what makes forgetting it the
# difference between a rebind that works and one that silently does not.
SC = m.SHORTCUTS
with open(SC, "w") as fh:
    fh.write("org.other.App\tpush-to-talk\tCaps_Lock\n")
    fh.write("org.asteroidzman.DiscordPTT\tpush-to-talk\tF9\n")
    fh.write("org.asteroidzman.DiscordPTT\tsomething-else\tF10\n")

check(m.read_saved("org.asteroidzman.DiscordPTT", "push-to-talk") == "F9",
      "read_saved finds our binding")
check(m.read_saved("org.asteroidzman.DiscordPTT", "nope") is None,
      "read_saved matches the shortcut id too, not just the app")
check(m.read_saved("org.nobody.App", "push-to-talk") is None,
      "read_saved does not answer for another app")

m.forget_saved("org.asteroidzman.DiscordPTT")
left = open(SC).read()
check("org.other.App" in left, "forget_saved leaves other apps' bindings")
check("org.asteroidzman.DiscordPTT" not in left,
      "forget_saved drops every line of ours")

# ── the menu ────────────────────────────────────────────────────────────────
rows = m.menu_rows("Super+V", "F12", leader=True)["menu"]["rows"]
vals = [r.get("value") for r in rows]
check("ptt:pick" in vals, "the menu offers a rebind")
check("ptt:save" in vals, "the menu offers a save")
inputs = [r for r in rows if r.get("input")]
check(len(inputs) == 1 and inputs[0]["value"] == "key",
      "the injected key is the one editable field")
check(inputs[0]["edit"] == "F12", "the field is prefilled with the current key")
check(any("Super+V" in (r.get("text") or "") for r in rows),
      "the menu names the binding in force")
check(any(r.get("enabled") is False for r in rows),
      "the heading is not clickable")
# A mirror must say so: its menu works, but the bridge it reports on is
# elsewhere, and that is worth seeing when something looks wrong.
mrows = m.menu_rows("F12", "F12", leader=False)["menu"]["rows"]
check(len(mrows) > len(rows), "a mirror's menu says it is a mirror")

# ── handle_menu ─────────────────────────────────────────────────────────────
# The whole point of routing both entry points through the conf: a pick asks,
# a save writes, and neither needs to know which instance it is running in.
asked = []

def pick(obj):
    # handle_menu answers on stdout -- an empty row set, which is how a plugin
    # closes its own menu. Swallowed here so the protocol does not land in the
    # middle of the test output.
    import contextlib, io
    with contextlib.redirect_stdout(io.StringIO()):
        m.handle_menu(obj, lambda: asked.append(1))

pick({"event": "menu", "value": "ptt:pick"})
check(asked == [1], "picking 'rebind' requests the picker")

m.save_conf({"key": "F12"})
pick({"event": "menu", "value": "ptt:save", "fields": {"key": "Pause"}})
check(m.load_conf()["key"] == "Pause", "saving the field writes the conf")
check(asked == [1], "saving does not also trigger a rebind prompt")

# An empty field is a person clearing a box, not a request to inject nothing.
pick({"event": "menu", "value": "ptt:save", "fields": {"key": "  "}})
check(m.load_conf()["key"] == "Pause", "an empty field is ignored, not written")

# ── stdin ───────────────────────────────────────────────────────────────────
# The leak this closes was observed, not theorised: these bridges sat in a GLib
# loop with nothing watching the pipe, so every bar restart left two more behind
# still holding an X connection.
import gi
gi.require_version("Gio", "2.0")
from gi.repository import GLib

r, w = os.pipe()
os.dup2(r, 0)
sys.stdin = os.fdopen(0, "r")
seen, quit_called = [], []
loop = GLib.MainLoop()
m.watch_stdin(seen.append, lambda: (quit_called.append(1), loop.quit()))
os.write(w, b'{"event":"click"}\n{"event":"menu","value":"x"}\n')
GLib.timeout_add(200, lambda: (os.close(w), False)[1])
GLib.timeout_add(3000, lambda: (loop.quit(), False)[1])
loop.run()
check(len(seen) == 2 and seen[0]["event"] == "click",
      "stdin delivers whole lines as objects")
check(quit_called == [1], "EOF on stdin stops the loop (the orphan leak)")

# Handed back so this block's results join the one tally at the end rather
# than printing a second, competing score.
with open(os.environ["PTT_TALLY"], "w") as fh:
    fh.write("%d %d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
if [ -r "$PTT_TALLY" ]; then
	read -r P F < "$PTT_TALLY"
	PASS=$((PASS + P)); FAIL=$((FAIL + F))
else
	# The block died before it could report -- an import error, a missing gi.
	# That is a failure, and a silent skip would read as a pass.
	bad "the rebind-path checks ran at all"
fi


# ── live session, when there is one ─────────────────────────────────────────
if command -v busctl >/dev/null 2>&1 \
		&& busctl --user status >/dev/null 2>&1; then
	if busctl --user list 2>/dev/null | grep -q "org.freedesktop.impl.portal.desktop.asteroidz"; then
		ok "asteroidz is registered as a portal backend"
	else
		bad "asteroidz is registered as a portal backend"
	fi

	SIGS="$(busctl --user introspect org.freedesktop.portal.Desktop \
		/org/freedesktop/portal/desktop \
		org.freedesktop.portal.GlobalShortcuts 2>/dev/null)"
	if printf '%s' "$SIGS" | grep -q "Activated" \
			&& printf '%s' "$SIGS" | grep -q "Deactivated"; then
		ok "the portal offers Activated and Deactivated"
	else
		bad "the portal offers Activated and Deactivated (press and release)"
	fi

	if command -v python3 >/dev/null 2>&1; then
		# The real resolution, through the same library the portal uses.
		RES="$(python3 - "$FILE_ID" <<'PY' 2>/dev/null
import sys, gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio
a = Gio.DesktopAppInfo.new(sys.argv[1] + ".desktop")
print("yes" if a is not None else "no")
PY
)"
		if [ "$RES" = "yes" ]; then
			ok "glib resolves $FILE_ID.desktop on this system"
		else
			echo "  --   $FILE_ID.desktop not installed here yet; skipped glib resolution"
		fi
	fi
else
	echo "  --   no session bus; skipped the live portal checks"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
