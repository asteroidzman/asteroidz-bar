// asteroidz settings: every configuration option the compositor publishes.
//
// A real toplevel window, not a popover. The popover this grew out of cannot
// hold it and the reasons are structural, not aesthetic: Popover latches its
// width from the panel at open and never resizes (resizing a mapped Wayland
// popup permanently hangs the client), its height is capped at 700 with no
// Flickable so anything past the cap is silently lost, and it is dismissed by
// the first click outside it -- which is every click on any other window while
// you are comparing a setting against its effect. Ninety-five explained options
// with a search box needs a window you can resize, scroll and leave open.
//
// FloatingWindow is an ordinary xdg toplevel, so none of that applies. It is
// exported by Quickshell._Window, which `import Quickshell` pulls in by default.
//
// ── how changes are applied ────────────────────────────────────────────────
//
// Two stages, deliberately:
//
//   preview   memory only, sent as you drag. The compositor's `set-config` has
//             a `persist:false` mode for exactly this, and without it a blur
//             radius or a shadow colour is unadjustable -- you would have to
//             write to disk to see what a value looks like.
//   apply     the staged set, written to the config file, all or nothing.
//
// A preview that is never applied is undone when the window closes. Leaving it
// in place would be a compositor running values that are in no file, which
// reverts at the next reload and looks like settings that forget themselves.

import Quickshell
import QtQuick
import Asteroidz.Bar
import "."
import ".."

