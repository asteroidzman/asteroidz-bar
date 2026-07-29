// A text field. A real one -- this is what a client can do that the
// compositor's popover could not: TextInput handles selection, the clipboard
// and IME, where the native bar had to grow a caret and a backspace that
// stepped over UTF-8 sequences by hand.
import QtQuick
import "."

Rectangle {
    id: root
    property alias text: input.text
    property string placeholder: ""
    signal committed(string value)

    implicitHeight: 24
    radius: Cfg.themeRadius
    color: Qt.rgba(1, 1, 1, 0.06)

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        verticalAlignment: TextInput.AlignVCenter
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize * 0.8
        font.hintingPreference: Font.PreferFullHinting
        selectByMouse: true
        clip: true
        onAccepted: root.committed(text)
    }

    Text {
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        visible: input.text === "" && !input.activeFocus
        text: root.placeholder
        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.4)
        font: input.font
    }
}
