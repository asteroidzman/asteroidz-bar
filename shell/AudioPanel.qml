// Sound, in a panel under the volume pill.
//
// It replaces a menu. The old one listed the sinks and nothing else: the level
// was readable only off the pill, changing it meant a wheel gesture on that
// pill with no visible target, and what an individual application was playing
// at was not shown anywhere at all. Every one of those is a thing PipeWire
// already tells us.
//
// The shape is DankMaterialShell's audio panel, deliberately -- a master row
// whose icon is the mute button and whose slider carries the reading, then the
// outputs as cards with the active one outlined, then the streams that are
// actually playing, each with its own slider. Their AudioSliderRow.qml and
// ControlCenter/Details/AudioOutputDetail.qml are what this is a port of; the
// colours, fonts and radii are this shell's, because a panel that brought its
// own palette would be a different application sitting in the same bar.
//
// Not ported: the per-device pinning (a preference stored in their cache for
// picking a default automatically -- there is nothing here that would read
// it), and the device-type artwork. This bar's icon set is illustrated rather
// than a symbol font, so there is no headset/tv/speaker glyph to draw and a
// speaker on every row would say nothing anyway. The outline and the word
// "Active" carry it.

import Quickshell
import Quickshell.Services.Pipewire
import QtQuick
import "."

