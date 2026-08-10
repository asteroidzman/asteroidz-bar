pragma Singleton

// The lock screen.
//
// ext-session-lock-v1, spoken from the shell rather than by a separate locker.
// The compositor already implements the protocol's side of it; what was missing
// was a client, and `idle { lock-command }` filled that gap by spawning one --
// swaylock, with its own config file, its own theme, and its own idea of what
// the wallpaper is. It could not show the wallpaper this desktop is actually
// displaying, because the wallpaper is drawn by this process.
//
// The protocol is what makes this safe to own. A lock client that crashes does
// NOT drop the lock: the compositor keeps every output blanked until something
// authenticates, which is the opposite failure of a locker that is just a
// fullscreen window. So the worst this file can do by breaking is leave the
// session locked, and the session staying locked is the safe direction.
//
// The wallpaper is drawn HERE rather than left showing through. A session lock
// hides every other surface, the wallpaper included -- it is a layer-shell
// surface like any other -- so "show the current wallpaper" means drawing it
// again on the lock surface. It goes through Paths.wallpaperThumb() so an HDR
// file arrives tone mapped instead of as raw PQ; the lock screen is an sRGB
// surface and a 1000-nit sunset drawn as plain gamma is a grey rectangle.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import QtQuick
import Asteroidz.Bar
import "."

