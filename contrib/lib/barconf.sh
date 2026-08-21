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

# ── resource limits, and a teardown that cannot leak ────────────────────────
#
# Both halves of this exist because a run of these suites took the machine's
# memory. Two separate faults, and fixing either alone leaves the other:
#
#   NOTHING WAS BOUNDED. A test bar is a real bar: it loads the wallpaper, every
#   module and the settings window, and several suites start one per case. A
#   handful of those at once is gigabytes, and nothing said stop.
#
#   NOTHING WAS REAPED. `setsid dbus-run-session -- … &` then `kill "$QS"` kills
#   the shell and leaves the bus: dbus-run-session's dbus-daemon is reparented
#   to init and stays for the session. Worse, each private bus ACTIVATES its own
#   xdg-desktop-portal, which stays too. This session ended with 54 orphaned
#   dbus-daemons and 53 orphaned portals holding memory, and 648M of /tmp.
#
# So each run gets a transient systemd scope. Everything the run starts lands in
# one cgroup: the bar, its dbus-daemon, every portal that bus activates, and any
# helper they fork. MemoryMax makes the cgroup the thing that fails instead of
# the desktop, and stopping the scope at teardown kills the WHOLE tree, which is
# the only reaping that does not depend on remembering a PID.
#
# Degrades to no limits rather than refusing to run, since a checkout on a
# machine without a user systemd instance should still be testable.
_bar_scope_unit="asteroidz-bartest-$$"
# One unit name per LAUNCH, not per script.
#
# A single name looked right until a suite started a SECOND bar: systemd
# answers "Unit ... was already loaded or has a fragment file", systemd-run
# exits non-zero, and because it is the head of the launch command the bar
# never starts at all. Nothing reports that -- the suite carries on comparing
# two screenshots of a window that is not there, which is a pair of identical
# images and therefore a pass. Found in wallpaper-thumb-test.sh, where "an SDR
# file is unchanged by the provider" had been certifying an empty screen.
#
# The names go in a FILE rather than a variable because bar_limits is used as
# `$(bar_limits)`: it runs in a subshell, so anything it assigns is gone by the
# time the caller reads it.
_bar_scope_dir="${TMPDIR:-/tmp}/asteroidz-bartest-scopes-$$"

# The REAL runtime dir, not the harness's.
#
# hl_start points XDG_RUNTIME_DIR at the test's own directory so the test
# compositor gets a private one. `systemctl --user` reaches the user manager
# through that variable, so under the harness it cannot connect at all -- which
# is not an error anyone sees, it just makes the check below fail and bar_limits
# return nothing. The first version did exactly that: every launch ran
# unlimited, `NO SCOPE ACTIVE` mid-run, and the leak was unchanged.
#
# Overriding it for the systemd calls only is safe because every launch site
# re-sets XDG_RUNTIME_DIR explicitly with `env` for the bar itself, so the
# child still gets the test's one.
_bar_real_runtime_dir() { echo "/run/user/$(id -u)"; }

bar_limits() { # -> argv prefix that runs a command inside this run's scope
	command -v systemd-run >/dev/null 2>&1 || return 0
	XDG_RUNTIME_DIR="$(_bar_real_runtime_dir)" \
		systemctl --user show-environment >/dev/null 2>&1 || return 0
	local unit="$_bar_scope_unit-$(date +%s%N)"
	mkdir -p "$_bar_scope_dir" 2>/dev/null \
		&& printf '%s\n' "$unit" >> "$_bar_scope_dir/units"
	printf '%s ' env "XDG_RUNTIME_DIR=$(_bar_real_runtime_dir)" \
		systemd-run --user --scope --quiet --collect \
		--unit="$unit" \
		-p MemoryMax=4G -p MemorySwapMax=0 -p TasksMax=512 -p CPUQuota=400%
}

# When this run began, so the reaper below can tell its own leftovers from
# whatever was already on the machine.
_bar_run_started="$(date +%s)"

