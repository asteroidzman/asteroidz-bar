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
// IpcHandler, for the keybind at the bottom of this file. Its absence does not
// fail locally: the whole shell refuses to load, blaming the first singleton in
// the chain rather than this one.
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick
// Paths.resolve, for the sound theme lookup: "which of these files exists" is
// the one thing QML cannot answer on its own.
import Asteroidz.Bar
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
        // Short-circuited during a bulk clear, and this is the whole fix: the
        // binding reads `tracked.values`, so it re-evaluates on every dismissal
        // whatever the generation counter says -- holding that counter still
        // was tried first and changed nothing.
        //
        // The end state is empty, so answering "empty" for the duration is not
        // a lie, and it costs O(1) instead of rebuilding an n-element array and
        // handing the centre's Repeater a fresh model n times.
        if (clearing)
            return [];
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
        function onValuesChanged() {
            // Held while a bulk clear is running -- see clearAll.
            if (!root.clearing)
                root.generation++;
        }
    }

    // Set while a whole list is being dismissed at once, so that everything
    // reading `list` rebuilds after the last one rather than between each.
    property bool clearing: false

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
    readonly property bool dnd: Cfg.notifyDnd

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

    readonly property int maxPopups: Cfg.notifyMaxPopups

    // How long a popup stays when the sender does not say.
    //
    // The sender's own expireTimeout wins when it sets one: an application
    // that says 2 seconds means 2 seconds. 0 means "until dismissed" per the
    // spec, and that is honoured rather than overridden -- a password prompt
    // or a failed backup is exactly the kind of thing that sets it.
    readonly property int defaultTimeout:
        Cfg.notifyTimeout

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

    // ── audible notifications ───────────────────────────────────────────────
    //
    // Off unless asked for, and silent while quiet -- which is the point. A
    // notification that is quieted but still makes a noise is not quieted, and
    // that is exactly how this desktop found out the sound was coming from
    // somewhere else entirely.
    //
    // Played with `pw-play`, which ships in pipewire-audio: anything with
    // working desktop audio already has it, so this adds no dependency. It is
    // one short-lived process per notification, which is the right trade for
    // an event that happens a few times an hour -- and it is fire-and-forget,
    // so a missing player or a busy sink cannot block the D-Bus call this is
    // reached from.
    //
    // The spec's own hints are honoured, in its own order of specificity:
    //
    //   suppress-sound  the sender says stay silent. It is asking for a reason
    //                   -- it has usually just made its own noise.
    //   sound-file      an exact file, played as given.
    //   sound-name      a themed name, looked up like any other.
    //
    // and only failing all three does the configured default get used.
    function announce(n) {
        if (!Cfg.notifySound)
            return;
        const hints = (n && n.hints) || ({});
        const suppress = hints["suppress-sound"];
        if (suppress === true || suppress === 1 || suppress === "true")
            return;

        const file = hints["sound-file"];
        if (file) {
            play(String(file));
            return;
        }
        const named = soundPath(String(hints["sound-name"] || Cfg.notifySoundName));
        if (named !== "")
            play(named);
    }

    function play(file) {
        // Detached rather than a Process object: two notifications close
        // together would otherwise fight over one `running`, and the second
        // would either be dropped or cut the first off mid-sound.
        Quickshell.execDetached(["pw-play", file]);
    }

    // The XDG sound theme lookup, which is the whole reason a NAME is better
    // than a path: `message-new-instant` is whatever the installed theme says
    // it is, and falls back to freedesktop's, which every sound theme package
    // depends on.
    function soundPath(name) {
        if (name === "")
            return "";
        const home = Quickshell.env("HOME") || "";
        const dataHome = Quickshell.env("XDG_DATA_HOME")
            || (home === "" ? "" : home + "/.local/share");
        const roots = [];
        if (dataHome !== "")
            roots.push(dataHome);
        for (const dir of String(Quickshell.env("XDG_DATA_DIRS")
                                 || "/usr/local/share:/usr/share").split(":"))
            if (dir !== "")
                roots.push(dir);

        const themes = [Cfg.notifySoundTheme, "freedesktop"];
        const candidates = [];
        for (const root of roots)
            for (const theme of themes)
                for (const ext of [".oga", ".ogg", ".wav"])
                    candidates.push(root + "/sounds/" + theme + "/stereo/"
                                    + name + ext);
        // Paths.resolve answers with a URL -- QUrl::fromLocalFile().toString()
        // -- because its other caller hands the result to an Image, which
        // wants one. A player wants a filesystem path, and `pw-play
        // file:///usr/share/...` simply fails to open it.
        //
        // This is what made the first version of the feature silent while
        // every test passed: the stub player logged whatever it was given, and
        // "does it contain /sounds/message-new-instant" is true of the URL too.
        const found = Paths.resolve(candidates);
        if (!found.startsWith("file://"))
            return found;
        return decodeURIComponent(found.substring("file://".length));
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
        // Quiet silences the sound as well as the popup, and it is the same
        // early return that does both: "do not disturb" that still makes a
        // noise is not do-not-disturb.
        if (dnd)
            return;
        announce(n);
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

    // Dismissing the lot, in ONE rebuild rather than one per notification.
    //
    // Each dismiss() removes an entry from the server's model, which fires
    // valuesChanged, which bumped `generation`, which rebuilt `list` -- and the
    // centre's Repeater takes `list` as its model, so a fresh array made it
    // destroy and recreate every card it was showing. Once per dismissal. That
    // is quadratic in cards, and a card is not cheap: an icon, styled text and
    // a RectangularGlow each.
    //
    // Measured on this desktop with the centre open: 40 notifications cost
    // 290ms, 200 cost 7790ms. Five times the count, twenty-seven times the
    // work -- which is the shape of n², and why a few hundred took the fifteen
    // seconds that started this.
    //
    // `clearing` holds the generation counter still for the duration, so the
    // list is rebuilt once, at the end, when it is empty.
    function clearAll() {
        popups = [];
        // Over a COPY: dismiss() mutates the model this is walking, and
        // iterating it directly skips every second entry.
        const all = list.slice();
        clearing = true;
        try {
            for (const n of all)
                if (n)
                    n.dismiss();
        } finally {
            // In a finally, so a throw part-way through cannot leave the
            // counter pinned -- the whole shell would then stop noticing any
            // notification arriving or leaving, which is a far worse failure
            // than a slow clear.
            clearing = false;
        }
        generation++;
    }

    function invoke(action) {
        if (action)
            action.invoke();
    }

    // ── reachable from a keybind ────────────────────────────────────────────
    //
    // swaync had a client for this: `swaync-client -t -sw` toggled the panel,
    // `-d` set do-not-disturb, and every keypress was a whole process spawned
    // to speak to a daemon over D-Bus. The daemon is this shell, so the bind
    // calls straight in:
    //
    //     Super+n { spawn "qs -p /usr/share/asteroidz-bar/shell.qml ipc call notify toggle"; }
    //
    // Replacing swaync without replacing this would have left every existing
    // Super+n binding silently doing nothing.
    signal toggleRequested(string monitor)

    // Which bar should answer. A key press does not know which screen you are
    // looking at and the compositor cannot pass it -- the bind spawns a command
    // line, and that process has no notion of focus by the time it runs. The
    // shell has it already, so the resolution happens here, the same way
    // `wallpaper nextFocused` does it.
    //
    // Resolved once, here, rather than in each pill: with every bar comparing
    // against `Compositor.focusedMonitor` itself, a moment when focus is
    // unknown opens the centre on every monitor at once.
    function focusedBarMonitor() {
        if (Compositor.focusedMonitor !== "")
            return Compositor.focusedMonitor;
        // Before the first focus event -- at startup, or on a compositor that
        // never sent one. Somewhere is better than nowhere.
        const screens = Quickshell.screens;
        return screens && screens.length > 0 ? screens[0].name : "";
    }

    IpcHandler {
        target: "notify"

        // Opens the centre, or closes it if this bar's popover is already up:
        // `Bar.showPanel` is itself a toggle, so pressing the bind twice is
        // open-then-close rather than open-then-open.
        function toggle(): string {
            const mon = root.focusedBarMonitor();
            if (mon === "")
                return "no screens";
            root.toggleRequested(mon);
            return mon;
        }

        // `quiet`, not `dnd`, so it does not shadow the property of that name.
        function quiet(): string {
            root.toggleDnd();
            return root.dnd ? "quiet" : "audible";
        }

        function clear(): string {
            const n = root.count;
            root.clearAll();
            return String(n);
        }

        function state(): string {
            return String(root.count) + (root.dnd ? " quiet" : "");
        }
    }
}
