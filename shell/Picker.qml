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
    implicitHeight: rowHeight + (open ? listBox.height + 4 : 0)
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
        active: root.open && QsWindow.window !== null
        parent: QsWindow.window ? QsWindow.window.contentItem : root
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
        parent: root.open && QsWindow.window ? QsWindow.window.contentItem : root
        z: 11

        // Placed by mapping, since the parent is no longer the header's.
        readonly property point at: root.open && QsWindow.window
            ? root.mapToItem(QsWindow.window.contentItem, 0, root.rowHeight + 4)
            : Qt.point(0, 0)
        x: parent === root ? 0 : at.x
        y: parent === root ? root.rowHeight + 4 : at.y

        width: root.width
        height: Math.min(root.maxRows, Math.max(1, root.values.length))
                * root.rowHeight + 4
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
