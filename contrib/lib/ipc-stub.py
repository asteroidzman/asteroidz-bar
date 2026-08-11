#!/usr/bin/env python3
"""A stand-in for the compositor's IPC socket.

Speaks just enough of the protocol for the bar's subscriptions: newline-
delimited JSON, one command then either a stream (watch) or one reply and a
hangup (everything else) -- the same shape ipc.h implements. Every received
command is appended to a log with a timestamp, which is what the reconnect
test asserts on: a re-subscription after a server restart is a line in the
second server's log, and before the reconnect fix there was never one.

--fragment exercises the framing: initial states are written a few bytes at a
time with small sleeps, and one reply deliberately shares a buffer with a
second complete object -- partial reads and coalesced reads are both things a
SOCK_STREAM socket is allowed to do, so the client must not care.
"""

import json
import os
import socket
import sys
import threading
import time

PATH, LOG = sys.argv[1], sys.argv[2]
FRAGMENT = "--fragment" in sys.argv

try:
    os.unlink(PATH)
except FileNotFoundError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(PATH)
srv.listen(16)

log = open(LOG, "a", buffering=1)


def payloads(cmd):
    if "bar-config" in cmd:
        return [{"theme": {"fg": [1, 1, 1, 1], "focus_bg": [0.4, 0.6, 1, 1]}}]
    if "all-monitors" in cmd:
        return [{"monitors": [{
            "name": "HEADLESS-1", "active": True, "layout_symbol": "[]=",
            "tags": [{"index": i, "name": str(i), "is_active": i == 1,
                      "is_urgent": False, "client_count": 0}
                     for i in range(1, 10)],
        }]}]
    if "all-clients" in cmd:
        return [{"clients": []}]
    if cmd.startswith("watch idle"):
        return [{"manual": False}]
    return [{"success": True}]


def send(conn, objs):
    data = "".join(json.dumps(o) + "\n" for o in objs).encode()
    if not FRAGMENT:
        conn.sendall(data)
        return
    # A few bytes at a time, with pauses long enough that each lands in its
    # own read on the far side.
    for i in range(0, len(data), 7):
        conn.sendall(data[i:i + 7])
        time.sleep(0.005)


def serve(conn):
    f = conn.makefile("r")
    try:
        for line in f:
            cmd = line.strip()
            if not cmd:
                continue
            log.write("%.3f %s\n" % (time.time(), cmd))
            if cmd.startswith("watch "):
                objs = payloads(cmd)
                if FRAGMENT and "all-clients" in cmd:
                    # Two complete objects in one buffer: the initial state
                    # and an immediate update, coalesced the way a stream may.
                    conn.sendall(b"".join(
                        json.dumps(o).encode() + b"\n" for o in objs * 2))
                else:
                    send(conn, objs)
                # A watch holds the connection; keep reading until EOF.
            else:
                send(conn, payloads(cmd))
                break
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
