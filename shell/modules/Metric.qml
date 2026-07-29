// cpu and memory: one glyph each, and the TINT is the reading.
//
// No text, deliberately. These sit in a tight run of artwork on the right, and
// a percentage beside each would double the width of the group for a number
// nobody reads continuously -- the four colour bands say "resting / working /
// heavy / saturated" at a glance, which is what a bar is for. The popover is
// where the numbers live.

import QtQuick
import ".."

Pill {
    id: root

    // "cpu" or "memory"
    property string kind: "cpu"

    readonly property int pct:
        kind === "cpu" ? Metrics.cpuPct : Metrics.memPct

    icons: [kind === "cpu" ? "waybar-sysinfo/cpu.svg"
                           : "waybar-sysinfo/mem.svg"]
    iconTint: Metrics.loadTint(pct)
    // Icon-only pills carry no padding of their own: the run is spaced by an
    // exact gap instead, because padding is symmetric and would also pad the
    // ends of the run against the panel edge.
    paddingX: 0
}
