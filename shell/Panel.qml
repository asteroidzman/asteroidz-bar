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
    // The native bar's shadow, with its geometry rather than a drop shadow's.
    // scenefx drew a rounded box GROWN by `shadow_size` on every side, gave
    // it the panel's radius grown to match, blurred the whole thing at
    // `shadow_blur`, and shifted it down by a third of the size. It is a soft
    // blob larger than the panel, not an outline traced around it -- which is
    // why it reads as blended into the panel instead of ringing it.
    //
    // It is deliberately NOT masked out of the panel's own area. The slab is
    // translucent, so the shadow does tint what shows through it, and a
    // version with the middle punched out was tried and rejected: with a hard
    // boundary at the slab's edge the shadow stops being part of the panel
    // and becomes a halo around it.
    //
    // RectangularGlow rather than MultiEffect's shadowEnabled, because
    // MultiEffect draws its SOURCE as well as the shadow -- a second copy of
    // the slab behind the real one. (And MultiEffect given a plain Rectangle
    // as `source` draws nothing whatsoever: a Rectangle is not a texture
    // provider, which is why this panel had no shadow at all.)
    RectangularGlow {
        id: shadow

        readonly property int delta: Cfg.panelShadowSize
        // How far the shadow reaches: solid out to `delta`, then the blur's
        // falloff, which for a gaussian is spent by about two sigma.
        readonly property int reach: delta + Math.ceil(2 * Cfg.panelShadowBlur)

        anchors.centerIn: slab
        width: slab.width
        height: slab.height
        // Down by a third of the size, so it sits under the panel the way it
        // sits under a window.
        anchors.verticalCenterOffset: Math.round(delta / 3)

        cornerRadius: Cfg.panelRadius + delta
        glowRadius: reach
        // `spread` is how much of the reach stays at full alpha before the
        // fade begins. Not `delta / reach` -- that would be the grown box's
        // full width, and a gaussian does not leave its box solid: it puts
        // the box's own edge at half alpha and spreads the rest both ways.
        // Half of it is the right approximation, and the difference is
        // visible: at delta/reach the shadow reads as a hard dark frame
        // around the panel rather than a shadow under it.
        spread: delta / (2 * reach)
        color: Cfg.panelShadowColor
        visible: Cfg.panelShadow && Cfg.panelEnable
        z: -1
    }
}
