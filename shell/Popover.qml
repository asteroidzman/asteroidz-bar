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
import Quickshell.Wayland
import QtQuick
import Qt5Compat.GraphicalEffects
import "."

PopupWindow {
    id: root

    // [{ text, icon, enabled, separator, submenu, checked, input, value }]
    property var rows: []
    // A whole component instead of rows: the display panel is a form, and a
    // form is not expressible as a list of one-line targets.
    property Component panel: null
    property string title: ""
    // Set while a field is being typed into; see Bar.qml, which raises the
    // layer-shell keyboard focus only while this is true.
    readonly property bool wantsKeyboard:
        wantsKeyboardPanel || rows.some(r => r && r.input)

    signal activated(int index)
    signal edited(int index, string text)

    color: "transparent"

    // The window is bigger than the panel by the shadow's reach on every
    // side, and the panel is inset by it. A popup can only paint inside
    // itself, so a shadow drawn at the panel's own edge would be clipped
    // away entirely -- the same thing that happened to the bar's.
    readonly property int shadowRoom:
        Cfg.panelShadow && Cfg.panelEnable
            ? Cfg.panelShadowSize + Math.ceil(2 * Cfg.panelShadowBlur)
            : 0

    readonly property int panelWidth:
        (panelLoader.item
            ? panelLoader.item.implicitWidth
            : Math.max(Cfg.popoverWidth, content.implicitWidth))
        + 2 * Cfg.popoverPadding
    readonly property int panelHeight:
        Math.min(700, (panelLoader.item
                       ? panelLoader.item.implicitHeight
                       : content.implicitHeight)
                      + 2 * Cfg.popoverPadding)

    implicitWidth: panelWidth + 2 * shadowRoom
    implicitHeight: panelHeight + 2 * shadowRoom

    // ...and the growth is taken back out of the ANCHOR RECT, which is the
    // only part of this that has to be measured rather than reasoned about.
    //
    // Measured: quickshell CENTRES a popup on its anchor horizontally, and
    // puts the popup's top edge at the anchor's bottom. So the horizontal
    // half needs no correction at all -- the panel is centred in the window
    // and the window is centred on the pill -- and the first attempt, which
    // "compensated" with a negative left margin, simply shoved every popover
    // one shadow-reach to the left. Negative margins did nothing vertically
    // either, which left them a reach too low.
    //
    // Raising the rect's bottom edge by the reach is what works, and it is
    // written as a negative y rather than a shortened height because the
    // reach is LARGER than a pill is tall: `height - room` goes negative and
    // gets clamped, which lands the panel a few pixels off.
    anchor.rect: anchor.item
        ? Qt.rect(0, -shadowRoom, anchor.item.width, anchor.item.height)
        : Qt.rect(0, 0, 1, 1)

    // The pointer dismisses it, so it must be able to take clicks that land
    // outside any row.
    grabFocus: wantsKeyboard

    // The panel: the part you can see, inset from the window by the shadow.
    Item {
        id: panelBox
        anchors.centerIn: parent
        width: root.panelWidth
        height: root.panelHeight

        // The bar's shadow, on the same terms -- see Panel.qml, which
        // explains why RectangularGlow, why spread 0 and why half alpha.
        RectangularGlow {
            readonly property int delta: Cfg.panelShadowSize
            readonly property int reach:
                delta + Math.ceil(2 * Cfg.panelShadowBlur)

            anchors.centerIn: parent
            anchors.verticalCenterOffset: Math.round(delta / 3)
            width: parent.width
            height: parent.height
            cornerRadius: Cfg.panelRadius + delta
            glowRadius: reach
            spread: 0
            color: Qt.rgba(Cfg.panelShadowColor.r, Cfg.panelShadowColor.g,
                           Cfg.panelShadowColor.b, Cfg.panelShadowColor.a * 0.5)
            visible: Cfg.panelShadow && Cfg.panelEnable
            z: -1
        }

        Rectangle {
            id: slab
            anchors.fill: parent
            radius: Cfg.panelRadius
            color: Cfg.popoverColor
        }
    }

    // The frost, asked for the same way the bar asks: the region carries the
    // corner radius, so the blur ends where the rounded panel does and the
    // shadow margin around it stays clear.
    BackgroundEffect.blurRegion: Region {
        item: panelBox
        radius: Cfg.panelRadius
    }

    Loader {
        id: panelLoader
        anchors.fill: panelBox
        anchors.margins: Cfg.popoverPadding
        sourceComponent: root.visible ? root.panel : null
        // A panel takes keys of its own (text fields), so the bar has to hold
        // keyboard focus while one is up.
        onLoaded: root.wantsKeyboardPanel = true
        onItemChanged: if (!item) root.wantsKeyboardPanel = false
    }

    property bool wantsKeyboardPanel: false

    Column {
        id: content
        visible: root.panel === null
        anchors.fill: panelBox
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
                        //
                        // `|| ""` on the label, not a bare read: a row is a
                        // plain object built by whichever module opened the
                        // menu, and the ones that carry no label at all (every
                        // separator) were binding `undefined` to a QString.
                        text: row.modelData.input
                            ? (row.modelData.text || "") + ": "
                              + (row.modelData.value || "")
                              + (root.focusedRow === row.index ? "▌" : "")
                            : (row.modelData.text || "")
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
                //
                // Compared against true rather than tested for truth: a row
                // that mentions neither field yields `undefined || undefined`,
                // which is undefined, not false -- and binding that to
                // `visible` fails outright instead of hiding the marker.
                Text {
                    visible: row.modelData.separator !== true
                        && (row.modelData.checked === true
                            || row.modelData.submenu === true)
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
