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
    readonly property bool panelEnable: num(panel, "enable", 1) !== 0
    readonly property int panelRadius: num(panel, "radius", 9)
    readonly property int panelPadding: num(panel, "padding", 12)
    readonly property bool panelBlur: num(panel, "blur", 1) !== 0
    readonly property bool panelShadow: num(panel, "shadow", 1) !== 0
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
    readonly property int themeRadius: num(theme, "corner_radius", 8)

    // Pango descriptor ("Ubuntu 16", "Noto Sans Bold 11"): family, optional
    // style words, then a size in POINTS. Qt wants those in separate
    // properties, so split on the trailing number.
    readonly property string fontDesc: str(theme, "font", "Ubuntu 16")
    readonly property var fontParts: {
        const m = /^(.*?)\s+(\d+(?:\.\d+)?)$/.exec(fontDesc.trim());
        if (!m)
            return { family: fontDesc.trim(), size: 11 };
        return { family: m[1].trim(), size: parseFloat(m[2]) };
    }
    readonly property string fontFamily: fontParts.family
    readonly property real fontSize: fontParts.size
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
    readonly property bool showAllTags: num(bar, "show_all_tags", 0) !== 0
    readonly property int minTags: num(bar, "min_tags", 3)
    readonly property bool showLogo: num(bar, "show_logo", 1) !== 0
    readonly property int tagIcons: num(bar, "tag_icons", 3)

    function modules(list) {
        return list.split(",").map(s => s.trim()).filter(s => s.length > 0);
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
