pragma Singleton

// How often each thing has been launched, so the launcher can put what you
// actually use at the top.
//
// This is the difference between a launcher and a list. `dis` matches Discord,
// Disk Usage Analyzer and a dozen others equally well by any string measure,
// and the one you meant is the one you open every day -- there is no way to
// know that from the query. Alphabetical order is a fair way of being wrong.
//
// A COUNT, not a decayed score, despite the name this file inherited from the
// idea. Decay would need a timestamp per entry and a policy for how fast to
// forget, and neither is observable from the outside: the only evidence anyone
// has that it works is that the thing they expected is first. A count does that
// and can be reasoned about.
//
// The CACHE, not the config. Nobody edits it, nothing else reads it, and losing
// it costs a few days of ordinary use to rebuild. Writing it to ~/.config would
// mean a file that changes every time an application is launched sitting in a
// directory people keep in version control.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    readonly property string path:
        (Quickshell.env("XDG_CACHE_HOME")
         || (Quickshell.env("HOME") + "/.cache"))
        + "/asteroidz-bar/launcher-uses.json"

    property var counts: ({})

    function count(key) {
        const n = root.counts[key];
        return n === undefined ? 0 : n;
    }

    function record(key) {
        if (!key)
            return;
        // A new object rather than a mutation: QML does not see a property
        // change when the contents of the same object change, so every binding
        // reading these counts would keep the value it first computed.
        const next = ({});
        for (const k in root.counts)
            next[k] = root.counts[k];
        next[key] = (next[key] || 0) + 1;
        root.counts = next;
        saveDebounce.restart();
    }

    // Debounced, because launching is a burst: the record happens on the same
    // frame as the window closing and the process starting, and a synchronous
    // write there is a write in the middle of the one interaction where any
    // delay is visible.
    Timer {
        id: saveDebounce
        interval: 500
        onTriggered: writer.setText(JSON.stringify(root.counts))
    }

    FileView {
        id: reader
        path: root.path
        preload: true
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                if (parsed && typeof parsed === "object")
                    root.counts = parsed;
            } catch (e) {
                // A corrupt cache is not worth a word to anyone: it rebuilds
                // itself from the next few launches.
                root.counts = ({});
            }
        }
    }

    FileView {
        id: writer
        path: root.path
        preload: false
        atomicWrites: true
        printErrors: false
    }
}
