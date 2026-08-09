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

    icons: [kind === "cpu" ? "asteroidz-bar/sysinfo/cpu.svg"
                           : "asteroidz-bar/sysinfo/mem.svg"]
    iconTint: Metrics.loadTint(pct)
    // Icon-only pills carry no padding of their own: the run is spaced by an
    // exact gap instead, because padding is symmetric and would also pad the
    // ends of the run against the panel edge.
    paddingX: 0

    property var bar: null

    // The tint says which BAND you are in; the panel says what is causing it.
    //
    // It used to open a five-row menu of totals, two of which were the numbers
    // this pill's own tint already conveys. "How busy" is not the question you
    // have when a pill goes red -- "what is doing it" is -- so it opens `top`
    // instead, sorted by whichever pill you pressed.
    onClicked: button => {
        if (button !== Qt.LeftButton || !bar)
            return;
        bar.showPanel(root, processes);
    }

    Component {
        id: processes
        // `bar` resolves here and not inside ProcessPanel.qml: a Component
        // captures the scope it is DECLARED in, and the panel is a separate
        // file that knows nothing about the bar hosting it.
        ProcessPanel {
            sortBy: root.kind === "memory" ? "mem" : "cpu"
            onCloseRequested: bar.closeMenu()
        }
    }
}
