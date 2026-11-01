#!/usr/bin/env python3
#
#  matrix.py — the rows of the protocol matrix.
#  Run it through Scripts/protocol-matrix.sh, which starts the fixture, cleans
#  the proxy variables out of the environment and checks ReqRes is listening.
#
#  Every row sends its traffic through `-x http://127.0.0.1:$REQRES_PROXY_PORT` (8034 by default; or, for the
#  WebSocket rows, a CONNECT to that address) and prints one line:
#      PASS|FAIL|SKIP  elapsed  <topic>  <row id>  <what it checks> — <detail>
#  PASS means the behaviour ReqRes should have; a FAIL on a row whose defect is
#  still open is the expected answer until that fix ships. The first run saved
#  with --baseline is what later runs are compared against.
#
#  --direct runs the same rows WITHOUT the proxy (the fixture's self-test uses
#  it): every row that does not need ReqRes must pass there, which is what
#  proves a FAIL through the proxy is ReqRes and not the instrument.
#
#  Optional "record" checks read what ReqRes RECORDED through its own MCP
#  helper (read-only tools: list_sessions, get_session) — the only way to see
#  the wrong-body defect on a reused connection, which the client never notices.
#
#  Nothing here writes outside --out and the fixture's work directory: no
#  keychain, no proxy settings, no ReqRes rules or settings.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
import argparse
import base64
import datetime
import hashlib
import json
import os
import queue
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts in the repo
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fixture  # noqa: E402

# 8034 unless Settings ▸ Capture ▸ Proxy port says otherwise (protocol-matrix.sh
# exports REQRES_PROXY_PORT).
PROXY = ("127.0.0.1", int(os.environ.get("REQRES_PROXY_PORT", "8034")))
MCP_HELPER = "/Applications/ReqRes.app/Contents/MacOS/reqres-mcp"


# ------------------------------------------------------------------ context

class Ctx:
    def __init__(self, direct, https_port, http_port, http80, log_path, work,
                 long_secs=45, quick=False, offline=True, rule_probe=False, recorder=None):
        self.direct = direct
        self.https_port = https_port
        self.http_port = http_port
        self.http80 = http80
        self.log_path = log_path
        self.work = work
        self.long_secs = long_secs
        self.quick = quick
        self.offline = offline
        self.rule_probe = rule_probe
        self.recorder = recorder
        self.out_dir = None  # results directory; the rule control's marker lives there
        self.mode = "direct" if direct else "unknown"  # set by the proxy-mode row
        self.client_trusts_leaf = None                 # set by the client-trust row
        self.run_tag = uuid.uuid4().hex[:8]

    def tag(self, row_id, suffix=""):
        return f"m{self.run_tag}-{row_id}{suffix}"

    def https(self, path, host="localhost"):
        return f"https://{host}:{self.https_port}{path}" if self.https_port else None

    def http(self, path, host="127.0.0.1", port=None):
        return f"http://{host}:{port or self.http_port}{path}"


class Skip(Exception):
    pass


# --------------------------------------------------------------------- curl

def curl(ctx, args, timeout, env_extra=None, via_proxy=True):
    """Runs curl with the proxy (or with every proxy disabled in --direct) and
    returns (returncode, stdout-bytes, stderr-text, elapsed). `-w` output is
    what the caller parses; bodies go to files the caller names."""
    command = ["curl", "-sS", "--max-time", str(timeout)]
    if via_proxy and not ctx.direct:
        command += ["-x", f"http://{PROXY[0]}:{PROXY[1]}"]
    elif via_proxy:
        command += ["--noproxy", "*"]
    command += args
    env = dict(os.environ)
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                 "http_proxy", "https_proxy", "all_proxy", "no_proxy"):
        env.pop(name, None)
    if env_extra:
        env.update(env_extra)
    start = time.time()
    try:
        done = subprocess.run(command, capture_output=True, timeout=timeout + 15, env=env)
        return done.returncode, done.stdout, done.stderr.decode("utf-8", "replace").strip(), time.time() - start
    except subprocess.TimeoutExpired:
        return 124, b"", "curl did not return", time.time() - start


def write_json_marker():
    return ["-w", "\n__RRM__%{json}"]


def split_marker(stdout):
    """Body text and the list of per-transfer -w json objects."""
    text = stdout.decode("utf-8", "replace")
    parts = text.split("\n__RRM__")
    metrics = []
    for part in parts[1:]:
        try:
            metrics.append(json.loads(part.strip().splitlines()[0]))
        except (ValueError, IndexError):
            metrics.append({})
    return parts[0], metrics


