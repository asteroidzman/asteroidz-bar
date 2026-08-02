pragma Singleton

// The bar's own settings.
//
// Which modules the bar draws, in which section, in what order, and on which
// output. That is the BAR's business, not the compositor's -- it draws none of
// it and cannot -- so it lives in the bar's own file rather than being carried
// across an IPC from a `bar {}` block in the compositor's config.
//
// It was carried across, for one historical reason: the compositor used to draw
// the bar itself, so its config described one. That bar is gone. What the
// compositor still legitimately owns and this still reads over `bar-config` is
// what is genuinely COMPOSITOR state -- the palette, the tags, the layout, the
// focused window -- and the geometry the compositor has to agree with because
// it reserves the space.
//
// ── the format ──────────────────────────────────────────────────────────────
//
// KDL, like the compositor's config, so there is one config language on this
// desktop rather than two.
//
// A deliberately narrow slice of it -- one node per section, carrying
// properties -- because there is no KDL parser in QML and writing a general one
// to store three lists and three strings would be a parser to maintain forever.
// What is written here is valid KDL that the compositor's own parser reads, and
// what is read back is this exact shape:
//
//     modules {
//         left   items="tags,layout,title" monitor=""
//         center items="media,clock"       monitor="DP-1"
//         right  items="volume,power"      monitor=""
//     }
//
// Anything else in the file is ignored rather than rejected, and a line this
// cannot make sense of leaves that section at its default -- a config file is
// not worth a bar that refuses to draw.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    readonly property string path:
        Quickshell.env("ASTEROIDZ_BAR_CONFIG")
        || (Quickshell.env("HOME") + "/.config/asteroidz-bar/config.kdl")

    // The sections, in the order a bar reads left to right. Named rather than
    // indexed so the file says what it means.
    readonly property var sectionIds: ["left", "center", "right"]

    // What a fresh install draws. Not read from the compositor: a default is a
    // decision this program makes about itself.
    readonly property var defaults: ({
        left: { items: ["tags", "layout", "title"], monitor: "" },
        center: { items: ["clock"], monitor: "" },
        right: { items: [], monitor: "" }
    })

    property var sections: defaults

    // The module names this bar can draw, for a settings page that has to offer
    // them, plus whatever plugins the compositor reports -- those are named by
    // whoever wrote them and cannot be known here.
    //
    // This list must match the `case` labels in modules/ModuleLoader.qml, which
    // is the one place that decides what a name resolves to. A name here that is
    // not there resolves to null: the settings page offers it, the user adds it,
    // and nothing appears -- with no error, because "no component" is how an
    // intentionally hidden module looks too. `spectrum` was exactly that for as
    // long as this list existed; it is a child of the media pill, not a module.
    // contrib/settings-test.sh compares the two and fails on any drift.
    readonly property var builtins: [
        "tags", "layout", "title", "clock", "battery", "network", "volume",
        "media", "idle", "notify", "weather", "tray", "power",
        "cpu", "memory"
    ]

    readonly property var available: {
        const out = builtins.slice();
        for (const p of (Cfg.custom || [])) {
            const n = p.name || "";
            if (n !== "")
                out.push("custom/" + n);
        }
        return out;
    }

    function itemsOf(section) {
        const s = sections[section];
        return (s && s.items) ? s.items : [];
    }

    function monitorOf(section) {
        const s = sections[section];
        return (s && s.monitor) ? s.monitor : "";
    }

    // Where a module currently sits, or "" if nowhere.
    function sectionOf(name) {
        for (const id of sectionIds)
            if (itemsOf(id).indexOf(name) >= 0)
                return id;
        return "";
    }

    // ── writing ─────────────────────────────────────────────────────────────
    //
    // Every mutation goes through here so there is one place that writes the
    // file and one shape on disk. The whole document is rewritten rather than
    // patched: it is a few hundred bytes, and a partial write is how a config
    // ends up describing a state that never existed.
    function save(next) {
        sections = next;
        conf.setText(render(next));
    }

    // Quoted with escapes, because a module name is arbitrary text: a plugin is
    // named by whoever wrote it and `custom/my "thing"` would otherwise produce
    // a file that does not parse.
    function quote(v) {
        return "\"" + String(v).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
    }

    function render(next) {
        let out = "// asteroidz-bar's own settings. Written by the settings\n"
                + "// window; hand edits are read back as they are.\n"
                + "modules {\n";
        for (const id of sectionIds) {
            const s = next[id] || { items: [], monitor: "" };
            out += "\t" + id
                 + " items=" + quote((s.items || []).join(","))
                 + " monitor=" + quote(s.monitor || "")
                 + "\n";
        }
        return out + "}\n";
    }

    function setMonitor(section, name) {
        const next = clone();
        next[section].monitor = name;
        save(next);
    }

    // Put `name` into `section` at `index`, taking it out of wherever it was.
    // One operation, because moving between sections and reordering within one
    // are the same act and doing them as two writes can leave a module in
    // neither.
    function place(name, section, index) {
        const next = clone();
        for (const id of sectionIds) {
            const at = next[id].items.indexOf(name);
            if (at >= 0)
                next[id].items.splice(at, 1);
        }
        const items = next[section].items;
        const to = Math.max(0, Math.min(index, items.length));
        items.splice(to, 0, name);
        save(next);
    }

    function remove(name) {
        const next = clone();
        for (const id of sectionIds) {
            const at = next[id].items.indexOf(name);
            if (at >= 0)
                next[id].items.splice(at, 1);
        }
        save(next);
    }

    function move(name, delta) {
        const id = sectionOf(name);
        if (id === "")
            return;
        const at = itemsOf(id).indexOf(name);
        place(name, id, at + delta);
    }

    // A deep copy, because splicing the live object would mutate what the UI is
    // bound to without the binding ever being told.
    function clone() {
        const out = ({});
        for (const id of sectionIds) {
            out[id] = {
                items: itemsOf(id).slice(),
                monitor: monitorOf(id)
            };
        }
        return out;
    }

    // One line per section, `<id> items="a,b" monitor="X"`. Comments and
    // anything unrecognised are skipped.
    function parse(text) {
        const out = ({});
        for (const id of sectionIds)
            out[id] = { items: defaults[id].items.slice(), monitor: "" };

        for (const raw of text.split("\n")) {
            const line = raw.trim();
            if (line === "" || line.startsWith("//") || line.startsWith("/*"))
                continue;
            const head = line.split(/\s+/)[0];
            if (sectionIds.indexOf(head) < 0)
                continue;

            const items = prop(line, "items");
            const monitor = prop(line, "monitor");
            out[head] = {
                items: items === null ? defaults[head].items.slice()
                     : items.split(",").map(x => x.trim()).filter(x => x !== ""),
                monitor: monitor === null ? "" : monitor
            };
        }
        return out;
    }

    // `key="value"` off one line, with the escapes render() writes. Returns
    // null when the property is absent, which is different from empty: absent
    // means "say nothing about this", empty means "every screen".
    function prop(line, key) {
        const m = line.match(new RegExp(key + '=\"((?:[^\"\\\\]|\\\\.)*)\"'));
        if (m === null)
            return null;
        return m[1].replace(/\\(.)/g, "$1");
    }

    FileView {
        id: conf
        path: root.path
        // Read synchronously, because the bar is built from it. Loaded
        // asynchronously, the first frame is drawn from the DEFAULTS and the
        // real sections arrive a moment later, so every module is created,
        // destroyed and created again -- harmless for a clock, wasteful for
        // anything that starts a process when it appears, and a visible flicker
        // of the wrong bar either way.
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root.sections = root.parse(text());
            } catch (e) {
                // A hand-edited file that no longer parses. The defaults draw a
                // usable bar, which is a better answer than no bar at all --
                // and the file is left exactly as it is, so whatever is wrong
                // with it is still there to look at.
                console.warn("asteroidz-bar: cannot read " + root.path + ":", e);
                root.sections = root.defaults;
            }
        }
        onLoadFailed: root.sections = root.defaults
    }
}
