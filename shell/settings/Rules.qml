pragma Singleton

// Window rules and keybinds, as data.
//
// The same arrangement Schema.qml has for options, and for the same reason: the
// compositor publishes a description of the vocabulary and the current contents,
// and this holds them. Nothing here knows what any individual rule field means.
//
// Three fetches rather than one, because they answer different questions and only
// two of them ever change. `window-rule-schema` and `dispatch-actions` are
// compile-time constant; the rules and binds are re-read after every write.

import Quickshell
import QtQuick
import ".."

Singleton {
    id: root

    // ── the vocabulary ──────────────────────────────────────────────────────
    property var fields: []          // window-rule fields, schema order
    property var fieldByKey: ({})
    property var fieldGroups: []
    property bool schemaLoaded: false

    // The 94 dispatch names a bind can call, with the KINDS of their arguments.
    // A keybind editor without this is a text box that accepts typos and writes
    // a config which fails at the next login.
    property var actions: []
    property var actionByName: ({})
    property bool actionsLoaded: false

    // The tag-rule vocabulary, kept apart from the window-rule one.
    //
    // They share nothing but a shape: different fields, different keys, and a
    // `layout` enum that exists in neither the option schema nor the window-rule
    // one. Merging them into a single `fields` would mean every lookup carrying
    // which kind it meant.
    property var tagFields: []
    property var tagFieldByKey: ({})
    property var tagFieldGroups: []
    property bool tagSchemaLoaded: false

    // ── the contents ────────────────────────────────────────────────────────
    property var rules: []
    property var tagRules: []
    property var binds: []
    property var notListed: []
    property bool contentLoaded: false

    property string error: ""
    // Bumped on every refresh, for bindings that read through a function.
    property int generation: 0

    readonly property bool ready: schemaLoaded && actionsLoaded && contentLoaded

    function load() {
        if (!Ipc.connected) {
            error = "not connected to a compositor";
            return;
        }
        if (!schemaLoaded)
            Ipc.request("get window-rule-schema", o => root.takeSchema(o));
        if (!actionsLoaded)
            Ipc.request("get dispatch-actions", o => root.takeActions(o));
        if (!tagSchemaLoaded)
            Ipc.request("get tag-rule-schema", o => root.takeTagSchema(o));
        refresh();
    }

    function takeSchema(obj) {
        if (!obj || !obj.fields) {
            error = "the compositor sent no rule schema";
            return;
        }
        const map = {};
        for (const f of obj.fields)
            map[f.key] = f;
        fields = obj.fields;
        fieldByKey = map;
        fieldGroups = obj.groups || [];
        schemaLoaded = true;
        error = "";
    }

    function takeActions(obj) {
        if (!obj || !obj.actions)
            return;
        const map = {};
        for (const a of obj.actions)
            map[a.name] = a;
        actions = obj.actions;
        actionByName = map;
        actionsLoaded = true;
    }

    function takeTagSchema(obj) {
        // Absent rather than empty on a compositor older than the verb, which is
        // a real state: the bar and the compositor are separate packages, and an
        // installed bar can be newer. The page says so rather than drawing an
        // editor with no fields.
        if (!obj || !obj.fields) {
            tagSchemaLoaded = false;
            return;
        }
        const map = {};
        for (const f of obj.fields)
            map[f.key] = f;
        tagFields = obj.fields;
        tagFieldByKey = map;
        tagFieldGroups = obj.groups || [];
        tagSchemaLoaded = true;
    }

    function refresh() {
        if (!Ipc.connected)
            return;
        Ipc.request("get tag-rules", o => {
            root.tagRules = (o && o.rules) || [];
            root.generation++;
        });
        Ipc.request("get window-rules", o => {
            root.rules = (o && o.rules) || [];
            root.contentLoaded = true;
            root.generation++;
        });
        Ipc.request("get binds", o => {
            root.binds = (o && o.binds) || [];
            root.notListed = (o && o.not_listed) || [];
            root.generation++;
        });
    }

    // ── reading ─────────────────────────────────────────────────────────────

    function fieldsIn(group) {
        return fields.filter(f => f.group === group);
    }

    function groupLabel(name) {
        for (const g of fieldGroups)
            if (g.name === name)
                return g.label;
        return name;
    }

    // What to call a rule in a list. Its matchers, because that is what a person
    // recognises it by -- "the mpv rule", not "rule 3".
    function ruleTitle(rule) {
        const f = rule.fields || {};
        const bits = [];
        if (f.appid) bits.push("app-id " + f.appid);
        if (f.title) bits.push("title " + f.title);
        if (f.toplevel_tag) bits.push("tag " + f.toplevel_tag);
        // A rule with no matchers applies to EVERY window, which is worth saying
        // in the loudest place available rather than leaving as a blank line.
        return bits.length ? bits.join(" · ") : "every window";
    }

    function ruleIsMatcher(key) {
        const f = fieldByKey[key];
        return f !== undefined && f.type === "match";
    }

    // The fields a rule sets that are not matchers, in schema order rather than
    // in whatever order the JSON object happened to enumerate.
    function ruleActions(rule) {
        const out = [];
        const set = rule.fields || {};
        for (const f of fields)
            if (f.type !== "match" && set[f.key] !== undefined)
                out.push(f.key);
        return out;
    }

    // The distinct values a matcher could take from the windows open right now.
    //
    // A rule editor that only offers a text box is asking you to know the app id
    // of a window you are looking at -- which is not shown anywhere, and is
    // `org.mozilla.firefox` rather than "Firefox". The compositor already reports
    // it for every client.
    //
    // Anchored, because these are REGEXES. `^kitty$` is what you mean when you
    // pick kitty from a list; bare `kitty` would also match `kitty-dropdown` and
    // anything else containing it, which is a rule that quietly applies to more
    // than you chose. Regex metacharacters in the value are escaped for the same
    // reason -- a `.` in an app id is a wildcard otherwise.
    function windowValuesFor(key) {
        void Compositor.generation;
        const seen = {};
        const out = [];
        for (const c of Compositor.clients) {
            const raw = key === "title" ? (c.title || "") : (c.appid || "");
            if (raw === "")
                continue;
            const v = "^" + raw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$";
            if (seen[v])
                continue;
            seen[v] = true;
            out.push(v);
        }
        return out;
    }

    // What to show for one of those, since an anchored escaped regex is not what
    // a person recognises.
    function windowLabelFor(key, value) {
        return value.replace(/^\^/, "").replace(/\$$/, "").replace(/\\(.)/g, "$1");
    }

    function bindTitle(bind) {
        let t = bind.action;
        if (bind.args && bind.args.length)
            t += " " + bind.args.join(" ");
        return t;
    }

    // What else is already bound to this chord, ignoring `exceptIndex`.
    //
    // Worth surfacing because the compositor says nothing: bindings are scanned
    // in order and the last match wins, so a duplicate does not fail -- the older
    // one simply stops working, at the next reload, with no message anywhere.
    // Mode matters: the same chord in two keymodes is not a clash.
    function bindsFor(chord, exceptIndex) {
        void generation;
        const hits = [];
        for (const b of binds) {
            if (b.index === exceptIndex || b.chord !== chord)
                continue;
            hits.push(bindTitle(b)
                      + (b.mode && b.mode !== "default" ? " (" + b.mode + ")" : ""));
        }
        return hits.join(", ");
    }

    function bindFlagSummary(bind) {
        const on = [];
        const f = bind.flags || {};
        for (const k of ["lock", "keysym", "release", "pass"])
            if (f[k])
                on.push(k);
        return on.join(" · ");
    }

    // ── writing ─────────────────────────────────────────────────────────────
    //
    // No preview, unlike options. A window rule takes effect when a window maps
    // and a keybind is a lookup, so there is nothing to see between writing and
    // applying -- the compositor has no persist:false for these for that reason.

    function submitRules(changes, onDone) {
        submit("set-window-rules", changes, onDone);
    }

    function submitTagRules(changes, onDone) {
        submit("set-tag-rules", changes, onDone);
    }

    // What to call a tag rule in a list: the tag, and what makes it distinct
    // from the other rules for the same tag -- which is usually the monitor.
    function tagRuleTitle(rule) {
        const f = rule.fields || {};
        let s = "Tag " + (f.id || "?");
        if (f.name)
            s += " · " + f.name;
        if (f.monitor_name)
            s += " · " + f.monitor_name;
        else if (f.monitor_model)
            s += " · " + f.monitor_model;
        return s;
    }

    function tagFieldsIn(group) {
        return tagFields.filter(f => f.group === group);
    }

    function tagGroupLabel(name) {
        for (const g of tagFieldGroups)
            if (g.name === name)
                return g.label;
        return name;
    }

    function submitBinds(changes, onDone) {
        submit("set-binds", changes, onDone);
    }

    function submit(verb, changes, onDone) {
        if (!Ipc.connected) {
            if (onDone)
                onDone({ ok: false, error: "no-compositor", results: [] });
            return;
        }
        Ipc.request(verb + " " + JSON.stringify({ changes: changes }), reply => {
            // Re-read rather than patching the local copy. A write renumbers
            // everything after a removal, and an index that is one out is an edit
            // applied to the wrong rule -- silently, because both rules are
            // plausible.
            root.refresh();
            if (onDone)
                onDone(reply);
        });
    }

    // The first useful error out of a reply, for a status line. The per-change
    // ones carry the detail; the top-level one is often just "something failed".
    function failureText(reply) {
        if (!reply)
            return "no reply";
        if (reply.results)
            for (const r of reply.results)
                if (r.ok === false && r.error && r.error !== "not-applied")
                    return r.error + (r.detail ? ": " + r.detail : "");
        return (reply.error || "refused")
               + (reply.detail ? ": " + reply.detail : "");
    }
}
