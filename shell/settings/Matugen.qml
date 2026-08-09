pragma Singleton

// Which Material role each asteroidz colour is generated from.
//
// matugen turns the wallpaper into a Material You palette and renders templates
// from it. One of those templates is `asteroidz-colors.kdl`, which becomes
// `~/.config/asteroidz/colors.kdl` — nine colours, each pinned to a role like
// `primary` or `surface_container_high`. Changing which role a colour uses means
// editing that template by hand and knowing both the role names and matugen's
// filter syntax.
//
// This holds the mapping and renders the template from it.
//
// ── the mapping is the source of truth, the template is the render target ───
//
// The template could be parsed back instead of keeping a mapping beside it, and
// that would be one file rather than two. It is not done that way because a
// template is arbitrary text with an arbitrary filter chain, and a parser that
// mostly works would silently drop whatever it did not understand the next time
// the file was written. The mapping is a flat key=value file that says exactly
// what it means.
//
// The exception is the FIRST run, where the template is all there is. It is
// parsed then, best-effort, so that opening this page and pressing Apply does not
// replace a tuned template with defaults. Anything the parse cannot recover falls
// back to the shipped mapping, and the previous template is kept at `.bak`.
//
// ── the role list comes from matugen ────────────────────────────────────────
//
// Asked for at runtime with `matugen --dry-run`, not hardcoded. A hardcoded list
// is a second description of somebody else's software that is correct until they
// add a role — and this whole settings effort exists because of what that costs.

