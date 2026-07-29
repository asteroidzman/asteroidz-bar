// asteroidz-bar: the asteroidz shell, out of the compositor.
//
// One bar per output, plus the wallpaper. Started by the compositor's autostart
// or by hand:
//
//     qs -p /usr/share/asteroidz-bar/shell.qml
//
// The compositor is reached over its own IPC socket, whose path it exports as
// ASTEROIDZ_INSTANCE_SIGNATURE. Without it the shell still runs -- with
// defaults and no compositor state -- because being able to start this under
// any compositor is what makes it developable without logging out.

import Quickshell
import QtQuick
import "."

ShellRoot {
    id: root

    Component.onCompleted: {
        const sig = Quickshell.env("ASTEROIDZ_INSTANCE_SIGNATURE");
        if (sig) {
            Ipc.socketPath = sig;
        } else {
            console.warn("asteroidz-bar: ASTEROIDZ_INSTANCE_SIGNATURE not set;"
                         + " running with defaults and no compositor state");
        }
    }

    Variants {
        model: Quickshell.screens

        Bar {}
    }
}
