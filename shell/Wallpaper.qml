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

    // What the browser offers. The same extensions the scripts discover, avif
    // and jxl included -- an HDR wallpaper has to be pickable here too, not
    // only nameable in the config file.
    readonly property var extensions:
        ["jpg", "jpeg", "png", "webp", "avif", "jxl"]

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
        root.apply(cfg);
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
        mode: root.mode
    }

    readonly property bool up: backdrop.ready
    readonly property string error: backdrop.error
}
