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
// the transparent gaps between them, which is not the look.

import QtQuick
import QtQuick.Effects
import "."

Item {
    id: root

    default property alias content: layout.data
    property int spacing: Cfg.moduleSpacing

    // Trimmed off the ends before padding, so the gap from the panel edge to
    // the first thing you can see matches the gap after the last one. Fed by
    // whoever knows what is actually in the section.
    property int leadTrim: 0
    property int trailTrim: 0

    // Measured, not counted. `children` includes the Repeater itself and any
    // other non-visual object parented here, so counting them reports a panel
    // full of nothing as occupied -- which is how three module names the shell
    // does not implement yet still produced two empty slabs on screen. A Row
    // lays out only its VISIBLE children, so its implicit width is exactly the
    // question being asked.
    readonly property bool empty: layout.implicitWidth <= 0

    visible: !empty
    implicitWidth: Math.max(2 * Cfg.panelPadding,
                            layout.implicitWidth - leadTrim - trailTrim
                            + 2 * Cfg.panelPadding)
    implicitHeight: Cfg.height

    Rectangle {
        id: slab
        anchors.fill: parent
        radius: Cfg.panelRadius
        color: Cfg.panelEnable ? Cfg.panelColor : "transparent"
    }

    Row {
        id: layout
        anchors.verticalCenter: parent.verticalCenter
        // Padding, less whatever the leading pill already contributes. This
        // goes NEGATIVE when a pinned pill's reserve exceeds the padding,
        // which is correct: the pill's box hangs outside the slab, its ink
        // does not.
        x: Cfg.panelPadding - root.leadTrim
        spacing: root.spacing
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
