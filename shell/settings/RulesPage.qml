// The window-rule list.
//
// Saved per card, not behind the window's global Apply bar. That is a mapping to
// the compositor's API rather than a preference: rules are addressed by INDEX, and
// a write renumbers everything after a removal. Batching a delete and an edit from
// two different cards would send the second with an index the first invalidated --
// applied to the wrong rule, silently, because both rules are plausible.
//
// A rule is also a unit in a way an option is not. You do not adjust six rules a
// little; you fix the mpv rule.

import QtQuick
import "."
import ".."

Item {
    id: page

    property int expandedRule: -1
    property string status: ""
    property bool statusBad: false

    readonly property var rules: {
        void Rules.generation;
        return Rules.rules;
    }

    function saveRule(card) {
        const fields = {};
        for (const k in card.draft)
            fields[k] = card.draft[k];
        if (Object.keys(fields).length === 0) {
            status = "a rule with no fields would apply to every window and do "
                     + "nothing — delete it instead";
            statusBad = true;
            return;
        }
        Rules.submitRules([{ op: "update", index: card.index, fields: fields }],
                          reply => page.report(reply, "saved"));
    }

    function deleteRule(index) {
        Rules.submitRules([{ op: "remove", index: index }],
                          reply => {
                              page.expandedRule = -1;
                              page.report(reply, "deleted");
                          });
    }

    function addRule() {
        // A placeholder matcher, not an empty one.
        //
        // Two reasons and they point the same way. A rule with no matchers
        // applies to EVERY window, and so does one whose matcher is the empty
        // regex -- so a half-made rule left open in this window would already be
        // acting on everything. And the compositor refuses to write a rule that
        // renders to nothing at all, which an empty-valued field does.
        //
        // A literal that matches no real app id is inert until you replace it,
        // and reads as obviously unfinished.
        Rules.submitRules([{ op: "add", fields: { appid: "new-rule" } }],
                          reply => {
                              page.report(reply, "added");
                              // Open the one that was just made. It is last,
                              // because that is where an add goes -- and where it
                              // goes matters: later rules override earlier ones.
                              if (reply && reply.ok)
                                  openLast.restart();
                          });
    }

    Timer {
        id: openLast
        interval: 250
        onTriggered: page.expandedRule = Rules.rules.length
            ? Rules.rules[Rules.rules.length - 1].index : -1
    }

    function report(reply, verb) {
        if (reply && reply.ok === true) {
            status = "rule " + verb;
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
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Rules apply in order and every match applies, so a later rule "
                  + "overrides an earlier one. Matchers are regular expressions."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            width: parent.width
            visible: page.status !== ""
            wrapMode: Text.WordWrap
            text: page.status
            color: page.statusBad ? Cfg.urgent : Cfg.focusBg
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            width: parent.width
            visible: page.rules.length === 0
            wrapMode: Text.WordWrap
            text: Rules.ready ? "No window rules."
                              : "Reading the rules from the compositor…"
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }

        Repeater {
            model: page.rules
            delegate: RuleCard {
                required property var modelData
                rule: modelData
                view: page
            }
        }

        Item { width: 1; height: Cfg.spacing }

        SmallButton {
            label: "New rule"
            onClicked: page.addRule()
        }
    }
}
