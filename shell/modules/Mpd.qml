// The MPD pill: a way in to the library that does not depend on playback.
//
// The panel used to hang off the media pill's right button, and that was
// wrong in a way only using it shows: the media pill exists when something is
// PLAYING, and the queue, the database and the saved playlists are most of
// what somebody wants before anything is. With MPD stopped there was no pill
// to aim at and no way to reach any of it -- a library browser locked behind
// having already found something to play.
//
// So it is its own module. The media pill goes on saying what is playing, for
// MPD and for everything else through MPRIS; this one is the library, and it
// is there whenever the daemon is.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    property var bar: null

    // Present when MPD is, absent when it is not -- the same call Clipboard
    // makes about a compositor with no clipboard to read. A pill that opens a
    // panel saying "MPD is not running" is worse than an absent one, and a
    // machine without mpd should not carry a button for it.
    shown: MpdService.connected

    icons: ["asteroidz-bar/mpd.svg"]
    iconTint: Cfg.fg

    // No text, ever.
    //
    // Not the track -- the media pill is already showing it, and two copies of
    // one title a few pills apart is the duplication the blackhole pill was
    // just cured of. Not a queue length either: it only grows, it is not
    // something anybody acts on from the bar, and it would be a number
    // changing constantly to no purpose. The clipboard pill makes this exact
    // argument about its own depth.
    text: ""
    paddingX: 0

    onClicked: button => {
        if (button === Qt.LeftButton && bar)
            bar.showPanel(root, panel);
    }

    // `bar` resolves in this Component rather than inside MpdPanel.qml: a
    // Component captures the scope it is DECLARED in, and the panel is a
    // separate file that knows nothing about the bar hosting it. The same
    // arrangement AudioPanel and the notification centre use.
    Component {
        id: panel
        MpdPanel {
            onCloseRequested: bar.closeMenu()
        }
    }
}
