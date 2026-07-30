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

    // THE TEXT FIELD KEYSTROKES HAVE TO BE FORWARDED TO.
    //
    // A Field inside a panel could not be typed into at all. The chain:
    // the compositor sends keys to whatever holds keyboard focus, which is the
    // BAR's layer surface (Bar.qml raises WlrKeyboardFocus.Exclusive while a
    // popover is up); this popup deliberately never grabs focus, because Qt
    // refuses to create a grabbing popup here and falls back silently; and the
    // key handler in Bar.qml routes everything to handleKey below, which only
    // ever knew about the MENU ROWS model. For a panel `rows` is empty, so
    // focusedRow stayed -1 and every keystroke past Escape was dropped on the
    // floor. Folder, Cycle and the Display tab's ICC path were all inert.
    //
    // So the event has to be forwarded across the window boundary, and it is
    // forwarded to a real TextInput rather than reimplemented: Field exists
    // precisely so that selection, the clipboard and IME are Qt's problem and
    // not ours, and hand-rolling a caret and a UTF-8-aware backspace is what
    // the native bar had to do.
    //
    // Set by Field on itself when clicked -- it walks up to find this object --
    // so there is no per-call-site wiring to forget when a panel gains a field.
    readonly property bool isPopover: true
    property Item keyTarget: null

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

    // THE SURFACE NEVER RESIZES WHILE IT IS UP. This is not a style choice.
    //
    // Resizing a mapped popup hangs the client, permanently. Qt resizes the
    // window (xdg_popup.reposition, its own token) and quickshell re-anchors
    // straight after (a second reposition, its own token, on its own
    // xdg_wm_base). When both land in one compositor event-loop cycle wlroots
    // coalesces them -- xdg-shell says in as many words that "if multiple
    // reposition requests are sent, the compositor may skip all but the last
    // one" -- so only the LAST token gets an xdg_popup.repositioned event and
    // Qt's is never answered. Qt then acks the configure, applies the new size
    // to its wp_viewport, commits WITHOUT A BUFFER and never paints again: the
    // old frame stays stretched over the new surface size until the popup is
    // destroyed. Opening the Scale list did that every time; switching tabs
    // got away with it only by winning the race.
    //
    // So the window is a fixed box and the PANEL moves inside it. Content is
    // free to grow and shrink -- a dropdown opening, a submenu replacing a
    // menu -- without a single reposition, because none of it reaches
    // implicitWidth/implicitHeight while `visible` is true.
    readonly property int panelWidth:
        (panelLoader.item
            ? panelLoader.item.implicitWidth
            : Math.max(Cfg.popoverWidth, content.implicitWidth))
        + 2 * Cfg.popoverPadding
    readonly property int panelHeight:
        Math.min(maxPanelHeight, (panelLoader.item
                                  ? panelLoader.item.implicitHeight
                                  : content.implicitHeight)
                                 + 2 * Cfg.popoverPadding)

    // As tall as the screen below the bar allows, capped. It has to FIT: a
    // window taller than the space under the pill gets slid back up by the
    // compositor (set_constraint_adjustment includes slide_y), which would
    // move the panel out from under the thing that opened it.
    readonly property int screenHeight:
        anchor.window && anchor.window.screen ? anchor.window.screen.height : 1080
    readonly property int maxPanelHeight:
        Math.min(700, screenHeight - Cfg.height - 2 * Cfg.marginY
                      - 2 * shadowRoom - 8)

    // Width is latched at open rather than fixed: a menu is as wide as its
    // rows, and every popover being as wide as the widest would look absurd.
    // Latching is enough because nothing MAPS at the wrong width -- the panel
    // loads before `visible` goes true (see panelLoader) -- and a submenu that
    // wants more room than its parent had elides instead of resizing.
    property int lockedWidth: 0
    onVisibleChanged: {
        if (visible) {
            lockedWidth = panelWidth + 2 * shadowRoom;
        } else {
            panel = null;
            /* The field is inside the panel that just went away. */
            keyTarget = null;
        }
    }

    implicitWidth: lockedWidth > 0 ? lockedWidth : panelWidth + 2 * shadowRoom
    implicitHeight: maxPanelHeight + 2 * shadowRoom

    // quickshell CENTRES a popup on its anchor horizontally and puts the
    // popup's top edge at the anchor's bottom, so no correction is needed in
    // either direction: the panel is inset from the window's top by the shadow
    // reach (see panelBox) and centred in it, and the window is centred on the
    // pill. An earlier attempt "compensated" with a negative left margin and
    // shoved every popover one shadow-reach to the left.
    anchor.rect: anchor.item
        ? Qt.rect(0, 0, anchor.item.width, anchor.item.height)
        : Qt.rect(0, 0, 1, 1)

    // NOT grabbed, because asking does not work here.
    //
    // A grabbing popup is the usual way a menu dismisses itself, and Qt
    // refuses to create one:
    //
    //   qt.qpa.wayland: Failed to create grabbing popup. Ensure popup has a
    //   transientParent set and that parent window has received input.
    //
    // It then falls back to an ordinary popup, silently, so the menu appears
    // and simply cannot be dismissed -- no click-outside, and no keyboard
    // focus for Escape to arrive through. Dismissal is therefore the BAR's
    // job: it covers the screen while a menu is up and closes it on any click
    // that is not on a pill, and it owns the keyboard focus that Escape
    // needs. See Bar.qml.
    grabFocus: false

    // The panel: the part you can see, inset from the window by the shadow.
    //
    // Pinned to the TOP of the window rather than centred in it. The window is
    // now a fixed tall box (see above) and only the panel tracks the content,
    // so centring would float the panel down the middle of that box and away
    // from the pill it hangs off.
    Item {
        id: panelBox
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: root.shadowRoom
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

    // Input stops at the panel, not at the window.
    //
    // The window is a shadow-reach larger than the panel on every side, and
    // that margin is transparent -- but a popup with no mask takes input
    // across its whole surface, so the margin above the panel sat ON TOP of
    // the pill that opened it and swallowed the click. Clicking the same pill
    // to close the menu did nothing at all, while clicking anywhere else
    // worked, which made it look like a toggle bug rather than a hit-testing
    // one.
    mask: Region {
        item: panelBox
        radius: Cfg.panelRadius
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
        // Loaded as soon as a panel is SET, not when the window becomes
        // visible: showPanel assigns `panel` and then `visible` in the same
        // tick, so loading eagerly means implicitWidth is already known when
        // the surface maps and the window never has to resize itself
        // afterwards. Waiting for `visible` made it map at the fallback width
        // and immediately reposition -- the exact move that hangs the client.
        // The popover clears `panel` when it hides, so nothing is kept alive.
        sourceComponent: root.panel
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

    // Keys are handled by whoever HAS the keyboard, which is the bar: this
    // popup never takes focus (see grabFocus above), so a Keys handler here
    // would never fire. Bar.qml calls this instead.
    function handleKey(event) {
        {
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
