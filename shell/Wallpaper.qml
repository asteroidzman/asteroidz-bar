pragma Singleton

// The wallpaper, drawn by the shell.
//
// Not launched by it -- drawn by it. This process puts the image on the
// screen itself, over the same Wayland connection it draws the bar with:
// starting asteroidz-bar puts up the bar AND the wallpaper, stopping it takes
// both down, and there is no second binary in between to launch, supervise or
// keep in step.
//
// The part QML cannot do is done in C++ (plugin/wallpaper.cpp), which links
// asteroidzbg as a library. asteroidzbg tags its surface through
// wp_color_manager_v1 with BT.2020 primaries and the PQ transfer function and
// decodes 10-bit AVIF and JPEG XL to match; Qt exposes no way to reach either,
// so an HDR wallpaper drawn through QML's Image would be silently flattened to
// SDR read as plain gamma -- precisely the bug asteroidzbg was forked from
// swaybg to fix. What moved in-process is the process boundary. The pixels
// take the same path they always did.
//
// What lives HERE is everything that is genuinely configuration: which file,
// which mode, which folder to browse, and the file that the rest of the
// desktop uses to say so.

import Quickshell
import Quickshell.Io
import QtQuick
import Asteroidz.Bar
import "settings"

Singleton {
    id: root

    // What is on screen, on disk, so anything else on the desktop can read it
    // without asking this process. The shell is the only thing that WRITES it
    // now -- the cycle daemon and the wallpaper scripts that used to are gone,
    // absorbed into this file.
    //
    // Overridable so a test can point the shell at a wallpaper of its own
    // without touching (or being touched by) the real desktop's.
    readonly property string confPath:
        Quickshell.env("ASTEROIDZ_BAR_WALLPAPER_CONF")
        || (Quickshell.env("HOME") + "/.config/asteroidz-bar/wallpaper.conf")

    property string path: ""
    property string mode: "fill"
    property string folder: Quickshell.env("HOME") + "/Pictures"
    property string order: "random"
    property int interval: 3600

    // What the browser offers: whatever the DECODER can read.
    //
    // Asked, not listed. This was six extensions, and a hardcoded list of
    // somebody else's capabilities is right until they gain one -- gdk-pixbuf
    // here also reads heic, heif, tiff, bmp, gif, svg and qoi, so a folder full
    // of perfectly displayable wallpapers showed a fraction of itself. Reported
    // as "there is a file Pictures/Dome.heic, why is it not shown".
    //
    // The fallback is the old six, for a build whose plugin is older than this
    // property: an empty browser would be a worse answer than a narrow one.
    readonly property var extensions: {
        const fromDecoder = Paths.imageExtensions();
        if (fromDecoder && fromDecoder.length > 0)
            return fromDecoder;
        return ["jpg", "jpeg", "png", "webp", "avif", "jxl"];
    }

    property var available: []

    Process {
        id: scan
        command: ["find", root.folder, "-maxdepth", "1", "-type", "f"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.split("\n")) {
                    const f = line.trim();
                    if (!f)
                        continue;
                    const ext = f.slice(f.lastIndexOf(".") + 1).toLowerCase();
                    if (root.extensions.indexOf(ext) >= 0)
                        out.push(f);
                }
                out.sort();
                root.available = out;
            }
        }
    }

    // Rescan, on demand.
    //
    // `onFolderChanged` alone was not enough, and the failure was total rather
    // than partial: `folder` defaults to ~/Pictures, and a wallpaper.conf with
    // no `folder=` line -- which is the common case, since nothing else in this
    // desktop writes one -- never changes it. The signal never fired, the scan
    // never ran, and the browser was empty forever. Reported as "the wallpaper
    // selector doesn't refresh from the folder"; it had never refreshed once.
    function rescan() {
        scan.running = true;
    }

    onFolderChanged: {
        // The watcher is watching the OLD directory: a Process picks up a
        // changed `command` when it starts, not while it runs.
        watcher.running = false;
        watcher.running = Qt.binding(() => root.folder !== "");
        rescan();
    }
    Component.onCompleted: rescan()

    // ── the folder, watched ─────────────────────────────────────────────────
    //
    // Rescanning when the page opens covers the ordinary case and nothing else:
    // a file saved, downloaded or deleted while the browser is on screen leaves
    // it showing a directory that no longer exists that way. One tile in this
    // session was scanned and then removed before it drew, so the grid asked the
    // renderer for a file that had gone.
    //
    // inotify rather than a timer. A poll is a `find` over the directory every
    // few seconds forever, for an event that happens a handful of times a day,
    // and it is still late by up to its own interval. This is idle until the
    // kernel says something changed.
    //
    // OPTIONAL: inotify-tools is an optdepend. Without it the process simply
    // fails to start and the scan-on-open path carries on doing its job, which
    // is why nothing here treats a missing binary as an error.
    Process {
        id: watcher
        running: root.folder !== ""
        command: ["inotifywait", "-m", "-q",
                  "-e", "create,delete,moved_to,moved_from,close_write",
                  "--format", ".", root.folder]
        stdout: SplitParser {
            // Every event is one line, and the content does not matter -- the
            // rescan reads the directory again regardless. What matters is that
            // a burst is ONE rescan: copying fifty files in emits fifty lines,
            // and a `find` per line would be fifty scans of a directory that is
            // still being written to.
            onRead: debounce.restart()
        }
    }

    Timer {
        id: debounce
        interval: 250
        onTriggered: root.rescan()
    }

    // Write one key back to wallpaper.conf. The file is the interface every
    // other piece of this desktop already uses -- the cycle daemon, the
    // hotkeys, set-wallpaper.sh -- so changing it here means they all agree
    // without any of them knowing about this shell.
    function setKey(key, value) {
        const lines = [];
        let replaced = false;
        for (const line of conf.text().split("\n")) {
            if (!line.trim())
                continue;
            if (line.startsWith(key + "=")) {
                lines.push(key + "=" + value);
                replaced = true;
            } else {
                lines.push(line);
            }
        }
        if (!replaced)
            lines.push(key + "=" + value);

        const text = lines.join("\n") + "\n";
        conf.setText(text);
        // ...and act on it here, rather than waiting to be told about it. The
        // file watcher does not report our OWN write -- it would loop if it
        // did -- so a wallpaper picked in the settings panel was written to
        // disk correctly and then never put on screen.
        applyConfig(parseText(text));
    }

    function parseText(t) {
        const out = {};
        for (const line of t.split("\n")) {
            const i = line.indexOf("=");
            if (i > 0)
                out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
        }
        return out;
    }

    // Everything the file can say, applied. Shared by the watcher and by
    // setKey, so a change made here and a change made by the cycle daemon
    // land in exactly the same way.
    function applyConfig(cfg) {
        if (cfg.folder) root.folder = cfg.folder;
        if (cfg.order) root.order = cfg.order;
        if (cfg.interval) root.interval = parseInt(cfg.interval) || 3600;

        if (cfg["wallpaper-scope"])
            root.scope = cfg["wallpaper-scope"];
        if (cfg.retheme !== undefined)
            root.retheming = !["0", "no", "false", "off"]
                .includes(String(cfg.retheme).toLowerCase());

        // Per-monitor overrides: `wallpaper.DP-1=/path/to/left.avif`.
        //
        // A prefixed key rather than a section or a second file, because this
        // file is a flat key=value that other things also write -- the cycle
        // daemon, a hotkey, a script -- and every one of them would have to
        // learn a new shape. A key they do not recognise is one they leave
        // alone, which is exactly the behaviour wanted.
        //
        // Rebuilt from scratch on every read, never merged: removing an
        // override means deleting its line, and a merge would keep honouring a
        // line that is no longer there.
        const per = ({});
        for (const k in cfg) {
            if (k.startsWith("wallpaper.") && cfg[k])
                per[k.slice(10)] = cfg[k];
        }
        root.storedPerMonitor = per;

        root.apply(cfg);
    }

    // ── one for all monitors, or one each ───────────────────────────────────
    //
    // An explicit choice rather than "per-monitor if any override exists".
    // Inferring it would mean the way to go back to a single wallpaper is to
    // delete every override -- which throws away exactly the settings somebody
    // with a dock or a laptop wants kept.
    property string scope: "all"   // "all" | "per-monitor"

    // Every override the FILE holds, whatever the scope, including monitors
    // that are not plugged in right now.
    //
    // Kept separate from what is drawn on purpose. Switching to one-for-all
    // must not delete anything, and neither must unplugging a monitor: an
    // entry for a screen that is not here is inert, not gone, and lights up
    // again by itself when that screen comes back. That is the whole point for
    // anyone who docks and undocks.
    property var storedPerMonitor: ({})

    // What actually reaches the wallpaper. Empty in "all" scope -- the
    // overrides are still on disk, they are simply not in force.
    readonly property var perMonitor: {
        void storedPerMonitor;
        return scope === "per-monitor" ? storedPerMonitor : ({});
    }

    // The monitors that are here now, from the outputs the backdrop has been
    // told about -- not from the compositor's monitor list. They agree, but
    // this is the list the drawing code matches names against, so offering any
    // other would let a settings page write an override that silently never
    // applies.
    readonly property var monitors: backdrop.outputs

    // Those, plus any monitor the file remembers that is not currently here,
    // so a setting made for the dock is visible and editable while undocked
    // rather than being invisible until you plug it back in.
    readonly property var knownMonitors: {
        const here = backdrop.outputs;
        const out = here.slice();
        const absent = [];
        for (const name in storedPerMonitor)
            if (here.indexOf(name) < 0)
                absent.push(name);
        absent.sort();
        return out.concat(absent);
    }

    function monitorConnected(name) {
        return backdrop.outputs.indexOf(name) >= 0;
    }

    function wallpaperFor(name) {
        return storedPerMonitor[name] || "";
    }

    function setMonitorWallpaper(name, file) {
        setKey("wallpaper." + name, file);
    }

    // What a file's own timetable says, for a page that wants to show it.
    // { dynamic: false } for an ordinary image, which is the usual answer.
    function dynamicInfo(file) {
        return backdrop.dynamicInfo(file || "");
    }

    FileView {
        id: conf
        path: root.confPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.applyConfig(root.parseText(text()))
    }

    function apply(cfg) {
        const next = cfg.wallpaper || "";
        const nextMode = cfg.mode || "fill";
        if (!next)
            return;

        const changed = next !== path;
        path = next;
        mode = nextMode;
        // Not on the first one. Startup takes `path` from "" to whatever the
        // config says, which is not a change anybody made -- and re-theming
        // there would run matugen and fire every reload hook on the machine
        // once per shell start, retoning a desktop that was already themed for
        // exactly this wallpaper when it was set.
        //
        // The cost is a theme left stale if something replaced the wallpaper
        // while the shell was down. The old script paid a state file to cover
        // that; a wrong palette until the next change is the cheaper mistake.
        if (changed && !firstApply)
            retheme();
        firstApply = false;
    }

    property bool firstApply: true

    // ── the theme follows the wallpaper ─────────────────────────────────────
    //
    // matugen derives the whole desktop's palette from the wallpaper, so a new
    // wallpaper means a new palette. set-wallpaper.sh used to do this, and it
    // was a shell script for one reason: the wallpaper was a separate process
    // too. It is not any more.
    //
    // `retheme=0` in wallpaper.conf turns it off, which is the setting somebody
    // wants when they have tuned a theme by hand and still want the picture to
    // change.
    property bool retheming: true

    function retheme() {
        if (!retheming || path === "")
            return;
        // Guarded against the reload that matugen's own post-hook causes: it
        // dispatches reload_config, the compositor re-reads its config, the bar
        // re-reads its own -- and if that round trip rewrote the wallpaper, this
        // would run again forever. The path has to have actually changed, which
        // apply() has already established.
        Matugen.retheme(path);
    }

    // A wallpaper the shell picked itself still has to reach the file, or
    // nothing else on the desktop knows what is on screen.
    function setWallpaper(file) {
        if (file && file !== path)
            setKey("wallpaper", file);
    }

    // Reachable from a keybind, without a script in between.
    //
    // `Super+y` used to spawn cycle-wallpaper.sh, which read this same config,
    // listed the same folder and wrote the same key -- a whole process to ask
    // the shell to do what the shell does. Now the compositor's bind calls
    // straight in:
    //
    //     qs -p /usr/share/asteroidz-bar/shell.qml ipc call wallpaper next
    IpcHandler {
        target: "wallpaper"

        function next(): string {
            root.advance();
            return root.path;
        }

        function set(file: string): string {
            root.setWallpaper(file);
            return root.path;
        }

        // What is on screen, for anything that wants to ask rather than parse
        // the config file itself.
        function current(): string {
            return root.path;
        }
    }

    // ── cycling ─────────────────────────────────────────────────────────────
    //
    // This was two shell scripts: a daemon that slept for `interval` and a
    // picker that advanced the file. Both read the same config this does and
    // wrote the same key, so the only thing they added was two more processes
    // and a rounding error -- the daemon slept the interval, then the picker
    // read the folder again, so "every 60 minutes" drifted by however long the
    // scan took, every time.
    //
    // Here it is a timer over a list the shell already maintains: `available`
    // is scanned on demand AND kept current by the folder watcher, so cycling
    // never picks a file that has just been deleted.
    Timer {
        id: cycle
        // `static` means never, whatever the interval says -- and an interval
        // of zero has always meant the same thing.
        running: root.order !== "static" && root.interval > 0
                 && root.available.length > 1
        interval: Math.max(60, root.interval) * 1000
        repeat: true
        onTriggered: root.advance()
    }

    function advance() {
        const list = available;
        if (list.length === 0)
            return;
        if (list.length === 1) {
            setWallpaper(list[0]);
            return;
        }

        const at = list.indexOf(path);
        if (order === "sequential") {
            // Not found means the current wallpaper is outside the folder, in
            // which case the next one is the first -- which is what the script
            // did, and is the only answer that makes progress.
            setWallpaper(list[(at + 1) % list.length]);
            return;
        }

        // Random, but never the one already up: a rotation that can repeat the
        // current wallpaper looks like it has stopped working.
        let pick = at;
        for (let i = 0; i < 8 && pick === at; i++)
            pick = Math.floor(Math.random() * list.length);
        if (pick === at)
            pick = (at + 1) % list.length;
        setWallpaper(list[pick]);
    }

    // The wallpaper itself.
    //
    // Not a process: this puts the image up on the shell's own Wayland
    // connection (plugin/wallpaper.cpp, which drives asteroidzbg as a
    // library). A change is a new buffer on a surface that is already mapped,
    // so there is no flash to hide and no old process to retire -- the
    // launch-new-then-kill-old dance the scripts needed is simply gone.
    //
    // `ready` goes true the first time an image is actually drawn; `error`
    // carries the reason when one cannot be, which is how a wallpaper that is
    // missing or in a format this build cannot decode stops being an
    // unexplained black screen.
    Backdrop {
        id: backdrop
        source: root.path
        sources: root.perMonitor
        mode: root.mode
        // Only for a `solar` dynamic wallpaper, whose schedule is the sun's
        // altitude rather than a clock. Nothing here asks for a lookup on a
        // wallpaper's account: this is whatever the shell already knows.
        latitude: Location.lat
        longitude: Location.lon
        hasLocation: Location.known
    }

    readonly property bool up: backdrop.ready
    readonly property string error: backdrop.error
}
