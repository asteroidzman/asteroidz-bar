// The way in to the settings window.
//
// It used to be the settings window: two tabs and a form, in a popover hung off
// this pill. Both tabs are pages in `shell/settings/` now, and what is left here
// is the button.
//
// The move is not tidying. A popover is dismissed by the first click outside it,
// and every way of judging a display change -- looking at another window,
// dragging something onto the second screen, reading a frame rate off a game --
// is a click outside it. A panel that could not survive you looking at what it
// did was the wrong container for the one setting whose effect is the whole
// screen. It was also capped at 700px with nothing to scroll, so the wallpaper
// browser was a 220px box inside a surface that could not grow.
//
// Left click opens the Displays page, because that is what this icon means and
// what the pill was for. Right click opens the settings window as such, on
// whatever page was last showing -- the same window, reached from the same pill,
// without pretending the icon promises it.

import QtQuick
import ".."
import "../settings"

Pill {
    id: root

    // Kept by the module loader for every module; unused here now that there is
    // no popover to anchor. Declared rather than dropped because ModuleLoader
    // assigns it, and an assignment to a property that does not exist is a QML
    // error at load rather than at click.
    property var bar: null

    icons: ["waybar-display/display.svg"]
    iconTint: Cfg.fg
    paddingX: 0
    fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

    onClicked: button => {
        if (button === Qt.LeftButton)
            Settings.open("displays");
        else if (button === Qt.RightButton)
            Settings.open();
    }
}
