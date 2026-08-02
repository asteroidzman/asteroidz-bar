// One keybind: the chord, what it runs, and the four flags.
//
// The action is a PICKER over the 94 dispatch names the compositor publishes, not
// a text field. A typo in a text field writes a config that fails to reload, and
// that failure surfaces at the next login rather than at the save -- which is the
// worst place for it. The compositor refuses an unknown action too; this is so
// you never reach that refusal.
//
// Arguments are text fields with the argument's KIND as the placeholder. The
// schema says a dispatch takes a `tag-index` or a `direction`, and showing that is
// most of the value; building a distinct control for each of the eleven kinds is
// not, when the kinds are mostly short words you already know.

import QtQuick
import "."
import ".."

Rectangle {
    id: root

    required property var bind
    required property var view

    readonly property int index: bind.index
    readonly property bool editable:
        bind.source && bind.source.editable === true
    readonly property bool expanded: view.expandedBind === index

    property string chord: ""
    property string action: ""
    property var args: []
    property var flags: ({})
    property bool dirty: false

    readonly property var actionSpec: {
        void Rules.generation;
        return Rules.actionByName[action] || null;
    }
    // How many boxes to show. From the CHOSEN action, not from what the bind
    // happens to carry: picking a different dispatch changes how many arguments
    // are meaningful, and leaving the old ones on screen would write them.
    readonly property var argKinds: (actionSpec && actionSpec.args) || []

    function startEdit() {
        chord = bind.chord;
        action = bind.action;
        args = (bind.args || []).slice();
        const f = {};
        for (const k of ["keysym", "lock", "release", "pass"])
            f[k] = (bind.flags || {})[k] === true;
        flags = f;
        dirty = false;
    }

    // Seeded from being EXPANDED, not from being tapped -- see RuleCard, which had
    // the same bug: a tap was one of three ways a card opens and the only one that
    // filled the draft. The other two are a newly added bind, which the page
    // expands itself, and the rebuild that follows every save.
    onExpandedChanged: if (expanded) startEdit()
    Component.onCompleted: if (expanded) startEdit()

    function setArg(i, v) {
        const a = args.slice();
        while (a.length <= i)
            a.push("");
        a[i] = v;
        args = a;
        dirty = true;
    }

    function setFlag(k, v) {
        const f = Object.assign({}, flags);
        f[k] = v;
        flags = f;
        dirty = true;
    }

    // ── capture ─────────────────────────────────────────────────────────────
    property bool capturing: false
    property string captureNote: ""
    property bool captureBad: false

    function startCapture() {
        if (capturing)
            return;
        capturing = true;
        captureNote = "";
        captureBad = false;
        Ipc.request("capture-chord", reply => {
            root.capturing = false;
            if (reply && reply.ok === true) {
                root.chord = reply.chord;
                root.dirty = true;
                // Said out loud, because a chord that is already taken will
                // simply stop doing its old job once this is saved -- the
                // compositor takes the LAST matching bind and says nothing.
                const clash = Rules.bindsFor(reply.chord, root.index);
                root.captureNote = clash === ""
                    ? ""
                    : "Already bound to " + clash + " — saving this will shadow it.";
                root.captureBad = clash !== "";
            } else if (reply && reply.error === "cancelled") {
                root.captureNote = "";
            } else {
                root.captureNote = reply && reply.detail
                    ? reply.detail : "capture failed";
                root.captureBad = true;
            }
        });
    }

    width: parent ? parent.width : 0
    implicitHeight: body.implicitHeight + 2 * Cfg.spacing
    radius: Cfg.themeRadius
    color: expanded ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.04)
    border.width: dirty ? 2 : 0
    border.color: Cfg.focusBg

    Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Cfg.spacing
        spacing: Cfg.spacing

        Item {
            width: parent.width
            height: Math.max(24, Math.round(Cfg.fontPixelSize * 1.4))

            Text {
                id: chordText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width * 0.4)
                elide: Text.ElideRight
                text: root.bind.chord
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.bold: true
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                anchors.left: chordText.right
                anchors.leftMargin: Cfg.spacing * 2
                anchors.right: chevron.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: Rules.bindTitle(root.bind)
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.75)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                id: chevron
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.expanded ? "▴" : "▾"
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize * 0.8
            }

            TapHandler {
                onTapped: {
                    root.view.expandedBind = root.expanded ? -1 : root.index;
                }
            }
        }

        Text {
            width: parent.width
            elide: Text.ElideRight
            text: {
                const bits = [];
                if (root.bind.kind !== "bind")
                    bits.push(root.bind.kind);
                // The keymode, because two binds can share a chord in different
                // modes and a list without it shows what look like duplicates.
                if (root.bind.mode && root.bind.mode !== "default")
                    bits.push("mode " + root.bind.mode);
                const fl = Rules.bindFlagSummary(root.bind);
                if (fl)
                    bits.push(fl);
                const src = root.bind.source || {};
                if (src.kind === "file")
                    bits.push((src.file || "").split("/").pop() + ":" + src.line);
                if (!root.editable)
                    bits.push(src.reason ? "managed by " + src.reason
                                         : "written in the legacy form");
                return bits.join("  ·  ");
            }
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                           Cfg.fg.a * (root.editable ? 0.55 : 0.4))
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        // ── the editor ──────────────────────────────────────────────────────
        //
        // Behind a Loader, not merely `visible: false`, and on a page of 89 binds
        // that is the difference between opening instantly and opening slowly.
        //
        // A hidden item is still BUILT. Every card carried a full editor -- a
        // Picker whose model is the 94 dispatch actions the compositor
        // publishes, four flag toggles, three fields -- so the page constructed
        // eighty-nine of them to show one. The compositor was never the cost:
        // `get binds` answers in 2ms and `get dispatch-actions` in 1ms, both
        // measured, which is what ruled out the fetch and pointed here.
        //
        // At most one card is expanded at a time, so at most one of these exists.
        Loader {
            width: parent.width
            active: root.expanded
            visible: active
            height: active && item ? item.implicitHeight : 0
            sourceComponent: editorBody
        }
    }

    Component {
        id: editorBody

        Column {
            spacing: 2

            Item { width: 1; height: Cfg.spacing }

            // Laid out by anchoring, not with FormRow.
            //
            // FormRow REPARENTS its control -- `control.parent = root` -- and
            // that is fine at the top level and a trap inside a Repeater: the
            // control outlives the delegate that created it, so when the model
            // is re-evaluated the object survives with a dead JS context and
            // every binding on it starts failing with "Cannot read property
            // 'round' of undefined". That is exactly what the flag rows did.
            // RuleFieldRow was already anchoring directly for its own reasons;
            // this follows it.
            component LabeledRow: Item {
                property string rowLabel: ""
                property alias content: holder.data
                width: parent ? parent.width : 0
                implicitHeight: Math.max(holder.implicitHeight,
                                         Math.round(Cfg.fontPixelSize * 1.5))

                Text {
                    anchors.left: parent.left
                    anchors.right: holder.left
                    anchors.rightMargin: Cfg.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: parent.rowLabel
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.hintingPreference: Font.PreferFullHinting
                }

                Item {
                    id: holder
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(Math.round(Cfg.fontPixelSize * 8),
                                    Math.round(parent.width * 0.5))
                    implicitHeight: childrenRect.height
                }
            }

            // The chord, typed or PRESSED.
            //
            // Capturing has to happen in the compositor, not here: it takes
            // bindings before the focused surface sees them, so a window reading
            // its own key events would receive everything except the
            // combinations that are already bound -- exactly the ones you reach
            // for when rebinding. `capture-chord` is a deferred reply: the
            // request goes out, nothing comes back, and the answer arrives when
            // a key is pressed.
            LabeledRow {
                rowLabel: "Chord"
                content: Item {
                    width: parent.width
                    implicitHeight: chordField.implicitHeight

                    Field {
                        id: chordField
                        anchors.left: parent.left
                        anchors.right: captureBtn.left
                        anchors.rightMargin: Cfg.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        value: root.chord
                        enabled: root.editable && !root.capturing
                        opacity: (root.editable && !root.capturing) ? 1.0 : 0.4
                        placeholder: root.capturing ? "" : "Super+Shift+Q"
                        onCommitted: v => { root.chord = v; root.dirty = true; }
                    }

                    SmallButton {
                        id: captureBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.editable
                        label: root.capturing ? "Press a key…" : "Capture"
                        active: root.capturing
                        onClicked: root.startCapture()
                    }
                }
            }

            Text {
                width: parent.width
                visible: root.capturing || root.captureNote !== ""
                wrapMode: Text.WordWrap
                text: root.capturing
                    ? "Press the combination now. Escape cancels. Every key goes "
                      + "to this capture, so a shortcut you press will not run."
                    : root.captureNote
                color: root.captureBad ? Cfg.urgent : Cfg.focusBg
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                font.hintingPreference: Font.PreferFullHinting
            }

            LabeledRow {
                rowLabel: "Action"
                z: 10
                content: Picker {
                    width: parent.width
                    values: {
                        void Rules.generation;
                        return Rules.actions.map(a => a.name);
                    }
                    current: root.action
                    maxRows: 8
                    enabled: root.editable
                    opacity: root.editable ? 1.0 : 0.4
                    onPicked: v => { root.action = v; root.dirty = true; }
                }
            }

            Text {
                width: parent.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                text: root.actionSpec ? (root.actionSpec.desc || "") : ""
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                font.hintingPreference: Font.PreferFullHinting
            }

            Repeater {
                model: root.argKinds
                delegate: LabeledRow {
                    required property string modelData
                    required property int index
                    rowLabel: "Argument " + (index + 1)
                    content: Field {
                        width: parent.width
                        value: index < root.args.length ? root.args[index] : ""
                        enabled: root.editable
                        opacity: root.editable ? 1.0 : 0.4
                        // The KIND, from the dispatch schema. "tag-index" says
                        // more than an empty box, and it is the difference
                        // between guessing and knowing that `view` wants 1-9.
                        placeholder: modelData
                        onCommitted: v => root.setArg(index, v)
                    }
                }
            }

            Item {
                width: parent.width
                height: Math.round(Cfg.fontPixelSize * 1.4)
                visible: root.argKinds.length === 0 && root.action !== ""

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "takes no arguments"
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                    font.family: Cfg.fontFamily
                    font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                    font.hintingPreference: Font.PreferFullHinting
                }
            }

            // The four flags, always all four. Unlike a rule field, absent does
            // not mean "says nothing" here -- a bind either fires on release or
            // it does not -- so there is nothing to add or drop.
            Repeater {
                model: [
                    { key: "lock", label: "While locked",
                      desc: "Still fires when the screen is locked." },
                    { key: "release", label: "On release",
                      desc: "Fires when the key comes up, not when it goes down." },
                    { key: "pass", label: "Pass through",
                      desc: "The focused client also receives the key." },
                    { key: "keysym", label: "Match by keysym",
                      desc: "Match the symbol rather than the physical key." }
                ]
                delegate: Column {
                    required property var modelData
                    width: parent.width
                    spacing: 0

                    LabeledRow {
                        rowLabel: modelData.label
                        content: Toggle {
                            anchors.right: parent.right
                            enabled: root.editable
                            opacity: root.editable ? 1.0 : 0.4
                            on: root.flags[modelData.key] === true
                            onToggled: v => root.setFlag(modelData.key, v)
                        }
                    }

                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: modelData.desc
                        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                                       Cfg.fg.a * 0.5)
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.76)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                }
            }

            Item { width: 1; height: Cfg.spacing }

            Row {
                spacing: Cfg.spacing
                visible: root.editable

                SmallButton {
                    label: "Save"
                    active: root.dirty
                    onClicked: if (root.dirty) root.view.saveBind(root)
                }
                SmallButton {
                    label: "Revert"
                    onClicked: root.startEdit()
                }
                SmallButton {
                    label: "Delete"
                    onClicked: root.view.deleteBind(root.index)
                }
            }
        }
    }
}
