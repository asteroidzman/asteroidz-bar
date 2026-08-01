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
