pragma Singleton

// CPU, memory and network, read straight out of /proc.
//
// One sampler for the whole machine, not one per output: these readings are
// machine-wide, so two monitors must not mean two reads of /proc. The native
// bar states the same rule for the same reason.
//
// No subprocesses. This is the set of modules that was always cheap to run in
// the compositor -- `/proc` and `/sys`, no D-Bus, no network, no fork -- and
// it stays cheap here: FileView reads the file, the deltas are arithmetic, and
// nothing is spawned per tick. The waybar plugins these replace forked wpctl
// and nmcli on their main loop, which is what made them expensive.

import Quickshell
import Quickshell.Io
import QtQuick
import "."

Singleton {
    id: root

    property int cpuPct: 0
    property int memPct: 0
    property real rxRate: 0     // bytes/second
    property real txRate: 0
    property bool linkUp: false

    // Previous sample, for the deltas. /proc/stat and /proc/net/dev are
    // counters since boot; a rate needs two readings and the time between.
    property var prevCpu: null
    property var prevNet: null
    property double prevAt: 0

    readonly property int intervalMs: Math.max(1, Cfg.interval) * 1000

    FileView { id: statFile; path: "/proc/stat"; blockLoading: true }
    FileView { id: memFile; path: "/proc/meminfo"; blockLoading: true }
    FileView { id: netFile; path: "/proc/net/dev"; blockLoading: true }

    function sampleCpu() {
        const line = statFile.text().split("\n")[0];
        if (!line || !line.startsWith("cpu "))
            return;
        const f = line.split(/\s+/).slice(1).map(Number);
        // user nice system idle iowait irq softirq steal
        const idle = (f[3] || 0) + (f[4] || 0);
        let total = 0;
        for (let i = 0; i < 8 && i < f.length; i++)
            total += f[i] || 0;

        if (prevCpu) {
            const dTotal = total - prevCpu.total;
            const dIdle = idle - prevCpu.idle;
            if (dTotal > 0)
                cpuPct = Math.round(100 * (dTotal - dIdle) / dTotal);
        }
        prevCpu = { total: total, idle: idle };
    }

    function sampleMem() {
        let total = 0, avail = 0;
        for (const line of memFile.text().split("\n")) {
            if (line.startsWith("MemTotal:"))
                total = parseInt(line.split(/\s+/)[1]);
            else if (line.startsWith("MemAvailable:"))
                avail = parseInt(line.split(/\s+/)[1]);
            if (total && avail)
                break;
        }
        // MemAvailable, not MemFree: free counts the page cache as used, which
        // pins the reading at "full" on any machine that has been up a while
        // and makes the module useless.
        if (total > 0)
            memPct = Math.round(100 * (total - avail) / total);
    }

    function sampleNet() {
        let rx = 0, tx = 0, up = false;
        const lines = netFile.text().split("\n");
        for (let i = 2; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line)
                continue;
            const parts = line.split(/:\s*/);
            if (parts.length < 2)
                continue;
            const iface = parts[0].trim();
            // Loopback is not a link and would report every local connection
            // as traffic; virtual bridges and containers are not this
            // machine's uplink either.
            if (iface === "lo" || iface.startsWith("veth")
                || iface.startsWith("docker") || iface.startsWith("br-"))
                continue;
            const f = parts[1].split(/\s+/).map(Number);
            rx += f[0] || 0;
            tx += f[8] || 0;
            if ((f[0] || 0) > 0 || (f[8] || 0) > 0)
                up = true;
        }

        const now = Date.now() / 1000.0;
        if (prevNet && prevAt > 0 && now > prevAt) {
            const dt = now - prevAt;
            rxRate = Math.max(0, (rx - prevNet.rx) / dt);
            txRate = Math.max(0, (tx - prevNet.tx) / dt);
        }
        prevNet = { rx: rx, tx: tx };
        prevAt = now;
        linkUp = up;
    }

    function sample() {
        statFile.reload();
        memFile.reload();
        netFile.reload();
        sampleCpu();
        sampleMem();
        sampleNet();
    }

    Timer {
        interval: root.intervalMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    // ── how a reading is shown ──────────────────────────────────────────────

    // Amber for "heavy". Not a theme colour because the theme has no word for
    // it; the native bar carries the same literal for the same reason.
    readonly property color amber: Qt.rgba(0.898, 0.631, 0.039, 1.0)

    // The tint IS the reading for cpu and memory -- these pills draw no text,
    // so the four bands have to be distinguishable at a glance.
    function loadTint(pct) {
        if (pct >= 85)
            return Cfg.urgent;
        if (pct >= 60)
            return amber;
        if (pct >= 20)
            return Cfg.focusBg;
        return Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45);
    }

    // Throughput bands, as fractions of the configured line speed when there
    // is one: "busy" only means anything relative to what the line can do. The
    // fixed bands top out at 4 MiB/s, which on a 266 Mbit connection pinned
    // both arrows saturated for any real download.
    //
    // The "active" band keeps its absolute floor either way -- a percentage
    // first step on a fast line would be tens of KB/s, and the whole point of
    // the dimmest state is to show that something is happening at all.
    function netTier(bytesPerSec, maxMbit) {
        if (maxMbit > 0) {
            const cap = maxMbit * 1000000.0 / 8.0;
            if (bytesPerSec >= cap * 0.65)
                return 3;
            if (bytesPerSec >= cap * 0.20)
                return 2;
            if (bytesPerSec >= 8 * 1024)
                return 1;
            return 0;
        }
        if (bytesPerSec >= 4 * 1024 * 1024)
            return 3;
        if (bytesPerSec >= 512 * 1024)
            return 2;
        if (bytesPerSec >= 8 * 1024)
            return 1;
        return 0;
    }

    function tierColor(tier) {
        switch (tier) {
        case 3: return Cfg.urgent;
        case 2: return amber;
        case 1: return Cfg.focusBg;
        // unlit, like a dark LED
        default: return Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.35);
        }
    }

    // A down link lights BOTH arrows in the urgent colour rather than showing a
    // separate disconnected glyph: the pair going red is the reading.
    readonly property int upTier:
        linkUp ? netTier(txRate, Cfg.netMaxUp) : 3
    readonly property int downTier:
        linkUp ? netTier(rxRate, Cfg.netMaxDown) : 3
}
