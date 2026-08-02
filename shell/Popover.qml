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
    // A whole component instead of rows, for a panel that is a form rather
    // than a list of one-line targets.
    //
    // Nothing in the bar uses this today: the display panel was the only one,
    // and it is a pair of pages in the settings window now. It is kept because
    // the alternative to a form in a popover is not "no form" -- it is a form
    // squeezed into `rows`, which is the shape this exists to avoid.
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

                    // The label, and the typed text, as SEPARATE items -- the
                    // label is what gives way when there is not enough room.
                    //
                    // They used to be one string, `label + ": " + value`, with
                    // ElideRight on the lot. A popover latches its width at
                    // open (see lockedWidth), so stepping from a short menu
                    // into a form makes every row too long, and eliding a
                    // "Times (HH:MM, comma separated): 20:00▌" from the right
                    // takes away the 20:00 and the caret and leaves the label.
                    // Typing worked perfectly and showed nothing, on exactly
                    // the fields whose labels were longest -- reported as
                    // "can't input time, start date" while Name, whose label
                    // is short, was fine.
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        // `|| ""` on the label, not a bare read: a row is a
                        // plain object built by whichever module opened the
                        // menu, and the ones that carry no label at all (every
                        // separator) were binding `undefined` to a QString.
                        text: row.modelData.input
                            ? (row.modelData.text || "") + ": "
                            : (row.modelData.text || "")
                        color: row.modelData.enabled === false
                            ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.4)
                            : Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.weight: Cfg.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                        elide: Text.ElideRight
                        // Whatever the value does not need. A field's own text
                        // is never the part that gets cut.
                        width: Math.min(implicitWidth,
                                        Math.max(0, content.width - 32 - value.width))
                    }

                    Text {
                        id: value
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.modelData.input === true
                        // The caret belongs to the value, so an empty field
                        // still shows where the keystrokes are going.
                        text: visible
                            ? (row.modelData.value || "")
                              + (root.focusedRow === row.index ? "▌" : "")
                            : ""
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.weight: Cfg.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                    }
                }

                // A number, chosen rather than typed: ‹ 08 ›
                //
                // A menu row is a poor text field -- there is no selection, no
                // cursor to move, and a mistyped "8:0" is only found when the
                // form is submitted and refused. For a bounded number there is
                // nothing to type: the arrows cover the whole range, wrap at
                // the ends, and cannot produce a value the plugin has to
                // reject. `spin` on a row is what asks for this.
                Row {
                    id: spin
                    visible: row.modelData.separator !== true
                        && root.spinOf(row.modelData) !== null
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12

                    Text {
                        text: "‹"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        // Its own handler, so the arrow is the target rather
                        // than the row: the row's handler only focuses.
                        TapHandler { onTapped: root.spinBy(row.index, -1) }
                    }

                    Text {
                        text: root.spinLabel(row.modelData)
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.weight: Cfg.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                        // Wide enough for the widest value in range, so the
                        // arrows do not shuffle sideways as the number changes
                        // -- a moving target is miserable to click repeatedly.
                        horizontalAlignment: Text.AlignHCenter
                        width: root.spinWidth(row.modelData, font)
                    }

                    Text {
                        text: "›"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        TapHandler { onTapped: root.spinBy(row.index, 1) }
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
                        // A field takes the keyboard; it does not act. That
                        // includes a stepper, whose arrows are handled above
                        // and whose row body is just a way to aim the arrow
                        // keys at it.
                        if (row.modelData.input
                                || root.spinOf(row.modelData) !== null) {
                            root.focusedRow = row.index;
                            return;
                        }
                        root.activated(row.index);
                    }
                }
            }
        }
    }

    // ── steppers ────────────────────────────────────────────────────────────
    //
    // A row is a stepper when it carries `spin`: {min, max, step, wrap, pad}.
    // Its value travels in `value` exactly like a text field's, so it comes
    // back to the plugin in `fields` with everything else and neither side
    // needs a second channel.

    function spinOf(r) {
        return r && r.spin ? r.spin : null;
    }

    function spinNum(r) {
        const s = spinOf(r);
        if (!s)
            return 0;
        const v = parseInt(r.value, 10);
        // A field that has never been set reads as its minimum, not as NaN --
        // which would print "NaN" in the row and travel back as "NaN".
        return isNaN(v) ? (s.min !== undefined ? s.min : 0) : v;
    }

    function spinLabel(r) {
        const s = spinOf(r);
        if (!s)
            return "";
        const pad = s.pad || 0;
        return String(spinNum(r)).padStart(pad, "0");
    }

    // Room for the widest value the range allows, measured rather than
    // guessed: the font is the theme's and its digits are not always the same
    // width as any other font's.
    function spinWidth(r, font) {
        const s = spinOf(r);
        if (!s)
            return 0;
        const pad = s.pad || 0;
        const lo = String(s.min !== undefined ? s.min : 0).padStart(pad, "0");
        const hi = String(s.max !== undefined ? s.max : 59).padStart(pad, "0");
        const m = Qt.createQmlObject(
            'import QtQuick; TextMetrics {}', root, "spinWidth");
        m.font = font;
        m.text = lo.length >= hi.length ? lo : hi;
        const w = m.advanceWidth;
        m.destroy();
        return Math.ceil(w) + 2;
    }

    function spinBy(index, direction) {
        const r = rows[index];
        const s = spinOf(r);
        if (!s)
            return;
        const min = s.min !== undefined ? s.min : 0;
        const max = s.max !== undefined ? s.max : 59;
        const step = s.step || 1;
        let v = spinNum(r) + direction * step;
        // Wrapping is the default: hours run into days and minutes into
        // hours, and a person spinning past 23 means 0. `wrap: false` clamps,
        // which is what a year wants.
        if (v > max)
            v = s.wrap === false ? max : min;
        if (v < min)
            v = s.wrap === false ? min : max;
        focusedRow = index;
        edited(index, String(v));
    }

    // Which field the keyboard is aimed at, or -1. A stepper counts: it is a
    // field, it just has no letters in it.
    function isField(r) {
        return r && (r.input === true || spinOf(r) !== null);
    }

    // Enter advances rather than submitting: a form is filled top to bottom
    // and ends in an explicit Save row.
    function focusNextField() {
        for (let i = focusedRow + 1; i < rows.length; i++) {
            if (isField(rows[i])) {
                focusedRow = i;
                return true;
            }
        }
        return false;
    }

    property int focusedRow: -1

    // The same aim, remembered by FIELD NAME, so it survives the rows array
    // being rebuilt.
    //
    // Every keystroke rebuilds it: `edited` hands the new text to Bar.qml,
    // which replaces the whole array to change one row's value. That fires
    // onRowsChanged, and the version of this that unconditionally aimed at the
    // first field therefore snapped the caret back to field one after every
    // single character. Only the first field of a form could be typed into at
    // all -- reported on the reminders form, where the name accepted text and
    // the three rows under it looked dead.
    property string focusedField: ""

    onFocusedRowChanged: {
        const r = focusedRow >= 0 && focusedRow < rows.length
            ? rows[focusedRow] : null;
        focusedField = isField(r) ? (r.field || "") : "";
    }

    onRowsChanged: {
        // Still the same field, under whatever index it now has.
        if (focusedField !== "") {
            for (let i = 0; i < rows.length; i++) {
                if (isField(rows[i]) && rows[i].field === focusedField) {
                    focusedRow = i;
                    return;
                }
            }
        }
        // Unnamed fields (a menu that is not a plugin's) have no name to match
        // on, so hold the index instead, and only while the form is plainly
        // still the same one: the row at that index is editable.
        if (focusedField === "" && focusedRow >= 0 && focusedRow < rows.length
                && isField(rows[focusedRow]))
            return;

        // A different set of rows. Aim at its first field: a form opened in
        // order to be filled in should be typeable the moment it appears --
        // a panel with no caret shows nothing about where text would land and
        // swallows nothing, which reads as broken.
        focusedRow = -1;
        for (let i = 0; i < rows.length; i++) {
            if (isField(rows[i])) {
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

            // A stepper has no text to edit. Left/Down go back, Right/Up go
            // on, and a stray letter does nothing rather than being appended
            // to a number.
            if (root.spinOf(cur) !== null) {
                if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
                    root.spinBy(root.focusedRow, -1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right
                           || event.key === Qt.Key_Up) {
                    root.spinBy(root.focusedRow, 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return
                           || event.key === Qt.Key_Enter) {
                    root.focusNextField();
                    event.accepted = true;
                }
                return;
            }

            if (event.key === Qt.Key_Backspace) {
                const v = cur.value || "";
                root.edited(root.focusedRow, v.slice(0, -1));
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.focusNextField())
                    event.accepted = true;
            } else if (event.text && event.text.length > 0
                       && event.text.charCodeAt(0) >= 0x20) {
                root.edited(root.focusedRow, (cur.value || "") + event.text);
                event.accepted = true;
            }
        }
    }
}
