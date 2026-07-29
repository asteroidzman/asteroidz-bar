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

    readonly property string outPath:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/asteroidz-bar-logo-" + key + ".svg"
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

        out.setText(recoloured);
        root.ready = true;
    }

    // The palette is rewritten by matugen on every wallpaper change, and the
    // compositor pushes it straight down `watch bar-config`.
    onAccentChanged: if (template.text()) regenerate()
}
