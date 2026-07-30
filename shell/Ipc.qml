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
    // which would race with the very first change.
    function watch(command, onJson) {
        if (!connected)
            return null;
        return watchComponent.createObject(root, {
            command: command,
            handler: onJson
        });
    }

    Component {
        id: watchComponent

        Socket {
            required property string command
            required property var handler

            path: root.socketPath
            connected: true

            onConnectionStateChanged: {
                if (connected)
                    write(command + "\n");
            }

            parser: SplitParser {
                onRead: line => {
                    if (line.length === 0)
                        return;
                    try {
                        handler(JSON.parse(line));
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

            onConnectionStateChanged: {
                if (connected)
                    write(command + "\n");
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
                    req.destroy();
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

            onConnectionStateChanged: {
                if (connected) {
                    write(command + "\n");
                    // Closing immediately would race the write. The reply is
                    // the signal that the command was seen, so use it as the
                    // cue to hang up.
                }
            }

            parser: SplitParser {
                onRead: _ => {
                    sock.connected = false;
                    sock.destroy();
                }
            }
        }
    }
}
