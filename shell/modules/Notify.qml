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

    // Subscribed, not polled.
    //
    // This used to ask the bus for three PROPERTIES named count, dnd and
    // inhibited. swaync has no such properties -- they are METHODS
    // (NotificationCount, GetDnd, IsInhibited) -- so every tick came back
    // `Failed to get property count: No such property "count"`, the parse gave
    // up, and the count sat at zero for ever. The bell read "nothing unread"
    // with fifty notifications waiting, which is the one thing it exists to
    // say.
    //
    // `swaync-client --subscribe` fixes it and costs less than what it
    // replaces: one long-lived process that writes a line whenever anything
    // changes, rather than forking busctl every two seconds to ask. It answers
    // once on connect too, so there is no gap before the first change.
    //
    // Its fields are NAMED -- {"count":51,"dnd":false,"visible":false,
    // "inhibited":false} -- which is why this and not the daemon's
    // GetSubscribeData. That returns a bare (bbub) whose order is not
    // self-describing, and reading it wrong would silently swap the count for
    // the DND flag; the compositor's own notification module refused it for
    // that reason and this inherits the refusal.
    Process {
        id: sub
        command: ["swaync-client", "--subscribe"]
        running: true

        stdout: SplitParser {
            onRead: line => {
                if (!line.trim())
                    return;
                try {
                    const o = JSON.parse(line);
                    root.count = o.count || 0;
                    root.dnd = !!o.dnd;
                    root.inhibited = !!o.inhibited;
                } catch (e) {
                    // Not a state line. Leave the last one standing rather
                    // than flashing the bell empty on one bad read.
                }
            }
        }
    }

    // The daemon is not always up before the bar is, and it can be restarted
    // under it -- swaync-client exits when that happens, taking the
    // subscription with it and freezing the bell at its last count. Re-running
    // it is the whole recovery. The retry is slow on purpose: a daemon that is
    // not there will not be there any sooner for being asked twice a second.
    Timer {
        interval: 5000
        running: !sub.running
        repeat: true
        onTriggered: sub.running = true
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
