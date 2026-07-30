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
            // Wide enough for a label column that fits its longest label at
            // whatever size the theme is, plus a control beside it. FormRow
            // reserves Cfg.fontPixelSize * 8 for the label alone, so a panel
            // fixed at 460 was already squeezing the controls at any font
            // larger than the default. The floor keeps small themes from
            // producing a panel narrower than the tabs it has to hold.
            //
            // Safe to change: Popover latches its width from this at open and
            // the panel loads before `visible` goes true, so the surface never
            // resizes while mapped -- see Popover.qml, which explains at length
            // why that is not optional.
            implicitWidth: Math.max(460, Math.round(Cfg.fontPixelSize * 22))
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

            // ── staged edits ────────────────────────────────────────────────
            //
            // Nothing here applies as you touch it. A display panel that acts
            // on every keystroke and every list pick makes a mode set out of
            // passing THROUGH a value on the way to the one you wanted, and a
            // mode set is a black screen for a moment -- so choosing 2560x1440
            // from a list of a dozen used to walk the monitor through whatever
            // you scrolled past. Edits collect here and go together on Apply.
            property var pending: ({})
            readonly property int pendingCount: Object.keys(pending).length

            // Cleared when the selected output changes: a scale staged for one
            // monitor must not be applied to the next one you click on.
            onSelectedChanged: pending = ({})

            function stage(key, value) {
                const p = Object.assign({}, pending);
                p[key] = value;
                pending = p;
            }

            // The staged value if there is one, else what the output reports.
            function staged(key, live) {
                return pending[key] !== undefined ? pending[key] : live;
            }

            function applyPending() {
                const c = panel.current;
                if (!c) {
                    pending = ({});
                    return;
                }
                const p = pending;
                const name = c.name;

                // Resolution and refresh are one dispatch: set_output_mode
                // takes WxH@Hz, so staging them separately and sending two
                // would mode-set twice, the first time to a rate the new
                // resolution may not even offer.
                if (p.res !== undefined || p.hz !== undefined) {
                    const res = p.res !== undefined ? p.res : panel.currentRes;
                    const hz = p.hz !== undefined
                        ? p.hz
                        : (panel.activeMode
                           ? String(Math.round(panel.activeMode.refresh / 1000))
                           : "");
                    dispatch("set_output_mode," + name + "," + res
                             + (hz ? "@" + hz : ""));
                }
                if (p.scale !== undefined)
                    dispatch("set_output_scale," + name + "," + p.scale);
                if (p.x !== undefined || p.y !== undefined) {
                    dispatch("set_output_position," + name + ","
                             + (p.x !== undefined ? p.x : c.x) + ","
                             + (p.y !== undefined ? p.y : c.y));
                }
                if (p.vrr !== undefined)
                    dispatch("set_output_vrr," + name + "," + (p.vrr ? 1 : 0));
                // The per-output HDR BASELINE, not a runtime flip: the
                // compositor resolves it against the global hdr-mode policy and
                // any force_hdr client, and remembers it either way.
                if (p.hdr !== undefined)
                    dispatch("set_output_hdr," + name + "," + (p.hdr ? 1 : 0));
                if (p.icc !== undefined)
                    dispatch("set_output_icc," + name + "," + p.icc);

                pending = ({});
            }

            // Tabs sized from their LABEL, not from a constant.
            //
            // These were `width: 100` with a centred Text that had no width, no
            // elide and no clip. At the shipped theme "Wallpaper" is wider than
            // 100px, so it overflowed its pill symmetrically, ate the 4px gap,
            // and was then painted over by the neighbouring rect -- which reads
            // as two bugs at once, tabs touching and text cut off, from one
            // cause. Everything here now derives from Cfg.fontPixelSize, the
            // way FormRow and Picker already did.
            // No explicit height: a Row already takes its implicitHeight from
            // its tallest child, and childrenRect.height inside a positioner
            // is a binding loop waiting to happen.
            Row {
                id: tabs
                spacing: Cfg.spacing

                Repeater {
                    model: ["Display", "Wallpaper"]
                    delegate: Rectangle {
                        required property string modelData
                        required property int index

                        // The label plus a breath of padding on each side. The
                        // cap is a backstop, not the normal case: a tab name
                        // long enough to hit it should elide rather than push
                        // the row wider than the panel.
                        readonly property int maxWidth:
                            Math.round(panel.implicitWidth / 3)
                        width: Math.min(maxWidth,
                                        Math.round(label.implicitWidth
                                                   + Cfg.fontPixelSize * 1.4))
                        height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))
                        radius: Cfg.themeRadius
                        color: panel.tab === index ? Cfg.focusBg
                                                   : Qt.rgba(1, 1, 1, 0.06)

                        Text {
                            id: label
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth,
                                            parent.width
                                            - Math.round(Cfg.fontPixelSize * 0.8))
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData
                            color: panel.tab === index ? Cfg.focusFg : Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
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
                        // Font-derived, because Arrange now reserves a band at
                        // the bottom for its hint and that band scales with the
                        // theme. At a fixed 150 the tiles lost ~24px of height
                        // to the reservation; this gives it back, so a
                        // two-monitor layout draws at the size it did before.
                        height: Math.round(Cfg.fontPixelSize * 8)
                        outputs: panel.outputs
                        selected: panel.selected
                        onPicked: name => panel.selected = name
                        // Staged like everything else. The drag still snaps
                        // and still shows where the monitor will land; it just
                        // does not rearrange the desktop until Apply.
                        onMoved: (name, x, y) => {
                            panel.stage("x", x);
                            panel.stage("y", y);
                        }
                    }

                    // Elided: an output name is whatever the display's EDID
                    // says it is, and a long one used to run off the panel.
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: panel.current
                            ? panel.current.name + "  ·  " + panel.currentRes
                              + (panel.activeMode
                                 ? "@" + Math.round(panel.activeMode.refresh / 1000)
                                 : "")
                              + (panel.current.hdr ? "  ·  HDR" : "")
                            : "no output"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.hintingPreference: Font.PreferFullHinting
                    }

                    // Resolution. Only modes the output actually reports: a
                    // mode wlroots did not advertise cannot be committed, and
                    // offering one only moves the failure later.
                    FormRow {
                        label: "Resolution"
                        width: parent.width
                        control: Picker {
                            // Every distinct resolution the output actually
                            // reports, largest first -- a mode wlroots did not
                            // advertise cannot be committed, and offering one
                            // only moves the failure later.
                            values: {
                                const seen = {};
                                const out = [];
                                const modes = (panel.current
                                               && panel.current.modes) || [];
                                for (const m of modes) {
                                    const k = m.width + "x" + m.height;
                                    if (!seen[k]) {
                                        seen[k] = true;
                                        out.push({ k: k, w: m.width, h: m.height });
                                    }
                                }
                                out.sort((a, b) => b.w - a.w || b.h - a.h);
                                return out.map(e => e.k);
                            }
                            current: panel.staged("res", panel.currentRes)
                            onPicked: v => panel.stage("res", v)
                        }
                    }

                    FormRow {
                        label: "Refresh"
                        width: parent.width
                        control: Picker {
                            // The rates available AT THE CURRENT RESOLUTION,
                            // matched on both dimensions: two modes can share
                            // a width and differ in height, and offering
                            // 1920x1080's rates while 1920x1200 is on screen
                            // produces a mode string the output does not have.
                            // Highest first, which is the one people want.
                            values: {
                                const out = [];
                                const modes = (panel.current
                                               && panel.current.modes) || [];
                                const w = panel.activeMode
                                    ? panel.activeMode.width : 0;
                                const h = panel.activeMode
                                    ? panel.activeMode.height : 0;
                                for (const m of modes) {
                                    if (m.width !== w || m.height !== h)
                                        continue;
                                    const hz = Math.round(m.refresh / 1000);
                                    if (out.indexOf(String(hz)) < 0)
                                        out.push(String(hz));
                                }
                                out.sort((a, b) => Number(b) - Number(a));
                                return out;
                            }
                            current: panel.staged("hz", panel.activeMode
                                ? String(Math.round(panel.activeMode.refresh / 1000))
                                : "")
                            onPicked: hz => panel.stage("hz", hz)
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
                            current: panel.staged("scale", panel.current
                                ? String(panel.current.scale) : "1")
                            onPicked: v => panel.stage("scale", v)
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
                            on: panel.staged("vrr", panel.current
                                ? panel.current.vrr_enabled === true : false)
                            onToggled: v => panel.stage("vrr", v)
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
                            // hdr_enabled, not hdr: `hdr` is what the output is
                            // REALLY doing right now, which the global hdr-mode
                            // policy or a force_hdr client can be overriding.
                            // A switch has to show the setting it writes, or it
                            // flips back under you -- the same reason the VRR
                            // row reads vrr_enabled.
                            on: panel.staged("hdr", panel.current
                                ? panel.current.hdr_enabled === true : false)
                            onToggled: v => panel.stage("hdr", v)
                        }
                    }

                    FormRow {
                        label: "ICC profile"
                        width: parent.width
                        control: Field {
                            text: panel.staged("icc",
                                (panel.current && panel.current.icc_profile) || "")
                            placeholder: "/path/to/profile.icm (SDR)"
                            onCommitted: v => panel.stage("icc", v)
                        }
                    }

                    // Apply / Revert. Present but inert when nothing is
                    // staged, rather than appearing and disappearing -- a row
                    // that materialises on first edit shifts everything under
                    // it, which moves the control you were about to click.
                    Item {
                        width: parent.width
                        height: Math.max(34, Math.round(Cfg.fontPixelSize * 2.0))

                        // Measured, not drawn: both buttons need the width of
                        // BOTH labels to size themselves alike, and a delegate
                        // cannot see its sibling's Text.
                        TextMetrics {
                            id: revertMetrics
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            text: "Revert"
                        }
                        TextMetrics {
                            id: applyMetrics
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            text: "Apply"
                        }

                        // Yields to the buttons rather than overrunning them:
                        // the status text is the expendable half of this row.
                        Text {
                            anchors.left: parent.left
                            anchors.right: buttons.left
                            anchors.rightMargin: Cfg.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: panel.pendingCount === 0
                                ? "no changes"
                                : panel.pendingCount + " change"
                                  + (panel.pendingCount === 1 ? "" : "s")
                                  + " pending"
                            color: panel.pendingCount === 0
                                ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                                : Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Row {
                            id: buttons
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Cfg.spacing

                            Repeater {
                                model: ["Revert", "Apply"]
                                delegate: Rectangle {
                                    required property string modelData
                                    readonly property bool primary:
                                        modelData === "Apply"
                                    readonly property bool live:
                                        panel.pendingCount > 0

                                    // Sized from the label, like the tabs. Both
                                    // buttons take the WIDER of the two labels
                                    // so the pair stays symmetric -- a Revert
                                    // narrower than Apply reads as an accident.
                                    width: Math.round(
                                        Math.max(revertMetrics.width,
                                                 applyMetrics.width)
                                        + Cfg.fontPixelSize * 2.0)
                                    height: Math.max(28, Math.round(
                                        Cfg.fontPixelSize * 1.6))
                                    radius: Cfg.themeRadius
                                    opacity: live ? 1.0 : 0.4
                                    color: primary && live
                                        ? Cfg.focusBg
                                        : Qt.rgba(1, 1, 1, 0.08)

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: parent.primary && parent.live
                                            ? Cfg.focusFg : Cfg.fg
                                        font.family: Cfg.fontFamily
                                        font.pointSize: Cfg.fontSize
                                        font.hintingPreference: Font.PreferFullHinting
                                    }

                                    TapHandler {
                                        enabled: parent.live
                                        onTapped: {
                                            if (parent.primary)
                                                panel.applyPending();
                                            else
                                                panel.pending = ({});
                                        }
                                    }
                                }
                            }
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
                        label: "Cycle (min)"
                        width: parent.width
                        control: Field {
                            placeholder: "0 = off"
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
