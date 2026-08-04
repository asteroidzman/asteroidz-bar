// The notification bell.
//
// The daemon is this shell now -- see NotificationService.qml -- so the state
// is read straight off it rather than out of `swaync-client --subscribe`. That
// was a long-lived process writing JSON lines, a second process spawned for
// every toggle, and a retry timer for when the daemon was restarted underneath
// it. All of it is gone: a count is a property.
//
// Never a filled pill. The state IS the artwork, and a filled pill made it
// worse: the glyph is tinted with the accent and the active look fills the
// pill with that same accent, so having a notification was precisely when the
// bell became invisible.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    readonly property int count: NotificationService.count
    readonly property bool dnd: NotificationService.dnd

    icons: [dnd ? "asteroidz-bar/bell-off.svg"
          : count > 0 ? "asteroidz-bar/bell.svg"
                      : "asteroidz-bar/bell-outline.svg"]

    iconTint: (count > 0 && !dnd) ? Cfg.focusBg : Cfg.fg

    // The number beside the bell once there is one. A glyph alone says
    // "something"; the number says how much, and the difference between one
    // notification and forty is most of the reason to look.
    text: count > 0 ? String(count) : ""
    paddingX: count > 0 ? Cfg.pillPadding : 0

    onClicked: button => {
        if (button === Qt.LeftButton)
            bar.showPanel(root, centre);
        else if (button === Qt.RightButton)
            NotificationService.toggleDnd();
    }

    Component {
        id: centre
        NotificationCentre {}
    }
}
