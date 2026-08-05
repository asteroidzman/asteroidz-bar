// A plugin's pill: whatever the process last said it should be.
//
// The protocol is the compositor's, unchanged -- one JSON object per line on
// stdout, events back on stdin -- because the plugins are the point. Three of
// them already exist and are used daily; a "better" schema would have bought
// nothing and broken all of them.
//
//   {"text":"Idle","icon":"asteroidz-bar/discord-voice/discord.svg","tint":"accent"}
//   {"menu":{"item":"","rows":[{"text":"Mute","value":"do:mute"}]}}
//   {"hidden":true}
//
// Two transports, as before: `interval N` runs the command every N seconds and
// reads one object, `continuous true` keeps one process up and reads a stream.
// Only a continuous plugin gets the event channel, because only a long-lived
// process is there to read it.

import Quickshell
import Quickshell.Io
import QtQuick
import ".."

Pill {
    id: root

    // This bar's size factor -- see Sizes.qml.
    readonly property real f:
        QsWindow.window && QsWindow.window.uiFactor !== undefined
            ? QsWindow.window.uiFactor : 1
    function px(v) { return Math.round(v * f); }

    // The `custom "<name>" { }` block this pill is, straight from the
    // compositor's config.
    property var plugin: ({})
    property var bar: null

    readonly property string name: plugin.name || ""
    readonly property bool continuous: plugin.continuous === true
    readonly property int interval: plugin.interval || 0

    // What the plugin last said. Kept whole rather than unpacked into
    // properties so a partial update cannot leave half the old state behind.
    property var state: ({})

    // `shown`, not `visible` -- see ModuleLoader: the slot is what hides, and
    // Item.visible is effective visibility, which would latch this off.
    shown: state.hidden !== true
           && (!!state.text || !!state.icon || icons.length > 0)

    text: state.text || ""
    icons: {
        const i = state.icon || plugin.icon || "";
        if (!i)
            return [];
        // "icon" may be one name or an array of them: the discord plugin draws
        // its logo AND a mute glyph, which is two icons in one pill.
        return Array.isArray(i) ? i : [i];
    }

    // The pill's own background, resolved first: everything drawn ON it has to
    // be legible against it, and only this line knows what it is.
    bg: state.class === "urgent" ? Cfg.urgent
      : state.class === "active" ? Cfg.focusBg
      : "transparent"

    // Named tints resolve against the theme; anything else is passed to Qt,
    // so a plugin can send "#e5a50a" for a state the theme has no word for.
    iconTint: {
        const t = state.tint || "";
        let c;
        switch (t) {
        case "": return "transparent";
        case "fg": c = Cfg.fg; break;
        case "accent": c = Cfg.focusBg; break;
        case "urgent": c = Cfg.urgent; break;
        case "dim":
            c = Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45);
            break;
        default: c = t; break;
        }
        // A tint names a colour for a pill with no background of its own.
        // The same plugin usually asks for `urgent` in both places at once --
        // "this is due" -- and an urgent icon on an urgent pill is invisible.
        return Cfg.legibleOn(c, bg);
    }

    fg: state.class === "active" ? Cfg.focusFg : Cfg.legibleOn(Cfg.fg, bg)

    // Icon-only plugins join the tight run of status artwork; one with a label
    // is padded like any other labelled pill.
    paddingX: text === "" ? 0 : px(Cfg.pillPadding)

    // ── the process ─────────────────────────────────────────────────────────

    function handle(obj) {
        if (obj.menu) {
            if (!bar)
                return;
            // `value` means two different things either side of this line, and
            // conflating them left every editable row showing its own field
            // name where the typed text should be. To a PLUGIN, value is the
            // row's id -- what comes back when the row is picked, and for an
            // editable row the name of the field. To the POPOVER, value is the
            // CONTENT of an editable row: the text drawn after the label and
            // rewritten on every keystroke. So they travel separately: `action`
            // is the id, `field` the name, and `value` starts as whatever the
            // plugin prefilled (`edit`) and is the field's text from then on.
            const rows = (obj.menu.rows || []).map(r => ({
                text: r.text || "",
                icon: r.icon || "",
                enabled: r.enabled !== false,
                separator: r.separator === true,
                submenu: r.submenu === true,
                checked: r.selected === true,
                input: r.input === true,
                // A bounded number, chosen with arrows rather than typed:
                // {min, max, step, wrap, pad}. It carries its value in the
                // same two places a text field does -- `field` names it and
                // `value` holds it -- so it comes back in `fields` with
                // everything else and the plugin reads it the same way.
                spin: (r.spin && typeof r.spin === "object") ? r.spin : null,
                action: r.value || "",
                field: (r.input === true || r.spin) ? (r.value || "") : "",
                value: (r.input === true || r.spin) ? (r.edit || "") : "",
                plugin: root
            }));
            // An empty menu is a plugin saying "nothing to offer", which is
            // the right answer after acting on a leaf -- and it closes the
            // panel rather than leaving stale rows claiming to be actionable.
            bar.showPluginMenu(root, rows);
            return;
        }
        root.state = obj;
    }

    function send(obj) {
        if (proc.running && root.continuous)
            proc.write(JSON.stringify(obj) + "\n");
    }

    // ── where this machine is ───────────────────────────────────────────────
    //
    // Sent unasked, because a plugin that wants sunrise, a tide table or a
    // local forecast should not have to geolocate for itself: three plugins
    // doing that would be three IP lookups a session and three chances to
    // disagree about where you are. The shell resolves it once
    // (Location.qml) and tells them.
    //
    // An event like any other, so a plugin that does not care simply ignores
    // an object whose `event` it does not recognise -- which they all already
    // do.
    function sendLocation() {
        if (!Location.known)
            return;
        send({
            event: "location",
            lat: Location.lat,
            lon: Location.lon,
            place: Location.place
        });
    }

    // Both directions, because either can be the late one: a plugin can start
    // before the lookup answers, and the lookup can have answered long before
    // a plugin added by a config reload starts.
    Connections {
        target: Location
        function onChanged() { root.sendLocation(); }
    }
    onContinuousChanged: if (continuous) startupLocation.restart()
    Timer {
        id: startupLocation
        // After the plugin's own first output, so its opening state is not
        // racing an event it may not be ready to read yet.
        interval: 1500
        onTriggered: root.sendLocation()
    }

    // Stop the plugins when this module goes away.
    //
    // Belt to the plugins' own braces. They exit on stdin EOF now, which covers
    // every way the bar can die including being killed outright -- but relying
    // on the child to notice makes shutdown asynchronous, and a module that is
    // being torn down while the shell keeps running (a config reload dropping a
    // custom block) would otherwise leave a process attached to a pipe nobody
    // reads.
    //
    // The leak this closes was real and quiet: 27 plugin processes across five
    // previous bar sessions, the oldest a day old, still polling. Nothing killed
    // them and nothing made them stop -- see exit_with_the_bar() in the plugins,
    // and note that a write to the dead pipe never raised BrokenPipeError
    // because emit() deduplicates and an unchanged plugin writes nothing at all.
    Component.onDestruction: {
        proc.running = false;
        poll.running = false;
    }

    Process {
        id: proc
        command: (root.plugin.exec || "").split(" ").filter(s => s.length > 0)
        running: root.continuous && command.length > 0
        stdinEnabled: root.continuous

        stdout: SplitParser {
            onRead: line => {
                if (!line.trim())
                    return;
                // Parsed and handled SEPARATELY, and this is not tidiness.
                //
                // Both used to sit in one try, so an exception thrown by
                // handle() was reported as "bad JSON from <plugin>" -- blaming
                // the plugin for the bar's own fault, with no way to tell the
                // two apart. That cost a real hunt: a startup warning sent me
                // through the plugin's every write path looking for a
                // malformed line that was never there.
                //
                // The offending text goes in the message for the same reason.
                // "Something was wrong somewhere" is not a diagnosis, and the
                // line is right here.
                let obj;
                try {
                    obj = JSON.parse(line);
                } catch (e) {
                    // A malformed line is the plugin's problem. Dropping it
                    // beats tearing down a process that will very likely
                    // deliver a good line next time -- the native runtime made
                    // the same call.
                    console.warn("asteroidz-bar: bad JSON from", root.name + ":",
                                 line.length > 200 ? line.slice(0, 200) + "…"
                                                   : line);
                    return;
                }
                try {
                    root.handle(obj);
                } catch (e) {
                    console.warn("asteroidz-bar: failed to handle a line from",
                                 root.name + ":", e);
                }
            }
        }

        // stderr is NOT discarded: a plugin that cannot start says so there,
        // and swallowing it makes "the pill never appeared" unexplainable.
        stderr: SplitParser {
            onRead: line => {
                if (line.trim())
                    console.warn("asteroidz-bar:", root.name + ":", line);
            }
        }
    }

    // The polled transport. One process per tick, output collected whole:
    // a plugin that prints its object and exits has no stream to split.
    Process {
        id: poll
        command: proc.command
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of text.split("\n")) {
                    if (!line.trim())
                        continue;
                    // Split the same way as the streaming transport above, and
                    // for the reason given there.
                    let obj;
                    try {
                        obj = JSON.parse(line);
                    } catch (e) {
                        console.warn("asteroidz-bar: bad JSON from",
                                     root.name + ":",
                                     line.length > 200 ? line.slice(0, 200) + "…"
                                                       : line);
                        continue;
                    }
                    try {
                        root.handle(obj);
                    } catch (e) {
                        console.warn("asteroidz-bar: failed to handle a line from",
                                     root.name + ":", e);
                    }
                }
            }
        }
    }

    Timer {
        interval: Math.max(1, root.interval) * 1000
        running: !root.continuous && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!poll.running) poll.running = true
    }

    Component.onCompleted: {
        // interval 0 with no `continuous` means "run it once at startup",
        // which is how a plugin that reports something static is written.
        if (!root.continuous && root.interval === 0
            && (root.plugin.exec || "") !== "")
            poll.running = true;
    }

    // ── interaction ─────────────────────────────────────────────────────────

    onClicked: button => {
        const which = button === Qt.RightButton ? "right"
                    : button === Qt.MiddleButton ? "middle" : "left";

        // Clicking the pill while its own menu is up closes it, here rather
        // than by asking the plugin. Now that a plugin's menu replaces its own
        // rows in place instead of toggling the panel, sending this click on
        // would have the plugin answer with the same menu again and the panel
        // would have no way to close from its own pill.
        if (bar && bar.menuBelongsTo(root)) {
            bar.closeMenu();
            return;
        }

        // A configured on-click command wins: it is the simple case, and a
        // plugin that wanted to handle the click itself would not have set one.
        const cmd = which === "right" ? plugin.on_click_right : plugin.on_click;
        if (cmd) {
            Quickshell.execDetached(["sh", "-c", cmd]);
            return;
        }
        send({ event: "click", button: which });
    }

    onWheel: delta =>
        send({ event: "scroll", direction: delta > 0 ? "up" : "down" })
}
