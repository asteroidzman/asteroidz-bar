// One section's backing panel: the rounded translucent slab a group of pills
// sits on.
//
// The bar surface itself is fully transparent and each non-empty section draws
// its own panel, which is what makes left/centre/right read as three groups
// rather than one strip. It is also what makes the blur work: the compositor
// blurs the region this reports, so an empty section contributes nothing and
// the wallpaper shows through between the groups.
//
// The shadow is drawn HERE rather than by the compositor. asteroidz will
// happily put a layer shadow behind the whole surface, but the surface is the
// full width of the output -- one shadow around all three sections, including
// the transparent gaps between them, which is not the look. A per-panel shadow
// has to come from whoever knows where the panels are.

import QtQuick
import QtQuick.Effects
import "."

Item {
    id: root

    default property alias content: layout.data
    property int spacing: Cfg.moduleSpacing
    // Measured, not counted. `children` includes the Repeater itself and any
    // other non-visual object parented here, so counting them reports a panel
    // full of nothing as occupied -- which is how three module names the shell
    // does not implement yet still produced two empty slabs on screen. A Row
    // lays out only its VISIBLE children, so its implicit width is exactly the
    // question being asked.
    readonly property bool empty: layout.implicitWidth <= 0

    visible: !empty
    implicitWidth: slab.implicitWidth
    implicitHeight: Cfg.height

    Rectangle {
        id: slab
        anchors.fill: parent
        radius: Cfg.panelRadius
        color: Cfg.panelEnable ? Cfg.panelColor : "transparent"

        implicitWidth: layout.implicitWidth + 2 * Cfg.panelPadding

        Row {
            id: layout
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Cfg.panelPadding
            spacing: root.spacing
        }
    }

    // A shadow the same size and place as the panel would be entirely hidden
    // behind an opaque one -- the native bar hit exactly this and grew the
    // shadow by its own blur radius so the soft edge clears the slab. Same
    // numbers here.
    MultiEffect {
        anchors.fill: slab
        source: slab
        shadowEnabled: Cfg.panelShadow && Cfg.panelEnable
        shadowColor: Cfg.panelShadowColor
        shadowBlur: Cfg.panelShadowBlur / 32.0
        shadowVerticalOffset: 0
        z: -1
    }
}
