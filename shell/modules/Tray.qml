// The StatusNotifierItem tray, with real context menus.
//
// This is the module that most justifies the move out of the compositor. The
// native one decodes application-supplied pixmaps on the compositor's event
// loop -- a tray icon is an arbitrary-sized ARGB array from an arbitrary
// application, and Steam's menu alone is several kilobytes of DBusMenu that
// had to be parsed there too. asteroidz-trayd was written to get that out of
// the compositor; here it is not needed at all, because quickshell is already
// an SNI host and a DBusMenu client.
//
// One pill per item, because a pill is the unit of hit testing.

import Quickshell
import Quickshell.Services.SystemTray
import QtQuick
import ".."

Row {
    id: root

    property var bar: null
    spacing: Cfg.spacing

    // Artwork with no label, so the run is spaced by an exact gap and the
    // pills carry no padding of their own.
    readonly property int leadTrim: 0
    readonly property int trailTrim: 0

    Repeater {
        model: SystemTray.items

        delegate: Pill {
            id: item
            required property var modelData

            icons: [modelData.icon]
            // Tray artwork comes from arbitrary applications and is the only
            // artwork in the bar drawn as a run of unrelated logos, so it is
            // the only place that needs ink normalisation.
            opticalIcons: true
            paddingX: 0
            fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

            // Passive items are hidden by the specification: an application
            // that says it has nothing to report should not hold width.
            // The enum is exported as `Status`, not `SystemTrayStatus`. Naming
            // it wrong does not fail loudly -- the binding throws, the
            // property keeps its default of true, and every passive item shows
            // up anyway.
            visible: modelData.status !== Status.Passive

            QsMenuOpener {
                id: opener
                menu: item.modelData.menu
            }

            onClicked: button => {
                if (button === Qt.LeftButton) {
                    // An item with ONLY a menu has no activate action; opening
                    // its menu is the whole of what a left click can mean.
                    if (modelData.onlyMenu && modelData.hasMenu)
                        openMenu();
                    else
                        modelData.activate();
                } else if (button === Qt.MiddleButton) {
                    modelData.secondaryActivate();
                } else if (button === Qt.RightButton && modelData.hasMenu) {
                    openMenu();
                }
            }

            // scroll(delta, horizontal), NOT scroll(orientation, delta).
            // Reversed, this sent every tray item a delta of ZERO with
            // `horizontal` set to whatever the wheel produced -- which is
            // truthy for any real scroll, so items got a horizontal no-op and
            // nothing that reacts to the wheel (a volume applet, a workspace
            // switcher) ever moved. Vertical, because Pill.wheel carries
            // angleDelta.y.
            onWheel: delta => modelData.scroll(delta, false)

            function openMenu() {
                if (!root.bar)
                    return;
                root.bar.showMenu(item, opener.children.values.map(e => ({
                    text: e.text,
                    icon: e.icon,
                    enabled: e.enabled,
                    separator: e.isSeparator,
                    submenu: e.hasChildren,
                    checked: e.checkState === Qt.Checked,
                    entry: e
                })));
            }
        }
    }
}
