// The panel that hangs off a pill: a menu, a set of readings, a form.
//
// A window of its own rather than an item drawn inside the bar: a panel
// surface is one bar's height tall and a menu is not, so anything drawn inside
// one would be clipped -- the native bar solves that by owning the whole scene
// graph, which a client does not.
//
// A LAYER SURFACE rather than an xdg popup, which is what this used to be. The
// compositor has no shadow for a popup: layer surfaces and toplevels each get
// one (layer_draw_shadow, client_draw_one_shadow), and a popup gets blur --
// popup_update_blur exists precisely for these popovers -- and nothing else.
// So a popover that wants the compositor's shadow instead of a Qt-drawn
// imitation of one has to stop being a popup.
//
// Three things fall out of that, and all three are simplifications:
//
//   - It takes the keyboard ITSELF. Qt refuses to create a grabbing popup here
//     ("Ensure popup has a transientParent set and that parent window has
//     received input"), falls back to an ordinary one silently, and left this
//     panel unable to receive so much as an Escape -- so the bar held focus on
//     its behalf and forwarded every keystroke across the window boundary. A
//     layer surface just asks for Exclusive focus and gets it.
//   - It may RESIZE while mapped. Repositioning a mapped xdg popup deadlocks
//     the client (Qt's reposition and quickshell's re-anchor coalesce into one
//     compositor cycle, only the last token is answered, and Qt then commits
//     without a buffer and never paints again), which is why this was a fixed
//     tall box with the panel floating inside it. A layer surface is
//     re-configured normally, so the surface is now exactly the panel -- which
//     is also what makes the compositor's shadow hug the panel rather than the
//     box it used to sit in.
//   - It is placed BY HAND. That is the one cost, and it is small: a popover
//     only ever hangs off one screen edge, so "constraint solving" is a clamp
//     in x (see anchorCenterX) rather than the flip-and-slide an arbitrary
//     popup needs.
//
// Row kinds are the ones the native popover has, and for the same reasons: a
// row is one hit target, so nothing is drawn that cannot be clicked.

import Quickshell
import Quickshell.Wayland
import QtQuick
import "."