def header_lines(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("latin-1").splitlines()
    except OSError:
        return []


def read_log(ctx):
    entries = []
    try:
        with open(ctx.log_path) as handle:
            for line in handle:
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return entries


def curl_failed(code, err):
    return f"curl exit {code}: {err[:160]}" if code else None


# ------------------------------------------------------------- pure verdicts
# Each returns (status, detail). They are pure so the self-test can feed them
# known-bad answers and prove they say FAIL.

def verdict_header_leak(echoed_headers, leaked_names):
    """The second request on a reused connection must carry none of the
    first request's headers (reqHeaders used to accumulate and be sent)."""
    present = {name.lower() for name, _ in echoed_headers}
    leaked = sorted(n for n in leaked_names if n.lower() in present)
    if leaked:
        return "FAIL", "the GET arrived with the POST's " + ", ".join(leaked)
    return "PASS", "the GET arrived with only its own headers"


def verdict_injected(echoed_headers):
    injected = sorted({name for name, _ in echoed_headers if name.lower().startswith("x-req-res")})
    if injected:
        return "FAIL", "ReqRes added " + ", ".join(injected)
    return "PASS", "no X-Req-Res-* header reached the server"


def verdict_set_cookie(lines, expected=2):
    count = sum(1 for line in lines if line.lower().startswith("set-cookie:"))
    if count == expected:
        return "PASS", f"{count} Set-Cookie headers reached the client"
    return "FAIL", f"{count} Set-Cookie header(s) reached the client, the server sent {expected}"


def verdict_sse(body, secs, elapsed):
    if "event: done" in body:
        return "PASS", f"all events and the done event in {elapsed:.1f}s"
    events = body.count("\n\n")
    return "FAIL", f"cut after {elapsed:.1f}s with {events} event(s), no done event (the stream lasts {secs:g}s)"


def verdict_recorded_bodies(expected_by_tag, recorded_by_tag):
    """Each exchange on one connection must be recorded with ITS OWN body
    (bodies used to be only appended, so row N showed responses 1..N)."""
    wrong = []
    for tag, own in expected_by_tag.items():
        body = recorded_by_tag.get(tag)
        if body is None:
            wrong.append(f"{tag}: no row")
            continue
        others = [value for other, value in expected_by_tag.items() if other != tag and value in body]
        if own not in body or others:
            wrong.append(f"{tag}: {'own body missing' if own not in body else 'carries another exchange'}")
    if wrong:
        return "FAIL", "; ".join(wrong)
    return "PASS", f"{len(expected_by_tag)} rows, each with its own body"


RAW_QUERY = 'q={"a":1}|x^y`z'


def verdict_raw_query(http_code, logged_paths, raw=RAW_QUERY):
    """Bytes browsers send unencoded in a query (WHATWG URL rules) must reach
    the server byte-identical. swift-nio 2.103's own outbound validator
    refuses `{ } | ^` and backtick (a 502 blaming the server); ReqRes's own
    validator forwards them."""
    if http_code != "200":
        return "FAIL", f"HTTP {http_code or '—'}: the request never reached the server whole"
    if not logged_paths:
        return "FAIL", "200, but the fixture logged no such request"
    if any(raw in path for path in logged_paths):
        return "PASS", "the query reached the server byte-identical"
    return "FAIL", "the server saw a rewritten target: " + logged_paths[0][:120]


def verdict_framing(lines):
    names = {line.split(":", 1)[0].lower() for line in lines if ":" in line}
    if "content-length" in names or "transfer-encoding" in names:
        return "PASS", "the response kept its framing header"
    return "FAIL", "no Content-Length or Transfer-Encoding: the response became close-delimited"


# ------------------------------------------------------------------- rows

def tls_issuer_row(ctx):
    """Which path HTTPS takes through ReqRes right now: intercepted (the leaf
    is signed by "ReqRes CA") or passthrough (the fixture's own certificate).
    Everything else is read in that light, so it runs first."""
    if not ctx.https_port:
        raise Skip("no HTTPS fixture (mkcert not set up)")
    sock = connect_through(ctx, "localhost", ctx.https_port, timeout=10)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    tls = context.wrap_socket(sock, server_hostname="localhost")
    der = tls.getpeercert(binary_form=True) or b""
    tls.close()
    if ctx.direct:
        ctx.mode = "direct"
        return "PASS", "direct (no proxy): the fixture's own certificate"
    if b"ReqRes CA" in der:
        ctx.mode = "intercepted"
        return "PASS", "INTERCEPTED — the leaf is issued by \"ReqRes CA\""
    ctx.mode = "passthrough"
    return "PASS", "PASSTHROUGH — the fixture's own certificate came back (CA not installed when capture started, or localhost excluded)"


def upstream_trust_row(ctx):
    if ctx.direct or ctx.mode != "intercepted":
        raise Skip("only the intercepted path verifies the upstream certificate")
    code, out, err, _ = curl(ctx, ["-k", "-o", "/dev/null", "-w", "%{http_code}", ctx.https("/health")], 20)
    status = out.decode().strip()
    if status == "200":
        return "PASS", "the root extension verified the fixture's mkcert certificate"
    return "FAIL", (f"HTTP {status or '—'} ({curl_failed(code, err) or 'no error'}) — the root extension did not accept the "
                    "fixture's certificate; is the mkcert CA in the System keychain (`mkcert -install`)? Every intercepted "
                    "local row below fails for this reason, not its own")


def client_trust_row(ctx):
    if not ctx.https_port:
        raise Skip("no HTTPS fixture")
    code, out, err, _ = curl(ctx, ["-o", "/dev/null", "-w", "%{http_code}", ctx.https("/health")], 20)
    ok = out.decode().strip() == "200"
    ctx.client_trusts_leaf = ok
    if ok:
        return "PASS", "curl verified the certificate it was shown for localhost"
    # A control, not a ReqRes check: which certificate curl is shown depends on
    # the mode (ReqRes's leaf, or the fixture's mkcert one in passthrough), and
    # whether this user's keychain trusts that issuer is not ReqRes's doing.
    raise Skip(f"curl does not trust the certificate it was shown for localhost ({err[:100]}); ip-literal will SKIP")


def sse_long_row(ctx):
    secs = ctx.long_secs
    code, out, err, elapsed = curl(ctx, ["-k", "-N", ctx.https(f"/sse?secs={secs}&every=1&probe={ctx.tag('sse')}")], secs + 30)
    return verdict_sse(out.decode("utf-8", "replace"), secs, elapsed)


def slow_ttfb_row(ctx, secs=None, row="slow"):
    secs = secs if secs is not None else ctx.long_secs
    code, out, err, elapsed = curl(ctx, ["-k", ctx.https(f"/slow?ttfb={secs}&probe={ctx.tag(row)}")], secs + 30)
    if out.decode("utf-8", "replace").startswith("slow-ok"):
        return "PASS", f"first byte after {elapsed:.1f}s, response complete"
    return "FAIL", f"no response after {elapsed:.1f}s ({curl_failed(code, err) or 'empty'}); the server answers at {secs:g}s"


def drip_row(ctx, secs, row="drip"):
    size = max(10, int(secs))
    code, out, err, elapsed = curl(ctx, ["-k", "-N", ctx.https(f"/drip?secs={secs}&bytes={size}&probe={ctx.tag(row)}")], secs + 30)
    got = out.count(b"*")
    if got == size and code == 0:
        return "PASS", f"{size} bytes over {elapsed:.1f}s"
    return "FAIL", f"{got}/{size} bytes, cut after {elapsed:.1f}s ({curl_failed(code, err) or 'short'})"


def upload_long_row(ctx):
    secs = max(2, round(ctx.long_secs * 4 / 3))  # 60 s at the default 45
    rate = 20000
    path = os.path.join(ctx.work, "upload.bin")
    with open(path, "wb") as handle:
        handle.write(os.urandom(rate * secs))
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    code, out, err, elapsed = curl(ctx, ["-k", "-T", path, "--limit-rate", str(rate), ctx.https(f"/upload?probe={ctx.tag('upload')}")], secs + 40)
    try:
        answer = json.loads(out.decode())
    except ValueError:
        return "FAIL", f"no answer after {elapsed:.1f}s ({curl_failed(code, err) or out[:80]!r})"
    if answer.get("sha256") == digest:
        return "PASS", f"{answer['bytes']} bytes uploaded over {elapsed:.1f}s, checksum matches"
    return "FAIL", f"the sink received {answer.get('bytes')} bytes, checksum differs"


def reuse_bodies_row(ctx):
    tags = [ctx.tag("reuse", str(i)) for i in range(3)]
    outs = [os.path.join(ctx.work, f"reuse-{i}.json") for i in range(3)]
    args = ["-k"]
    for tag, out in zip(tags, outs):
        args += ["-o", out, ctx.https(f"/uuid?probe={tag}")]
    code, stdout, err, _ = curl(ctx, args + ["-w", "%{num_connects} "], 30)
    if code:
        return "FAIL", curl_failed(code, err)
    connects = stdout.decode().split()
    uuids = {}
    for tag, out in zip(tags, outs):
        try:
            uuids[tag] = json.load(open(out))["uuid"]
        except (OSError, ValueError, KeyError):
            return "FAIL", f"{tag}: the client got no uuid"
    if len(set(uuids.values())) != 3:
        return "FAIL", "the client got a repeated body"
    reused = connects[1:] == ["0", "0"]
    if not reused:
        raise Skip(f"curl did not reuse its connection (connects per transfer: {' '.join(connects)})")
    if ctx.recorder is None:
        raise Skip("the client got three distinct bodies on one connection; what ReqRes RECORDED needs --record (or look at the three /uuid rows in ReqRes)")
    recorded = {tag: ctx.recorder.response_body(tag) for tag in tags}
    return verdict_recorded_bodies(uuids, recorded)


def header_leak_row(ctx):
    tag = ctx.tag("leak")
    out = os.path.join(ctx.work, "leak.json")
    args = ["-k", "-X", "POST", "-H", "Authorization: Bearer matrix-leak", "-H", "X-Matrix-Only-First: 1",
            "--data-binary", "abcdef", "-o", "/dev/null", ctx.https(f"/upload?probe={tag}-post"),
            "--next"]
    if not ctx.direct:
        args += ["-x", f"http://{PROXY[0]}:{PROXY[1]}"]
    else:
        args += ["--noproxy", "*"]
    args += ["-k", "-o", out, ctx.https(f"/echo-headers?probe={tag}-get")]
    code, _, err, _ = curl(ctx, args, 30)
    if code:
        return "FAIL", curl_failed(code, err)
    try:
        echoed = json.load(open(out))
    except (OSError, ValueError):
        return "FAIL", "the GET got no echo"
    ports = {e["path"].split("probe=")[-1]: e["client_port"] for e in read_log(ctx) if tag in e.get("path", "")}
    if ports.get(f"{tag}-post") != ports.get(f"{tag}-get"):
        raise Skip("the two requests reached the fixture on different connections, so reuse was not exercised")
    return verdict_header_leak(echoed["headers"], ["Content-Length", "Authorization", "X-Matrix-Only-First"])


def set_cookie_row(ctx):
    headers = os.path.join(ctx.work, "cookies.headers")
    code, _, err, _ = curl(ctx, ["-k", "-D", headers, "-o", "/dev/null", ctx.https(f"/cookies?probe={ctx.tag('cookies')}")], 20)
    if code:
        return "FAIL", curl_failed(code, err)
    return verdict_set_cookie(header_lines(headers))


def injected_headers_row(ctx):
    out = os.path.join(ctx.work, "echo.json")
    code, _, err, _ = curl(ctx, ["-k", "-o", out, ctx.https(f"/echo-headers?probe={ctx.tag('echo')}")], 20)
    if code:
        return "FAIL", curl_failed(code, err)
    return verdict_injected(json.load(open(out))["headers"])


def gzip_row(ctx):
    tag = ctx.tag("gzip")
    code, out, err, _ = curl(ctx, ["-k", "--compressed", ctx.https(f"/gzip?probe={tag}")], 20)
    if code or b'"gzipped": true' not in out:
        return "FAIL", curl_failed(code, err) or "the client could not decode the body"
    if ctx.recorder is None:
        return "PASS", "the client decoded the gzip body (recorded body not checked without --record)"
    body = ctx.recorder.response_body(tag)
    if body and '"gzipped"' in body:
        return "PASS", "decoded by the client AND recorded decoded"
    return "FAIL", "the client decoded it, but ReqRes recorded " + ("no row" if body is None else "no readable body")


def binary_row(ctx):
    tag = ctx.tag("binary")
    out = os.path.join(ctx.work, "binary.bin")
    code, _, err, _ = curl(ctx, ["-k", "-o", out, ctx.https(f"/binary?probe={tag}")], 20)
    if code:
        return "FAIL", curl_failed(code, err)
    if open(out, "rb").read() != fixture.BINARY_BODY:
        return "FAIL", "the client received different bytes"
    if ctx.recorder is None:
        return "PASS", "the client received the 256 bytes intact (recorded body not checked without --record)"
    body = ctx.recorder.response_body(tag)
    if body:
        return "PASS", "intact at the client AND a body is recorded"
    return "FAIL", "intact at the client, but ReqRes recorded " + ("no row" if body is None else "an EMPTY body")


def empty_row(ctx, status):
    headers = os.path.join(ctx.work, f"empty{status}.headers")
    code, out, err, elapsed = curl(ctx, ["-k", "-D", headers, "-o", "/dev/null", "-w", "%{http_code}",
                                         ctx.https(f"/empty?status={status}&probe={ctx.tag('empty', str(status))}")], 15)
    got = out.decode().strip()
    if got == str(status) and elapsed < 5 and not code:
        return "PASS", f"{status} with no body in {elapsed:.1f}s"
    return "FAIL", f"HTTP {got or '—'} after {elapsed:.1f}s ({curl_failed(code, err) or 'framing'})"


def expect_100_row(ctx):
    path = os.path.join(ctx.work, "expect.bin")
    with open(path, "wb") as handle:
        handle.write(os.urandom(1 << 20))
    code, out, err, elapsed = curl(ctx, ["-k", "-H", "Expect: 100-continue", "--expect100-timeout", "8",
                                         "--data-binary", "@" + path, "-o", "/dev/null", "-w", "%{http_code}",
                                         ctx.https(f"/upload?probe={ctx.tag('expect')}")], 30)
    if out.decode().strip() == "200" and elapsed < 5:
        return "PASS", f"the server's 100 Continue reached the client ({elapsed:.1f}s)"
    return "FAIL", f"HTTP {out.decode().strip() or '—'} after {elapsed:.1f}s — curl waited out its own 8 s expect timeout"


def big_header_row(ctx):
    args = ["-k", "-o", "/dev/null", "-w", "%{http_code}"]
    for index in range(10):
        args += ["-H", f"X-Matrix-Big-{index}: " + "a" * 7000]
    code, out, err, _ = curl(ctx, args + [ctx.https(f"/health?probe={ctx.tag('bighdr')}")], 20)
    status = out.decode().strip()
    if status == "200":
        return "PASS", "a 70 KB request header block went through"
    return "FAIL", f"HTTP {status or '—'} ({curl_failed(code, err) or 'refused'})"


def raw_query_row(ctx):
    tag = ctx.tag("rawq")
    # -g: curl must not treat {} as a glob; the bytes go out as written.
    code, out, err, _ = curl(ctx, ["-g", "-k", "-o", "/dev/null", "-w", "%{http_code}",
                                   ctx.https(f"/health?probe={tag}&{RAW_QUERY}")], 20)
    if code and not out:
        return "FAIL", curl_failed(code, err)
    paths = [e.get("path", "") for e in read_log(ctx) if tag in e.get("path", "")]
    return verdict_raw_query(out.decode().strip(), paths)


def ip_literal_row(ctx):
    if not ctx.client_trusts_leaf:
        raise Skip("curl does not trust the leaf it is shown for localhost, so a verification failure here would prove nothing")
    code, out, err, _ = curl(ctx, ["-o", "/dev/null", "-w", "%{http_code}", ctx.https("/health", host="127.0.0.1")], 20)
    if out.decode().strip() == "200":
        return "PASS", "the certificate for https://127.0.0.1 verified (IP SAN)"
    return "FAIL", f"verification failed for an IP-literal host ({err[:120]}) — the leaf names the IP as DNS:, not IP:"


def ipv6_row(ctx):
    try:
        socket.create_connection(("::1", ctx.https_port), timeout=3).close()
    except OSError:
        raise Skip("the fixture has no [::1] listener")
    code, out, err, _ = curl(ctx, ["-k", "-g", "-o", "/dev/null", "-w", "%{http_code}", ctx.https("/health", host="[::1]")], 20)
    if out.decode().strip() == "200":
        return "PASS", "https://[::1] answered"
    return "FAIL", f"HTTP {out.decode().strip() or '—'} ({curl_failed(code, err) or ''})"


def failure_row(ctx):
    if ctx.direct:
        raise Skip("needs the proxy")
    closed = free_port()
    code, out, err, elapsed = curl(ctx, ["-k", "-o", "/dev/null", "-w", "%{http_connect} %{http_code}", f"https://127.0.0.1:{closed}/"], 20)
    parts = out.decode().split() + ["", ""]
    connect, status = parts[0], parts[1]
    # Two right answers: with the CA installed a CONNECT is
    # answered 200 WITHOUT a dial (mocks never contact the server) and the
    # first request gets the 502; without the CA the server is dialled before
    # the CONNECT is answered, so the CONNECT itself gets the 502.
    detail = f"CONNECT answered {connect or 'nothing'}, the request {status or 'nothing'}"
    if not (connect == "502" or (connect == "200" and status == "502")):
        return "FAIL", detail + " — wanted 502 at the CONNECT (no CA) or 200 then 502 at the request (CA installed)"
    if ctx.recorder is not None and ctx.recorder.find_rows(f"127.0.0.1:{closed}") == []:
        return "FAIL", detail + ", but no row was recorded"
    return "PASS", detail


def ws_exchange(sock, host, port, echoes=5, stream=3):
    """Upgrade on `sock`, echo `echoes` frames, ask the server to talk for
    `stream` seconds while we stay silent, then echo again. Returns (ok, detail)."""
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET /ws HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            return False, "closed before the upgrade answer"
        head += chunk
    status = head.split(b"\r\n")[0].decode("latin-1")
    if " 101" not in status:
        return False, f"no upgrade: {status}"
    if fixture.websocket_accept(key).encode() not in head:
        return False, "wrong Sec-WebSocket-Accept"
    done = 0
    for index in range(echoes):
        message = f"echo {index}".encode()
        sock.sendall(fixture.encode_frame(message, mask=True))
        _, payload = fixture.decode_frame(sock)
        if payload != message:
            return False, f"echo {index} came back as {payload[:40]!r}"
        done += 1
    if stream:
        sock.sendall(fixture.encode_frame(f"stream {stream}".encode(), mask=True))
        for index in range(stream):
            _, payload = fixture.decode_frame(sock)
            if payload != f"tick {index}".encode():
                return False, f"server-to-client stream broke at tick {index}"
    message = b"after the quiet"
    sock.sendall(fixture.encode_frame(message, mask=True))
    _, payload = fixture.decode_frame(sock)
    if payload != message:
        return False, "no echo after the client's quiet period"
    sock.sendall(fixture.encode_frame(b"", opcode=0x8, mask=True))
    return True, f"101, {done} echoes, {stream} s of server-only frames, one more echo"


def wss_local_row(ctx):
    sock = connect_through(ctx, "localhost", ctx.https_port, timeout=15)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    sock = context.wrap_socket(sock, server_hostname="localhost")
    sock.settimeout(10)
    try:
        ok, detail = ws_exchange(sock, "localhost", ctx.https_port)
    except (OSError, ConnectionError, ValueError) as error:
        ok, detail = False, f"stalled or dropped ({error or type(error).__name__})"
    finally:
        sock.close()
    return ("PASS" if ok else "FAIL"), f"[{ctx.mode}] {detail}"


def ws_plain_row(ctx):
    sock = connect_through(ctx, "127.0.0.1", ctx.http_port, timeout=15)
    sock.settimeout(10)
    try:
        ok, detail = ws_exchange(sock, "127.0.0.1", ctx.http_port, echoes=3, stream=2)
    except (OSError, ConnectionError, ValueError) as error:
        ok, detail = False, f"stalled or dropped ({error or type(error).__name__})"
    finally:
        sock.close()
    return ("PASS" if ok else "FAIL"), detail


def http_non80_row(ctx):
    code, out, err, elapsed = curl(ctx, ["-o", "/dev/null", "-w", "%{http_code}", ctx.http(f"/uuid?probe={ctx.tag('http3000')}")], 12)
    if out.decode().strip() == "200":
        return "PASS", f"plain http:// on port {ctx.http_port} answered in {elapsed:.1f}s"
    return "FAIL", f"no answer after {elapsed:.1f}s ({curl_failed(code, err) or ''}) — plain HTTP did not reach a port other than 80"


def http80_row(ctx):
    if not ctx.http80:
        raise Skip("the fixture could not bind 127.0.0.1:80 (see http-neverssl for the same check against a real site)")
    headers = os.path.join(ctx.work, "http80.headers")
    code, out, err, elapsed = curl(ctx, ["-D", headers, "-o", "/dev/null", "-w", "%{http_code}",
                                         ctx.http(f"/uuid?probe={ctx.tag('http80')}", port=80)], 15)
    if out.decode().strip() != "200":
        return "FAIL", f"HTTP {out.decode().strip() or '—'} after {elapsed:.1f}s ({curl_failed(code, err) or ''})"
    status, detail = verdict_framing(header_lines(headers))
    code, out, err, elapsed = curl(ctx, ["-o", "/dev/null", "-w", "%{http_code}", ctx.http("/empty?status=204", port=80)], 10)
    if out.decode().strip() != "204" or elapsed > 5:
        return "FAIL", f"{detail}; a 204 took {elapsed:.1f}s (bogus chunked terminator?)"
    return status, detail + "; a 204 finished promptly"


# The rule rows send `Host: localhost` (no port). The core finds a request's
# host filter by the inner request's Host header, exactly
# (`MitmService.allHostsByHostName[head.headers["Host"].first]`, GlueHandler),
# and a host filter cannot carry a port (AddHostModal, MCPWriteValidation). A
# plain `curl https://localhost:8443/…` sends `Host: localhost:8443`, which no
# filter can ever equal — a rule would never apply, enabled or not, and a
# "disabled rule did not apply" PASS would prove nothing. The CONNECT target
# stays localhost:8443; the fixture ignores Host.
RULE_PROBE_HOST_HEADER = ["-H", "Host: localhost"]
RULE_CONTROL_MARKER = "rule-control-passed"


def verdict_rule(phase, http_code, body):
    """`enabled`: the positive control — the override must rewrite the answer,
    or the rule cannot match this host and the disabled check is meaningless
    (SKIP, not PASS). `disabled`: the fixture's own answer must come back."""
    original = body == "fixture-original" and http_code == "200"
    if phase == "enabled":
        if original:
            return "SKIP", "the ENABLED override did not apply — rules cannot match this host, so the disabled check would prove nothing (is the host filter exactly `localhost`?)"
        return "PASS", f"the enabled override applied (HTTP {http_code or '—'}, {body[:40]!r})"
    if original:
        return "PASS", "the disabled rule did not apply"
    return "FAIL", f"HTTP {http_code or '—'}, {body[:60]!r} — a disabled rule still rewrote the answer"


def rule_probe_answer(ctx):
    out = os.path.join(ctx.work, "rule-probe.body")
    code, stdout, err, _ = curl(ctx, ["-k", *RULE_PROBE_HOST_HEADER, "-o", out, "-w", "%{http_code}",
                                      ctx.https("/rule-probe")], 20)
    if code:
        return None, None, curl_failed(code, err)
    try:
        body = open(out, "rb").read().decode("utf-8", "replace")
    except OSError:
        body = ""
    return stdout.decode().strip(), body, None


def rule_marker_path(ctx):
    return os.path.join(ctx.out_dir, RULE_CONTROL_MARKER) if ctx.out_dir else None


def rule_enabled_row(ctx):
    if ctx.rule_probe != "enabled":
        raise Skip("step 1 of the rule check: create an ENABLED override for host `localhost`, path /rule-probe, then run with --rule-probe enabled (see the checklist)")
    http_code, body, failure = rule_probe_answer(ctx)
    if failure:
        return "FAIL", failure
    status, detail = verdict_rule("enabled", http_code, body)
    marker = rule_marker_path(ctx)
    if marker:
        if status == "PASS":
            with open(marker, "w") as handle:
                handle.write(datetime.datetime.now().isoformat() + "\n")
        elif os.path.exists(marker):
            os.remove(marker)
    return status, detail


def rule_disabled_row(ctx):
    if ctx.rule_probe != "disabled":
        raise Skip("step 2 of the rule check: switch the override OFF in the Overrides list, then run with --rule-probe disabled")
    marker = rule_marker_path(ctx)
    if marker is not None and not os.path.exists(marker):
        raise Skip("the enabled control has not passed in this results directory — run --rule-probe enabled first, or a PASS here proves nothing")
    http_code, body, failure = rule_probe_answer(ctx)
    if failure:
        return "FAIL", failure
    return verdict_rule("disabled", http_code, body)


# The value the Settings ▸ Capture block exports. Its single source is
# `CaptureEnvironmentLines.noProxyHosts` (Swift, MCPKit); the self-test reads
# that file and fails if the two ever differ, so this row cannot drift from
# what the pane prints.
NO_PROXY_HOSTS = "localhost,127.0.0.1,::1"
CAPTURE_ENVIRONMENT_SWIFT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Sources",
                                         "AppServices", "Sources", "MCPKit", "CaptureEnvironmentLines.swift")


