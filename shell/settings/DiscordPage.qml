// Push-to-talk for Discord: the two keys, and which is which.
//
// This page exists because the distinction is not guessable and getting it
// backwards is the whole failure mode. There are two keys:
//
//   TRIGGER  what you press. asteroidz grabs it through the global-shortcuts
//            portal and CONSUMES it, so no application ever sees it. Free to
//            change, may be a chord, and nothing else needs to be told.
//
//   KEY      what is injected into the X server for Discord's own keybind
//            service to hear. It must equal the key set inside Discord, so
//            changing it means changing Discord too -- which is why it is
//            further down the page and described as such.
//
// Leave `key` alone, set Discord once, and rebind the trigger as often as you
// like. That asymmetry is the point of having two.
//
// Nothing here talks to the bridge process. Every control writes
// ~/.config/asteroidz-bar/discord-ptt.conf, which the bridge watches -- the same
// file the pill's menu writes and the same file the docstring tells people to
// hand-edit. One channel, so an edit behaves identically whichever way it was
// made, and this page cannot drift out of step with a process it does not own.

import QtQuick
import Quickshell
import Quickshell.Io
import "."
import ".."

Item {
    id: page

    implicitHeight: col.implicitHeight

    // ── the conf ────────────────────────────────────────────────────────────

    readonly property string confPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/asteroidz-bar/discord-ptt.conf"

    // The compositor's record of interactively picked bindings. It OUTRANKS the
    // conf's trigger at bind time -- deliberately, so an app cannot undo a key
    // the user chose -- which means the effective trigger is this when it has an
    // entry and the conf otherwise. Showing the conf alone would have this page
    // confidently display a key that is not the one bound.
    readonly property string shortcutsPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/asteroidz/global-shortcuts"

    readonly property string appId: "org.asteroidzman.DiscordPTT"
    readonly property string shortcutId: "push-to-talk"

    property int generation: 0
    property var conf: ({ trigger: "F12", key: "F12" })
    property string picked: ""

    readonly property string effectiveTrigger:
        picked || conf.trigger || "F12"

    // Waiting for the compositor's overlay to take a key. Purely presentational:
    // the picker is modal in the compositor, so this only explains why the
    // window has stopped responding to the keyboard.
    property bool picking: false

    function parseConf(text) {
        const out = { trigger: "F12", key: "F12" };
        for (const raw of (text || "").split("\n")) {
            const line = raw.trim();
            if (!line || line.startsWith("#") || line.indexOf("=") < 0)
                continue;
            const k = line.slice(0, line.indexOf("=")).trim();
            const v = line.slice(line.indexOf("=") + 1).trim();
            if (v && (k === "trigger" || k === "key"))
                out[k] = v;
        }
        return out;
    }

    function parsePicked(text) {
        for (const raw of (text || "").split("\n")) {
            const parts = raw.split("\t");
            if (parts.length >= 3 && parts[0] === page.appId
                    && parts[1] === page.shortcutId)
                return parts[2].trim();
        }
        return "";
    }

    // Rewrite the whole file, keeping every line that is not the one changing.
    //
    // The same rule the plugin's save_conf follows, and for the same reason: the
    // file is documented as hand-editable, so a comment somebody left themselves
    // must survive a click in here.
    function write(key, value) {
        const lines = (confReader.text() || "").split("\n");
        const out = [];
        let seen = false;
        for (const raw of lines) {
            const line = raw.trim();
            const k = line.indexOf("=") >= 0
                ? line.slice(0, line.indexOf("=")).trim() : "";
            if (line && !line.startsWith("#") && k === key) {
                out.push(key + " = " + value);
                seen = true;
            } else {
                out.push(raw);
            }
        }
        if (!seen)
            out.push(key + " = " + value);
        confWriter.setText(out.join("\n").replace(/\n+$/, "") + "\n");
        page.generation++;
    }

    FileView {
        id: confReader
        path: page.confPath
        watchChanges: true
        onLoaded: page.conf = page.parseConf(text())
        onFileChanged: reload()
        // Absent is the normal state: the bridge ships working defaults and
        // only writes this file once something is changed.
        onLoadFailed: page.conf = ({ trigger: "F12", key: "F12" })
    }

    FileView { id: confWriter; path: page.confPath; preload: false }

    FileView {
        id: shortcutsReader
        path: page.shortcutsPath
        watchChanges: true
        onLoaded: {
            const p = page.parsePicked(text());
            if (p && p !== page.picked)
                page.picking = false;   // the overlay took a key
            page.picked = p;
        }
        onFileChanged: reload()
        onLoadFailed: page.picked = ""
    }

    // Asking for the picker.
    //
    // The bridge owns the portal session and only it can start one, so the
    // request travels as a file it watches. That is also what makes this work
    // from the pill on a second monitor, where the clicked instance is a mirror
    // with no session of its own.
    FileView {
        id: pickRequest
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
              + "/asteroidz-discord-ptt.state.pick"
        preload: false
    }

    // ── capturing the injected key ──────────────────────────────────────────

    property bool capturing: false
    property string captureNote: ""

    function captureKey() {
        capturing = true;
        captureNote = "";
        Ipc.request("capture-chord", reply => {
            page.capturing = false;
            if (!reply || reply.ok !== true) {
                // Escape is the documented way out and is not a failure.
                if (!(reply && reply.error === "cancelled"))
                    page.captureNote = (reply && reply.detail) || "capture failed";
                return;
            }
            const chord = reply.chord || "";

            // A chord is not injectable. XTEST sends ONE keycode with no
            // modifier state, so `Super+V` would arrive at Discord as a bare V
            // -- which is worse than refusing, because it would appear to work
            // and then type into whatever had focus.
            if (chord.indexOf("+") >= 0) {
                page.captureNote = "Modifiers cannot be injected — press the "
                    + "key on its own. (Hold them for the key you PRESS "
                    + "instead; that one is grabbed, not replayed.)";
                return;
            }
            // `code:N` is a key the layout gives no name to. The injector looks
            // its target up BY NAME, so there is nothing it could do with this.
            if (chord.startsWith("code:")) {
                page.captureNote = "That key has no name under this layout, so "
                    + "it cannot be named to Discord either.";
                return;
            }
            if (chord && chord !== page.conf.key)
                page.write("key", chord);
        });
    }

    function requestPick() {
        page.picking = true;
        // Non-empty on purpose. The bridge only tests for the file's existence,
        // but setText("") is not reliably a write -- there is nothing to put in
        // the buffer and the call can be elided, leaving no file and a page that
        // waits for a picker nobody was asked for.
        pickRequest.setText("pick\n");
    }

    // The overlay gives up after twelve seconds and this page would otherwise
    // sit claiming to be waiting forever.
    Timer {
        running: page.picking
        interval: 13000
        onTriggered: page.picking = false
    }

    // ── layout ──────────────────────────────────────────────────────────────

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Push-to-talk"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize * 1.15
            font.bold: true
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Discord's own push-to-talk cannot work on Wayland: its "
                + "keybinds live in a native module that talks to X11 directly, "
                + "so it only hears the key while a Discord window has focus. "
                + "asteroidz takes the key globally and replays it into "
                + "XWayland, where Discord is listening."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // ── the key you press ───────────────────────────────────────────────

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            text: "The key you press"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.bold: true
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Taken by the compositor before any application sees it, so "
                + "it can be anything, including a chord. Changing it does not "
                + "require changing anything in Discord."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        Row {
            spacing: Cfg.spacing

            Rectangle {
                width: Math.round(current.implicitWidth + Cfg.fontPixelSize * 1.4)
                height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.5))
                radius: Cfg.themeRadius
                color: Qt.rgba(1, 1, 1, 0.08)

                Text {
                    font.weight: Cfg.fontWeight
                    id: current
                    anchors.centerIn: parent
                    text: page.picking ? "press a key…" : page.effectiveTrigger
                    color: page.picking ? Cfg.focusBg : Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.hintingPreference: Font.PreferFullHinting
                }
            }

            SmallButton {
                anchors.verticalCenter: parent.verticalCenter
                label: page.picking ? "waiting…" : "Rebind…"
                active: page.picking
                onClicked: if (!page.picking) page.requestPick()
            }
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: page.picking
            wrapMode: Text.WordWrap
            text: "Press the key or chord you want, anywhere on screen. "
                + "Escape cancels."
            color: Cfg.focusBg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // ── the key Discord hears ───────────────────────────────────────────

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            text: "The key Discord hears"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.bold: true
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Injected into XWayland, so it must match the key set in "
                + "Discord's own keybind settings — and anything else focused "
                + "in X sees it too, which is why it should be a key you do not "
                + "otherwise use. An X keysym name (F12, Pause, Scroll_Lock). "
                + "There is no reason to change this unless Discord is already "
                + "using the default for something else."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.6)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        Row {
            spacing: Cfg.spacing

            Rectangle {
                width: Math.round(currentKey.implicitWidth + Cfg.fontPixelSize * 1.4)
                height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.5))
                radius: Cfg.themeRadius
                color: Qt.rgba(1, 1, 1, 0.08)

                Text {
                    font.weight: Cfg.fontWeight
                    id: currentKey
                    anchors.centerIn: parent
                    text: page.capturing ? "press a key…"
                                         : (page.conf.key || "F12")
                    color: page.capturing ? Cfg.focusBg : Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.hintingPreference: Font.PreferFullHinting
                }
            }

            // Captured, not typed. What belongs here is an X keysym NAME --
            // `Scroll_Lock`, not "scroll lock" -- and a text box gave no way to
            // learn the spelling: a wrong one resolved to nothing, was injected,
            // discarded by the server, and looked exactly like Discord ignoring
            // push-to-talk.
            //
            // Through the COMPOSITOR's capture-chord, not Qt key events, for the
            // reason BindCard gives: the compositor takes bindings before the
            // focused surface sees them, so a window reading its own keys gets
            // everything except the combinations already bound.
            SmallButton {
                anchors.verticalCenter: parent.verticalCenter
                label: page.capturing ? "waiting…" : "Capture…"
                active: page.capturing
                onClicked: if (!page.capturing) page.captureKey()
            }
        }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            visible: page.captureNote !== ""
            wrapMode: Text.WordWrap
            text: page.captureNote
            color: Cfg.urgent
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        Text {
            font.weight: Cfg.fontWeight
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Discord must be running under XWayland for any of this to "
                + "reach it — a native Wayland Discord has no X connection and "
                + "its keybind service is simply inert. "
                + "~/.local/bin/discord-xwayland starts it correctly."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSizeSmall
            font.hintingPreference: Font.PreferFullHinting
        }
    }
}
