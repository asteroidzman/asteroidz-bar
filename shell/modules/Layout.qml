// The layout indicator.
//
// Artwork keyed on the layout NAME, because that is what the asset filenames
// use (tile/scroller/monocle/float.svg) -- the same SVGs the waybar workspace
// plugin drew, now vendored into asteroidz's own assets/bar-icons rather than
// left to whichever plugin package happened to install them. The symbol is the
// fallback for a layout with no artwork
// installed, which is also why the pill keeps a fixed width: it is clickable,
// and a control that changes size when you use it moves out from under the
// pointer.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    property string screenName: ""

    readonly property string symbol: {
        void Compositor.generation;
        return Compositor.layoutSymbol(screenName);
    }

    // The artwork is keyed on the layout NAME (tile/scroller/monocle/float.svg)
    // but no IPC payload carries the name -- it carries `layout_index`, an
    // index into the compositor's layouts[] table, and the symbol. The index is
    // the exact answer, so use it and keep the symbol as the fallback label:
    // matching on symbols would break the day someone gives one a nicer glyph.
    readonly property var layoutNames: ["tile", "scroller", "monocle", "float"]

    readonly property string art: {
        void Compositor.generation;
        const i = Compositor.layoutIndex(screenName);
        return (i >= 0 && i < layoutNames.length) ? layoutNames[i] : "";
    }

    icons: art !== ""
        ? ["asteroidz-bar/layouts/" + art + ".svg"]
        : []
    text: art !== "" ? "" : symbol

    // A chip, like the tags -- bar_kind_is_chips() covers TAGS and LAYOUT --
    // so it takes the tag padding, not the narrower status-pill one.
    paddingX: Cfg.tagPadding
    chip: true

    onClicked: button => {
        if (root.screenName !== "" &&
            Compositor.focusedMonitor !== root.screenName)
            Ipc.dispatch("dispatch focus_monitor," + root.screenName);
        if (button === Qt.LeftButton)
            Ipc.dispatch("dispatch switch_layout");
    }
}
