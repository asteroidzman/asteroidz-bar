// The clipboard pill.
//
// Opens the history under itself on a left click, and on the keybind that
// ClipboardService turns into a signal -- which is how it will actually be
// used. A clipboard manager you have to aim at with a mouse is a clipboard
// manager you stop using.
//
// The history is the C++ Clipboard singleton (ext-data-control-v1, on the
// shell's own Wayland connection). This file is a button and a panel; it holds
// no state of its own.

import Quickshell
import QtQuick
import Asteroidz.Bar
import ".."

Pill {
    id: root

    // Handed in by ModuleLoader, the way Power takes it. Notify reaches `bar`
    // through the scope chain instead -- both work, but a declared property is
    // the one that fails loudly rather than resolving to nothing if the slot
    // ever stops providing it.
    property var bar: null

    // Hidden entirely when the compositor offers no clipboard to read, rather
    // than shown as a button that opens a panel saying so. A bar slot that
    // cannot ever do anything is worse than an absent one -- the notify pill
    // makes the same call about a missing daemon.
    shown: Clipboard.available

    icons: ["asteroidz-bar/clipboard.svg"]

    // Paused is a state worth seeing from the bar. Recording is the normal
    // case and says nothing; NOT recording is the one you want to be reminded
    // of, because it is the one you turned on for a reason and will forget.
    iconTint: Clipboard.paused
              ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
              : Cfg.fg

    // The count is deliberately absent. Unlike the bell, where the number IS
    // the news, a clipboard's depth is not something you act on -- it only
    // ever grows, so it would be a number that changes constantly and means
    // nothing.
    text: ""
    paddingX: 0

    onClicked: button => {
        if (button === Qt.LeftButton)
            bar.showPanel(root, panel);
        else if (button === Qt.RightButton)
            Clipboard.paused = !Clipboard.paused;
    }

    // The limit is config, and the backend is where it has to land. Bound
    // rather than set once, so editing the config re-applies it without a
    // restart, exactly like every other Cfg value.
    Binding {
        target: Clipboard
        property: "limit"
        value: Cfg.clipboardLimit
    }

    // One bar answers, not all of them. The handler lives in
    // ClipboardService, a singleton -- see the note there about what happens
    // when it lives here instead and a second monitor appears.
    Connections {
        target: ClipboardService
        function onToggleRequested(monitor) {
            if (bar.screenName === monitor)
                bar.showPanel(root, panel);
        }
    }

    Component {
        id: panel
        // `bar` resolves here and not inside ClipboardPanel.qml: a Component
        // captures the scope it is DECLARED in, and the panel is a separate
        // file that knows nothing about the bar hosting it.
        ClipboardPanel {
            onCloseRequested: bar.closeMenu()
        }
    }
}
