// The idle inhibitor: a mug, lit when sleep is being held off.
//
// Never a filled pill. The icon is tinted with the accent, and the "active"
// look fills the pill with that same accent -- so turning the inhibitor ON is
// exactly when its mug would vanish. The bell fell into the same trap.

import QtQuick
import ".."

Pill {
    id: root

    property bool inhibited: false

    icons: [inhibited ? "asteroidz-bar/idle-on.svg"
                      : "asteroidz-bar/idle-off.svg"]
    iconTint: inhibited ? Cfg.focusBg : Cfg.fg
    paddingX: 0

    // Both states draw the same square, so toggling cannot reflow the section.
    fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

    onClicked: button => {
        if (button !== Qt.LeftButton)
            return;
        // The compositor owns the inhibitor; -1 toggles.
        Ipc.dispatch("dispatch toggle_idle_inhibit,-1");
        root.inhibited = !root.inhibited;
    }
}