# Reap the private buses this run started.
#
# The scope alone is not enough, and the measurement says so: it is created (a
# scope is live twelve seconds in) and gone by twenty-four, while the bar is
# still running and the test still passes -- quickshell re-parents itself out of
# the cgroup, so from then on nothing bounds it and stopping the scope kills
# nothing. The scope still earns its place by bounding the STARTUP burst, which
# is when several bars at once take the memory, but it cannot be the reaper.
#
# `dbus-run-session` forks a dbus-daemon that is reparented to init when the
# session ends, and every one of those private buses activates its own
# xdg-desktop-portal, which stays with it. Killing the daemon takes its portals
# with it -- measured: 54 daemons killed, 53 orphaned portals went too.
#
# Identified by BINARY plus START TIME, never by a pattern over a command line.
# The session bus here is dbus-broker, a different program, so it cannot match;
# and requiring a start time after this run began means a daemon that was
# already running when the suite started is left alone.
_bar_reap_buses() {
	local p start
	for p in $(pgrep -x dbus-daemon 2>/dev/null); do
		[ -d "/proc/$p" ] || continue
		# Seconds since boot -> wall clock, via /proc/uptime, so this does not
		# depend on ps output formats.
		start="$(awk -v t="$(awk "{print \$22}" "/proc/$p/stat" 2>/dev/null)" \
			-v hz=100 -v now="$(date +%s)" -v up="$(cut -d. -f1 /proc/uptime)" \
			'BEGIN { printf "%d", now - up + (t / hz) }' 2>/dev/null)"
		[ -n "$start" ] || continue
		[ "$start" -ge "$_bar_run_started" ] 2>/dev/null || continue
		kill "$p" 2>/dev/null
	done
	return 0
}

# Stop the scope, and with it everything the run started. Safe to call twice and
# safe when no scope was ever made.
bar_scope_stop() {
	_bar_reap_buses
	command -v systemctl >/dev/null 2>&1 || return 0
	if [ -f "$_bar_scope_dir/units" ]; then
		while read -r _bs_unit; do
			[ -n "$_bs_unit" ] || continue
			XDG_RUNTIME_DIR="$(_bar_real_runtime_dir)" \
				systemctl --user stop "$_bs_unit.scope" >/dev/null 2>&1
		done < "$_bar_scope_dir/units"
		rm -rf "$_bar_scope_dir"
	fi
	return 0
}

# Chained into hl_stop rather than added to twenty traps.
#
# Every suite here already does `trap 'hl_stop' EXIT` before sourcing this file,
# so hooking the function is what reaches all of them -- including the ones that
# exit early on a failed premise, which are exactly the runs that used to leak.
if declare -f hl_stop >/dev/null 2>&1 \
	&& ! declare -f _bar_orig_hl_stop >/dev/null 2>&1; then
	eval "_bar_orig_hl_stop() $(declare -f hl_stop | tail -n +2)"
	hl_stop() { bar_scope_stop; _bar_orig_hl_stop "$@"; }
fi

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
#
# No `shadow` key: the shell draws no shadows and never reads one. See
# bar_conf_effects, which turns on the shadow that actually gets drawn.
bar_conf_panel() {
	echo 'panel { enable #true; radius 9; padding 12; blur #true }'
}

# The COMPOSITOR-side half of the bar's look, for suites that measure blur or
# shadows. Append to $HL_CONFIG and reload before launching the bar.
#
# Two things have to be true for a bar panel to be shadowed at all, and neither
# is a default:
#
#   - effects/shadow/enable, obviously; and
#   - a layerrule naming the shell's namespaces. Panels, popovers and toasts
#     sit INSIDE the strip the bar reserves rather than reserving anything
#     themselves, which is exclusion zone -1, and asteroidz only shadows a
#     layer surface automatically at zone 0. The trailing dash in the pattern
#     excludes `asteroidz-bar` itself -- the full-width strip, which must stay
#     shadowless or it would draw one shadow around the whole output.
#
# The size is deliberately small, and that is the interesting part: the shadow
# is drawn around the SURFACE, so a shadow blurred by more pixels than the
# panel is tall spreads its alpha over a radius bigger than the thing casting
# it and becomes invisible without ever being absent. At the desktop's own
# 72/72 a bar panel has no visible shadow at all while a popover -- ten times
# the area -- looks right, which is exactly the shape of bug these numbers
# exist to keep out of the tests.
#
# Written one node per line. A block written on ONE line parses as something
# else -- the same trap the bar's own KDL subset has with `custom "x" { … }` --
# and a layerrule that silently did not take is indistinguishable here from a
# shadow that was never drawn.
bar_conf_effects() {
	cat <<'EOF'
effects {
	blur {
		enable 1
		layer 0
		passes 2
		radius 6
		transparency-threshold 0.5
	}
	shadow {
		enable 1
		layer 0
		size 24
		blur 24
		color "0x000000aa"
		// position is left at its default, which aims the shadow downwards
		// (position/y is 10). That is where a suite has to read it anyway: the
		// compositor clips a layer shadow to the monitor, so above a bar
		// anchored margin-y from the top of the screen there is no room for
		// one -- see the note on the shadow assertion in look-test.sh.
	}
}
misc {
	layerrule layer_name:asteroidz-bar-.*,forceshadow:1
}
EOF
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
