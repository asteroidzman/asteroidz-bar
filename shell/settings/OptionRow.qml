// One configuration option, drawn from its schema entry.
//
// Everything here is decided by data: which control to build comes from `type`,
// the range comes from `min`/`max`, the choices come from `enum`, the
// explanation is the compositor's own `desc`, and whether the control is
// editable comes from the provenance of the current value. There is no per-option
// code anywhere in this window, which is the whole point -- an option added to
// `config-schema.h` shows up here, explained and bounded, with no QML change.

import QtQuick
import "."
import ".."

Item {
    id: root

    // The schema entry: { key, path, group, subgroup, label, desc, type,
    //                     default, min?, max?, enum?, flags }
    required property var option
    // The settings window, for staging. Passed rather than reached for, so this
    // type stays usable anywhere a host offers the same three functions.
    required property var view

    readonly property string key: option.key
    readonly property string type: option.type
    readonly property bool numeric:
        type === "int" || type === "uint" || type === "float"
        || type === "double"
    readonly property bool bounded:
        numeric && option.min !== undefined && option.max !== undefined
    readonly property bool fractional: type === "float" || type === "double"

    // The legal answers, when there is a fixed set of them.
    //
    // Read from `enum` regardless of TYPE. An option can be stored as a string
    // and still have five legal values -- the animation types are, because
    // there the name is the value rather than an index into a table -- and
    // deciding the control from the type alone put a text box in front of a
    // closed list and asked the reader to know the spellings.
    readonly property var choices: option.enum || []

    // What the control should be showing: the staged edit if there is one, else
    // what the compositor reports.
    readonly property string shown: view.stagedValue(key)
    readonly property bool staged: view.isStaged(key)

    // Editable, and if not, why not.
    //
    // Two separate questions, and conflating them is how a settings app comes to
    // silently discard edits: matugen's file is REWRITTEN whenever the wallpaper
    // changes, so a value written there is not rejected -- it survives until the
    // next wallpaper and then reverts, which looks like the compositor forgetting
    // things at random. Overriding is offered explicitly instead.
    readonly property bool foreign: !Schema.writableOf(key)
    readonly property bool overridden: view.isOverridden(key)
    readonly property bool editable: !foreign || overridden

    readonly property bool atDefault: shown === option.default

    // The label column, right-aligned, with the control and everything that
    // explains it in the column beside it.
    //
    // This is the reference screenshot's arrangement, and it is a real
    // improvement over label-left/control-right: a description that starts under
    // the LABEL reads as a caption for the label, and the eye has to cross the
    // row to find what it describes. Under the control, it is where the answer to
    // "what does this do" belongs -- beside the thing that does it.
    //
    // A third of the width, floored so a narrow window does not squeeze the
    // labels to nothing and capped so a wide one does not strand the controls a
    // long way right of them.
    readonly property int labelColumn:
        Math.max(Math.round(Cfg.fontPixelSize * 6),
                 Math.min(Math.round(Cfg.fontPixelSize * 14),
                          Math.round(root.width * 0.30)))
    readonly property int gutter: Cfg.spacing * 2
    readonly property int fieldColumn:
        Math.max(Math.round(Cfg.fontPixelSize * 6),
                 root.width - labelColumn - gutter)
    readonly property int controlWidth:
        Math.min(fieldColumn, Math.max(Math.round(Cfg.fontPixelSize * 9),
                                       Math.round(root.width * 0.34)))

    implicitHeight: block.implicitHeight + Cfg.spacing

    // The label, right-aligned against the gutter and pinned to the top of the
    // row rather than centred in it: the row is as tall as its explanation, and
    // a label floating halfway down that has nothing beside it.
    Text {
        font.weight: Cfg.fontWeight
        id: labelText
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: Math.round(Cfg.fontPixelSize * 0.28)
        width: root.labelColumn
        horizontalAlignment: Text.AlignRight
        wrapMode: Text.WordWrap
        text: root.option.label
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
    }

    // Says "this differs from what the compositor is running", which is the one
    // piece of state a control cannot show about itself: a slider at 8 looks the
    // same whether 8 is applied or pending. In the gutter now, where it marks the
    // row rather than trailing the label's last word.
    Rectangle {
        anchors.verticalCenter: labelText.verticalCenter
        anchors.left: labelText.right
        anchors.leftMargin: Math.round(root.gutter / 2) - 3
        visible: root.staged
        width: 6
        height: 6
        radius: 3
        color: Cfg.focusBg
    }

    Column {
        id: block
        anchors.left: parent.left
        anchors.leftMargin: root.labelColumn + root.gutter
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 2

        // ── the control ─────────────────────────────────────────────────────
        Loader {
            id: control
            width: root.controlWidth
            sourceComponent: {
                if (root.type === "bool") return boolControl;
                if (root.choices.length > 0) return enumControl;
                if (root.type === "color") return colorControl;
                if (root.bounded) return sliderControl;
                return textControl;
            }
        }

        // ── the explanation ─────────────────────────────────────────────────
        //
        // Always shown, never behind a hover or an info icon. These sentences
        // are why the schema carries a `desc` field at all, and an explanation
        // you have to discover is one most people never read.
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: text !== ""
            wrapMode: Text.WordWrap
            text: root.option.desc || ""
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        // ── provenance, and the two affordances that depend on it ───────────
        Item {
            width: parent.width
            height: visible ? Math.round(Cfg.fontPixelSize * 1.2) : 0
            visible: !root.atDefault || root.foreign

            Text {
                font.weight: Cfg.fontWeight
                id: srcText
                anchors.left: parent.left
                anchors.right: acts.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: {
                    if (root.staged)
                        return "pending · was " + Schema.valueOf(root.key);
                    return Schema.sourceText(root.key);
                }
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
                font.hintingPreference: Font.PreferFullHinting
            }

            Row {
                id: acts
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Cfg.spacing

                // Override, for a value some other tool owns.
                //
                // It works because `source` in KDL is applied IN PLACE and later
                // declarations win: appending the key at the end of the main
                // config shadows the generated file that was sourced earlier. The
                // compositor does that when asked; it refuses by default. Both
                // halves matter -- refusing forever is a dead end, and doing it
                // silently means matugen and the settings window quietly fight
                // over the palette.
                SmallButton {
                    visible: root.foreign
                    label: root.overridden ? "Overriding" : "Override"
                    active: root.overridden
                    onClicked: root.view.toggleOverride(root.key)
                }

                SmallButton {
                    visible: !root.atDefault
                    label: "Reset"
                    onClicked: root.view.resetKey(root.key)
                }
            }
        }
    }

    // ── the controls ────────────────────────────────────────────────────────

    // Values cross the socket as the string a user would write, for every type,
    // so each control parses on the way in and formats on the way out. One
    // representation, and no argument about whether a bool is `true`, `#true` or
    // 1 -- the compositor accepts what it accepts and this asks it.
    Component {
        id: boolControl
        Item {
            implicitHeight: Math.max(22, Math.round(Cfg.fontPixelSize * 1.35))
            Toggle {
                // Left, with the other controls. It was right-aligned when the
                // control column was flush to the pane's right edge; now every
                // control starts at the same x, and a toggle drifting off to the
                // right would be the one that broke the line.
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.editable
                opacity: root.editable ? 1.0 : 0.4
                // "1"/"0" on the way out, not "true"/"false".
                //
                // OPT_BOOL is an int32_t and parse_option reads it with atoi, so
                // the schema formats it as 1 or 0 and validation puts the value
                // through strtod -- "true" comes back "expected a number", which
                // would be every toggle in this window refusing to apply. Both
                // spellings are accepted on the way IN, because a hand-written
                // config may legitimately say either.
                on: root.shown === "1" || root.shown === "true"
                onToggled: v => root.view.stage(root.key, v ? "1" : "0")
            }
        }
    }

    Component {
        id: enumControl
        Picker {
            // Aliases are dropped: `encoded` is a second spelling of `srgb` and
            // offering both would be two list entries that do the same thing,
            // one of which never appears as the current value.
            values: (root.option.enum || [])
                .filter(m => m.alias !== true).map(m => m.name)
            current: root.shown
            enabled: root.editable
            opacity: root.editable ? 1.0 : 0.4
            onPicked: v => root.view.stage(root.key, v)
        }
    }

    Component {
        id: colorControl
        ColorField {
            value: root.shown
            enabled: root.editable
            onCommitted: v => root.view.stage(root.key, v)
        }
    }

    Component {
        id: sliderControl
        Slider {
            from: root.option.min
            to: root.option.max
            // `target`, not `value`: `value` is what the drag writes, and a
            // binding on it dies at the first movement. See Slider.qml.
            target: {
                const v = parseFloat(root.shown);
                return isNaN(v) ? root.option.min : v;
            }
            enabled: root.editable
            // An integer steps by one; a float steps by a thousandth of its
            // range, so `0 .. 1` gets 0.001 and `0 .. 4096` gets ~4 -- one fixed
            // step cannot serve both, and this schema contains both.
            stepSize: root.fractional
                ? Math.abs(root.option.max - root.option.min) / 1000.0
                : 1
            decimals: root.fractional ? decimalsFor() : 0

            // As many places as the range needs and no more. A 0..1 opacity wants
            // three; a 0..4096 blur size wants none, and showing "512.000" there
            // is noise that also makes the readout column twice as wide as it
            // needs to be.
            function decimalsFor() {
                const span = Math.abs(root.option.max - root.option.min);
                if (span <= 2) return 3;
                if (span <= 20) return 2;
                return 1;
            }

            // Continuous drag previews; the release is what gets staged for
            // Apply. Staging every step would be a hundred entries in the
            // pending set for one gesture, and the window coalesces previews on
            // a timer anyway -- see SettingsWindow.preview.
            onMoved: v => root.view.preview(root.key, root.fmt(v))
            onReleased: v => root.view.stage(root.key, root.fmt(v))
        }
    }

    Component {
        id: textControl
        Field {
            value: root.shown
            enabled: root.editable
            opacity: root.editable ? 1.0 : 0.4
            // The nine numbers the compositor does not bound get a field, not a
            // slider with an invented range. What the field says it wants is the
            // default, which is the only concrete example available.
            placeholder: root.numeric ? root.option.default : ""
            onCommitted: v => root.view.stage(root.key, v)
        }
    }

    // Slider values are reals and the compositor reads strings, so the format
    // has to be decided once, here, rather than by String(v) -- which renders
    // 0.30000000000000004 for three drags of a 0.1 step and writes that into the
    // config file.
    function fmt(v) {
        if (!fractional)
            return String(Math.round(v));
        const span = Math.abs(option.max - option.min);
        const places = span <= 2 ? 3 : (span <= 20 ? 2 : 1);
        // parseFloat strips the trailing zeros toFixed adds, so an integral
        // float writes as "1" rather than "1.000" and stops reading as changed
        // from a default of "1".
        return String(parseFloat(v.toFixed(places)));
    }
}
