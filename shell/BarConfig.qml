pragma Singleton

// The bar's own settings.
//
// Everything about how this bar looks and behaves: its height and margins, its
// pills, its panel, its popovers, its idle timeouts, its plugins, and which
// modules go where. That is the BAR's business -- it is the only program that
// draws any of it.
//
// It used to arrive over IPC from the compositor's `bar {}` block, for one
// historical reason: the compositor used to draw the bar, so its config
// described one. That bar is gone, and sixty-two values went on being stored,
// clamped, described and served by a program that never read them. They are
// here now.
//
// What the compositor still serves, and should, is the THEME -- the palette
// matugen rewrites at runtime, which titlebars and the overview draw from too.
// A bar that read the palette from a file would stop matching the desktop the
// moment the wallpaper changed. See Cfg.qml.
//
// ── the format ──────────────────────────────────────────────────────────────
//
// KDL, like the compositor's config, so there is one config language on this
// desktop rather than two:
//
//     bar    { height 48; position "top" }
//     panel  { enable #true; radius 9; color "#0a0a0cd9" }
//     idle   { enable #true; dpms-timeout 300 }
//     custom "mail" { exec "checkmail"; interval 60 }
//     modules {
//         left   items="tags,layout,title" monitor=""
//         center items="media,clock"       monitor="DP-1"
//     }
//
// A deliberately narrow reader, not a KDL parser: blocks one level deep,
// holding either `key value` leaves or the `items=` properties the modules
// block uses. Nothing here nests further, and a general parser would be a
// parser to maintain forever. Anything it cannot make sense of is ignored
// rather than rejected -- a config file is not worth a bar that refuses to
// draw -- and every value has a working default, so the shell renders
// standalone with no config at all.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    readonly property string path:
        Quickshell.env("ASTEROIDZ_BAR_CONFIG")
        || (Quickshell.env("HOME") + "/.config/asteroidz-bar/config.kdl")

    // ── module placement ────────────────────────────────────────────────────

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

    // Re-read explicitly, not bound.
    //
    // FileView exposes its content as text(), a METHOD -- and a QML binding
    // tracks property reads, not calls, so a binding on it has no dependency
    // to be notified by and evaluates exactly once, whenever it happens to be
    // touched first. With `blockLoading` that can even be before the file has
    // been read, and the whole config silently stays at its defaults.
    //
    // So the parse is driven from both ends: Component.onCompleted covers the
    // load that already finished during construction, onLoaded covers every
    // reload after it. Either alone leaves a gap.
    property var sections: defaults
    property var groups: ({})
    property var custom: []

    function reparse() {
        try {
            const got = parse(conf.text() || "");
            sections = got.sections;
            groups = got.groups;
            custom = got.custom;
        } catch (e) {
            // A hand-edited file that no longer parses. The defaults draw a
            // usable bar, which is a better answer than no bar at all -- and
            // the file is left exactly as it is, so whatever is wrong with it
            // is still there to look at.
            console.warn("asteroidz-bar: cannot read " + path + ":", e);
            sections = defaults;
            groups = ({});
            custom = [];
        }
    }

    Component.onCompleted: reparse()

    // ── everything else ─────────────────────────────────────────────────────
    //
    // One object per block, holding whatever the file said. Read through the
    // typed accessors below rather than directly, so a missing key is the
    // default rather than `undefined` reaching a binding.
    function groupOf(g) {
        const v = groups[g];
        return (v && typeof v === "object") ? v : ({});
    }

    function numOf(g, key, fallback) {
        const v = groupOf(g)[key];
        if (v === undefined || v === null || v === "")
            return fallback;
        const n = Number(v);
        return isNaN(n) ? fallback : n;
    }

    function strOf(g, key, fallback) {
        const v = groupOf(g)[key];
        return (v === undefined || v === null || v === "") ? fallback : String(v);
    }

    // For values where EMPTY IS AN ANSWER -- a module list, where "" means
    // "draw nothing here" rather than "unset, use the default".
    function strOrEmptyOf(g, key, fallback) {
        const v = groupOf(g)[key];
        return (v === undefined || v === null) ? fallback : String(v);
    }

    // KDL spells booleans `#true` / `#false`; a config written by hand may well
    // say `true` or `1`. All three mean the same thing and none of them should
    // need looking up.
    function flagOf(g, key, fallback) {
        const v = groupOf(g)[key];
        if (v === undefined || v === null || v === "")
            return fallback;
        const s = String(v).toLowerCase();
        return s === "#true" || s === "true" || s === "1" || s === "yes";
    }

    // "#RRGGBBAA" or "#RRGGBB", the way a person writes a colour. The
    // compositor's IPC sends four floats instead, because a hex string has to
    // pick a byte order and CSS and Qt disagree -- but that argument is about
    // a WIRE format between two programs. In a file a human edits, hex is what
    // they will type, and there is only one reader.
    function colOf(g, key, fallback) {
        const v = groupOf(g)[key];
        if (v === undefined || v === null || v === "")
            return fallback;
        const s = String(v).replace(/^#/, "");
        if (s.length !== 6 && s.length !== 8)
            return fallback;
        const b = [];
        for (let i = 0; i < s.length; i += 2) {
            const n = parseInt(s.substr(i, 2), 16);
            if (isNaN(n))
                return fallback;
            b.push(n / 255);
        }
        return Qt.rgba(b[0], b[1], b[2], b.length === 4 ? b[3] : 1);
    }

    // ── the modules the bar can draw ────────────────────────────────────────
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
        for (const p of (custom || [])) {
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
    // Every mutation goes through save() so there is one place that writes the
    // file and one shape on disk. The whole document is rewritten rather than
    // patched: it is a couple of kilobytes, and a partial write is how a config
    // ends up describing a state that never existed.
    //
    // Rewriting does lose hand-written comments, which the compositor's own
    // writer goes to some length to preserve. The difference is who writes:
    // that file is edited by hand and occasionally by a settings page, this one
    // is the settings page's own store that can also be edited by hand.
    // Writing the file IS the update: the write triggers a reload, the reload
    // re-parses, and everything re-reads from what was actually stored rather
    // than from a copy kept alongside it that could disagree.
    function save(nextSections, nextGroups, nextCustom) {
        conf.setText(render(
            nextSections !== undefined ? nextSections : sections,
            nextGroups !== undefined ? nextGroups : groups,
            nextCustom !== undefined ? nextCustom : custom));
    }

    function setValue(group, key, value) {
        const g = ({});
        for (const k of Object.keys(groups))
            g[k] = Object.assign(({}), groups[k]);
        if (!g[group])
            g[group] = ({});
        g[group][key] = value;
        save(undefined, g, undefined);
    }

    // Quoted with escapes, because these are arbitrary text: a module name, a
    // plugin command, a clock format. `format "%H:%M"` is fine unquoted right
    // up until someone writes a space.
    function quote(v) {
        return "\"" + String(v).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
    }

    // Numbers bare, booleans as KDL spells them, everything else quoted.
    function literal(v) {
        if (typeof v === "number")
            return String(v);
        if (typeof v === "boolean")
            return v ? "#true" : "#false";
        const s = String(v);
        if (s === "#true" || s === "#false")
            return s;
        if (s !== "" && !isNaN(Number(s)))
            return s;
        return quote(s);
    }

    function render(sections, groups, custom) {
        let out = "// asteroidz-bar's own settings. Written by the settings\n"
                + "// window; hand edits are read back as they are.\n";

        for (const g of Object.keys(groups)) {
            const keys = Object.keys(groups[g] || ({}));
            if (keys.length === 0)
                continue;
            out += "\n" + g + " {\n";
            for (const k of keys)
                out += "\t" + k + " " + literal(groups[g][k]) + "\n";
            out += "}\n";
        }

        for (const c of (custom || [])) {
            if (!c || !c.name)
                continue;
            out += "\ncustom " + quote(c.name) + " {\n";
            for (const k of Object.keys(c)) {
                if (k === "name")
                    continue;
                out += "\t" + k + " " + literal(c[k]) + "\n";
            }
            out += "}\n";
        }

        out += "\nmodules {\n";
        for (const id of sectionIds) {
            const s = sections[id] || { items: [], monitor: "" };
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

    // ── reading ─────────────────────────────────────────────────────────────

    // KDL literals into the JS types the rest of the shell expects.
    //
    // These used to arrive as JSON from the compositor, already typed, and a
    // good deal of code reads them that way -- `if (plugin.continuous)` is
    // fine either way, but `interval` gets arithmetic done to it and a plugin
    // entry whose `continuous` is the STRING "#true" is truthy even when the
    // file says #false. Reading a config must not change what a value IS.
    //
    // A quoted string stays a string whatever it looks like: `format "12"` is
    // a clock format, not the number twelve.
    function coerce(v, wasQuoted) {
        if (wasQuoted)
            return v;
        if (v === "#true" || v === "true")
            return true;
        if (v === "#false" || v === "false")
            return false;
        if (v !== "" && !isNaN(Number(v)))
            return Number(v);
        return v;
    }

    function wasQuoted(raw) {
        const t = raw.trim().replace(/;$/, "").trim();
        return t.length >= 2 && t[0] === "\"" && t[t.length - 1] === "\"";
    }

    // Strip a trailing `;` and surrounding quotes, undoing render()'s escapes.
    function unquote(s) {
        let v = s.trim().replace(/;$/, "").trim();
        if (v.length >= 2 && v[0] === "\"" && v[v.length - 1] === "\"")
            v = v.slice(1, -1).replace(/\\(.)/g, "$1");
        return v;
    }

    // One pass, tracking which block we are inside. Blocks are one level deep
    // by construction, so a depth counter is enough and there is no stack.
    function parse(text) {
        const outSections = ({});
        for (const id of sectionIds)
            outSections[id] = { items: defaults[id].items.slice(), monitor: "" };
        const outGroups = ({});
        const outCustom = [];

        let block = "";        // the block we are inside, "" at top level
        let entry = null;      // the custom-plugin entry being filled

        // `rawLine`, not `raw`: the value branches below declare a `raw` of
        // their own, and re-declaring the loop binding's name inside its own
        // body confuses Qt's JS engine rather than shadowing cleanly -- the
        // inner one reads back as 0, and every parse threw
        // "Property 'trim' of object 0 is not a function" into the catch that
        // quietly substitutes the defaults.
        for (const rawLine of text.split("\n")) {
            let line = rawLine.trim();
            if (line === "" || line.startsWith("//") || line.startsWith("/*"))
                continue;

            if (line === "}" || line === "};") {
                if (entry) {
                    outCustom.push(entry);
                    entry = null;
                }
                block = "";
                continue;
            }

            // `name {` or `custom "name" {` opens a block.
            if (line.endsWith("{")) {
                const head = line.slice(0, -1).trim();
                const parts = head.split(/\s+/);
                if (parts[0] === "custom" && parts.length > 1) {
                    entry = { name: unquote(parts.slice(1).join(" ")) };
                    block = "custom";
                } else {
                    block = parts[0];
                    if (block !== "modules" && !outGroups[block])
                        outGroups[block] = ({});
                }
                continue;
            }

            if (block === "modules") {
                const head = line.split(/\s+/)[0];
                if (sectionIds.indexOf(head) < 0)
                    continue;
                const items = prop(line, "items");
                const monitor = prop(line, "monitor");
                outSections[head] = {
                    items: items === null ? defaults[head].items.slice()
                         : items.split(",").map(x => x.trim())
                                .filter(x => x !== ""),
                    monitor: monitor === null ? "" : monitor
                };
                continue;
            }

            if (block === "") {
                // A one-line block, `panel { enable #true; radius 9 }`.
                const m = line.match(/^([A-Za-z_][\w-]*)\s*\{(.*)\}\s*;?$/);
                if (m) {
                    const g = m[1];
                    if (!outGroups[g])
                        outGroups[g] = ({});
                    for (const part of m[2].split(";")) {
                        const kv = part.trim().split(/\s+/);
                        if (kv.length >= 2) {
                            const raw = kv.slice(1).join(" ");
                            outGroups[g][kv[0]] =
                                coerce(unquote(raw), wasQuoted(raw));
                        }
                    }
                }
                continue;
            }

            // `key value` inside a block.
            const sp = line.indexOf(" ");
            if (sp < 0)
                continue;
            const key = line.slice(0, sp).trim();
            const raw = line.slice(sp + 1);
            const value = coerce(unquote(raw), wasQuoted(raw));
            if (entry)
                entry[key] = value;
            else if (outGroups[block])
                outGroups[block][key] = value;
        }
        if (entry)
            outCustom.push(entry);

        return { sections: outSections, groups: outGroups, custom: outCustom };
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
        // Read synchronously, because the bar is built from it. Loaded async
        // the first frame comes from the defaults and the real values arrive a
        // moment later, so every module is created, destroyed and created
        // again -- wasteful for anything that starts a process when it
        // appears, and a visible flicker of the wrong bar regardless.
        blockLoading: true
        // Without this the file is not read until something asks for it, and
        // what asks first is a binding that then gets "".
        preload: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.reparse()
        // A missing or unreadable file parses as "" -- which is the defaults,
        // and is what a first run should draw.
        onLoadFailed: root.reparse()
    }
}
