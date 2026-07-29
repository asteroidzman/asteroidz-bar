pragma Singleton

// Everything the bar knows about the compositor, from ONE subscription.
//
// `watch all-monitors` carries, per output: the tag list with occupancy,
// selection and urgency, the layout symbol, the focused client's title and app
// id, and which output is focused. And it is pushed on tag switches, focus
// changes and title changes -- handle_print_status() re-broadcasts all-monitors
// for ALL_MONITORS, KEYMODE, KB_LAYOUT, FOCUSED_CLIENT and TAGS alike -- so
// three modules that would each have wanted their own watch share one.
//
// The client list is a second subscription because it is not in that payload
// and is needed for one thing only: the app icons drawn inside tag pills.

import Quickshell
import QtQuick
import "."

Singleton {
    id: root

    // name -> monitor object, as delivered.
    property var monitors: ({})
    // Every client, for tag icons: [{appid, tags, monitor}, ...]
    property var clients: []
    property string focusedMonitor: ""

    // A change counter, because a JS object property does not notify on
    // mutation and QML bindings on monitors[name] would go stale. Everything
    // that reads compositor state depends on this instead.
    property int generation: 0

    function monitor(name) {
        return monitors[name] || null;
    }

    // The tags this output should show a pill for, in the order it should show
    // them, with the state each pill needs. Mirrors bar_module_refresh_tags:
    // every tag that is selected or holds a window, then padded with the
    // lowest-numbered empty tags up to `min-tags`.
    function visibleTags(screenName) {
        void generation;
        const mon = monitor(screenName);
        if (!mon || !mon.tags)
            return [];

        const show = [];
        let relevant = 0;
        for (let i = 0; i < mon.tags.length; i++) {
            const t = mon.tags[i];
            const on = Cfg.showAllTags || t.is_active || t.client_count > 0;
            show.push(on);
            if (on)
                relevant++;
        }
        for (let i = 0; i < mon.tags.length && relevant < Cfg.minTags; i++) {
            if (!show[i]) {
                show[i] = true;
                relevant++;
            }
        }

        const out = [];
        for (let i = 0; i < mon.tags.length; i++) {
            if (!show[i])
                continue;
            const t = mon.tags[i];
            out.push({
                index: t.index,
                // "3" normally, "3: name" once the tag is worth naming -- a
                // renamed tag nobody is using is noise, which is why the
                // native module gates the name on selected||occupied too.
                label: (t.is_active || t.client_count > 0)
                       && t.name !== String(t.index)
                    ? t.index + ": " + t.name
                    : String(t.index),
                active: t.is_active,
                urgent: t.is_urgent,
                occupied: t.client_count > 0,
                icons: Cfg.tagIcons > 0
                    ? appIcons(screenName, t.index, Cfg.tagIcons)
                    : []
            });
        }
        return out;
    }

    // App ids of the first `limit` windows on a tag, for the icons drawn
    // inside its pill.
    function appIcons(screenName, tag, limit) {
        const out = [];
        for (let i = 0; i < clients.length && out.length < limit; i++) {
            const c = clients[i];
            if (c.monitor !== screenName)
                continue;
            if (!c.tags || c.tags.indexOf(tag) < 0)
                continue;
            if (c.appid)
                out.push(c.appid);
        }
        return out;
    }

    function layoutSymbol(screenName) {
        void generation;
        const mon = monitor(screenName);
        return mon ? (mon.layout_symbol || "") : "";
    }

    function layoutIndex(screenName) {
        void generation;
        const mon = monitor(screenName);
        return mon ? (mon.layout_index || 0) : 0;
    }

    function activeClient(screenName) {
        void generation;
        const mon = monitor(screenName);
        return mon ? mon.active_client : null;
    }

    Component.onCompleted: {
        Ipc.watch("watch all-monitors", obj => {
            if (!obj.monitors)
                return;
            const map = {};
            let focused = "";
            for (const m of obj.monitors) {
                map[m.name] = m;
                if (m.active)
                    focused = m.name;
            }
            root.monitors = map;
            root.focusedMonitor = focused;
            root.generation++;
        });

        Ipc.watch("watch all-clients", obj => {
            if (!obj.clients)
                return;
            root.clients = obj.clients;
            root.generation++;
        });
    }
}
