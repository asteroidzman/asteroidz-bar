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
import Qt5Compat.GraphicalEffects
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

    // ── the shadow ──────────────────────────────────────────────────────────
    //
    // A glow with the panel's own shape punched out of it. That is more
    // machinery than a drop shadow ought to need, and both halves are
    // load-bearing.
    //
    // The punch-out is because the slab is TRANSLUCENT. Anything drawn behind
    // it shows through -- and what is meant to show through is the
    // compositor's blur of the wallpaper. A shadow covering the panel's own
    // area darkens that 15% and takes the frost with it: measured, the panel
    // interior went from rgb(32,36,42) to rgb(16,17,19). Masked to the region
    // OUTSIDE the slab, the interior is pixel-identical to having no shadow.
    //
    // RectangularGlow rather than MultiEffect's shadowEnabled because
    // MultiEffect draws its SOURCE as well as the shadow, which would put a
    // second copy of the slab behind the real one -- the same darkening by
    // another route. (And MultiEffect given a plain Rectangle as `source`
    // draws nothing at all: a Rectangle is not a texture provider. That is
    // why this panel had no shadow whatsoever.)
    Item {
        id: glow
        anchors.centerIn: slab
        // Room for the falloff. The layer is only as big as this item, so a
        // glow wider than the margin gets cut off square.
        width: slab.width + 4 * Cfg.panelShadowBlur
        height: slab.height + 4 * Cfg.panelShadowBlur
        visible: false
        layer.enabled: true

        RectangularGlow {
            anchors.centerIn: parent
            width: slab.width
            height: slab.height
            glowRadius: Cfg.panelShadowBlur
            spread: 0.1
            color: Cfg.panelShadowColor
            cornerRadius: Cfg.panelRadius + Cfg.panelShadowBlur
        }
    }

    Item {
        id: hole
        anchors.fill: glow
        visible: false
        layer.enabled: true

        Rectangle {
            anchors.centerIn: parent
            width: slab.width
            height: slab.height
            radius: Cfg.panelRadius
            color: "white"
        }
    }

    OpacityMask {
        anchors.fill: glow
        source: glow
        maskSource: hole
        invert: true
        visible: Cfg.panelShadow && Cfg.panelEnable
        z: -1
    }
}
