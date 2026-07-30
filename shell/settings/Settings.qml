pragma Singleton

// The settings window, at most one of it.
//
// A singleton because the window has to be reachable from anywhere that wants to
// offer a way in -- the display panel today, a keybind later -- and because two
// of them staging different edits against the same compositor is a way to lose
// changes with no warning.
//
// Built on first open, not at startup. A bar that never opens settings should not
// pay for the object tree or the schema fetch behind it, and `visible` on an
// unmapped toplevel is not the same as not having one: a hidden window still
// holds its Flickable, its Repeaters and its bindings.
//
// createObject rather than LazyLoader: the loader's `active` has its own opinion
// about window visibility, and the interesting state here is "does the window
// exist yet", which is exactly what a null check answers.

import Quickshell
import QtQuick
import "."

Singleton {
    id: root

    property var window: null

    Component {
        id: windowComponent
        SettingsWindow {}
    }

    function open() {
        if (window === null)
            window = windowComponent.createObject(root);
        if (window !== null) {
            window.visible = true;
            // Un-minimise, for the case where it is already open and iconified.
            // A client cannot raise itself on Wayland -- there is no protocol for
            // it -- so this is the extent of what a second "open settings" can
            // do about a window that is already there.
            window.minimized = false;
        }
    }

    function toggle() {
        if (window !== null && window.visible)
            window.visible = false;
        else
            open();
    }
}
