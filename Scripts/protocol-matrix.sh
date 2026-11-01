#!/bin/bash
#
#  protocol-matrix.sh — what ReqRes does to real HTTP(S) traffic, measured.
#  One command, after capture is started:
#
#      Scripts/protocol-matrix.sh --baseline     # the first run: saved as the baseline
#      Scripts/protocol-matrix.sh                # later runs: compared with it
#
#  It starts a local fixture (Scripts/protocol-fixture/fixture.py), sends every
#  probe through the ReqRes proxy at 127.0.0.1:$REQRES_PROXY_PORT (8034 unless
#  Settings ▸ Capture ▸ Proxy port says otherwise — capture_status prints it),
#  prints PASS / FAIL / SKIP
#  with the elapsed time and the topic each row checks, writes a
#  timestamped results file, and ends with the checks only a human can do.
#  A FAIL on a row whose defect is still open is the expected answer until
#  that fix ships — the baseline is the "before" picture.
#
#  Options:
#    --baseline        save this run as the baseline (kept if one already exists)
#    --quick           skip the rows that take 45-90 s each (the long streams)
#    --offline         skip the rows that need httpbin.org, echo.websocket.org, neverssl.com, google.com
#    --long-secs N     length of the "longer than 30 s" rows (default 45)
#    --only a,b        run only these row ids
#    --rule-probe P    the two-run rule check, P = enabled (the control, rule ON) then
#                      disabled (rule switched OFF) — see the checklist for the setup
#    --no-record       do not read ReqRes's recorded rows through its MCP helper
#    --http80          also serve plain HTTP on 127.0.0.1:80, if macOS lets this user bind it
#    --https-port N    fixture HTTPS port (default 8443)
#    --http-port N     fixture plain-HTTP port (default 3000, a common local-backend port)
#    --out DIR         results directory (default ~/ReqRes-protocol-matrix, or $REQRES_MATRIX_OUT)
#    --selftest        check the instrument itself, WITHOUT the proxy, and exit
#
#  It refuses to run unless the ACTIVATED extension is the one inside
#  /Applications/ReqRes.app (Scripts/extension-version-check.sh --running);
#  REQRES_MATRIX_ANY_ENGINE=1 measures whatever is running instead.
#
#  Before the first run (once — none of this is done by the script):
#    brew install mkcert && mkcert -install
#      mkcert -install trusts mkcert's CA in the System keychain, which is what
#      lets ReqRes's root extension verify the fixture's certificate on the
#      intercepted path. Without mkcert every HTTPS row SKIPs.
#    Start capture from the ReqRes window (or MCP start_capture) — never with
#      `scutil --nc start`, which starts the tunnel with the CA flag off and sends
#      every HTTPS connection down passthrough.
#
#  It never changes system state: no keychain writes, no proxy settings, no
#  ReqRes rules or settings. It reads the keychain once (is mkcert's CA in the
#  System keychain?) and reads ReqRes's rows through its MCP helper, read-only.
#  The only process it signals is the fixture it started.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$HERE/protocol-fixture"
PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3)"

HTTPS_PORT=8443
HTTP_PORT=3000
HTTP80=""
OUT="${REQRES_MATRIX_OUT:-}"
PASSTHROUGH_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest)
      exec "$PY" "$FIXTURE_DIR/fixture.py" selftest ;;
    --baseline|--quick|--offline|--no-record)
      PASSTHROUGH_ARGS+=("$1"); shift ;;
    --long-secs|--only|--rule-probe)
      [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      PASSTHROUGH_ARGS+=("$1" "$2"); shift 2 ;;
    --http80) HTTP80="--http80"; shift ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed -e 's/^# \{0,2\}//' -e '/^set -u/d'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ -z "$OUT" ]; then
  OUT="$HOME/ReqRes-protocol-matrix"
fi

# A terminal set up from Settings ▸ Capture carries HTTP(S)_PROXY and NO_PROXY.
# NO_PROXY=localhost would send every fixture probe AROUND ReqRes even with
# curl's -x, so the probes run with none of them.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
export PYTHONDONTWRITEBYTECODE=1  # no __pycache__ in Scripts/protocol-fixture

command -v curl >/dev/null || { echo "curl not found" >&2; exit 2; }

port_open() { "$PY" -c "import socket,sys; socket.create_connection(('$1', int('$2')), timeout=2).close()" 2>/dev/null; }

echo "ReqRes protocol matrix — $(date '+%Y-%m-%d %H:%M:%S')"

