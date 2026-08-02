// The monitors: arrangement, mode, scale, VRR, HDR and colour profile.
//
// This was the bar's display popover. It moved here whole, and the move is not
// tidying: a popover is dismissed by the first click outside it, and every way
// of judging a display change -- looking at another window, dragging something
// to the second screen, reading a number off a game -- is a click outside it.
// The panel that let you change a mode could not survive you looking at the
// result. A toplevel can, and it can also be taller than 700px and scroll,
// which the arrangement canvas and seven rows were already testing.
//
// What did NOT change is the apply model, which is the part that matters most
// here and is explained at `pending` below.
//
// Nothing on this page goes through `set-config`. Outputs are not configuration
// options -- they are hardware state, applied by dispatches
// (set_output_mode/scale/position/vrr/hdr/icc) that the compositor already had
// and already persists to monitors.kdl on its own. So this page carries its own
// Apply, the way the rule and bind pages carry their own Save, and the window's
// global apply bar is hidden while it is showing.

import QtQuick
import "."
import ".."

Item {
    id: page

    implicitHeight: col.implicitHeight

    // Selected output, by name. Seeded from the focused one, which is the
    // monitor whose settings a person opening this almost always wants.
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
        return Compositor.monitor(page.selected)
            || (outputs.length ? outputs[0] : null);
    }

    // The active mode, which is where the current refresh rate lives. There is
    // no `refresh` field on the monitor itself -- the modes array carries a
    // `current` flag instead, and reading a field that does not exist would have
    // shown an empty refresh picker on every output rather than failing loudly.
    readonly property var activeMode: {
        const modes = (current && current.modes) || [];
        for (const m of modes)
            if (m.current)
                return m;
        return null;
    }

    // The logical size is width/height DIVIDED by the scale, so it is not a
    // mode. Compare against the mode list in mode terms.
    readonly property string currentRes:
        activeMode ? activeMode.width + "x" + activeMode.height : ""

    function dispatch(cmd) {
        Ipc.dispatch("dispatch " + cmd);
    }

    // ── staged edits ────────────────────────────────────────────────────────
    //
    // Nothing here applies as you touch it, and this is the one page in the
    // window where that is true. Everywhere else a change previews live, because
    // seeing it is the point. Here, passing THROUGH a value on the way to the one
    // you wanted is a mode set, and a mode set is a black screen for a moment --
    // so picking 2560x1440 from a list of a dozen would walk the monitor through
    // whatever you scrolled past. Edits collect here and go together on Apply.
    property var pending: ({})
    readonly property int pendingCount: Object.keys(pending).length

    // Cleared when the selected output changes: a scale staged for one monitor
    // must not be applied to the next one you click on.
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
        const c = page.current;
        if (!c) {
            pending = ({});
            return;
        }
        const p = pending;
        const name = c.name;

        // Resolution and refresh are one dispatch: set_output_mode takes WxH@Hz,
        // so staging them separately and sending two would mode-set twice, the
        // first time to a rate the new resolution may not even offer.
        if (p.res !== undefined || p.hz !== undefined) {
            const res = p.res !== undefined ? p.res : page.currentRes;
            const hz = p.hz !== undefined
                ? p.hz
                : (page.activeMode
                   ? String(Math.round(page.activeMode.refresh / 1000))
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
        // The per-output HDR BASELINE, not a runtime flip: the compositor
        // resolves it against the global hdr-mode policy and any force_hdr
        // client, and remembers it either way.
        if (p.hdr !== undefined)
            dispatch("set_output_hdr," + name + "," + (p.hdr ? 1 : 0));
        if (p.icc !== undefined)
            dispatch("set_output_icc," + name + "," + p.icc);

        pending = ({});
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Drag a screen to arrange it, or click one to change its "
                  + "settings. Changes are applied together, so the display "
                  + "does not re-sync on every pick."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        // The arrangement, drawn to scale and draggable. A list could describe
        // an arrangement ("DP-1 is left of HDMI-A-1") but not let you fix one,
        // and a monitor layout is a relationship between rectangles.
        //
        // Taller here than it was in the popover, which is the plainest gain
        // from the move: the panel had to fit inside a surface capped at 700px
        // with six form rows under this, so the canvas was squeezed to about a
        // third of what a two-monitor layout wants.
        Arrange {
            width: parent.width
            height: Math.round(Cfg.fontPixelSize * 11)
            outputs: page.outputs
            selected: page.selected
            onPicked: name => page.selected = name
            // Staged like everything else. The drag still snaps and still shows
            // where the monitor will land; it just does not rearrange the
            // desktop until Apply.
            onMoved: (name, x, y) => {
                page.stage("x", x);
                page.stage("y", y);
            }
        }

        // Elided: an output name is whatever the display's EDID says it is, and
        // a long one used to run off the panel.
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: page.current
                ? page.current.name + "  ·  " + page.currentRes
                  + (page.activeMode
                     ? "@" + Math.round(page.activeMode.refresh / 1000)
                     : "")
                  + (page.current.hdr ? "  ·  HDR" : "")
                : "no output"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }

        FormRow {
            label: "Resolution"
            width: parent.width
            control: Picker {
                // Every distinct resolution the output actually reports, largest
                // first -- a mode wlroots did not advertise cannot be committed,
                // and offering one only moves the failure later.
                values: {
                    const seen = {};
                    const out = [];
                    const modes = (page.current && page.current.modes) || [];
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
                current: page.staged("res", page.currentRes)
                onPicked: v => page.stage("res", v)
            }
        }

        FormRow {
            label: "Refresh"
            width: parent.width
            control: Picker {
                // The rates available AT THE CURRENT RESOLUTION, matched on both
                // dimensions: two modes can share a width and differ in height,
                // and offering 1920x1080's rates while 1920x1200 is on screen
                // produces a mode string the output does not have. Highest
                // first, which is the one people want.
                values: {
                    const out = [];
                    const modes = (page.current && page.current.modes) || [];
                    const w = page.activeMode ? page.activeMode.width : 0;
                    const h = page.activeMode ? page.activeMode.height : 0;
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
                current: page.staged("hz", page.activeMode
                    ? String(Math.round(page.activeMode.refresh / 1000))
                    : "")
                onPicked: hz => page.stage("hz", hz)
            }
        }

        // Fractional scaling is real here -- this desktop runs an output at
        // 0.75 -- so the list spans below 1 as well as above, and stays short
        // enough to read at a glance.
        FormRow {
            label: "Scale"
            width: parent.width
            control: Picker {
                values: ["0.75", "1", "1.25", "1.5", "1.75", "2"]
                current: page.staged("scale", page.current
                    ? String(page.current.scale) : "1")
                onPicked: v => page.stage("scale", v)
            }
        }

        FormRow {
            label: "VRR"
            width: parent.width
            control: Toggle {
                // vrr_enabled is the persisted SETTING. `vrr` is the live
                // per-client answer, which is false while nothing on screen is
                // driving adaptive sync -- a switch bound to that would flick
                // itself off.
                on: page.staged("vrr", page.current
                    ? page.current.vrr_enabled === true : false)
                onToggled: v => page.stage("vrr", v)
            }
        }

        FormRow {
            label: "HDR"
            width: parent.width
            // Hidden on an output that cannot do it: a control that visibly does
            // nothing is worse than an absent one.
            visible: page.current && page.current.hdr_capable === true
            control: Toggle {
                // hdr_enabled, not hdr: `hdr` is what the output is REALLY doing
                // right now, which the global hdr-mode policy or a force_hdr
                // client can be overriding. A switch has to show the setting it
                // writes, or it flips back under you -- the same reason the VRR
                // row reads vrr_enabled.
                on: page.staged("hdr", page.current
                    ? page.current.hdr_enabled === true : false)
                onToggled: v => page.stage("hdr", v)
            }
        }

        FormRow {
            label: "ICC profile"
            width: parent.width
            control: Field {
                // `value`, not `text`: a live binding onto `text` is broken by
                // the first keystroke and then never tracks again. See Field.qml.
                value: page.staged("icc",
                    (page.current && page.current.icc_profile) || "")
                placeholder: "/path/to/profile.icm (SDR)"
                onCommitted: v => page.stage("icc", v)
            }
        }

        // Apply / Revert, this page's own.
        //
        // The window's apply bar is hidden while this page is showing, and that
        // is deliberate rather than an omission: that bar promises "preview live,
        // Apply writes to disk", and neither half is true here. Nothing previews,
        // and Apply sends dispatches the compositor persists itself.
        //
        // Present but inert when nothing is staged, rather than appearing on
        // first edit -- a row that materialises shifts everything under it, which
        // moves the control you were about to click.
        Item {
            width: parent.width
            height: Math.max(34, Math.round(Cfg.fontPixelSize * 2.0))

            // Measured, not drawn: both buttons need the width of BOTH labels to
            // size themselves alike, and a delegate cannot see its sibling's Text.
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

            // Yields to the buttons rather than overrunning them: the status text
            // is the expendable half of this row.
            Text {
                anchors.left: parent.left
                anchors.right: buttons.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                // "no changes" alone did not say that changes WAIT here, which
                // is the difference between this page and every other one. It
                // matters most when nothing is staged, which is exactly when the
                // old text was least informative.
                text: page.pendingCount === 0
                    ? "Changes wait for Apply"
                    : page.pendingCount + " change"
                      + (page.pendingCount === 1 ? "" : "s") + " pending"
                color: page.pendingCount === 0
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
                        readonly property bool primary: modelData === "Apply"
                        readonly property bool live: page.pendingCount > 0

                        // Both buttons take the WIDER of the two labels so the
                        // pair stays symmetric -- a Revert narrower than Apply
                        // reads as an accident.
                        width: Math.round(Math.max(revertMetrics.width,
                                                   applyMetrics.width)
                                          + Cfg.fontPixelSize * 2.0)
                        height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))
                        radius: Cfg.themeRadius
                        opacity: live ? 1.0 : 0.4
                        color: primary && live ? Cfg.focusBg
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

                        HoverHandler {
                            // Dimmed means it does nothing; see the same
                            // pair on the settings window's apply bar.
                            cursorShape: parent.live ? Qt.PointingHandCursor
                                                     : Qt.ArrowCursor
                        }
                        TapHandler {
                            enabled: parent.live
                            onTapped: {
                                if (parent.primary)
                                    page.applyPending();
                                else
                                    page.pending = ({});
                            }
                        }
                    }
                }
            }
        }
    }
}