Singleton {
    id: root

    // Requested, not commanded: WlSessionLock.locked is what actually holds
    // the session, and the compositor decides when it takes effect.
    property bool locked: false

    // What the compositor says, which is the only thing worth believing. A
    // lock that was asked for and refused must not read as locked to anything
    // else in the shell.
    readonly property bool active: session.locked

    // Somebody else's locker, if one was named.
    //
    // `idle { lock-command }` is a statement about which locker this desktop
    // uses, not about idling -- it was only ever in that block because the
    // idle timeout was the only thing that locked. So it is read HERE, and
    // every way of locking goes through this one function: the power menu, the
    // idle timeout and `ipc call lock lock` cannot disagree about what Lock
    // means, which they did when each carried its own answer.
    readonly property string command:
        Cfg.strOrEmpty(BarConfig.groups.idle || ({}), "lock-command", "")

    function lock() {
        if (root.command) {
            Quickshell.execDetached(["sh", "-c", root.command]);
            return;
        }
        if (root.locked)
            return;
        root.locked = true;
    }

    // NOT exposed over IPC, and that is the whole point of it being here.
    // Anything that can call this can unlock the machine, so the only caller
    // is the surface below, after PAM has said yes.
    function releaseAfterAuth() {
        root.locked = false;
    }

    // ── the way in ──────────────────────────────────────────────────────────
    //
    // Locking is safe to expose; unlocking is not. A bind runs `asteroidz-bar
    // ipc call lock lock`, and there is deliberately no matching `unlock`:
    // an IPC socket that can unlock the session is a lock screen with a hole
    // in it, and the socket is reachable by anything running as this user --
    // which is exactly what the lock exists to stop mattering.
    IpcHandler {
        target: "lock"

        function lock(): string {
            root.lock();
            return "locked";
        }

        // Status, so a bind or a script can tell without guessing.
        function status(): string {
            return session.locked ? "locked" : "unlocked";
        }
    }

    WlSessionLock {
        id: session
        locked: root.locked

        surface: WlSessionLockSurface {
            id: surface

            // Black underneath, so nothing of the desktop is ever visible in
            // the gap between the surface being mapped and the wallpaper
            // finishing its decode.
            color: "black"

            // Which wallpaper THIS output is showing. In per-monitor scope the
            // two screens can differ, and a lock screen that showed the shared
            // one on both would be showing a picture that is on neither.
            readonly property string wallpaper: {
                void Wallpaper.storedPerMonitor;
                const name = surface.screen ? surface.screen.name : "";
                return (name ? Wallpaper.wallpaperFor(name) : "") || Wallpaper.path;
            }

            Image {
                anchors.fill: parent
                // Decoded at the screen's own size: this is a full-screen
                // image, not a tile, and asking for less would upscale a
                // thumbnail across a 4K panel.
                source: surface.wallpaper
                    ? Paths.wallpaperThumb(surface.wallpaper,
                                           Math.max(surface.width, surface.height))
                    : ""
                fillMode: {
                    switch (Wallpaper.mode) {
                    case "stretch": return Image.Stretch;
                    case "fit":     return Image.PreserveAspectFit;
                    case "center":  return Image.Pad;
                    case "tile":    return Image.Tile;
                    default:        return Image.PreserveAspectCrop;
                    }
                }
                // Synchronous. The surface is already up and black by the time
                // this runs, and a lock screen that fades its wallpaper in is
                // a lock screen that spends its first half second looking like
                // it failed.
                asynchronous: false
                cache: false
            }

            // Enough shade to read white text over a bright wallpaper, and not
            // so much that the wallpaper stops being the thing on screen. A
            // gradient rather than a flat wash: the text sits in the middle,
            // so that is the only band that needs it.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.15) }
                    GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.45) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.15) }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: Math.round(surface.height * 0.012)

                // The clock, at a size taken from the SCREEN rather than from
                // the bar's font size. The bar's font is sized for a 24px
                // strip; the same number across a 4K panel is a caption, not a
                // clock.
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, Cfg.lockClockFormat)
                    color: "white"
                    font.family: Cfg.fontFamily
                    font.weight: Cfg.fontWeight
                    font.pixelSize: Math.round(surface.height * 0.14)
                    font.hintingPreference: Font.PreferFullHinting
                    style: Text.Raised
                    styleColor: Qt.rgba(0, 0, 0, 0.55)
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, Cfg.lockDateFormat)
                    color: Qt.rgba(1, 1, 1, 0.85)
                    font.family: Cfg.fontFamily
                    font.weight: Cfg.fontWeight
                    font.pixelSize: Math.round(surface.height * 0.030)
                    font.hintingPreference: Font.PreferFullHinting
                    style: Text.Raised
                    styleColor: Qt.rgba(0, 0, 0, 0.55)
                }

                Item { width: 1; height: Math.round(surface.height * 0.05) }

                // ── the way out ─────────────────────────────────────────────
                //
                // No visible field until there is something to show. A lock
                // screen's job is to display the machine's state, and an empty
                // box asking for a password is a worse first impression than a
                // clock -- but the moment a key is pressed the person needs to
                // see that it registered, so it appears with the first
                // character and stays for as long as PAM has something to say.
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.round(surface.width * 0.22)
                    height: Math.round(surface.height * 0.045)
                    opacity: entry.text.length > 0 || pam.active
                             || surface.notice !== "" ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: Qt.rgba(0, 0, 0, 0.45)
                        border.width: 1
                        border.color: surface.noticeIsError
                            ? Qt.rgba(1, 0.35, 0.35, 0.8)
                            : Qt.rgba(1, 1, 1, 0.25)
                    }

                    // Dots, not characters. Nothing here echoes the password,
                    // and the count is capped so a shoulder-surfer cannot read
                    // the length off the screen either.
                    Text {
                        anchors.centerIn: parent
                        text: "•".repeat(Math.min(entry.text.length, 12))
                        color: "white"
                        font.family: Cfg.fontFamily
                        font.weight: Cfg.fontWeight
                        font.pixelSize: Math.round(parent.height * 0.42)
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: surface.notice
                    visible: surface.notice !== ""
                    color: surface.noticeIsError ? Qt.rgba(1, 0.55, 0.55, 1)
                                                 : Qt.rgba(1, 1, 1, 0.8)
                    font.family: Cfg.fontFamily
                    font.weight: Cfg.fontWeight
                    font.pixelSize: Math.round(surface.height * 0.018)
                    font.hintingPreference: Font.PreferFullHinting
                }
            }

            property string notice: ""
            property bool noticeIsError: false

            SystemClock {
                id: clock
                // Seconds only if the format asks for them: a lock screen that
                // repaints every second on every output for a clock with no
                // seconds in it is a wakeup per second for nothing.
                precision: Cfg.lockClockFormat.indexOf("s") >= 0
                    ? SystemClock.Seconds : SystemClock.Minutes
            }

            // The keyboard. A TextInput rather than a hand-rolled key handler
            // because it already knows about input methods, dead keys, compose
            // sequences and paste -- all of which are ways a real password gets
            // typed, and all of which a key-by-key handler gets wrong for
            // exactly the people who cannot then log in.
            TextInput {
                id: entry
                focus: true
                // Never drawn -- the dots above are what is on screen -- but
                // it carries the theme font anyway. An invisible element with
                // a different font is a trap for whoever makes it visible.
                visible: false
                font.family: Cfg.fontFamily
                font.weight: Cfg.fontWeight
                echoMode: TextInput.Password
                enabled: !pam.active

                onAccepted: {
                    if (text.length === 0)
                        return;
                    surface.notice = "";
                    surface.noticeIsError = false;
                    pam.start();
                }

                Keys.onEscapePressed: {
                    entry.text = "";
                    surface.notice = "";
                }
            }

            // Focus follows the surface: a lock screen you have to click
            // before you can type is a lock screen people think has frozen.
            onVisibleChanged: if (visible) entry.forceActiveFocus()
            Component.onCompleted: entry.forceActiveFocus()

            PamContext {
                id: pam
                // Its own file rather than borrowing another package's.
                // Depending on /etc/pam.d/swaylock would mean the lock screen
                // stops working when swaylock is uninstalled, which is exactly
                // the sort of dependency nobody remembers having.
                config: "asteroidz-bar"

                onPamMessage: {
                    if (this.responseRequired) {
                        this.respond(entry.text);
                        return;
                    }
                    if (this.message !== "") {
                        surface.notice = this.message;
                        surface.noticeIsError = this.messageIsError;
                    }
                }

                onCompleted: result => {
                    entry.text = "";
                    if (result === PamResult.Success) {
                        root.releaseAfterAuth();
                        return;
                    }
                    surface.noticeIsError = true;
                    surface.notice = result === PamResult.MaxTries
                        ? "too many attempts" : "wrong password";
                    entry.forceActiveFocus();
                }

                onError: err => {
                    // A PAM stack that cannot even be started is the one
                    // failure that must be LOUD: the session stays locked and
                    // there is no way in from here, so the message has to say
                    // what to fix rather than "wrong password".
                    entry.text = "";
                    surface.noticeIsError = true;
                    surface.notice = "PAM error (" + err + ") -- check /etc/pam.d/asteroidz-bar";
                    entry.forceActiveFocus();
                }
            }
        }
    }
}
