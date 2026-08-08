pragma Singleton

// The calendar's command surface.
//
// It exists because of a hole in the panel: the Reauthorise button there is
// conditional on Calendar.needsAuth, which is correct as an affordance -- a
// "reauthorise" button sitting in your face while the login works is noise --
// but it means authorize() is unreachable until the login has ALREADY failed.
// That is the one path a calendar depends on at exactly the moment it is
// broken, and it could not be exercised or tested while things were healthy.
//
// So the actions live here as well, where a keybind or a terminal can reach
// them:
//
//   qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar authorize
//   qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar sync
//   qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar status
//
// A singleton, not a handler in the clock module: a module is instantiated
// once per bar, and two bars registering the same IPC target means one wins
// and the other is discarded with a warning. ClipboardService says the same
// thing at more length, having learned it the hard way.

import Quickshell
import Quickshell.Io
import Asteroidz.Bar

Singleton {
    id: root

    // Show the Reauthorise button even though nothing is wrong.
    //
    // The button is conditional on needsAuth, which is the right affordance --
    // one sitting in your face while the login works is noise -- but it also
    // means the button cannot be SEEN, let alone clicked, until the login has
    // already failed. This reveals it on demand so the whole path can be
    // exercised while things are healthy.
    //
    // Session-only, and deliberately not a config key: it is a way to test a
    // button, not a preference. It resets when the shell restarts, so nobody
    // can leave it on and forget.
    property bool revealAuth: false

    IpcHandler {
        target: "calendar"

        // `ipc call calendar showAuth` -- reveals the button until the shell
        // restarts. Toggles, so the same command puts it away again.
        function showAuth(): string {
            root.revealAuth = !root.revealAuth;
            return root.revealAuth
                ? "Reauthorise button shown (until restart)"
                : "Reauthorise button hidden again";
        }

        // Opens the browser for a fresh consent. Safe to run while the login
        // is healthy -- that is the point of it being here -- because Google
        // issues a new refresh token and the old one keeps working until it
        // does.
        function authorize(): string {
            if (!Calendar.configured)
                return "no account configured: this will start a first login";
            Calendar.authorize();
            return "browser opened for " + (Calendar.account || "the account");
        }

        function sync(): string {
            Calendar.sync();
            return Calendar.syncing ? "syncing" : "already up to date";
        }

        // Deliberately reports COUNTS and flags, never event contents: a
        // command you might run over SSH or paste into a bug report should not
        // print what is in your calendar.
        function status(): string {
            return "configured=" + Calendar.configured
                 + " needsAuth=" + Calendar.needsAuth
                 + " syncing=" + Calendar.syncing
                 + " calendars=" + Calendar.calendars.length
                 + " events=" + Calendar.events.length
                 + " lastSync=" + (Calendar.lastSync || "never")
                 + (Calendar.error !== "" ? " error='" + Calendar.error + "'" : "");
        }
    }
}
