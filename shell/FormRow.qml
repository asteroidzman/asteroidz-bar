// A labelled control, at a fixed label width so a column of them lines up.
import QtQuick
import "."

Item {
    id: root
    property string label: ""
    property Item control: null
    // Wide enough for the longest label at whatever size the theme is using.
    readonly property int labelWidth: Math.round(Cfg.fontPixelSize * 8)

    // Tall enough for its control, not a constant: a Picker with its list open
    // is taller than a row, and a fixed 28 would have the list drawn over
    // whatever setting comes next instead of pushing it down.
    readonly property int rowHeight: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))
    implicitHeight: Math.max(rowHeight, control ? control.implicitHeight + 4 : 0)
    visible: true

    onControlChanged: if (control) {
        control.parent = root;
        control.anchors.left = undefined;
        control.x = Qt.binding(() => root.labelWidth);
        // Pinned to the TOP once the control is taller than a row: a control
        // that grows downwards (a list opening) must not drift upwards as it
        // does, or the thing under the pointer moves out from under it.
        control.y = Qt.binding(() => control.implicitHeight > root.rowHeight
            ? 2 : (root.height - control.height) / 2);
        control.width = Qt.binding(() => root.width - root.labelWidth);
    }

    Text {
        anchors.left: parent.left
        // Level with the control, on the control's terms: once a Picker opens
        // its list the row is several times a row tall, and a label centred in
        // THAT sits halfway down the open list with nothing beside it.
        y: root.control && root.control.implicitHeight > root.rowHeight
            ? Math.round((root.rowHeight - height) / 2)
            : Math.round((root.height - height) / 2)
        text: root.label
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
    }
}
