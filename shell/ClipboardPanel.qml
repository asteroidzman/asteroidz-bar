// The clipboard history, in a panel under the pill.
//
// The list is the whole feature, so it gets the whole panel: a search field
// that is always focused, rows you can walk with the arrow keys, and Enter to
// put one back on the clipboard. Everything else -- delete, clear -- is
// reachable but out of the way, because the common action by an enormous
// margin is "the thing I copied three copies ago".
//
// The history itself lives in C++ (Asteroidz.Bar's Clipboard singleton, which
// speaks ext-data-control-v1 on the shell's own Wayland connection). Nothing
// here shells out, polls, or knows what a mime type is beyond "text or image".

import Quickshell
import QtQuick
import Asteroidz.Bar
import "."

Item {
    id: root

    // Raised when the panel has done the thing it was opened for. Wired to the
    // bar's closeMenu() by whoever opens it -- this file cannot reach the bar
    // itself, because it is loaded from a Component and only that Component's
    // defining scope has `bar` in it.
    signal closeRequested()

    implicitWidth: Cfg.clipboardWidth
    implicitHeight: col.implicitHeight

    // The query, and the filtered view of it.
    //
    // Filtering here rather than in C++ on purpose: the list is capped at a
    // few hundred entries, a substring match over that is nothing, and keeping
    // the backend free of "what is the user typing" keeps it a clipboard
    // rather than a search engine.
    property string query: ""
    readonly property var shown: {
        const all = Clipboard.entries;
        const q = query.trim().toLowerCase();
        if (q === "")
            return all;
        const out = [];
        for (const e of all) {
            // Images match on their dimensions string, which is all the text
            // they have -- so "128" finds a 128×128 screenshot.
            if (String(e.preview).toLowerCase().includes(q))
                out.push(e);
        }
        return out;
    }

    // Which row Enter would act on. Clamped rather than reset when the list
    // changes under it: typing narrows the list, and jumping the selection
    // back to the top on every keystroke is what makes a search box feel like
    // it is fighting you.
    property int selected: 0
    onShownChanged: {
        if (selected >= shown.length)
            selected = Math.max(0, shown.length - 1);
    }

    function activate(index) {
        const e = shown[index];
        if (!e)
            return;
        Clipboard.copy(e.id);
        // Closing is the point: you asked for a thing to be on the clipboard,
        // it is, and the next thing you do is paste it somewhere else.
        root.closeRequested();
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // ── the header ──────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    if (!Clipboard.available)
                        return "Clipboard";
                    const n = Clipboard.entries.length;
                    return n === 0 ? "Clipboard" : "Clipboard (" + n + ")";
                }
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.weight: Font.DemiBold
                font.hintingPreference: Font.PreferFullHinting
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                // Pausing, where it is discoverable. It stops RECORDING and
                // nothing else -- what is already here stays, and the
                // clipboard itself keeps working -- which is the distinction
                // that matters when you are about to paste a password.
                Rectangle {
                    width: pauseLabel.implicitWidth + 12
                    height: Math.max(18, Math.round(Cfg.fontPixelSize * 1.15))
                    radius: Cfg.themeRadius
                    color: Clipboard.paused ? Cfg.focusBg
                         : pauseHover.hovered ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.12)
                                              : "transparent"

                    Text {
                        id: pauseLabel
                        anchors.centerIn: parent
                        text: Clipboard.paused ? "paused" : "recording"
                        color: Clipboard.paused ? Cfg.focusFg : Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                    HoverHandler { id: pauseHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Clipboard.paused = !Clipboard.paused }
                }

                Rectangle {
                    visible: Clipboard.entries.length > 0
                    width: clearLabel.implicitWidth + 12
                    height: Math.max(18, Math.round(Cfg.fontPixelSize * 1.15))
                    radius: Cfg.themeRadius
                    color: clearHover.hovered
                           ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.12)
                           : "transparent"

                    Text {
                        id: clearLabel
                        anchors.centerIn: parent
                        text: "clear"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                    HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                    // Clearing empties the very list the panel exists to show,
                    // so staying open leaves you looking at "Nothing copied
                    // yet."
                    TapHandler {
                        onTapped: {
                            Clipboard.clear();
                            root.closeRequested();
                        }
                    }
                }
            }
        }

        // ── the search box ──────────────────────────────────────────────────
        //
        // Always focused, and it owns the arrow keys as well as the text: a
        // clipboard panel is opened to find something, so the keyboard should
        // be in the search box without being asked, and moving the selection
        // should not require leaving it.
        Rectangle {
            width: parent.width
            visible: Clipboard.available && Clipboard.entries.length > 0
            height: Math.max(24, Math.round(Cfg.fontPixelSize * 1.5))
            radius: Cfg.themeRadius
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.08)

            TextInput {
                id: search
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
                font.hintingPreference: Font.PreferFullHinting
                selectByMouse: true
                focus: true

                onTextChanged: root.query = text

                Keys.onDownPressed: root.selected =
                    Math.min(root.selected + 1, root.shown.length - 1)
                Keys.onUpPressed: root.selected = Math.max(root.selected - 1, 0)
                Keys.onReturnPressed: root.activate(root.selected)
                Keys.onEnterPressed: root.activate(root.selected)
                Keys.onEscapePressed: root.closeRequested()
                // Delete the highlighted row without leaving the keyboard.
                // Shift, because plain Delete belongs to the text field.
                Keys.onDeletePressed: event => {
                    if (event.modifiers & Qt.ShiftModifier) {
                        const e = root.shown[root.selected];
                        if (e)
                            Clipboard.remove(e.id);
                        event.accepted = true;
                    } else {
                        event.accepted = false;
                    }
                }

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: search.text === ""
                    text: "Search"
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.4)
                    font: search.font
                }
            }
        }

        // ── nothing to show ─────────────────────────────────────────────────
        Text {
            width: parent.width
            visible: !Clipboard.available || root.shown.length === 0
            text: {
                if (!Clipboard.available)
                    return Clipboard.error !== ""
                        ? Clipboard.error
                        : "The compositor does not offer a clipboard to read.";
                if (Clipboard.entries.length === 0)
                    return "Nothing copied yet.";
                return "Nothing matches “" + root.query + "”.";
            }
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            wrapMode: Text.WordWrap
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        // ── the list ────────────────────────────────────────────────────────
        //
        // Scrolls rather than growing: the popover caps its own height and
        // silently loses anything past the cap, so a long list has to be
        // scrollable inside a bounded box rather than a tall column.
        Flickable {
            id: flick
            width: parent.width
            visible: root.shown.length > 0
            height: Math.min(rows.implicitHeight, Cfg.clipboardHeight)
            contentWidth: width
            contentHeight: rows.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // Keep the highlighted row on screen when the arrows walk past the
            // edge of the visible box.
            function reveal(y, h) {
                if (y < contentY)
                    contentY = y;
                else if (y + h > contentY + height)
                    contentY = y + h - height;
            }

            Column {
                id: rows
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.shown

                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index

                        width: rows.width
                        height: Math.max(
                            Math.round(Cfg.fontPixelSize * 1.9),
                            thumb.visible ? thumb.height + 8 : 0
                        )
                        radius: Cfg.themeRadius
                        color: index === root.selected ? Cfg.focusBg
                             : rowHover.hovered ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.10)
                                                : "transparent"

                        readonly property color ink:
                            index === root.selected ? Cfg.focusFg : Cfg.fg

                        onYChanged: if (index === root.selected) flick.reveal(y, height)
                        Connections {
                            target: root
                            function onSelectedChanged() {
                                if (row.index === root.selected)
                                    flick.reveal(row.y, row.height);
                            }
                        }

                        Image {
                            id: thumb
                            visible: row.modelData.kind === "image"
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            // Asked for once per entry and cached in C++; a
                            // binding straight to a function call is safe here
                            // because `id` never changes for a given row.
                            source: row.modelData.kind === "image"
                                    ? Clipboard.thumbnail(row.modelData.id) : ""
                            fillMode: Image.PreserveAspectFit
                            height: Math.round(Cfg.fontPixelSize * 1.9)
                            width: height
                            smooth: true
                            asynchronous: true
                        }

                        Text {
                            anchors.left: thumb.visible ? thumb.right : parent.left
                            anchors.leftMargin: 8
                            anchors.right: kindLabel.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.preview
                            color: row.ink
                            elide: Text.ElideRight
                            font.family: Cfg.fontFamily
                            font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        // The size, quietly. It is what tells a 12-byte token
                        // apart from the 400KB of HTML that looked identical
                        // once elided.
                        Text {
                            id: kindLabel
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.size < 1024
                                  ? row.modelData.size + " B"
                                  : Math.round(row.modelData.size / 1024) + " K"
                            color: Qt.rgba(row.ink.r, row.ink.g, row.ink.b, 0.45)
                            font.family: Cfg.fontFamily
                            font.pointSize: Math.max(6, Cfg.fontSize * 0.7)
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onTapped: eventPoint => {
                                // Middle-click deletes, which is the one
                                // destructive action that should not need a
                                // menu. Left activates.
                                if (eventPoint.event.button === Qt.MiddleButton)
                                    Clipboard.remove(row.modelData.id);
                                else
                                    root.activate(row.index);
                            }
                        }
                    }
                }
            }
        }
    }
}
