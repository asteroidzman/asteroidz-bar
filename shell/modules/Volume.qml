// The output volume.
//
// Read from PipeWire directly rather than by forking `pactl` -- quickshell
// binds the node graph, so the default sink's volume and mute are properties
// to watch, not a subprocess to poll. That removes the fork-per-tick the
// waybar plugin this replaces performed.

import Quickshell
import Quickshell.Services.Pipewire
import QtQuick
import ".."

Pill {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool have: sink !== null && sink.audio !== null
    readonly property bool muted: have && sink.audio.muted
    readonly property int pct: have ? Math.round(sink.audio.volume * 100) : 0

    // Bind the default sink so its volume actually tracks; an unbound node
    // reports whatever it held when it was first seen.
    PwObjectTracker { objects: root.sink ? [root.sink] : [] }

    icons: [muted || pct === 0 ? "waybar-volume/vol-mute.svg"
          : pct < 34 ? "waybar-volume/vol-low.svg"
          : pct < 67 ? "waybar-volume/vol-med.svg"
                     : "waybar-volume/vol-high.svg"]

    // Dimmed while muted, so it reads as inactive like a resting metric.
    iconTint: muted ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                    : Cfg.fg

    // The level is shown even when muted: unmuting restores it, so hiding it
    // behind a dash just means looking up what you are about to get. Mute is
    // carried by the crossed-out glyph and the dimmed tint instead.
    text: have ? pct + "%" : ""

    // Pinned per DIGIT COUNT, not to the widest reading there is. Digits are
    // proportional, so an unpinned pill twitches on every step of a volume
    // ramp -- but pinning everything to "100%" leaves a two-digit level
    // floating in a hole a whole digit wide. This way the width is stable
    // through a ramp and steps only at 9->10 and 99->100, which is a moment
    // the pill is visibly changing anyway.
    //
    // Through widthForText, so the speaker glyph keeps its advance. Pinning
    // to the level alone left this pill ~28px narrow, and content overflows a
    // pill rather than being clipped -- so what it looked like was the volume
    // pill jammed against its neighbours with no space either side.
    fixedWidth: !have ? 0
              : widthForText(pct >= 100 ? m100.width
                           : pct >= 10 ? m88.width : m8.width)

    TextMetrics { id: m100; font: root.textFont; text: "100%" }
    TextMetrics { id: m88; font: root.textFont; text: "88%" }
    TextMetrics { id: m8; font: root.textFont; text: "8%" }

    onWheel: delta => {
        if (!have)
            return;
        const step = Cfg.volumeStep / 100.0;
        sink.audio.volume = Math.max(0, Math.min(1,
            sink.audio.volume + (delta > 0 ? step : -step)));
    }

    property var bar: null

    onClicked: button => {
        if (button === Qt.MiddleButton && have) {
            sink.audio.muted = !sink.audio.muted;
            return;
        }
        if (button !== Qt.LeftButton || !bar)
            return;

        // Every sink that can actually play, with the current one checked.
        // Picking one sets the DEFAULT rather than moving streams, which is
        // what `pactl set-default-sink` did and what people mean by "output".
        const rows = [{
            text: have ? (muted ? "Muted  " : "Volume  ") + pct + "%"
                       : "no audio server",
            enabled: false
        }, { separator: true }];

        for (const node of Pipewire.nodes.values) {
            if (!node.isSink || !node.audio)
                continue;
            rows.push({
                text: node.nickname || node.description || node.name,
                checked: sink && node.id === sink.id,
                value: String(node.id),
                node: node
            });
        }
        bar.showMenu(root, rows);
    }
}
