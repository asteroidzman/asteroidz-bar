// One module's tile.
//
// The native bar draws a pill as a single scene node: rounded rect, optional
// artwork, one Pango line. That is deliberate -- hit testing is per node, so
// nothing is drawn that cannot be clicked -- and it is worth keeping even
// though a QML item could hold arbitrary sub-widgets. A pill is one target.
//
// Geometry mirrors bar.h exactly: the pill is inset vertically inside the
// panel (`pill-inset`, 6px of a 48px bar => 36px pills), padded horizontally
// by `pill-padding`, and floored at `pill-min-width` so a single glyph does
// not produce a sliver.

import QtQuick
import "."

Item {
    id: root

    property string text: ""
    property string icon: ""
    property color fg: Cfg.fg
    property color bg: "transparent"
    property int paddingX: Cfg.pillPadding
    // A width to pin to, so a clock does not resize the bar every second as
    // its digits change width. 0 sizes to content.
    property int fixedWidth: 0
    property bool interactive: true

    signal clicked(int button)
    signal wheel(int delta)

    readonly property int contentWidth:
        (iconItem.visible ? iconItem.width + (label.text ? 6 : 0) : 0)
        + label.implicitWidth

    implicitWidth: fixedWidth > 0
        ? fixedWidth
        : Math.max(Cfg.pillMinWidth, contentWidth + 2 * paddingX)
    implicitHeight: Cfg.height - 2 * Cfg.pillInset

    Rectangle {
        id: tile
        anchors.fill: parent
        radius: Cfg.themeRadius
        color: root.bg
    }

    Row {
        anchors.centerIn: parent
        spacing: label.text && iconItem.visible ? 6 : 0

        Image {
            id: iconItem
            visible: root.icon !== ""
            source: root.icon
            // Icons are square and sized to the pill's text, the way the
            // native bar sizes its artwork off the row height rather than off
            // the source image -- an SVG has no natural size, and a PNG's is
            // whatever the application shipped.
            width: Math.round(root.implicitHeight * 0.55)
            height: width
            sourceSize.width: width * 2
            sourceSize.height: width * 2
            fillMode: Image.PreserveAspectFit
            anchors.verticalCenter: parent.verticalCenter
            smooth: true
        }

        Text {
            id: label
            text: root.text
            color: root.fg
            font.family: Cfg.fontFamily
            // Pixels, not points. The compositor's size is points at a FIXED
            // 96dpi, so converting once here means the label cannot move
            // because someone's Xft.dpi did -- which is exactly what made the
            // first build render 1.75x too large.
            font.pixelSize: Cfg.fontPixelSize
            renderType: Text.NativeRendering
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            width: root.fixedWidth > 0
                ? Math.min(implicitWidth, root.fixedWidth - 2 * root.paddingX)
                : implicitWidth
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.interactive
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: mouse => root.clicked(mouse.button)
        onWheel: ev => root.wheel(ev.angleDelta.y)
    }
}
