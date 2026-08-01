pragma Singleton

// What happens when nothing has been touched for a while.
//
// This replaces swayidle, and there is not much to replace: the compositor
// implements ext-idle-notify-v1 and owns DPMS, and the bar is a Wayland client
// that can hold an idle timer and dispatch to it. A separate daemon between the
// two was only ever translating one into the other, with its own config file
// and a set of timeouts nothing else in the desktop could read. The timeouts
// live in the compositor's config now (`bar { idle { … } }`) and arrive here
// over `watch bar-config`, so changing one is a reload rather than a restart of
// something else.
//
// Each action is its OWN monitor rather than a chain of stages. They are
// independent timeouts -- screen off at ten minutes, suspend at thirty means
// suspend at thirty, not forty -- and a chain would also have to decide what
// happens when a middle stage is disabled. Wayland's protocol gives each
// notification its own timeout for the same reason.

import Quickshell
import Quickshell.Wayland
import QtQuick
import "."

Singleton {
    id: root

    readonly property var cfg: Cfg.idle
    readonly property bool enabled: Cfg.flag(cfg, "enable", false)

    readonly property int dpmsTimeout: Cfg.num(cfg, "dpms_timeout", 0)
    readonly property int lockTimeout: Cfg.num(cfg, "lock_timeout", 0)
    readonly property int suspendTimeout: Cfg.num(cfg, "suspend_timeout", 0)
    readonly property bool lockBeforeSuspend:
        Cfg.flag(cfg, "lock_before_suspend", false)
    readonly property bool respectInhibitors:
        Cfg.flag(cfg, "respect_inhibitors", true)
    readonly property string lockCommand: Cfg.strOrEmpty(cfg, "lock_command", "")
    readonly property string onIdleCommand: Cfg.strOrEmpty(cfg, "on_idle", "")
    readonly property string onResumeCommand: Cfg.strOrEmpty(cfg, "on_resume", "")

    // Whether the outputs are off BECAUSE OF THIS, so resume only powers them
    // back on when it was the one that turned them off. Otherwise every scrap
    // of activity would dispatch dpms_on to a compositor that never blanked --
    // harmless, but it would also fight `dpms_off_monitor` typed by hand.
    property bool blanked: false

    // A command from the config, run through a shell because that is what it
    // looks like in the file: `on-resume "~/.config/scripts/x.sh"` has a tilde
    // in it, and quoting rules people already know beat a second syntax.
    function run(cmd) {
        if (!cmd)
            return;
        Quickshell.execDetached(["sh", "-c", cmd]);
    }

    function lock() {
        if (root.lockCommand)
            run(root.lockCommand);
    }

    // ── screen off ──────────────────────────────────────────────────────────
    //
    // `.` is an unanchored regex on the output name, so one dispatch covers
    // every monitor.
    IdleMonitor {
        enabled: root.enabled && root.dpmsTimeout > 0
        timeout: root.dpmsTimeout
        respectInhibitors: root.respectInhibitors
        onIsIdleChanged: {
            if (isIdle) {
                root.blanked = true;
                Ipc.dispatch("dispatch dpms_off_monitor,.");
                root.run(root.onIdleCommand);
            } else {
                // Outputs first, then the hook: a resume command that draws
                // something, or re-locks an audio device the display engine
                // knocked out, wants the screens already coming back.
                if (root.blanked) {
                    root.blanked = false;
                    Ipc.dispatch("dispatch dpms_on_monitor,.");
                }
                root.run(root.onResumeCommand);
            }
        }
    }

    // ── lock ────────────────────────────────────────────────────────────────
    IdleMonitor {
        enabled: root.enabled && root.lockTimeout > 0 && root.lockCommand !== ""
        timeout: root.lockTimeout
        respectInhibitors: root.respectInhibitors
        // Only on the way IN. A lock screen is dismissed by the person, not by
        // the pointer moving.
        onIsIdleChanged: if (isIdle) root.lock()
    }

    // ── suspend ─────────────────────────────────────────────────────────────
    //
    // systemctl without --user: this is a system transition and polkit decides
    // whether the session may make it, exactly as the power menu does.
    IdleMonitor {
        enabled: root.enabled && root.suspendTimeout > 0
        timeout: root.suspendTimeout
        respectInhibitors: root.respectInhibitors
        onIsIdleChanged: {
            if (!isIdle)
                return;
            // Before the suspend call, not after: the machine may be asleep
            // before a detached lock process has drawn anything, and coming
            // back to an unlocked screen is the failure this option exists to
            // prevent.
            if (root.lockBeforeSuspend)
                root.lock();
            Quickshell.execDetached(["systemctl", "suspend"]);
        }
    }
}
