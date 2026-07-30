// A colour: the swatch, and the hex a user actually types.
//
// asteroidz spells colours `0xRRGGBBAA`, and that is what this edits -- one
// representation, the same one in the config file, the docs and the socket. A
// picker that produced only a swatch would make the value unspeakable: you
// could not paste one in from the palette, could not read one back out, and
// could not tell 0x00000000 from 0x000000ff.
//
// The swatch sits over a checkerboard so alpha is visible. Without it a fully
// transparent colour renders exactly like an opaque black one, and `shadow
// color 0x00000000` (a shadow turned off by making it invisible, which is a
// thing people do) looks identical to the darkest possible shadow.

import QtQuick
import "."
import ".."

Item {
    id: root

    // The canonical string, e.g. "0x2c2c2cff". Round-tripped, not derived from
    // `swatch`: parsing to a colour and formatting back loses nothing for a
    // valid value and would silently rewrite an invalid one to black.
    property string value: ""

    signal committed(string hex)

    implicitHeight: Math.max(24, Math.round(Cfg.fontPixelSize * 1.35))

    readonly property color parsed: Schema.parseColor(value, "transparent")
    readonly property bool valid:
        /^(?:0x|#)?(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test((value || "").trim())

    Item {
        id: swatch
        width: root.height
        height: root.height
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        opacity: root.enabled ? 1.0 : 0.4

        // The checkerboard. Cell size is derived so the pattern always has an
        // even number of cells across -- an odd count puts two same-coloured
        // cells side by side at the wrap and the grid stops reading as a grid.
        readonly property int cell: Math.max(3, Math.floor(width / 4))

        Rectangle {
            anchors.fill: parent
            radius: Cfg.themeRadius
            color: "#808080"
            clip: true

            Grid {
                columns: Math.ceil(swatch.width / swatch.cell)
                Repeater {
                    model: Math.ceil(swatch.width / swatch.cell)
                            * Math.ceil(swatch.height / swatch.cell)
                    delegate: Rectangle {
                        required property int index
                        readonly property int cols:
                            Math.ceil(swatch.width / swatch.cell)
                        width: swatch.cell
                        height: swatch.cell
                        color: ((index % cols) + Math.floor(index / cols)) % 2
                            ? "#606060" : "#a0a0a0"
                    }
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Cfg.themeRadius
            color: root.valid ? root.parsed : "transparent"
            border.width: 1
            border.color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.25)
        }

        // Says the text is not a colour, rather than showing the checkerboard
        // and leaving you to work out why the swatch went blank.
        Text {
            anchors.centerIn: parent
            visible: !root.valid && root.value !== ""
            text: "!"
            color: Cfg.urgent
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.bold: true
        }
    }

    Field {
        id: hex
        anchors.left: swatch.right
        anchors.leftMargin: Cfg.spacing
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: root.height
        // No `enabled` here: Item.enabled propagates down the object tree, so
        // disabling the ColorField already disables this. Opacity is what SAYS
        // so -- enabled is not a visual property, and a read-only field left at
        // full opacity just ignores clicks for no stated reason.
        opacity: root.enabled ? 1.0 : 0.4
        placeholder: "0xRRGGBBAA"

        // `value`, not `text`. A live binding onto `text` is broken by the first
        // keystroke and never tracks again, and until it breaks it resets the
        // cursor to the end of the line on every external update -- so typing a
        // colour comes out backwards. Field.value copies in only while the field
        // is not being edited.
        value: root.value
        onCommitted: v => {
            const t = v.trim();
            if (t === "")
                return;
            // Normalised on the way out, so "#2C2C2C" typed by hand and
            // "0x2c2c2cff" from the palette are the same value afterwards --
            // otherwise the row shows as changed-from-default forever because
            // its string differs from the compositor's spelling of the same
            // colour.
            const c = Schema.parseColor(t, null);
            root.committed(c === null ? t : Schema.formatColor(c));
        }
    }
}
