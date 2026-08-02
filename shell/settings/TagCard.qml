// One tag rule: which tag, on which monitor, in which layout, and the settings
// that layout reads.
//
// A near-twin of RuleCard, and deliberately so -- a tag rule and a window rule
// are the same kind of object (a set of fields, addressed by index, edited in
// place, saved on its own) over different vocabularies. What is NOT shared is
// the vocabulary itself: the fields, their types and their groups come from
// `get tag-rule-schema`, so nothing here knows what `mfact` means.
//
// Collapsed by default, like a window rule and for the same reason: a list of
// tags is something you read far more often than you edit, and nine rules
// expanded across thirteen fields each is not a list.

import QtQuick
import "."
import ".."

Rectangle {
    id: root

    required property var rule
    required property var view

    readonly property int index: rule.index
    readonly property bool expanded: view.expandedTag === index
    readonly property var source: rule.source || ({})
    readonly property bool editable: source.editable === true

    // The edit in progress. Copied out of the rule on expand rather than bound
    // to it, so a half-made change is not written by the next refresh -- and so
    // Revert has something to go back to.
    property var draft: ({})
    property var draftKeys: []

    function startEdit() {
        const d = {};
        const keys = [];
        // Schema order, not whatever order the JSON enumerated: the fields
        // should read the same way every time the card opens.
        for (const f of Rules.tagFields)
            if (rule.fields[f.key] !== undefined) {
                d[f.key] = rule.fields[f.key];
                keys.push(f.key);
            }
        draft = d;
        draftKeys = keys;
    }

    readonly property bool dirty: {
        void draft;
        const orig = rule.fields || {};
        const mine = Object.keys(draft);
        if (mine.length !== Object.keys(orig).length)
            return true;
        for (const k of mine)
            if (draft[k] !== orig[k])
                return true;
        return false;
    }

    function setField(key, value) {
        const d = Object.assign({}, draft);
        d[key] = value;
        draft = d;
    }

    function dropField(key) {
        const d = Object.assign({}, draft);
        delete d[key];
        draft = d;
        draftKeys = draftKeys.filter(k => k !== key);
    }

    function addField(key) {
        if (draft[key] !== undefined)
            return;
        const f = Rules.tagFieldByKey[key];
        const d = Object.assign({}, draft);
        // A sensible starting value per type, because an empty string is not one
        // for a number and would be written as a field that fails to parse.
        d[key] = f && f.type === "enum" && f.enum && f.enum.length
            ? f.enum[0].name
            : (f && (f.type === "int" || f.type === "float") ? "1"
               : (f && f.type === "tristate" ? "1" : ""));
        draft = d;
        // Schema order again, so an added field lands where it belongs rather
        // than at the end.
        const keys = [];
        for (const sf of Rules.tagFields)
            if (d[sf.key] !== undefined)
                keys.push(sf.key);
        draftKeys = keys;
    }

    onExpandedChanged: if (expanded) startEdit()
    Component.onCompleted: if (expanded) startEdit()

    width: parent ? parent.width : 0
    implicitHeight: col.implicitHeight + Cfg.spacing * 2
    radius: Cfg.themeRadius
    color: expanded ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.04)

    Column {
        id: col
        x: Cfg.spacing
        y: Cfg.spacing
        width: parent.width - Cfg.spacing * 2
        spacing: 2

        // ── the summary ─────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.6))

            Text {
                anchors.left: parent.left
                anchors.right: chevron.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: Rules.tagRuleTitle(root.rule)
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.hintingPreference: Font.PreferFullHinting
            }

            Text {
                id: chevron
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: root.expanded ? "▴" : "▾"
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize * 0.8
            }

            TapHandler {
                onTapped: root.view.expandedTag = root.expanded ? -1 : root.index
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }

        // What the rule actually does, on one line, so the list is readable
        // without opening anything.
        Text {
            width: parent.width
            visible: !root.expanded && text !== ""
            elide: Text.ElideRight
            text: {
                const f = root.rule.fields || {};
                const bits = [];
                if (f.layout_name) bits.push(f.layout_name);
                if (f.nmaster) bits.push("nmaster " + f.nmaster);
                if (f.mfact) bits.push("mfact " + f.mfact);
                if (f.scroller_default_proportion)
                    bits.push("cols " + f.scroller_default_proportion);
                if (f.open_as_floating === "1") bits.push("opens floating");
                if (f.no_hide === "1") bits.push("never hides");
                if (f.no_render_border === "1") bits.push("no borders");
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
        // Behind a Loader, like BindCard's: a hidden item is still built, and a
        // page of nine cards would construct nine editors to show one.
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

            Text {
                width: parent.width
                visible: !root.editable
                wrapMode: Text.WordWrap
                text: root.source.kind === "legacy"
                    ? "Written as a `tagrule=` line rather than a `tag` block, "
                      + "so there is no block to rewrite. Read-only."
                    : "From " + (root.source.file || "a generated file")
                      + (root.source.reason ? " (" + root.source.reason + ")" : "")
                      + ", which is rewritten by something else. Read-only."
                color: Cfg.urgent
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
                font.hintingPreference: Font.PreferFullHinting
            }

            Repeater {
                model: root.draftKeys
                delegate: RuleFieldRow {
                    required property string modelData
                    width: parent.width
                    // The tag vocabulary, not the window one. Same row, same
                    // controls: the schema says `enum` and `tristate` in both.
                    field: Rules.tagFieldByKey[modelData] || ({})
                    value: root.draft[modelData] || ""
                    editable: root.editable
                    onChanged: v => root.setField(modelData, v)
                    onDropped: root.dropField(modelData)
                }
            }

            Item { width: 1; height: Cfg.spacing }

            // Adding a field, from the ones this rule does not already set.
            Picker {
                width: Math.round(Cfg.fontPixelSize * 14)
                visible: root.editable
                maxRows: 8
                values: {
                    const out = ["Add a setting…"];
                    for (const f of Rules.tagFields)
                        if (root.draft[f.key] === undefined)
                            out.push(f.label);
                    return out;
                }
                current: "Add a setting…"
                onPicked: v => {
                    for (const f of Rules.tagFields)
                        if (f.label === v) {
                            root.addField(f.key);
                            return;
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
                    onClicked: if (root.dirty) root.view.saveTag(root)
                }
                SmallButton {
                    label: "Revert"
                    onClicked: root.startEdit()
                }
                SmallButton {
                    label: "Delete"
                    onClicked: root.view.deleteTag(root.index)
                }
            }
        }
    }
}
