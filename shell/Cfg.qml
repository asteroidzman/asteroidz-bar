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
// Explicit, and load-bearing. Without it `BarConfig` resolves through QML's
// implicit same-directory import, which builds its own instance rather than
// using the one qmldir registers as a singleton -- so this file read an empty
// config that nothing ever populated, while every other file saw the real one.
// Silent: two objects of the same type, one of them never loaded.
import "."

Singleton {
    id: root

    // The bar's own settings, read from its own config file. PROPERTIES, not
    // accessor calls: a QML binding tracks property READS, so a binding whose
    // expression is only a function call has nothing to depend on and
    // evaluates exactly once -- before the file has been read, leaving every
    // value at its default for the life of the process. That is not
    // theoretical; it is what the first version of this did.
    readonly property var bar: BarConfig.groups.bar || ({})
    readonly property var panel: BarConfig.groups.panel || ({})
    readonly property var popover: BarConfig.groups.popover || ({})

    // The theme is still the compositor's: matugen rewrites it at runtime, and
    // titlebars and the overview draw from the same palette.
    property var theme: ({})
    property bool loaded: false

    function num(obj, key, fallback) {
        const v = obj[key];
        return (v === undefined || v === null) ? fallback : v;
    }

    function str(obj, key, fallback) {
        const v = obj[key];
        return (v === undefined || v === null || v === "") ? fallback : v;
    }

    // For values where EMPTY IS AN ANSWER.
    //
    // `str` treats "" as "not set" and hands back the default, which is right
    // for a font or a clock format -- and wrong for a module list, where ""
    // means "draw nothing in this section". A bar configured with
    // `modules-right ""` was getting the default list instead of an empty
    // one, which is the opposite of what was asked for.
    function strOrEmpty(obj, key, fallback) {
        const v = obj[key];
        return (v === undefined || v === null) ? fallback : v;
    }

    // Booleans need their own reader, and skipping it costs more than it looks.
    //
    // The compositor sends real JSON booleans, and `num(bar, "show-all-tags",
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

    // ── sizes ───────────────────────────────────────────────────────────────
    //
    // An em: a multiple of the theme font's pixel height, rounded to a whole
    // logical pixel.
    //
    // Every default below goes through this, and it is the only reason one
    // setting -- `theme { font }` -- can resize the whole bar. They used to be
    // absolute pixel counts, each tuned by hand against whatever font was in
    // the theme at the time, so raising the font grew the text inside boxes
    // that stayed where they were: a 48px bar with 17pt type in it is snug,
    // and the same 48px bar with 10pt type in it is a band of empty space
    // with a thin line of writing across the middle.
    //
    // The multipliers are the old numbers divided by the font they were
    // chosen against (the compositor's default, "monospace Bold 16" -- 21.33
    // pixels at 96 dpi), so an unconfigured bar on the default theme is within
    // a pixel of what it always was.
    //
    // Still LOGICAL pixels: the output scale is applied to the finished
    // surface by the compositor, not here. See the note in Bar.qml.
    function em(mult) { return Math.round(fontPixelSize * mult); }

    // ── geometry ────────────────────────────────────────────────────────────
    readonly property int height: num(bar, "height", em(2.25))
    readonly property bool bottom: str(bar, "position", "top") === "bottom"
    readonly property int spacing: num(bar, "spacing", em(0.375))
    readonly property int marginX: num(bar, "margin-x", em(0.375))
    readonly property int marginY: num(bar, "margin-y", em(0.42))
    readonly property int pillMinWidth: num(bar, "pill-min-width", em(1.3))
    readonly property int pillInset: num(bar, "pill-inset", em(0.28))
    readonly property int pillPadding: num(bar, "pill-padding", em(0.28))
    readonly property int tagPadding: num(bar, "tag-padding", em(0.75))
    readonly property int moduleSpacing: num(bar, "module-spacing", em(0.56))
    readonly property int traySpacing: num(bar, "tray-spacing", em(1.125))

    // ── panel ───────────────────────────────────────────────────────────────
    readonly property bool panelEnable: flag(panel, "enable", true)
    readonly property int panelRadius: num(panel, "radius", em(0.42))
    readonly property int panelPadding: num(panel, "padding", em(0.56))
    readonly property bool panelBlur: flag(panel, "blur", true)
    readonly property bool panelShadow: flag(panel, "shadow", true)
    readonly property int panelShadowSize: num(panel, "shadow-size", em(0.66))
    readonly property real panelShadowBlur: num(panel, "shadow-blur", em(0.66))
    readonly property color panelColor: col(panel, "color",
                                            Qt.rgba(0.039, 0.039, 0.047, 0.85))
    readonly property color panelShadowColor: col(panel, "shadow-color",
                                                  Qt.rgba(0, 0, 0, 0.70))

    // ── notifications ───────────────────────────────────────────────────────
    //
    // Gathered here rather than read straight out of BarConfig in each of the
    // four notification files, which is what they did -- so `380` was written
    // twice, in the toasts and in the centre, and a change to one silently made
    // the popup and the panel it opens into different widths.
    //
    // 20 ems is about 45 characters of body text, which is a notification
    // rather than a paragraph.
    readonly property var notify: BarConfig.groups.notify || ({})
    readonly property int notifyWidth: num(notify, "width", em(20))
    readonly property int notifyCentreHeight:
        num(notify, "centre-height", em(20))
    readonly property int notifyTimeout: num(notify, "timeout", 5000)
    readonly property int notifyMaxPopups: num(notify, "max-popups", 4)
    readonly property bool notifyDnd: flag(notify, "dnd", false)

    // The clipboard.
    //
    // Wider than the notification centre, because what is being scanned here
    // is a line you are trying to RECOGNISE rather than a message you are
    // reading: more characters per row is what turns "which of these four
    // URLs" into a glance instead of four hovers.
    readonly property var clipboard: BarConfig.groups.clipboard || ({})
    readonly property int clipboardWidth: num(clipboard, "width", em(24))
    readonly property int clipboardHeight: num(clipboard, "height", em(22))
    // Roughly a day of ordinary copying. The cost is memory -- every entry is
    // held whole, images included -- so this is the knob for anyone who pastes
    // screenshots all day.
    readonly property int clipboardLimit: num(clipboard, "limit", 100)

    // The calendar, under the clock.
    //
    // Width is driven by the month grid rather than by taste: seven columns
    // wide enough for a two-digit day with room to breathe, and the agenda
    // underneath inherits it.
    readonly property var calendar: BarConfig.groups.calendar || ({})
    readonly property int calendarWidth: num(calendar, "width", em(21))
    readonly property int calendarAgendaHeight: num(calendar, "agenda-height", em(11))
    // How far ahead to fetch. The grid only ever shows a month, but the agenda
    // reads forward, and refetching on every arrow press would make paging the
    // month a network round trip.
    readonly property int calendarHorizon: num(calendar, "horizon-days", 60)

    // On by default, unlike the sound. A toast over a fullscreen film or game
    // is an intrusion with no way to dismiss it that does not leave what you
    // are doing, so the useful default is the quiet one -- and the
    // notification still lands in the centre either way.
    readonly property bool notifyHideOverFullscreen:
        flag(notify, "hide-over-fullscreen", true)

    // Off by default. A desktop that starts making noise because it was
    // updated is worse than one that never made any.
    readonly property bool notifySound: flag(notify, "sound", false)
    // A name from the freedesktop sound-naming spec, not a path, so it follows
    // whatever sound theme is installed rather than hardcoding one
    // distribution's file layout.
    readonly property string notifySoundName:
        str(notify, "sound-name", "message-new-instant")
    readonly property string notifySoundTheme:
        str(notify, "sound-theme", "freedesktop")
    // The artwork's box on a card. Also font-derived, so the icon keeps its
    // proportion to the text beside it.
    readonly property int notifyIconSize: num(notify, "icon-size", em(1.8))

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

    // ── legibility ──────────────────────────────────────────────────────────
    //
    // The palette has no partner for `urgent`. `focus_bg` has `focus_fg`, and
    // matugen sets both from a Material pair, but urgent is a single colour
    // chosen to read against the BAR -- so anything that paints it as a
    // BACKGROUND has to work out its own foreground. On this desktop urgent
    // comes out as a light salmon (matugen's error container), and the theme
    // foreground is near-white: a pill that went urgent was white on pale
    // pink, which is how a reminder coming due announced itself illegibly.
    //
    // Rec.709 luminance against the midpoint, the same rule the compositor's
    // own bar_readable_fg applies, so a chip on the bar and a chip drawn here
    // pick the same side.

    function luminance(c) {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }

    // The theme foreground, or near-black when the background is too light for
    // it. Near-black rather than pure: the palette is never pure black either,
    // and it keeps the alpha the theme asked for.
    function readableOn(c) {
        return luminance(c) < 0.5 ? fg : Qt.rgba(0.08, 0.08, 0.08, fg.a);
    }

    // `want` if it can be read on `over`, else whatever can be.
    //
    // A ratio rather than a luminance test, because the failure is not always
    // light-on-light: an icon tinted `urgent` on a pill whose background is
    // also urgent has no contrast at all whatever the luminance says, and that
    // is exactly what a plugin sends when something is due.
    function legibleOn(want, over) {
        if (!over || over === "transparent" || over.a === 0)
            return want;
        const a = luminance(want) + 0.05;
        const b = luminance(over) + 0.05;
        const ratio = a > b ? a / b : b / a;
        return ratio >= 2.2 ? want : readableOn(over);
    }

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

    readonly property string clockFormat: str(bar, "clock-format", "%H:%M:%S")
    // Where the icons live. The compositor's package installs them and used to
    // serve this path along with everything else; the default is the same
    // search list it built, so an unconfigured bar still finds the ship and the
    // tag glyphs. Without it every Icon resolves to nothing and the bar draws
    // text where the artwork should be -- silently, because a missing icon is
    // also how an intentionally blank one looks.
    readonly property string iconDir: str(bar, "icon-dir",
        "/usr/share/asteroidz/bar-icons:"
        + Quickshell.env("HOME") + "/.local/share:/usr/share")
    readonly property int titleWidth: num(bar, "title-width", em(15))
    readonly property bool showAllTags: flag(bar, "show-all-tags", false)
    readonly property int minTags: num(bar, "min-tags", 3)
    readonly property int tagIcons: num(bar, "tag-icons", 3)
    readonly property int interval: num(bar, "interval", 2)
    readonly property int volumeStep: num(bar, "volume-step", 5)
    readonly property real netMaxDown: num(bar, "net-max-down", 0)
    readonly property real netMaxUp: num(bar, "net-max-up", 0)
    readonly property int mediaWidth: num(bar, "media-width", em(13))
    readonly property int mediaBars: num(bar, "media-bars", 6)
    readonly property int mediaFps: num(bar, "media-fps", 20)
    readonly property bool mediaViz: num(bar, "media-viz", 1) !== 0
    readonly property int weatherInterval: num(bar, "weather-interval", 15)

    // ── popover ─────────────────────────────────────────────────────────────
    readonly property int popoverWidth: num(popover, "width", em(16))
    readonly property int popoverRowHeight: num(popover, "row-height", em(1.6))
    readonly property int popoverSpacing: num(popover, "spacing", em(0.1))
    readonly property int popoverPadding: num(popover, "padding", em(0.56))
    readonly property int popoverGap: num(popover, "gap", em(0.28))
    readonly property color popoverColor: col(popover, "color",
                                              Qt.rgba(0.039, 0.039, 0.047, 0.95))
    readonly property string weatherLocation: str(bar, "weather-location", "")

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
        // A plugin showing artwork and no label is icon-only too, but whether
        // it HAS a label is a runtime answer -- so plugins are treated as
        // labelled here and pay one pill-padding of gap. Guessing the other
        // way would jam a labelled plugin against its neighbour.
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
            if (obj.theme) root.theme = obj.theme;
            root.loaded = true;
        });
    }
}
