// The keybind list.
//
// Saved per card for the same reason the rules are: binds are addressed by index
// and a write renumbers everything after a removal, so batching two cards' edits
// would send the second against an index the first invalidated.
//
// Binds that cannot be rewritten are still listed. Hiding them would be worse than
// showing them greyed: you would rebind Super+Q in here, find it still doing the
// old thing, and have nothing to look at. The kinds that have no KDL handler at
// all are named at the foot of the list for the same reason.

import QtQuick
import "."
import ".."

Item {
    id: page

    property int expandedBind: -1
    property string status: ""
    property bool statusBad: false
    property string filter: ""

    readonly property var binds: {
        void Rules.generation;
        if (filter === "")
            return Rules.binds;
        const n = filter.toLowerCase();
        return Rules.binds.filter(
            b => b.chord.toLowerCase().includes(n)
                 || b.action.toLowerCase().includes(n)
                 || (b.args || []).join(" ").toLowerCase().includes(n));
    }

    function saveBind(card) {
        if (!card.chord || !card.action) {
            status = "a bind needs a chord and an action";
            statusBad = true;
            return;
        }
        // Only as many arguments as the chosen action takes. The card keeps the
        // old ones in its draft when you switch dispatch, so that switching back
        // does not lose what you typed -- but writing them would put arguments on
        // a dispatch that has none.
        const n = card.argKinds.length;
        const args = [];
        for (let i = 0; i < n; i++)
            args.push(i < card.args.length ? card.args[i] : "");
        Rules.submitBinds([{
            op: "update", index: card.index, kind: card.bind.kind,
            chord: card.chord, action: card.action, args: args,
            flags: card.flags
        }], reply => page.report(reply, "saved"));
    }

    function deleteBind(index) {
        Rules.submitBinds([{ op: "remove", index: index }], reply => {
            page.expandedBind = -1;
            page.report(reply, "deleted");
        });
    }

    function addBind() {
        Rules.submitBinds([{
            op: "add", kind: "bind", chord: "Super+F1", action: "kill_client"
        }], reply => {
            page.report(reply, "added");
            if (reply && reply.ok)
                openLast.restart();
        });
    }

    Timer {
        id: openLast
        interval: 250
        onTriggered: {
            // The new bind, found by what it was created as rather than by
            // position: an add goes into the existing `binds` block, so its index
            // is wherever that block sits in the file, not the end of the list.
            for (const b of Rules.binds)
                if (b.chord === "Super+F1" && b.action === "kill_client") {
                    page.expandedBind = b.index;
                    return;
                }
        }
    }

    function report(reply, verb) {
        if (reply && reply.ok === true) {
            status = "bind " + verb;
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

        Field {
            width: parent.width
            placeholder: "Filter by chord or action"
            value: page.filter
            onTextChanged: page.filter = text
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

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: page.binds.length === 0
            wrapMode: Text.WordWrap
            text: !Rules.ready ? "Reading the binds from the compositor…"
                : (page.filter !== "" ? "Nothing matches “" + page.filter + "”."
                                      : "No binds.")
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }

        Repeater {
            model: page.binds
            delegate: BindCard {
                required property var modelData
                bind: modelData
                view: page
            }
        }

        Item { width: 1; height: Cfg.spacing }

        SmallButton {
            label: "New bind"
            onClicked: page.addBind()
        }

        // What this list does NOT contain, said out loud. axis, switch and
        // gesture binds are raw comma-string leaves with no KDL block handler, so
        // nothing records a source for them and they cannot appear here. A list
        // with no note would be quietly claiming they do not exist, and someone
        // tidying their binds through this window would lose them.
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: Rules.notListed.length > 0
            wrapMode: Text.WordWrap
            text: "Not shown: " + Rules.notListed.join(", ")
                  + " — these have no block form yet, so they can only be edited "
                  + "in the config file."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }
    }
}
