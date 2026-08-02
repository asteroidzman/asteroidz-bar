pragma Singleton

// The battery, read straight from sysfs.
//
// Named ...Service rather than Battery, like IdleService beside Idle: the
// module in shell/modules/ is called Battery, and two types of one name in
// directories that are both imported is ambiguous -- which QML reports as the
// IMPORTING type being unavailable, four levels away from the cause.
//
// A singleton rather than state inside the module, for the reason Metrics is
// one: a second monitor means a second bar, and two modules polling the same two
// files twice a second is work for one answer.
//
// No upower, no D-Bus. `capacity` and `status` are two small files the kernel
// keeps current, and a daemon in between would be a dependency, a service to be
// running, and a second description of what those files already say. asteroidz
// has no battery dependency and this does not add one.
//
// ── which battery ───────────────────────────────────────────────────────────
//
// There is no directory listing in QML, so the name cannot be discovered -- it
// is asked for. The list below is the names Linux actually uses: BAT0..BAT2 on
// almost everything, CMB0 on some older ACPI firmware, macsmc-battery on Apple
// silicon. A machine whose battery is called something else reports no battery,
// which is the same outcome as having none and is visibly nothing rather than
// visibly wrong.
//
// Paths.resolve caches its answer, misses included, so a machine that GAINS a
// battery after the bar started keeps saying it has none until the bar restarts.
// That is a laptop having its cell replaced, not a case worth a second file
// system scan every two seconds.

import Quickshell
import Quickshell.Io
import QtQuick
import Asteroidz.Bar
import "."

Singleton {
    id: root

    // Where to look. Overridable so this can be tested at all: the machine this
    // was written on has no battery -- /sys/class/power_supply is empty -- and a
    // module that can only be exercised on other hardware is a module nobody
    // checks. contrib/battery-test.sh points this at a directory it writes.
    readonly property string base:
        Quickshell.env("ASTEROIDZ_BAR_BATTERY_DIR") || "/sys/class/power_supply"

    readonly property var names: ["BAT0", "BAT1", "BAT2", "CMB0",
                                  "macsmc-battery"]

    // The first of those that exists, as a plain path. Paths.resolve answers
    // with a file: URL because its usual caller is an Image; FileView wants a
    // path.
    readonly property string dir: {
        const url = Paths.resolve(names.map(n => base + "/" + n + "/capacity"));
        if (url === "")
            return "";
        return url.replace(/^file:\/\//, "").replace(/\/capacity$/, "");
    }

    readonly property bool present: dir !== ""

    property int pct: -1
    property string status: ""

    readonly property bool charging:
        status === "Charging" || status === "Full"
    // "Not charging" is a real fourth state and not a synonym for discharging:
    // it is what a plugged-in laptop says once the cell is at its charge limit.
    // Calling it discharging would put a draining icon on a machine on mains.
    readonly property bool onMains:
        charging || status === "Not charging"

    FileView {
        id: capacityFile
        path: root.dir === "" ? "" : root.dir + "/capacity"
        blockLoading: true
    }
    FileView {
        id: statusFile
        path: root.dir === "" ? "" : root.dir + "/status"
        blockLoading: true
    }

    function sample() {
        if (!present)
            return;
        capacityFile.reload();
        statusFile.reload();
        const c = parseInt(capacityFile.text(), 10);
        if (!isNaN(c))
            pct = Math.max(0, Math.min(100, c));
        status = statusFile.text().trim();
    }

    // The bar's own interval, like every other polled reading here. A battery
    // moves by one percent in minutes, so this is already far more often than it
    // changes -- but sharing the tick keeps one timer for the whole shell.
    Timer {
        interval: Math.max(1, Cfg.interval) * 1000
        running: root.present
        repeat: true
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    // Charging outranks the level: what a bolt says is "this is going up", which
    // is the fact that decides whether a low reading is a problem.
    readonly property string icon: {
        if (!present)
            return "";
        if (charging)
            return "asteroidz-bar/battery/battery-charging.svg";
        if (pct >= 95) return "asteroidz-bar/battery/battery-full.svg";
        if (pct >= 75) return "asteroidz-bar/battery/battery-90.svg";
        if (pct >= 45) return "asteroidz-bar/battery/battery-60.svg";
        if (pct >= 20) return "asteroidz-bar/battery/battery-30.svg";
        return "asteroidz-bar/battery/battery-10.svg";
    }

    // The same four bands the metrics use, inverted: for a battery it is the LOW
    // end that is urgent, where for cpu and memory it is the high end. Anything
    // on mains is unremarkable whatever the number, because it is going up.
    readonly property color tint: {
        if (onMains || pct >= 40)
            return Cfg.fg;
        if (pct >= 20)
            return Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.75);
        return Cfg.urgent;
    }

    // "72%", or "72% · charging". The pill shows the number; the popover is
    // where the rest goes.
    readonly property string label: present && pct >= 0 ? pct + "%" : ""
}
