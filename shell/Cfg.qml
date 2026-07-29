pragma Singleton

// The bar's geometry and palette, served by the compositor.
//
// asteroidz resolves `bar {}` and `theme {}` -- defaults, clamping, and the
// matugen palette that gets rewritten whenever the wallpaper changes -- and
// serves the RESULT over `watch bar-config`. Parsing the KDL here instead
// would be a second reader that agrees with the first until one of them gains
// a default, and it would still not see a palette written after startup.
//
// Every value below is also a working default, so the shell renders standalone
// (no compositor, or one built without the bar config) instead of coming up
// blank. They are the same numbers asteroidz defaults to; where the compositor
// answers, it wins.

import Quickshell
import QtQuick

Singleton {
    id: root

    // Live values, replaced wholesale on every update.
    property var bar: ({})
    property var panel: ({})
    property var popover: ({})
    property var theme: ({})
    property var custom: []
    property bool loaded: false

    function num(obj, key, fallback) {
        const v = obj[key];
        return (v === undefined || v === null) ? fallback : v;
    }

    function str(obj, key, fallback) {
        const v = obj[key];
        return (v === undefined || v === null || v === "") ? fallback : v;
    }

    // Booleans need their own reader, and skipping it costs more than it looks.
    //
    // The compositor sends real JSON booleans, and `num(bar, "show_all_tags",
    // 0) !== 0` evaluates `false !== 0`, which in JavaScript is TRUE -- strict
    // inequality between a boolean and a number is always true. Every flag read
    // that way inverted itself whenever the answer was `false`, which is how a
    // bar configured with `show-all-tags false` came up showing all nine.
    function flag(obj, key, fallback) {
        const v = obj[key];
        if (v === undefined || v === null)
            return fallback;
        return v === true || v === 1;
    }

    // Colours arrive as [r,g,b,a] floats rather than a hex string: CSS reads
    // #RRGGBBAA and Qt reads #AARRGGBB, and a string that parses under both but
    // means different things is a bug that surfaces months later as "the bar is
    // slightly the wrong colour".
    function col(obj, key, fallback) {
        const v = obj[key];
        if (!v || v.length !== 4)
            return fallback;
        return Qt.rgba(v[0], v[1], v[2], v[3]);
    }

    // ── geometry ────────────────────────────────────────────────────────────
    readonly property int height: num(bar, "height", 48)
    readonly property bool bottom: str(bar, "position", "top") === "bottom"
    readonly property int spacing: num(bar, "spacing", 8)
    readonly property int marginX: num(bar, "margin_x", 8)
    readonly property int marginY: num(bar, "margin_y", 9)
    readonly property int pillMinWidth: num(bar, "pill_min_width", 28)
    readonly property int pillInset: num(bar, "pill_inset", 6)
    readonly property int pillPadding: num(bar, "pill_padding", 6)
    readonly property int tagPadding: num(bar, "tag_padding", 16)
    readonly property int moduleSpacing: num(bar, "module_spacing", 12)
    readonly property int traySpacing: num(bar, "tray_spacing", 24)

    // ── panel ───────────────────────────────────────────────────────────────
    readonly property bool panelEnable: flag(panel, "enable", true)
    readonly property int panelRadius: num(panel, "radius", 9)
    readonly property int panelPadding: num(panel, "padding", 12)
    readonly property bool panelBlur: flag(panel, "blur", true)
    readonly property bool panelShadow: flag(panel, "shadow", true)
    readonly property int panelShadowSize: num(panel, "shadow_size", 14)
    readonly property real panelShadowBlur: num(panel, "shadow_blur", 14.0)
    readonly property color panelColor: col(panel, "color",
                                            Qt.rgba(0.039, 0.039, 0.047, 0.85))
    readonly property color panelShadowColor: col(panel, "shadow_color",
                                                  Qt.rgba(0, 0, 0, 0.70))

    // ── theme ───────────────────────────────────────────────────────────────
    readonly property color fg: col(theme, "fg", Qt.rgba(1, 1, 1, 1))
    readonly property color bg: col(theme, "bg", Qt.rgba(0, 0, 0, 0.85))
    readonly property color focusFg: col(theme, "focus_fg", fg)
    readonly property color focusBg: col(theme, "focus_bg",
                                         Qt.rgba(0.4, 0.6, 1.0, 1))
    readonly property color urgent: col(theme, "urgent",
                                        Qt.rgba(0.95, 0.35, 0.35, 1))
    readonly property int themeRadius: num(theme, "corner_radius", 5)
    readonly property color border: col(theme, "border", Qt.rgba(0, 0, 0, 0))
    readonly property int borderWidth: num(theme, "border_width", 4)
    readonly property int themePaddingY: num(theme, "padding_y", 0)

    // A Pango descriptor is "FAMILY [STYLE-OPTIONS] SIZE", and the style
    // options are the part that bites: "monospace Bold 16" is a BOLD monospace
    // at 16pt, not a family called "monospace Bold". Treating the whole
    // leading run as the family means Qt cannot match it, silently falls back
    // to its default sans, and the bar renders in a font nobody configured --
    // which is exactly what the first parity run showed.
    //
    // The default is the compositor's own fallback (text-node.c), so an
    // unconfigured theme lands on the same font here as there.
    readonly property string fontDesc: str(theme, "font", "monospace Bold 16")

    readonly property var pangoWeights: ({
        "thin": 100, "ultra-light": 200, "extralight": 200, "extra-light": 200,
        "ultralight": 200, "light": 300, "semi-light": 350, "semilight": 350,
        "demilight": 350, "book": 380, "normal": 400, "regular": 400,
        "medium": 500, "semi-bold": 600, "semibold": 600, "demibold": 600,
        "demi-bold": 600, "bold": 700, "ultra-bold": 800, "ultrabold": 800,
        "extrabold": 800, "extra-bold": 800, "heavy": 900, "black": 900,
        "ultra-heavy": 1000, "ultraheavy": 1000
    })
    readonly property var pangoStyles: ["italic", "oblique", "roman"]
    // Consumed so they do not end up in the family, but not otherwise acted on:
    // Qt's stretch is a separate axis and these are rare in a bar font.
    readonly property var pangoStretches: [
        "ultra-condensed", "extra-condensed", "condensed", "semi-condensed",
        "semi-expanded", "expanded", "extra-expanded", "ultra-expanded"
    ]

    readonly property var fontParts: {
        let s = fontDesc.trim();
        let size = 11;

        const m = /^(.*?)\s+(\d+(?:\.\d+)?)$/.exec(s);
        if (m) {
            s = m[1].trim();
            size = parseFloat(m[2]);
        }

        let weight = 400;
        let italic = false;

        // Style words are a SUFFIX, so walk back from the end and stop at the
        // first word that is not one -- otherwise a family legitimately called
        // "Book Antiqua" loses its first word.
        let words = s.split(/\s+/);
        while (words.length > 1) {
            const w = words[words.length - 1].toLowerCase();
            if (pangoWeights[w] !== undefined) {
                weight = pangoWeights[w];
            } else if (pangoStyles.indexOf(w) >= 0) {
                italic = (w !== "roman");
            } else if (pangoStretches.indexOf(w) >= 0) {
                // consumed
            } else {
                break;
            }
            words.pop();
        }

        return {
            family: words.join(" "),
            size: size,
            weight: weight,
            italic: italic
        };
    }
    readonly property string fontFamily: fontParts.family
    readonly property real fontSize: fontParts.size
    readonly property int fontWeight: fontParts.weight
    readonly property bool fontItalic: fontParts.italic
    // The compositor's Pango size is points at a fixed 96dpi (text-node.c sets
    // the resolution explicitly), so the pixel height is points * 96/72. Using
    // this rather than font.pointSize takes Qt's own DPI guess out of the
    // picture entirely -- see bin/asteroidz-bar for why that matters.
    readonly property real fontPixelSize: fontSize * 96.0 / 72.0

    // ── module lists ────────────────────────────────────────────────────────
    readonly property string modulesLeft: str(bar, "modules_left", "tags,layout,title")
    readonly property string modulesCenter: str(bar, "modules_center", "clock")
    readonly property string modulesRight: str(bar, "modules_right", "")
    readonly property string leftMonitor: str(bar, "modules_left_monitor", "")
    readonly property string centerMonitor: str(bar, "modules_center_monitor", "")
    readonly property string rightMonitor: str(bar, "modules_right_monitor", "")

    readonly property string clockFormat: str(bar, "clock_format", "%H:%M:%S")
    readonly property string iconDir: str(bar, "icon_dir", "")
    readonly property int titleWidth: num(bar, "title_width", 320)
    readonly property bool showAllTags: flag(bar, "show_all_tags", false)
    readonly property int minTags: num(bar, "min_tags", 3)
    readonly property bool showLogo: flag(bar, "show_logo", true)
    readonly property int tagIcons: num(bar, "tag_icons", 3)

    function modules(list) {
        return list.split(",").map(s => s.trim()).filter(s => s.length > 0);
    }

    // Tags AND layout are "chips": filled tiles whose own background is the
    // edge you see, so they carry the wider tag padding and contribute no ink
    // inset. Getting this wrong is worth 32px per pill -- the layout indicator
    // was a bare 36px square instead of a 68px chip.
    function isChip(module) {
        return module === "tags" || module === "layout";
    }

    // Artwork with no label. These are laid out as one run with an exact gap
    // rather than with padding each, because padding is symmetric and can only
    // ever produce an even gap -- and it pads the ends of the run against the
    // panel edge too.
    function isIconOnly(module) {
        return ["cpu", "memory", "network", "idle", "notify", "tray", "vpn",
                "display"].indexOf(module) >= 0;
    }

    function pillPaddingFor(module) {
        if (isChip(module))
            return tagPadding;
        if (isIconOnly(module))
            return 0;
        return pillPadding;
    }

    // How much of the space between two pills is already taken up by the left
    // one's own padding.
    function inkInset(module) {
        return isChip(module) ? 0 : pillPaddingFor(module);
    }

    // The gap between two adjacent modules, measured the way you SEE it: ink to
    // ink, not box to box.
    //
    // A constant box gap renders as an inconsistent visible one -- 12px between
    // two icons, 18 between an icon and a label, 24 between two labels -- which
    // is why the native bar subtracts each side's padding from the configured
    // separation and floors the result, so two backgrounds can never fuse into
    // one wider pill.
    function moduleGap(prev, next) {
        if (prev === "")
            return 0;
        // Two runs of tiles meet box to box, at the same spacing the tiles
        // INSIDE a chip module already use -- otherwise the seam between the
        // tags and the layout indicator is wider than the seams between the
        // tags themselves, and the two runs stop reading as one row.
        if (isChip(prev) && isChip(next))
            return spacing;
        // The tray gets a wider berth, so other applications' icons read as
        // their own group rather than as more of ours.
        const base = (prev === "tray" || next === "tray" ||
                      prev === "custom/tray" || next === "custom/tray")
            ? traySpacing
            : moduleSpacing;
        return Math.max(2, base - inkInset(prev) - inkInset(next));
    }

    // Does `section` belong on this output? "" and "all" mean every screen,
    // otherwise it names one. (The compositor also accepts "focused"; that
    // needs focus tracking, so it is treated as "all" until phase 2 lands it.)
    function sectionOnScreen(which, screenName) {
        if (which === "" || which === "all" || which === "focused")
            return true;
        return which === screenName;
    }

    Component.onCompleted: {
        Ipc.watch("watch bar-config", obj => {
            if (obj.bar) root.bar = obj.bar;
            if (obj.panel) root.panel = obj.panel;
            if (obj.popover) root.popover = obj.popover;
            if (obj.theme) root.theme = obj.theme;
            if (obj.custom) root.custom = obj.custom;
            root.loaded = true;
        });
    }
}
