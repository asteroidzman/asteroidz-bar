// The power menu: lock, log out, suspend, hibernate, reboot, power off.
//
// Every entry here except Lock destroys work that is not saved, and the menu is
// one click from the bar. So the destructive ones are TWO steps: picking one
// replaces the list with a confirmation, and the confirmation is what runs it.
// The panel stays open between the two, which is the same "a menu answering
// with rows is navigation" behaviour the plugin menus use.
//
// Two steps rather than a modal dialogue, because a dialogue would be a second
// mechanism for a question this popover can already ask, and because a menu
// that closes and reopens somewhere else is how a misclick becomes a shutdown.
//
// Log out is the odd one: it dispatches `quit`, which the COMPOSITOR confirms
// with its own full-screen prompt. That is not a duplicate of the confirmation
// here -- it is the one that catches a `quit` from anywhere else, a keybind
// included -- so this menu hands over rather than asking twice.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    property var bar: null

    icons: ["asteroidz-bar/power.svg"]
    iconTint: Cfg.fg
    paddingX: 0
    fixedWidth: iconSize + 2 * Cfg.borderWidth + 1

    // Not a property of the menu: the popover is shared and rebuilds its rows,
    // so what is being confirmed has to outlive the row that asked.
    property var pendingAction: null

    // `systemctl` without --user: these are system transitions and polkit
    // decides whether this session may make them. A seat-local logged-in user
    // normally may, and where they may not, systemctl says so rather than this
    // module guessing.
    readonly property var actions: [
        {
            id: "lock",
            label: "Lock",
            // Straight through, no confirmation. Locking loses nothing, and a
            // "really lock?" step would make the one safe entry the slowest.
            confirm: "",
            run: () => Quickshell.execDetached(
                ["sh", "-c", "~/.config/asteroidz/scripts/lock.sh"])
        },
        {
            id: "logout",
            label: "Log out",
            confirm: "",   // the compositor asks; see the header
            run: () => Ipc.dispatch("dispatch quit")
        },
        {
            id: "suspend",
            label: "Suspend",
            confirm: "Suspend now?",
            run: () => Quickshell.execDetached(["systemctl", "suspend"])
        },
        {
            id: "hibernate",
            label: "Hibernate",
            confirm: "Hibernate now?",
            run: () => Quickshell.execDetached(["systemctl", "hibernate"])
        },
        {
            id: "reboot",
            label: "Restart",
            confirm: "Restart? Unsaved work in every window is lost.",
            run: () => Quickshell.execDetached(["systemctl", "reboot"])
        },
        {
            id: "poweroff",
            label: "Power off",
            confirm: "Power off? Unsaved work in every window is lost.",
            run: () => Quickshell.execDetached(["systemctl", "poweroff"])
        }
    ]

    function menuRows() {
        const rows = [];
        for (const a of actions) {
            if (a.id === "suspend")
                rows.push({ separator: true });
            rows.push({ text: a.label, act: () => root.choose(a) });
        }
        return rows;
    }

    // Picked from the list. Either it runs, or it asks.
    function choose(a) {
        if (!a.confirm) {
            a.run();
            return true;   // close the panel
        }
        root.pendingAction = a;
        if (bar)
            bar.showRows([
                { text: a.confirm, enabled: false },
                { separator: true },
                { text: "Yes, " + a.label.toLowerCase(),
                  act: () => { a.run(); return true; } },
                // Cancel goes BACK rather than closing. Landing here by
                // misclick should cost one more click, not the whole menu.
                { text: "Cancel", act: () => { root.pendingAction = null;
                                               root.bar.showRows(root.menuRows());
                                               return false; } }
            ]);
        return false;      // keep the panel open on the question
    }

    onClicked: button => {
        if (button !== Qt.LeftButton || !bar)
            return;
        if (bar.menuBelongsTo(root)) {
            bar.closeMenu();
            return;
        }
        pendingAction = null;
        bar.showMenu(root, menuRows());
    }
}
