// Two stacked arrows -- upload on top, download below -- each lit by its own
// direction's throughput, like the pair of activity LEDs on a switch port.
//
// Drawn rather than themed: no icon set ships sixteen files for the four-by-four
// combination of tiers, and the pair has to be ONE glyph so it occupies one
// pill and one hit target. The native bar renders it into a cairo surface
// cached on the tier pair; here it is two GPU-rasterised triangles that
// repaint only when a tier actually changes.

import QtQuick
import QtQuick.Shapes
import ".."

Pill {
    id: root

    paddingX: 0
    fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

    Item {
        id: art
        anchors.centerIn: parent
        width: root.iconSize
        height: root.iconSize

        // A gap between the two so they read as two lights, not one shape.
        readonly property real gap: height * 0.10
        readonly property real half: (height - gap) / 2

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            // Edge to edge horizontally. The native version inset these by 12%
            // a side once, which is drawn-in transparent margin -- the pill
            // reserves the glyph's full extent, so it rendered as dead space
            // either side of the arrows.
            ShapePath {
                fillColor: Metrics.tierColor(Metrics.upTier)
                strokeWidth: 0
                startX: art.width / 2
                startY: 0
                PathLine { x: art.width; y: art.half }
                PathLine { x: 0; y: art.half }
                PathLine { x: art.width / 2; y: 0 }
            }

            ShapePath {
                fillColor: Metrics.tierColor(Metrics.downTier)
                strokeWidth: 0
                startX: art.width / 2
                startY: art.height
                PathLine { x: art.width; y: art.half + art.gap }
                PathLine { x: 0; y: art.half + art.gap }
                PathLine { x: art.width / 2; y: art.height }
            }
        }
    }
}
