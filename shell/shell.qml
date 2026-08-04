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
        // Touching the singleton is what creates it. A Singleton nothing ever
        // refers to is never instantiated, and the wallpaper would simply
        // never start -- silently, because there is nothing to fail.
        void Wallpaper.binary;
        // Same for the idle service, which is a set of timers and no pixels at
        // all -- exactly the shape of thing that goes missing without a
        // reference. It does nothing until `bar { idle { enable true } }`.
        void IdleService.enabled;
        // And the notification server. This shell IS
        // org.freedesktop.Notifications -- a singleton nothing refers to is
        // never constructed, so without this the bus name would simply never
        // be taken and every notification on the desktop would go nowhere.
        void NotificationService.count;
        if (!Ipc.connected)
            console.warn("asteroidz-bar: ASTEROIDZ_INSTANCE_SIGNATURE not set;"
                         + " running with defaults and no compositor state");
    }

    Variants {
        model: Quickshell.screens

        Bar {}
    }

    // The toasts, one overlay per screen. Separate from the bar because a
    // notification is not part of the strip: it arrives without anybody
    // clicking anything, and it must not reserve space or take the keyboard.
    Variants {
        model: Quickshell.screens

        NotificationPopups {}
    }
}
