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

# bar_conf <left> <center> <right> [extra KDL on stdin]
#
# Writes the whole file: the module placement, then anything else the test
# needs. Whole-file rather than append, so a test that calls it twice gets what
# it asked for the second time rather than both.
#
#     bar_conf "" "clock" "" <<'EOF'
#     panel { enable #true; radius 9 }
#     EOF
bar_conf() {
	local left="$1" center="$2" right="$3"
	{
		# The artwork in THIS checkout, not whatever is installed. An icon-only
		# module with no icon renders nothing, takes no width and simply
		# disappears from the strip -- which once made a spacing test fail with
		# a baffling "spread 13px" (six modules, four gaps, two of them merged)
		# on any build whose prefix did not match the installed package. Tests
		# should measure the tree they are run from.
		printf 'bar { icon-dir "%s/assets/bar-icons:%s/.local/share:/usr/share" }\n' \
			"$HL_REPO" "$HOME"
		printf 'modules {\n\tleft items="%s" monitor=""\n' "$left"
		printf '\tcenter items="%s" monitor=""\n' "$center"
		printf '\tright items="%s" monitor=""\n}\n' "$right"
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