PanelWindow {
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

    // ── where it goes ───────────────────────────────────────────────────────
    //
    // The pill that opened this is an item in a DIFFERENT surface -- a
    // SectionWindow -- so its position means nothing here. Bar.qml converts it
    // into the output's own coordinates and hands over the one number that
    // decides placement: the pill's horizontal centre.
    property real anchorCenterX: 0

    WlrLayershell.namespace: "asteroidz-bar-popover"
    // Above the panels, which are Top. A menu drawn under the bar it hangs off
    // is a menu nobody can read.
    WlrLayershell.layer: WlrLayer.Overlay

    // Exclusive while it is up, nothing while it is not.
    //
    // Exclusive rather than OnDemand: OnDemand leaves it to the compositor to
    // decide when this surface has the keyboard and it never decided in our
    // favour -- Escape went to whatever was focused before the menu opened. A
    // menu is modal for as long as it is up, which is what Exclusive says.
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    // Reserves nothing, placed where it asks -- the same terms as the panels.
    exclusionMode: ExclusionMode.Ignore

    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        left: true
    }

    // Clear of the strip the bar reserves, on whichever edge the bar is on.
    margins {
        top: Cfg.bottom ? 0 : Cfg.height + 2 * Cfg.marginY
        bottom: Cfg.bottom ? Cfg.height + 2 * Cfg.marginY : 0
        left: root.placedX
    }

    readonly property int screenWidth: screen ? screen.width : 1920
    readonly property int screenHeight: screen ? screen.height : 1080

    // Centred under the pill, then pushed back inside the screen. This is the
    // whole of what an xdg popup's constraint adjustment used to do here: a
    // popover is pinned to one edge, so the only correction it can need is in
    // x, and a menu on the last pill of the right-hand group is the case that
    // needs it.
    readonly property int placedX: Math.round(Math.max(
        Cfg.marginX,
        Math.min(root.anchorCenterX - root.width / 2,
                 root.screenWidth - root.width - Cfg.marginX)))

    // The surface IS the panel: these are the window's own size.
    //
    // It used to be a fixed tall box with the panel floating inside it,
    // because resizing a mapped xdg popup hangs the client permanently -- Qt
    // resizes the window (xdg_popup.reposition, its own token) and quickshell
    // re-anchors straight after (a second reposition, its own token, on its
    // own xdg_wm_base); when both land in one compositor event-loop cycle
    // wlroots coalesces them, only the LAST token is answered, and Qt then
    // acks the configure, commits WITHOUT A BUFFER and never paints again.
    //
    // None of that applies to a layer surface, which is re-configured like any
    // other window. So the box is gone, and the surface tracks the panel --
    // which is what the compositor needs it to do, since the shadow it draws
    // goes around the SURFACE. A box with a small panel floating in it would
    // have its shadow drawn around the box.
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

    // As tall as the screen beyond the bar allows, capped. It has to FIT: a
    // surface taller than the space under the pill would run off the far edge,
    // and nothing repositions it back -- this places itself.
    readonly property int maxPanelHeight:
        Math.min(700, root.screenHeight - Cfg.height - 3 * Cfg.marginY)

    // Width is latched at open rather than fixed: a menu is as wide as its
    // rows, and every popover being as wide as the widest would look absurd.
    // Latching is enough because nothing MAPS at the wrong width -- the panel
    // loads before `visible` goes true (see panelLoader) -- and a submenu that
    // wants more room than its parent had elides instead of resizing.
    // Width is latched at open rather than tracked: a menu is as wide as its
    // rows, and every popover being as wide as the widest would look absurd.
    // Resizing is no longer forbidden -- see above -- but a submenu that wants
    // more room than its parent had still elides rather than growing, because
    // a panel that changes width under the pointer is worse to use than one
    // that does not.
    property int lockedWidth: 0
    onVisibleChanged: {
        if (visible) {
            lockedWidth = panelWidth;
            // Taking the keyboard is not the same as an item holding it:
            // without this the surface has focus and nothing in it does, so
            // the key handler below never runs.
            keys.forceActiveFocus();
        } else {
            panel = null;
            /* The field is inside the panel that just went away. */
            keyTarget = null;
        }
    }

    implicitWidth: lockedWidth > 0 ? lockedWidth : panelWidth
    implicitHeight: panelHeight

    // The slab: the whole surface.
    //
    // There is no inset box any more. The compositor's shadow is drawn around
    // the SURFACE, so the panel and the surface being the same rectangle is
    // exactly what puts the shadow around the panel -- and it is also why the
    // mask that used to live here is gone. The mask existed because the window
    // was a shadow-reach larger than the panel on every side and that
    // transparent margin sat on top of the pill and swallowed the click that
    // should have closed the menu. With no margin there is nothing to mask.
    Rectangle {
        id: slab
        anchors.fill: parent
        radius: Cfg.panelRadius
        color: Cfg.popoverColor
    }

    // The frost, asked for the same way the panels ask: the region carries the
    // corner radius, so the blur ends where the rounded panel does.
    // A null item leaves a region with no area, which the compositor reads as
    // an explicit opt-out -- see the note in SectionWindow.qml.
    WlrLayershell.BackgroundEffect.blurRegion: Region {
        item: Cfg.panelBlur ? slab : null
        radius: Cfg.panelRadius
    }

    // Escape, and everything a form in a popover needs typed into it.
    //
    // Here rather than in Bar.qml, because this surface holds the keyboard
    // itself now. While this was an xdg popup it could not take focus at all,
    // so the BAR held focus on its behalf and forwarded every keystroke across
    // the window boundary to handleKey below.
    Item {
        id: keys
        anchors.fill: parent
        focus: true
        // Forwarded FIRST, so a text field in a panel gets the keystroke
        // before the menu's own row handling sees it -- see keyTarget.
        Keys.forwardTo: root.keyTarget ? [root.keyTarget] : []
        Keys.onPressed: event => root.handleKey(event)
    }

    Loader {
        id: panelLoader
        anchors.fill: parent
        anchors.margins: Cfg.popoverPadding
        // Loaded as soon as a panel is SET, not when the window becomes
        // visible: showPanel assigns `panel` and then `visible` in the same
        // tick, so loading eagerly means implicitWidth is already known when
        // the surface maps and the window never has to resize itself
        // afterwards. Waiting for `visible` made it map at the fallback width
        // and immediately reposition -- the exact move that hangs the client.
        // The popover clears `panel` when it hides, so nothing is kept alive.
        sourceComponent: root.panel
    }

    Column {
        id: content
        visible: root.panel === null
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
                        font.weight: Cfg.fontWeight
                        text: "‹"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        // Its own handler, so the arrow is the target rather
                        // than the row: the row's handler only focuses.
                        TapHandler { onTapped: root.spinBy(row.index, -1) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
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
                        font.weight: Cfg.fontWeight
                        text: "›"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        TapHandler { onTapped: root.spinBy(row.index, 1) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }

                // Checked entries and submenus, drawn at the trailing edge.
                //
                // Compared against true rather than tested for truth: a row
                // that mentions neither field yields `undefined || undefined`,
                // which is undefined, not false -- and binding that to
                // `visible` fails outright instead of hiding the marker.
                Text {
                    font.weight: Cfg.fontWeight
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

                HoverHandler {
                    id: hover
                    // A separator is not a row you can act on, and a
                    // disabled entry is one that refuses -- neither may
                    // claim to be clickable.
                    cursorShape: !row.modelData.separator
                        && row.modelData.enabled !== false
                        ? Qt.PointingHandCursor : Qt.ArrowCursor
                }

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

    // Called by the Keys handler above, which this surface's own focus makes
    // possible. Kept as a named function rather than inlined because it is the
    // whole of the popover's keyboard contract in one place.
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
