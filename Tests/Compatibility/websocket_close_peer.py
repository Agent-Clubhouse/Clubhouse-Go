#!/usr/bin/env python3
"""Private loopback close-code peer for the frozen Go 147 / simulator audits."""
import argparse
import base64
import hashlib
import pathlib
import select
import socket
import struct
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--code", type=int, choices=(1000, 1013), required=True)
parser.add_argument("--out", type=pathlib.Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
prefix = args.out / f"close{args.code}"
stop = prefix.with_name(prefix.name + "-stop")
stop.unlink(missing_ok=True)
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
    prefix.with_name(prefix.name + "-port").write_text(str(server.getsockname()[1]))
    while not stop.exists():
        if not select.select([server], [], [], 0.2)[0]:
            continue
        conn, _ = server.accept()
        with conn:
            try:
                conn.settimeout(2)
                request = b""
                while b"\r\n\r\n" not in request and len(request) <= 8192:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    request += chunk
                if b"\r\n\r\n" not in request:
                    continue
                headers = dict(line.split(":", 1) for line in request.decode().split("\r\n")[1:] if ":" in line)
                key = next(v.strip() for k, v in headers.items() if k.lower() == "sec-websocket-key")
                accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
                conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                time.sleep(0.05)
                frame = b"\x88\x02" + struct.pack("!H", args.code)
                conn.sendall(frame)
                with prefix.with_name(prefix.name + "-wire.log").open("a") as log:
                    log.write(f"sent-close={args.code} frame={frame.hex()}\n")
                try:
                    conn.recv(4096)
                    time.sleep(0.1)
                except OSError:
                    pass
            except (OSError, ValueError, StopIteration, UnicodeError):
                pass
