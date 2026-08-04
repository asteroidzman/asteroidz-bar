pragma Singleton

// The notification daemon. This shell IS org.freedesktop.Notifications now.
//
// swaync did this, and the bar watched it over `swaync-client --subscribe`:
// one long-lived process writing a JSON line whenever the count changed, plus
// a second process spawned for every toggle. That worked, and it meant a
// notification arrived at the bar third-hand -- the sender told the daemon, the
// daemon told its client, the client told a pill -- with the daemon owning the
// history, the do-not-disturb flag, and what a notification even looked like.
// Three of those are this shell's business.
//
// So the server lives here. Nothing else has to be installed or supervised,
// the popup is drawn by the same code that draws the bar, and the history is
// one list rather than a count read back over a socket.
//
// ── what a daemon owes its senders ─────────────────────────────────────────
//
// The capability flags below are a CONTRACT, not preferences. An application
// asks GetCapabilities and then formats for the answer: claiming `body-markup`
// and rendering the tags literally puts `<b>` in front of somebody, and NOT
// claiming it makes well-behaved senders strip formatting they could have had.
// Each one here is claimed because the popup genuinely honours it.
//
// `persistence` says the daemon keeps notifications after they leave the
// screen, which is what makes a notification centre meaningful rather than a
// list of things you already missed.

import Quickshell
import Quickshell.Services.Notifications
import QtQuick
import "."

Singleton {
    id: root

    // ── the server ──────────────────────────────────────────────────────────

    readonly property alias tracked: server.trackedNotifications

    NotificationServer {
        id: server

        // Kept across a shell reload. Quickshell can re-exec this config on a
        // file change, and without this every notification on screen would
        // vanish with it -- including ones nobody had read yet.
        keepOnReload: true

        // Claimed because they are honoured, see the note above.
        persistenceSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        actionsSupported: true
        actionIconsSupported: false
        inlineReplySupported: false

        onNotification: n => {
            // Tracking is what keeps it alive past this signal; an untracked
            // notification is destroyed the moment the handler returns, and the
            // popup would be drawing a dangling object.
            n.tracked = true;

            // And this is what keeps it from becoming one LATER.
            //
            // A notification can go away without anybody here asking: the
            // sender closes it, or the server expires it. The object is
            // destroyed when that happens, and `popups` is a plain JS array
            // holding a reference -- so the next time it was reassigned, the
            // Repeater regenerated its delegates over a dangling pointer and
            // the shell segfaulted inside QQmlIncubator. Not a rare race
            // either: any application that withdraws its own notification does
            // exactly this.
            n.closed.connect(function() { root.hidePopup(n); });

            root.arrived(n);
        }
    }

    signal arrived(var notification)

    // ── history ─────────────────────────────────────────────────────────────
    //
    // Newest first, which is the order a person reads a stack of them in.
    // Derived from the server's model rather than kept alongside it: a second
    // list would have to be told about every dismissal, including the ones an
    // application makes on its own by closing a notification it sent.
    readonly property var list: {
        void generation;
        const out = [];
        for (let i = 0; i < tracked.values.length; i++)
            out.unshift(tracked.values[i]);
        return out;
    }

    readonly property int count: list.length

    // Bumped to re-evaluate `list`, which reads through an ObjectModel whose
    // contents change without the property itself being reassigned.
    property int generation: 0

    Connections {
        target: server.trackedNotifications
        function onValuesChanged() { root.generation++; }
    }

    // ── do not disturb ──────────────────────────────────────────────────────
    //
    // Suppresses the POPUP, never the notification. A notification that is
    // dropped instead of quieted is one the person never finds out about, and
    // "do not disturb" is a statement about interruption rather than about
    // whether the thing happened -- so it still lands in the centre and the
    // bell still counts it.
    //
    // Persisted, because it outlives a shell restart in the user's mind: a
    // person who silenced their notifications before a meeting does not expect
    // a shell reload to start shouting again.
    readonly property bool dnd: BarConfig.flagOf("notify", "dnd", false)

    function toggleDnd() {
        BarConfig.setValue("notify", "dnd", !dnd);
    }

    // ── what is on screen right now ─────────────────────────────────────────
    //
    // A separate list from the history: a popup is a thing with a lifetime,
    // and the history is a thing with a length.
    property var popups: []

    function showPopup(n) {
        // Filtered on the way in as well as on the way out. `closed` covers
        // the notifications this shell is told about; this covers anything
        // that leaves the model by a route nobody signalled.
        const next = popups.filter(p => p);
        next.push(n);
        // Oldest first out. A stack that grows without bound covers the screen,
        // and the ones at the bottom are the ones already read.
        while (next.length > maxPopups)
            next.shift();
        popups = next;
    }

    function hidePopup(n) {
        popups = popups.filter(p => p && p !== n);
    }

    readonly property int maxPopups: BarConfig.numOf("notify", "max-popups", 4)

    // How long a popup stays when the sender does not say.
    //
    // The sender's own expireTimeout wins when it sets one: an application
    // that says 2 seconds means 2 seconds. 0 means "until dismissed" per the
    // spec, and that is honoured rather than overridden -- a password prompt
    // or a failed backup is exactly the kind of thing that sets it.
    readonly property int defaultTimeout:
        BarConfig.numOf("notify", "timeout", 5000)

    function timeoutFor(n) {
        if (!n)
            return defaultTimeout;
        if (n.expireTimeout === 0)
            return 0;                       // until dismissed, deliberately
        if (n.expireTimeout > 0)
            return n.expireTimeout;
        // Critical outlives the others when nobody specified. It is the one
        // urgency the spec reserves for something that has gone wrong.
        return n.urgency === NotificationUrgency.Critical
            ? 0 : defaultTimeout;
    }

    // ── why the popup is raised on the NEXT turn ────────────────────────────
    //
    // `arrived` is emitted from inside DBusNotificationServer::Notify -- the
    // D-Bus method call itself. Building the popup list there reassigns
    // `popups`, which is a Repeater's model, so the Repeater regenerated and
    // incubated a delegate over a Notification the server had not finished
    // setting up yet. That segfaults inside QQmlIncubator, and it took the
    // whole shell down: three crash reports, all with Notify at the bottom of
    // the stack and QQuickRepeater::setModel at the top.
    //
    // Queued and drained once, rather than a callLater per notification: a
    // burst arriving in one turn should cost one model rebuild, not one each,
    // and Qt.callLater collapses repeated calls to the same function.
    property var pending: []

    onArrived: n => {
        if (dnd)
            return;
        const q = pending.slice();
        q.push(n);
        pending = q;
        Qt.callLater(drainPending);
    }

    function drainPending() {
        const q = pending;
        pending = [];
        for (const n of q)
            if (n)
                showPopup(n);
    }

    // ── acting on them ──────────────────────────────────────────────────────

    // Dismissing removes it from the centre AND tells the sender, which is the
    // difference between dismiss() and merely dropping the reference: an
    // application that is waiting to know its notification was closed gets its
    // NotificationClosed signal.
    function dismiss(n) {
        if (!n)
            return;
        hidePopup(n);
        n.dismiss();
    }

    // Off the screen, still in the centre. What a popup timing out means.
    function expire(n) {
        if (!n)
            return;
        hidePopup(n);
    }

    function clearAll() {
        popups = [];
        // Over a COPY: dismiss() mutates the model this is walking, and
        // iterating it directly skips every second entry.
        const all = list.slice();
        for (const n of all)
            if (n)
                n.dismiss();
    }

    function invoke(action) {
        if (action)
            action.invoke();
    }
}
