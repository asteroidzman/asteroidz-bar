// The notification settings.
//
// The shell IS org.freedesktop.Notifications -- see NotificationService.qml --
// so there is no daemon to configure and no second config file to keep in step.
// Every control here writes the bar's own config, which is the same file a
// hand-edit goes into and the same one the popups read.
//
// No Apply bar. Each of these is independently meaningful and takes effect the
// moment it lands: there is nothing to batch, and the toasts are exactly the
// kind of thing you want to see change as you change it. That matches the
// Push-to-talk page and differs from the options pages, where a compositor
// reload is the cost of a write.

import QtQuick
import Quickshell
import Quickshell.Io
import "."
import ".."

Item {
    id: page

    implicitHeight: col.implicitHeight

    // ── the installed sound themes ──────────────────────────────────────────
    //
    // Discovered rather than listed here, because which themes exist is a
    // property of the machine: freedesktop is the only one guaranteed, and
    // this desktop happens to have ocean, gnome and several more.
    //
    // A theme is a directory under `<root>/sounds/` -- the same roots the
    // lookup itself walks -- and it counts only if it actually holds sounds,
    // so a stray empty directory does not become an option that plays nothing.
    property var soundThemes: ["freedesktop"]

    Process {
        id: scanThemes
        running: true
        command: ["sh", "-c",
                  "for r in \"${XDG_DATA_HOME:-$HOME/.local/share}\" "
                  + "$(echo \"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\" | tr ':' ' '); do "
                  + "[ -d \"$r/sounds\" ] || continue; "
                  + "for t in \"$r\"/sounds/*/; do "
                  + "[ -d \"$t\" ] || continue; "
                  + "ls \"$t\" 2>/dev/null | grep -q . && basename \"$t\"; "
                  + "done; done | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.split("\n")) {
                    const t = line.trim();
                    if (t !== "" && out.indexOf(t) < 0)
                        out.push(t);
                }
                // Whatever is configured stays offered even if it is not
                // installed: dropping it would silently rewrite the setting to
                // something else the moment this page was opened.
                if (out.indexOf(Cfg.notifySoundTheme) < 0)
                    out.push(Cfg.notifySoundTheme);
                if (out.length > 0)
                    page.soundThemes = out;
            }
        }
    }

    // Written straight through. `setValue` merges into the group and saves, so
    // a key this page never touches is not disturbed by one that it does.
    function set(key, value) {
        BarConfig.setValue("notify", key, value);
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            text: "Notifications"
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Cfg.fontSize
            font.weight: Font.DemiBold
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This shell is the notification daemon. Nothing else needs to "
                  + "be installed or running — and a second daemon would only "
                  + "race it for the bus name."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.5)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // ── quiet ───────────────────────────────────────────────────────────
        FormRow {
            width: parent.width
            label: "Quiet"
            control: Toggle {
                on: Cfg.notifyDnd
                onToggled: value => page.set("dnd", value)
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Suppresses the popup, never the notification. What arrives "
                  + "still arrives, still lands in the centre and is still "
                  + "counted by the bell."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        FormRow {
            width: parent.width
            label: "Hide over fullscreen"
            control: Toggle {
                on: Cfg.notifyHideOverFullscreen
                onToggled: value => page.set("hide-over-fullscreen", value)
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Toasts draw on the overlay layer, above everything — "
                  + "including a fullscreen film or game, where there is no "
                  + "way to dismiss one without leaving what you are doing. "
                  + "Per screen: a film on one monitor leaves the other alone, "
                  + "and the notification still lands in the centre."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // ── sound ───────────────────────────────────────────────────────────
        FormRow {
            width: parent.width
            label: "Sound"
            control: Toggle {
                on: Cfg.notifySound
                onToggled: value => page.set("sound", value)
            }
        }

        FormRow {
            width: parent.width
            visible: Cfg.notifySound
            label: "Sound name"
            control: Field {
                value: Cfg.notifySoundName
                onCommitted: v => page.set("sound-name", v)
            }
        }

        FormRow {
            width: parent.width
            visible: Cfg.notifySound
            label: "Sound theme"
            control: Picker {
                values: page.soundThemes
                current: Cfg.notifySoundTheme
                onPicked: v => page.set("sound-theme", v)
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "A name from the freedesktop sound-naming spec — "
                  + "<i>message-new-instant</i>, <i>bell</i>, <i>complete</i> — "
                  + "not a path, so it follows whatever sound theme is "
                  + "installed. A sender that names its own sound gets that "
                  + "one, and a sender asking for silence is given it.<br><br>"
                  + "Played with <i>pw-play</i>, from pipewire-audio. Quiet "
                  + "silences this too."
            textFormat: Text.StyledText
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // ── how long, how many ──────────────────────────────────────────────
        //
        // The sliders write on RELEASE, not on every move: `moved` fires
        // continuously through a drag and each one would rewrite the config
        // file. `released` is the one worth persisting.
        FormRow {
            width: parent.width
            label: "Timeout"
            control: Slider {
                from: 1000
                to: 30000
                stepSize: 500
                target: Cfg.notifyTimeout
                onReleased: v => page.set("timeout", Math.round(v))
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Milliseconds, and only when the sender does not say. An "
                  + "application that asks for two seconds gets two seconds, "
                  + "and 0 means \"until dismissed\" — which is honoured, so a "
                  + "failed backup is still there when you come back."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        FormRow {
            width: parent.width
            label: "Max popups"
            control: Slider {
                from: 1
                to: 10
                stepSize: 1
                target: Cfg.notifyMaxPopups
                onReleased: v => page.set("max-popups", Math.round(v))
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Oldest first out. A stack that grows without bound covers "
                  + "the screen, and the ones at the bottom are the ones you "
                  + "have already read."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // ── size ────────────────────────────────────────────────────────────
        FormRow {
            width: parent.width
            label: "Card width"
            control: Slider {
                from: 240
                to: 900
                stepSize: 10
                target: Cfg.notifyWidth
                onReleased: v => page.set("width", Math.round(v))
            }
        }

        FormRow {
            width: parent.width
            label: "Icon size"
            control: Slider {
                from: 16
                to: 96
                stepSize: 2
                target: Cfg.notifyIconSize
                onReleased: v => page.set("icon-size", Math.round(v))
            }
        }

        FormRow {
            width: parent.width
            label: "Centre height"
            control: Slider {
                from: 200
                to: 1200
                stepSize: 20
                target: Cfg.notifyCentreHeight
                onReleased: v => page.set("centre-height", Math.round(v))
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Left unset, all three follow the theme's font size — the "
                  + "card is about 45 characters of body text wide whatever "
                  + "that size is. Setting one here pins it, and the reset "
                  + "below hands it back."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        Item { width: 1; height: Cfg.spacing }

        // Removes the keys rather than writing today's defaults into the file.
        // A number that happens to equal the current default is still a pinned
        // number, and it would stop following the font the moment the theme
        // changed -- the opposite of what "reset" means here.
        SmallButton {
            label: "Reset sizes"
            onClicked: {
                const g = ({});
                for (const k of Object.keys(BarConfig.groups))
                    g[k] = Object.assign(({}), BarConfig.groups[k]);
                if (g.notify) {
                    delete g.notify["width"];
                    delete g.notify["icon-size"];
                    delete g.notify["centre-height"];
                }
                BarConfig.save(undefined, g, undefined);
            }
        }
    }
}
