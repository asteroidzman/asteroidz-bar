// One value out of a short list, cycled by clicking.
//
// Not a dropdown: a popup inside a popup needs its own grab and its own
// dismiss rules, and every list here is short enough that stepping through it
// is faster than opening something. Scroll works too, which is how the native
// bar's steppers behaved.
import QtQuick
import "."

Rectangle {
    id: root
    property var values: []
    property string current: ""
    signal picked(string value)

    implicitHeight: 24
    radius: Cfg.themeRadius
    color: Qt.rgba(1, 1, 1, 0.06)

    function step(dir) {
        if (!values.length)
            return;
        let i = values.indexOf(current);
        if (i < 0)
            i = 0;
        i = (i + dir + values.length) % values.length;
        picked(values[i]);
    }

    Text {
        anchors.centerIn: parent
        text: root.current === "" ? "—" : root.current
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize * 0.8
        font.hintingPreference: Font.PreferFullHinting
    }

    TapHandler { onTapped: root.step(1) }
    WheelHandler { onWheel: ev => root.step(ev.angleDelta.y > 0 ? 1 : -1) }
}
