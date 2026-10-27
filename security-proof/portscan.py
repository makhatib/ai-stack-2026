#!/usr/bin/env python3
"""TCP connect scan of ports 1-65535 with epoll.  Stdlib only.

Prints the open ports, space separated, on stdout.  Exit 0 = the scan ran to the
end and every probe gave an answer; exit 3 = some probes could not run (the
caller must treat that as NOT MEASURED).

WHY NOT asyncio.  The first version of this scan used asyncio.wait_for per probe.
At 1500-4000 probes in flight the event loop lagged, the per-probe timer fired
before the loop looked at a connection that HAD completed, and the scan reported
ports 22 and 80 as closed (measured on the dev sandbox, 2026-10-27: 4000 in flight
-> no open port found; 500 -> all three).  A scan that is blind in the quiet
direction is the worst failure this script can have.  Here a connection that is
ready is always handled BEFORE any timeout is looked at, so lag cannot turn an
open port into a closed one.
"""
import errno
import resource
import select
import socket
import sys
import time

host = sys.argv[1]
timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 1.5
inflight_max = int(sys.argv[3]) if len(sys.argv) > 3 else 3000

soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
want = 4096 if hard == resource.RLIM_INFINITY else min(4096, hard)
if soft < want:
    resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
    soft = want
inflight_max = max(20, min(inflight_max, soft - 100))

try:
    addr = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
except OSError as e:
    sys.stderr.write("cannot resolve %s: %s\n" % (host, e))
    sys.exit(3)

ep = select.epoll()
pending = {}                      # fd -> (socket, port, started)
open_ports, unrunnable = [], 0
next_port = 1
CLOSED = (errno.ECONNREFUSED, errno.ECONNRESET)
TIMEOUTLIKE = (errno.ETIMEDOUT,)

def start(port):
    global unrunnable
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)
    try:
        rc = s.connect_ex((addr, port))
    except OSError:
        s.close(); unrunnable += 1; return
    if rc == 0:
        open_ports.append(port); s.close(); return
    if rc != errno.EINPROGRESS:
        s.close()
        if rc not in CLOSED:
            unrunnable += 1       # EMFILE, ENETUNREACH ...: this probe did not run
        return
    pending[s.fileno()] = (s, port, time.monotonic())
    ep.register(s.fileno(), select.EPOLLOUT)

while next_port <= 65535 or pending:
    while next_port <= 65535 and len(pending) < inflight_max:
        start(next_port); next_port += 1
    if not pending:
        continue
    # 1) everything that is READY is handled first ...
    for fd, _ in ep.poll(0.05):
        s, port, _t = pending.pop(fd)
        ep.unregister(fd)
        err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if err == 0:
            open_ports.append(port)
        elif err not in CLOSED and err not in TIMEOUTLIKE:
            unrunnable += 1
        s.close()
    # 2) ... and only then are the stragglers timed out.
    now = time.monotonic()
    for fd in [f for f, (_s, _p, t0) in pending.items() if now - t0 > timeout]:
        s, port, _t = pending.pop(fd)
        ep.unregister(fd); s.close()          # no answer: filtered / dropped

if unrunnable:
    sys.stderr.write("%d probes could not run\n" % unrunnable)
    sys.exit(3)
print(" ".join(map(str, sorted(open_ports))))
