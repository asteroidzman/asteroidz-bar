// One output's bar.
//
// FOUR layer surfaces per output, not one, and the shadow is why.
//
// asteroidz draws a layer surface's shadow around that surface's own box
// (layer_draw_shadow in animation/layer.h). A bar drawn as ONE full-width
// surface therefore has exactly one shape it can cast a shadow from -- the
// whole strip, gaps between the groups included -- which is not the look. So
// each group is its own surface (SectionWindow) and the compositor shadows
// each one, with the same code, the same parameters and the same
// `effects/shadow` config that shadows every window on the desktop. The bar
// used to draw its own approximation of that shadow in QML; it does not any
// more.
//
// What is left in THIS surface is the part that is a property of the strip
// rather than of any group: the exclusive zone (one strip is reserved once,
// not three times) and the click-catcher that dismisses an open popover.
//
//   asteroidz-bar          this: reserves the strip, catches stray clicks
//   asteroidz-bar-panel    one per non-empty group, shadowed and blurred
//   asteroidz-bar-popover  the menu, when one is up
//
// The panels reserve nothing and are placed inside the strip this one
// reserves, which is exclusion-zone -1 -- so they need a `layerrule` naming
// their namespace to be shadowed at all. See SectionWindow.qml and the README.

import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import QtQuick
import "."
import "modules"

