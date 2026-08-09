// The per-tag layout rules.
//
// Which layout each tag opens in, on which monitor, with the master factor and
// the scroller proportions that layout reads. These live in `tag` blocks and
// until recently were reachable only by editing the config file: `set-config`
// writes OPTIONS, and a tag rule is not one.
//
// Saved per card, not behind the window's global Apply bar, for the reason the
// rule and bind pages are: tag rules are addressed by INDEX, and a write
// renumbers everything after a removal. Batching a delete and an edit from two
// cards would send the second against an index the first invalidated.
//
// Rules apply in ORDER and a later one wins, which is why the list is not sorted
// by tag number: the order on screen is the order in the file, and re-sorting it
// would hide why a tag ends up in the layout it does.

import QtQuick
import "."
import ".."

Item {
    id: page

    property int expandedTag: -1
    property string status: ""
    property bool statusBad: false

    readonly property var tagRules: {
        void Rules.generation;
        return Rules.tagRules;
    }

    function saveTag(card) {
        const fields = {};
        for (const k in card.draft)
            fields[k] = card.draft[k];
        if (fields.id === undefined || fields.id === "") {
            // The compositor refuses this too, but saying it here means the
            // person sees why without a round trip: a `tag` block with no id
            // applies to tag 0, the ~0 tag, which is never what was meant.
            status = "a tag rule needs a tag number";
            statusBad = true;
            return;
        }
        Rules.submitTagRules([{ op: "update", index: card.index,
                                fields: fields }],
                             reply => page.report(reply, "saved"));
    }

    function deleteTag(index) {
        Rules.submitTagRules([{ op: "remove", index: index }],
                             reply => {
                                 page.expandedTag = -1;
                                 page.report(reply, "deleted");
                             });
    }

    function addTag() {
        // Tag 1 in the tiled layout: a rule that is complete, valid, and says
        // something ordinary. An empty one would be refused by the writer, and a
        // rule with only an id would be a block that sets nothing.
        Rules.submitTagRules([{ op: "add",
                                fields: { id: "1", layout_name: "tile" } }],
                             reply => {
                                 page.report(reply, "added");
                                 if (reply && reply.ok)
                                     openLast.restart();
                             });
    }

    Timer {
        id: openLast
        interval: 250
        onTriggered: page.expandedTag = Rules.tagRules.length
            ? Rules.tagRules[Rules.tagRules.length - 1].index : -1
    }

    function report(reply, verb) {
        if (reply && reply.ok === true) {
            status = "tag rule " + verb;
            statusBad = false;
        } else {
            status = Rules.failureText(reply);
            statusBad = true;
        }
    }

    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Rules apply in order and a later one wins, so the list is in "
                  + "file order rather than tag order. A rule with no monitor "
                  + "applies on every one of them."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: page.status !== ""
            wrapMode: Text.WordWrap
            text: page.status
            color: page.statusBad ? Cfg.urgent : Cfg.focusBg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        // A compositor older than the verb is a real state -- the bar and the
        // compositor are separate packages -- and it is worth saying plainly
        // rather than drawing an empty list that looks like "you have no tag
        // rules".
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: !Rules.tagSchemaLoaded
            wrapMode: Text.WordWrap
            text: "This compositor does not publish tag rules. It predates "
                  + "`get tag-rule-schema`; restart it after upgrading."
            color: Cfg.urgent
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: Rules.tagSchemaLoaded && page.tagRules.length === 0
            wrapMode: Text.WordWrap
            text: "No tag rules. Every tag opens in the default layout."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }

        Repeater {
            model: page.tagRules
            delegate: TagCard {
                required property var modelData
                rule: modelData
                view: page
            }
        }

        Item { width: 1; height: Cfg.spacing }

        SmallButton {
            visible: Rules.tagSchemaLoaded
            label: "New tag rule"
            onClicked: page.addTag()
        }
    }
}