FloatingWindow {
    id: win

    title: "asteroidz settings"
    minimumSize: Qt.size(Math.round(Cfg.fontPixelSize * 26),
                         Math.round(Cfg.fontPixelSize * 18))
    implicitWidth: Math.round(Cfg.fontPixelSize * 40)
    implicitHeight: Math.round(Cfg.fontPixelSize * 30)
    // panelColor, not `bg`.
    //
    // Visually this IS a panel -- the same surface the popovers are drawn on --
    // and `bg` is the wrong token for a second reason: nothing stops a theme from
    // setting bg and focus_bg to the same colour, and then the accent that marks
    // the selected group, fills a slider and outlines a focused field is invisible
    // against the surface it is drawn on. The headless test theme does exactly
    // that, which is how this was found.
    //
    // Forced opaque. A toplevel has nothing behind it to blend with -- there is no
    // blur here, unlike the popover -- so a translucent panelColor would show the
    // wallpaper through the text.
    color: Qt.rgba(Cfg.panelColor.r, Cfg.panelColor.g, Cfg.panelColor.b, 1.0)

    // ── selection and search ────────────────────────────────────────────────

    property string group: ""
    property string search: ""

    // Which of the three things this window edits is showing.
    //
    // Separate from `group`, which selects an option GROUP, because rules and
    // binds are not options: they have their own schema, their own verbs, and --
    // the part that shows in the UI -- their own apply model. See applyBar.
    property string page: "options"
    readonly property bool onOptions: page === "options"

    readonly property var shownOptions: {
        void Schema.generation;
        return Schema.options.filter(
            o => (win.group === "" || o.group === win.group)
                 && Schema.matches(o, win.search));
    }

    // ── staged edits ────────────────────────────────────────────────────────
    //
    // key -> the string to write. `null` means "remove the declaration and go
    // back to the default", which is what Reset stages -- distinct from staging
    // the default's value, because that would write the default into the file
    // and leave it there as an explicit setting.
    property var pending: ({})
    // What each staged key was BEFORE anything was previewed, so closing without
    // applying can put the compositor back. Recorded once per key on first touch;
    // re-recording on every drag step would capture the preview as the original.
    property var originals: ({})
    property var overrides: ({})

    readonly property int pendingCount: Object.keys(pending).length
    property string status: ""
    property bool statusBad: false

    function stagedValue(key) {
        void Schema.generation;
        const p = pending[key];
        if (p === undefined)
            return Schema.valueOf(key);
        // A staged removal shows the default, which is what it will become.
        if (p === null) {
            const o = Schema.byKey[key];
            return o ? o.default : "";
        }
        return p;
    }

    function isStaged(key) {
        return pending[key] !== undefined;
    }

    function isOverridden(key) {
        return overrides[key] === true;
    }

    // The value AND where it came from. The kind is what decides how a discard is
    // undone: a key that was at its default can simply be un-set, while one that
    // came from a file has to be re-read from that file or its provenance is lost.
    function rememberOriginal(key) {
        if (originals[key] !== undefined)
            return;
        const e = Schema.entry(key);
        const o = Object.assign({}, originals);
        o[key] = {
            value: Schema.valueOf(key),
            kind: (e && e.source) ? e.source.kind : "default"
        };
        originals = o;
    }

    function stage(key, value) {
        rememberOriginal(key);
        const p = Object.assign({}, pending);
        p[key] = value;
        pending = p;
        status = "";
        // Staged values preview too, so what you see is the value you are about
        // to write. Toggles, pickers and fields all land here.
        if (value !== null)
            preview(key, value);
        else
            previewNow([{ key: key, value: null }]);
    }

    function resetKey(key) {
        // Already at the default and not staged: nothing to do, and staging a
        // removal for a key that has no declaration would ask the compositor to
        // remove something that is not there.
        if (!isStaged(key) && Schema.isDefault(key))
            return;
        rememberOriginal(key);
        const p = Object.assign({}, pending);
        p[key] = null;
        pending = p;
        status = "";
        previewNow([{ key: key, value: null }]);
    }

    function toggleOverride(key) {
        const o = Object.assign({}, overrides);
        if (o[key])
            delete o[key];
        else
            o[key] = true;
        overrides = o;
    }

    // ── preview, coalesced ──────────────────────────────────────────────────
    //
    // A slider drag emits continuously, and one socket per emission is sixty
    // connections a second for a gesture. These collect here and go out together
    // on a short timer, so a drag costs a handful of requests and a drag across
    // two controls costs one request carrying both.

    property var previewQueue: ({})

    function preview(key, value) {
        rememberOriginal(key);
        const q = Object.assign({}, previewQueue);
        q[key] = value;
        previewQueue = q;
        previewTimer.restart();
    }

    Timer {
        id: previewTimer
        interval: 60
        onTriggered: {
            const q = win.previewQueue;
            win.previewQueue = ({});
            const changes = [];
            for (const k in q)
                changes.push({ key: k, value: q[k] });
            if (changes.length > 0)
                win.previewNow(changes);
        }
    }

    function previewNow(changes) {
        Schema.submit(changes, false, reply => {
            // A refused preview is worth saying, because otherwise the control
            // moves and nothing happens and there is no way to tell whether the
            // compositor took it. It is not worth reverting the control over:
            // the number the compositor reports is what the row shows once the
            // refresh lands, so a rejected value visibly snaps back on its own.
            if (reply && reply.ok !== true)
                win.reportFailure(reply);
        });
    }

    function needOverride() {
        for (const k in pending)
            if (!Schema.writableOf(k))
                return true;
        return false;
    }

    function applyPending() {
        if (pendingCount === 0)
            return;
        const changes = [];
        for (const k in pending)
            changes.push({ key: k, value: pending[k] });

        // `override` is a property of the REQUEST, not of a change, so a batch
        // containing one opted-in key would carry it for every foreign key in
        // the batch. Split rather than over-reach: the opted-in ones go in their
        // own request with override set, everything else in a plain one. Two
        // writes instead of one, and no key gets shadowed because a neighbour
        // was.
        const over = changes.filter(c => overrides[c.key] === true);
        const plain = changes.filter(c => overrides[c.key] !== true);

        let outstanding = (over.length ? 1 : 0) + (plain.length ? 1 : 0);
        let failed = null;
        let wrote = 0;

        const done = reply => {
            outstanding--;
            if (reply && reply.ok === true)
                wrote += (reply.applied || 0);
            else if (failed === null)
                failed = reply;
            if (outstanding > 0)
                return;
            if (failed !== null) {
                win.reportFailure(failed);
                return;
            }
            // Only the successfully written keys leave the staged set. Clearing
            // it unconditionally would show "no changes" over a config file that
            // does not contain them.
            win.pending = ({});
            win.originals = ({});
            win.status = wrote + " setting" + (wrote === 1 ? "" : "s")
                         + " saved";
            win.statusBad = false;
        };

        if (plain.length)
            Schema.submit(plain, true, done);
        if (over.length)
            Schema.submitOverride(over, true, done);
    }

    function reportFailure(reply) {
        let msg = (reply && reply.error) ? reply.error : "refused";
        if (reply && reply.detail)
            msg += ": " + reply.detail;
        // The per-change errors are the useful ones -- `out-of-range` carries the
        // bounds, `read-only-source` carries the file -- and the top-level error
        // is often just "one of these failed".
        if (reply && reply.results) {
            for (const r of reply.results) {
                if (r.ok === false && r.error && r.error !== "not-applied") {
                    msg = r.key + ": " + r.error
                          + (r.detail ? " (" + r.detail + ")" : "");
                    break;
                }
            }
        }
        status = msg;
        statusBad = true;
    }

    // Put back whatever was previewed but never applied.
    //
    // Two routes, and which one is used matters:
    //
    //   every touched key was at its DEFAULT -- un-set them. `value: null` removes
    //   the declaration, which is the state they were actually in. Cheap, exact,
    //   and it leaves provenance reading "default" as it should.
    //
    //   any touched key came from a FILE -- reload. Writing the old value back
    //   would leave the value right and the provenance wrong: the compositor
    //   records it as set at runtime, so a key sitting in config.kdl reads back as
    //   "changed in memory, not saved" from then on. That is exactly the confusion
    //   provenance exists to prevent, and the test caught it doing precisely that
    //   after an Apply.
    function discardPending() {
        const nulls = [];
        let anyFromFile = false;
        for (const k in originals) {
            if (originals[k].kind === "file")
                anyFromFile = true;
            nulls.push({ key: k, value: null });
        }
        pending = ({});
        originals = ({});
        overrides = ({});
        previewQueue = ({});
        status = "";
        statusBad = false;
        if (nulls.length === 0)
            return;
        if (anyFromFile)
            Schema.reloadFromDisk();
        else
            Schema.submit(nulls, false, null);
    }

    onVisibleChanged: {
        if (visible)
            Schema.load();
        else
            discardPending();
    }

    // The ship, as this window's icon.
    //
    // Wayland's only mechanism is xdg-toplevel-icon-v1, which Qt drives from
    // QGuiApplication::setWindowIcon -- unreachable from QML, hence the
    // WindowIcon helper in the plugin.
    //
    // A theme NAME, not Logo.source. The protocol carries both a name and pixel
    // buffers and asteroidz records only the name, so an icon built from a file
    // path arrives as buffers and is dropped -- `get all-clients` reported
    // `"icon": ""` for a window that looked correctly iconified from this side.
    // The package installs the ship as `asteroidz-settings` in hicolor for this.
    //
    // It is therefore the packaged ship rather than the accent-recoloured copy
    // Logo.qml writes: recolouring produces a FILE, and a file cannot travel down
    // a channel that carries a name.
    Component.onCompleted: WindowIcon.set("asteroidz-settings")

    // ── layout ──────────────────────────────────────────────────────────────

    Item {
        anchors.fill: parent

        // ── sidebar ─────────────────────────────────────────────────────────
        Rectangle {
            id: sidebar
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.max(Math.round(Cfg.fontPixelSize * 8),
                            Math.round(parent.width * 0.22))
            color: Qt.rgba(1, 1, 1, 0.04)

            Column {
                anchors.fill: parent
                anchors.margins: Cfg.panelPadding
                spacing: 2

                Text {
                    text: "asteroidz"
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.bold: true
                    font.hintingPreference: Font.PreferFullHinting
                }

                Item { width: 1; height: Cfg.spacing }

                // "All" first, then the compositor's groups in the order it
                // declares them -- that order is curated in config-schema.h and
                // sorting it here would throw away the one thing a schema cannot
                // express as a field.
                Repeater {
                    // The option groups, then the two things that are not
                    // options. `page` distinguishes them: an entry with a page of
                    // "options" also selects a group, the other two do not.
                    model: [{ name: "", label: "All settings", page: "options" }]
                        .concat(Schema.groups.map(
                            g => ({ name: g.name, label: g.label,
                                    page: "options" })))
                        .concat([{ name: "", label: "Displays",
                                   page: "displays" },
                                 { name: "", label: "Wallpaper",
                                   page: "wallpaper" },
                                 { name: "", label: "Window rules",
                                   page: "rules" },
                                 { name: "", label: "Keybinds",
                                   page: "binds" },
                                 { name: "", label: "Palette",
                                   page: "palette" },
                                 { name: "", label: "Push-to-talk",
                                   page: "discord" }])

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool selected:
                            win.page === modelData.page
                            && (modelData.page !== "options"
                                || win.group === modelData.name)

                        width: sidebar.width - 2 * Cfg.panelPadding
                        height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.5))
                        radius: Cfg.themeRadius
                        color: selected
                            ? Cfg.focusBg
                            : hover.hovered ? Qt.rgba(1, 1, 1, 0.10)
                                            : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: modelData.label
                            color: parent.selected ? Cfg.focusFg : Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        HoverHandler { id: hover }
                        TapHandler {
                            onTapped: {
                                win.page = modelData.page;
                                win.group = modelData.name;
                                if (modelData.page === "rules"
                                        || modelData.page === "binds")
                                    Rules.load();
                                if (modelData.page === "palette")
                                    Matugen.load();
                                scroll.contentY = 0;
                            }
                        }
                    }
                }
            }

            // Which files the settings come from, and which of them can be
            // written. This is the answer to "why is that greyed out", in the
            // one place a person looks for it.
            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Cfg.panelPadding
                spacing: 1

                Repeater {
                    model: Schema.files
                    delegate: Text {
                        required property var modelData
                        width: parent.width
                        elide: Text.ElideMiddle
                        text: modelData.path.split("/").pop()
                              + (modelData.writable ? "" :
                                 " · " + (modelData.reason || "read-only"))
                        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                                       Cfg.fg.a * (modelData.writable
                                                   ? 0.5 : 0.35))
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.72)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                }
            }
        }

        // ── header: search, and a close that does not depend on decorations ──
        Item {
            id: header
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Cfg.panelPadding
            height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))

            Field {
                id: searchField
                anchors.left: parent.left
                anchors.right: closeBtn.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                // Options only. It searches the option schema, and leaving it on
                // the bind page would be a box that filters nothing -- the bind
                // page carries its own filter, over chords and actions.
                visible: win.onOptions
                placeholder: "Search settings"
                // Round-tripped through `value` so that leaving the field does
                // not wipe what you searched for: Field puts `value` back when it
                // loses focus, and a field with no value to put back goes empty.
                value: win.search
                // Filters as you type rather than on Enter. Search is the one
                // field here where the intermediate states are useful.
                onTextChanged: {
                    win.search = text;
                    scroll.contentY = 0;
                }
            }

            SmallButton {
                id: closeBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                label: "Close"
                // Present even though this is a toplevel with a close button:
                // asteroidz draws no client-side decorations, so under the
                // default window rules there is no titlebar to close from.
                onClicked: win.visible = false
            }
        }

        // ── the options ─────────────────────────────────────────────────────
        Flickable {
            id: scroll
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: applyBar.top
            anchors.margins: Cfg.panelPadding
            clip: true
            contentWidth: width
            contentHeight: rows.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: rows
                width: scroll.width - (scroll.contentHeight > scroll.height
                                       ? Cfg.spacing + 4 : 0)
                spacing: Cfg.spacing

                // The monitors. Kept once built, like the editors below: an
                // arrangement dragged but not applied is exactly the kind of
                // half-finished state that must survive a glance at another
                // page.
                Loader {
                    width: rows.width
                    active: win.page === "displays"
                    visible: active
                    height: active && item ? item.implicitHeight : 0
                    sourceComponent: DisplaysPage {}
                }

                Loader {
                    width: rows.width
                    active: win.page === "wallpaper"
                    visible: active
                    height: active && item ? item.implicitHeight : 0
                    sourceComponent: WallpaperPage {}
                }

                // The rule and bind editors, each built once and kept, so that
                // an expanded card and a half-typed regex survive a trip to the
                // options page and back.
                Loader {
                    width: rows.width
                    active: win.page === "rules"
                    visible: active
                    height: active && item ? item.implicitHeight : 0
                    sourceComponent: RulesPage {}
                }

                Loader {
                    width: rows.width
                    active: win.page === "binds"
                    visible: active
                    height: active && item ? item.implicitHeight : 0
                    sourceComponent: BindsPage {}
                }

                Loader {
                    width: rows.width
                    active: win.page === "palette"
                    visible: active
                    height: active && item ? item.implicitHeight : 0
                    sourceComponent: MatugenPage {}
                }

                // No Apply bar: every control on this page writes the bridge's
                // conf the moment it is used, because there is nothing to batch
                // -- two keys, each independently meaningful, and the bridge
                // applies an edit the instant it lands.
                Loader {
                    width: rows.width
                    active: win.page === "discord"
                    visible: active
                    height: active && item ? item.implicitHeight : 0
                    sourceComponent: DiscordPage {}
                }

                // Not loaded yet, or loaded and there is nothing to show. Both
                // are states a person can land in and neither should render as
                // an empty pane.
                Text {
                    width: parent.width
                    visible: win.onOptions
                             && (!Schema.ready || win.shownOptions.length === 0)
                    wrapMode: Text.WordWrap
                    text: {
                        if (Schema.error !== "")
                            return Schema.error;
                        if (!Schema.ready)
                            return "Reading the schema from the compositor…";
                        if (win.search !== "")
                            return "Nothing matches “" + win.search
                                   + "”.";
                        return "No settings in this group.";
                    }
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.hintingPreference: Font.PreferFullHinting
                }

                Repeater {
                    model: win.onOptions ? win.shownOptions : []

                    delegate: Column {
                        // An id, not `parent.parent`. Counting visual-parent hops
                        // from a nested Text is exactly as fragile as it looks:
                        // one of these headings silently never rendered because
                        // the hop count was off by one, and a `visible` binding
                        // that resolves to `undefined` is false rather than an
                        // error.
                        id: entry
                        required property var modelData
                        required property int index
                        width: rows.width
                        spacing: Cfg.spacing

                        // A heading whenever the group or subgroup changes from
                        // the row above. Derived from the sequence rather than
                        // built as a separate model, so filtering and searching
                        // cannot leave a heading over an empty section or drop
                        // one that is still needed.
                        readonly property var prev: index > 0
                            ? win.shownOptions[index - 1] : null
                        readonly property bool newGroup:
                            prev === null || prev.group !== modelData.group
                        readonly property bool newSub:
                            newGroup
                            || (prev.subgroup || "") !== (modelData.subgroup || "")

                        Column {
                            width: entry.width
                            spacing: 0
                            visible: entry.newGroup || entry.newSub
                            // Air above a heading, but not above the first one --
                            // the pane already has its padding there.
                            topPadding: entry.index === 0 ? 0 : Cfg.spacing

                            Text {
                                // Only where it tells you something: with a group
                                // selected in the sidebar every row is in it, and
                                // repeating its name over the first one is noise.
                                // While searching it is the opposite -- results
                                // come from everywhere and the group is the
                                // context.
                                visible: entry.newGroup
                                         && (win.group === ""
                                             || win.search !== "")
                                text: Schema.groupLabel(modelData.group)
                                color: Cfg.focusBg
                                font.family: Cfg.fontFamily
                                font.pointSize: Cfg.fontSize
                                font.bold: true
                                font.hintingPreference: Font.PreferFullHinting
                            }

                            Text {
                                readonly property string sub:
                                    Schema.subgroupLabel(modelData.subgroup || "")
                                visible: sub !== ""
                                text: sub
                                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                                               Cfg.fg.a * 0.7)
                                font.family: Cfg.fontFamily
                                font.pointSize: Cfg.fontSize
                                font.hintingPreference: Font.PreferFullHinting
                            }
                        }

                        OptionRow {
                            width: entry.width
                            option: modelData
                            view: win
                        }
                    }
                }
            }

            // A scroll position indicator, drawn rather than imported: bringing
            // in QtQuick.Controls for a ScrollBar drags its whole style along,
            // and every other control in this shell is drawn from Cfg.
            Rectangle {
                anchors.right: parent.right
                width: 4
                radius: 2
                visible: scroll.contentHeight > scroll.height
                y: scroll.contentY
                   + (scroll.contentY / Math.max(1, scroll.contentHeight
                                                    - scroll.height))
                     * (scroll.height - height)
                height: Math.max(24, scroll.height * scroll.height
                                     / Math.max(1, scroll.contentHeight))
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.25)
            }
        }

        // ── the apply bar ───────────────────────────────────────────────────
        // Only on the options page.
        //
        // Not a simplification -- the apply models are genuinely different and
        // showing one bar for all of them would lie about at least two.
        //
        //   options    preview live, commit together, written to a config file.
        //   rules and binds are addressed by INDEX and a write renumbers
        //              everything after a removal, so batching two cards' edits
        //              would send the second against an index the first
        //              invalidated. Each card saves itself.
        //   displays   nothing previews -- a mode set is a black screen -- and
        //              Apply sends dispatches, not a config write. That page
        //              draws its own Apply, saying its own terms.
        //   wallpaper and push-to-talk apply on the spot, and have nothing to
        //              batch.
        //
        // The bar that would promise otherwise is absent rather than misleading.
        Rectangle {
            id: applyBar
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: win.onOptions
            height: visible ? Math.max(40, Math.round(Cfg.fontPixelSize * 2.2))
                            : 0
            color: Qt.rgba(1, 1, 1, 0.04)

            // Present and inert when nothing is staged, rather than appearing on
            // first edit -- a bar that materialises pushes the pane up, which
            // moves the control you were about to click next.
            Text {
                anchors.left: parent.left
                anchors.leftMargin: Cfg.panelPadding
                anchors.right: buttons.left
                anchors.rightMargin: Cfg.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                text: {
                    if (win.status !== "")
                        return win.status;
                    if (win.pendingCount === 0)
                        return "Changes preview live · Apply writes them to disk";
                    return win.pendingCount + " change"
                           + (win.pendingCount === 1 ? "" : "s")
                           + " previewing, not yet saved"
                           + (win.needOverride() ? " · some are read-only" : "");
                }
                color: win.statusBad
                    ? Cfg.urgent
                    : (win.pendingCount === 0 && win.status === ""
                       ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                       : Cfg.fg)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.hintingPreference: Font.PreferFullHinting
            }

            Row {
                id: buttons
                anchors.right: parent.right
                anchors.rightMargin: Cfg.panelPadding
                anchors.verticalCenter: parent.verticalCenter
                spacing: Cfg.spacing

                // Both sized to the WIDER of the two labels, so the pair stays
                // symmetric: a Revert narrower than Apply reads as an accident.
                TextMetrics {
                    id: revertMetrics
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    text: "Revert"
                }
                TextMetrics {
                    id: applyMetrics
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    text: "Apply"
                }

                Repeater {
                    model: ["Revert", "Apply"]

                    delegate: Rectangle {
                        required property string modelData
                        readonly property bool primary: modelData === "Apply"
                        readonly property bool live: win.pendingCount > 0

                        width: Math.round(Math.max(revertMetrics.width,
                                                   applyMetrics.width)
                                          + Cfg.fontPixelSize * 2.0)
                        height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))
                        radius: Cfg.themeRadius
                        opacity: live ? 1.0 : 0.4
                        color: primary && live ? Cfg.focusBg
                                               : Qt.rgba(1, 1, 1, 0.08)

                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: parent.primary && parent.live
                                ? Cfg.focusFg : Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        TapHandler {
                            enabled: parent.live
                            onTapped: {
                                if (parent.primary)
                                    win.applyPending();
                                else
                                    win.discardPending();
                            }
                        }
                    }
                }
            }
        }
    }
}