def swift_no_proxy_hosts():
    """The literal assigned to `noProxyHosts` in CaptureEnvironmentLines.swift,
    or None when the file or the line is not there."""
    try:
        source = open(CAPTURE_ENVIRONMENT_SWIFT).read()
    except OSError:
        return None
    found = re.search(r'static let noProxyHosts\s*=\s*"([^"]*)"', source)
    return found.group(1) if found else None


def no_proxy_row(ctx):
    """The Settings pane's NO_PROXY line: with HTTP_PROXY pointing
    at ReqRes, a local backend must still be reached directly."""
    env = {"HTTP_PROXY": f"http://{PROXY[0]}:{PROXY[1]}", "http_proxy": f"http://{PROXY[0]}:{PROXY[1]}",
           "NO_PROXY": NO_PROXY_HOSTS, "no_proxy": NO_PROXY_HOSTS}
    code, out, err, elapsed = curl(ctx, ["-o", "/dev/null", "-w", "%{http_code}", ctx.http("/health", host="localhost")], 10,
                                   env_extra=env, via_proxy=False)
    if out.decode().strip() == "200":
        return "PASS", f"localhost bypassed the proxy ({elapsed:.1f}s)"
    return "FAIL", f"no answer ({curl_failed(code, err) or ''}) — the environment block would hang a local backend"


