#!/usr/bin/env python3
"""Minimal HTTP zero-streamer: serves an endless body of zeros on :9999.

Used as the RX flood source for the atl1c link-down wait test: the host
under test pulls from this server with `curl -s http://<server>:9999/ -o
/dev/null`, which loads the physical RX path of the NIC under test (traffic
between VMs on the same bridge would bypass it).

TCP is used on purpose: flow control keeps the sender stable, unlike a UDP
flood, which on macOS dies with ENOBUFS after ~50 s at ~74 kpps. A TCP pull
also dies when the link flaps (the script on the host detects that through
its bridge-counter check); restart the pull after each flap if needed.

Runs for 60 minutes, one connection at a time.
"""
import socket
import time

HDR = (b"HTTP/1.1 200 OK\r\n"
       b"Content-Type: application/octet-stream\r\n"
       b"Content-Length: 999999999999\r\n"
       b"Connection: close\r\n\r\n")
BLK = b"\0" * 131072

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 9999))
srv.listen(2)
end = time.time() + 3600
conns = 0
while time.time() < end:
    c, addr = srv.accept()
    conns += 1
    t0 = time.time()
    sent = 0
    try:
        c.settimeout(5)
        try:
            c.recv(65536)  # HTTP request headers
        except socket.timeout:
            pass
        c.settimeout(None)
        c.sendall(HDR)
        while True:
            c.sendall(BLK)
            sent += len(BLK)
    except OSError:
        pass
    finally:
        c.close()
    dt = time.time() - t0
    print(f"conn {conns} from {addr[0]}: {sent/1e6:.0f} MB in {dt:.1f}s "
          f"({sent/dt/1e6 if dt else 0:.1f} MB/s)", flush=True)
print("SERVER-DONE")
