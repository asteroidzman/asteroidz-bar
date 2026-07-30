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

    // ── the contents ────────────────────────────────────────────────────────
    property var rules: []
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

    function refresh() {
        if (!Ipc.connected)
            return;
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

    function bindTitle(bind) {
        let t = bind.action;
        if (bind.args && bind.args.length)
            t += " " + bind.args.join(" ");
        return t;
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
