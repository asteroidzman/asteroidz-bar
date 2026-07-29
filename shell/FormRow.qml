// A labelled control, at a fixed label width so a column of them lines up.
import QtQuick
import "."

Item {
    id: root
    property string label: ""
    property Item control: null

    // Tall enough for its control, not a constant: a Picker with its list open
    // is taller than a row, and a fixed 28 would have the list drawn over
    // whatever setting comes next instead of pushing it down.
    implicitHeight: Math.max(28, control ? control.implicitHeight + 4 : 0)
    visible: true

    onControlChanged: if (control) {
        control.parent = root;
        control.anchors.left = undefined;
        control.x = Qt.binding(() => 150);
        // Pinned to the TOP once the control is taller than a row: a control
        // that grows downwards (a list opening) must not drift upwards as it
        // does, or the thing under the pointer moves out from under it.
        control.y = Qt.binding(() => control.implicitHeight > 24
            ? 2 : (root.height - control.height) / 2);
        control.width = Qt.binding(() => root.width - 150);
    }

    Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize * 0.8
        font.hintingPreference: Font.PreferFullHinting
    }
}
