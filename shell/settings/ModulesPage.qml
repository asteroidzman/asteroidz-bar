// What the bar draws, where, in what order, and on which screen.
//
// This is the bar's OWN configuration -- it is written to the bar's config
// file, not sent to the compositor, because the compositor draws none of it.
// It used to live in the compositor's `bar {}` block for one historical
// reason: the compositor used to draw the bar.
//
// Applied as you change it, like the Wallpaper page and for the same reason:
// the only way to arrange a bar is to see it. There is no Apply, and the
// window's apply bar stays hidden here.

import QtQuick
import "."
import ".."

Item {
    id: page

    implicitHeight: col.implicitHeight

    // Everything the bar could draw that is not already placed. A module can
    // only be in one section, so this is the difference rather than a list with
    // some entries greyed out.
    readonly property var unplaced: {
        void BarConfig.sections;
        const out = [];
        for (const m of BarConfig.available)
            if (BarConfig.sectionOf(m) === "")
                out.push(m);
        return out;
    }

    // "" is every screen and is the ordinary answer, so it is offered first and
    // by a name rather than as an empty entry.
    readonly property string everyScreen: "every screen"

    // Compositor.monitors is a MAP KEYED BY OUTPUT NAME, not an array -- it is
    // built that way so `Compositor.monitor("DP-1")` is a lookup rather than a
    // scan. Iterating it with for...of throws, which in QML means this function
    // returns nothing and the picker silently offers only "every screen".
    function monitorValues() {
        const out = [everyScreen];
        for (const name of Object.keys(Compositor.monitors || ({})))
            if (name !== "")
                out.push(name);
        return out;
    }

    // "focused" is deliberately not offered. Cfg.sectionOnScreen() treats it
    // exactly like "" -- it is a name inherited from the old config that never
    // meant anything different -- and a picker entry that changes nothing is
    // worse than one that is missing, because the user has no way to tell it
    // did not work. A config that still says "focused" keeps behaving as it
    // always has, and reads back here as what it actually does.
    function monitorLabel(stored) {
        if (stored === "" || stored === "all" || stored === "focused")
            return everyScreen;
        return stored;
    }

    function monitorStored(label) {
        return label === everyScreen ? "" : label;
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Drawn left to right within each section. A module can only "
                  + "be in one section at a time."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Repeater {
            model: BarConfig.sectionIds

            delegate: Column {
                id: sec
                required property string modelData
                width: col.width
                spacing: 4

                readonly property var items: {
                    void BarConfig.sections;
                    return BarConfig.itemsOf(modelData);
                }

                Item { width: 1; height: Cfg.spacing }

                Text {
                    text: sec.modelData.charAt(0).toUpperCase()
                          + sec.modelData.slice(1)
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.weight: Font.DemiBold
                    font.hintingPreference: Font.PreferFullHinting
                }

                // NOT a FormRow. FormRow does `control.parent = root`, which is
                // fine at the top level and a trap in a delegate: the control is
                // reparented out of the delegate that made it, so it draws over
                // whatever is above -- here, straight on top of the section
                // heading -- and it outlives the delegate with a dead JS
                // context, which is why picking a monitor did nothing. The
                // label and the control are anchored directly instead, the way
                // RuleFieldRow and BindCard's LabeledRow both do.
                Item {
                    width: sec.width
                    // Follows the picker, which expands IN PLACE rather than
                    // opening a popup -- a dropdown hanging past this surface's
                    // edge would be clipped away by it. A fixed height here
                    // means the list opens into a box that cannot hold it and
                    // nothing appears to happen.
                    height: Math.max(Math.max(28, Math.round(Cfg.fontPixelSize * 1.6)),
                                     shownPick.implicitHeight)
                    z: shownPick.open ? 10 : 0

                    Text {
                        id: shownLabel
                        anchors.left: parent.left
                        anchors.right: shownPick.left
                        anchors.rightMargin: Cfg.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: "Shown on"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.hintingPreference: Font.PreferFullHinting
                    }

                    Picker {
                        id: shownPick
                        anchors.right: parent.right
                        anchors.top: parent.top
                        width: Math.max(Math.round(Cfg.fontPixelSize * 8),
                                        Math.round(parent.width * 0.42))
                        values: page.monitorValues()
                        current: page.monitorLabel(BarConfig.monitorOf(sec.modelData))
                        onPicked: v => BarConfig.setMonitor(sec.modelData,
                                                           page.monitorStored(v))
                    }
                }

                Text {
                    width: parent.width
                    visible: sec.items.length === 0
                    text: "Empty."
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                    font.family: Cfg.fontFamily
                    font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
                    font.hintingPreference: Font.PreferFullHinting
                }

                // One row per module, in the order it is drawn.
                Repeater {
                    model: sec.items

                    delegate: Rectangle {
                        id: row
                        required property string modelData
                        required property int index
                        width: sec.width
                        // Same as the row above: the section picker expands in
                        // place, so this has to make room for it.
                        readonly property int lineHeight:
                            Math.max(28, Math.round(Cfg.fontPixelSize * 1.7))
                        height: Math.max(lineHeight, sectionPick.implicitHeight)
                        z: sectionPick.open ? 10 : 0
                        radius: Cfg.themeRadius
                        color: Qt.rgba(1, 1, 1, 0.05)

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Cfg.spacing
                            y: (row.lineHeight - height) / 2
                            text: (row.index + 1) + ".  " + row.modelData
                            color: Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: Cfg.spacing
                            y: (row.lineHeight - implicitHeight) / 2
                            spacing: 4

                            // Order within the section. Buttons rather than
                            // drag: a drag needs a drop target for every gap
                            // between rows AND for the two other sections, and
                            // an arrow that moves one place is unambiguous
                            // about what it did.
                            SmallButton {
                                label: "▲"
                                active: row.index > 0
                                onClicked: if (row.index > 0)
                                    BarConfig.move(row.modelData, -1)
                            }
                            SmallButton {
                                label: "▼"
                                active: row.index < sec.items.length - 1
                                onClicked: if (row.index < sec.items.length - 1)
                                    BarConfig.move(row.modelData, 1)
                            }
                            // Which section it belongs to. Appending rather
                            // than preserving the index, because position in
                            // one section says nothing about position in
                            // another.
                            Picker {
                                id: sectionPick
                                width: Math.round(Cfg.fontPixelSize * 6)
                                values: BarConfig.sectionIds
                                current: sec.modelData
                                onPicked: v => {
                                    if (v !== sec.modelData)
                                        BarConfig.place(row.modelData, v,
                                                        BarConfig.itemsOf(v).length);
                                }
                            }
                            SmallButton {
                                label: "Remove"
                                onClicked: BarConfig.remove(row.modelData)
                            }
                        }
                    }
                }
            }
        }

        Item { width: 1; height: Cfg.spacing }

        // ── adding one back ─────────────────────────────────────────────────
        Text {
            text: "Not shown"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.weight: Font.DemiBold
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            width: parent.width
            visible: page.unplaced.length === 0
            wrapMode: Text.WordWrap
            text: "Everything this bar can draw is placed."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Flow {
            width: parent.width
            spacing: 6

            Repeater {
                model: page.unplaced

                delegate: Rectangle {
                    id: spare
                    required property string modelData
                    height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.6))
                    width: spareLabel.implicitWidth
                           + Math.round(Cfg.fontPixelSize * 1.2)
                    radius: Cfg.themeRadius
                    color: Qt.rgba(1, 1, 1, 0.06)

                    Text {
                        id: spareLabel
                        anchors.centerIn: parent
                        text: "+ " + spare.modelData
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSize
                        font.hintingPreference: Font.PreferFullHinting
                    }

                    // Added to the right section, which is where a status
                    // module goes and is the least surprising place for one to
                    // appear. It can be moved from there.
                    TapHandler {
                        onTapped: BarConfig.place(
                            spare.modelData, "right",
                            BarConfig.itemsOf("right").length)
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
            }
        }
    }
}
