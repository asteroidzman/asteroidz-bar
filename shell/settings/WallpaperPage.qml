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

    // Every time the page opens, because the folder is a directory on disk that
    // anything may have written to since -- the cycle daemon, a download, a
    // screenshot. Nothing watches it, and a browser showing a folder as it was
    // an hour ago is a browser that cannot find the file you just saved.
    Component.onCompleted: Wallpaper.rescan()

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
            label: "Cycle (min)"
            width: parent.width
            control: Field {
                placeholder: "0 = off"
                value: String(Math.round(Wallpaper.interval / 60))
                onCommitted: v =>
                    Wallpaper.setKey("interval",
                                     String(Math.round(Number(v) * 60)))
            }
        }

        FormRow {
            label: "Order"
            width: parent.width
            control: Picker {
                values: ["random", "sequential"]
                current: Wallpaper.order
                onPicked: v => Wallpaper.setKey("order", v)
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

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: modelData === Wallpaper.path ? 3 : 0
                    border.color: Cfg.focusBg
                }

                TapHandler {
                    onTapped: Wallpaper.setKey("wallpaper", modelData)
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }

        Text {
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
