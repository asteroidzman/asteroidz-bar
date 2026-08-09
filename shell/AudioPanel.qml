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

    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool haveSource: source !== null && source.audio !== null

    // Every node the panel draws, bound at once.
    //
    // A PipeWire node reports whatever it held when it was first seen until
    // something binds it, so an unbound row shows a volume that never moves --
    // which looks exactly like a slider that does not work. The pill only ever
    // needed the default sink; this needs all of them, the sources, and the
    // streams.
    PwObjectTracker {
        objects: {
            const out = [];
            for (const node of Pipewire.nodes.values) {
                if (node.audio)
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

    // The microphones. Same rule as the sinks, the other way round -- a source
    // that is a stream is an application RECORDING, not a device.
    readonly property var sources: {
        void Pipewire.nodes.values;
        const out = [];
        for (const node of Pipewire.nodes.values) {
            if (node.audio && !node.isSink && !node.isStream)
                out.push(node);
        }
        out.sort((a, b) => {
            if (a === root.source)
                return -1;
            if (b === root.source)
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

    // A microphone has two states and not four. There is no "quiet mic" glyph
    // in this icon set and there should not be: a level below half is a normal
    // way to record, where a volume below half is a thing you did on purpose
    // and want to see.
    function micIcon(muted, volume) {
        return muted || volume <= 0 ? "asteroidz-bar/volume/mic-mute.svg"
                                    : "asteroidz-bar/volume/mic.svg";
    }

    // The tint every one of these rows uses: the accent while it is doing
    // something, the foreground dimmed while it is not.
    function liveTint(live) {
        return live ? Cfg.focusBg
                    : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55);
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
                font.weight: Cfg.fontWeightEmphasis
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                font.weight: Cfg.fontWeight
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.have && root.sink.audio.muted
                text: "muted"
                color: Cfg.urgent
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
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
            font.pointSize: Cfg.fontSizeSmall
            font.weight: Cfg.fontWeightEmphasis
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

                    // Sets the DEFAULT rather than moving what is already
                    // playing, which is what `pactl set-default-sink` does and
                    // what people mean by picking an output.
                    delegate: AudioDeviceRow {
                        required property var modelData
                        width: outputs.width
                        label: root.name(modelData)
                        current: modelData === root.sink
                        onPicked: Pipewire.preferredDefaultAudioSink = modelData
                    }
                }
            }
        }

        // ── the microphone ──────────────────────────────────────────────────
        //
        // Below the outputs rather than in a tab of its own, which is where
        // DankMaterialShell keeps it: their control centre is a full-height
        // surface with room for two detail views, and this is a popover with a
        // height cap. A tab would also hide the one control here that is
        // reached in a hurry -- muting a microphone is not something you go
        // looking for a second click to do.
        //
        // The whole section is absent when there is no input at all, rather
        // than present and dead. A machine with no microphone should not be
        // told about the microphone it does not have.
        Item {
            width: parent.width
            visible: root.sources.length > 0
            height: visible ? Math.max(24, Math.round(Cfg.fontPixelSize * 1.4)) : 0

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Microphone"
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.weight: Cfg.fontWeightEmphasis
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                font.weight: Cfg.fontWeight
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.haveSource && root.source.audio.muted
                text: "muted"
                color: Cfg.urgent
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
                font.hintingPreference: Font.PreferFullHinting
            }
        }

        Row {
            width: parent.width
            visible: root.sources.length > 0
            spacing: Cfg.spacing
            height: visible ? Math.round(Cfg.fontPixelSize * 2) : 0

            Rectangle {
                id: micButton
                width: parent.height
                height: parent.height
                radius: width / 2
                color: micHover.hovered ? Qt.rgba(1, 1, 1, 0.12) : "transparent"

                Icon {
                    anchors.centerIn: parent
                    name: root.micIcon(root.haveSource && root.source.audio.muted,
                                       root.haveSource ? root.source.audio.volume : 0)
                    size: Math.round(Cfg.fontPixelSize * 1.1)
                    tint: root.liveTint(root.haveSource && !root.source.audio.muted
                                        && root.source.audio.volume > 0)
                }

                HoverHandler { id: micHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    enabled: root.haveSource
                    onTapped: root.source.audio.muted = !root.source.audio.muted
                }
            }

            Slider {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - micButton.width - Cfg.spacing
                enabled: root.haveSource
                from: 0
                to: 100
                stepSize: 1
                unit: "%"
                wheelStep: Cfg.volumeStep
                target: root.haveSource
                        ? Math.round(root.source.audio.volume * 100) : 0
                onMoved: v => {
                    if (!root.haveSource)
                        return;
                    root.source.audio.volume = v / 100;
                    if (v > 0 && root.source.audio.muted)
                        root.source.audio.muted = false;
                }
            }
        }

        // ── the inputs ──────────────────────────────────────────────────────
        //
        // Listed even when there is only one, which the outputs are too. The
        // first cut hid a single microphone on the grounds that one device is
        // not a choice -- and then the panel never said WHICH microphone the
        // slider above belonged to, on the one machine that has exactly one.
        Text {
            width: parent.width
            visible: root.sources.length > 0
            text: "Input"
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.weight: Cfg.fontWeightEmphasis
            font.hintingPreference: Font.PreferFullHinting
        }

        Flickable {
            width: parent.width
            visible: root.sources.length > 0
            height: visible
                    ? Math.min(inputs.implicitHeight, Math.round(Cfg.fontPixelSize * 9))
                    : 0
            contentWidth: width
            contentHeight: inputs.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: inputs
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.sources

                    delegate: AudioDeviceRow {
                        required property var modelData
                        width: inputs.width
                        label: root.name(modelData)
                        current: modelData === root.source
                        onPicked: Pipewire.preferredDefaultAudioSource = modelData
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
            font.pointSize: Cfg.fontSizeSmall
            font.weight: Cfg.fontWeightEmphasis
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
                            font.weight: Cfg.fontWeight
                            id: label
                            width: parent.width
                            text: root.streamLabel(stream.modelData)
                            elide: Text.ElideRight
                            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.8)
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
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
