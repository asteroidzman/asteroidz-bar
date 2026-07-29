pragma Singleton

// The wallpaper, owned by the shell.
//
// asteroidzbg is part of this package and part of this process's lifecycle:
// starting asteroidz-bar puts up the bar AND the wallpaper, and stopping it
// takes both down. There is nothing else to launch and nothing else to keep
// in step.
//
// It stays a SEPARATE PROCESS rather than becoming a layer-shell window drawn
// here, and that is not a shortcut. asteroidzbg tags its surface through
// wp_color_manager_v1 with BT.2020 primaries and the PQ transfer function, and
// decodes 10-bit AVIF and JPEG XL to match. QML has no way to reach either --
// drawing the wallpaper in this process would silently turn every HDR
// wallpaper into an SDR one read as plain gamma, which is precisely the bug
// asteroidzbg was forked from swaybg to fix. Embedding it means owning it, not
// reimplementing it.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    // Where the packaged binary is. The launcher exports this; the fallback is
    // for running from a working tree.
    //
    // An absolute path deliberately: PATH here would find
    // /usr/local/bin/asteroidzbg first on a machine that has a hand-installed
    // copy, and then the wallpaper would come from a different build than the
    // rest of the package.
    readonly property string binary:
        Quickshell.env("ASTEROIDZ_BAR_BG") || "/usr/bin/asteroidzbg"

    // The same file the wallpaper scripts write, so whatever sets it -- the
    // cycle daemon, a menu, a hotkey -- is picked up here without any of them
    // needing to know about this shell.
    readonly property string confPath:
        Quickshell.env("HOME") + "/.config/waybar/wallpaper.conf"

    property string path: ""
    property string mode: "fill"

    FileView {
        id: conf
        path: root.confPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.apply(parse())

        function parse() {
            const out = {};
            for (const line of text().split("\n")) {
                const i = line.indexOf("=");
                if (i > 0)
                    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
            }
            return out;
        }
    }

    // Launch the new one, retire the old one.
    //
    // In that order, with a beat in between: killing first leaves the output
    // showing whatever was behind the wallpaper -- usually black -- for as long
    // as the new process takes to map its surface. Overlapping them means the
    // new layer is already up when the old one goes, so a wallpaper change is
    // a swap rather than a flash. The scripts this replaces used the same
    // trick and the same 0.3s.
    property var current: null

    function apply(cfg) {
        const next = cfg.wallpaper || "";
        const nextMode = cfg.mode || "fill";
        if (!next || (next === path && nextMode === mode && current))
            return;

        path = next;
        mode = nextMode;

        const previous = current;
        current = bgComponent.createObject(root, {
            image: next,
            fillMode: nextMode
        });

        if (previous)
            retire.retiring.push(previous), retire.restart();
    }

    Timer {
        id: retire
        interval: 300
        property var retiring: []
        onTriggered: {
            for (const p of retiring) {
                p.running = false;
                p.destroy();
            }
            retiring = [];
        }
    }

    Component {
        id: bgComponent

        Process {
            required property string image
            required property string fillMode

            command: [root.binary, "-o", "*", "-i", image, "-m", fillMode]
            running: true

            // A wallpaper process that exits on its own is a real fault -- a
            // missing file, a codec that is not built in -- and silently
            // restarting it would spin. Say so once and leave the last
            // wallpaper up.
            onExited: (code, status) => {
                if (code !== 0 && root.current === this)
                    console.warn("asteroidz-bar: asteroidzbg exited", code,
                                 "for", image);
            }
        }
    }
}
