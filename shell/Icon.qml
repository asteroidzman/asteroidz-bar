// Artwork, resolved the way the compositor resolves it.
//
// Two kinds of name arrive here and they are not looked up the same way:
//
//   "waybar-asteroidz-workspaces/logo.svg"  a path relative to one of the
//                                           roots in `bar { icon-dir }`
//   "firefox"                               an icon THEME name (an app id)
//
// The first is a search path, tried in order, first hit wins -- the same list
// the native bar walks, so a locally-customised asset still beats the packaged
// one. There is no file-existence API in QML, so "first hit" is implemented by
// letting Image fail and moving to the next candidate; a miss costs one
// rejected load, not a warning and not a blank pill.

import Quickshell
import QtQuick
import "."

Image {
    id: root

    // Either form. Empty draws nothing.
    property string name: ""

    readonly property var candidates: {
        if (name === "")
            return [];
        if (name.startsWith("/"))
            return ["file://" + name];
        if (name.includes("/")) {
            // relative asset: every root in the search path, in order
            const roots = Cfg.iconDir.split(":").filter(s => s.length > 0);
            return roots.map(r => "file://" + r + "/" + name);
        }
        // theme name; Quickshell hands back "" when the theme has no such icon
        const p = Quickshell.iconPath(name, true);
        return p ? [p] : [];
    }

    property int candidate: 0

    source: candidate < candidates.length ? candidates[candidate] : ""
    visible: source !== "" && status === Image.Ready

    onCandidatesChanged: candidate = 0
    onStatusChanged: {
        if (status === Image.Error && candidate + 1 < candidates.length)
            candidate++;
    }

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
    readonly property bool themeIcon: name !== "" && !name.includes("/")
    sourceSize.width: themeIcon ? size * 2 : 0
    sourceSize.height: size * 2
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: true
}
