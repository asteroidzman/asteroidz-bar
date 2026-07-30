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
    // idle steals keys from whatever you were typing into -- so this is raised
    // while a popover is OPEN and dropped the moment it closes.
    //
    // Any popover, not just one with a text field: a menu has to answer
    // Escape, and it cannot be sent a key it was never given focus to
    // receive.
    // Exclusive, not OnDemand, while a menu is up.
    //
    // OnDemand leaves it to the compositor to decide when this surface has
    // the keyboard, and it never decided in our favour: Escape went to
    // whatever was focused before the menu opened and the menu ignored it. A
    // menu is modal for as long as it is up, which is exactly what Exclusive
    // says.
    WlrLayershell.keyboardFocus: menu.visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        left: true
        right: true
    }

    // Taller than it reserves, by exactly the shadow's reach.
    //
    // The compositor's own bar drew into the scene graph, so its shadow could
    // spill as far past the panel as it liked. A layer surface cannot: it can
    // only paint inside itself, and at height + 2*margin there are nine pixels
    // below the panel -- so a shadow grown by 14 and blurred by 14 lost most
    // of itself to the surface edge, which is the half that shows.
    //
    // The extra height is NOT reserved (see exclusiveZone below), so it costs
    // no screen space: it is transparent, takes no input, and windows are
    // free to sit under it.
    readonly property int shadowRoom:
        Cfg.panelShadow && Cfg.panelEnable
            ? Cfg.panelShadowSize + Math.ceil(2 * Cfg.panelShadowBlur)
            : 0

    // While a menu is open this surface covers the OUTPUT, and that is how a
    // menu gets dismissed.
    //
    // The usual mechanism is a grabbing popup, and Qt will not create one
    // here ("parent window has received input" is never satisfied), falling
    // back to a plain popup that cannot be dismissed by anything. So the bar
    // does it: full-screen while a menu is up, transparent, with a catcher
    // under the panels that closes on any click which is not on a pill. The
    // exclusive zone does not change, so nothing on screen moves.
    readonly property bool menuOpen: menu.visible
    readonly property int restingHeight: Cfg.height + 2 * Cfg.marginY + shadowRoom

    implicitHeight: menuOpen && screen ? screen.height : restingHeight
    // Windows are kept clear of the bar AND of the gap it floats in: the
    // margin is part of the bar's footprint, not free space a maximised window
    // may use, or the panel would sit on top of window content. The shadow is
    // not part of that footprint -- it is something to see through.
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

    // Input lands on the panels, and nowhere else on this surface.
    //
    // The surface spans the whole output and is now taller than it reserves,
    // so without a mask it would swallow every click that landed in the
    // transparent gaps between the groups -- including the shadow band below
    // the bar, which is not reserved and therefore has real window content
    // under it.
    // Null mask == the whole surface, which is what a catcher needs; the
    // panels-only mask is what an idle bar needs so the transparent gaps
    // between the groups do not swallow clicks meant for windows.
    mask: menuOpen ? null : panelsOnly

    Region {
        id: panelsOnly
        regions: [
            Region { item: leftPanel },
            Region { item: centerPanel },
            Region { item: rightPanel }
        ]
    }

    // The catcher, which closes the menu on a click that is not on a panel.
    //
    // It has to TEST that rather than rely on being underneath, because being
    // underneath is not enough: the pills use TapHandlers, and a pointer
    // handler does not consume the event for items below it. Clicking the
    // open pill therefore ran both -- this closed the menu, and the pill's own
    // toggle then saw a closed menu and opened it straight back up, so the
    // one gesture that was supposed to dismiss it was the only one that could
    // not.
    MouseArea {
        anchors.fill: parent
        z: -10
        enabled: root.menuOpen
        visible: root.menuOpen
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: mouse => {
            if (!root.onAPanel(mouse.x, mouse.y))
                menu.visible = false;
        }
    }

    // Is this point on one of the three panels? In the window's own
    // coordinates, which is what a click on this surface arrives in.
    function onAPanel(x, y) {
        for (const p of [leftPanel, centerPanel, rightPanel]) {
            if (!p.visible)
                continue;
            const r = p.mapToItem(null, 0, 0, p.width, p.height);
            if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
                return true;
        }
        return false;
    }

    // Escape, and everything a form in a popover needs typed into it.
    //
    // Here rather than in the popover because THIS is the window with
    // keyboard focus -- the popup never takes any -- so a Keys handler over
    // there would never fire.
    Item {
        id: keys
        anchors.fill: parent
        focus: true
        // Forwarded FIRST, so a text field in a panel gets the keystroke before
        // the menu's own row handling sees it. The compositor delivers keys to
        // this surface and the popover never holds focus, so without this a
        // Field inside a panel could not be typed into -- see Popover.keyTarget.
        Keys.forwardTo: menu.keyTarget ? [menu.keyTarget] : []
        Keys.onPressed: event => menu.handleKey(event)
    }

    // Taking the keyboard is not the same as an item holding it: without this
    // the window had focus and nothing in it did, so the key handler above
    // never ran.
    onMenuOpenChanged: if (menuOpen) keys.forceActiveFocus()

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
            // A plugin's row. Nothing happened here at all before this: the
            // popover fell through to `visible = false`, so every row in the
            // medication, discord and nordvpn menus looked live, closed the
            // panel and told the plugin nothing.
            //
            // The whole form goes back with the row, not just the row: a plugin
            // that puts editable rows up gets them all as `fields` keyed by
            // name, because "Save" is a row like any other and has no other way
            // to see what was typed above it.
            if (row && row.plugin) {
                const fields = {};
                for (const r of rows) {
                    if (r && r.input && r.field)
                        fields[r.field] = r.value || "";
                }
                row.plugin.send({
                    event: "menu",
                    value: row.action || "",
                    fields: fields
                });
                // NOT closed here. What happens to the panel is the plugin's
                // answer to say: a new set of rows to step into, the same set
                // again when it rejects a form, or an empty set to dismiss.
                return;
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

    // A plugin answering with a menu while its own is already up is
    // NAVIGATION -- a submenu, a form replacing a list, the same form again
    // after a rejected save -- not a second click on its pill. showMenu reads
    // an open panel as a toggle and closes it, which would have made every
    // step into a plugin submenu dismiss the thing being stepped into, so the
    // rows are swapped in place instead. An empty set still closes it, which
    // is how a plugin says "done" once it has acted.
    function showPluginMenu(item, rows) {
        if (menuBelongsTo(item)) {
            showRows(rows);
            return;
        }
        showMenu(item, rows);
    }

    // Is the popover currently this item's?
    function menuBelongsTo(item) {
        return menu.visible && menu.anchor.item === item;
    }

    function closeMenu() {
        menu.visible = false;
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
