// MPD, as a client rather than a transport.
//
// The media pill drives whatever is playing through MPRIS, and for a browser
// tab or a video player that is the whole of what there is to do. MPD is a
// library with a daemon in front of it: the queue is editable, the database is
// browsable, playlists are saved and loaded. None of that reaches MPRIS --
// TrackList is the part of the spec almost nobody implements, mpd-mpris
// included -- so it is reached here, over MPD's own protocol.
//
// Four tabs rather than four panels, because they are four views of one thing
// and the transport line above them belongs to all four.

import QtQuick
import "."
// SmallButton lives with the settings pages; it is a button, not a setting.
import "settings"

Item {
    id: root

    signal closeRequested()

    // Wider than the other panels. Two columns of text per row -- a title and
    // a time, a track and a button -- and a title is the thing a person is
    // actually reading.
    implicitWidth: Math.max(460, Cfg.popoverWidth)
    implicitHeight: col.implicitHeight

    property string tab: "Queue"
    readonly property var tabs: ["Queue", "Browse", "Playlists", "Search"]

    // How tall a list may get before it scrolls instead of growing. The
    // popover caps its own height and silently loses whatever is past the cap.
    readonly property int listHeight: Cfg.em(16)

    // ── browse state ────────────────────────────────────────────────────────
    //
    // Artist, then album, then tracks: a path rather than a tree, because a
    // tree in a popover is a lot of chrome for two levels.
    property string browseArtist: ""
    property string browseAlbum: ""
    property var browseAlbums: []
    property var browseTracks: []

    function openArtist(name) {
        browseArtist = name;
        browseAlbum = "";
        browseTracks = [];
        browseAlbums = [];
        MpdService.albumsOf(name, list => root.browseAlbums = list);
    }
    function openAlbum(name) {
        browseAlbum = name;
        MpdService.tracksOf(root.browseArtist, name,
                            list => root.browseTracks = list);
    }
    function browseUp() {
        if (browseAlbum !== "") {
            browseAlbum = "";
            browseTracks = [];
        } else {
            browseArtist = "";
            browseAlbums = [];
        }
    }

    // ── search state ────────────────────────────────────────────────────────
    property var searchResults: []
    function runSearch(text) {
        MpdService.search(text, list => root.searchResults = list);
    }

    // ── playlist state ──────────────────────────────────────────────────────
    // Held as the whole entry rather than a name: a stored playlist is
    // addressed by its name and a library one by its path, and only the stored
    // kind can be deleted.
    property var openPlaylist: null
    property var openPlaylistTracks: []
    function showPlaylist(entry) {
        openPlaylist = entry;
        MpdService.playlistTracks(entry.path,
                                  list => root.openPlaylistTracks = list);
    }
    function closePlaylist() {
        openPlaylist = null;
        openPlaylistTracks = [];
    }

    // A song's display title. `Title` is a tag and tags are optional: a file
    // with none still has to say something, and its basename is what the
    // person who filed it chose.
    function titleOf(song) {
        if (!song)
            return "";
        if (song.Title)
            return song.Title;
        const f = String(song.file || "");
        return f.slice(f.lastIndexOf("/") + 1);
    }

    function artistOf(song) {
        return song ? (song.Artist || song.AlbumArtist || "") : "";
    }

    // m:ss from MPD's seconds. `duration` is the float one and `Time` the old
    // integer; both appear depending on the command.
    function clock(seconds) {
        const t = Math.max(0, Math.floor(Number(seconds) || 0));
        return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0");
    }
    function lengthOf(song) {
        return clock(song.duration !== undefined ? song.duration : song.Time);
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // ── what is playing ─────────────────────────────────────────────────
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: MpdService.connected
                ? (root.titleOf(MpdService.currentSong) || "Nothing loaded")
                : "MPD is not running"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.weight: Cfg.fontWeightEmphasis
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            width: parent.width
            elide: Text.ElideRight
            visible: text !== ""
            text: root.artistOf(MpdService.currentSong)
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.weight: Cfg.fontWeight
            font.hintingPreference: Font.PreferFullHinting
        }

        // ── transport ───────────────────────────────────────────────────────
        Row {
            spacing: 6

            Repeater {
                model: [
                    { glyph: "⏮", act: "previous" },
                    { glyph: MpdService.playing ? "⏸" : "▶", act: "toggle" },
                    { glyph: "⏭", act: "next" },
                    { glyph: "⏹", act: "stop" }
                ]

                delegate: Rectangle {
                    required property var modelData
                    width: Cfg.em(1.9)
                    height: Cfg.em(1.6)
                    radius: Cfg.themeRadius
                    color: hov.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                       : Qt.rgba(1, 1, 1, 0.07)

                    Text {
                        anchors.centerIn: parent
                        text: modelData.glyph
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSizeSmall
                        font.weight: Cfg.fontWeight
                    }
                    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            const a = modelData.act;
                            if (a === "previous") MpdService.previous();
                            else if (a === "toggle") MpdService.toggle();
                            else if (a === "next") MpdService.next();
                            else MpdService.stop();
                        }
                    }
                }
            }
        }

        // ── the tabs ────────────────────────────────────────────────────────
        Row {
            width: parent.width
            spacing: 4

            Repeater {
                model: root.tabs

                delegate: Rectangle {
                    required property string modelData
                    readonly property bool here: root.tab === modelData
                    width: (root.width - 12) / 4
                    height: Cfg.em(1.7)
                    radius: Cfg.themeRadius
                    color: here ? Cfg.focusBg
                         : (tabHov.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                           : Qt.rgba(1, 1, 1, 0.07))

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.here ? Cfg.legibleOn(Cfg.focusFg, Cfg.focusBg)
                                           : Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSizeSmall
                        font.weight: Cfg.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                    }
                    HoverHandler { id: tabHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.tab = modelData }
                }
            }
        }

        // ── Queue ───────────────────────────────────────────────────────────
        MpdList {
            width: parent.width
            visible: root.tab === "Queue"
            maxHeight: root.listHeight
            model: MpdService.queue
            emptyText: "The queue is empty."
            // Which row is playing, so the list says where you are rather than
            // leaving it to be worked out from the title above.
            currentIndex: MpdService.songPos
            labelOf: song => root.titleOf(song)
            subOf: song => root.artistOf(song)
            trailOf: song => root.lengthOf(song)
            onActivated: i => MpdService.playAt(i)
            actionGlyph: "×"
            onAction: i => MpdService.removeAt(i)
        }

        Row {
            width: parent.width
            spacing: 6
            visible: root.tab === "Queue" && MpdService.queue.length > 0

            SmallButton {
                label: "clear"
                onClicked: MpdService.clearQueue()
            }
            SmallButton {
                label: "save as playlist"
                onClicked: saveName.visible = !saveName.visible
            }
        }

        Field {
            id: saveName
            width: parent.width
            visible: false
            placeholder: "playlist name, Enter to save"
            onCommitted: name => {
                if (name.trim() !== "") {
                    MpdService.savePlaylist(name.trim());
                    visible = false;
                }
            }
        }

        // ── Browse ──────────────────────────────────────────────────────────
        Row {
            width: parent.width
            spacing: 6
            visible: root.tab === "Browse" && root.browseArtist !== ""

            SmallButton {
                label: "← back"
                onClicked: root.browseUp()
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Cfg.em(6)
                elide: Text.ElideRight
                text: root.browseAlbum !== ""
                    ? root.browseArtist + " › " + root.browseAlbum
                    : root.browseArtist
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
                font.weight: Cfg.fontWeight
            }
        }

        MpdList {
            width: parent.width
            visible: root.tab === "Browse" && root.browseArtist === ""
            maxHeight: root.listHeight
            model: MpdService.artists
            emptyText: "No artists in the database."
            labelOf: a => a
            onActivated: i => root.openArtist(MpdService.artists[i])
        }

        MpdList {
            width: parent.width
            visible: root.tab === "Browse" && root.browseArtist !== ""
                     && root.browseAlbum === ""
            maxHeight: root.listHeight
            model: root.browseAlbums
            emptyText: "No albums for this artist."
            labelOf: a => a
            onActivated: i => root.openAlbum(root.browseAlbums[i])
        }

        MpdList {
            width: parent.width
            visible: root.tab === "Browse" && root.browseAlbum !== ""
            maxHeight: root.listHeight
            model: root.browseTracks
            emptyText: "No tracks on this album."
            labelOf: song => root.titleOf(song)
            trailOf: song => root.lengthOf(song)
            // Enqueue on click, play on the button: adding is the common one,
            // and a click that replaced what is playing would be a surprise.
            onActivated: i => MpdService.addUri(root.browseTracks[i].file)
            actionGlyph: "▶"
            onAction: i => MpdService.addPlay(root.browseTracks[i].file)
        }

        // ── Playlists ───────────────────────────────────────────────────────
        Row {
            width: parent.width
            spacing: 6
            visible: root.tab === "Playlists" && root.openPlaylist !== null

            SmallButton {
                label: "← back"
                onClicked: root.closePlaylist()
            }
            SmallButton {
                label: "load"
                onClicked: MpdService.loadPlaylist(root.openPlaylist.path)
            }
            // Only for a stored one. `rm` reaches into playlist_directory and
            // nowhere else, so offering it for a file that lives beside its
            // album would be a button that fails -- or worse, one a reader
            // expects to delete their .m3u.
            SmallButton {
                label: "delete"
                visible: root.openPlaylist && root.openPlaylist.stored
                onClicked: {
                    MpdService.removePlaylist(root.openPlaylist.path);
                    root.closePlaylist();
                }
            }
        }

        MpdList {
            width: parent.width
            visible: root.tab === "Playlists" && root.openPlaylist === null
            maxHeight: root.listHeight
            model: MpdService.allPlaylists
            emptyText: "No playlists saved, and none in the library."
            labelOf: p => p.name
            // Where a library playlist lives, so two albums' "Disc 1.m3u" are
            // not two identical rows. A stored one has no second line: its
            // name is unique by construction.
            subOf: p => p.stored ? "" : p.where
            onActivated: i => root.showPlaylist(MpdService.allPlaylists[i])
        }

        MpdList {
            width: parent.width
            visible: root.tab === "Playlists" && root.openPlaylist !== null
            maxHeight: root.listHeight
            model: root.openPlaylistTracks
            emptyText: "That playlist is empty."
            labelOf: song => root.titleOf(song)
            subOf: song => root.artistOf(song)
            trailOf: song => root.lengthOf(song)
            onActivated: i => MpdService.addUri(root.openPlaylistTracks[i].file)
        }

        // ── Search ──────────────────────────────────────────────────────────
        Field {
            width: parent.width
            visible: root.tab === "Search"
            placeholder: "artist, album or title"
            onCommitted: text => root.runSearch(text)
        }

        MpdList {
            width: parent.width
            visible: root.tab === "Search"
            maxHeight: root.listHeight
            model: root.searchResults
            emptyText: "Nothing found."
            labelOf: song => root.titleOf(song)
            subOf: song => root.artistOf(song)
            trailOf: song => root.lengthOf(song)
            onActivated: i => MpdService.addUri(root.searchResults[i].file)
            actionGlyph: "▶"
            onAction: i => MpdService.addPlay(root.searchResults[i].file)
        }

        // ── modes, volume, outputs ──────────────────────────────────────────
        //
        // Below the tabs rather than inside one, because they are the state of
        // the daemon and not of the view.
        Row {
            width: parent.width
            spacing: 6

            Repeater {
                model: [
                    { name: "repeat", on: MpdService.repeatOn },
                    { name: "random", on: MpdService.randomOn },
                    { name: "single", on: MpdService.singleOn },
                    { name: "consume", on: MpdService.consumeOn }
                ]

                delegate: Rectangle {
                    required property var modelData
                    width: (root.width - 18) / 4
                    height: Cfg.em(1.6)
                    radius: Cfg.themeRadius
                    color: modelData.on ? Cfg.focusBg
                         : (mHov.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                         : Qt.rgba(1, 1, 1, 0.07))

                    Text {
                        anchors.centerIn: parent
                        text: modelData.name
                        color: modelData.on
                            ? Cfg.legibleOn(Cfg.focusFg, Cfg.focusBg) : Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSizeSmall
                        font.weight: Cfg.fontWeight
                    }
                    HoverHandler { id: mHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: MpdService.setMode(modelData.name, !modelData.on)
                    }
                }
            }
        }

        // MPD reports -1 when it has no mixer at all, which is not the same as
        // silence and must not draw as a slider sitting at zero.
        Row {
            width: parent.width
            spacing: 8
            visible: MpdService.volume >= 0

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "vol"
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
                font.weight: Cfg.fontWeight
            }

            Rectangle {
                id: track
                anchors.verticalCenter: parent.verticalCenter
                width: root.width - Cfg.em(4)
                height: Cfg.em(0.5)
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.12)

                Rectangle {
                    width: parent.width * Math.max(0, MpdService.volume) / 100
                    height: parent.height
                    radius: parent.radius
                    color: Cfg.focusBg
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: eventPoint =>
                        MpdService.setVolume(
                            eventPoint.position.x / track.width * 100)
                }
            }
        }

        // One row per output, because a machine with an ALSA device and an
        // httpd stream is the ordinary MPD setup and switching between them
        // otherwise means a terminal.
        Repeater {
            model: MpdService.outputs

            delegate: Row {
                required property var modelData
                width: root.width
                spacing: 8

                Rectangle {
                    width: Cfg.em(1)
                    height: width
                    radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: modelData.outputenabled === "1"
                        ? Cfg.focusBg : Qt.rgba(1, 1, 1, 0.12)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.width - Cfg.em(2)
                    elide: Text.ElideRight
                    text: modelData.outputname || ""
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSizeSmall
                    font.weight: Cfg.fontWeight
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: MpdService.setOutput(
                        modelData.outputid,
                        modelData.outputenabled !== "1")
                }
            }
        }
    }
}