# --- rows against real sites (skipped with --offline)

def reachable_directly(url):
    code, _, _, _ = curl(Ctx(True, None, None, False, None, None), ["-o", "/dev/null", url], 10)
    return code == 0


def internet_row(url, fn):
    def run(ctx):
        if not reachable_directly(url):
            raise Skip(f"{url} is not reachable even without the proxy")
        return fn(ctx)
    return run


def httpbin_drip_row(ctx):
    code, out, err, elapsed = curl(ctx, ["-N", "https://httpbin.org/drip?duration=60&numbytes=60"], 100)
    if code == 0 and out.count(b"*") == 60:
        return "PASS", f"60 bytes over {elapsed:.1f}s"
    return "FAIL", f"{out.count(b'*')}/60 bytes, cut after {elapsed:.1f}s ({curl_failed(code, err) or ''})"


def httpbin_cookies_row(ctx):
    headers = os.path.join(ctx.work, "httpbin-cookies.headers")
    code, _, err, _ = curl(ctx, ["-D", headers, "-o", "/dev/null", "https://httpbin.org/cookies/set?a=1&b=2"], 20)
    if code:
        return "FAIL", curl_failed(code, err)
    return verdict_set_cookie(header_lines(headers))


def neverssl_row(ctx):
    headers = os.path.join(ctx.work, "neverssl.headers")
    code, _, err, elapsed = curl(ctx, ["-D", headers, "-o", "/dev/null", "http://neverssl.com/"], 20)
    if code:
        return "FAIL", f"{curl_failed(code, err)} after {elapsed:.1f}s"
    status, detail = verdict_framing(header_lines(headers))
    return status, f"{detail} ({elapsed:.1f}s)"


