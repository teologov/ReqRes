#!/usr/bin/env python3
#
#  fixture.py — the local servers the protocol matrix probes through ReqRes.
#  Stdlib only, so it runs on the stock /usr/bin/python3 (3.9) with nothing
#  installed.
#
#  One process, up to four listeners, the same endpoints on each:
#    HTTPS  127.0.0.1:<https-port>  and  [::1]:<https-port>   (needs --cert/--key)
#    HTTP   127.0.0.1:<http-port>                              (plain, default 3000)
#    HTTP   127.0.0.1:80   only with --http80, skipped if the bind is refused
#
#  Endpoints (every one accepts ?probe=<tag>, echoed back, so a row can be
#  found again in ReqRes's traffic list):
#    /health                 "ok"
#    /sse?secs=N&every=S     text/event-stream, one event every S s for N s, then `event: done`
#    /drip?secs=N&bytes=M    M bytes spread evenly over N s, with a Content-Length
#    /slow?ttfb=N            nothing for N s, then a short body
#    /upload                 (POST/PUT) sink: {"bytes": n, "sha256": ...}; answers 100-continue
#    /empty?status=204|400   204 with no body, or 400 with Content-Length: 0
#    /echo-headers           the request's headers as ordered [name, value] pairs, repeats kept
#    /cookies                two Set-Cookie headers
#    /gzip                   a gzip-encoded JSON body
#    /uuid                   {"uuid": ...} — a fresh 20-digit value per request
#    /binary                 256 bytes that are not UTF-8, sha256 in X-Fixture-SHA256
#    /rule-probe             "fixture-original" — what a DISABLED override must let through
#    /ws                     WebSocket echo; a text frame "stream N" makes the server send
#                            N frames one second apart while the client stays silent
#
#  Every request is appended to --log as one JSON line: time, listener, the
#  client's port (= the upstream connection ReqRes opened, so two lines with
#  the same port arrived on one reused connection), method, path, headers.
#
#  Usage:
#    fixture.py serve --log FILE [--cert C --key K] [--https-port 8443] [--http-port 3000] [--http80]
#    fixture.py selftest        # direct, no proxy: starts everything and checks every endpoint
#
#  It never touches the keychain, the proxy settings or anything outside the
#  files it is told to write.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
import argparse
import base64
import gzip
import hashlib
import http.server
import json
import os
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time
import uuid
from urllib.parse import parse_qs, urlparse

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts in the repo
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BINARY_BODY = bytes(range(256))  # 0x80..0xFF alone are invalid UTF-8
LOG_LOCK = threading.Lock()


# ------------------------------------------------------------ websocket frames
# Shared with the matrix's client.

def _encode_frame(payload: bytes, opcode: int = 0x1, mask: bool = False) -> bytes:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    mask_bit = 0x80 if mask else 0x00
    if length < 126:
        header.append(mask_bit | length)
    elif length < (1 << 16):
        header.append(mask_bit | 126)
        header += struct.pack("!H", length)
    else:
        header.append(mask_bit | 127)
        header += struct.pack("!Q", length)
    if not mask:
        return bytes(header) + payload
    key = os.urandom(4)
    return bytes(header) + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))


def _recv_exactly(sock, count: int) -> bytes:
    buffer = b""
    while len(buffer) < count:
        chunk = sock.recv(count - len(buffer))
        if not chunk:
            raise ConnectionError("peer closed mid-frame")
        buffer += chunk
    return buffer


