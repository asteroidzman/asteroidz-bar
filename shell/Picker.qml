// One value out of a list, chosen from the list.
//
// It used to CYCLE: each click stepped to the next value and applied it. For
// a colour scheme that is merely unusual; for a display mode it means every
// click is a real mode set, so picking 2560x1440 out of a dozen modes walked
// the monitor through every mode on the way there. The scroll wheel did the
// same, a mode per notch.
//
// The list opens in place rather than as a popup. A popup inside a popup needs
// its own grab and its own dismiss rules -- and more practically this panel IS
// a popup, a Wayland surface sized to its content, so a dropdown hanging past
// its edge would be clipped away by the surface. Expanding inline grows the
// panel, which is the one thing that reliably makes room.

import QtQuick
import QtQuick.Window
import Quickshell
import "."

Item {
    id: root

    property var values: []
    property string current: ""
    // Rows shown before the list scrolls. Modes are the long case: a monitor
    // with a dozen of them should not produce a panel taller than the screen.
    property int maxRows: 6

    signal picked(string value)

    property bool open: false

    // Sized from the font, not a constant: the rows use the bar's font now,
    // and 24px was chosen when they were drawing it at 80%.
    readonly property int rowHeight: Math.max(24, Math.round(Cfg.fontPixelSize * 1.5))

    // Where an open list is drawn: the window's own content item, so it can
    // hang outside the scrolling pane this row lives in.
    //
    // QsWindow.window FIRST, then Qt's own Window attached property, and the
    // fallback is the entire point rather than belt-and-braces. QsWindow.window
    // is NULL inside the settings window -- a FloatingWindow -- and everything
    // here depended on it: the list fell back to expanding inside the row,
    // where the pane's clip cut it away completely. What that looks like is a
    // dropdown that opens (the arrow flips to ▴), pushes the rows under it out
    // of view, and shows NOTHING to click. Reported as being unable to change
    // an output's scale back after setting it to 1.75, and reproduced headlessly
    // at that scale: `PICKERDBG parentIsRoot=true win=false winH=0`.
    //
    // Qt's Window attached property resolves for any QQuickWindow, which a
    // FloatingWindow is, so it answers where the Quickshell one does not.
    readonly property Item overlayParent: {
        if (QsWindow.window && QsWindow.window.contentItem)
            return QsWindow.window.contentItem;
        if (Window.window && Window.contentItem)
            return Window.contentItem;
        return null;
    }
    readonly property bool inlineList: overlayParent === null

    // Only when the list really is drawn INSIDE this row. It grew
    // unconditionally before, so even a correctly reparented list shoved the
    // rows below it down by its own height for no reason -- and when the
    // reparenting silently failed, that displacement was the only visible
    // evidence that anything had opened at all.
    implicitHeight: rowHeight + (open && inlineList ? listBox.height + 4 : 0)
    // Above the settings below it while open, so the list is not drawn under
    // the next row as the panel reflows.
    z: open ? 10 : 0

    Rectangle {
        id: header
        width: parent.width
        height: root.rowHeight
        radius: Cfg.themeRadius
        color: root.open ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06)

        Text {
            font.weight: Cfg.fontWeight
            anchors.centerIn: parent
            text: root.current === "" ? "—" : root.current
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }

        // The affordance. Without it this reads as a label -- which is half of
        // why it was ever a stepper.
        Text {
            font.weight: Cfg.fontWeight
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: root.open ? "▴" : "▾"
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize * 0.7
        }

        TapHandler {
            onTapped: if (root.values.length > 1) root.open = !root.open
        }
        // A picker with one entry is a readout, and its header does nothing when
        // clicked -- so it must not claim otherwise.
        HoverHandler {
            cursorShape: root.values.length > 1 ? Qt.PointingHandCursor
                                                : Qt.ArrowCursor
        }
    }

    // Clicking anywhere else closes the list.
    //
    // At the WINDOW's level, not inside this item: an open list has to be
    // dismissable from the whole window, and anything parented here is clipped
    // by the Flickable the settings pane scrolls in. Without it the list stayed
    // open until it was used, which in the settings window -- where there is no
    // surrounding popover to dismiss it -- meant it never closed at all.
    //
    // Below the list (z 9 against 11) so picking an entry still reaches the
    // entry, and above the header, so clicking the header while open closes it
    // through here rather than toggling twice.
    Loader {
        active: root.open && root.overlayParent !== null
        parent: root.overlayParent ? root.overlayParent : root
        anchors.fill: parent
        z: 9
        sourceComponent: Item {
            TapHandler { onTapped: root.open = false }
        }
    }

    // Escape closes it too, and this is a Shortcut rather than a Keys handler.
    //
    // Keys.onEscapePressed needs ACTIVE focus, not merely `focus: true`, and
    // there is no dependable way to hold it here: this item lives inside a
    // Flickable inside a pane, the catcher above is reparented to the window's
    // contentItem after creation, and whatever was last clicked -- a field, a
    // slider -- is holding focus anyway. Both were tried and neither fired: the
    // assertion read "32 -> 32 px accent", the list untouched, against a build
    // that looked correct.
    //
    // A Shortcut is scoped to the WINDOW rather than to an item, which is the
    // scope this claim actually has: while a list is open in this window, Escape
    // closes it. `enabled` keeps exactly one of them live, so a page full of
    // pickers cannot make the sequence ambiguous.
    //
    // Reported live, and the gap is one this window created. In the bar a Picker
    // was always inside a popover, and Bar.qml forwarded Escape to
    // Popover.handleKey, which closed the whole panel and took the list with it.
    // A toplevel has no surrounding popover, so the key reached nothing at all.
    Shortcut {
        sequence: "Escape"
        enabled: root.open
        onActivated: root.open = false
    }

    Rectangle {
        id: listBox
        // Reparented to the window while open, for the same reason as the
        // catcher above: inside the Flickable it is clipped to the visible
        // pane, so a list opened near the bottom lost its last rows.
        parent: root.open && root.overlayParent ? root.overlayParent : root
        z: 11

        // Placed by mapping, since the parent is no longer the header's. The
        // HEADER's own top-left, not the row below it, so the arithmetic below
        // can put the list on either side of it.
        readonly property point at: root.open && root.overlayParent
            ? root.mapToItem(root.overlayParent, 0, 0)
            : Qt.point(0, 0)
        readonly property int winHeight:
            root.overlayParent ? root.overlayParent.height : 0

        x: parent === root ? 0 : at.x

        // Below the header if it fits, above it if it does not.
        //
        // It used to be "below", full stop. A window is not infinitely tall,
        // and this list is reparented OUT of the scrolling pane, so a list
        // opened near the bottom was drawn past the window's edge and simply
        // clipped away -- the row expanded, and there was nothing in the gap to
        // click. On the Displays page, whose Scale row sits under a monitor
        // arrangement and two other pickers, that is where the row normally is.
        //
        // Reported live at output scale 1.75, where the logical window is short
        // enough to lose the whole list. It reproduces at any scale on a short
        // enough window; the scale only decided how much of it went missing.
        y: {
            if (parent === root)
                return root.rowHeight + 4;
            const below = at.y + root.rowHeight + 4;
            if (below + height <= winHeight)
                return below;
            const above = at.y - 4 - height;
            if (above >= 0)
                return above;
            // Taller than the window on either side: pin it inside and let the
            // list scroll. Never negative, which would clip the FIRST rows --
            // the ones a list is usually opened for.
            return Math.max(0, winHeight - height);
        }

        width: root.width
        // Never taller than the window it is drawn in, whatever maxRows says.
        height: Math.min(
                    Math.min(root.maxRows, Math.max(1, root.values.length))
                        * root.rowHeight + 4,
                    winHeight > 0 ? winHeight : Number.MAX_VALUE)
        visible: root.open
        radius: Cfg.themeRadius
        color: Cfg.popoverColor
        border.width: 1
        border.color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.15)

        ListView {
            anchors.fill: parent
            anchors.margins: 2
            clip: true
            model: root.values
            currentIndex: root.values.indexOf(root.current)

            delegate: Rectangle {
                required property string modelData
                width: ListView.view.width
                height: root.rowHeight
                radius: Cfg.themeRadius
                color: modelData === root.current
                    ? Cfg.focusBg
                    : hover.hovered ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.10)
                                    : "transparent"

                Text {
                    font.weight: Cfg.fontWeight
                    anchors.centerIn: parent
                    text: modelData
                    color: modelData === root.current ? Cfg.focusFg : Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.hintingPreference: Font.PreferFullHinting
                }

                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        root.open = false;
                        // Only on an actual change: re-picking the current
                        // mode is still a mode set, and a mode set is a blank
                        // screen for a moment.
                        if (modelData !== root.current)
                            root.picked(modelData);
                    }
                }
            }
        }
    }
}