import Quickshell
import Quickshell.Io
import QtQuick
import Asteroidz.Bar
import ".."

Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    // All three are overridable, and that is a test requirement rather than a
    // convenience. Applying rewrites a template in the user's matugen directory
    // and then runs matugen for real -- which re-renders every template on the
    // machine and fires every post-hook. A headless test that could not redirect
    // those would be re-theming the desktop it is running beside.
    readonly property string mapPath:
        Quickshell.env("ASTEROIDZ_MATUGEN_CONF")
        || (home + "/.config/asteroidz-bar/matugen.conf")
    readonly property string templatePath:
        Quickshell.env("ASTEROIDZ_MATUGEN_TEMPLATE")
        || (home + "/.config/matugen/templates/asteroidz-colors.kdl")

    // The packaged template, for seeding a user copy that is not there yet.
    //
    // The package deliberately does not write into ~/.config -- that would
    // overwrite a tuned template, and would do it on every upgrade. Seeding here
    // is safe because it happens only when the file is absent, which is the one
    // moment where copying cannot destroy anything.
    readonly property string shippedTemplate:
        Quickshell.env("ASTEROIDZ_MATUGEN_SHIPPED")
        || "/usr/share/asteroidz-bar/matugen/asteroidz-colors.kdl"
    readonly property string matugenToml:
        Quickshell.env("ASTEROIDZ_MATUGEN_TOML")
        || (home + "/.config/matugen/config.toml")
    readonly property string colorsOut:
        Quickshell.env("ASTEROIDZ_COLORS_OUT")
        || (home + "/.config/asteroidz/colors.kdl")

    // The nine colours this template owns, in the order they appear in it.
    //
    // Fixed rather than taken from the schema's `matugen` flag, because the flag
    // describes what IS generated and this list describes what CAN be. They agree
    // today; if they ever disagree, this is the one that decides what the
    // template contains.
    //
    // The four state colours -- maximize, scratchpad, global, overlay -- are
    // deliberately absent. They default to focus-color, which is what makes a
    // themed border keep its hue when a window is maximized; generating them
    // would pin them to a role and lose that. See docs/visuals/theming.md.
    readonly property var keys: [
        { key: "bordercolor",            path: "layout/border/color",
          label: "Border, resting",      role: "surface_container_high", gray: true },
        { key: "focuscolor",             path: "layout/border/focus-color",
          label: "Border, focused",      role: "primary",                gray: false },
        { key: "urgentcolor",            path: "layout/border/urgent-color",
          label: "Border, urgent",       role: "error",                  gray: false },
        { key: "border_gradient_color2", path: "layout/border/gradient/color2",
          label: "Border gradient end",  role: "tertiary",               gray: false },
        { key: "theme_bg_color",         path: "theme/bg-color",
          label: "Surface",              role: "surface_container_high", gray: true },
        { key: "theme_fg_color",         path: "theme/fg-color",
          label: "Text",                 role: "on_surface",             gray: false },
        { key: "theme_focus_bg_color",   path: "theme/focus-bg-color",
          label: "Surface, focused",     role: "primary",                gray: false },
        { key: "theme_focus_fg_color",   path: "theme/focus-fg-color",
          label: "Text, focused",        role: "on_primary",             gray: false },
        { key: "theme_urgent_color",     path: "theme/urgent-color",
          label: "Attention",            role: "error",                  gray: false }
    ]

    // ── how the palette is generated, not just which role each colour takes ──
    //
    // `type` and `prefer` are GONE, not merely hidden.
    //
    // They were matugen's CLI flags: which Material scheme to derive, and which
    // candidate source colour to prefer when an image yields several. The
    // palette is generated in-process by ColorEngine now, which takes a seed
    // from the image and one tone map, so neither flag has anything to act on.
    // Leaving them on the page meant two controls that wrote a config file and
    // changed no colour on screen.
    //
    // What remains is what the engine actually reads: `mode` becomes
    // ColorEngine.dark and `contrast` becomes ColorEngine.contrast.
    property var scheme: ({ mode: "dark", contrast: "0" })

    function setScheme(field, value) {
        const s = Object.assign({}, scheme);
        s[field] = value;
        scheme = s;
        generation++;
    }

    // The flags every invocation must carry. Empty strings are dropped rather
    // than passed as "", which matugen rejects.

    // ── the other applications ──────────────────────────────────────────────
    //
    // Discovered from the user's config.toml rather than configured here. Apply
    // rewrites all of them and always did; the page just never said so, which is
    // the part that made it feel like a compositor setting.
    //
    // [{ name, output, enabled }]
    property var templates: []

    function templateEnabled(name) {
        void generation;
        const e = mapping["template." + name];
        return !e || e.role !== "off";
    }

    function setTemplateEnabled(name, on) {
        const m = Object.assign({}, mapping);
        m["template." + name] = { role: on ? "on" : "off", gray: false, owned: on };
        mapping = m;
        generation++;
    }

    // key -> { role, gray, owned }
    property var mapping: ({})
    property var roles: []
    property bool loaded: false
    property string status: ""
    property bool statusBad: false
    property bool busy: false
    // A re-theme that arrived before the mapping was read; run once it is.
    property string pendingRetheme: ""
    property int generation: 0

    function defaultsFor(k) {
        for (const d of keys)
            if (d.key === k)
                return { role: d.role, gray: d.gray, owned: true };
        return { role: "primary", gray: false, owned: true };
    }

    function entry(k) {
        void generation;
        return mapping[k] || defaultsFor(k);
    }

    function set(k, field, value) {
        const m = Object.assign({}, mapping);
        const e = Object.assign({}, entry(k));
        e[field] = value;
        m[k] = e;
        mapping = m;
        generation++;
    }

    // ── loading ─────────────────────────────────────────────────────────────

    function load() {
        if (loaded)
            return;
        loadRoles();
        mapFile.reload();
        templateFile.reload();
    }

    function runPendingRetheme() {
        const w = pendingRetheme;
        if (w === "")
            return;
        pendingRetheme = "";
        loaded = true;   // whatever the file said, or did not
        retheme(w);
    }

    function parseMapping(text) {
        const out = {};
        const sch = Object.assign({}, scheme);
        let sawScheme = false;
        for (const line of text.split("\n")) {
            const t = line.trim();
            if (!t || t.startsWith("#"))
                continue;
            const i = t.indexOf("=");
            if (i <= 0)
                continue;
            const k = t.slice(0, i).trim();
            // `role[:grayscale]`, or the literal `off`.
            const v = t.slice(i + 1).trim();
            // Settings are namespaced with a dot; colour keys are C identifiers
            // and never contain one, so the two cannot collide.
            if (k.startsWith("scheme.")) {
                const f = k.slice(7);
                if (f === "type" || f === "mode" || f === "contrast"
                    || f === "prefer") {
                    sch[f] = v;
                    sawScheme = true;
                }
                continue;
            }
            if (v === "off") {
                out[k] = { role: defaultsFor(k).role, gray: false, owned: false };
                continue;
            }
            const bits = v.split(":");
            out[k] = {
                role: bits[0],
                gray: bits.indexOf("grayscale") >= 0,
                owned: true
            };
        }
        if (sawScheme)
            scheme = sch;
        return out;
    }

    function serialiseMapping() {
        const lines = [
            "# Which Material role each asteroidz colour is generated from.",
            "# Written by the settings window; `off` means it is left alone.",
            "",
            "# How the palette is generated. The engine is built in now, so",
            "# these are the only two knobs it has: the tone map to solve",
            "# against, and how far to push contrast within it.",
            "scheme.mode=" + scheme.mode,
            "scheme.contrast=" + scheme.contrast,
            ""
        ];
        for (const d of keys) {
            const e = entry(d.key);
            lines.push(d.key + "=" + (!e.owned ? "off"
                : e.role + (e.gray ? ":grayscale" : "")));
        }
        const off = templates.filter(t => !templateEnabled(t.name));
        if (off.length) {
            lines.push("");
            lines.push("# Templates left out of Apply. They stay in matugen's own");
            lines.push("# config, so a wallpaper change still renders them.");
            for (const t of off)
                lines.push("template." + t.name + "=off");
        }
        return lines.join("\n") + "\n";
    }

    // ── reading the template list out of matugen's config ───────────────────
    //
    // A deliberately shallow TOML read: section headers and output_path, nothing
    // else. It never rewrites the file from what it parsed, so a value it fails
    // to understand costs a display string, not the user's config.
    function parseTemplates(text) {
        const out = [];
        let cur = null;
        for (const raw of text.split("\n")) {
            const t = raw.trim();
            const m = /^\[templates\.([^\]]+)\]/.exec(t);
            if (m) {
                cur = { name: m[1], output: "", input: "", hook: "" };
                out.push(cur);
                continue;
            }
            if (/^\[/.test(t)) {
                cur = null;
                continue;
            }
            if (!cur)
                continue;
            // input_path and post_hook matter now that this shell renders the
            // templates itself: the list used to be for display only, so
            // reading just the output path was enough.
            const q = /=\s*"(.*)"/.exec(t);
            if (!q)
                continue;
            if (t.startsWith("output_path")) cur.output = q[1];
            else if (t.startsWith("input_path")) cur.input = q[1];
            else if (t.startsWith("post_hook")) cur.hook = q[1];
        }
        return out;
    }

    // A config containing only the enabled templates, for Apply.
    //
    // matugen has no --template filter: it renders everything in the config it is
    // given. But it takes `-c`, so a filtered COPY does the job and the user's own
    // config.toml is never touched -- which matters, because that file themes
    // every application on the machine and this page is not its owner.
    function filteredToml(text) {
        const keep = [];
        let cur = null, curName = null;
        for (const raw of text.split("\n")) {
            const m = /^\s*\[templates\.([^\]]+)\]/.exec(raw);
            if (m) {
                curName = m[1];
                cur = templateEnabled(curName) ? keep : null;
                if (cur)
                    cur.push(raw);
                continue;
            }
            if (/^\s*\[/.test(raw)) {
                curName = null;
                cur = keep;
            }
            if (cur)
                cur.push(raw);
        }
        return keep.join("\n") + "\n";
    }

    // Recover the mapping from an existing template, well enough not to lose a
    // tuned one on first use.
    //
    // Deliberately narrow: it looks for `colors.<role>` and for the word
    // `grayscale` on the same line as a known path, and gives up on anything
    // else. A cleverer parser would be one that fails in ways nobody notices.
    function seedFromTemplate(text) {
        const out = {};
        const lines = text.split("\n");
        for (const d of keys) {
            const leaf = d.path.split("/").pop();
            for (const line of lines) {
                if (line.indexOf(leaf) < 0 || line.indexOf("colors.") < 0)
                    continue;
                const m = /colors\.([a-z_]+)\./.exec(line);
                if (!m)
                    continue;
                out[d.key] = {
                    role: m[1],
                    gray: line.indexOf("grayscale") >= 0,
                    owned: true
                };
                break;
            }
        }
        return out;
    }

    FileView {
        id: mapFile
        path: root.mapPath
        onLoaded: {
            root.mapping = root.parseMapping(text());
            root.loaded = true;
            root.runPendingRetheme();
        }
        onLoadFailed: {
            // No mapping yet. Seed from the template if there is one, so the
            // first Apply reproduces what is already there rather than
            // overwriting it with defaults.
            root.mapping = ({});
            templateFile.reload();
            root.loaded = true;
            // A pending re-theme still runs. No mapping is a real state -- a
            // machine that has never opened the Palette page -- and the
            // built-in scheme is the honest answer there.
            root.runPendingRetheme();
        }
    }

    FileView {
        id: templateFile
        path: root.templatePath
        onLoaded: {
            if (Object.keys(root.mapping).length === 0) {
                root.mapping = root.seedFromTemplate(text());
                root.generation++;
            }
        }
        // No template at all: a fresh install, where the packaged one has never
        // been copied. Seed from it rather than showing an empty page and waiting
        // for the user to work out that a file is missing.
        onLoadFailed: shippedFile.reload()
    }

    FileView {
        id: shippedFile
        path: root.shippedTemplate
        preload: false
        onLoaded: {
            templateWriter.setText(text());
            if (Object.keys(root.mapping).length === 0) {
                root.mapping = root.seedFromTemplate(text());
                root.generation++;
            }
            root.status = "copied the packaged template to "
                          + root.templatePath;
            root.statusBad = false;
        }
        onLoadFailed: {
            root.status = "no matugen template, and none installed to "
                          + root.shippedTemplate;
            root.statusBad = true;
        }
    }

    // The role list, from the engine that will render them.
    //
    // It used to come from `matugen --dry-run`, and asking the tool rather than
    // hardcoding a table was the right instinct -- it just has to be the tool
    // that actually does the work. Reading it from ColorEngine keeps that
    // property and drops the last reason this shell needs matugen installed at
    // all: the page now cannot offer a role the renderer would not understand.
    function loadRoles() {
        root.roles = Object.keys(ColorEngine.roles).sort();
        if (root.roles.length === 0) {
            // Only before the first wallpaper has been read. Generating from
            // the current one fills it in without touching any output file.
            ColorEngine.source = Wallpaper.path;
            root.roles = Object.keys(ColorEngine.roles).sort();
        }
    }

    // ── rendering ───────────────────────────────────────────────────────────

    // One `{{ }}` expression for a role.
    //
    // `hex_stripped` is the six digits without the leading `#`, which is what
    // goes after asteroidz's `0x`; the alpha is appended literally because these
    // are all opaque. The grayscale form has to go through `to_color` first --
    // the filter chain works on a colour, not on a string.
    function expressionFor(role, gray) {
        return gray
            ? "0x{{colors." + role
              + ".default.hex | to_color | grayscale | format: \"hex_stripped\"}}ff"
            : "0x{{colors." + role + ".default.hex_stripped}}ff";
    }

    function renderTemplate() {
        const e = k => entry(k);
        const on = k => e(k).owned;
        const ex = k => expressionFor(e(k).role, e(k).gray);

        let out = "";
        out += "// ! Auto-generated file. Do not edit directly.\n";
        out += "// Written by the asteroidz settings window; edit the palette\n";
        out += "// there instead, or remove `source` for this file from your\n";
        out += "// config to take a colour back.\n\n";

        const border = ["bordercolor", "focuscolor", "urgentcolor",
                        "border_gradient_color2"].some(on);
        if (border) {
            out += "layout {\n    border {\n";
            if (on("bordercolor"))
                out += "        color " + ex("bordercolor") + "\n";
            if (on("focuscolor"))
                out += "        focus-color " + ex("focuscolor") + "\n";
            if (on("urgentcolor"))
                out += "        urgent-color " + ex("urgentcolor") + "\n";
            if (on("border_gradient_color2"))
                out += "        gradient { color2 "
                       + ex("border_gradient_color2") + " }\n";
            out += "    }\n}\n\n";
        }

        const theme = ["theme_bg_color", "theme_fg_color", "theme_focus_bg_color",
                       "theme_focus_fg_color", "theme_urgent_color"].some(on);
        if (theme) {
            out += "theme {\n";
            if (on("theme_bg_color"))
                out += "    bg-color " + ex("theme_bg_color") + "\n";
            if (on("theme_fg_color"))
                out += "    fg-color " + ex("theme_fg_color") + "\n";
            if (on("theme_focus_bg_color"))
                out += "    focus-bg-color " + ex("theme_focus_bg_color") + "\n";
            if (on("theme_focus_fg_color"))
                out += "    focus-fg-color " + ex("theme_focus_fg_color") + "\n";
            if (on("theme_urgent_color"))
                out += "    urgent-color " + ex("theme_urgent_color") + "\n";
            out += "}\n";
        }

        // A template that sets nothing is still a valid KDL file, and asteroidz
        // sources it unconditionally -- so it has to exist and parse even when
        // every colour has been taken back by hand.
        if (!border && !theme)
            out += "// every colour is set by hand; matugen writes nothing here\n";
        return out;
    }

    // ── wiring matugen up ───────────────────────────────────────────────────
    //
    // A template matugen has not been told about renders nothing. The entry is
    // four lines of TOML and the page can add them, which is the difference
    // between "copy this file and then edit that one" and pressing Apply.
    //
    // APPENDED, never rewritten. This is the user's file and it configures every
    // other themed application on the machine -- rofi, kitty, waybar, btop. A
    // page that regenerated it would be a settings window that can lose your
    // whole desktop theme, so it only ever adds a section that is not there, and
    // keeps the previous contents beside it.

    // Whether matugen's config exists, tracked rather than inferred from an empty
    // read: FileView.text() answers "" for a file that is missing and for one
    // that is empty, and those need different writes.
    property bool tomlExists: false

    function tomlHasEntry(text) {
        // Asked as "is this template already rendered by something", not "is
        // there a section called [templates.asteroidz]". The name is the user's
        // to choose, and a second section pointing at the same template would
        // render it twice rather than fail -- untidy, and invisible.
        return text.indexOf("asteroidz-colors.kdl") >= 0;
    }

    function tomlEntry() {
        return "\n# asteroidz: the compositor's palette. Added by the settings\n"
             + "# window's Palette page; edit or remove it freely.\n"
             + "[templates.asteroidz]\n"
             + "input_path = \"" + templatePath + "\"\n"
             + "output_path = \"" + colorsOut + "\"\n"
             + "# What makes a change visible: matugen writes the file and the\n"
             + "# compositor re-reads it. Without this the palette changes on disk\n"
             + "# and the screen does not.\n"
             + "post_hook = \"amsg dispatch reload_config 2>/dev/null || true\"\n";
    }

    // Read at load time and acted on SYNCHRONOUSLY at Apply.
    //
    // The first version deferred: Apply set a flag and called reload(), meaning
    // to act in onLoaded. It never fired -- a FileView with `preload: false` does
    // not re-emit for a reload the way a preloaded one does -- so Apply wrote the
    // template, ran matugen, reported success, and silently skipped the one step
    // that makes matugen render the template at all. Nothing observable said so;
    // the palette test noticed because it looks at the file.
    FileView {
        id: tomlFile
        path: root.matugenToml
        watchChanges: true
        onLoaded: {
            root.tomlExists = true;
            // watchChanges is on, so editing config.toml by hand while the page
            // is open updates the list rather than leaving it stale.
            root.templates = root.parseTemplates(tomlFile.text());
            root.generation++;
        }
        onLoadFailed: {
            root.tomlExists = false;
            root.templates = [];
        }
    }

    FileView { id: tomlWriter; path: root.matugenToml;          preload: false }
    FileView { id: tomlBackup; path: root.matugenToml + ".bak"; preload: false }

    // The filtered copy lives in the runtime dir, not beside the real config: it
    // is derived, per-run, and must never be mistaken for the file matugen is
    // normally pointed at.
    readonly property string filteredTomlPath:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/asteroidz-bar-matugen.toml"
    FileView { id: filteredWriter; path: root.filteredTomlPath; preload: false }

    function wireMatugen() {
        if (!tomlExists) {
            // No matugen config at all. `[config]` is required for the file to
            // parse -- matugen refuses one without it.
            tomlWriter.setText("[config]\n" + tomlEntry());
            status = (status ? status + " · " : "") + "created matugen's config";
            return;
        }
        const cur = tomlFile.text();
        if (tomlHasEntry(cur))
            return;
        tomlBackup.setText(cur);
        tomlWriter.setText(cur.replace(/\n*$/, "\n") + tomlEntry());
        status = (status ? status + " · " : "")
                 + "added the template to matugen's config";
    }

    // ── applying ────────────────────────────────────────────────────────────

    // Re-theme for a wallpaper that just changed.
    //
    // Not `apply()`: that rewrites the template and the mapping, which is what
    // the Palette page's button means. A wallpaper change means only "run the
    // templates that are already there against this image", so this renders and
    // nothing else -- and matugen's own post-hooks do the reloading, which is
    // how every other themed application on the machine hears about it.
    //
    // set-wallpaper.sh used to do this. It was a shell script because the
    // wallpaper was one; now the shell draws the wallpaper itself, and a
    // separate process to re-theme it is a second thing to keep in step. They
    // DID fall out of step -- the script passed scheme-fidelity and the Palette
    // page passed nothing, which is scheme-tonal-spot, and 39 of matugen's 50
    // roles differ between them -- so whichever ran last retoned the desktop.
    function retheme(wallpaper) {
        if (busy || !wallpaper)
            return;
        // The scheme flags live in the mapping file, and that is loaded lazily
        // -- the Palette page calls load() when it is opened. A re-theme can
        // happen long before anybody opens it (the wallpaper cycles on a timer,
        // or is set from a keybind), and running with the built-in defaults
        // would quietly retone the whole desktop to a scheme the user did not
        // choose. This is the exact failure the shell script had, from the
        // other direction.
        if (!loaded) {
            mapFile.reload();
            pendingRetheme = wallpaper;
            return;
        }
        busy = true;
        status = "";
        statusBad = false;
        renderWallpaper = wallpaper;
        converted = false;
        runRender(wallpaper);
    }

    // An Apply pressed while something else is rendering is QUEUED, not
    // dropped.
    //
    // It used to return silently, and a re-theme sets `busy` without asking --
    // the wallpaper cycling on a timer, or a keybind changing it. So pressing
    // Apply during that second or two did nothing at all, with no message,
    // and pressing it again a moment later worked. Reported exactly that way:
    // "sometimes you can set it, sometimes you cannot".
    property string queuedApply: ""
    property bool hasQueuedApply: false

    function apply(wallpaper) {
        if (busy) {
            queuedApply = wallpaper || "";
            hasQueuedApply = true;
            status = "waiting for the palette currently rendering…";
            statusBad = false;
            return;
        }
        busy = true;
        status = "";
        statusBad = false;
        // The mapping first, so a matugen run that fails still leaves the
        // choice recorded -- otherwise the page would forget what you picked
        // because the tool it drives was missing.
        mapWriter.setText(serialiseMapping());
        backupWriter.setText(templateFile.text());
        templateWriter.setText(renderTemplate());
        // And make sure matugen knows about the template, or the render below
        // produces nothing and says it succeeded.
        wireMatugen();
        if (wallpaper && wallpaper !== "") {
            // The real config unless something is actually switched off. Keeping
            // the common case byte-identical to a bare `matugen image` means the
            // filtered copy -- the part that can go wrong -- only ever runs when
            // you asked for it.
            let cfg = [];
            const off = templates.filter(t => !templateEnabled(t.name));
            // Everything switched off has to be caught here rather than left to
            // matugen. A config with no templates in it does not fail to render
            // -- it fails to PARSE, with `missing field templates` pointing at
            // line 1, which is a TOML error about a file the user never edited
            // and has nothing to do with the toggles they just moved.
            if (templates.length > 0 && off.length === templates.length) {
                endRun();
                status = "every application is switched off, so nothing was "
                         + "rendered. The template and your choices are saved.";
                statusBad = true;
                return;
            }
            if (off.length && tomlExists) {
                filteredWriter.setText(filteredToml(tomlFile.text()));
                cfg = ["-c", root.filteredTomlPath];
            }
            renderWallpaper = wallpaper;
            converted = false;
            runRender(wallpaper);
        } else {
            endRun();
            status = "template written; no wallpaper set, so nothing was rendered";
        }
    }

    FileView { id: mapWriter;      path: root.mapPath;              preload: false }
    FileView { id: templateWriter; path: root.templatePath;         preload: false }
    // The previous template, kept beside it. The same promise the config writer
    // makes: an Apply must never be the thing that loses a file you tuned.
    FileView { id: backupWriter;   path: root.templatePath + ".bak"; preload: false }

    // ── running it, and the format matugen cannot read ──────────────────────
    //
    // matugen decodes what the Rust `image` crate decodes. The wallpaper browser
    // offers what gdk-pixbuf decodes, which is a strictly wider set -- so once
    // the browser stopped hiding HEIC, a wallpaper you can see on screen became
    // one the Palette page dies on:
    //
    //   failed to decode image: Unsupported(PathExtension("heic"))
    //   exit 101                                    (a Rust panic, not an error)
    //
    // The shell has a decoder that reads the file -- it is DRAWING the file. So
    // the fix is to convert and try again.
    //
    // React, do not predict. The alternative is a list here of the formats
    // matugen supports, checked before the first run, and that is the exact
    // shape of mistake the extension list was just fixed for: a hardcoded copy
    // of somebody else's capabilities, correct until they change. Instead the
    // first run is byte-identical to a bare `matugen image <file>` -- the same
    // principle the filtered TOML above is written to -- and the conversion only
    // ever happens on a run that has already failed. If matugen gains HEIC, this
    // path simply stops being taken, with nothing to update.
    //
    // The failure is at decode, before any template is rendered or any post-hook
    // runs, so a first attempt that fails this way has changed nothing.

    property string renderWallpaper: ""
    property bool converted: false

    // Derived, per run, and it must never be mistaken for a wallpaper: the
    // runtime dir, like the filtered TOML.
    readonly property string convertedPath:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/asteroidz-bar-palette-source.png"

    // The palette is generated IN THIS PROCESS now.
    //
    // matugen is gone from the theming path: the engine lives in the plugin
    // (see plugin/palette.hpp for why it exists rather than what it replaces),
    // so there is no binary to find, no subprocess per wallpaper change, and no
    // "multiple source colors found, use --prefer" -- which is what matugen
    // answered on this desktop's own wallpaper.
    //
    // Everything around this is unchanged. The role mapping, the template and
    // the page that edits them all still work exactly as they did, because the
    // template is still matugen's syntax and the roles still carry Material's
    // names.
    function runRender(file) {
        // The scheme block already records mode and contrast; they mean the
        // same thing to this engine, so the page keeps driving them.
        ColorEngine.dark = root.scheme.mode !== "light";
        ColorEngine.contrast = Math.max(0, Math.min(1, Number(root.scheme.contrast) || 0));
        ColorEngine.source = file;

        if (ColorEngine.error !== "") {
            // The image cannot be decoded -- an AVIF or JXL wallpaper, most
            // likely, which QImage will not read without a plugin. Fall through
            // to the PNG conversion the matugen path already used for exactly
            // this, rather than failing.
            if (!root.converted && root.renderWallpaper !== "") {
                root.convertAndRetry();
                return;
            }
            root.endRun();
            root.status = ColorEngine.error;
            root.statusBad = true;
            return;
        }

        // EVERY enabled template, not just the compositor's.
        //
        // matugen rendered the whole config on each wallpaper change -- kitty,
        // rofi, waybar, GTK and the rest -- and a version of this that wrote
        // only colors.kdl left the other thirteen frozen at whatever the last
        // matugen run produced. Nothing would have reported that: the files
        // stay valid, they just stop agreeing with the wallpaper.
        // One template that cannot be rendered must not take the rest with it.
        //
        // This used to `break` on the first failure, which meant a single
        // unreadable input froze the WHOLE palette -- and reported it under
        // that template's name, so the message named something unrelated to
        // what the user was looking at. It is not a rare case now that matugen
        // is gone: its config can list templates whose input files went with
        // it, and the first of those aborts everything after it.
        //
        // So failures are collected and skipped, and the run fails only if
        // NOTHING rendered. A partial palette is the right outcome: the
        // compositor's own colours are one of these entries, and the reason to
        // press Apply is almost always to see them change.
        // The asteroidz entry is rendered whether or not the parsed list has
        // caught up with the file.
        //
        // apply() calls wireMatugen() to add it to the config and then renders
        // immediately, but `templates` is parsed from that file by a FileView
        // and does not refresh synchronously -- so on the very Apply that wires
        // the template in, the list still describes the file as it was, and the
        // compositor's own colours were the one thing not rendered. Which is
        // the reason anyone presses Apply.
        //
        // Merged by output path so that a list which HAS caught up does not
        // render it twice.
        const list = root.templates.slice();
        if (root.templatePath !== "" && root.colorsOut !== ""
            && !list.some(t => t.output === root.colorsOut)) {
            list.push({ name: "asteroidz", input: root.templatePath,
                        output: root.colorsOut, hook: "" });
        }

        const hooks = [];
        const skipped = [];
        let rendered = 0;
        for (const t of list) {
            if (!t.input || !t.output || !root.templateEnabled(t.name))
                continue;
            if (!ColorEngine.renderTemplate(t.input, t.output)) {
                skipped.push(t.name + " (" + ColorEngine.error + ")");
                continue;
            }
            rendered++;
            if (t.hook)
                hooks.push(t.hook);
        }

        if (rendered === 0) {
            root.endRun();
            root.status = skipped.length > 0
                ? "nothing could be rendered — " + skipped.join(", ")
                : "no templates to render";
            root.statusBad = true;
            return;
        }

        // The post-hooks the templates declare -- SIGUSR1 to kitty, a
        // compositor reload -- in one shell rather than a process each. They
        // are the templates' own, so the compositor reload is not issued here
        // as well: that would be two reloads for one wallpaper.
        if (hooks.length > 0) {
            postHooks.command = ["sh", "-c", hooks.join("; ")];
            postHooks.running = true;
        }

        root.endRun();
        root.status = root.converted
            ? "palette applied, from a converted copy of the wallpaper"
            : "palette applied";
        // Said plainly rather than swallowed. A template that is silently never
        // rendered is a theme that quietly stops tracking the wallpaper.
        if (skipped.length > 0)
            root.status += " — skipped " + skipped.join(", ");
        root.statusBad = false;
    }

    // Every path that ends a render comes through here, so a queued Apply
    // cannot be forgotten by whichever branch happens to finish.
    function endRun() {
        busy = false;
        if (!hasQueuedApply)
            return;
        const w = queuedApply;
        hasQueuedApply = false;
        queuedApply = "";
        apply(w);
    }

    // 1024 on the long edge. matugen quantises down to a fraction of that, so
    // the palette is unchanged by the resize, and it keeps the conversion off
    // the several-thousand-pixel original.
    function convertAndRetry() {
        const why = Paths.renderToPng(renderWallpaper, convertedPath, 1024);
        if (why !== "") {
            root.status = "matugen cannot read this image, and neither can the "
                          + "shell: " + why;
            root.statusBad = true;
            root.endRun();
            return;
        }
        converted = true;
        runRender(convertedPath);
    }

    // The templates' own post-hooks. Failures are not the shell's business to
    // report: a hook that reloads an application which is not running fails
    // every time by design (`pkill kitty` with no kitty), which is why the
    // config's own hooks all end in `|| true`.
    Process { id: postHooks }

    // The real thing: render every template and run every post-hook, which is
    // exactly what a wallpaper change does. One of those hooks reloads the
    // compositor, which is how the new palette reaches the screen.

    // matugen's failures are several lines of panic decoration around one line
    // that says what happened. The row has one line to say it in.
    function firstLine(text) {
        if (!text)
            return "";
        for (const raw of text.split("\n")) {
            // The ANSI colouring survives a pipe; it is not a terminal here.
            const line = raw.replace(/\x1b\[[0-9;]*m/g, "").trim();
            if (line === "" || line.startsWith("Location:")
                || line.startsWith("Backtrace") || line.startsWith("Run with"))
                continue;
            if (line.startsWith("Message:"))
                return ": " + line.slice(8).trim();
            return ": " + line;
        }
        return "";
    }
}
