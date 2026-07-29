// The focused window's title, for THIS output.
//
// Per-monitor, not global: each screen shows what is focused on it, which is
// why this reads all-monitors rather than `watch focused-client` (that one is
// the session's single focused client, and would print the same title on every
// bar).
//
// With nothing focused the pill disappears rather than showing an empty slab,
// so the section collapses -- the native module releases its pills for the
// same reason.

import QtQuick
import ".."

Pill {
    id: root

    property string screenName: ""

    readonly property var client: {
        void Compositor.generation;
        return Compositor.activeClient(screenName);
    }

    visible: client && client.title
    text: (client && client.title) ? client.title : ""
    icons: (client && client.appid) ? [client.appid] : []

    // `title-width` is a CAP, not a pin. Pinned, every short title left a wide
    // empty pill and pushed the centre section off centre for no reason.
    maxWidth: Cfg.titleWidth

    onClicked: button => {
        if (button !== Qt.LeftButton || !client || !client.id)
            return;
        // `client,<id>` is a prefix the dispatcher strips out of the command
        // and turns into the target, not an argument to focus_id -- the
        // function itself takes none.
        Ipc.dispatch("dispatch client," + client.id + " focus_id");
    }
}
