// A small labelled button, sized to its label.
//
// Sized rather than fixed, because that is the bug this whole window exists
// downstream of: the display panel's buttons were `width: 84` with a centred
// non-eliding Text, and at any font larger than the default the label painted
// straight out over its neighbour. Nothing in here is allowed a literal width.

import QtQuick
import ".."

Rectangle {
    id: root

    property string label: ""
    // Latched on, for a toggle. Distinct from hover, which is transient.
    property bool active: false

    signal clicked()

    implicitWidth: Math.round(text.implicitWidth + Cfg.fontPixelSize * 1.0)
    implicitHeight: Math.max(20, Math.round(Cfg.fontPixelSize * 1.1))
    width: implicitWidth
    height: implicitHeight
    radius: Cfg.themeRadius
    color: active
        ? Cfg.focusBg
        : hover.hovered ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.08)

    Text {
        id: text
        anchors.centerIn: parent
        text: root.label
        color: root.active ? Cfg.focusFg : Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Math.max(7, Cfg.fontSize * 0.78)
        font.hintingPreference: Font.PreferFullHinting
    }

    HoverHandler { id: hover }
    TapHandler { onTapped: root.clicked() }
}
