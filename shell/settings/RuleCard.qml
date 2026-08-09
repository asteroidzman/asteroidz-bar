// One window rule: a summary you can scan, and an editor you open.
//
// Collapsed by default because a rule list is something you read far more often
// than you edit, and fifty-three possible fields expanded across a dozen rules is
// not a list. The summary is the matchers, because "the mpv rule" is how a person
// refers to it -- not "rule 3".
//
// The editor shows the fields the rule SETS, and nothing else. That is not a
// space saving: a rule holds only what it sets, and offering all fifty-three with
// unset controls would mean a Save could not tell "leave blur alone" from "turn
// blur off". Adding a field is a deliberate act with its own picker.

import QtQuick
import "."
import ".."

Rectangle {
    id: root

    required property var rule
    // The page, for staging. Passed rather than reached for, the same way
    // OptionRow takes its view.
    required property var view

    readonly property int index: rule.index
    readonly property bool editable:
        rule.source && rule.source.editable === true
    readonly property bool expanded: view.expandedRule === index

    // The edit in progress: key -> value, or undefined for a dropped field.
    // Seeded from the rule the first time it is opened, so an unopened card
    // costs nothing.
    property var draft: ({})
    property bool dirty: false

    function startEdit() {
        const d = {};
        for (const k in rule.fields)
            d[k] = rule.fields[k];
        draft = d;
        dirty = false;
    }

    // Seeded from being EXPANDED, not from being tapped.
    //
    // A tap is one of three ways a card ends up open and it was the only one that
    // filled the draft, so the other two rendered an empty editor over a rule
    // that plainly has fields -- "This rule has no fields" printed underneath a
    // header listing them.
    //
    // The other two: a newly added rule is expanded by the page rather than by a
    // tap; and after any save the page re-reads, which replaces the model array
    // and REBUILDS every delegate -- so the card is constructed already expanded,
    // with a fresh empty draft, and nothing ever taps it. That second one is the
    // one that bites in normal use, because it happens every time you press Save.
    onExpandedChanged: if (expanded) startEdit()
    Component.onCompleted: if (expanded) startEdit()

    function setField(key, value) {
        const d = Object.assign({}, draft);
        d[key] = value;
        draft = d;
        dirty = true;
    }

    function dropField(key) {
        const d = Object.assign({}, draft);
        delete d[key];
        draft = d;
        dirty = true;
    }

    // Schema order, not object order, so a rule edited twice does not shuffle its
    // own rows under the pointer.
    readonly property var draftKeys: {
        void Rules.generation;
        const out = [];
        for (const f of Rules.fields)
            if (draft[f.key] !== undefined)
                out.push(f.key);
        return out;
    }

    readonly property var addableFields: {
        void Rules.generation;
        return Rules.fields.filter(f => draft[f.key] === undefined);
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

        // ── the summary line ────────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(24, Math.round(Cfg.fontPixelSize * 1.4))

            Text {
                font.weight: Cfg.fontWeight
                anchors.left: parent.left
                anchors.right: chevron.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: Rules.ruleTitle(root.rule)
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.bold: true
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                font.weight: Cfg.fontWeight
                id: chevron
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.expanded ? "▴" : "▾"
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
            }

            TapHandler {
                onTapped: {
                    // No startEdit here: setting expandedRule flips `expanded`,
                    // which seeds it. One path, so it cannot be forgotten on
                    // another.
                    root.view.expandedRule = root.expanded ? -1 : root.index;
                }
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }

        // What it does, and where it lives. Both on one dim line, because
        // collapsed cards are for scanning.
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            elide: Text.ElideRight
            text: {
                void Rules.generation;
                const acts = Rules.ruleActions(root.rule);
                const what = acts.length
                    ? acts.map(k => (Rules.fieldByKey[k] || {}).label || k)
                          .join(", ")
                    : "sets nothing";
                const src = root.rule.source || {};
                let where = "";
                if (src.kind === "file")
                    where = (src.file || "").split("/").pop() + ":" + src.line;
                if (!root.editable)
                    where += (where ? " · " : "")
                             + (src.reason ? "managed by " + src.reason
                                           : "cannot be rewritten");
                return what + (where ? "  ·  " + where : "");
            }
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                           Cfg.fg.a * (root.editable ? 0.55 : 0.4))
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        // ── the editor ──────────────────────────────────────────────────────
        //
        // Behind a Loader rather than merely hidden. A hidden item is still
        // built, and this one is a row per field of a rule that accepts
        // fifty-three of them -- so a list of seventeen rules constructed
        // seventeen editors to show one. See BindCard, where the same change is
        // worth more (eighty-nine cards, each with a picker over ninety-four
        // dispatch actions) and where the measurements are.
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

            Repeater {
                model: root.draftKeys
                delegate: RuleFieldRow {
                    required property string modelData
                    width: parent.width
                    field: Rules.fieldByKey[modelData]
                    value: root.draft[modelData]
                    editable: root.editable
                    onChanged: v => root.setField(modelData, v)
                    onDropped: root.dropField(modelData)
                }
            }

            Text {
                font.weight: Cfg.fontWeight
                width: parent.width
                visible: root.draftKeys.length === 0
                wrapMode: Text.WordWrap
                text: "This rule has no fields. A rule with no matchers applies "
                      + "to every window; one that also sets nothing does nothing."
                color: Cfg.urgent
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
                font.hintingPreference: Font.PreferFullHinting
            }

            Item { width: 1; height: Cfg.spacing }

            // Adding a field, by name. Grouped and searchable would be nicer;
            // a flat picker of the ~50 not-yet-set ones is what the schema
            // gives for free and is already better than remembering the names.
            Item {
                width: parent.width
                height: adder.implicitHeight
                visible: root.editable
                z: 5

                Picker {
                    id: adder
                    width: parent.width
                    values: {
                        const out = ["Add a field…"];
                        for (const f of root.addableFields)
                            out.push(f.label + "  (" + f.nice + ")");
                        return out;
                    }
                    current: "Add a field…"
                    maxRows: 8
                    onPicked: v => {
                        for (const f of root.addableFields) {
                            if (v === f.label + "  (" + f.nice + ")") {
                                // The default a newly added field takes. A
                                // tri-state added by hand means "turn this on" --
                                // nobody adds a field in order to set it to its
                                // inherited value.
                                root.setField(f.key,
                                              f.type === "tristate" ? "1"
                                              : (f.type === "enum"
                                                 ? (f.enum || [{}])[0].name || ""
                                                 : ""));
                                break;
                            }
                        }
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
                    onClicked: if (root.dirty) root.view.saveRule(root)
                }
                SmallButton {
                    label: "Revert"
                    onClicked: root.startEdit()
                }
                SmallButton {
                    label: "Delete"
                    onClicked: root.view.deleteRule(root.index)
                }
            }
        }
    }
}
