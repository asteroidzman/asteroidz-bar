// The monitor layout, drawn to scale and draggable.
//
// The one thing in this panel that is NOT a list of rows. A list could
// describe an arrangement -- "DP-1 is left of HDMI-A-1" -- but not let you fix
// one, and a layout is a relationship between rectangles, which is a picture.
//
// Positions are committed on RELEASE, not during the drag: every move is a
// live output-layout change that re-arranges every client on every screen, and
// doing that per mouse-motion event would thrash the whole desktop to show a
// rectangle moving.

import QtQuick
import "."

Item {
    id: root

    property var outputs: []
    property string selected: ""

    signal picked(string name)
    signal moved(string name, int x, int y)

    // Layout coordinates -> canvas coordinates. Computed from the bounding box
    // of every output so the picture fills the space whatever the arrangement.
    readonly property var bounds: {
        if (!outputs.length)
            return { x: 0, y: 0, w: 1, h: 1 };
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (const o of outputs) {
            x0 = Math.min(x0, o.x);
            y0 = Math.min(y0, o.y);
            x1 = Math.max(x1, o.x + o.width);
            y1 = Math.max(y1, o.y + o.height);
        }
        return { x: x0, y: y0, w: Math.max(1, x1 - x0), h: Math.max(1, y1 - y0) };
    }

    readonly property real zoom: Math.min(width / (bounds.w * 1.15),
                                          height / (bounds.h * 1.15))

    Rectangle {
        anchors.fill: parent
        radius: Cfg.themeRadius
        color: Qt.rgba(0, 0, 0, 0.25)
    }

    Repeater {
        model: root.outputs

        delegate: Rectangle {
            id: tile
            required property var modelData

            // Where the drag has put it, in LAYOUT coordinates. Seeded from
            // the output and updated by the drag, so the tile follows the
            // pointer without anything being committed yet.
            property int lx: modelData.x
            property int ly: modelData.y

            // Inset by a pixel on every side. Outputs are drawn at their exact
            // layout coordinates, so two monitors that are flush -- which is
            // what the snap on release deliberately produces -- shared an edge
            // and rendered as one undifferentiated block. The gap is the only
            // thing that says "these are two screens".
            x: (lx - root.bounds.x) * root.zoom
               + (root.width - root.bounds.w * root.zoom) / 2 + 1
            y: (ly - root.bounds.y) * root.zoom
               + (root.height - root.bounds.h * root.zoom) / 2 + 1
            width: Math.max(1, modelData.width * root.zoom - 2)
            height: Math.max(1, modelData.height * root.zoom - 2)

            radius: 3
            color: modelData.name === root.selected
                ? Cfg.focusBg : Qt.rgba(1, 1, 1, 0.12)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.25)

            Text {
                anchors.centerIn: parent
                // The canvas is a fraction of real size, so a 1920px-wide
                // output can land at ~120px here and an output name is longer
                // than that at any font. Elide rather than overflow -- and
                // below the width where an ellipsis still says something,
                // drop the label entirely: "H…" identifies nothing, while the
                // selection highlight and the tile's own shape already do.
                width: Math.max(0, parent.width - 8)
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                visible: parent.width >= Cfg.fontPixelSize * 3
                text: tile.modelData.name
                color: tile.modelData.name === root.selected ? Cfg.focusFg : Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(6, Cfg.fontSize * 0.6)
                font.hintingPreference: Font.PreferFullHinting
            }

            DragHandler {
                id: drag
                target: null

                onActiveChanged: {
                    if (active) {
                        root.picked(tile.modelData.name);
                        return;
                    }
                    // Snap to the neighbours' edges on release. Two monitors a
                    // few pixels apart is not an arrangement anyone wants: the
                    // gap is dead space no window can occupy, and the canvas is
                    // drawn at a fraction of real size, so flush is a value you
                    // could only hit by luck.
                    let sx = tile.lx, sy = tile.ly;
                    const snap = 80;
                    for (const o of root.outputs) {
                        if (o.name === tile.modelData.name)
                            continue;
                        for (const [a, b] of [[sx, o.x + o.width],
                                              [sx + tile.modelData.width, o.x],
                                              [sx, o.x]]) {
                            if (Math.abs(a - b) < snap)
                                sx += b - a;
                        }
                        for (const [a, b] of [[sy, o.y + o.height],
                                              [sy + tile.modelData.height, o.y],
                                              [sy, o.y]]) {
                            if (Math.abs(a - b) < snap)
                                sy += b - a;
                        }
                    }
                    tile.lx = sx;
                    tile.ly = sy;
                    root.moved(tile.modelData.name, sx, sy);
                }

                onTranslationChanged: {
                    if (!active || root.zoom <= 0)
                        return;
                    tile.lx = tile.modelData.x
                        + Math.round(drag.translation.x / root.zoom);
                    tile.ly = tile.modelData.y
                        + Math.round(drag.translation.y / root.zoom);
                }
            }

            TapHandler { onTapped: root.picked(tile.modelData.name) }
        }
    }

    Text {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.margins: 4
        text: "drag to arrange · click to select"
        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
        font.family: Cfg.fontFamily
        font.pointSize: Math.max(6, Cfg.fontSize * 0.6)
        font.hintingPreference: Font.PreferFullHinting
    }
}
