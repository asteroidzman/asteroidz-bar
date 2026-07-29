// The notification bell.
//
// swaync is the daemon here, and it publishes exactly what a bar needs on its
// own bus name: the unread count, do-not-disturb, and whether the control
// centre is open. Watching that is far cheaper and far more accurate than
// counting org.freedesktop.Notifications traffic, which cannot see what the
// daemon has already dismissed.
//
// Never a filled pill. The state IS the artwork, and a filled pill made it
// worse: the glyph is tinted with the accent and the active look fills the
// pill with that same accent, so having a notification was precisely when the
// bell became invisible.

import Quickshell
import Quickshell.Io
import QtQuick
import ".."

Pill {
    id: root

    property int count: 0
    property bool dnd: false
    property bool inhibited: false

    icons: [inhibited ? "asteroidz-bar/bell-sleep.svg"
          : dnd ? "asteroidz-bar/bell-off.svg"
          : count > 0 ? "asteroidz-bar/bell.svg"
                      : "asteroidz-bar/bell-outline.svg"]

    iconTint: (count > 0 && !dnd) ? Cfg.focusBg : Cfg.fg
    paddingX: 0

    // swaync's D-Bus interface, polled rather than subscribed.
    //
    // The compositor subscribes to the daemon's Subscribe signal because it is
    // already on the bus; from here that would mean a bus connection whose only
    // job is one signal. `busctl --json` on a two-second tick costs a fork we
    // would rather not make either -- but this is the one module whose state
    // has no file to read and no quickshell service, and two seconds is well
    // inside how fast a bell needs to react.
    Process {
        id: query
        command: ["busctl", "--user", "--json=short", "get-property",
                  "org.erikreider.swaync.cc", "/org/erikreider/swaync/cc",
                  "org.erikreider.swaync.cc", "count", "dnd", "inhibited"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Three separate replies, one per property, in order.
                const vals = [];
                for (const line of text.split("\n")) {
                    if (!line.trim())
                        continue;
                    try {
                        vals.push(JSON.parse(line).data);
                    } catch (e) {
                        // The daemon is not running: leave the last state
                        // rather than flashing the bell empty on one bad tick.
                        return;
                    }
                }
                if (vals.length >= 3) {
                    root.count = vals[0] || 0;
                    root.dnd = !!vals[1];
                    root.inhibited = !!vals[2];
                }
            }
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!query.running) query.running = true
    }

    onClicked: button => {
        if (button === Qt.LeftButton)
            toggle.running = true;
    }

    Process {
        id: toggle
        command: ["swaync-client", "-t"]
    }
}
