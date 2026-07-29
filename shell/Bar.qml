// One output's bar.
//
// A layer-shell surface spanning the output's width, transparent, with three
// panels floating on it. The surface is full-width rather than three separate
// windows because the exclusive zone is a property of a surface: three windows
// would either reserve three overlapping strips or none at all.

import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import QtQuick
import "."
import "modules"

PanelWindow {
    id: root

    required property var modelData
    screen: modelData
    readonly property string screenName: modelData ? modelData.name : ""

    WlrLayershell.namespace: "asteroidz-bar"
    WlrLayershell.layer: WlrLayer.Top
    // No keyboard until something asks for it. A bar that takes focus while
    // idle steals keys from whatever you were typing into, and the popovers
    // that DO need keys (phase 4) can raise this per-window.
    // No keyboard until something asks for it. A bar that takes focus while
    // idle steals keys from whatever you were typing into -- so this is raised
    // only while a popover with a text field is open, and dropped the moment
    // it closes.
    WlrLayershell.keyboardFocus: menu.visible && menu.wantsKeyboard
        ? WlrKeyboardFocus.OnDemand
        : WlrKeyboardFocus.None

    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        left: true
        right: true
    }

    implicitHeight: Cfg.height + 2 * Cfg.marginY
    // Windows are kept clear of the bar AND of the gap it floats in: the
    // margin is part of the bar's footprint, not free space a maximised window
    // may use, or the panel would sit on top of window content.
    exclusiveZone: Cfg.height + 2 * Cfg.marginY

    color: "transparent"

    // The frosted look, preserved across the move out of the compositor.
    //
    // scenefx blurs what is behind a layer surface, and asteroidz will mask
    // that by the surface's own alpha -- but the region below is better than a
    // mask: it carries the panels' CORNER RADII, so the blur ends exactly
    // where the rounded slab does instead of leaving square ears at the
    // corners. Only non-empty sections contribute, so the gaps between groups
    // stay genuinely transparent.
    WlrLayershell.BackgroundEffect.blurRegion: Region {
        regions: [
            Region {
                item: leftPanel
                radius: Cfg.panelRadius
            },
            Region {
                item: centerPanel
                radius: Cfg.panelRadius
            },
            Region {
                item: rightPanel
                radius: Cfg.panelRadius
            }
        ]
    }

    // Exactly one popover, session-wide, anchored to whatever raised it.
    // Two would need z-order arbitration and a grab each for no benefit: a bar
    // popover is a menu, and menus are modal by convention.
    Popover {
        id: menu
        anchor.window: root
        visible: false

        onActivated: index => {
            const row = rows[index];
            // A PipeWire sink, picked from the volume menu. Setting the
            // preferred default is what "output" means to a person: it moves
            // where new streams go and what the volume pill controls, which is
            // the same thing `pactl set-default-sink` did.
            if (row && row.node) {
                Pipewire.preferredDefaultAudioSink = row.node;
                visible = false;
                return;
            }
            if (row && row.entry) {
                // A submenu opens in place rather than closing: the panel is
                // the same panel, showing a different level.
                if (row.submenu) {
                    root.showRows(row.entry.children
                        ? row.entry.children.values.map(root.rowFor) : []);
                    return;
                }
                row.entry.triggered();
            }
            visible = false;
        }

        onEdited: (index, text) => {
            const copy = rows.slice();
            copy[index] = Object.assign({}, copy[index], { value: text });
            rows = copy;
        }
    }

    function rowFor(e) {
        return {
            text: e.text,
            icon: e.icon,
            enabled: e.enabled,
            separator: e.isSeparator,
            submenu: e.hasChildren,
            checked: e.checkState === Qt.Checked,
            entry: e
        };
    }

    function showRows(rows) {
        menu.rows = rows;
        menu.visible = rows.length > 0;
    }

    // Open an arbitrary component under `item` -- a settings panel rather than
    // a list of rows. Menus and panels share one popover for the same reason
    // there is only one of either: two would need z-order arbitration and a
    // grab each.
    function showPanel(item, component) {
        if (menu.visible) {
            menu.visible = false;
            return;
        }
        menu.rows = [];
        menu.anchor.item = item;
        menu.anchor.edges = Edges.Bottom;
        menu.anchor.gravity = Edges.Bottom;
        menu.panel = component;
        menu.visible = true;
    }

    // Open a menu under `item`, which must be a pill in this bar. Anchored to
    // the pill rather than to the pointer, so the panel stays put while the
    // menu is up and lands in the same place every time.
    function showMenu(item, rows) {
        if (menu.visible) {
            menu.visible = false;
            return;
        }
        menu.anchor.item = item;
        menu.anchor.edges = Edges.Bottom;
        menu.anchor.gravity = Edges.Bottom;
        // Clear any panel: the popover is shared, and a menu opened after a
        // settings panel would otherwise draw the panel with the menu's rows
        // hidden behind it.
        menu.panel = null;
        showRows(rows);
    }

    // The strip itself: exactly `height` tall, `margin_y` from the screen
    // edge it is anchored to.
    //
    // NOT the whole surface. The surface is height + 2*margin tall because
    // that is what the compositor reserves (bar_reserve: `height + 2 *
    // margin_y`) -- the second margin is breathing room below the bar, not
    // part of it. Filling the surface and centring the panels inside it put
    // them 4.5px low, which is the sort of error that looks like nothing and
    // fails a pixel diff.
    Item {
        height: Cfg.height
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: Cfg.bottom ? undefined : parent.top
        anchors.bottom: Cfg.bottom ? parent.bottom : undefined
        anchors.topMargin: Cfg.bottom ? 0 : Cfg.marginY
        anchors.bottomMargin: Cfg.bottom ? Cfg.marginY : 0
        anchors.leftMargin: Cfg.marginX
        anchors.rightMargin: Cfg.marginX

        Section {
            id: leftPanel
            bar: root
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            list: Cfg.modulesLeft
            monitorFilter: Cfg.leftMonitor
            screenName: root.screenName
        }

        Section {
            id: centerPanel
            bar: root
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            list: Cfg.modulesCenter
            monitorFilter: Cfg.centerMonitor
            screenName: root.screenName
        }

        Section {
            id: rightPanel
            bar: root
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            list: Cfg.modulesRight
            monitorFilter: Cfg.rightMonitor
            screenName: root.screenName
        }
    }
}
