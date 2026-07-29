// Name -> module, the way `modules-left "tags,layout,title"` means it.
//
// A Loader rather than a switch that builds everything and hides the unused:
// a module is a process's worth of work (a socket, a timer, a subscription),
// and the whole point of the config listing them is that the ones you did not
// list cost nothing.
//
// An unknown name loads nothing and says so once. The native bar warns and
// carries on for the same reason -- a typo in one module name should not cost
// you the other eleven.

import QtQuick
import "."
import ".."

Loader {
    id: root

    property string module: ""
    property string screenName: ""

    // `custom/<name>` is a plugin. Phase 5; recognised here so the name does
    // not warn as unknown in the meantime.
    readonly property bool isCustom: module.startsWith("custom/")

    visible: status === Loader.Ready
    active: !isCustom

    sourceComponent: {
        switch (module) {
        case "clock":
            return clockComponent;
        default:
            return null;
        }
    }

    Component {
        id: clockComponent
        Clock {}
    }

    Component.onCompleted: {
        if (!isCustom && sourceComponent === null)
            console.warn("asteroidz-bar: unknown module:", module);
    }
}
