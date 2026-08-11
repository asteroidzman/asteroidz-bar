pragma Singleton

// The compositor connection: one socket, newline-delimited JSON both ways.
//
// asteroidz already speaks this -- `amsg` is a forty-line client of it -- so
// the bar needs no new protocol and no compositor plumbing to read state. What
// it does need is to stop SHELLING OUT for it: `amsg watch all-tags` in a
// Process works, but it is a fork per subscription and a pipe per fork for
// data the compositor is already willing to push down one socket.
//
// One socket per subscription rather than one multiplexed connection, because
// the protocol is one-command-then-stream: `watch` converts the connection
// into an event channel, and there is no framing that would let two watches
// share it. Sockets are cheap; guessing at a framing the server does not
// implement is not.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    // Read HERE, not handed in by shell.qml.
    //
    // A singleton is created when something first uses it, and the things that
    // use this one are created while ShellRoot is building its children --
    // before ShellRoot's own Component.onCompleted runs. Setting the path from
    // there meant every subscription was opened against an empty path, found
    // itself disconnected, and gave up permanently: a bar that connected to
    // nothing and drew its defaults, silently and forever.
    //
    // Empty is still a legitimate state -- the shell can be run under another
    // compositor while being worked on, and should draw defaults rather than
    // refuse -- but it now means "genuinely not set", not "asked too early".
    readonly property string socketPath:
        Quickshell.env("ASTEROIDZ_INSTANCE_SIGNATURE") || ""

    readonly property bool connected: socketPath !== ""

    // Open a `watch` subscription. `onJson` is called with the parsed object
    // for every update, starting with the initial state the compositor pushes
    // on subscribe -- so a caller never has to `get` first and then `watch`,
    // which would race with the very first change. That initial push is also
    // what makes RECONNECTING sound: a re-subscribe replays the full current
    // state, so nothing accumulated during an outage is missed.
    function watch(command, onJson) {
        if (!connected)
            return null;
        return watchComponent.createObject(root, {
            command: command,
            handler: onJson
        });
    }

    // A subscription is a CONTROLLER holding a socket, not a socket.
    //
    // Reconnecting cannot be done by flipping `connected` on one Socket.
    // quickshell redials by itself only when an ESTABLISHED connection closes
    // (socket.cpp: onSocketDisconnected), and that one immediate attempt races
    // a compositor that is still restarting. When the attempt fails,
    // QLocalSocket parks in UnconnectedState with no disconnected() signal, so
    // quickshell's internal socket pointer never clears -- and setConnected
    // only dials when that pointer is null. A Socket whose connect attempt has
    // failed is therefore inert for the life of the object, and before this
    // controller existed, one compositor restart left every subscription --
    // the theme, the tags, the focus, the idle state -- frozen at its last
    // value until the shell was restarted by hand.
    //
    // So each retry builds a FRESH Socket. The dead one is destroyed first,
    // which is also what makes reconnection deterministic: there is never more
    // than one socket per subscription, a destroyed socket's parser cannot
    // deliver anything, and the compositor re-pushes the full current state on
    // re-subscribe, so state converges regardless of what was missed during
    // the outage. No generation counter is needed -- object lifetime is the
    // epoch.
    Component {
        id: watchComponent

        QtObject {
            id: ctl
            required property string command
            required property var handler

            // Failed attempts in a row, for the backoff. Reset on success so
            // the next outage starts from the short interval again.
            property int failures: 0
            property var sock: null

            property Timer retry: Timer {
                // Capped exponential backoff: a compositor restart is over in
                // seconds, and a permanently absent one should cost a wakeup
                // every few seconds, not a storm.
                interval: Math.min(5000,
                                   250 * Math.pow(2, Math.min(ctl.failures, 5)))
                onTriggered: {
                    if (ctl.sock && ctl.sock.connected)
                        return;
                    ctl.dial();
                }
            }

            function scheduleRetry() {
                failures++;
                retry.restart();
            }

            function dial() {
                if (sock) {
                    sock.destroy();
                    sock = null;
                }
                sock = watchSocketComponent.createObject(ctl, { ctl: ctl });
            }

            Component.onCompleted: dial()
            Component.onDestruction: {
                if (sock) {
                    sock.destroy();
                    sock = null;
                }
            }
        }
    }

    Component {
        id: watchSocketComponent

        Socket {
            required property var ctl

            path: root.socketPath
            connected: true

            onConnectionStateChanged: {
                if (connected) {
                    ctl.failures = 0;
                    ctl.retry.stop();
                    write(ctl.command + "\n");
                } else {
                    // The connection dropped. quickshell dials once, right
                    // now; if that lands, the branch above runs again and
                    // stops the timer. If it does not, onError fires and the
                    // timer is already pending from here.
                    ctl.scheduleRetry();
                }
            }

            // A connect ATTEMPT that fails lands here and ONLY here:
            // QLocalSocket emits disconnected() only for a connection that
            // existed. Without this, one failed retry used to be the end of
            // the subscription for the life of the process.
            onError: ctl.scheduleRetry()

            parser: SplitParser {
                onRead: line => {
                    if (line.length === 0)
                        return;
                    try {
                        ctl.handler(JSON.parse(line));
                    } catch (e) {
                        // A malformed line is the compositor's problem, not a
                        // reason to tear down a subscription that will very
                        // likely deliver a good line next time.
                        console.warn("asteroidz-bar: bad IPC line:", line);
                    }
                }
            }
        }
    }

    // One command, one reply, then hang up.
    //
    // Neither of the two above fits a `get`. `dispatch` throws the answer away,
    // which is right for a click handler and useless when the answer IS the
    // point; `watch` keeps the connection open forever, which is right for a
    // subscription and an fd leaked per query otherwise.
    //
    // The compositor already behaves exactly this way at the other end: a
    // non-watch command queues its reply, sets `closing`, and closes the fd
    // once the queue drains (ipc.h). So one line then EOF is the contract, not
    // an assumption -- and hanging up here on the first line is agreeing with
    // it rather than guessing.
    //
    // `onJson` receives the parsed reply. It is not called at all if the
    // compositor is not there, which is the same "draw defaults, do not
    // refuse" stance the rest of this singleton takes.
    function request(command, onJson) {
        if (!connected)
            return;
        requestComponent.createObject(root, {
            command: command,
            handler: onJson
        });
    }

    Component {
        id: requestComponent

        Socket {
            id: req
            required property string command
            required property var handler

            path: root.socketPath
            connected: true

            // One shot means one lifetime: a request whose connection FAILS
            // (compositor down), or closes without ever delivering a line,
            // must not sit in memory forever -- and before this guard, it did:
            // the only destroy() was in the reply path, so every dispatch and
            // request made while the compositor was away leaked a Socket.
            //
            // Guarded, because teardown is reachable twice in one turn: the
            // reply path sets connected = false, which re-enters through
            // onConnectionStateChanged. destroy() is deferred, so the handler
            // running after finish() is safe; calling destroy() twice is not.
            property bool finished: false
            function finish() {
                if (finished)
                    return;
                finished = true;
                req.destroy();
            }

            onError: finish()

            onConnectionStateChanged: {
                if (connected)
                    write(command + "\n");
                else
                    finish();
            }

            parser: SplitParser {
                onRead: line => {
                    // Hang up FIRST, and unconditionally.
                    //
                    // The handler is application code that can throw -- a
                    // missing field, a rename -- and a throw between parsing
                    // and closing would leak the socket. Ordering it this way
                    // means the fd is already released no matter what happens
                    // next.
                    req.connected = false;
                    let obj = null;
                    try {
                        obj = JSON.parse(line);
                    } catch (e) {
                        console.warn("asteroidz-bar: bad reply to",
                                     req.command + ":", line);
                    }
                    if (obj !== null && req.handler)
                        req.handler(obj);
                    req.finish();
                }
            }
        }
    }

    // Fire-and-forget dispatch, for click handlers. No reply is read: every
    // dispatch answers {"success":true} or an error, and there is nothing
    // useful for a bar to do with either.
    function dispatch(command) {
        if (!connected)
            return;
        dispatchComponent.createObject(root, { command: command });
    }

    Component {
        id: dispatchComponent

        Socket {
            id: sock
            required property string command

            path: root.socketPath
            connected: true

            // Same lifetime guard as a request's, and for the same leak.
            property bool finished: false
            function finish() {
                if (finished)
                    return;
                finished = true;
                sock.destroy();
            }

            onError: finish()

            onConnectionStateChanged: {
                if (connected) {
                    write(command + "\n");
                    // Closing immediately would race the write. The reply is
                    // the signal that the command was seen, so use it as the
                    // cue to hang up.
                } else {
                    finish();
                }
            }

            parser: SplitParser {
                onRead: _ => {
                    sock.connected = false;
                    sock.finish();
                }
            }
        }
    }
}