def _decode_frame(sock):
    first, second = _recv_exactly(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exactly(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exactly(sock, 8))[0]
    key = _recv_exactly(sock, 4) if second & 0x80 else None
    payload = _recv_exactly(sock, length) if length else b""
    if key:
        payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
    return opcode, payload


encode_frame = _encode_frame
decode_frame = _decode_frame


def websocket_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


class _BufferedRecv:
    """`recv(n)` over a buffered reader, for a frame decoder written for sockets."""

    def __init__(self, reader):
        self.reader = reader

    def recv(self, count):
        return self.reader.read1(count)


# ------------------------------------------------------------------ handler

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive, and 100-continue is answered
    server_version = "ReqResProtocolFixture/1"
    sys_version = ""

    def log_message(self, fmt, *args):  # the JSON log below replaces stderr noise
        pass

    # --- plumbing

    def _query(self):
        parsed = urlparse(self.path)
        return parsed.path, {k: v[-1] for k, v in parse_qs(parsed.query).items()}

    def _log(self, extra=None):
        path = getattr(self.server, "log_path", None)
        if not path:
            return
        entry = {
            "t": round(time.time(), 3),
            "listener": self.server.label,
            "client_port": self.client_address[1],
            "method": self.command,
            "path": self.path,
            "headers": [[k, v] for k, v in self.headers.items()],
        }
        if extra:
            entry.update(extra)
        with LOG_LOCK, open(path, "a") as handle:
            handle.write(json.dumps(entry) + "\n")

    def _send(self, status, body=b"", headers=(), content_type="text/plain; charset=utf-8"):
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        for name, value in headers:
            self.send_header(name, value)
        if status not in (204, 304) and not (100 <= status < 200):
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, obj, headers=()):
        self._send(status, json.dumps(obj).encode(), headers, "application/json")

    def _read_body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _chunk(self, data: bytes):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    # --- verbs

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def _dispatch(self):
        path, query = self._query()
        probe = query.get("probe", "")
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self._log()
            return self._websocket()
        body = self._read_body() if self.command in ("POST", "PUT") else b""
        self._log({"body_bytes": len(body)} if body else None)
        route = {
            "/health": self._health, "/sse": self._sse, "/drip": self._drip, "/slow": self._slow,
            "/upload": self._upload, "/empty": self._empty, "/echo-headers": self._echo_headers,
            "/cookies": self._cookies, "/gzip": self._gzip, "/uuid": self._uuid,
            "/binary": self._binary, "/rule-probe": self._rule_probe,
        }.get(path)
        if route is None:
            return self._send(404, b"no such fixture endpoint\n")
        route(query=query, probe=probe, body=body)

    # --- endpoints

    def _health(self, **_):
        self._send(200, b"ok")

    def _sse(self, query, probe, **_):
        secs, every = float(query.get("secs", 5)), max(0.05, float(query.get("every", 1)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        count, start = 0, time.time()
        try:
            while time.time() - start < secs:
                self._chunk(f"id: {count}\ndata: {{\"n\": {count}, \"probe\": \"{probe}\"}}\n\n".encode())
                count += 1
                time.sleep(every)
            self._chunk(f"event: done\ndata: {count}\n\n".encode())
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except OSError:
            self.close_connection = True

    def _drip(self, query, **_):
        secs, total = float(query.get("secs", 5)), max(1, int(query.get("bytes", 60)))
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.end_headers()
        pause = secs / total
        try:
            for _ in range(total):
                self.wfile.write(b"*")
                self.wfile.flush()
                time.sleep(pause)
        except OSError:
            self.close_connection = True

    def _slow(self, query, probe, **_):
        time.sleep(float(query.get("ttfb", 5)))
        self._send(200, f"slow-ok {probe}".encode())

    def _upload(self, body, **_):
        self._json(200, {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})

    def _empty(self, query, **_):
        status = int(query.get("status", 204))
        self._send(status, b"", content_type=None if status == 204 else "text/plain")

    def _echo_headers(self, probe, **_):
        self._json(200, {
            "method": self.command,
            "probe": probe,
            "client_port": self.client_address[1],
            "headers": [[k, v] for k, v in self.headers.items()],
        })

    def _cookies(self, **_):
        self._send(200, b"two cookies", headers=[
            ("Set-Cookie", "fixture_a=1; Path=/; HttpOnly"),
            ("Set-Cookie", "fixture_b=2; Path=/; Secure"),
        ])

    def _gzip(self, probe, **_):
        body = gzip.compress(json.dumps({"gzipped": True, "probe": probe}).encode())
        self._send(200, body, headers=[("Content-Encoding", "gzip")], content_type="application/json")

    def _uuid(self, probe, **_):
        # Digits only, on purpose. When ReqRes records accumulated bodies
        # the row is `{…}{…}`, not JSON, and the MCP helper redacts
        # it as free text: a 24+ character run mixing letters and digits (a
        # uuid4) becomes the redaction placeholder, and the matrix would report
        # "own body missing" instead of the real defect, "carries another
        # exchange". A digit-only nonce is never high-entropy to MCPRedactor.
        self._json(200, {"uuid": f"{uuid.uuid4().int % 10**20:020d}", "probe": probe})

    def _binary(self, **_):
        self._send(200, BINARY_BODY, headers=[("X-Fixture-SHA256", hashlib.sha256(BINARY_BODY).hexdigest())],
                   content_type="application/octet-stream")

    def _rule_probe(self, **_):
        self._send(200, b"fixture-original")

    def _websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            return self._send(400, b"missing Sec-WebSocket-Key")
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        sock = self.connection
        # Frames are READ through rfile: its buffer may already hold bytes that
        # arrived with the upgrade request, and a raw recv would skip them.
        reader = _BufferedRecv(self.rfile)
        try:
            while True:
                opcode, payload = decode_frame(reader)
                if opcode == 0x8:
                    sock.sendall(encode_frame(b"", opcode=0x8))
                    return
                if opcode == 0x9:
                    sock.sendall(encode_frame(payload, opcode=0xA))
                    continue
                if payload.startswith(b"stream "):
                    # The server talks while the client is silent — the shape
                    # passthrough's client-only idle clock cuts.
                    for index in range(int(payload.split()[1])):
                        time.sleep(1)
                        sock.sendall(encode_frame(f"tick {index}".encode()))
                    continue
                sock.sendall(encode_frame(payload, opcode))
        except (ConnectionError, OSError, ValueError, IndexError):
            return


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    tls = None  # an ssl.SSLContext for the HTTPS listeners

    def process_request_thread(self, request, client_address):
        # The TLS handshake runs HERE, on the connection's own thread — wrapping
        # the listening socket would run it inside accept(), where one stalled
        # handshake blocks every other connection to the fixture.
        if self.tls is not None:
            try:
                request.settimeout(15)
                request = self.tls.wrap_socket(request, server_side=True)
                request.settimeout(None)
            except (ssl.SSLError, OSError):
                self.shutdown_request(request)
                return
        super().process_request_thread(request, client_address)


class Server6(Server):
    address_family = socket.AF_INET6


def start(label, host, port, log_path, tls_context=None):
    """Binds and serves on a daemon thread; returns the server or raises OSError."""
    server = (Server6 if ":" in host else Server)((host, port), Handler)
    server.label, server.log_path, server.tls = label, log_path, tls_context
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def tls_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    context.set_alpn_protocols(["http/1.1"])
    return context


def serve(args) -> int:
    started = []
    try:
        if args.cert and args.key:
            context = tls_context(args.cert, args.key)
            started.append(start("https", "127.0.0.1", args.https_port, args.log, context))
            try:
                started.append(start("https6", "::1", args.https_port, args.log, context))
            except OSError as error:
                print(f"fixture: [::1]:{args.https_port} not bound ({error}); the IPv6 row will SKIP", flush=True)
        started.append(start("http", "127.0.0.1", args.http_port, args.log))
    except OSError as error:
        print(f"fixture: cannot bind: {error}", flush=True)
        return 2
    if args.http80:
        try:
            started.append(start("http80", "127.0.0.1", 80, args.log))
        except OSError as error:
            print(f"fixture: 127.0.0.1:80 not bound ({error}); port-80 rows will SKIP", flush=True)
    print("fixture: ready " + " ".join(f"{s.label}={s.server_address[1]}" for s in started), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        return 0


# ----------------------------------------------------------------- self-test

def selftest(_args) -> int:
    """Starts every listener on ephemeral ports with a throwaway self-signed
    certificate and runs the matrix's own rows against them DIRECTLY — no
    proxy. Every row that can run without ReqRes must PASS here; a row that
    fails here is a broken instrument, not a ReqRes defect. Then the matrix's
    verdict functions are fed known-bad answers and must say FAIL."""
    import subprocess
    import tempfile
    here = os.path.dirname(os.path.abspath(__file__))
    work = tempfile.mkdtemp(prefix="reqres-fixture-selftest-")
    cert, key = os.path.join(work, "cert.pem"), os.path.join(work, "key.pem")
    made = subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
         "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1", "-keyout", key, "-out", cert],
        capture_output=True,
    )
    if made.returncode != 0:
        print("selftest: openssl could not make a throwaway certificate; HTTPS rows will be skipped")
        cert = key = None
    log = os.path.join(work, "requests.jsonl")
    context = tls_context(cert, key) if cert else None
    ports = {}
    https = start("https", "127.0.0.1", 0, log, context) if context else None
    if https:
        ports["https"] = https.server_address[1]
        try:
            start("https6", "::1", ports["https"], log, context)
        except OSError:
            pass
    http = start("http", "127.0.0.1", 0, log)
    ports["http"] = http.server_address[1]
    sys.path.insert(0, here)
    import matrix  # noqa: E402  (the matrix lives next to this file)
    code = matrix.run_selftest(ports=ports, log_path=log, work=work)
    if code == 0:
        import shutil
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"selftest: work files kept in {work}")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description="ReqRes protocol-matrix fixture")
    sub = parser.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--log", required=True)
    s.add_argument("--cert")
    s.add_argument("--key")
    s.add_argument("--https-port", type=int, default=8443)
    s.add_argument("--http-port", type=int, default=3000)
    s.add_argument("--http80", action="store_true")
    sub.add_parser("selftest")
    args = parser.parse_args()
    return serve(args) if args.mode == "serve" else selftest(args)


if __name__ == "__main__":
    sys.exit(main())
