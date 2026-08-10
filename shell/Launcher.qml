pragma Singleton

// The launcher: what `rofi -show drun` and `rofi -show run` were bound to.
//
// Two modes, because two are what the binds used. `drun` lists desktop entries
// with their icons; `run` lists executables on PATH. Everything else rofi can
// do -- window, ssh, calc, dmenu -- is not here, and adding it before anything
// asks would be building against a list of features rather than against a use.
//
// In the shell rather than beside it, for the same reason the wallpaper is: it
// already knows the theme, the font, the focused monitor and the icon search
// path, and a separate process would need all four passed to it and kept in
// step. The old one was themed by writing a .rasi file out of matugen on every
// palette change.
//
// LAYER SHELL with exclusive keyboard focus, not a toplevel window. A launcher
// that is an ordinary window gets tiled by the compositor, appears in the
// window list, and can lose focus to whatever opens behind it -- all three of
// which a launcher must not do.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import Asteroidz.Bar
import "."

Singleton {
    id: root

    property bool open: false
    // "drun" -- desktop entries; "run" -- executables on PATH.
    property string mode: "drun"
    property string query: ""
    property int selected: 0

    function show(which) {
        root.mode = which === "run" ? "run" : "drun";
        root.query = "";
        root.selected = 0;
        if (root.mode === "run")
            pathScan.rescan();
        root.open = true;
    }

    function hide() {
        root.open = false;
        root.query = "";
        root.selected = 0;
    }

    function toggle(which) {
        if (root.open && root.mode === (which === "run" ? "run" : "drun"))
            root.hide();
        else
            root.show(which);
    }

    IpcHandler {
        target: "launcher"

        function drun(): string { root.show("drun"); return "shown"; }
        function run(): string { root.show("run"); return "shown"; }
        function hide(): string { root.hide(); return "hidden"; }
        function toggle(which: string): string {
            root.toggle(which);
            return root.open ? "shown" : "hidden";
        }

        // What this mode would offer for a query, best first, one per line.
        // Read-only: it does not open the launcher, change what is typed in it,
        // or run anything.
        function match(query: string): string {
            return root.rankedFor(query).map(i => i.name).join("\n");
        }
    }

    // ── what gets launched ──────────────────────────────────────────────────

    function launch(entry) {
        if (!entry)
            return;
        Frecency.record(root.mode + ":" + entry.key);
        root.hide();

        if (entry.kind === "app") {
            const de = entry.entry;
            if (de.runInTerminal) {
                // The terminal is the compositor's business, not a list of
                // emulators to try in order: it is already configured as a
                // keybind, so the same command runs here.
                Quickshell.execDetached(["sh", "-c",
                    Cfg.launcherTerminal + " -e " + de.execString]);
                return;
            }
            Quickshell.execDetached({
                command: de.command,
                workingDirectory: de.workingDirectory || undefined,
            });
            return;
        }

        // run mode: what was typed, through a shell, so arguments, pipes and
        // redirections behave the way they do everywhere else a person types a
        // command. A launcher that exec'd argv[0] directly would take
        // `grim -o DP-1 shot.png` and look for a binary with spaces in it.
        Quickshell.execDetached(["sh", "-c", entry.exec]);
    }

    // ── the candidates ──────────────────────────────────────────────────────

    // PATH, scanned once per open in run mode. Not watched: the set changes
    // when something is installed, and re-reading a dozen directories at the
    // moment the launcher opens is cheaper than an inotify watch on all of
    // them for an event that happens weekly.
    property var pathEntries: []
    Process {
        id: pathScan
        function rescan() { running = true; }
        command: ["sh", "-c",
            "IFS=:; for d in $PATH; do [ -d \"$d\" ] && " +
            "find -L \"$d\" -maxdepth 1 -type f -executable -printf '%f\\n' " +
            "2>/dev/null; done | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.split("\n")) {
                    const f = line.trim();
                    if (f)
                        out.push(f);
                }
                root.pathEntries = out;
            }
        }
    }

    // Everything the current mode can offer, before the query narrows it.
    readonly property var pool: {
        if (root.mode === "run")
            return root.pathEntries.map(name => ({
                kind: "exec", key: name, name: name, sub: "", icon: "",
                exec: name,
            }));

        const out = [];
        for (const app of DesktopEntries.applications.values) {
            if (app.noDisplay)
                continue;
            out.push({
                kind: "app",
                key: String(app.id),
                name: app.name || String(app.id),
                sub: app.genericName || app.comment || "",
                icon: app.icon || "",
                entry: app,
            });
        }
        return out;
    }

    // ── matching ────────────────────────────────────────────────────────────
    //
    // Ranked, not filtered. A launcher that only filters falls back to
    // alphabetical order, which for `man` puts "Archive Manager" above
    // "Manuals" -- it has no way to say that one of them STARTS with what was
    // typed. The bands below are that statement, in the order a person means
    // them:
    //
    //   0  the name starts with the query          "man" -> Manuals
    //   1  a word in the name starts with it       "man" -> Archive Manager
    //   2  the name contains it anywhere           "nual" -> Manuals
    //   3  the description or id contains it
    //
    // The pair has to be chosen carefully to mean anything: "Discord" and
    // "Disk Usage Analyzer" look like the obvious example for `dis` and are
    // useless as one, because "Discord" sorts first alphabetically anyway. A
    // test written on that pair passes against a launcher with no ranking at
    // all, which is exactly what happened here.
    //
    // Within a band, whatever has been launched most often comes first. That
    // is the part muscle memory actually depends on: the second character you
    // type should not reorder the thing you were about to press Enter on.
    function rank(item, q) {
        const name = item.name.toLowerCase();
        if (name.startsWith(q))
            return 0;
        for (const word of name.split(/[\s\-_.]+/))
            if (word.startsWith(q))
                return 1;
        if (name.indexOf(q) >= 0)
            return 2;
        const rest = (item.sub + " " + item.key).toLowerCase();
        if (rest.indexOf(q) >= 0)
            return 3;
        return -1;
    }

    // The ranked list for an arbitrary query, without touching what is on
    // screen. `results` is this applied to what is typed; `match` over IPC is
    // this applied to a question -- "what would you run for `dis`" is a
    // reasonable thing for a script to ask, and it is the only way the
    // ORDERING can be asserted from outside, since the order is the feature
    // and a screenshot of a list cannot be read back into names.
    function rankedFor(query) {
        const q = String(query || "").trim().toLowerCase();
        const scored = [];
        for (const item of root.pool) {
            const band = q === "" ? 0 : root.rank(item, q);
            if (band < 0)
                continue;
            scored.push({ item: item, band: band,
                          uses: Frecency.count(root.mode + ":" + item.key) });
        }
        scored.sort((a, b) => {
            if (a.band !== b.band)
                return a.band - b.band;
            if (a.uses !== b.uses)
                return b.uses - a.uses;
            return a.item.name.localeCompare(b.item.name);
        });
        // Capped: a `run` pool is several thousand entries, and a list nobody
        // will scroll to the end of costs a delegate each.
        const out = scored.slice(0, 100).map(s => s.item);

        // Whatever was typed, runnable as a command -- in EITHER mode.
        //
        // The pool is a list of NAMES: desktop entries, or the basenames of
        // everything on PATH. Neither can express `grim -o DP-1 shot.png`,
        // and that is most of what a person types into a run prompt. So the
        // query itself is offered as an entry.
        //
        // LAST, always, and never selected by default. It is one keystroke
        // from `firefox` to `firefox` and if the free-form entry sorted first
        // then Enter on a matched application would launch a shell command
        // that happens to share its name -- silently, and with the arguments
        // parsed differently. Appended after the cap for the same reason: it
        // must not be pushed off the end by a hundred fuzzy matches.
        //
        // Suppressed when it would duplicate the top hit, so typing an exact
        // command name does not offer the same word twice.
        // `raw`, not `q`. Matching is case-insensitive, so `q` is folded --
        // and building the entry out of the folded copy meant the row SAID
        // `grim -o headless-1 /tmp/x.png` for a query typed with a capital in
        // it. Displaying one command and running another is the one thing a
        // run prompt must never do, even when the difference looks harmless:
        // paths and arguments are case-sensitive and shells do not forgive it.
        const raw = String(query || "").trim();
        if (raw !== "" && !(out.length > 0 && out[0].name.toLowerCase() === q))
            out.push({ kind: "exec", key: raw, name: raw, icon: "",
                       sub: "run command", exec: raw });
        return out;
    }

    readonly property var results: root.rankedFor(root.query)

    onResultsChanged: if (root.selected >= root.results.length)
        root.selected = Math.max(0, root.results.length - 1);

    // ── the window ──────────────────────────────────────────────────────────

    LazyLoader {
        active: root.open

        PanelWindow {
            id: win

            // The focused output, so it opens where the person is looking.
            // Falling back to the first screen rather than to none: a launcher
            // that does not appear is indistinguishable from a bind that did
            // not fire.
            screen: {
                const want = Compositor.focusedMonitor;
                for (const s of Quickshell.screens)
                    if (s.name === want)
                        return s;
                return Quickshell.screens[0] || null;
            }

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "asteroidz-launcher"
            // Exclusive, so typing goes here and nowhere else. Without it the
            // keystrokes reach whatever was focused underneath -- which for a
            // launcher opened over a terminal means typing the query into a
            // shell prompt.
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            anchors { top: true; left: true; right: true; bottom: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            // NO blur region, deliberately.
            //
            // The popovers frost themselves through ext-background-effect and
            // this did too. It is the wrong call for a launcher: the panel is
            // a list of names being read while the eye is moving down it, and
            // a moving wallpaper underneath is exactly the kind of noise that
            // costs a fixation per row. The popovers are glanced at; this is
            // read.
            //
            // Not "blur off, still translucent" either -- see the fill below.

            // The screen, dimmed.
            //
            // FIRST, so everything below is drawn over it: the launcher is a
            // layer-shell Overlay surface covering the whole output, so this
            // reaches the bar and any window under it as well. That is the
            // intent -- what is being dimmed is the desktop, not the wallpaper
            // specifically.
            //
            // Not an opacity on the window. The panel is drawn into this same
            // surface, so fading the surface would fade the launcher along
            // with the thing it is meant to stand out from.
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, Cfg.launcherDim)
                visible: Cfg.launcherDim > 0
            }

            // Click-off closes, the way every launcher does.
            MouseArea {
                anchors.fill: parent
                onClicked: root.hide()
            }

            Rectangle {
                id: panel
                anchors.horizontalCenter: parent.horizontalCenter
                // Tighter than it was: half the screen and 900px was a slab.
                // A launcher wants to be the size of the thing you are reading
                // -- a column of names -- not the size of the space available.
                y: Math.round(parent.height * 0.16)
                width: Math.min(Math.round(parent.width * 0.34), 640)
                height: Math.min(field.height + list.contentHeight + pad * 3,
                                 Math.round(parent.height * 0.5))

                // The launcher's own padding, tighter than the popovers'.
                // Cfg.spacing is the bar strip's inter-module gap and it is
                // generous for a list: at 12px per side plus 12 between the
                // field and the rows, a five-item list carried more padding
                // than content.
                readonly property int pad: Math.max(4, Math.round(Cfg.spacing * 0.6))
                radius: Cfg.panelRadius
                // The theme's panel colour with its ALPHA DISCARDED.
                //
                // Still the theme -- the hue comes from the same setting every
                // other surface is filled with, so a palette change moves this
                // with it -- but opaque. Translucency and legibility are in
                // direct conflict here: what shows through a 15% panel is
                // whatever the wallpaper happens to be, and a launcher is read
                // rather than glanced at.
                color: Qt.rgba(Cfg.panelColor.r, Cfg.panelColor.g,
                               Cfg.panelColor.b, 1)
                border.width: 1
                border.color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.12)

                // Swallows the click-off handler above, so clicking inside the
                // panel does not dismiss it.
                MouseArea { anchors.fill: parent }

                Column {
                    anchors.fill: parent
                    anchors.margins: panel.pad
                    spacing: panel.pad

                    Item {
                        id: field
                        width: parent.width
                        height: Math.round(Cfg.fontPixelSize * 1.8)

                        Text {
                            id: prompt
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.mode === "run" ? "run" : "apps"
                            color: Cfg.focusBg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.weight: Cfg.fontWeightEmphasis
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        TextInput {
                            id: input
                            anchors {
                                left: prompt.right
                                leftMargin: Cfg.spacing
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                            }
                            focus: true
                            color: Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.weight: Cfg.fontWeight
                            font.hintingPreference: Font.PreferFullHinting
                            selectByMouse: true
                            onTextChanged: {
                                root.query = text;
                                root.selected = 0;
                            }

                            Keys.onEscapePressed: root.hide()
                            Keys.onDownPressed: root.selected =
                                Math.min(root.selected + 1, root.results.length - 1)
                            Keys.onUpPressed: root.selected =
                                Math.max(root.selected - 1, 0)
                            // Tab moves too. It is what the muscle expects from
                            // a completion prompt, and it is not otherwise used
                            // here.
                            Keys.onTabPressed: root.selected =
                                (root.selected + 1) % Math.max(1, root.results.length)
                            Keys.onReturnPressed: root.accept()
                            Keys.onEnterPressed: root.accept()
                        }

                        Component.onCompleted: input.forceActiveFocus()
                    }

                    ListView {
                        id: list
                        width: parent.width
                        height: parent.height - field.height - panel.pad
                        clip: true
                        model: root.results
                        currentIndex: root.selected
                        // Keeps the selection on screen when it is moved by the
                        // keyboard rather than by the pointer.
                        highlightFollowsCurrentItem: true
                        highlightMoveDuration: 0
                        onCurrentIndexChanged: positionViewAtIndex(
                            currentIndex, ListView.Contain)

                        delegate: Item {
                            required property var modelData
                            required property int index

                            width: list.width
                            height: Math.round(Cfg.fontPixelSize * 1.9)

                            Rectangle {
                                anchors.fill: parent
                                radius: Cfg.themeRadius
                                color: index === root.selected ? Cfg.focusBg
                                                               : "transparent"
                            }

                            // The shell's own Icon, not a hand-rolled Image.
                            //
                            // Icon.qml already carries everything an icon
                            // needs here and each piece of it was learned the
                            // hard way: theme names go through
                            // Quickshell.iconPath, SVGs are rasterised at
                            // twice the box so a scaled output is crisp rather
                            // than an upscale, and BOTH sourceSize dimensions
                            // are asked for -- a width-only request is what
                            // this delegate did, and it is documented there as
                            // the thing that makes theme icons come back
                            // wrong. On a fractionally scaled output the
                            // result was a soft, blurred icon in every row.
                            Icon {
                                id: icon
                                anchors {
                                    left: parent.left
                                    leftMargin: Cfg.spacing
                                    verticalCenter: parent.verticalCenter
                                }
                                name: modelData.icon
                                size: Math.round(Cfg.fontPixelSize * 1.5)
                            }

                            Text {
                                anchors {
                                    left: icon.visible ? icon.right : parent.left
                                    leftMargin: Cfg.spacing
                                    right: sub.left
                                    rightMargin: Cfg.spacing
                                    verticalCenter: parent.verticalCenter
                                }
                                text: modelData.name
                                elide: Text.ElideRight
                                color: index === root.selected ? Cfg.focusFg : Cfg.fg
                                font.family: Cfg.fontFamily
                                font.pointSize: Cfg.fontSize
                                font.weight: Cfg.fontWeight
                                font.hintingPreference: Font.PreferFullHinting
                            }

                            Text {
                                id: sub
                                anchors {
                                    right: parent.right
                                    rightMargin: Cfg.spacing
                                    verticalCenter: parent.verticalCenter
                                }
                                width: Math.min(implicitWidth, parent.width * 0.4)
                                text: modelData.sub
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignRight
                                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.55)
                                font.family: Cfg.fontFamily
                                font.pointSize: Cfg.fontSizeSmall
                                font.weight: Cfg.fontWeight
                                font.hintingPreference: Font.PreferFullHinting
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: root.selected = index
                                onClicked: root.launch(modelData)
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: root.results.length === 0
                            text: root.mode === "run" ? "no such command"
                                                      : "no such application"
                            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.5)
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.weight: Cfg.fontWeight
                            font.hintingPreference: Font.PreferFullHinting
                        }
                    }
                }
            }
        }
    }

    // Enter launches whatever is selected, and what was typed is always one of
    // the things that can be -- rankedFor() appends it as the last entry. It
    // used to be a special case here, reachable only in run mode and only when
    // nothing else matched, which meant a command with arguments could not be
    // run at all while any application's name contained the same letters.
    function accept() {
        if (root.results.length > 0 && root.selected < root.results.length)
            root.launch(root.results[root.selected]);
    }
}
