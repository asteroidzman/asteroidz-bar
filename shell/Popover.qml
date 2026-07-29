// The panel that hangs off a pill: a menu, a set of readings, a form.
//
// A real popup window rather than an item drawn inside the bar. The bar
// surface is 66px tall and a menu is not, so anything drawn inside it would be
// clipped -- the native bar solves that by owning the whole scene graph, which
// a client does not. A popup is also what makes the click-outside-to-dismiss
// and the keyboard grab work without inventing either.
//
// Row kinds are the ones the native popover has, and for the same reasons: a
// row is one hit target, so nothing is drawn that cannot be clicked.

import Quickshell
import QtQuick
import "."

PopupWindow {
    id: root

    // [{ text, icon, enabled, separator, submenu, checked, input, value }]
    property var rows: []
    property string title: ""
    // Set while a field is being typed into; see Bar.qml, which raises the
    // layer-shell keyboard focus only while this is true.
    readonly property bool wantsKeyboard: rows.some(r => r && r.input)

    signal activated(int index)
    signal edited(int index, string text)

    color: "transparent"
    implicitWidth: Math.max(Cfg.popoverWidth, content.implicitWidth
                            + 2 * Cfg.popoverPadding)
    implicitHeight: Math.min(600, content.implicitHeight
                             + 2 * Cfg.popoverPadding)

    // The pointer dismisses it, so it must be able to take clicks that land
    // outside any row.
    grabFocus: wantsKeyboard

    Rectangle {
        anchors.fill: parent
        radius: Cfg.panelRadius
        color: Cfg.popoverColor
    }

    Column {
        id: content
        anchors.fill: parent
        anchors.margins: Cfg.popoverPadding
        spacing: Cfg.popoverSpacing

        Repeater {
            model: root.rows

            delegate: Item {
                id: row
                required property var modelData
                required property int index

                width: content.width
                height: modelData.separator ? Math.max(1, Cfg.popoverSpacing * 2)
                                            : Cfg.popoverRowHeight

                // A separator is scenery, not a target: clicking one must
                // neither act nor dismiss, the way it behaves in every menu.
                Rectangle {
                    visible: row.modelData.separator === true
                    anchors.centerIn: parent
                    width: parent.width
                    height: 1
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.18)
                }

                Rectangle {
                    visible: !row.modelData.separator
                    anchors.fill: parent
                    radius: Cfg.themeRadius
                    color: hover.hovered && row.modelData.enabled !== false
                        ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.10)
                        : "transparent"
                }

                Row {
                    visible: !row.modelData.separator
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Icon {
                        name: row.modelData.icon || ""
                        size: Cfg.popoverRowHeight - 12
                        visible: name !== ""
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        // A field shows what has been typed, with a caret --
                        // the label alone gives no clue where the keystrokes
                        // are going.
                        text: row.modelData.input
                            ? row.modelData.text + ": " + (row.modelData.value || "")
                              + (root.focusedRow === row.index ? "▌" : "")
                            : row.modelData.text
                        color: row.modelData.enabled === false
                            ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.4)
                            : Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.weight: Cfg.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, content.width - 32)
                    }
                }

                // Checked entries and submenus, drawn at the trailing edge.
                Text {
                    visible: !row.modelData.separator
                        && (row.modelData.checked || row.modelData.submenu)
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.submenu ? "›" : "✓"
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                }

                HoverHandler { id: hover }

                TapHandler {
                    enabled: !row.modelData.separator
                        && row.modelData.enabled !== false
                    onTapped: {
                        if (row.modelData.input) {
                            root.focusedRow = row.index;
                            return;
                        }
                        root.activated(row.index);
                    }
                }
            }
        }
    }

    // Which field the keyboard is aimed at, or -1.
    //
    // A form opened in order to be filled in should be typeable the moment it
    // appears, so the first field is aimed automatically -- a panel with no
    // caret shows nothing about where text would land and swallows nothing,
    // which reads as broken.
    property int focusedRow: -1

    onRowsChanged: {
        focusedRow = -1;
        for (let i = 0; i < rows.length; i++) {
            if (rows[i] && rows[i].input) {
                focusedRow = i;
                break;
            }
        }
    }

    Item {
        anchors.fill: parent
        focus: root.wantsKeyboard

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.visible = false;
                event.accepted = true;
                return;
            }
            if (root.focusedRow < 0)
                return;

            const cur = root.rows[root.focusedRow];
            if (event.key === Qt.Key_Backspace) {
                const v = cur.value || "";
                root.edited(root.focusedRow, v.slice(0, -1));
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                // Enter advances rather than submitting: a form is filled top
                // to bottom and ends in an explicit Save row.
                for (let i = root.focusedRow + 1; i < root.rows.length; i++) {
                    if (root.rows[i].input) {
                        root.focusedRow = i;
                        event.accepted = true;
                        return;
                    }
                }
            } else if (event.text && event.text.length > 0
                       && event.text.charCodeAt(0) >= 0x20) {
                root.edited(root.focusedRow, (cur.value || "") + event.text);
                event.accepted = true;
            }
        }
    }
}
