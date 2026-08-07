// The battery: a cell, its level, and whether it is going up.
//
// Absent on a machine with no battery, rather than drawn empty or drawn at zero.
// A desktop that shows a permanently full battery is saying something false
// about hardware it does not have, and one that shows 0% is saying something
// alarming. The idle cup hides itself on the same principle -- a control for
// something that is not happening is worse than no control.
//
// Text as well as artwork, unlike the cpu and memory pills beside it. Those are
// bands you glance at; a battery percentage is a number people actually read,
// which is why the volume pill carries its number too.
//
// The reading lives in the BatteryService singleton, named that way for the
// reason IdleService is: a module and a singleton with the same name are
// ambiguous to anything importing both directories, and ModuleLoader imports
// both. The clash does not report itself as a clash -- it surfaces as "Type
// ModuleLoader unavailable" and a bar that is simply not there.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    property var bar: null

    visible: BatteryService.present

    icons: BatteryService.present ? [BatteryService.icon] : []
    iconTint: BatteryService.tint
    text: BatteryService.label
    // Icon-and-text, so this one keeps the theme's padding rather than the zero
    // the icon-only pills use.
    paddingX: Cfg.pillPadding

    onClicked: button => {
        if (button !== Qt.LeftButton || !bar)
            return;
        bar.showMenu(root, [
            { text: "Charge    " + (BatteryService.pct >= 0 ? BatteryService.pct + "%" : "—"),
              enabled: false },
            // The kernel's own word, not a translation of it. "Not charging" is
            // a state of its own -- plugged in and holding at a charge limit --
            // and rewording it as "discharging" would be wrong about a machine
            // sitting on mains.
            { text: "State     " + (BatteryService.status || "unknown"),
              enabled: false }
        ]);
    }
}
