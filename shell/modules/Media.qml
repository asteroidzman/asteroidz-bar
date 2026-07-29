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

    // The player to follow: whichever one is actually playing, else the first
    // that can be controlled at all. Picking "the first" outright means a
    // paused browser tab outranks the music.
    readonly property var player: {
        let fallback = null;
        for (const p of Mpris.players.values) {
            if (p.playbackState === MprisPlaybackState.Playing)
                return p;
            if (!fallback && p.canControl)
                fallback = p;
        }
        return fallback;
    }

    readonly property bool have: player !== null
    readonly property bool playing:
        have && player.playbackState === MprisPlaybackState.Playing

    // `shown`, not `visible` -- see ModuleLoader. This is the module that made
    // it necessary: idle, it still measures its transport controls, its pinned
    // title and its visualiser, so its slot reserved 390px of nothing and the
    // centre panel drew three times wider than the clock inside it.
    property bool shown: have

    readonly property int leadTrim: 0
    readonly property int trailTrim: Cfg.pillPadding

    // ── transport ───────────────────────────────────────────────────────────

    Pill {
        icons: ["waybar-media-cava/prev.svg"]
        iconTint: Cfg.fg
        // These SVGs fill their viewBox edge to edge, with none of the margin
        // a themed icon carries, so at the pill's full height they tower over
        // every other glyph on the bar. Two thirds puts their ink on the same
        // optical size as the status icons beside them.
        iconScale: 0.66
        paddingX: 0
        fixedWidth: iconSize + 2 * Cfg.borderWidth + 1
        onClicked: if (root.have) root.player.previous()
    }

    Pill {
        // The ACTION, not the state: a playing track offers pause.
        icons: [root.playing ? "waybar-media-cava/pause.svg"
                             : "waybar-media-cava/play.svg"]
        iconTint: Cfg.fg
        iconScale: 0.66
        paddingX: 0
        fixedWidth: iconSize + 2 * Cfg.borderWidth + 1
        onClicked: if (root.have) root.player.togglePlaying()
    }

    Pill {
        icons: ["waybar-media-cava/next.svg"]
        iconTint: Cfg.fg
        iconScale: 0.66
        paddingX: 0
        fixedWidth: iconSize + 2 * Cfg.borderWidth + 1
        onClicked: if (root.have) root.player.next()
    }

    // ── the track ───────────────────────────────────────────────────────────

    Pill {
        id: track

        text: {
            if (!root.have)
                return "";
            const t = root.player.trackTitle || "";
            const a = root.player.trackArtist || "";
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
        onClicked: if (root.have) root.player.togglePlaying()

        // While something is playing the leading glyph is a live spectrum;
        // paused or silent, it falls back to the transport glyph.
        icons: viz.showing ? [] : [root.playing ? "waybar-media-cava/pause.svg"
                                                : "waybar-media-cava/play.svg"]
        // The spectrum is not an icon, so the pill reserves room for it and
        // hands back the slot to put it in -- positioning it by hand drew it
        // over the title, and then, once the label made room, left it stranded
        // at the pill's left edge while the room itself moved with the centred
        // row.
        leadingSpace: viz.showing ? viz.implicitWidth : 0

        Spectrum {
            id: viz
            parent: track.leadingSlot
            anchors.fill: parent
            running: Cfg.mediaViz && root.playing
        }
    }
}