def wss_public_row(ctx):
    sock = connect_through(ctx, "echo.websocket.org", 443, timeout=15)
    context = ssl.create_default_context() if ctx.direct else ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if not ctx.direct:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    sock = context.wrap_socket(sock, server_hostname="echo.websocket.org")
    sock.settimeout(10)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET / HTTP/1.1\r\nHost: echo.websocket.org\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1)
            if not chunk:
                return "FAIL", "closed before the upgrade answer"
            head += chunk
        if b" 101" not in head.split(b"\r\n")[0]:
            return "FAIL", "no upgrade: " + head.split(b"\r\n")[0].decode("latin-1")
        for index in range(3):
            message = f"reqres-matrix {index}".encode()
            sock.sendall(fixture.encode_frame(message, mask=True))
            for _ in range(4):  # the server greets first
                _, payload = fixture.decode_frame(sock)
                if payload == message:
                    break
            else:
                return "FAIL", f"echo {index} never came back"
        return "PASS", f"[{ctx.mode}] 101 and 3 echoes through a publicly trusted upstream"
    except (OSError, ConnectionError, ValueError) as error:
        return "FAIL", f"[{ctx.mode}] stalled after the upgrade ({error or type(error).__name__})"
    finally:
        sock.close()


def h2_row(ctx):
    code, out, err, _ = curl(ctx, ["--http2", "-o", "/dev/null", "-w", "%{http_code} %{http_version}", "https://www.google.com/"], 20)
    parts = out.decode().split()
    if code or not parts:
        return "FAIL", curl_failed(code, err) or "no answer"
    note = "HTTP/2 capture is on" if parts[1] == "2" else "HTTP/2 capture is off (the default) — Settings ▸ Capture ▸ Capture HTTP/2 (beta)"
    return "PASS", f"HTTP {parts[0]}, negotiated HTTP/{parts[1]} ({note})"


