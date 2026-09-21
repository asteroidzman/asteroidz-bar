pragma Singleton

// MPD, spoken to directly.
//
// The media module follows MPRIS, which is the right abstraction for "a thing
// that plays" and the only one every other player answers to. MPD does not
// answer to it at all -- mpd-mpris exists to bridge that gap, and while the
// bridge is running the bar already shows the track and drives the transport.
//
// What the bridge cannot carry is everything that makes MPD a LIBRARY rather
// than a player: the queue as an editable list, the database to browse, the
// stored playlists, the search. MPRIS has TrackList for some of that and
// almost nobody implements it, mpd-mpris included. So this speaks MPD's own
// protocol, and the module keeps using MPRIS for what MPRIS is good at.
//
// The protocol is line-based and pleasant: a command per line, a response of
// `key: value` lines, terminated by `OK` or by `ACK [code@n] {cmd} message`.
// Binary responses (album art) are the one exception and are not asked for
// here.

import Quickshell
import Quickshell.Io
import QtQuick
import "."

Singleton {
    id: root

    // Where MPD listens.
    //
    // The socket rather than the TCP port, because Quickshell's Socket is a
    // QLocalSocket and speaks nothing else -- and because a socket under
    // XDG_RUNTIME_DIR is already scoped to this user, where port 6600 is
    // reachable by anything on the machine. Arch's mpd.service creates it
    // without being asked; a config naming a different one overrides.
    readonly property string socketPath: Cfg.mpdSocket

    // ── connection ──────────────────────────────────────────────────────────
    //
    // TWO of them, and that is the protocol's doing rather than a choice.
    // `idle` is how MPD reports change, and it works by not answering until
    // something changes -- so the connection that waits on it cannot also
    // carry commands. One socket listens, one asks.
    //
    // Rebuilt through Loaders because a Socket that fails to connect stays
    // failed: the object is terminal, so retrying means a NEW one rather than
    // setting `connected` again. MPD restarting is an ordinary event -- it is
    // a user service like any other -- and a shell that needed restarting to
    // notice would be worse than one that never connected at all.
    property int generation: 0

    // The live command socket, assigned by the object itself rather than read
    // off the Loader.
    //
    // `cmdLoader.item` is not set yet while the Socket is emitting its own
    // connectionStateChanged -- the Loader assigns it once construction
    // finishes -- so a pump() that went through the Loader found null at
    // exactly the moment there was something to send, dropped the queue on the
    // floor, and had nothing to retrigger it. The bar showed MPD as connected
    // and every field empty.
    property var cmdSock: null

    readonly property bool connected:
        cmdSock !== null && cmdSock.connected

    function reconnect() {
        root.generation++;
    }

    Timer {
        id: retry
        interval: 4000
        repeat: false
        onTriggered: root.reconnect()
    }

    Loader {
        id: cmdLoader
        active: true
        sourceComponent: cmdComponent
        property int gen: root.generation
        onGenChanged: {
            active = false;
            active = true;
        }
    }

    Loader {
        id: idleLoader
        active: true
        sourceComponent: idleComponent
        property int gen: root.generation
        onGenChanged: {
            active = false;
            active = true;
        }
    }

    // ── the command connection ──────────────────────────────────────────────
    //
    // One command in flight at a time. MPD answers in order and nothing here
    // needs pipelining; a queue keeps the caller's handler attached to the
    // right response without having to match them up afterwards.
    property var pending: []
    property var inflight: null
    property var lines: []

    function send(command, onDone) {
        root.pending.push({ cmd: command, done: onDone || null });
        root.pump();
    }

    function pump() {
        if (root.inflight !== null || root.pending.length === 0)
            return;
        if (!root.cmdSock || !root.cmdSock.connected)
            return;
        root.inflight = root.pending.shift();
        root.lines = [];
        root.cmdSock.write(root.inflight.cmd + "\n");
    }

    function finish(ok, message) {
        const job = root.inflight;
        root.inflight = null;
        const collected = root.lines;
        root.lines = [];
        if (job && job.done)
            job.done(ok, collected, message || "");
        root.pump();
    }

    Component {
        id: cmdComponent
        Socket {
            id: cmdSocket
            path: root.socketPath
            connected: true
            Component.onCompleted: root.cmdSock = cmdSocket
            onConnectionStateChanged: {
                if (connected) {
                    // Assigned here as well as on completion: which of the two
                    // happens first depends on whether the socket connects
                    // synchronously, and the queue must not depend on the
                    // answer.
                    root.cmdSock = cmdSocket;
                    root.refreshAll();
                    root.pump();
                } else {
                    // Whatever was in flight will never be answered.
                    root.inflight = null;
                    root.lines = [];
                    retry.restart();
                }
            }
            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    const l = String(line);
                    // The greeting, once per connection. Not a response to
                    // anything, so it must not complete a command that has
                    // not been sent yet.
                    if (l.startsWith("OK MPD "))
                        return;
                    if (l === "OK") {
                        root.finish(true, "");
                        return;
                    }
                    if (l.startsWith("ACK ")) {
                        root.finish(false, l);
                        return;
                    }
                    root.lines.push(l);
                }
            }
        }
    }

    // ── the idle connection ─────────────────────────────────────────────────
    //
    // Named subsystems rather than a bare `idle`, so MPD does not wake this up
    // for things nothing here draws -- a sticker write or a partition change
    // would otherwise cost a full refresh.
    readonly property string idleSubsystems:
        "idle player mixer options playlist database stored_playlist output"

    Component {
        id: idleComponent
        Socket {
            id: idleSock
            path: root.socketPath
            connected: true
            onConnectionStateChanged: {
                if (connected)
                    write(root.idleSubsystems + "\n");
                else
                    retry.restart();
            }
            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    const l = String(line);
                    if (l.startsWith("OK MPD "))
                        return;
                    if (l.startsWith("changed: ")) {
                        root.changedSubsystems.push(l.slice(9));
                        return;
                    }
                    if (l === "OK" || l.startsWith("ACK ")) {
                        // Ask again FIRST: between the answer and the next
                        // `idle` this connection is deaf, and a refresh that
                        // ran in between would widen that window by however
                        // long MPD took to answer it.
                        const what = root.changedSubsystems;
                        root.changedSubsystems = [];
                        idleSock.write(root.idleSubsystems + "\n");
                        root.onChanged(what);
                    }
                }
            }
        }
    }

    property var changedSubsystems: []

    // What each subsystem invalidates. Narrow on purpose: a volume change
    // should not re-read a thousand-song queue.
    function onChanged(subsystems) {
        let wantStatus = false;
        let wantQueue = false;
        let wantPlaylists = false;
        let wantDatabase = false;
        let wantOutputs = false;
        for (const s of subsystems) {
            if (s === "player" || s === "mixer" || s === "options")
                wantStatus = true;
            if (s === "playlist") {
                wantStatus = true;
                wantQueue = true;
            }
            if (s === "stored_playlist")
                wantPlaylists = true;
            // A playlist file living in the library changes with the
            // DATABASE, not with stored_playlist -- MPD does not consider it
            // one of those.
            if (s === "database")
                wantDatabase = true;
            if (s === "output")
                wantOutputs = true;
        }
        if (wantStatus) refreshStatus();
        if (wantQueue) refreshQueue();
        if (wantPlaylists) refreshPlaylists();
        if (wantOutputs) refreshOutputs();
        if (wantDatabase) {
            refreshArtists();
            refreshLibraryPlaylists();
        }
    }

    function refreshAll() {
        refreshStatus();
        refreshQueue();
        refreshPlaylists();
        refreshOutputs();
        refreshArtists();
    }

    // ── parsing ─────────────────────────────────────────────────────────────
    //
    // A response is `key: value` lines. Records are split on a key that starts
    // a new one -- `file` for songs, `playlist` for stored playlists -- because
    // MPD does not delimit them any other way.
    function pairs(list) {
        const out = [];
        for (const l of list) {
            const i = l.indexOf(": ");
            if (i > 0)
                out.push([l.slice(0, i), l.slice(i + 2)]);
        }
        return out;
    }

    function records(list, startKey) {
        const out = [];
        let cur = null;
        for (const [k, v] of pairs(list)) {
            if (k === startKey) {
                if (cur)
                    out.push(cur);
                cur = ({});
            }
            if (cur === null)
                continue;
            // First wins: a song can carry several Artist lines and the
            // display wants one, not the last one it happened to see.
            if (cur[k] === undefined)
                cur[k] = v;
        }
        if (cur)
            out.push(cur);
        return out;
    }

    function flat(list) {
        const out = ({});
        for (const [k, v] of pairs(list))
            if (out[k] === undefined)
                out[k] = v;
        return out;
    }

    // ── state ───────────────────────────────────────────────────────────────
    property var status: ({})
    property var currentSong: ({})
    property var queue: []
    property var playlists: []
    property var outputs: []
    property var artists: []

    readonly property bool playing: status.state === "play"
    readonly property bool paused: status.state === "pause"
    readonly property int volume: parseInt(status.volume) >= 0
        ? parseInt(status.volume) : -1
    readonly property bool repeatOn: status.repeat === "1"
    readonly property bool randomOn: status.random === "1"
    readonly property bool singleOn: status.single === "1"
    readonly property bool consumeOn: status.consume === "1"
    // Which queue position is playing, or -1. Used to mark the row.
    readonly property int songPos:
        status.song !== undefined ? parseInt(status.song) : -1

    function refreshStatus() {
        send("status", (ok, l) => {
            if (ok) root.status = root.flat(l);
        });
        send("currentsong", (ok, l) => {
            if (ok) root.currentSong = root.flat(l);
        });
    }

    function refreshQueue() {
        send("playlistinfo", (ok, l) => {
            if (ok) root.queue = root.records(l, "file");
        });
    }

    function refreshPlaylists() {
        send("listplaylists", (ok, l) => {
            if (ok) root.playlists = root.records(l, "playlist");
        });
        refreshLibraryPlaylists();
    }

    // ── playlist FILES, in the library ──────────────────────────────────────
    //
    // `listplaylists` reports only what is in MPD's playlist_directory, and a
    // ripped album's .m3u does not live there -- it sits beside the tracks it
    // names, inside music_directory, where MPD indexes it but the stored-
    // playlist commands never mention it. A library can therefore be full of
    // playlists while the Playlists tab says "No saved playlists", which is
    // what it said here with four of them on disk.
    //
    // `listall` walks the whole database and reports them as `playlist:` lines
    // -- one round trip for every one of them, at the cost of also listing
    // every file. That is the trade: a recursive lsinfo would transfer far
    // less and ask far more often, and this runs on connect and on a database
    // change rather than on a keystroke.
    property var libraryPlaylists: []

    function refreshLibraryPlaylists() {
        send("listall", (ok, l) => {
            if (!ok)
                return;
            const out = [];
            for (const [k, v] of root.pairs(l))
                if (k === "playlist" && v !== "")
                    out.push(v);
            out.sort();
            root.libraryPlaylists = out;
        });
    }

    // Both kinds, in one list for the panel.
    //
    // They differ in exactly one way that matters to a reader: a stored
    // playlist can be deleted, a file in the library is not MPD's to remove --
    // `rm` only ever touches playlist_directory. Everything else, loading and
    // listing included, takes the same path either way.
    readonly property var allPlaylists: {
        const out = [];
        for (const p of root.playlists)
            out.push({ name: p.playlist, path: p.playlist, stored: true });
        for (const f of root.libraryPlaylists) {
            const cut = String(f).lastIndexOf("/");
            out.push({
                name: String(f).slice(cut + 1).replace(/\.[^.]+$/, ""),
                where: cut > 0 ? String(f).slice(0, cut) : "",
                path: f,
                stored: false
            });
        }
        return out;
    }

    function refreshOutputs() {
        send("outputs", (ok, l) => {
            if (ok) root.outputs = root.records(l, "outputid");
        });
    }

    function refreshArtists() {
        send("list artist", (ok, l) => {
            if (!ok)
                return;
            const out = [];
            for (const [k, v] of root.pairs(l))
                if (k === "Artist" && v !== "")
                    out.push(v);
            out.sort((a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : 1);
            root.artists = out;
        });
    }

    // ── quoting ─────────────────────────────────────────────────────────────
    //
    // MPD takes a quoted argument with backslash escapes, and every one of
    // these strings is a filename or a tag somebody else chose: an album
    // called `12"` is not a syntax error waiting to happen unless this makes
    // it one.
    function q(s) {
        return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    }

    // ── transport and modes ─────────────────────────────────────────────────
    function play() { send("play"); }
    function pause(on) { send("pause " + (on ? "1" : "0")); }
    function toggle() { send(root.playing ? "pause 1" : "play"); }
    function next() { send("next"); }
    function previous() { send("previous"); }
    function stop() { send("stop"); }
    function seek(seconds) { send("seekcur " + Math.round(seconds)); }
    function setVolume(v) { send("setvol " + Math.max(0, Math.min(100, Math.round(v)))); }

    function setMode(name, on) { send(name + " " + (on ? "1" : "0")); }

    // ── the queue ───────────────────────────────────────────────────────────
    function playAt(pos) { send("play " + pos); }
    function removeAt(pos) { send("delete " + pos); }
    function moveTo(from, to) { send("move " + from + " " + to); }
    function clearQueue() { send("clear"); }
    function addUri(uri) { send("add " + q(uri)); }
    // Add and play it, which is what a double click on a search result means.
    function addPlay(uri) {
        send("addid " + q(uri), (ok, l) => {
            if (!ok)
                return;
            const id = root.flat(l)["Id"];
            if (id !== undefined)
                send("playid " + id);
        });
    }

    // ── the database ────────────────────────────────────────────────────────
    function albumsOf(artist, done) {
        send("list album artist " + q(artist), (ok, l) => {
            if (!ok) { done([]); return; }
            const out = [];
            for (const [k, v] of root.pairs(l))
                if (k === "Album" && v !== "")
                    out.push(v);
            done(out);
        });
    }

    function tracksOf(artist, album, done) {
        send("find artist " + q(artist) + " album " + q(album), (ok, l) => {
            done(ok ? root.records(l, "file") : []);
        });
    }

    // `search` rather than `find`: case-insensitive and substring, which is
    // what somebody typing three letters into a box means.
    function search(text, done) {
        if (String(text).trim() === "") { done([]); return; }
        send("search any " + q(text), (ok, l) => {
            done(ok ? root.records(l, "file") : []);
        });
    }

    // ── stored playlists ────────────────────────────────────────────────────
    function playlistTracks(name, done) {
        send("listplaylistinfo " + q(name), (ok, l) => {
            done(ok ? root.records(l, "file") : []);
        });
    }
    function loadPlaylist(name) { send("load " + q(name)); }
    function savePlaylist(name) { send("save " + q(name)); }
    function removePlaylist(name) { send("rm " + q(name)); }

    // ── outputs ─────────────────────────────────────────────────────────────
    function setOutput(id, on) {
        send((on ? "enableoutput " : "disableoutput ") + id);
    }
}
