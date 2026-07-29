// Artwork, resolved the way the compositor resolves it.
//
// Two kinds of name arrive here and they are not looked up the same way:
//
//   "asteroidz-bar/logo.svg"   a path relative to one of the roots in
//                              `bar { icon-dir }`
//   "firefox"                  an icon THEME name (an app id)
//
// The first is a search path, tried in order, first hit wins -- the same list
// the native bar walks, so a locally-customised asset still beats the packaged
// one.
//
// "First hit" is one stat per candidate, through Paths.resolve (the C++
// module). It used to be implemented by pointing this Image at each candidate
// in turn and moving on when it failed, which worked but logged a warning for
// every miss -- and misses are the NORMAL case for a search path, so a cold
// start printed a dozen "Cannot open" lines about artwork that was found one
// candidate later and drawn correctly.

import Quickshell
import QtQuick
import Qt5Compat.GraphicalEffects
import Asteroidz.Bar
import "."

Image {
    id: root

    // Either form. Empty draws nothing.
    property string name: ""

    // Recolour the artwork wholesale. The monochrome status glyphs are drawn
    // in the theme's colours rather than their own, and for cpu and memory the
    // tint IS the reading -- so this is not decoration, it is the value.
    // Transparent leaves the artwork's own colours alone, which is what the
    // network arrows need (they carry two colours and tinting would flatten
    // both halves to one).
    property color tint: "transparent"
    readonly property bool tinted: tint.a > 0

    readonly property string resolved: {
        if (name === "")
            return "";
        // Already a URL: quickshell hands back things like
        // "image://icon/dialog-information" for tray items, whose icon may be
        // a theme name, an inline pixmap, or a path -- it has already done the
        // resolving. Treating that as a relative asset (it contains a slash)
        // sent it through the bar's icon-dir search, where it matched nothing
        // and the tray drew empty pills.
        if (name.includes("://"))
            return name;
        if (name.startsWith("/"))
            return Paths.resolve([name]);
        if (name.includes("/")) {
            // relative asset: every root in the search path, in order
            const roots = Cfg.iconDir.split(":").filter(s => s.length > 0);
            return Paths.resolve(roots.map(r => r + "/" + name));
        }
        // theme name; Quickshell hands back "" when the theme has no such icon
        return Quickshell.iconPath(name, true);
    }

    source: resolved
    visible: source !== "" && status === Image.Ready

    // The box the artwork is fitted into. Width is the ADVANCE, which is not
    // always the box: a portrait icon fitted into a square box only occupies
    // box * w/h of it, and reserving the full square would pad the pill with
    // space the artwork never covers. A landscape or square icon gets the box
    // (asteroidz_icon_advance: `w >= h` returns the box unchanged).
    property int size: 0

    readonly property real aspect:
        (implicitWidth > 0 && implicitHeight > 0)
            ? implicitWidth / implicitHeight
            : 1.0

    height: size
    width: aspect < 1.0 ? Math.round(size * aspect) : size

    // Both dimensions for a THEME icon, height only for a file asset.
    //
    // SVGs have no natural size, so one dimension has to be asked for (times
    // two, so a scaled output gets crisp artwork rather than an upscale). Ask
    // for both and the image is rasterised into a square and reports a square
    // implicit size, which silently defeats the advance rule above.
    //
    // But asking for height ALONE breaks the icon-theme provider: it stopped
    // resolving the application icons entirely and drew a grey block where the
    // artwork should be. Theme icons are square by specification, so they lose
    // nothing by being asked for as squares, and the aspect rule is left for
    // the artwork where it actually applies.
    // Only the bar's OWN vendored artwork is asked for by height alone. That
    // is the artwork whose aspect ratio the advance rule needs to know, and it
    // is the only artwork we ship, so we know it renders correctly that way.
    //
    // Everything else -- icon-theme names and the URLs quickshell hands back
    // for tray items -- is asked for as a square, because a height-only
    // request breaks both providers: theme icons came back as grey blocks and
    // tray icons as magenta smears. They are square by specification anyway.
    readonly property bool ownAsset:
        name !== "" && name.includes("/") && !name.includes("://")
        && !name.startsWith("/")
    sourceSize.width: ownAsset ? 0 : size * 2
    sourceSize.height: size * 2
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: true

    // Tinting is a MASK, not a colour blend.
    //
    // The compositor paints the tint THROUGH the artwork's alpha (a cairo mask
    // paint), so a monochrome glyph comes out entirely in the tint colour.
    // MultiEffect's `colorization` is a hue blend that preserves luminance
    // instead, which turned the dark-drawn cpu and memory glyphs black rather
    // than blue -- technically a tint, visibly a bug. ColorOverlay is the
    // operation that was actually meant.
    layer.enabled: tinted
    layer.effect: ColorOverlay {
        color: root.tint
    }
}