# ------------------------------------------------------------ plumbing

def connect_through(ctx, host, port, timeout):
    """A TCP socket to host:port — via a CONNECT through ReqRes, or directly."""
    if ctx.direct:
        return socket.create_connection((host, port), timeout=timeout)
    sock = socket.create_connection(PROXY, timeout=timeout)
    sock.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            raise ConnectionError("the proxy closed the connection during CONNECT")
        head += chunk
    status = head.split(b"\r\n")[0].decode("latin-1")
    if " 200" not in status:
        raise ConnectionError(f"CONNECT answered {status}")
    return sock


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def proxy_listening():
    try:
        socket.create_connection(PROXY, timeout=2).close()
        return True
    except OSError:
        return False


class Recorder:
    """What ReqRes recorded, read through its own MCP helper over stdio.
    Read-only tools only (list_sessions, get_session)."""

    def __init__(self, helper):
        self.process = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
        self.replies = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.next_id = 1
        reply = self._call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "protocol-matrix", "version": "1"}})
        if not reply or "result" not in reply:
            raise RuntimeError("the MCP helper did not initialize")
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        text, is_error = self._tool("list_sessions", {"limit": 1})
        if text is None or is_error:
            raise RuntimeError(f"the MCP helper cannot read ReqRes's sessions: {(text or 'no answer')[:160]}")

    def _pump(self):
        for line in self.process.stdout:
            try:
                self.replies.put(json.loads(line))
            except ValueError:
                pass

    def _send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def _call(self, method, params, timeout=15):
        self.next_id += 1
        ident = self.next_id
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                reply = self.replies.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if reply.get("id") == ident:
                return reply
        return None

    def _tool(self, name, arguments):
        reply = self._call("tools/call", {"name": name, "arguments": arguments})
        try:
            return reply["result"]["content"][0]["text"], bool(reply["result"].get("isError"))
        except (TypeError, KeyError, IndexError):
            return None, True

    def tool(self, name, arguments):
        text, is_error = self._tool(name, arguments)
        return None if is_error else text

    def find_rows(self, url_part, wait=6):
        deadline = time.time() + wait
        while True:
            text = self.tool("list_sessions", {"url_contains": url_part, "limit": 20}) or ""
            uids = re.findall(r"uid=(\S+)", text)
            if uids or time.time() > deadline:
                return uids
            time.sleep(0.5)

    def response_body(self, tag):
        """The recorded response body of the row whose URL carries `tag`, ''
        when the row has none, None when there is no row."""
        uids = self.find_rows(f"probe={tag}")
        if not uids:
            return None
        detail = self.tool("get_session", {"uid": uids[0]}) or ""
        if "\nResponse body:\n" not in detail:
            return ""
        return detail.split("\nResponse body:\n", 1)[1].split("\ncURL:", 1)[0]

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()


# ------------------------------------------------------------------ table

LONG, NET, HTTPS = "long", "internet", "https"

ROWS = [
    # id, topic, what it checks, function, tags
    ("proxy-mode", "https path", "which HTTPS path ReqRes takes right now", tls_issuer_row, {HTTPS}),
    ("upstream-trust", "upstream tls", "the root extension trusts the fixture's mkcert CA", upstream_trust_row, {HTTPS}),
    ("client-trust", "client tls", "curl trusts the leaf it is shown (control for ip-literal)", client_trust_row, {HTTPS}),
    ("no-injected-headers", "headers", "no X-Req-Res-* header reaches the server", injected_headers_row, {HTTPS}),
    ("reuse-header-leak", "connection reuse", "a GET after a POST on one connection carries only its own headers", header_leak_row, {HTTPS}),
    ("reuse-bodies", "connection reuse", "three exchanges on one connection are recorded with their own bodies", reuse_bodies_row, {HTTPS}),
    ("set-cookie-x2", "headers", "two Set-Cookie headers both reach the client", set_cookie_row, {HTTPS}),
    ("gzip-body", "bodies", "a gzip body is decoded (client, and recorded with --record)", gzip_row, {HTTPS}),
    ("binary-body", "bodies", "a non-UTF-8 body arrives intact (and is recorded with --record)", binary_row, {HTTPS}),
    ("empty-204", "framing", "204 with no body finishes promptly", lambda c: empty_row(c, 204), {HTTPS}),
    ("empty-400", "framing", "400 with Content-Length: 0 finishes promptly", lambda c: empty_row(c, 400), {HTTPS}),
    ("expect-100", "1xx", "Expect: 100-continue gets the server's 100", expect_100_row, {HTTPS}),
    ("big-header-block", "header limits", "a 70 KB request header block goes through", big_header_row, {HTTPS}),
    ("raw-query-bytes", "request target", "a query carrying { \" | ^ ` reaches the server byte-identical", raw_query_row, {HTTPS}),
    ("ip-literal", "ip literals", "https://127.0.0.1 verifies (IP SAN in the leaf)", ip_literal_row, {HTTPS}),
    ("ipv6-literal", "ip literals", "https://[::1] works", ipv6_row, {HTTPS}),
    ("slow-2", "relay idle", "a 2 s time-to-first-byte (passthrough's delay/2)", lambda c: slow_ttfb_row(c, 2, "slow2"), {HTTPS}),
    ("drip-5", "relay idle", "a 5 s download (passthrough's cut)", lambda c: drip_row(c, 5, "drip5"), {HTTPS}),
    ("failure-row", "failures", "a CONNECT to a closed port answers 502 (and leaves a row)", failure_row, set()),
    ("wss-local", "websocket", "wss:// echo + server-only frames through a trusted upstream", wss_local_row, {HTTPS}),
    ("ws-plain", "websocket", "ws:// echo via CONNECT to a plain port", ws_plain_row, set()),
    ("http-port-3000", "plain http", "plain http:// to a non-80 port", http_non80_row, set()),
    ("http-port-80", "plain http", "plain http:// on port 80 keeps its framing", http80_row, set()),
    ("no-proxy-env", "no_proxy", "the Capture pane's NO_PROXY keeps localhost off the proxy", no_proxy_row, set()),
    ("rule-enabled", "rules", "control: an ENABLED override applies to this host", rule_enabled_row, {HTTPS}),
    ("rule-disabled", "rules", "a DISABLED override does not apply", rule_disabled_row, {HTTPS}),
    ("sse-long", "long transfers", "an SSE stream longer than 30 s", sse_long_row, {HTTPS, LONG}),
    ("slow-ttfb-long", "long transfers", "a first byte after more than 30 s", slow_ttfb_row, {HTTPS, LONG}),
    ("drip-long", "long transfers", "a download lasting about 90 s", lambda c: drip_row(c, 2 * c.long_secs, "driplong"), {HTTPS, LONG}),
    ("upload-long", "long transfers", "an upload lasting about 60 s", upload_long_row, {HTTPS, LONG}),
    ("httpbin-drip-60", "long transfers", "httpbin drip for 60 s", internet_row("https://httpbin.org/get", httpbin_drip_row), {NET, LONG}),
    ("httpbin-cookies", "headers", "httpbin sets two cookies; both reach the client", internet_row("https://httpbin.org/get", httpbin_cookies_row), {NET}),
    ("wss-public", "websocket", "wss://echo.websocket.org through the intercepted path", internet_row("https://echo.websocket.org/", wss_public_row), {NET}),
    ("http-neverssl", "plain http", "plain http://neverssl.com keeps its framing", internet_row("http://neverssl.com/", neverssl_row), {NET}),
    ("h2-negotiation", "http/2", "what HTTP version a --http2 client ends up with", internet_row("https://www.google.com/", h2_row), {NET}),
]

