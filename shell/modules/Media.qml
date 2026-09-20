// Now playing: three transport buttons and the track, with a live spectrum
// where the leading glyph would be.
//
// Four pills, not one widget. A pill is the unit of hit testing -- one node
// cannot hold three targets -- so previous, play/pause and next are each their
// own, and they are icon-only, which costs about as much width as one word.
//
// Nothing playing drops the whole module so the slot collapses, rather than
// leaving a permanently empty widget on the bar.

import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Shapes
import ".."

Row {
    id: root

    spacing: Cfg.moduleSpacing

    // The bar, for the MPD panel the track pill opens. Injected by
    // ModuleLoader the way every other panel-opening module takes it.
    property var bar: null

    // The player to follow: whichever one is actually playing, else the first
    // PAUSED one. Picking "the first" outright means a paused browser tab
    // outranks the music.
    readonly property var player: {
        let fallback = null;
        for (const p of Mpris.players.values) {
            if (p.playbackState === MprisPlaybackState.Playing)
                return p;
            // Paused, not merely controllable.
            //
            // `canControl` is true for any player that exposes the interface at
            // all, including one sitting at Stopped with nothing loaded -- and
            // applications register that at startup and leave it there for the
            // rest of the session. So this module appeared with dead transport
            // buttons, no title and a flat visualiser, claiming something was
            // playing when nothing had ever been opened.
            //
            // Paused means a track IS loaded, which is the case the fallback
            // exists for. Stopped means an application saying only that it
            // could play something one day.
            if (!fallback && p.canControl
                    && p.playbackState === MprisPlaybackState.Paused)
                fallback = p;
        }
        return fallback;
    }

    readonly property bool have: player !== null

    // MPD without a bridge.
    //
    // mpd-mpris is what puts MPD on MPRIS, and while it runs the branch above
    // finds it like any other player. It is a separate service that can be
    // absent, disabled or dead, and MPD playing into a module that has hidden
    // itself is the worst of the three -- the bar says nothing is playing
    // while the room disagrees, and the MPD panel this pill opens cannot be
    // reached at all, because the pill is not there to click.
    //
    // So MPD is a source in its own right, and only when MPRIS has nobody:
    // with the bridge running, following BOTH would draw the same track twice
    // and leave two sets of transport buttons fighting over one daemon.
    readonly property bool mpdOnly: !have && MpdService.connected
    readonly property bool anySource: have || mpdOnly

    readonly property bool playing: mpdOnly
        ? MpdService.playing
        : (have && player.playbackState === MprisPlaybackState.Playing)

    // What the pill says, from whichever source is in force.
    readonly property string sourceTitle: mpdOnly
        ? (MpdService.currentSong.Title || "")
        : (have ? (player.trackTitle || "") : "")
    readonly property string sourceArtist: mpdOnly
        ? (MpdService.currentSong.Artist || "")
        : (have ? (player.trackArtist || "") : "")

    // One place the transport aims at, so three buttons do not each branch.
    function goPrevious() {
        if (mpdOnly) MpdService.previous();
        else if (have) player.previous();
    }
    function goNext() {
        if (mpdOnly) MpdService.next();
        else if (have) player.next();
    }
    function goToggle() {
        if (mpdOnly) MpdService.toggle();
        else if (have) player.togglePlaying();
    }

    // `shown`, not `visible` -- see ModuleLoader. This is the module that made
    // it necessary: idle, it still measures its transport controls, its pinned
    // title and its visualiser, so its slot reserved 390px of nothing and the
    // centre panel drew three times wider than the clock inside it.
    property bool shown: anySource

    readonly property int leadTrim: 0
    readonly property int trailTrim: Cfg.pillPadding

    // ── transport ───────────────────────────────────────────────────────────

    Pill {
        icons: ["asteroidz-bar/media-cava/prev.svg"]
        iconTint: Cfg.fg
        // These SVGs fill their viewBox edge to edge, with none of the margin
        // a themed icon carries, so at the pill's full height they tower over
        // every other glyph on the bar. Two thirds puts their ink on the same
        // optical size as the status icons beside them.
        iconScale: 0.66
        paddingX: 0
        fixedWidth: iconSize + 2 * Cfg.borderWidth + 1
        onClicked: root.goPrevious()
    }

    Pill {
        // The ACTION, not the state: a playing track offers pause.
        icons: [root.playing ? "asteroidz-bar/media-cava/pause.svg"
                             : "asteroidz-bar/media-cava/play.svg"]
        iconTint: Cfg.fg
        iconScale: 0.66
        paddingX: 0
        fixedWidth: iconSize + 2 * Cfg.borderWidth + 1
        onClicked: root.goToggle()
    }

    Pill {
        icons: ["asteroidz-bar/media-cava/next.svg"]
        iconTint: Cfg.fg
        iconScale: 0.66
        paddingX: 0
        fixedWidth: iconSize + 2 * Cfg.borderWidth + 1
        onClicked: root.goNext()
    }

    // ── the track ───────────────────────────────────────────────────────────

    Pill {
        id: track

        text: {
            if (!root.anySource)
                return "";
            const t = root.sourceTitle;
            const a = root.sourceArtist;
            return a ? t + " • " + a : t;
        }
        // Pinned AND capped at the same width. Pinned so the bar does not
        // resize itself on every track change; capped because a pinned pill
        // does not elide -- the label is only ever measured against maxWidth
        // (see Pill.qml, which explains why fixedWidth cannot be used for it)
        // -- so a long title simply overflowed the pill and was drawn straight
        // across the clock and the weather beside it.
        fixedWidth: Cfg.mediaWidth
        maxWidth: Cfg.mediaWidth

        // Left toggles, right opens MPD.
        //
        // The transport pills beside this one already toggle, so a left click
        // here doing it again is the convenience it always was. The panel goes
        // on the right button because it is about ONE player: MPD is a library
        // with a daemon in front of it, and the queue, the database and the
        // playlists have nowhere else to be reached from. A browser tab has no
        // such thing and would open an empty panel, so the entry is only there
        // when MPD is actually answering.
        onClicked: button => {
            if (button === Qt.RightButton) {
                if (MpdService.connected && root.bar)
                    root.bar.showPanel(track, mpdPanel);
                return;
            }
            root.goToggle();
        }

        // No glyph of its own. It used to fall back to a play/pause icon
        // whenever the spectrum was not showing, which put a SECOND play
        // button on the bar the moment anything was paused -- a foot from the
        // transport's own, and not a control at all.
        // The spectrum is not an icon, so the pill reserves room for it and
        // hands back the slot to put it in -- positioning it by hand drew it
        // over the title, and then, once the label made room, left it stranded
        // at the pill's left edge while the room itself moved with the centred
        // row.
        // Reserved for as long as the visualiser is enabled, whether or not
        // anything is coming through it: room that appears and disappears with
        // the audio shifts the title sideways every time a track pauses or a
        // passage goes quiet.
        leadingSpace: viz.showing ? viz.implicitWidth : 0

        // `bar` resolves in this Component rather than inside MpdPanel.qml,
        // the same arrangement AudioPanel and the notification centre use: a
        // Component captures the scope it is DECLARED in, and the panel is a
        // separate file that knows nothing about the bar hosting it.
        Component {
            id: mpdPanel
            MpdPanel {
                onCloseRequested: bar.closeMenu()
            }
        }

        Spectrum {
            id: viz
            parent: track.leadingSlot
            anchors.fill: parent
            active: Cfg.mediaViz
            running: Cfg.mediaViz && root.playing
        }
    }
}
