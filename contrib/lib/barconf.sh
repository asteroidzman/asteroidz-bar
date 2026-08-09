# barconf.sh — write the bar's own config for a test.
#
# How the bar looks is the BAR's setting now, not the compositor's. Every suite
# here used to append a `bar { … }` block to the compositor's config and let it
# come back over IPC; the compositor does not store any of that any more, and a
# config that still carries it fails to parse.
#
# So a test writes $BAR_CONF instead. The shared shape is the same in every
# suite -- one section list, plus whatever that test is actually about -- which
# is why it lives here rather than being copied ten times with ten chances to
# drift.
#
# Source AFTER hl_start, which is what sets $HL_OUTDIR.

# Where the config goes. The launch of asteroidz-bar in each suite passes this
# as ASTEROIDZ_BAR_CONFIG, so the shell reads this file and not the user's.
bar_conf_path() { echo "$HL_OUTDIR/bar-config.kdl"; }

# An XDG_CONFIG_HOME for the bar under test, so that a test bar cannot write to
# the real desktop's settings.
#
# This exists because it already happened. The shell pushes the configured font
# out to GTK, Qt and gsettings at startup, a test bar is a real bar and reaches
# that code like any other, and the fixtures here declare fonts of their own --
# so `contrib/process-test.sh`, whose config says `theme { font "Ubuntu 16" }`,
# silently rewrote the developer's actual desktop font to Ubuntu 16 in all five
# places. Nothing failed. It was noticed because the desktop looked different.
#
# A SYMLINK FARM, not an empty directory, and that is the whole design.
#
# An empty XDG_CONFIG_HOME would isolate the writes, but it would also take
# qt6ct's settings away from every suite here -- and qt6ct is what tells Qt
# which font to use. Half of these tests assert on COUNTED PIXELS, so silently
# re-rendering every string in a different font would move numbers in fifteen
# suites at once, for a reason that has nothing to do with what any of them is
# testing. Linking each entry through means everything reads exactly what it
# reads today.
#
# The exceptions are the entries anything might WRITE to, which are copied
# instead: a write through a symlinked directory lands in the real one, which
# would leave this doing nothing at all.
#
# dconf is NOT among them, and cannot be. gsettings is the fifth target, and
# XDG_CONFIG_HOME does not contain it -- measured, not assumed. gsettings does
# not write anything itself; it asks ca.desrt.dconf over D-Bus, and an
# activated service is started by the BUS with the bus's activation
# environment, not the caller's. Setting the variable before `dbus-run-session`
# does not help either: the dconf-service processes left behind by these runs
# had no XDG_CONFIG_HOME in /proc/<pid>/environ at all, and wrote straight to
# the real database.
#
# So gsettings is contained by GSETTINGS_BACKEND=memory instead, which is
# passed alongside this and keeps the whole thing in-process with nothing to
# activate. The cost is that a test bar reads gsettings defaults rather than
# the desktop's -- accepted, because the bar takes its settings from its own
# config file and the alternative was a suite that rewrites the desktop.
bar_xdg_home() { # bar_xdg_home -> path to use as XDG_CONFIG_HOME
	local dst="$HL_OUTDIR/xdg-config" src="${XDG_CONFIG_HOME:-$HOME/.config}"
	local e name

	# Built once per run; a second call is the same sandbox, not a fresh one.
	if [ ! -d "$dst" ]; then
		mkdir -p "$dst"
		for e in "$src"/* "$src"/.[!.]*; do
			[ -e "$e" ] || continue
			ln -sfn "$e" "$dst/$(basename "$e")"
		done
		for name in gtk-3.0 gtk-4.0 qt5ct qt6ct; do
			rm -f "$dst/$name"
			[ -d "$src/$name" ] && cp -r "$src/$name" "$dst/$name"
		done
	fi
	echo "$dst"
}

# bar_conf <left> <center> <right> [extra KDL on stdin]
#
# Writes the whole file: the module placement, then anything else the test
# needs. Whole-file rather than append, so a test that calls it twice gets what
# it asked for the second time rather than both.
#
#     bar_conf "" "clock" "" <<'EOF'
#     panel { enable #true; radius 9 }
#     EOF
#
# A section may name the output it is drawn on, with `@`:
#
#     bar_conf "" "clock@DP-1" ""
#
# which is the `monitor=` property. Spelled into the section list rather than
# taken as three more positional arguments, because a call with six positionals
# of which three are usually empty is unreadable at the call site.
bar_conf() {
	local left="${1%%@*}" center="${2%%@*}" right="${3%%@*}"
	local lmon="" cmon="" rmon=""
	case "$1" in *@*) lmon="${1#*@}" ;; esac
	case "$2" in *@*) cmon="${2#*@}" ;; esac
	case "$3" in *@*) rmon="${3#*@}" ;; esac
	{
		# The artwork in THIS checkout, not whatever is installed. An icon-only
		# module with no icon renders nothing, takes no width and simply
		# disappears from the strip -- which once made a spacing test fail with
		# a baffling "spread 13px" (six modules, four gaps, two of them merged)
		# on any build whose prefix did not match the installed package. Tests
		# should measure the tree they are run from.
		printf 'bar { icon-dir "%s/assets/bar-icons:%s/.local/share:/usr/share" }\n' \
			"$HL_REPO" "$HOME"
		printf 'modules {\n\tleft items="%s" monitor="%s"\n' "$left" "$lmon"
		printf '\tcenter items="%s" monitor="%s"\n' "$center" "$cmon"
		printf '\tright items="%s" monitor="%s"\n}\n' "$right" "$rmon"
		# Only when there IS a heredoc. `cat` with nothing on stdin would sit
		# waiting for the terminal, which in a test run is a hang with no
		# output to explain it.
		[ -t 0 ] || cat
	} > "$(bar_conf_path)"
}

# The panel every visual suite draws against: on, with the radius and padding
# the shipped defaults use, so a screenshot here matches a real bar.
bar_conf_panel() {
	echo 'panel { enable #true; radius 9; padding 12; blur #true; shadow #true }'
}

# Stop a backgrounded `dbus-run-session -- … &` and take its bus with it.
#
# Killing the dbus-run-session PID does NOT kill the dbus-daemon it forked:
# that daemon is reparented to init and stays, holding an inotify instance and
# a socket, for the rest of the session. Every backgrounded launch in these
# suites leaked one, and they accumulate across runs -- 383 of them were live
# at once, which exhausted fs.inotify.max_user_instances (1024) and started
# breaking unrelated programs: `journalctl -f` could no longer get a watch
# descriptor.
#
# So the launch is put in its own process GROUP with setsid, and the whole
# group is signalled. Pair bar_session_run with bar_session_kill.
bar_session_run() { # bar_session_run CMD... -> pid of the group leader
	setsid "$@" &
	echo $!
}

bar_session_kill() { # bar_session_kill PID
	[ -n "${1:-}" ] || return 0
	# The group first (negative PID), then the leader, so a launcher that
	# never made a group of its own is still stopped.
	kill -- "-$1" 2>/dev/null
	kill "$1" 2>/dev/null
	wait "$1" 2>/dev/null
	return 0
}
