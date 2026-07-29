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

    // Set at startup by shell.qml from ASTEROIDZ_INSTANCE_SIGNATURE. Empty
    // means "no compositor found", which is a legitimate state: the bar can be
    // started from a terminal under another compositor while being worked on,
    // and should draw with defaults rather than refuse.
    property string socketPath: ""

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
