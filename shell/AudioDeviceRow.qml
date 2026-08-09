// One audio device in the panel's list: what it is called, whether it is the
// one in use, and a click that makes it so.
//
// Its own file because outputs and inputs are the same row. DankMaterialShell
// has this delegate twice -- once in AudioOutputDetail.qml and once in
// AudioInputDetail.qml, sixty lines each, differing in which service property
// they compare against -- and the second copy is where a difference creeps in
// that nobody meant.

import QtQuick
import "."

Rectangle {
    id: root

    property string label: ""
    property bool current: false

    signal picked()

    height: Math.round(Cfg.fontPixelSize * 2.4)
    radius: Cfg.themeRadius
    color: hover.hovered ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.05)
    border.width: current ? 2 : 1
    border.color: current ? Cfg.focusBg : Qt.rgba(1, 1, 1, 0.08)

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Cfg.panelPadding
        anchors.rightMargin: Cfg.panelPadding
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
            width: parent.width
            text: root.label
            elide: Text.ElideRight
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
            font.weight: root.current ? Cfg.fontWeightEmphasis : Cfg.fontWeight
            font.hintingPreference: Font.PreferFullHinting
        }

        // The state in words as well as in the outline. A border alone is a
        // convention you have to already know, and this list is read at a
        // glance while something is playing.
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            text: root.current ? "Active" : "Available"
            color: root.current
                   ? Cfg.focusBg
                   : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(6, Cfg.fontSize * 0.7)
            font.hintingPreference: Font.PreferFullHinting
        }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    // The panel stays open afterwards. Picking a device is something you may
    // want to hear the result of and then adjust.
    TapHandler { onTapped: root.picked() }
}