Item {
    id: root

    signal closeRequested()

    // Wide enough for a device name to be worth reading. Sink descriptions are
    // things like "Family 17h/19h HD Audio Controller Digital Stereo (HDMI 2)",
    // so this is a question of how much elides, not whether.
    implicitWidth: Math.max(340, Cfg.popoverWidth)
    implicitHeight: col.implicitHeight

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool have: sink !== null && sink.audio !== null

    // Every node the panel draws, bound at once.
    //
    // A PipeWire node reports whatever it held when it was first seen until
    // something binds it, so an unbound row shows a volume that never moves --
    // which looks exactly like a slider that does not work. The pill only ever
    // needed the default sink; this needs all of them and the streams too.
    PwObjectTracker {
        objects: {
            const out = [];
            for (const node of Pipewire.nodes.values) {
                if (node.audio && node.isSink)
                    out.push(node);
            }
            return out;
        }
    }

    readonly property var sinks: {
        void Pipewire.nodes.values;
        const out = [];
        for (const node of Pipewire.nodes.values) {
            if (node.audio && node.isSink && !node.isStream)
                out.push(node);
        }
        // The current one first, then by name, so the list does not reorder
        // itself under the pointer when something is plugged in.
        out.sort((a, b) => {
            if (a === root.sink)
                return -1;
            if (b === root.sink)
                return 1;
            return name(a).toLowerCase() < name(b).toLowerCase() ? -1 : 1;
        });
        return out;
    }

    readonly property var streams: {
        void Pipewire.nodes.values;
        const out = [];
        for (const node of Pipewire.nodes.values) {
            if (node.audio && node.isSink && node.isStream)
                out.push(node);
        }
        return out;
    }

    // What to call a node. DMS's AudioService.displayName, in the order it
    // tries them: the description a device gives itself is the one a person
    // recognises, and `node.name` is the last resort because it is the
    // machine's ("alsa_output.pci-0000_0c_00.1.hdmi-stereo").
    function name(node) {
        if (!node)
            return "";
        const props = node.properties || ({});
        if (props["node.description"] && props["node.description"] !== node.name)
            return props["node.description"];
        if (node.description && node.description !== node.name)
            return node.description;
        if (props["device.description"])
            return props["device.description"];
        if (node.nickname && node.nickname !== node.name)
            return node.nickname;
        return node.name || "";
    }

    // An application's own name for what it is playing, where it has one --
    // "Spotify: Blue Monday" rather than twice the same word.
    //
    // Not every stream has an application.name. This machine's desktop-audio
    // loopback has none, and its node.name is "output./usr/bin/pw-loopback-
    // 3835816" while its media.name is that same path with " output" on the
    // end -- so the obvious two fields joined by a colon printed the same
    // unreadable path twice. What is wanted from a path is its last component,
    // and what is wanted from a media name is the part that is not already in
    // the application's.
    function streamLabel(node) {
        const props = node.properties || ({});
        let app = props["application.name"] || props["application.process.binary"] || "";
        if (!app) {
            app = props["node.description"] || node.description || node.name || "";
            app = app.replace(/^output\./, "");
            if (app.includes("/"))
                app = app.slice(app.lastIndexOf("/") + 1);
            app = app.replace(/-\d+$/, "");  // the pid pipewire appends
        }
        const media = props["media.name"] || "";
        if (!media || media.includes(app) || app.includes(media))
            return app;
        return app + ": " + media;
    }

    function icon(muted, volume) {
        if (muted || volume <= 0)
            return "asteroidz-bar/volume/vol-mute.svg";
        if (volume < 0.34)
            return "asteroidz-bar/volume/vol-low.svg";
        if (volume < 0.67)
            return "asteroidz-bar/volume/vol-med.svg";
        return "asteroidz-bar/volume/vol-high.svg";
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // ── the master row ──────────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Sound"
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.weight: Font.DemiBold
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.have && root.sink.audio.muted
                text: "muted"
                color: Cfg.urgent
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                font.hintingPreference: Font.PreferFullHinting
            }
        }

        Row {
            width: parent.width
            spacing: Cfg.spacing
            height: Math.round(Cfg.fontPixelSize * 2)

            // The icon IS the mute button, which is the one piece of DMS's
            // layout that does real work: mute is the thing you reach for in a
            // hurry, and it is already the glyph you are looking at.
            Rectangle {
                id: muteButton
                width: parent.height
                height: parent.height
                radius: width / 2
                color: muteHover.hovered ? Qt.rgba(1, 1, 1, 0.12) : "transparent"

                Icon {
                    anchors.centerIn: parent
                    name: root.icon(root.have && root.sink.audio.muted,
                                    root.have ? root.sink.audio.volume : 0)
                    size: Math.round(Cfg.fontPixelSize * 1.1)
                    tint: root.have && !root.sink.audio.muted
                          && root.sink.audio.volume > 0
                          ? Cfg.focusBg
                          : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                }

                HoverHandler { id: muteHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    enabled: root.have
                    onTapped: root.sink.audio.muted = !root.sink.audio.muted
                }
            }

            Slider {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - muteButton.width - Cfg.spacing
                enabled: root.have
                from: 0
                to: 100
                stepSize: 1
                unit: "%"
                wheelStep: Cfg.volumeStep
                // `target`, not `value`: the drag writes `value`, and a
                // binding on it dies at the first movement. See Slider.qml.
                target: root.have ? Math.round(root.sink.audio.volume * 100) : 0
                // Unmuting on a drag rather than leaving the level moving
                // silently: dragging a volume slider is asking to hear
                // something.
                onMoved: v => {
                    if (!root.have)
                        return;
                    root.sink.audio.volume = v / 100;
                    if (v > 0 && root.sink.audio.muted)
                        root.sink.audio.muted = false;
                }
            }
        }

        // ── the outputs ─────────────────────────────────────────────────────
        Text {
            width: parent.width
            text: "Output"
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.weight: Font.DemiBold
            font.hintingPreference: Font.PreferFullHinting
        }

        // Bounded and scrollable, not tall: the popover caps its own height and
        // silently loses whatever is past the cap, which on a machine with six
        // sinks would be the streams below.
        Flickable {
            width: parent.width
            height: Math.min(outputs.implicitHeight, Math.round(Cfg.fontPixelSize * 11))
            contentWidth: width
            contentHeight: outputs.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: outputs
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.sinks

                    delegate: Rectangle {
                        id: device
                        required property var modelData
                        readonly property bool current: modelData === root.sink

                        width: outputs.width
                        height: Math.round(Cfg.fontPixelSize * 2.4)
                        radius: Cfg.themeRadius
                        color: deviceHover.hovered ? Qt.rgba(1, 1, 1, 0.10)
                                                   : Qt.rgba(1, 1, 1, 0.05)
                        border.width: current ? 2 : 1
                        border.color: current ? Cfg.focusBg : Qt.rgba(1, 1, 1, 0.08)

                        Column {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Cfg.panelPadding
                            anchors.rightMargin: Cfg.panelPadding
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0

                            Text {
                                width: parent.width
                                text: root.name(device.modelData)
                                elide: Text.ElideRight
                                color: Cfg.fg
                                font.family: Cfg.fontFamily
                                font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
                                font.weight: device.current ? Font.DemiBold : Font.Normal
                                font.hintingPreference: Font.PreferFullHinting
                            }

                            Text {
                                width: parent.width
                                text: device.current ? "Active" : "Available"
                                color: device.current
                                       ? Cfg.focusBg
                                       : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                                font.family: Cfg.fontFamily
                                font.pointSize: Math.max(6, Cfg.fontSize * 0.7)
                                font.hintingPreference: Font.PreferFullHinting
                            }
                        }

                        HoverHandler { id: deviceHover; cursorShape: Qt.PointingHandCursor }
                        // Sets the DEFAULT rather than moving what is already
                        // playing, which is what `pactl set-default-sink` does
                        // and what people mean by picking an output. The panel
                        // stays up: picking a device is something you may want
                        // to hear the result of and then adjust.
                        TapHandler {
                            onTapped: Pipewire.preferredDefaultAudioSink = device.modelData
                        }
                    }
                }
            }
        }

        // ── what is playing ─────────────────────────────────────────────────
        Text {
            width: parent.width
            visible: root.streams.length > 0
            text: "Playing"
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.weight: Font.DemiBold
            font.hintingPreference: Font.PreferFullHinting
        }

        Flickable {
            width: parent.width
            visible: root.streams.length > 0
            height: Math.min(apps.implicitHeight, Math.round(Cfg.fontPixelSize * 9))
            contentWidth: width
            contentHeight: apps.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: apps
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.streams

                    delegate: Item {
                        id: stream
                        required property var modelData
                        readonly property bool live: modelData && modelData.audio !== null

                        width: apps.width
                        height: label.height + slider.height + 2

                        Text {
                            id: label
                            width: parent.width
                            text: root.streamLabel(stream.modelData)
                            elide: Text.ElideRight
                            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.8)
                            font.family: Cfg.fontFamily
                            font.pointSize: Math.max(6, Cfg.fontSize * 0.75)
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Row {
                            id: slider
                            anchors.top: label.bottom
                            anchors.topMargin: 2
                            width: parent.width
                            spacing: Cfg.spacing
                            height: Math.round(Cfg.fontPixelSize * 1.4)

                            Rectangle {
                                id: streamMute
                                width: parent.height
                                height: parent.height
                                radius: width / 2
                                color: streamHover.hovered ? Qt.rgba(1, 1, 1, 0.12)
                                                           : "transparent"

                                Icon {
                                    anchors.centerIn: parent
                                    name: root.icon(stream.live && stream.modelData.audio.muted,
                                                    stream.live ? stream.modelData.audio.volume : 0)
                                    size: Math.round(Cfg.fontPixelSize * 0.85)
                                    tint: stream.live && !stream.modelData.audio.muted
                                          && stream.modelData.audio.volume > 0
                                          ? Cfg.focusBg
                                          : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                                }

                                HoverHandler { id: streamHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    enabled: stream.live
                                    onTapped: stream.modelData.audio.muted =
                                              !stream.modelData.audio.muted
                                }
                            }

                            Slider {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - streamMute.width - Cfg.spacing
                                enabled: stream.live
                                from: 0
                                to: 100
                                stepSize: 1
                                unit: "%"
                                wheelStep: Cfg.volumeStep
                                target: stream.live
                                        ? Math.round(stream.modelData.audio.volume * 100) : 0
                                onMoved: v => {
                                    if (!stream.live)
                                        return;
                                    stream.modelData.audio.volume = v / 100;
                                    if (v > 0 && stream.modelData.audio.muted)
                                        stream.modelData.audio.muted = false;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
