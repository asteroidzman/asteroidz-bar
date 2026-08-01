pragma Singleton

// The asteroidz ship, with its exhaust in the theme's colour.
//
// The artwork is a wireframe Atari-Asteroids triangle with a flame out of the
// back, and the flame is meant to follow the theme -- the SVG says so itself:
//
//     the flame hexes below are substituted for shades of the theme accent, by
//     string replacement, in asteroidz-bar's shell/Logo.qml -- keep them
//     verbatim.
//
// The recolouring used to be the plugin's (asteroidz_ws.c logo_pixbuf); that
// plugin is gone, so it lives here now. It cannot be done with a
// tint the way every other icon in the bar is coloured: ColorOverlay paints
// through the whole alpha channel, so tinting this would flood the hull as
// well and leave a solid triangle. The colours have to be swapped in the
// source, which means writing a copy of the file.
//
// The copy lives in XDG_RUNTIME_DIR and is rewritten whenever the palette
// changes, which on this desktop is every time the wallpaper does.

import Quickshell
import Quickshell.Io
import QtQuick
import Asteroidz.Bar
import "."

Singleton {
    id: root

    // What the artwork is called in the icon search path, and where that
    // search actually found it.
    readonly property string sourceName: "asteroidz-bar/logo.svg"
    readonly property string sourcePath: {
        const roots = Cfg.iconDir.split(":").filter(s => s.length > 0);
        return Paths.resolve(roots.map(r => r + "/" + sourceName));
    }

    // The path ALTERNATES between two names, and that is load-bearing rather
    // than tidy.
    //
    // Rewriting one fixed path did not repaint: Qt caches an Image by its URL,
    // so a second regenerate() wrote a newly-coloured file that nothing looked
    // at, and the ship kept the accent it was born with while the rest of the
    // bar followed the wallpaper. A changing URL is what invalidates the cache.
    //
    // Two names rather than a counter, so a desktop that changes wallpaper on a
    // timer leaves two files in XDG_RUNTIME_DIR instead of one per change.
    property int generation: 0
    readonly property string outPath:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/asteroidz-bar-logo-" + key + "-" + (generation % 2) + ".svg"
    // Per bar process: two of them (a second monitor) must not write each
    // other's file while one of them is reading it.
    readonly property string key: Math.random().toString(36).slice(2, 10)

    // The colour the exhaust burns in. The accent, because that is what the
    // theme calls its own colour and what every other "this is us" element on
    // the bar uses.
    readonly property color accent: Cfg.focusBg

    // Ready only once a recoloured copy exists; until then the pill draws the
    // artwork as shipped rather than nothing at all.
    property bool ready: false
    readonly property string source: ready ? "file://" + outPath : sourcePath

    function hex(c) {
        return "#"
            + Math.round(c.r * 255).toString(16).padStart(2, "0")
            + Math.round(c.g * 255).toString(16).padStart(2, "0")
            + Math.round(c.b * 255).toString(16).padStart(2, "0");
    }

    FileView {
        id: template
        path: root.sourcePath.startsWith("file://")
            ? root.sourcePath.slice("file://".length)
            : root.sourcePath
        onLoaded: root.regenerate()
    }

    FileView {
        id: out
        path: root.outPath

        // `ready` is a claim that the file EXISTS, and regenerate() sets it on
        // the line after setText(). With an asynchronous write that claim was a
        // race: the Image was pointed at the copy, the copy was not there yet,
        // Image reported "Cannot open" once and never retried -- so the ship
        // vanished from the bar for the rest of the session, and came back on
        // whichever restart happened to win the race, which is exactly how it
        // presented ("my logo is missing", again, intermittently).
        //
        // blockWrites makes the claim true. atomicWrites so a reader can never
        // catch a half-written SVG, which fails to parse the same unrecoverable
        // way.
        blockWrites: true
        atomicWrites: true

        // Nothing to preload: this path is an OUTPUT. Reading it at startup
        // found no file and warned about it on every single start -- about the
        // file this object exists to create.
        preload: false
    }

    // The flame is a three-stop gradient plus a pale core. Each is replaced by
    // a shade of the accent in the same order, so the plume keeps its shape
    // and its depth and only changes hue.
    function regenerate() {
        const svg = template.text();
        if (!svg)
            return;

        const recoloured = svg
            .replace("#ffd27f", hex(Qt.lighter(accent, 1.5)))
            .replace("#ff9a3c", hex(accent))
            .replace("#f2603f", hex(Qt.darker(accent, 1.4)))
            .replace("#fff2cf", hex(Qt.lighter(accent, 1.8)));

        // Bumped BEFORE the write, so setText lands on the path `source` is
        // about to point at. Bumping it after would write the new colours to
        // the name that is on its way out and publish the name of a file that
        // does not exist -- the same failure this whole comment block is about,
        // reintroduced from the other direction.
        root.generation++;
        out.setText(recoloured);
        root.ready = true;
    }

    // The palette is rewritten by matugen on every wallpaper change, and the
    // compositor pushes it straight down `watch bar-config`.
    onAccentChanged: if (template.text()) regenerate()
}
