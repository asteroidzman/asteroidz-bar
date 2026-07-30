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

    // The value from OUTSIDE, for a field that mirrors state someone else owns.
    //
    // Separate from `text` because binding a live value straight onto `text`
    // fights the keyboard: typing assigns to input.text, which breaks the
    // binding, so the field stops tracking the value it is supposed to be
    // showing -- and until it breaks, every external update resets the cursor to
    // the end of the line. This copies in only when the field is not being
    // edited.
    //
    // Leaving the field without pressing Enter therefore puts the shown value
    // back, which is the honest reading of a commit-on-Enter field: the edit did
    // not take. The ⏎ hint below says so while the edit is live.
    property string value: ""
    onValueChanged: if (!keysHere) input.text = value;
    Component.onCompleted: input.text = value;

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

    // Whether keystrokes will land HERE.
    //
    // The answer depends on what kind of window this field is in, and there are
    // two:
    //
    // In a POPOVER, not `input.focus` and not `input.activeFocus`, though both
    // are tempting. Bar.qml forwards keys to whatever the popover names as its
    // keyTarget, so being that target IS being focused, and anything else would
    // be a highlight that lies. activeFocus in particular is unreliable there --
    // it additionally requires the popup's window to be active, which it is not
    // in any dependable way, because the bar holds the keyboard.
    //
    // In an ORDINARY WINDOW -- the settings window is a real xdg toplevel -- none
    // of that applies: the window has the keyboard itself and Qt's own focus is
    // exactly where the keys are going. Answering with the popover's rule there
    // would report false forever, which means no caret, no outline, and a
    // placeholder drawn over the text you are typing.
    //
    // A field with no affordance was reported as "you can type stuff in but it
    // is not clear you're actually focused on the field", which is the whole
    // problem: the caret TextInput draws by itself is tied to activeFocus, so it
    // came and went for reasons having nothing to do with where the keys were
    // going.
    readonly property bool keysHere: {
        const w = QsWindow.window;
        if (w !== null && w.isPopover === true)
            return w.keyTarget === input;
        return input.activeFocus;
    }

    // What the value was when this field last became focused, or was last
    // committed. Only used to decide whether the "press Enter" hint is showing,
    // so it does not have to survive an external update exactly.
    //
    // NOT called `baseline`: Item already declares that as FINAL (it is an
    // anchor line), and QML rejects the whole type with "Cannot override FINAL
    // property" -- which surfaces as the BAR failing to load, four levels of
    // "Type X unavailable" away from the actual line.
    property string lastCommitted: ""
    readonly property bool dirty: keysHere && input.text !== lastCommitted

    // One handler, both jobs: QML allows exactly one binding per signal, and a
    // second `onKeysHereChanged` elsewhere in this file is not a duplicate
    // handler, it is "Property value set multiple times" and the whole type
    // failing to load.
    onKeysHereChanged: {
        if (keysHere)
            lastCommitted = input.text;
        else
            // Left without committing: put the shown value back. An edit that
            // was not applied should not keep sitting there looking applied, and
            // if Enter WAS pressed then `value` is already the new one and this
            // is a no-op.
            input.text = value;
    }

    implicitHeight: Math.max(24, Math.round(Cfg.fontPixelSize * 1.35))
    radius: Cfg.themeRadius
    color: keysHere ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06)

    // The accent outline is the unambiguous part. The fill lifting from 6% to
    // 12% alone is too subtle to read as a state, and on a light theme it is
    // nearly invisible.
    border.width: keysHere ? 2 : 0
    border.color: Cfg.focusBg

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: enterHint.visible ? enterHint.width + 10 : 6
        verticalAlignment: TextInput.AlignVCenter
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
        selectByMouse: true
        clip: true

        onAccepted: {
            root.lastCommitted = text;
            root.committed(text);
        }

        // `focus`, not `activeFocus`. activeFocus additionally requires the
        // item's WINDOW to be active, which this popup's is not in any reliable
        // way -- the bar holds the keyboard. Qt still tracks focus within the
        // popup's own scope and a click sets it, which is the signal wanted.
        onFocusChanged: if (focus) root.claimKeys()

        // Forced on rather than left to TextInput.
        //
        // Its own caret is bound to activeFocus, which here is decided by
        // whether the POPUP's window is active -- nothing to do with where the
        // keys are actually going. So the caret appeared and vanished for
        // unrelated reasons, and a field you were typing into often had none.
        cursorVisible: root.keysHere
    }

    // "There is an uncommitted edit in here, and Enter is what applies it."
    //
    // The two fields in the wallpaper tab apply on Enter and nothing said so --
    // reported alongside the missing focus highlight. Shown only while focused
    // AND changed, so it is an instruction at the moment it is actionable rather
    // than decoration that is always there.
    Text {
        id: enterHint
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        visible: root.dirty
        text: "⏎"
        color: Cfg.focusBg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
    }

    Text {
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        // keysHere, not activeFocus: the placeholder has to disappear when the
        // field is the one taking keys, on the same terms as everything else
        // here.
        visible: input.text === "" && !root.keysHere
        text: root.placeholder
        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.4)
        font: input.font
    }
}
