// The wallpaper: where they come from, how often they change, and which one.
//
// The other half of the bar's old display popover. It kept its apply model in
// the move -- everything here takes effect as you change it -- and that is not
// an inconsistency with the Displays page beside it. Nothing on this page is
// disruptive or slow, and applying immediately is the only way picking a
// wallpaper could work at all: you choose it by seeing it.
//
// The window makes one thing possible that the popover could not: the browser
// is as tall as the folder needs. In a surface capped at 700px it was a 220px
// box scrolling inside a panel that could not scroll, which is why it was three
// tiles of however many you own.

import QtQuick
import "."
import ".."

Item {
    id: page

    implicitHeight: col.implicitHeight

    // Spelt out rather than "all"/"per-monitor": these are the words in the
    // dropdown, and what is stored is not what is shown.
    readonly property string scopeAll: "One for all monitors"
    readonly property string scopePer: "One per monitor"

    // Which monitor a tile click applies to, in per-monitor scope. Empty means
    // every monitor, which is also what the whole page means in "all" scope.
    property string target: ""

    // The file the target is showing: its own override, or the shared one if
    // it has none. This is what the grid marks as selected.
    readonly property string current: {
        void Wallpaper.storedPerMonitor;
        if (target === "") return Wallpaper.path;
        return Wallpaper.wallpaperFor(target) || Wallpaper.path;
    }

    // The timetable of whatever the target is showing. Re-asked whenever that
    // changes, and on a slow tick so the countdown below does not sit at the
    // number it had when the page opened.
    property var dyn: ({ dynamic: false })
    function refreshDyn() { dyn = Wallpaper.dynamicInfo(current); }
    onCurrentChanged: refreshDyn()
    Timer {
        running: page.dyn.dynamic === true
        interval: 60000
        repeat: true
        onTriggered: page.refreshDyn()
    }

    // The first monitor, so the page is usable the moment it is switched to
    // per-monitor: a grid whose clicks go nowhere until you notice there is a
    // selector above it is a grid that looks broken.
    function pickDefaultTarget() {
        if (Wallpaper.scope !== "per-monitor") {
            target = "";
            return;
        }
        if (target !== "" && Wallpaper.knownMonitors.indexOf(target) >= 0)
            return;
        const m = Wallpaper.knownMonitors;
        target = m.length ? m[0] : "";
    }

    Connections {
        target: Wallpaper
        function onScopeChanged() { page.pickDefaultTarget(); }
        function onKnownMonitorsChanged() { page.pickDefaultTarget(); }
    }

    // Every time the page opens, because the folder is a directory on disk that
    // anything may have written to since -- the cycle daemon, a download, a
    // screenshot. Nothing watches it, and a browser showing a folder as it was
    // an hour ago is a browser that cannot find the file you just saved.
    Component.onCompleted: {
        Wallpaper.rescan();
        pickDefaultTarget();
        refreshDyn();
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // No intro line here. The page heading carries it -- every page has a
        // subtitle now -- and this said the same sentence a second time, one
        // line below it.
        FormRow {
            label: "Folder"
            width: parent.width
            control: Field {
                value: Wallpaper.folder
                onCommitted: v => Wallpaper.setKey("folder", v)
            }
        }

        FormRow {
            label: "Change"
            width: parent.width
            control: Picker {
                // `static` is a first-class choice rather than "set the
                // interval to zero". Leaving a wallpaper alone is a normal
                // thing to want -- and with it expressed as an interval, the
                // way to say it was to type a number into a field that then
                // sat there claiming to mean something.
                values: ["random", "sequential", "static"]
                current: Wallpaper.order
                onPicked: v => Wallpaper.setKey("order", v)
            }
        }

        FormRow {
            label: "Every (min)"
            width: parent.width
            // A period is meaningless when nothing is cycling, and a control
            // that does nothing is worse than an absent one: it invites you to
            // set it and then ignores you.
            visible: Wallpaper.order !== "static"
            control: Field {
                value: String(Math.round(Wallpaper.interval / 60))
                onCommitted: v =>
                    Wallpaper.setKey("interval",
                                     String(Math.round(Number(v) * 60)))
            }
        }

        // ── one for all monitors, or one each ───────────────────────────────
        FormRow {
            label: "Applies to"
            width: parent.width
            control: Picker {
                values: [page.scopeAll, page.scopePer]
                current: Wallpaper.scope === "per-monitor" ? page.scopePer : page.scopeAll
                onPicked: v => Wallpaper.setKey(
                    "wallpaper-scope", v === page.scopePer ? "per-monitor" : "all")
            }
        }

        // ── what a dynamic wallpaper is doing ───────────────────────────────
        //
        // These files carry their own timetable, and nothing else on screen
        // says so: the tile looks like any other still. Worth stating, because
        // a wallpaper that changes on its own is otherwise a surprise -- and
        // because the timetables in the wild are not all sane, so "showing
        // frame 0 of 2, changes in 47 min" is what makes a badly authored one
        // diagnosable instead of just wrong.
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: page.dyn.dynamic === true
            wrapMode: Text.WordWrap
            text: {
                const d = page.dyn;
                if (!d.dynamic)
                    return "";
                let s = "Dynamic wallpaper: " + d.images + " images, showing "
                        + (d.index + 1) + ".";
                if (d.solar)
                    s += " Its schedule is by sun position, which needs a "
                       + "location this shell does not have, so it follows the "
                       + "file's light and dark pair instead.";
                if (d.changesIn !== undefined) {
                    const h = Math.floor(d.changesIn / 60);
                    const m = d.changesIn % 60;
                    s += " Next change in "
                       + (h > 0 ? h + " h " + m + " min" : m + " min") + ".";
                }
                return s;
            }
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        // Which monitor the tiles below apply to. Shown only when there is a
        // choice to make: with one wallpaper for everything there is no target
        // to pick, and the row would be a control that does nothing.
        Column {
            width: parent.width
            spacing: 4
            visible: Wallpaper.scope === "per-monitor"

            Text {
                font.weight: Cfg.fontWeight
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Picking below sets the wallpaper for the selected "
                      + "monitor. A monitor that is not plugged in keeps its "
                      + "setting and takes it up again when it comes back."
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
                font.hintingPreference: Font.PreferFullHinting
            }

            Flow {
                width: parent.width
                spacing: 6

                Repeater {
                    model: Wallpaper.knownMonitors

                    delegate: Rectangle {
                        id: mon
                        required property string modelData
                        readonly property bool here:
                            Wallpaper.monitorConnected(modelData)
                        readonly property bool chosen: page.target === modelData

                        height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.6))
                        width: label.implicitWidth
                               + Math.round(Cfg.fontPixelSize * 1.2)
                        radius: Cfg.themeRadius
                        color: mon.chosen ? Cfg.focusBg : Qt.rgba(1, 1, 1, 0.06)

                        Text {
                            font.weight: Cfg.fontWeight
                            id: label
                            anchors.centerIn: parent
                            // The name the compositor gives it: that is what
                            // the override is keyed by, and what everything
                            // else on this desktop calls the same screen.
                            text: mon.here ? mon.modelData
                                           : mon.modelData + " (away)"
                            color: mon.chosen ? Cfg.focusFg
                                 : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                                           Cfg.fg.a * (mon.here ? 1 : 0.5))
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        TapHandler { onTapped: page.target = mon.modelData }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }

            Text {
                font.weight: Cfg.fontWeight
                width: parent.width
                visible: Wallpaper.knownMonitors.length === 0
                wrapMode: Text.WordWrap
                text: "No monitors have reported their names yet."
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.hintingPreference: Font.PreferFullHinting
            }

            SmallButton {
                visible: page.target !== ""
                         && Wallpaper.wallpaperFor(page.target) !== ""
                label: "Clear " + page.target
                onClicked: Wallpaper.setMonitorWallpaper(page.target, "")
            }
        }

        // The browser. Thumbnails rather than a list of filenames, because
        // nobody recognises a wallpaper by its name.
        //
        // Laid out at its full height and NOT interactive: it is inside the
        // window's Flickable, and a scrollable grid nested in a scrollable pane
        // eats the wheel wherever the pointer happens to be, so the page under
        // the pointer stops scrolling without anything looking wrong. One
        // scrollable thing per pane; this one is a block of tiles that happens to
        // be tall.
        GridView {
            width: parent.width
            height: contentHeight
            interactive: false
            cellWidth: Math.floor(width / 4)
            cellHeight: Math.floor(cellWidth * 9 / 16)
            model: Wallpaper.available

            delegate: Item {
                required property string modelData
                width: GridView.view.cellWidth - 6
                height: GridView.view.cellHeight - 6

                Image {
                    anchors.fill: parent
                    source: "file://" + modelData
                    fillMode: Image.PreserveAspectCrop
                    // Thumbnails, not wallpapers: asking for the full 4K decode
                    // of every file in the folder to draw a 140px tile is how a
                    // browser like this eats a gigabyte.
                    sourceSize.width: 320
                    asynchronous: true
                    clip: true
                }

                // What is marked is what the CURRENT target is showing, not
                // what the default is: in per-monitor scope the question the
                // grid answers is "which one is on DP-1", and marking the
                // global wallpaper there would point at the wrong tile.
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: modelData === page.current ? 3 : 0
                    border.color: Cfg.focusBg
                }

                TapHandler {
                    onTapped: page.target === ""
                        ? Wallpaper.setKey("wallpaper", modelData)
                        : Wallpaper.setMonitorWallpaper(page.target, modelData)
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: Wallpaper.available.length === 0
            wrapMode: Text.WordWrap
            text: "No images in that folder."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.hintingPreference: Font.PreferFullHinting
        }
    }
}
