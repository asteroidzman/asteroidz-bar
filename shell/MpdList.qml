// A bounded, scrolling list of rows, for the MPD panel's four tabs.
//
// Extracted because it is used seven times -- the queue, artists, albums,
// album tracks, playlists, playlist tracks and search results are all the same
// thing: a list too long for a popover, where a row has a label, sometimes a
// second line, sometimes a time at the right, and sometimes one button.
//
// Scrolls rather than grows, for the reason the clipboard panel's list does:
// the popover caps its own height and silently loses whatever is past the cap,
// so a long list has to be a scrollable box rather than a tall column.

import QtQuick
import "."

Item {
    id: root

    // Rows to draw. Plain JS arrays, because that is what MpdService parses
    // MPD's responses into.
    property var model: []
    property int maxHeight: Cfg.em(16)
    property string emptyText: ""

    // The row that is playing, marked rather than selected -- nothing here has
    // a selection. -1 for a list where the idea does not apply.
    property int currentIndex: -1

    // How to read a row. Taken as functions rather than property names because
    // the rows are not one shape: an artist is a bare string and a song is a
    // record, and a list that had to know which would need a flag per tab.
    property var labelOf: item => String(item)
    property var subOf: null
    property var trailOf: null

    // The optional button at the right end of a row.
    property string actionGlyph: ""

    signal activated(int index)
    signal action(int index)

    implicitHeight: model.length === 0 ? empty.implicitHeight
                                       : Math.min(rows.implicitHeight, maxHeight)

    Text {
        id: empty
        width: parent.width
        visible: root.model.length === 0 && root.emptyText !== ""
        text: root.emptyText
        wrapMode: Text.WordWrap
        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSizeSmall
        font.weight: Cfg.fontWeight
        font.hintingPreference: Font.PreferFullHinting
    }

    Flickable {
        anchors.fill: parent
        visible: root.model.length > 0
        contentWidth: width
        contentHeight: rows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: rows
            width: parent.width
            spacing: 2

            Repeater {
                model: root.model

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index

                    width: rows.width
                    height: line.implicitHeight + 8
                    radius: Cfg.themeRadius
                    color: root.currentIndex === index ? Cfg.focusBg
                         : (rowHov.hovered ? Qt.rgba(1, 1, 1, 0.10)
                                           : "transparent")

                    readonly property color ink: root.currentIndex === index
                        ? Cfg.legibleOn(Cfg.focusFg, Cfg.focusBg) : Cfg.fg

                    Column {
                        id: line
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.right: trail.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.labelOf(row.modelData)
                            color: row.ink
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.weight: Cfg.fontWeight
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            visible: root.subOf !== null && text !== ""
                            text: root.subOf ? root.subOf(row.modelData) : ""
                            color: Qt.rgba(row.ink.r, row.ink.g, row.ink.b,
                                           row.ink.a * 0.6)
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.weight: Cfg.fontWeight
                            font.hintingPreference: Font.PreferFullHinting
                        }
                    }

                    // The time, and the button, both right-aligned. An Item
                    // rather than nothing when neither is wanted, because the
                    // label anchors to its left edge and an absent anchor
                    // target collapses the row.
                    Row {
                        id: trail
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.trailOf !== null
                            text: root.trailOf ? root.trailOf(row.modelData) : ""
                            color: Qt.rgba(row.ink.r, row.ink.g, row.ink.b,
                                           row.ink.a * 0.6)
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.weight: Cfg.fontWeight
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.actionGlyph !== ""
                            width: Cfg.em(1.3)
                            height: width
                            radius: Cfg.themeRadius
                            color: actHov.hovered ? Qt.rgba(1, 1, 1, 0.18)
                                                  : Qt.rgba(1, 1, 1, 0.08)

                            Text {
                                anchors.centerIn: parent
                                text: root.actionGlyph
                                color: row.ink
                                font.family: Cfg.fontFamily
                                font.pointSize: Cfg.fontSizeSmall
                                font.weight: Cfg.fontWeight
                            }
                            HoverHandler {
                                id: actHov
                                cursorShape: Qt.PointingHandCursor
                            }
                            // Its own handler, and the row's asks where the tap
                            // landed rather than fighting it for the grab --
                            // the same arrangement the wallpaper tiles' tick
                            // uses, and for the same reason: both would fire.
                            TapHandler { onTapped: root.action(row.index) }
                        }
                    }

                    HoverHandler { id: rowHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: eventPoint => {
                            const x = eventPoint.position.x;
                            if (root.actionGlyph !== "" && x >= trail.x)
                                return;
                            root.activated(row.index);
                        }
                    }
                }
            }
        }
    }
}
