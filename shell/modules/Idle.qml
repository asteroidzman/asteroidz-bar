// The idle inhibitor: a mug, lit when sleep is being held off.
//
// Never a filled pill. The icon is tinted with the accent, and the "active"
// look fills the pill with that same accent -- so turning the inhibitor ON is
// exactly when its mug would vanish. The bell fell into the same trap.
//
// It shows IdleService.manualInhibit, which comes from the compositor over
// `watch idle` -- not from a local copy of what this pill last did. The
// difference shows up the moment anything else touches the same state: a
// keybind bound to toggle_idle_inhibit, a second bar on another output, a bar
// restart while the inhibit was on. The last one is the bad one, because it
// leaves a machine that will never sleep behind an icon saying it will.

import QtQuick
import ".."

Pill {
    id: root

    readonly property bool inhibited: IdleService.manualInhibit

    // Nothing here idles, nothing here to inhibit. With `bar { idle { enable
    // false } }` -- or with every timeout at 0 -- the screen will not blank on
    // its own, and a button offering to prevent that is describing a session
    // it is not in. asteroidz-bar is the idle daemon now (swayidle is gone),
    // so "the feature is off" really does mean nothing will happen.
    shown: IdleService.active

    icons: [inhibited ? "asteroidz-bar/idle-on.svg"
                      : "asteroidz-bar/idle-off.svg"]
    iconTint: inhibited ? Cfg.focusBg : Cfg.fg
    paddingX: 0

    // Both states draw the same square, so toggling cannot reflow the section.
    fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

    onClicked: button => {
        if (button !== Qt.LeftButton)
            return;
        // The compositor owns the inhibitor. No optimistic update: the new
        // state arrives over the watch, which is also the only way this pill
        // hears about a change it did not make.
        IdleService.toggleInhibit();
    }
}