MANUAL = [
    ("LLM stream", "A real LLM stream through HTTPS_PROXY: paste Settings ▸ Capture's lines into a fresh terminal, run a long `claude` answer; it must finish and appear as ONE row."),
    ("no CA", "Remove the CA (Settings ▸ Certificate), restart capture, and run this matrix again — proxy-mode must say PASSTHROUGH; drip-5, slow-2 and wss-local are the relay-idle rows."),
    ("codesign", "`codesign --force --timestamp -s <identity> <some copy>` while capturing: does it fail? If the timestamp request is plain http://timestamp.apple.com the default exclusion never protected it."),
    ("zstd", "Brave/Chrome on a site that serves zstd (e.g. facebook.com): is the recorded body readable?"),
    ("HTTP/3", "Safari and Brave on an HTTP/3 site (cloudflare-quic.com) with capture on: a CONNECT row appears (QUIC fell back to TCP)."),
    ("rules", "Rules, two runs: add the host filter `localhost` (no port) and an Override on it for path `/rule-probe` returning 418; run `Scripts/protocol-matrix.sh --only rule-enabled --rule-probe enabled` (must PASS — the control); switch the override OFF in the Overrides list; run `Scripts/protocol-matrix.sh --only rule-disabled --rule-probe disabled`."),
    ("mocks", "Mocks: a Map Local rule on the host filter `localhost` (no port) for /uuid; request it with `curl -x http://127.0.0.1:8034 -k -H 'Host: localhost' https://localhost:8443/uuid` (without that Host header the rule can never match — the core compares Host exactly, port included); the mock must come back, and /uuid must NOT be in the fixture's request log (path printed below)."),
    ("memory", "Memory: `curl -N -x http://127.0.0.1:8034 -k 'https://localhost:8443/sse?secs=1200&every=0.01'` for 20 min while watching the extension's memory in Activity Monitor (it must stay bounded)."),
    ("soak", "Ten minutes of ordinary Safari and Brave browsing with capture on: nothing new breaks."),
    ("breakpoint", "A breakpoint on localhost holds `/slow?ttfb=1`, and resumes."),
    ("TLS", "swift-nio-ssl 2.37.5 offers the hybrid X25519MLKEM768 key share by default, so every upstream ClientHello is ~1.2 KB larger: browse an HTTPS origin known to sit behind an old middlebox or load balancer (a corporate VPN portal, a bank) with capture on; it must load as it does without ReqRes."),
    ("query", "A GraphQL GET in a browser (e.g. a site whose network tab shows `?query={...}`): it must load, and its row must show the raw query."),
]


def run_rows(ctx, only=None, skip_tags=()):
    results = []
    for row_id, section, title, fn, tags in ROWS:
        if only and row_id not in only:
            continue
        start = time.time()
        if HTTPS in tags and not ctx.https_port:
            status, detail = "SKIP", "no HTTPS fixture: mkcert is not set up (brew install mkcert && mkcert -install)"
        elif NET in tags and ctx.offline:
            status, detail = "SKIP", "--offline"
        elif LONG in tags and ctx.quick:
            status, detail = "SKIP", "--quick"
        elif set(tags) & set(skip_tags):
            status, detail = "SKIP", "not part of this run"
        else:
            try:
                status, detail = fn(ctx)
            except Skip as reason:
                status, detail = "SKIP", str(reason)
            except Exception as error:  # an instrument error is a FAIL with its reason, never a crash
                status, detail = "FAIL", f"{type(error).__name__}: {error}"
        elapsed = time.time() - start
        detail = " ".join(str(detail).split())  # one line per row, in the terminal and the TSV
        results.append((row_id, section, status, elapsed, title, detail))
        print(f"{status:<4}  {elapsed:6.1f}s  {section:<16} {row_id:<20} {title} — {detail}", flush=True)
    return results


# --------------------------------------------------------- results files

