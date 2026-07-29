// The clock.
//
// Pinned to the width of the widest time its format can ever produce, so the
// bar does not reflow every second as the digits change width -- and, with a
// centred section, so the whole centre group does not shuffle sideways once a
// minute. The native bar probes twelve sample dates for exactly this reason
// (month and weekday names vary in length); the same trick works here, just
// through a hidden Text rather than a Pango measurement.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    // SystemClock ticks on the second boundary rather than every 1000ms from
    // whenever the shell happened to start, so a seconds format does not drift
    // visibly against every other clock on the machine.
    SystemClock {
        id: clock
        precision: Cfg.clockFormat.includes("%S") ? SystemClock.Seconds
                                                  : SystemClock.Minutes
    }

    text: Qt.formatDateTime(clock.date, strftimeToQt(Cfg.clockFormat))
    // Same arithmetic a natural pill uses, or a pinned pill is a different
    // width than an unpinned one holding the same text.
    fixedWidth: Math.ceil(metrics.width) + 2 * paddingX
                + 2 * Cfg.borderWidth + 1

    // strftime is the compositor's format language (it hands the string
    // straight to strftime); Qt wants its own. Translating the handful of
    // specifiers a clock actually uses is better than either making the user
    // learn a second syntax for the same setting, or shelling out to `date`
    // once a second.
    function strftimeToQt(fmt) {
        const map = {
            "%H": "HH", "%I": "hh", "%M": "mm", "%S": "ss",
            "%p": "AP", "%P": "ap",
            "%Y": "yyyy", "%y": "yy",
            "%m": "MM", "%d": "dd", "%e": "d",
            "%b": "MMM", "%B": "MMMM", "%a": "ddd", "%A": "dddd",
            "%%": "%"
        };
        let out = "";
        for (let i = 0; i < fmt.length; i++) {
            if (fmt[i] === "%" && i + 1 < fmt.length) {
                const key = fmt.substring(i, i + 2);
                if (map[key] !== undefined) {
                    out += map[key];
                    i++;
                    continue;
                }
            }
            // Literal text has to be quoted or Qt reads letters in it as
            // format characters -- the "·" separator is safe, but the "a" in
            // a user's "%H:%M at %a" is not.
            out += /[A-Za-z]/.test(fmt[i]) ? "'" + fmt[i] + "'" : fmt[i];
        }
        return out;
    }

    // The widest the format gets: one probe per month, cycling the weekday
    // with it, plus wide digits everywhere numeric.
    TextMetrics {
        id: metrics
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
        font.weight: Cfg.fontWeight
        font.italic: Cfg.fontItalic
        text: {
            let widest = "";
            let best = 0;
            for (let m = 0; m < 12; m++) {
                const probe = new Date(2024, m, 22 + (m % 7), 22, 58, 58);
                const s = Qt.formatDateTime(probe,
                                            root.strftimeToQt(Cfg.clockFormat));
                if (s.length > best) {
                    best = s.length;
                    widest = s;
                }
            }
            return widest;
        }
    }
}
