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

    // ── dragging a module ───────────────────────────────────────────────────
    //
    // The arrows stay: they move one place, they are unambiguous about what
    // they did, and they are the only way to do this from a keyboard. Drag is
    // the direct way, and it is the one that can cross sections in one motion
    // rather than "remove, then re-add at the far end".
    //
    // The dragged row is NOT moved. It sits in its Column looking picked up
    // (dimmed), and a line shows where it would land -- because moving the item
    // would reflow the Column under the pointer, which moves the drop target
    // while you are aiming at it.
    property string dragName: ""
    property string dropSection: ""
    property int dropIndex: -1

    // Where would a release at this height put it? Sections are asked in
    // order; the last one also catches anything below it, so a drag past the
    // bottom lands at the end rather than nowhere.
    function updateDrop(py) {
        for (let i = 0; i < sectionRep.count; i++) {
            const sec = sectionRep.itemAt(i);
            if (!sec)
                continue;
            const top = sec.mapToItem(page, 0, 0).y;
            if (py < top + sec.height || i === sectionRep.count - 1) {
                dropSection = sec.modelData;
                dropIndex = sec.indexAt(py);
                return;
            }
        }
    }

    function commitDrop() {
        const name = dragName;
        const sect = dropSection;
        const at = dropIndex;
        dragName = "";
        dropSection = "";
        dropIndex = -1;
        if (name !== "" && sect !== "" && at >= 0)
            BarConfig.place(name, sect, at);
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Drawn left to right within each section. A module can only "
                  + "be in one section at a time \u2014 drag one to move it, or "
                  + "use the arrows to nudge it and the section box to send it "
                  + "elsewhere."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Repeater {
            id: sectionRep
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

                // How many rows sit above this height: the insertion index a
                // release here would use. Measured from each row's MIDPOINT, so
                // the target flips when the pointer passes the middle of a row
                // rather than its edge -- an edge means the last few pixels of a
                // row already belong to the next slot.
                function indexAt(py) {
                    let n = 0;
                    for (let i = 0; i < rowRep.count; i++) {
                        const it = rowRep.itemAt(i);
                        if (!it)
                            continue;
                        if (py > it.mapToItem(page, 0, it.height / 2).y)
                            n = i + 1;
                    }
                    return n;
                }

                Item { width: 1; height: Cfg.spacing }

                Text {
                    text: sec.modelData.charAt(0).toUpperCase()
                          + sec.modelData.slice(1)
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.weight: Cfg.fontWeightEmphasis
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
                    readonly property int lineHeight:
                        Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))
                    height: Math.max(lineHeight, shownPick.implicitHeight)
                    z: shownPick.open ? 10 : 0

                    // A fixed-height line to centre on. Centring on the ITEM
                    // instead moves everything down as soon as the picker
                    // expands, because the item is what grew.
                    Item {
                        id: shownLine
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: parent.lineHeight
                    }

                    Text {
                        font.weight: Cfg.fontWeight
                        id: shownLabel
                        anchors.left: parent.left
                        anchors.right: shownPick.left
                        anchors.rightMargin: Cfg.spacing
                        anchors.verticalCenter: shownLine.verticalCenter
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

                // An empty section still has to be a place you can drop into,
                // and a one-line label is a very small target for that. It
                // keeps a row's worth of height while a drag is in progress,
                // and says so.
                Item {
                    width: parent.width
                    visible: sec.items.length === 0
                    height: page.dragName !== ""
                            ? Math.max(28, Math.round(Cfg.fontPixelSize * 1.7))
                            : emptyLabel.implicitHeight

                    Rectangle {
                        anchors.fill: parent
                        visible: page.dragName !== ""
                        radius: Cfg.themeRadius
                        color: "transparent"
                        border.width: 1
                        border.color: page.dropSection === sec.modelData
                            ? Cfg.focusBg
                            : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.2)
                    }

                    Text {
                        font.weight: Cfg.fontWeight
                        id: emptyLabel
                        anchors.centerIn: parent
                        text: page.dragName !== "" ? "Drop here" : "Empty."
                        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                }

                // A header for the control columns. Once per section rather
                // than a label on every row: the picker is a `left/center/right`
                // box sitting directly under a "Shown on" row that also reads
                // like a placement control, and without a word over it there is
                // nothing to say which of the two axes it is.
                Item {
                    width: sec.width
                    height: Math.round(Cfg.fontPixelSize * 1.1)
                    visible: sec.items.length > 0

                    Text {
                        font.weight: Cfg.fontWeight
                        anchors.right: parent.right
                        anchors.rightMargin: Cfg.spacing + Math.round(Cfg.fontPixelSize * 4.6)
                        text: "section"
                        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.72)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                }

                // One row per module, in the order it is drawn.
                Repeater {
                    id: rowRep
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
                        color: Qt.rgba(1, 1, 1, row.beingDragged ? 0.02 : 0.05)
                        opacity: row.beingDragged ? 0.45 : 1.0

                        readonly property bool beingDragged:
                            page.dragName === row.modelData && page.dragName !== ""

                        // Picking it up. A DragHandler rather than a MouseArea
                        // so the taps on the buttons inside still get through --
                        // a MouseArea over the row would swallow them.
                        DragHandler {
                            id: rowDrag
                            target: null
                            onActiveChanged: {
                                if (active) {
                                    page.dragName = row.modelData;
                                } else if (page.dragName !== "") {
                                    page.commitDrop();
                                }
                            }
                            onCentroidChanged: {
                                if (!active)
                                    return;
                                page.updateDrop(
                                    page.mapFromItem(null,
                                        centroid.scenePosition).y);
                            }
                        }

                        HoverHandler {
                            cursorShape: rowDrag.active ? Qt.ClosedHandCursor
                                                        : Qt.OpenHandCursor
                        }

                        // Where it would land. Drawn on the row rather than
                        // between rows, because a Column's spacing is 4px and a
                        // line in it would be invisible.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 2
                            radius: 1
                            color: Cfg.focusBg
                            visible: page.dragName !== ""
                                     && page.dropSection === sec.modelData
                                     && (page.dropIndex === row.index
                                         || (page.dropIndex === row.index + 1
                                             && row.index === sec.items.length - 1))
                            y: page.dropIndex === row.index ? -3 : parent.height + 1
                        }

                        // Same fixed line as above, for the same reason.
                        Item {
                            id: rowLine
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: row.lineHeight
                        }

                        Text {
                            font.weight: Cfg.fontWeight
                            anchors.left: parent.left
                            anchors.leftMargin: Cfg.spacing
                            anchors.verticalCenter: rowLine.verticalCenter
                            text: (row.index + 1) + ".  " + row.modelData
                            color: Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        // Anchored to the line's TOP, not centred on the Row:
                        // the Row's implicitHeight is the open picker's, so
                        // centring it drove `y` negative and floated the whole
                        // control cluster up over the row above -- which is
                        // what made two rows' buttons overlap and every click
                        // land on the wrong one.
                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: Cfg.spacing
                            y: Math.max(0, Math.round(
                                   (row.lineHeight - sectionPick.rowHeight) / 2))
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
            font.weight: Cfg.fontWeightEmphasis
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            font.weight: Cfg.fontWeight
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
                        font.weight: Cfg.fontWeight
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
