#!/usr/bin/env python3
"""A SOCKS5 proxy for the native demo's "HTTP via SOCKS" probe, standard library only.

    python3 -I examples/native-demo/socks_probe.py [port]      (default 1080, on 127.0.0.1)

The simulator shares the Mac's loopback, so the probe's `socks` {127.0.0.1, 1080} reaches it. Every
CONNECT is logged with its address type: ATYP 3 (a domain name) shows that the hostname went to the proxy
unresolved. The proxy does not connect anywhere: it answers the HTTP request itself, with a body naming
the host it was asked for, so the probe needs no network and its hostname (`socksprobe`) need not exist.
"""
import socket
import struct
import sys
import threading


def recv_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def serve(conn, peer):
    try:
        version, nmethods = recv_exact(conn, 2)
        recv_exact(conn, nmethods)
        if version != 5:
            return
        conn.sendall(b"\x05\x00")  # no authentication
        _, cmd, _, atyp = recv_exact(conn, 4)
        if atyp == 1:
            host = socket.inet_ntoa(recv_exact(conn, 4))
        elif atyp == 3:
            host = recv_exact(conn, recv_exact(conn, 1)[0]).decode("ascii", "replace")
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
        else:
            return
        (port,) = struct.unpack("!H", recv_exact(conn, 2))
        print(f"socks: {peer[0]}:{peer[1]} CONNECT cmd={cmd} ATYP={atyp} host={host} port={port}", flush=True)
        conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", port))
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = conn.recv(4096)
            if not chunk:
                return
            request += chunk
        line = request.split(b"\r\n", 1)[0].decode("ascii", "replace")
        print(f"socks: request line {line}", flush=True)
        body = f"hello via socks to {host}:{port} (ATYP {atyp})\n".encode()
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n"
                     + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    except (ConnectionError, OSError) as e:
        print(f"socks: {peer}: {e}", flush=True)
    finally:
        conn.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 1080
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(16)
    print(f"socks: listening on 127.0.0.1:{port}", flush=True)
    while True:
        conn, peer = server.accept()
        threading.Thread(target=serve, args=(conn, peer), daemon=True).start()


if __name__ == "__main__":
    main()
