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

Singleton {
    id: root

    // The same file the wallpaper scripts write, so whatever sets it -- the
    // cycle daemon, a menu, a hotkey -- is picked up here without any of them
    // needing to know about this shell.
    //
    // Overridable so a test can point the shell at a wallpaper of its own
    // without touching (or being touched by) the real desktop's.
    readonly property string confPath:
        Quickshell.env("ASTEROIDZ_BAR_WALLPAPER_CONF")
        || (Quickshell.env("HOME") + "/.config/waybar/wallpaper.conf")

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

        path = next;
        mode = nextMode;
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
