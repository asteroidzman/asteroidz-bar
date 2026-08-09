// One field of one window rule: its label, a control, and a way to drop it.
//
// The control comes from the schema's `type`, the same way OptionRow works. Two
// of those types exist only here and both are places a UI is wrong by default:
//
//   match     a REGEX, not literal text. The placeholder says so, because a
//             field that looks like a text box gets `org.mozilla.firefox` typed
//             into it and that is a pattern where every `.` is a wildcard.
//   tag       written 1..9 and stored as a bitmask. A picker, not a number box,
//             because there are nine of them and typing 12 is not an error the
//             compositor reports.
//
// Dropping a field is a first-class action rather than an afterthought. A rule
// holds only what it sets -- that is the whole distinction between "says nothing
// about blur" and "turns blur off" -- so removing a field has to be expressible,
// and it cannot be expressed by clearing a control.

import QtQuick
import "."
import ".."

Item {
    id: root

    required property var field   // the schema entry
    required property string value
    property bool editable: true

    signal changed(string v)
    signal dropped()

    readonly property int controlWidth:
        Math.max(Math.round(Cfg.fontPixelSize * 8),
                 Math.round(root.width * 0.42))

    // A matcher gets a second line: the windows open right now.
    readonly property bool offersWindows:
        field.type === "match" && editable
        && (field.key === "appid" || field.key === "title")

    // The first line, so the label and its control stay level with each other
    // when a second line is added below. Centring them in the WHOLE row instead
    // would drop them halfway down once the window picker appears.
    readonly property int lineHeight:
        Math.max(control.implicitHeight, Math.round(Cfg.fontPixelSize * 1.5))

    implicitHeight: lineHeight
                    + (offersWindows ? fromWindows.implicitHeight + 2 : 0)

    Item {
        id: line
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.lineHeight
    }

    Text {
        font.weight: Cfg.fontWeight
        id: label
        anchors.left: parent.left
        anchors.right: control.left
        anchors.rightMargin: Cfg.spacing
        anchors.verticalCenter: line.verticalCenter
        elide: Text.ElideRight
        text: root.field.label
        color: Cfg.fg
        opacity: root.editable ? 1.0 : 0.5
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
    }

    Loader {
        id: control
        anchors.right: dropBtn.left
        anchors.rightMargin: Cfg.spacing
        anchors.verticalCenter: line.verticalCenter
        width: root.controlWidth
        sourceComponent: {
            const t = root.field.type;
            if (t === "tristate") return boolControl;
            if (t === "enum") return enumControl;
            if (t === "tag") return tagControl;
            return textControl;
        }
    }

    SmallButton {
        id: dropBtn
        anchors.right: parent.right
        anchors.verticalCenter: line.verticalCenter
        visible: root.editable
        label: "×"
        onClicked: root.dropped()
    }

    // Pick a matcher off a window that is open.
    //
    // The same inline-picker idiom as "Add a field…" in the rule card, and the
    // same reason: a dropdown that opens as a popup inside a scrolling pane is a
    // second surface with its own dismiss rules, where expanding in place just
    // grows the row.
    Picker {
        id: fromWindows
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: line.bottom
        anchors.topMargin: 2
        visible: root.offersWindows
        z: 4
        maxRows: 6
        values: {
            const out = ["From an open window…"];
            for (const v of Rules.windowValuesFor(root.field.key))
                out.push(Rules.windowLabelFor(root.field.key, v));
            return out;
        }
        current: "From an open window…"
        onPicked: v => {
            for (const val of Rules.windowValuesFor(root.field.key))
                if (Rules.windowLabelFor(root.field.key, val) === v) {
                    root.changed(val);
                    return;
                }
        }
    }

    Component {
        id: boolControl
        Item {
            implicitHeight: Math.max(22, Math.round(Cfg.fontPixelSize * 1.35))
            Toggle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.editable
                opacity: root.editable ? 1.0 : 0.4
                // A two-state control for a THREE-state field, and that is
                // correct here: the third state is "the rule does not mention
                // this", which is the × beside it rather than a third position.
                // A tri-state widget would let you save a rule into a state the
                // file cannot distinguish from not having the field at all.
                on: root.value === "1"
                onToggled: v => root.changed(v ? "1" : "0")
            }
        }
    }

    Component {
        id: enumControl
        Picker {
            values: (root.field.enum || []).map(m => m.name)
            current: root.value
            enabled: root.editable
            opacity: root.editable ? 1.0 : 0.4
            onPicked: v => root.changed(v)
        }
    }

    Component {
        id: tagControl
        Picker {
            values: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
            current: root.value
            enabled: root.editable
            opacity: root.editable ? 1.0 : 0.4
            onPicked: v => root.changed(v)
        }
    }

    Component {
        id: textControl
        Field {
            value: root.value
            enabled: root.editable
            opacity: root.editable ? 1.0 : 0.4
            placeholder: {
                if (root.field.regex === true)
                    return "regex, e.g. ^kitty$";
                if (root.field.min !== undefined
                        && root.field.max !== undefined)
                    return root.field.min + " – " + root.field.max;
                return "";
            }
            onCommitted: v => root.changed(v)
        }
    }
}
