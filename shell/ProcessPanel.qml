// `top`, in a popover.
//
// The cpu and memory pills used to open a five-row menu of totals -- two of
// which were the numbers the pills' own tint already conveyed. The question
// you actually have when a pill goes red is never "how red", it is "what is
// doing it", and that needed a list.
//
// Sorted by whichever pill you pressed: cpu opens by CPU, memory opens by
// memory, because the pill is the question. The header lets you change your
// mind without closing it.
//
// Sampling only runs while this is open (Processes.active), because walking
// /proc every two seconds to fill a list nobody has opened is exactly the idle
// cost this shell avoids elsewhere.

import Quickshell
import QtQuick
import Asteroidz.Bar
import "."

Item {
    id: root

    signal closeRequested()

    // Which column the panel was opened on: "cpu", "mem" or "net".
    property string sortBy: "cpu"

    implicitWidth: Cfg.processWidth
    implicitHeight: col.implicitHeight

    Component.onCompleted: {
        Processes.limit = Cfg.processLimit;
        Processes.intervalMs = Cfg.processInterval;
        Processes.sortBy = root.sortBy;
        Processes.active = true;
    }
    // Stop sampling the moment the panel goes away. Component.onDestruction
    // rather than a visibility binding: the popover destroys its content, and
    // a timer left running in a destroyed panel is a walk of /proc a second
    // for the rest of the session.
    Component.onDestruction: Processes.active = false

    function rate(bps) {
        if (bps >= 1048576) return (bps / 1048576).toFixed(1) + "M";
        if (bps >= 1024) return Math.round(bps / 1024) + "K";
        return Math.round(bps) + "B";
    }

    function human(bytes) {
        if (bytes >= 1073741824)
            return (bytes / 1073741824).toFixed(1) + "G";
        if (bytes >= 1048576)
            return Math.round(bytes / 1048576) + "M";
        return Math.round(bytes / 1024) + "K";
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // ── totals, and the sort ────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "CPU " + Processes.cpuPct + "%   RAM "
                      + root.human(Processes.memUsed) + " / " + root.human(Processes.memTotal)
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
                font.weight: Cfg.fontWeightEmphasis
                font.hintingPreference: Font.PreferFullHinting
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Repeater {
                    model: [
                        { label: "cpu", key: "cpu" },
                        { label: "mem", key: "mem" },
                        { label: "net", key: "net" },
                    ]

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on: Processes.sortBy === modelData.key

                        width: sortLabel.implicitWidth + 12
                        height: Math.max(18, Math.round(Cfg.fontPixelSize * 1.15))
                        radius: Cfg.themeRadius
                        color: on ? Cfg.focusBg
                             : sortHover.hovered ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.12)
                                                 : "transparent"

                        Text {
                            font.weight: Cfg.fontWeight
                            id: sortLabel
                            anchors.centerIn: parent
                            text: modelData.label
                            color: parent.on ? Cfg.focusFg : Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.hintingPreference: Font.PreferFullHinting
                        }
                        HoverHandler { id: sortHover; cursorShape: Qt.PointingHandCursor }
                        // Re-sorts the sample already in hand; it does not
                        // refetch, so changing your mind is free.
                        TapHandler { onTapped: Processes.sortBy = modelData.key }
                    }
                }
            }
        }

        // ── the list ────────────────────────────────────────────────────────
        Flickable {
            width: parent.width
            height: Math.min(rows.implicitHeight, Cfg.processHeight)
            contentWidth: width
            contentHeight: rows.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: rows
                width: parent.width
                spacing: 1

                Repeater {
                    model: Processes.list

                    delegate: Item {
                        id: row
                        required property var modelData
                        width: rows.width
                        height: Math.round(Cfg.fontPixelSize * 1.35)

                        // A bar behind the row rather than beside it: at this
                        // height a separate meter column would be three pixels
                        // tall and unreadable, where a tint behind the text
                        // reads at a glance and costs no width.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            height: parent.height
                            radius: Cfg.themeRadius
                            width: {
                                if (Processes.sortBy === "net") {
                                    // Relative to the busiest row, because there
                                    // is no "100%" for a network the way there is
                                    // for a core or for RAM.
                                    const top = Processes.list.length > 0
                                        ? Processes.list[0].rx + Processes.list[0].tx : 0;
                                    const mine = row.modelData.rx + row.modelData.tx;
                                    return top > 0 ? parent.width * Math.min(1, mine / top) : 0;
                                }
                                return parent.width * Math.min(1, (Processes.sortBy === "mem"
                                    ? row.modelData.memPct : row.modelData.cpu) / 100);
                            }
                            color: Qt.rgba(Cfg.focusBg.r, Cfg.focusBg.g, Cfg.focusBg.b, 0.22)
                        }

                        Text {
                            font.weight: Cfg.fontWeight
                            id: pidText
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(Cfg.fontPixelSize * 2.6)
                            text: row.modelData.pid
                            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                            horizontalAlignment: Text.AlignRight
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Text {
                            font.weight: Cfg.fontWeight
                            anchors.left: pidText.right
                            anchors.leftMargin: 8
                            anchors.right: cpuText.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.name
                            color: Cfg.fg
                            elide: Text.ElideRight
                            font.family: Cfg.fontFamily
                            // The row's subject, so the configured size. The
                            // pid and the figures beside it are the quiet half
                            // and stay a step down.
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Text {
                            font.weight: Cfg.fontWeight
                            id: cpuText
                            anchors.right: memText.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(Cfg.fontPixelSize * (Processes.sortBy === "net" ? 3.4 : 2.2))
                            horizontalAlignment: Text.AlignRight
                            text: Processes.sortBy === "net"
                                  ? "\u2193 " + root.rate(row.modelData.rx)
                                  : row.modelData.cpu.toFixed(1)
                            color: Processes.sortBy === "cpu"
                                   ? Cfg.fg
                                   : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Text {
                            font.weight: Cfg.fontWeight
                            id: memText
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(Cfg.fontPixelSize * (Processes.sortBy === "net" ? 3.4 : 2.4))
                            horizontalAlignment: Text.AlignRight
                            text: Processes.sortBy === "net"
                                  ? "\u2191 " + root.rate(row.modelData.tx)
                                  : root.human(row.modelData.mem)
                            color: Processes.sortBy === "mem"
                                   ? Cfg.fg
                                   : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSizeSmall
                            font.hintingPreference: Font.PreferFullHinting
                        }
                    }
                }
            }
        }

        // ── the network line the old menu carried ───────────────────────────
        //
        // Kept because it was there before this panel replaced that menu, and
        // losing a reading in a change that was supposed to ADD one would be a
        // poor trade. It is the network module's data, not this panel's.
        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            text: "↓ " + Metrics.rate(Metrics.rxRate) + "   ↑ " + Metrics.rate(Metrics.txRate)
                  + (Metrics.linkUp ? "" : "   (link down)")
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }
    }
}
