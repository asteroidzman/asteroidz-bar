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
    readonly property string matugenBin:
        Quickshell.env("ASTEROIDZ_MATUGEN_BIN") || "matugen"

    // The packaged template, for seeding a user copy that is not there yet.
    //
    // The package deliberately does not write into ~/.config -- that would
    // overwrite a tuned template, and would do it on every upgrade. Seeding here
    // is safe because it happens only when the file is absent, which is the one
    // moment where copying cannot destroy anything.
    readonly property string shippedTemplate:
        Quickshell.env("ASTEROIDZ_MATUGEN_SHIPPED")
        || "/usr/share/asteroidz-bar/matugen/asteroidz-colors.kdl"

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

    // key -> { role, gray, owned }
    property var mapping: ({})
    property var roles: []
    property bool loaded: false
    property string status: ""
    property bool statusBad: false
    property bool busy: false
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
        roleProbe.running = true;
        mapFile.reload();
        templateFile.reload();
    }

    function parseMapping(text) {
        const out = {};
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
        return out;
    }

    function serialiseMapping() {
        const lines = [
            "# Which Material role each asteroidz colour is generated from.",
            "# Written by the settings window; `off` means matugen does not set it.",
            ""
        ];
        for (const d of keys) {
            const e = entry(d.key);
            lines.push(d.key + "=" + (!e.owned ? "off"
                : e.role + (e.gray ? ":grayscale" : "")));
        }
        return lines.join("\n") + "\n";
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
        }
        onLoadFailed: {
            // No mapping yet. Seed from the template if there is one, so the
            // first Apply reproduces what is already there rather than
            // overwriting it with defaults.
            root.mapping = ({});
            templateFile.reload();
            root.loaded = true;
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

    // The role list, from the installed matugen rather than from a table here.
    //
    // --dry-run is load-bearing: without it this would render every template the
    // user has and fire every post-hook -- reloading waybar, kitty and the
    // compositor -- just to find out what the roles are called.
    Process {
        id: roleProbe
        command: [root.matugenBin, "--dry-run", "-q", "color", "hex",
                  "#3f6ded", "--json", "hex"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text);
                    root.roles = Object.keys(d.colors || {}).sort();
                } catch (e) {
                    root.status = "could not read matugen's role list";
                    root.statusBad = true;
                }
            }
        }
        onExited: (code, _) => {
            if (code !== 0 && root.roles.length === 0) {
                root.status = "matugen is not installed, or refused to run";
                root.statusBad = true;
            }
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

    // ── applying ────────────────────────────────────────────────────────────

    function apply(wallpaper) {
        if (busy)
            return;
        busy = true;
        status = "";
        statusBad = false;
        // The mapping first, so a matugen run that fails still leaves the
        // choice recorded -- otherwise the page would forget what you picked
        // because the tool it drives was missing.
        mapWriter.setText(serialiseMapping());
        backupWriter.setText(templateFile.text());
        templateWriter.setText(renderTemplate());
        if (wallpaper && wallpaper !== "") {
            render.command = [root.matugenBin, "image", wallpaper];
            render.running = true;
        } else {
            busy = false;
            status = "template written; no wallpaper set, so nothing was rendered";
        }
    }

    FileView { id: mapWriter;      path: root.mapPath;              preload: false }
    FileView { id: templateWriter; path: root.templatePath;         preload: false }
    // The previous template, kept beside it. The same promise the config writer
    // makes: an Apply must never be the thing that loses a file you tuned.
    FileView { id: backupWriter;   path: root.templatePath + ".bak"; preload: false }

    // The real thing: render every template and run every post-hook, which is
    // exactly what a wallpaper change does. One of those hooks reloads the
    // compositor, which is how the new palette reaches the screen.
    Process {
        id: render
        onExited: (code, _) => {
            root.busy = false;
            if (code === 0) {
                root.status = "palette applied";
                root.statusBad = false;
            } else {
                root.status = "matugen failed (exit " + code + ")";
                root.statusBad = true;
            }
        }
    }
}