def write_results(out_dir, results, ctx, baseline):
    os.makedirs(out_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(out_dir, f"matrix-{stamp}.tsv")
    with open(path, "w") as handle:
        handle.write(f"# ReqRes protocol matrix {stamp}\n")
        handle.write(f"# mode={ctx.mode} proxy={'none (direct)' if ctx.direct else '%s:%d' % PROXY}"
                     f" app={installed_version()} record={'yes' if ctx.recorder else 'no'}\n")
        handle.write("id\tsection\tstatus\telapsed_s\tcheck\tdetail\n")
        for row_id, section, status, elapsed, title, detail in results:
            handle.write(f"{row_id}\t{section}\t{status}\t{elapsed:.1f}\t{title}\t{detail}\n")
    base_path = os.path.join(out_dir, "baseline.tsv")
    if baseline:
        if os.path.exists(base_path):
            print(f"\nbaseline: {base_path} already exists — kept; delete it to record a new one")
        else:
            shutil.copyfile(path, base_path)
            print(f"\nbaseline: saved as {base_path}")
    return path, base_path


def load_baseline(base_path):
    rows = {}
    try:
        for line in open(base_path):
            if line.startswith("#") or line.startswith("id\t"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 3:
                rows[fields[0]] = fields[2]
    except OSError:
        pass
    return rows


def installed_version():
    plist = "/Applications/ReqRes.app/Contents/Info.plist"
    try:
        short = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print CFBundleShortVersionString", plist],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        build = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print CFBundleVersion", plist],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        return f"{short}/{build}" if short else "not installed"
    except Exception:
        return "unknown"


# -------------------------------------------------------------- self-test

def run_selftest(ports, log_path, work):
    """Called by `fixture.py selftest`: the rows DIRECT against a fixture on
    ephemeral ports, then the verdicts against known-bad answers."""
    ctx = Ctx(direct=True, https_port=ports.get("https"), http_port=ports["http"], http80=False,
              log_path=log_path, work=work, long_secs=2, offline=True)
    print("== rows, direct (no proxy) — every non-SKIP row must PASS")
    results = run_rows(ctx)
    failed = [r for r in results if r[2] == "FAIL"]
    passed = [r for r in results if r[2] == "PASS"]

    print("\n== verdicts: known-bad answers must say FAIL, good ones PASS, an unmatched control SKIP")
    controls = [
        ("header leak", verdict_header_leak([["Content-Length", "6"], ["Accept", "*/*"]], ["Content-Length"])),
        ("injected header", verdict_injected([["X-Req-Res-Server", "Enabled"]])),
        ("one Set-Cookie", verdict_set_cookie(["Set-Cookie: a=1", "Content-Type: text/plain"])),
        ("cut stream", verdict_sse("id: 0\ndata: 1\n\n", 45, 30.2)),
        ("cumulative bodies", verdict_recorded_bodies({"a": "u1", "b": "u2"}, {"a": "u1", "b": "u1u2"})),
        ("missing row", verdict_recorded_bodies({"a": "u1"}, {})),
        ("close-delimited", verdict_framing(["HTTP/1.1 200 OK", "Content-Type: text/plain"])),
        ("disabled rule applied", verdict_rule("disabled", "418", "mocked")),
        ("raw query refused", verdict_raw_query("502", [])),
        ("raw query re-encoded", verdict_raw_query("200", ["/health?probe=t&q=%7B%22a%22:1%7D%7Cx%5Ey%60z"])),
    ]
    good = [
        ("clean GET", verdict_header_leak([["Accept", "*/*"]], ["Content-Length"])),
        ("own bodies", verdict_recorded_bodies({"a": "u1", "b": "u2"}, {"a": "{u1}", "b": "{u2}"})),
        ("disabled rule let through", verdict_rule("disabled", "200", "fixture-original")),
        ("enabled rule applied", verdict_rule("enabled", "418", "mocked")),
        ("raw query intact", verdict_raw_query("200", ["/health?probe=t&" + RAW_QUERY])),
    ]
    # A positive control must never PASS on the fixture's own answer: an
    # override that cannot match the host says SKIP, so the disabled check is
    # not trusted on the strength of a rule that never applied.
    must_skip = [
        ("unmatched enabled rule", verdict_rule("enabled", "200", "fixture-original")),
    ]
    if ctx.https_port:
        # Both rule rows for real, with the Host header, against a fixture no
        # rule rewrites: the control must SKIP, the disabled check must PASS.
        # (out_dir stays None, so no marker is read or written.)
        ctx.rule_probe = "enabled"
        must_skip.append(("rule-enabled row, fixture unrewritten", rule_enabled_row(ctx)))
        ctx.rule_probe = "disabled"
        good.append(("rule-disabled row, fixture unrewritten", rule_disabled_row(ctx)))
        ctx.rule_probe = None
    swift_hosts = swift_no_proxy_hosts()
    good.append(("no-proxy-env uses the pane's list",
                 ("PASS", f"both say {NO_PROXY_HOSTS!r}") if swift_hosts == NO_PROXY_HOSTS
                 else ("FAIL", f"matrix.py says {NO_PROXY_HOSTS!r}, CaptureEnvironmentLines.swift says {swift_hosts!r}")))
    bad_controls = [name for name, (status, _) in controls if status != "FAIL"]
    bad_good = [name for name, (status, _) in good if status != "PASS"]
    bad_skip = [name for name, (status, _) in must_skip if status != "SKIP"]
    for name, (status, detail) in controls + good + must_skip:
        print(f"{status:<4}  control: {name} — {detail}")

    https_note = "" if ctx.https_port else " (HTTPS rows skipped: no openssl certificate)"
    print(f"\nselftest: {len(passed)} rows PASS, {len(failed)} FAIL, {len(results) - len(passed) - len(failed)} SKIP{https_note}; "
          f"{len(controls) + len(good) + len(must_skip) - len(bad_controls) - len(bad_good) - len(bad_skip)}"
          f"/{len(controls) + len(good) + len(must_skip)} verdict controls correct")
    # A floor, so a run where everything quietly SKIPs cannot report success.
    ok = not failed and not bad_controls and not bad_good and not bad_skip and len(passed) >= (15 if ctx.https_port else 4)
    print("selftest: " + ("PASS — the instrument works" if ok else "FAIL — fix the instrument before trusting a proxy run"))
    return 0 if ok else 1


# ------------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(description="ReqRes protocol matrix rows (use Scripts/protocol-matrix.sh)")
    parser.add_argument("--https-port", type=int)
    parser.add_argument("--http-port", type=int, required=True)
    parser.add_argument("--http80", action="store_true")
    parser.add_argument("--log", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--long-secs", type=int, default=45)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--rule-probe", choices=["enabled", "disabled"])
    parser.add_argument("--no-record", action="store_true")
    parser.add_argument("--mcp-helper", default=MCP_HELPER)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--only", help="comma-separated row ids")
    args = parser.parse_args()

    recorder, record_note = None, ""
    if args.no_record:
        record_note = "off (--no-record)"
    elif not os.access(args.mcp_helper, os.X_OK):
        record_note = f"off ({args.mcp_helper} not found)"
    else:
        try:
            recorder = Recorder(args.mcp_helper)
            record_note = "on (reading ReqRes's rows through its MCP helper, read-only)"
        except Exception as error:
            record_note = f"off ({error})"
    print(f"record checks: {record_note}\n")

    ctx = Ctx(direct=False, https_port=args.https_port, http_port=args.http_port, http80=args.http80,
              log_path=args.log, work=args.work, long_secs=args.long_secs, quick=args.quick,
              offline=args.offline, rule_probe=args.rule_probe, recorder=recorder)
    ctx.out_dir = args.out
    os.makedirs(args.out, exist_ok=True)
    only = set(args.only.split(",")) if args.only else None
    if only and "proxy-mode" not in only and args.https_port:
        only.add("proxy-mode")  # every row is read in the light of the mode
    results = run_rows(ctx, only=only)
    if recorder:
        recorder.close()

    path, base_path = write_results(args.out, results, ctx, args.baseline)
    baseline = load_baseline(base_path) if not args.baseline else {}
    changed = [(r[0], baseline[r[0]], r[2]) for r in results if r[0] in baseline and baseline[r[0]] != r[2]]
    counts = {s: sum(1 for r in results if r[2] == s) for s in ("PASS", "FAIL", "SKIP")}
    print(f"\n{counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['SKIP']} SKIP — mode: {ctx.mode}, app {installed_version()}")
    if changed:
        print("changed since the baseline:")
        for row_id, before, after in changed:
            print(f"  {row_id}: {before} → {after}")
    elif baseline:
        print("no row changed since the baseline")
    print(f"results: {path}")
    print(f"fixture request log: {args.log}")
    print("\nManual checks (not automatable here):")
    for section, text in MANUAL:
        print(f"  [ ] {section:<10} {text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
