pragma Singleton

// The clipboard's keybind end, and nothing else.
//
// This exists because of a mistake worth recording: the IpcHandler started out
// inside modules/Clipboard.qml, which is instantiated ONCE PER BAR. On a second
// monitor quickshell logged
//
//   Handler was registered but will not be used because another handler is
//   registered for target clipboard
//
// and the bind quietly half-worked. The handler that won belonged to one
// particular bar, and the signal it raised was that bar's own -- so the panel
// could only ever open on that monitor, and pressing the bind while looking at
// the other one did nothing at all. A singleton is registered once no matter
// how many bars exist, and its signal reaches every one of them, which is why
// NotificationService owns the `notify` handler rather than the bell pill.
//
// The history itself is the C++ Clipboard singleton; this file does not touch
// it except to pass through the two commands that are not "open the panel".

import Quickshell
import Quickshell.Io
import Asteroidz.Bar
import "."

Singleton {
    id: root

    // Every bar hears this; exactly one acts on it. The comparison happens in
    // the module, against its own screen.
    signal toggleRequested(string monitor)

    // Which bar should answer. A key press does not know which screen you are
    // looking at and the compositor cannot pass it -- the bind spawns a command
    // line, and that process has no notion of focus by the time it runs. The
    // shell has it already, so the resolution happens here.
    //
    // Resolved once, centrally, rather than in each pill: with every bar
    // comparing against Compositor.focusedMonitor itself, a moment when focus
    // is unknown opens the panel on every monitor at once.
    function focusedBarMonitor() {
        if (Compositor.focusedMonitor !== "")
            return Compositor.focusedMonitor;
        // Before the first focus event -- at startup, or on a compositor that
        // never sent one. Somewhere is better than nowhere.
        const screens = Quickshell.screens;
        return screens && screens.length > 0 ? screens[0].name : "";
    }

    IpcHandler {
        target: "clipboard"

        // Opens the panel, or closes it if this bar's popover is already up:
        // Bar.showPanel is itself a toggle, so pressing the bind twice is
        // open-then-close rather than open-then-open.
        function toggle(): string {
            const mon = root.focusedBarMonitor();
            if (mon === "")
                return "no screens";
            root.toggleRequested(mon);
            return mon;
        }

        function pause(): string {
            Clipboard.paused = !Clipboard.paused;
            return Clipboard.paused ? "paused" : "recording";
        }

        function clear(): string {
            const n = Clipboard.entries.length;
            Clipboard.clear();
            return "cleared " + n;
        }
    }
}