Scope {
    id: root

    required property var modelData
    readonly property string screenName: modelData ? modelData.name : ""

    readonly property bool menuOpen: menu.visible

    // ── on sizes, and why there is no scale factor here ─────────────────────
    //
    // Every size in this shell is a WAYLAND LOGICAL PIXEL, used raw. The
    // compositor multiplies a layer surface by its output's `scale`, so a bar
    // 48 logical pixels tall is 84 real pixels on an output at scale 1.75 and
    // 36 on one at 0.75 -- which is what display scaling is for, and it is the
    // same multiplication the compositor applies to its own titlebars, so the
    // bar and the desktop it sits on stay the same size as each other.
    //
    // This used to carry a second factor of its own -- each output's height
    // over the tallest output's -- on the theory that a fixed 48px bar is a
    // bigger share of a shorter screen. It measured LOGICAL heights, which
    // already contain the scale, so it was dividing out part of the thing it
    // sat on top of; and its reference was global, so setting DP-1 to scale
    // 1.75 moved the tallest output from DP-1 to HDMI-A-1 and made the bar on
    // HDMI-A-1 -- untouched, nothing about it changed -- 1.5x bigger.
    //
    // The answer to "this bar is too big on that monitor" is that monitor's
    // scale, which the user already sets and every other program obeys.

    // ── the strip: what is reserved, and what catches a stray click ─────────
    //
    // Declared first so it maps first, which puts it under the panels. That is
    // belt to the braces of the mask below, not a load-bearing assumption.
    PanelWindow {
        id: strip

        screen: root.modelData

        WlrLayershell.namespace: "asteroidz-bar"
        WlrLayershell.layer: WlrLayer.Top
        // Never takes the keyboard. The popover is a surface of its own now
        // and asks for focus itself, so this one has no reason to -- and a bar
        // that takes focus while idle steals keys from whatever you were
        // typing into.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: !Cfg.bottom
            bottom: Cfg.bottom
            left: true
            right: true
        }

        color: "transparent"

        // One pixel while idle, the whole output while a popover is open.
        //
        // It is NOT as tall as the strip it reserves, and that is deliberate:
        // this surface would otherwise lie across all three section surfaces,
        // and a layer surface covering another is the one thing the panels do
        // that the popover and the toasts -- which are shadowed and frosted
        // correctly -- do not. Nothing is drawn here in either case, so the
        // height only decides what this surface overlaps.
        //
        // The reserved strip is unaffected: exclusive_zone is a number the
        // client sends, not the surface's size, so a 1px surface reserves the
        // full bar height just as a full-height one did.
        //
        // Full-output while a menu is up is what dismisses the menu. The usual
        // mechanism is a grabbing popup, and Qt will not create one here
        // ("parent window has received input" is never satisfied), falling
        // back to a plain popup that cannot be dismissed by anything. So the
        // bar does it: full-screen, transparent, closing on any click that
        // reaches it. The exclusive zone does not change, so nothing moves.
        implicitHeight: root.menuOpen && screen ? screen.height : 1

        // Windows are kept clear of the bar AND of the gap it floats in: the
        // margin is part of the bar's footprint, not free space a maximised
        // window may use, or the panels would sit on top of window content.
        // The shadow is not part of that footprint -- it is something to see
        // through, and it is drawn outside every one of these surfaces.
        exclusiveZone: Cfg.height + 2 * Cfg.marginY

        // Input, and only where it is wanted.
        //
        // Idle: none at all. This surface draws nothing and every pill lives
        // in another surface, so there is nothing here to click -- an empty
        // region is how a layer surface says "pass everything through", and
        // it is what keeps the strip from swallowing clicks meant for a
        // window under the gap between two groups.
        //
        // Open: everything EXCEPT the panels. Subtracting them is what lets
        // the pill that opened a menu still be clicked to close it: the click
        // has to reach the pill's own surface, and this one is in the way of
        // it. Doing it with a mask rather than by stacking means it does not
        // depend on which surface the compositor happens to put on top.
        mask: root.menuOpen ? catcherMask : noInput

        Region { id: noInput }

        Region {
            id: catcherMask
            width: strip.width
            height: strip.height

            Region {
                intersection: Intersection.Subtract
                x: leftWin.originX
                y: leftWin.originY
                width: leftWin.visible ? leftWin.width : 0
                height: leftWin.visible ? leftWin.height : 0
            }
            Region {
                intersection: Intersection.Subtract
                x: centerWin.originX
                y: centerWin.originY
                width: centerWin.visible ? centerWin.width : 0
                height: centerWin.visible ? centerWin.height : 0
            }
            Region {
                intersection: Intersection.Subtract
                x: rightWin.originX
                y: rightWin.originY
                width: rightWin.visible ? rightWin.width : 0
                height: rightWin.visible ? rightWin.height : 0
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.menuOpen
            visible: root.menuOpen
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            // No "was that on a panel?" test any more: the mask above means a
            // click that lands on a panel never arrives here in the first
            // place. It used to have to check, because the panels were items
            // in this same surface and a TapHandler does not consume the event
            // for items below it -- so clicking the open pill ran both, this
            // closed the menu and the pill's own toggle opened it straight
            // back up.
            onPressed: menu.visible = false
        }
    }

    // ── the three groups, one surface each ──────────────────────────────────

    SectionWindow {
        id: leftWin
        screen: root.modelData
        bar: root
        place: "left"
    }

    SectionWindow {
        id: centerWin
        screen: root.modelData
        bar: root
        place: "center"
    }

    SectionWindow {
        id: rightWin
        screen: root.modelData
        bar: root
        place: "right"
    }

    // ── the popover ─────────────────────────────────────────────────────────
    //
    // Exactly one, session-wide, anchored to whatever raised it. Two would
    // need z-order arbitration and a grab each for no benefit: a bar popover
    // is a menu, and menus are modal by convention.
    Popover {
        id: menu

        screen: root.modelData
        visible: false

        onActivated: index => {
            const row = rows[index];
            // A row carrying its own callback: the power menu's, where the
            // destructive entries answer with a CONFIRMATION rather than acting.
            //
            // The return value decides what happens to the panel, because the
            // two cases are genuinely different and no single default suits
            // both: `true` closes it (the action ran), anything else leaves it
            // open (a question was asked, and closing would dismiss the question
            // along with it).
            if (row && typeof row.act === "function") {
                if (row.act() === true)
                    visible = false;
                return;
            }
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
            // reminders, discord and nordvpn menus looked live, closed the
            // panel and told the plugin nothing.
            //
            // The whole form goes back with the row, not just the row: a plugin
            // that puts editable rows up gets them all as `fields` keyed by
            // name, because "Save" is a row like any other and has no other way
            // to see what was typed above it.
            if (row && row.plugin) {
                const fields = {};
                for (const r of rows) {
                    // Steppers as well as text fields: to a plugin the two are
                    // the same thing, a named value the form carries.
                    if (r && (r.input || r.spin) && r.field)
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
        if (menu.visible)
            Popovers.opened(root);
    }

    // One popover session-wide is a RULE, not a property of the object model:
    // every bar owns a popover, so a menu on one monitor and a menu on another
    // could both be up, each with its own full-output catcher and its own
    // claim to Exclusive keyboard focus -- which only one surface can hold, so
    // Escape answered on one screen and was swallowed on the other.
    Connections {
        target: Popovers
        function onOpened(owner) {
            if (owner !== root)
                menu.visible = false;
        }
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

    // Which pill the open popover belongs to.
    //
    // Tracked here rather than read off the popover's anchor, which is what it
    // used to be: an xdg popup was anchored to the pill ITEM, and a layer
    // surface is placed at a coordinate and has no idea what asked for it.
    property var menuItem: null

    // Is the popover currently this item's?
    function menuBelongsTo(item) {
        return menu.visible && menuItem === item;
    }

    function closeMenu() {
        menu.visible = false;
    }

    // Aim the popover at a pill.
    //
    // The pill is an item in a SectionWindow, so its position is that
    // surface's, and the popover is a third surface that knows only the
    // output. Converting between them is what SectionWindow.originX exists
    // for: surface origin plus in-surface position is the output coordinate,
    // and the popover clamps from there.
    function aimAt(item) {
        menuItem = item;
        const win = surfaceOf(item);
        if (!win)
            return;
        const p = item.mapToItem(null, 0, 0);
        menu.anchorCenterX = win.originX + p.x + item.width / 2;
    }

    // Which of the three surfaces an item is in. Walked rather than asked,
    // because an item knows its parent chain and not its window.
    function surfaceOf(item) {
        let p = item;
        while (p) {
            if (p === leftWin.section)
                return leftWin;
            if (p === centerWin.section)
                return centerWin;
            if (p === rightWin.section)
                return rightWin;
            p = p.parent;
        }
        return null;
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
        aimAt(item);
        menu.panel = component;
        menu.visible = true;
        Popovers.opened(root);
    }

    // Open a menu under `item`, which must be a pill in this bar. Anchored to
    // the pill rather than to the pointer, so the panel stays put while the
    // menu is up and lands in the same place every time.
    function showMenu(item, rows) {
        if (menu.visible) {
            menu.visible = false;
            return;
        }
        aimAt(item);
        // Clear any panel: the popover is shared, and a menu opened after a
        // settings panel would otherwise draw the panel with the menu's rows
        // hidden behind it.
        menu.panel = null;
        showRows(rows);
    }
}
