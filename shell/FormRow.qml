// A labelled control, at a fixed label width so a column of them lines up.
import QtQuick
import "."

Item {
    id: root
    property string label: ""
    property Item control: null

    implicitHeight: 28
    visible: true

    onControlChanged: if (control) {
        control.parent = root;
        control.anchors.left = undefined;
        control.x = Qt.binding(() => 150);
        control.y = Qt.binding(() => (root.height - control.height) / 2);
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
