import QtQuick
import "."

Rectangle {
    id: root
    property bool on: false
    signal toggled(bool value)

    implicitHeight: 22
    implicitWidth: 44
    radius: height / 2
    color: on ? Cfg.focusBg : Qt.rgba(1, 1, 1, 0.10)

    Rectangle {
        width: parent.height - 6
        height: width
        radius: width / 2
        color: Cfg.fg
        y: 3
        x: root.on ? root.width - width - 3 : 3
        Behavior on x { NumberAnimation { duration: 90 } }
    }

    TapHandler { onTapped: root.toggled(!root.on) }
    // On the HoverHandler, not the TapHandler: a PointerHandler applies its
    // cursorShape while it is ACTIVE, and a TapHandler is active only while the
    // button is held -- which is a cursor that changes after you have already
    // committed to pressing.
    HoverHandler { cursorShape: Qt.PointingHandCursor }
}
