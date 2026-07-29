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

    readonly property int rowHeight: 24
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
            font.pointSize: Cfg.fontSize * 0.8
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
    }

    Rectangle {
        id: listBox
        anchors.top: header.bottom
        anchors.topMargin: 4
        width: parent.width
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
                    font.pointSize: Cfg.fontSize * 0.8
                    font.hintingPreference: Font.PreferFullHinting
                }

                HoverHandler { id: hover }
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