# The engine being measured must be the one installed: macOS keeps an older
# system extension when the new bundle's version is not higher, and then every
# row describes the previous engine. REQRES_MATRIX_ANY_ENGINE=1 skips this
# (measuring an older build on purpose).
if [ "${REQRES_MATRIX_ANY_ENGINE:-}" != "1" ]; then
  "$HERE/extension-version-check.sh" --running || exit 1
fi
PROXY_PORT="${REQRES_PROXY_PORT:-8034}"
export REQRES_PROXY_PORT="$PROXY_PORT"
if ! port_open 127.0.0.1 "$PROXY_PORT"; then
  cat <<EOF

ReqRes is NOT listening on 127.0.0.1:$PROXY_PORT, so there is nothing to measure.
  - Changed the port in Settings ▸ Capture? Run with REQRES_PROXY_PORT=<port>.
  - Start capture from the ReqRes window (or MCP start_capture). Not with
    \`scutil --nc start\`: that starts the tunnel with the CA flag off.
  - If capture says it is on and this still fails, the proxy never bound its
    port: Capture ▸ Diagnose Setup… says why.
  - To check the instrument itself without ReqRes: $0 --selftest
EOF
  exit 3
fi
echo "proxy: 127.0.0.1:$PROXY_PORT is listening"

for port in "$HTTPS_PORT" "$HTTP_PORT"; do
  if port_open 127.0.0.1 "$port"; then
    owner="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '2p' | awk '{print $1" (pid "$2")"}')"
    echo "port $port is already in use by ${owner:-another process}; pick another with --https-port / --http-port" >&2
    exit 2
  fi
done

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$OUT/run-$STAMP"
mkdir -p "$WORK" || exit 2
LOG="$WORK/requests.jsonl"

CERT_ARGS=()
CAROOT=""
if command -v mkcert >/dev/null; then CAROOT="$(mkcert -CAROOT 2>/dev/null)"; fi
if [ -n "$CAROOT" ] && [ -f "$CAROOT/rootCA.pem" ]; then
  # Makes a leaf in the run directory; does NOT install anything.
  if mkcert -cert-file "$WORK/fixture.pem" -key-file "$WORK/fixture-key.pem" localhost 127.0.0.1 ::1 >"$WORK/mkcert.out" 2>&1; then
    CERT_ARGS=(--cert "$WORK/fixture.pem" --key "$WORK/fixture-key.pem")
    echo "https fixture: mkcert certificate for localhost, 127.0.0.1, ::1"
    # Read-only: is mkcert's CA where the ROOT extension looks? (`mkcert
    # -install` puts it in the System keychain on macOS.)
    system_ca="$(security find-certificate -a -c "mkcert" /Library/Keychains/System.keychain 2>/dev/null)"
    if [ -z "$system_ca" ]; then
      echo "warning: no mkcert CA in the System keychain — on the intercepted path ReqRes's root extension will"
      echo "         refuse the fixture's certificate (run \`mkcert -install\` once). The upstream-trust row reports it."
    fi
  else
    echo "https fixture: mkcert failed (see $WORK/mkcert.out) — HTTPS rows will SKIP"
  fi
else
  echo "https fixture: SKIP — mkcert is not set up (brew install mkcert && mkcert -install); every HTTPS row will SKIP"
fi

"$PY" "$FIXTURE_DIR/fixture.py" serve --log "$LOG" --https-port "$HTTPS_PORT" --http-port "$HTTP_PORT" \
  ${CERT_ARGS[@]+"${CERT_ARGS[@]}"} $HTTP80 >"$WORK/fixture.out" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null' EXIT
trap 'kill "$FIXTURE_PID" 2>/dev/null; exit 130' INT TERM

ready=""
for _ in $(seq 1 50); do
  ready="$(sed -n '/fixture: ready/p' "$WORK/fixture.out")"
  [ -n "$ready" ] && break
  if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ -z "$ready" ]; then
  echo "the fixture did not start:" >&2
  cat "$WORK/fixture.out" >&2
  exit 2
fi
sed -n '/not bound/p' "$WORK/fixture.out"
echo "$ready"
echo

MATRIX_ARGS=(--http-port "$HTTP_PORT" --log "$LOG" --work "$WORK" --out "$OUT")
[ ${#CERT_ARGS[@]} -gt 0 ] && MATRIX_ARGS+=(--https-port "$HTTPS_PORT")
case "$ready" in *http80=*) MATRIX_ARGS+=(--http80) ;; esac

"$PY" "$FIXTURE_DIR/matrix.py" "${MATRIX_ARGS[@]}" ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
status=$?
echo
echo "run directory: $WORK"
exit $status
