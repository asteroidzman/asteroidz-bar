// A text field. A real one -- this is what a client can do that the
// compositor's popover could not: TextInput handles selection, the clipboard
// and IME, where the native bar had to grow a caret and a backspace that
// stepped over UTF-8 sequences by hand.
import QtQuick
import Quickshell
import "."

Rectangle {
    id: root
    property alias text: input.text
    property string placeholder: ""
    signal committed(string value)

    // Claim the popover's key forwarding.
    //
    // Keys arrive at the BAR's surface, not at the popup this lives in -- see
    // Popover.keyTarget, which explains why -- so being clicked is not enough to
    // receive them.
    //
    // `QsWindow.window`, not a walk up `parent`. The visual parent chain does
    // NOT reach the window: a Loader's item is parented to the Loader, the
    // Loader to the window's contentItem, and a PopupWindow is not an Item, so
    // the chain dead-ends one step short. Walking it looked right, compiled,
    // ran, and set nothing -- the keys arrived at the bar with keyTarget still
    // null. QsWindow.window is quickshell's attached property for exactly this,
    // and it returns the WRAPPER (the PopupWindow) rather than the underlying
    // QQuickWindow, which is the object carrying keyTarget.
    function claimKeys() {
        const w = QsWindow.window;
        if (w && w.isPopover === true)
            w.keyTarget = input;
    }

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
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
        selectByMouse: true
        clip: true
        onAccepted: root.committed(text)

        // `focus`, not `activeFocus`. activeFocus additionally requires the
        // item's WINDOW to be active, which this popup's is not in any reliable
        // way -- the bar holds the keyboard. Qt still tracks focus within the
        // popup's own scope and a click sets it, which is the signal wanted.
        onFocusChanged: if (focus) root.claimKeys()
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
