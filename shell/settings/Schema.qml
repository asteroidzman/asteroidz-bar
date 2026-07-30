pragma Singleton

// The compositor's configuration, as data.
//
// asteroidz publishes a machine-readable schema of every option it accepts --
// type, range, enum members, default, group, and a human description -- plus
// the resolved value of each and WHERE that value came from. This singleton is
// the whole of the bar's knowledge of that: it fetches, keeps it live, and
// submits changes back. Nothing here parses KDL, and nothing here knows what
// any individual option means.
//
// That division is the reason this is affordable. The alternative -- a settings
// UI with its own table of options, ranges and defaults -- is a second
// description of the config that agrees with the compositor's until one of them
// gains an option, and then silently writes values the compositor clamps or
// rejects. Here, an option added to `config-schema.h` appears in this window
// with its label and explanation and no QML change at all.
//
// Loaded LAZILY, on first use. The bar holds ~95 options and their provenance
// only once you open the settings window; a bar that never opens it never pays
// for the fetch. It is one 24 KB read over a unix socket, so there is no disk
// cache -- adding one would be a staleness bug in exchange for nothing.

import Quickshell
import QtQuick
import ".."

Singleton {
    id: root

    // ── the schema ──────────────────────────────────────────────────────────

    // Ordered as the compositor declares them, which is the order they are
    // meant to be presented in -- the group list is curated over there, so
    // sorting it here would throw away the one piece of information a schema
    // cannot express as a field.
    property var groups: []
    property var options: []
    property var byKey: ({})
    property string digest: ""
    property bool schemaLoaded: false

    // ── the values ──────────────────────────────────────────────────────────
    //
    // key -> { value, rgba?, is_default, source: { kind, file, line, path,
    //          writable, reason? } }
    //
    // `value` is always the string a user would write, for every type. The UI
    // converts on the way into a control and converts back on the way out, so
    // there is exactly one representation crossing the socket and no argument
    // about whether a colour is #RRGGBBAA or #AARRGGBB. Colours additionally
    // carry `rgba` as four floats, because Qt wants floats to paint with and a
    // string to round-trip through, and deriving one from the other in QML is
    // where byte-order bugs live.
    property var values: ({})
    property var files: []
    property bool valuesLoaded: false

    readonly property bool ready: schemaLoaded && valuesLoaded
    readonly property bool available: Ipc.connected

    // Something went wrong and the window should say so rather than sit empty.
    property string error: ""

    // Bumped on every change from the compositor. Bindings that read `values`
    // through a function -- which is most of them, because the interesting
    // reads are `valueOf(key)` -- cannot depend on the property itself, so they
    // read this instead. Without it a row shows the value it had when it was
    // built and never updates.
    property int generation: 0

    function load() {
        if (!Ipc.connected) {
            error = "not connected to a compositor";
            return;
        }
        if (schemaLoaded && valuesLoaded)
            return;
        if (!schemaLoaded)
            Ipc.request("get config-schema", obj => root.takeSchema(obj));
        if (!valuesLoaded)
            Ipc.request("get config", obj => root.takeValues(obj));
    }

    function takeSchema(obj) {
        if (!obj || !obj.options) {
            error = "the compositor sent no schema"
                    + (obj && obj.error ? ": " + obj.error : "");
            return;
        }
        const map = {};
        for (const o of obj.options)
            map[o.key] = o;
        options = obj.options;
        byKey = map;
        groups = obj.groups || [];
        digest = obj.digest || "";
        schemaLoaded = true;
        error = "";
    }

    function takeValues(obj) {
        if (!obj || !obj.values) {
            error = "the compositor sent no values"
                    + (obj && obj.error ? ": " + obj.error : "");
            return;
        }
        values = obj.values;
        files = obj.files || [];
        valuesLoaded = true;
        generation++;
    }

    // ── reading ─────────────────────────────────────────────────────────────

    function entry(key) {
        void generation;
        const e = values[key];
        return e === undefined ? null : e;
    }

    // The RESOLVED value: what the compositor is running, not what is in the
    // file. Those differ whenever a value was clamped, and showing the file's
    // number would be a panel that reads 200 next to a compositor running 100.
    function valueOf(key) {
        const e = entry(key);
        if (e !== null)
            return e.value;
        // Falling back to the schema default rather than "" matters while the
        // two fetches are in flight: a control bound to "" briefly renders as
        // empty and then jumps, and for a Picker it renders as no selection at
        // all.
        const o = byKey[key];
        return o ? o.default : "";
    }

    function colorOf(key, fallback) {
        const e = entry(key);
        if (e !== null && e.rgba && e.rgba.length === 4)
            return Qt.rgba(e.rgba[0], e.rgba[1], e.rgba[2], e.rgba[3]);
        return parseColor(valueOf(key), fallback);
    }

    // 0xRRGGBBAA (what asteroidz reads and writes) into a Qt colour.
    //
    // Not Qt.color(): it reads "#AARRGGBB" for eight hex digits, so every
    // colour handed to it in the compositor's own spelling comes back with the
    // alpha and the red channel swapped -- which for an opaque colour means
    // full red and whatever transparency the red channel happened to be.
    function parseColor(s, fallback) {
        const m = /^(?:0x|#)?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(
            (s || "").trim());
        if (!m)
            return fallback;
        const h = m[1];
        const n = v => parseInt(v, 16) / 255.0;
        return Qt.rgba(n(h.substr(0, 2)), n(h.substr(2, 2)), n(h.substr(4, 2)),
                       h.length === 8 ? n(h.substr(6, 2)) : 1.0);
    }

    // And back, in the spelling the compositor reads.
    //
    // Math.round, not truncation. Truncating turns 0x2c into 0x2b, and since
    // every save round-trips through here that is a theme which visibly darkens
    // one step every time you touch the settings window.
    function formatColor(c) {
        const h = v => {
            const s = Math.round(Math.max(0, Math.min(1, v)) * 255)
                .toString(16);
            return s.length === 1 ? "0" + s : s;
        };
        return "0x" + h(c.r) + h(c.g) + h(c.b) + h(c.a);
    }

    // Is this option's value editable at all, and if not, why?
    //
    // Decided per FILE, not per option: matugen and the display plugin both
    // regenerate their file wholesale, so an edit written there is not refused,
    // it is silently reverted the next time the wallpaper changes. The schema's
    // `matugen` flag is only a hint for greying the control out before you
    // click; `source.writable` is the compositor's actual answer and the one
    // acted on here.
    function writableOf(key) {
        const e = entry(key);
        if (e === null || !e.source)
            return true;
        return e.source.writable !== false;
    }

    function reasonOf(key) {
        const e = entry(key);
        return (e && e.source && e.source.reason) ? e.source.reason : "";
    }

    function isDefault(key) {
        const e = entry(key);
        return e === null ? true : e.is_default === true;
    }

    // Where it comes from, in a sentence, for the row's second line.
    function sourceText(key) {
        const e = entry(key);
        if (e === null || !e.source)
            return "";
        const s = e.source;
        if (s.kind === "default")
            return "default";
        if (s.kind === "runtime")
            return "changed in memory, not saved";
        const name = (s.file || "").split("/").pop();
        let t = name + (s.line ? ":" + s.line : "");
        // The path it ACTUALLY lives at, when that is not the canonical one.
        // `misc { border_radius 9 }` is a legal spelling of a top-level
        // `border_radius`, and saying "config.kdl:34" without saying where in
        // it sends you looking in the wrong block.
        const o = byKey[key];
        if (s.path && o && o.path && s.path !== o.path)
            t += " (" + s.path + ")";
        if (s.reason)
            t += " · " + s.reason;
        return t;
    }

    // ── grouping ──────────────────────────────────────────────────────────

    function optionsIn(group) {
        void generation;
        return options.filter(o => o.group === group);
    }

    // Subgroups of a group, in first-appearance order. The schema does not list
    // them separately and does not need to: the option table is already in
    // presentation order, so the order they first appear in IS their order.
    function subgroupsIn(group) {
        const seen = {};
        const out = [];
        for (const o of options) {
            if (o.group !== group)
                continue;
            const sg = o.subgroup || "";
            if (seen[sg])
                continue;
            seen[sg] = true;
            out.push(sg);
        }
        return out;
    }

    // "window-open" -> "Window open". The schema carries labels for options and
    // for groups but not for subgroups, which are a slug; rather than add a
    // third table that has to agree with the other two, derive it.
    function subgroupLabel(sg) {
        if (sg === "" || sg === "general")
            return "";
        const s = sg.replace(/[-_]/g, " ");
        return s.charAt(0).toUpperCase() + s.slice(1);
    }

    function groupLabel(name) {
        for (const g of groups)
            if (g.name === name)
                return g.label;
        return name;
    }

    // Free-text match over everything a person might remember about an option:
    // its label, its explanation, its KDL path, and the internal key. The key
    // is included deliberately -- someone who has read the docs knows
    // `blur_num_passes` and should not have to guess that it is called "Passes"
    // here.
    function matches(o, needle) {
        if (needle === "")
            return true;
        const n = needle.toLowerCase();
        return (o.label || "").toLowerCase().includes(n)
            || (o.desc || "").toLowerCase().includes(n)
            || (o.path || "").toLowerCase().includes(n)
            || (o.key || "").toLowerCase().includes(n)
            || (o.subgroup || "").toLowerCase().includes(n)
            || groupLabel(o.group).toLowerCase().includes(n);
    }

    // ── writing ─────────────────────────────────────────────────────────────

    // `changes` is [{key, value}], with value === null meaning "remove the
    // declaration and go back to the default".
    //
    // One request for the whole batch, because the compositor's contract is
    // all-or-nothing: if any value in it is invalid, none are applied. Sending
    // them one at a time would give up exactly the property an Apply button
    // needs, and leave half a form applied when the other half was rejected.
    function submit(changes, persist, onDone) {
        submitWith(changes, persist, false, onDone);
    }

    // The same, shadowing a generated file.
    //
    // Separate rather than a fourth positional flag on `submit`, because
    // `override` is not a detail: it appends the key at the end of the main
    // config so a later declaration beats the sourced file matugen owns. Every
    // call site should read as having decided that.
    function submitOverride(changes, persist, onDone) {
        submitWith(changes, persist, true, onDone);
    }

    function submitWith(changes, persist, override, onDone) {
        if (!Ipc.connected) {
            if (onDone)
                onDone({ ok: false, error: "no-compositor",
                         detail: "not connected", results: [] });
            return;
        }
        const body = JSON.stringify({
            changes: changes,
            persist: persist === true,
            override: override === true
        });
        Ipc.request("set-config " + body, reply => {
            // Re-read rather than trusting the echo. The reply says what each
            // value became, but a change can move a value the UI is not showing
            // -- override_config clamps in cascades -- and provenance moves too
            // once a key is written to a file for the first time.
            root.refresh();
            if (onDone)
                onDone(reply);
        });
    }

    function refresh() {
        if (!Ipc.connected)
            return;
        Ipc.request("get config", obj => root.takeValues(obj));
    }

    // Throw away every memory-only change and go back to what is on disk.
    //
    // A reload, not a batch of writes putting the old values back. Those two are
    // not the same thing: writing "4" back over a preview of "8" leaves the value
    // correct and the PROVENANCE wrong -- the compositor now records that key as
    // set at runtime, so a key that is saved in config.kdl reads back as "changed
    // in memory, not saved" forever after. Re-reading the files is the only
    // operation that restores both.
    //
    // It costs a `run_exec()`, so the compositor respawns whatever is in `spawn`.
    // That is deliberate on reload and it is why previews are not reverted this
    // way one at a time -- once, on closing the window, is the whole budget.
    function reloadFromDisk(onDone) {
        if (!Ipc.connected)
            return;
        Ipc.dispatch("dispatch reload_config");
        // The reload is asynchronous and `dispatch` reads no reply, so there is
        // nothing to chain off. Long enough for the compositor to re-read three
        // files and re-apply, short enough not to be felt.
        reloadSettle.callback = onDone === undefined ? null : onDone;
        reloadSettle.restart();
    }

    Timer {
        id: reloadSettle
        interval: 250
        property var callback: null
        onTriggered: {
            root.refresh();
            if (callback)
                callback();
        }
    }

    // ── staying live ────────────────────────────────────────────────────────
    //
    // Only started once something has asked for the schema. `watch config`
    // pushes every value on subscribe, so subscribing eagerly would be the
    // whole fetch this singleton just went out of its way to defer.
    property var watcher: null

    onReadyChanged: if (ready && watcher === null) {
        watcher = Ipc.watch("watch config", obj => {
            // A DIFF, not the whole set -- `changed` carries only what moved,
            // so a matugen palette reload is a few hundred bytes rather than
            // 30 KB. Merged in place; the initial push has everything and
            // arrives before any real change, so there is no window where this
            // is missing values.
            if (!obj || !obj.changed)
                return;
            const v = {};
            for (const k in root.values)
                v[k] = root.values[k];
            for (const k in obj.changed)
                v[k] = obj.changed[k];
            root.values = v;
            root.generation++;
        });
    }
}
