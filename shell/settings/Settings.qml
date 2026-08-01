pragma Singleton

// The settings window, at most one of it.
//
// A singleton because the window has to be reachable from anywhere that wants to
// offer a way in -- the display panel today, a keybind later -- and because two
// of them staging different edits against the same compositor is a way to lose
// changes with no warning.
//
// Built on first open, not at startup. A bar that never opens settings should not
// pay for the object tree or the schema fetch behind it, and `visible` on an
// unmapped toplevel is not the same as not having one: a hidden window still
// holds its Flickable, its Repeaters and its bindings.
//
// createObject rather than LazyLoader: the loader's `active` has its own opinion
// about window visibility, and the interesting state here is "does the window
// exist yet", which is exactly what a null check answers.

import Quickshell
import QtQuick
import "."
// For Ipc: fetching an already-open window is the compositor's job, not a
// client's, so this singleton needs the socket as well as the window.
import ".."

Singleton {
    id: root

    property var window: null

    Component {
        id: windowComponent
        SettingsWindow {}
    }

    function open() {
        const existed = window !== null;
        if (!existed)
            window = windowComponent.createObject(root);
        if (window === null)
            return;
        window.visible = true;
        window.minimized = false;
        // An already-open window has to be fetched by the COMPOSITOR.
        //
        // This is what made a second "All settings…" look broken. The window was
        // still there, on whichever tag it was opened from, and a client cannot
        // raise itself on Wayland -- there is no protocol for it. So the press
        // reused the existing window, correctly, and from the far side of a tag
        // switch that is indistinguishable from nothing happening.
        //
        // The bar is not limited to what a client can do: it has the
        // compositor's IPC. focus_id runs client_active(), which switches to the
        // window's tag, un-minimises it and focuses it.
        if (existed)
            summon();
    }

    // Ask the compositor to bring the settings window here.
    //
    // Matched on title, not app-id: every window this shell owns shares one
    // app-id, so matching that could summon the bar itself.
    function summon() {
        Ipc.request("get all-clients", function (d) {
            const cs = (d && d.clients) || [];
            for (let i = 0; i < cs.length; i++) {
                if (cs[i].title === "asteroidz settings") {
                    // Three things here are easy to get wrong and every one of
                    // them fails silently, because the reply is {"success":true}
                    // whenever the action NAME parsed -- it says nothing about
                    // whether the action did anything.
                    //
                    //   - `dispatch ` is part of the string Ipc.dispatch sends
                    //     verbatim; it is not added for you.
                    //   - the id is a `client,<id>` PREFIX, not focus_id's own
                    //     argument. `focus_id,<id>` leaves arg->tc NULL and
                    //     focusid() returns immediately.
                    //   - the prefix must be terminated by a COMMA. The parser
                    //     accepts the id only when the next character is ',' or
                    //     end-of-string, so `client,<id> focus_id` -- with a
                    //     space, as modules/Title.qml writes it -- never sets
                    //     the client at all.
                    Ipc.dispatch("dispatch client," + cs[i].id + ",focus_id");
                    return;
                }
            }
        });
    }

    function toggle() {
        if (window !== null && window.visible)
            window.visible = false;
        else
            open();
    }
}
