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

    // Optional artwork before the label. Sized from the font like everything
    // else here: an icon pinned at 16px beside a label that grows with the
    // theme is the same bug this component exists to stop, one element over.
    property string icon: ""
    readonly property bool hasIcon: icon !== ""
    readonly property int iconSize: Math.round(Cfg.fontPixelSize * 0.9)

    signal clicked()

    implicitWidth: Math.round(text.implicitWidth + Cfg.fontPixelSize * 1.0
                              + (hasIcon ? iconSize + Cfg.spacing : 0))
    implicitHeight: Math.max(20, Math.round(Cfg.fontPixelSize * 1.1))
    width: implicitWidth
    height: implicitHeight
    radius: Cfg.themeRadius
    color: active
        ? Cfg.focusBg
        : hover.hovered ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.08)

    // Icon and label as one centred run, rather than the icon anchored left:
    // with the button sized to its contents there is no slack to anchor into,
    // and a left-anchored icon would sit on the corner radius.
    Row {
        anchors.centerIn: parent
        spacing: Cfg.spacing

        Icon {
            visible: root.hasIcon
            anchors.verticalCenter: parent.verticalCenter
            width: root.hasIcon ? root.iconSize : 0
            height: root.iconSize
            size: root.iconSize
            name: root.icon
            // Follows the label, so it inverts with it when the button latches.
            tint: root.active ? Cfg.focusFg : Cfg.fg
        }

        Text {
            font.weight: Cfg.fontWeight
            id: text
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.active ? Cfg.focusFg : Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.78)
            font.hintingPreference: Font.PreferFullHinting
        }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.clicked() }
}
