// Displays and wallpaper: the waybar-display plugin, as a bar module.
//
// Two tabs, the same two that plugin had, because they are the two things
// people open a display panel for -- change a screen, or change what is on it.
// Everything the Display tab does now goes through dispatches
// (set_output_mode/scale/position/vrr/icc, toggle_hdr): the compositor kept
// those apply paths when its own bar was taken out, so this panel drives the
// same tested code the popover used to.
//
// A settings panel, not a menu, so it is a Popover with a form in it rather
// than a list of rows. That is the one place this shell deliberately does more
// than the native bar could: the compositor's popover was rows and nothing
// else, which is why picking a resolution there meant drilling into a submenu.

import Quickshell
import Quickshell.Io
import QtQuick
import ".."

Pill {
    id: root

    property var bar: null

    icons: ["waybar-display/display.svg"]
    iconTint: Cfg.fg
    paddingX: 0
    fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

    onClicked: button => {
        if (button === Qt.LeftButton && bar)
            bar.showPanel(root, panelComponent);
    }

    Component {
        id: panelComponent

        Item {
            id: panel
            implicitWidth: 460
            implicitHeight: tabs.height + content.implicitHeight + 24

            property int tab: 0
            // Selected output, by name. Empty means the focused one.
            property string selected: Compositor.focusedMonitor

            readonly property var outputs: {
                void Compositor.generation;
                const out = [];
                for (const k in Compositor.monitors)
                    out.push(Compositor.monitors[k]);
                return out;
            }

            readonly property var current: {
                void Compositor.generation;
                return Compositor.monitor(panel.selected)
                    || (outputs.length ? outputs[0] : null);
            }

            // The active mode, which is where the current refresh rate lives.
            // There is no `refresh` field on the monitor itself -- the modes
            // array carries a `current` flag instead, and reading a field that
            // does not exist would have shown an empty refresh picker on every
            // output rather than failing loudly.
            readonly property var activeMode: {
                const modes = (current && current.modes) || [];
                for (const m of modes)
                    if (m.current)
                        return m;
                return null;
            }

            // The logical size is width/height DIVIDED by the scale, so it is
            // not a mode. Compare against the mode list in mode terms.
            readonly property string currentRes:
                activeMode ? activeMode.width + "x" + activeMode.height : ""

            function dispatch(cmd) {
                Ipc.dispatch("dispatch " + cmd);
            }

            Row {
                id: tabs
                spacing: 4
                height: 32

                Repeater {
                    model: ["Display", "Wallpaper"]
                    delegate: Rectangle {
                        required property string modelData
                        required property int index

                        width: 100
                        height: 28
                        radius: Cfg.themeRadius
                        color: panel.tab === index ? Cfg.focusBg
                                                   : Qt.rgba(1, 1, 1, 0.06)

                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: panel.tab === index ? Cfg.focusFg : Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize * 0.8
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        TapHandler { onTapped: panel.tab = index }
                    }
                }
            }

            Loader {
                id: content
                anchors.top: tabs.bottom
                anchors.topMargin: 12
                width: parent.width
                sourceComponent: panel.tab === 0 ? displayTab : wallpaperTab
            }

            // ── Display ─────────────────────────────────────────────────────

            Component {
                id: displayTab

                Column {
                    spacing: 8

                    // The arrangement, drawn to scale and draggable. A list
                    // could describe an arrangement ("DP-1 is left of HDMI-A-1")
                    // but not let you fix one, and a monitor layout is a
                    // relationship between rectangles.
                    Arrange {
                        width: parent.width
                        height: 150
                        outputs: panel.outputs
                        selected: panel.selected
                        onPicked: name => panel.selected = name
                        onMoved: (name, x, y) =>
                            panel.dispatch("set_output_position," + name
                                           + "," + x + "," + y)
                    }

                    Text {
                        text: panel.current
                            ? panel.current.name + "  ·  " + panel.currentRes
                              + (panel.activeMode
                                 ? "@" + Math.round(panel.activeMode.refresh / 1000)
                                 : "")
                              + (panel.current.hdr ? "  ·  HDR" : "")
                            : "no output"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize * 0.9
                        font.hintingPreference: Font.PreferFullHinting
                    }

                    // Resolution. Only modes the output actually reports: a
                    // mode wlroots did not advertise cannot be committed, and
                    // offering one only moves the failure later.
                    FormRow {
                        label: "Resolution"
                        width: parent.width
                        control: Picker {
                            values: {
                                const seen = {};
                                const out = [];
                                const modes = (panel.current
                                               && panel.current.modes) || [];
                                for (const m of modes) {
                                    const k = m.width + "x" + m.height;
                                    if (!seen[k]) {
                                        seen[k] = true;
                                        out.push(k);
                                    }
                                }
                                return out;
                            }
                            current: panel.currentRes
                            onPicked: v =>
                                panel.dispatch("set_output_mode,"
                                               + panel.current.name + "," + v)
                        }
                    }

                    FormRow {
                        label: "Refresh"
                        width: parent.width
                        control: Picker {
                            values: {
                                const out = [];
                                const modes = (panel.current
                                               && panel.current.modes) || [];
                                const w = panel.activeMode
                                    ? panel.activeMode.width : 0;
                                for (const m of modes) {
                                    if (m.width !== w)
                                        continue;
                                    const hz = Math.round(m.refresh / 1000);
                                    if (out.indexOf(String(hz)) < 0)
                                        out.push(String(hz));
                                }
                                return out;
                            }
                            current: panel.activeMode
                                ? String(Math.round(panel.activeMode.refresh / 1000))
                                : ""
                            onPicked: hz =>
                                panel.dispatch("set_output_mode,"
                                    + panel.current.name + ","
                                    + panel.currentRes + "@" + hz)
                        }
                    }

                    // Fractional scaling is real here -- this desktop runs an
                    // output at 0.75 -- so the list spans below 1 as well as
                    // above, and stays short enough to read at a glance.
                    FormRow {
                        label: "Scale"
                        width: parent.width
                        control: Picker {
                            values: ["0.75", "1", "1.25", "1.5", "1.75", "2"]
                            current: panel.current
                                ? String(panel.current.scale) : "1"
                            onPicked: v =>
                                panel.dispatch("set_output_scale,"
                                               + panel.current.name + "," + v)
                        }
                    }

                    FormRow {
                        label: "VRR"
                        width: parent.width
                        control: Toggle {
                            // vrr_enabled is the persisted SETTING. `vrr` is
                            // the live per-client answer, which is false while
                            // nothing on screen is driving adaptive sync -- a
                            // switch bound to that would flick itself off.
                            on: panel.current
                                ? panel.current.vrr_enabled === true : false
                            onToggled: v =>
                                panel.dispatch("set_output_vrr,"
                                    + panel.current.name + "," + (v ? 1 : 0))
                        }
                    }

                    FormRow {
                        label: "HDR"
                        width: parent.width
                        // Hidden on an output that cannot do it: a control that
                        // visibly does nothing is worse than an absent one.
                        visible: panel.current
                                 && panel.current.hdr_capable === true
                        control: Toggle {
                            on: panel.current ? panel.current.hdr === true : false
                            // toggle_hdr acts on the FOCUSED output, so move
                            // focus there first -- the same two-step the tag
                            // pills do for `view`.
                            onToggled: {
                                if (Compositor.focusedMonitor !== panel.current.name)
                                    panel.dispatch("focus_monitor,"
                                                   + panel.current.name);
                                panel.dispatch("toggle_hdr");
                            }
                        }
                    }

                    FormRow {
                        label: "ICC profile"
                        width: parent.width
                        control: Field {
                            text: (panel.current && panel.current.icc_profile) || ""
                            placeholder: "/path/to/profile.icm (SDR)"
                            onCommitted: v =>
                                panel.dispatch("set_output_icc,"
                                               + panel.current.name + "," + v)
                        }
                    }
                }
            }

            // ── Wallpaper ───────────────────────────────────────────────────

            Component {
                id: wallpaperTab

                Column {
                    spacing: 8

                    FormRow {
                        label: "Folder"
                        width: parent.width
                        control: Field {
                            text: Wallpaper.folder
                            onCommitted: v => Wallpaper.setKey("folder", v)
                        }
                    }

                    FormRow {
                        label: "Cycle (min, 0=off)"
                        width: parent.width
                        control: Field {
                            text: String(Math.round(Wallpaper.interval / 60))
                            onCommitted: v =>
                                Wallpaper.setKey("interval",
                                                 String(Math.round(Number(v) * 60)))
                        }
                    }

                    FormRow {
                        label: "Order"
                        width: parent.width
                        control: Picker {
                            values: ["random", "sequential"]
                            current: Wallpaper.order
                            onPicked: v => Wallpaper.setKey("order", v)
                        }
                    }

                    // The browser. Thumbnails rather than a list of filenames,
                    // because nobody recognises a wallpaper by its name.
                    GridView {
                        width: parent.width
                        height: 220
                        cellWidth: Math.floor(width / 3)
                        cellHeight: Math.floor(cellWidth * 9 / 16)
                        clip: true
                        model: Wallpaper.available

                        delegate: Item {
                            required property string modelData
                            width: GridView.view.cellWidth - 6
                            height: GridView.view.cellHeight - 6

                            Image {
                                anchors.fill: parent
                                source: "file://" + modelData
                                fillMode: Image.PreserveAspectCrop
                                // Thumbnails, not wallpapers: asking for the
                                // full 4K decode of every file in the folder
                                // to draw a 140px tile is how a browser like
                                // this eats a gigabyte.
                                sourceSize.width: 320
                                asynchronous: true
                                clip: true
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                border.width: modelData === Wallpaper.path ? 3 : 0
                                border.color: Cfg.focusBg
                            }

                            TapHandler {
                                onTapped: Wallpaper.setKey("wallpaper", modelData)
                            }
                        }
                    }
                }
            }
        }
    }
}
