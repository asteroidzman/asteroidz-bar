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

    visible: have

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
        fixedWidth: Cfg.mediaWidth
        onClicked: if (root.have) root.player.togglePlaying()

        // While something is playing the leading glyph is a live spectrum;
        // paused or silent, it falls back to the transport glyph.
        icons: viz.showing ? [] : [root.playing ? "waybar-media-cava/pause.svg"
                                                : "waybar-media-cava/play.svg"]

        Spectrum {
            id: viz
            anchors.verticalCenter: parent.verticalCenter
            x: track.paddingX + Cfg.borderWidth
            height: track.iconSize
            width: track.iconSize
            running: Cfg.mediaViz && root.playing
        }
    }
}
