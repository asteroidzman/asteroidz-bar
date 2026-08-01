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

    // `shown`, not `visible`: the loader that holds this module hides the
    // module's slot when it has nothing to show, and Item.visible reports
    // EFFECTIVE visibility -- so a module reading its own `visible` back would
    // latch itself off the moment its slot was hidden. See ModuleLoader.
    shown: client && client.title
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
        //
        // It must end in a COMMA. The parser accepts the id only when the next
        // character is ',' or end-of-string, so the space this used to have meant
        // the prefix was never recognised at all: client_id stayed unset,
        // arg->tc stayed NULL, focusid() returned immediately, and clicking the
        // title did nothing. The reply was still {"success":true}, because
        // success only ever meant the action NAME parsed.
        Ipc.dispatch("dispatch client," + client.id + ",focus_id");
    }
}
