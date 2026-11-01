#!/bin/bash
#
#  mcp-e2e.sh — drive the MCP bridge's write surface against a DEBUG build of
#  ReqRes, headlessly: launch the app with the bridge forced on and the
#  approval sheet auto-answered, hit every route with curl, clean up.
#
#  Usage:  Scripts/mcp-e2e.sh <output-dir> allow|deny
#    allow — the sheet is auto-approved: creates a host filter and rules, patches,
#            deletes them again (nothing is left in the store)
#    deny  — the sheet is auto-denied: every write must answer 403 consent_denied
#
#  Needs: a Debug build in DerivedData (REQRES_MCP_BRIDGE / REQRES_MCP_AUTO_CONSENT
#  are DEBUG-only hooks), curl, python3. Never run it against a Release build.
#  The app instance it launches is its own (pid in <output-dir>/mcp-pid) — it never
#  signals any other ReqRes process.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/ReqRes-*/Build/Products/Debug/ReqRes.app | head -1)
OUT="$1"; MODE="$2"   # MODE: allow | deny
[ -n "$OUT" ] && [ -n "$MODE" ] || { echo "usage: $0 <output-dir> allow|deny" >&2; exit 2; }
mkdir -p "$OUT"
( REQRES_MCP_BRIDGE=1 REQRES_MCP_AUTO_CONSENT=$MODE MCPAgentWritesWithoutAsking=0 "$APP/Contents/MacOS/ReqRes" > "$OUT/mcp-app-$MODE.out" 2>/dev/null & echo $! > "$OUT/mcp-pid" )
for i in $(seq 1 20); do sleep 1; grep -q "bridge port=" "$OUT/mcp-app-$MODE.out" && break; done
LINE=$(grep "bridge port=" "$OUT/mcp-app-$MODE.out" | head -1)
PORT=$(echo "$LINE" | sed 's/.*port=\([0-9]*\).*/\1/'); TOKEN=$(echo "$LINE" | sed 's/.*token=//')
echo "bridge: port=$PORT token=${TOKEN:0:6}…"
B="http://127.0.0.1:$PORT"; H="Authorization: Bearer $TOKEN"
req() { # method path [json]
  local m=$1 p=$2 d=$3 code
  if [ -n "$d" ]; then code=$(curl -s --max-time 20 -o "$OUT/body" -w "%{http_code}" -X "$m" -H "$H" -H "Content-Type: application/json" --data "$d" "$B$p"); else code=$(curl -s --max-time 20 -o "$OUT/body" -w "%{http_code}" -X "$m" -H "$H" "$B$p"); fi
  echo "  $m $p -> $code  $(head -c 700 "$OUT/body")"
}
echo "== $MODE mode"
# leftovers from an earlier run
for id in $(curl -s --max-time 20 -H "$H" "$B/v1/hosts" | python3 -c "import json,sys; print(' '.join(str(h['id']) for h in json.load(sys.stdin)['hosts'] if h['host']=='mcp-test.example.com'))"); do req DELETE "/v1/hosts/$id"; done
req GET /v1/health
req GET /v1/hosts
req GET /v1/rules
req POST /v1/hosts '{"host":"mcp-test.example.com","scheme":"https"}'
HOST_ID=$(python3 -c "import json,sys; d=json.load(open('$OUT/body')); print(d.get('id',''))" 2>/dev/null)
req POST /v1/rules "{\"mode\":\"override\",\"path\":\"users?*\",\"hostId\":${HOST_ID:-0},\"responseStatus\":503,\"responseHeaders\":{\"X-Mock\":\"1\"},\"responseBody\":\"{\\\"error\\\":\\\"mocked\\\"}\"}"
RULE_ID=$(python3 -c "import json,sys; d=json.load(open('$OUT/body')); print(d.get('id',''))" 2>/dev/null)
req GET "/v1/rules?host_id=${HOST_ID:-0}"
req PATCH "/v1/rules/${RULE_ID:-0}" '{"enabled":false,"responseStatus":404}'
[ -n "$RULE_ID" ] && req DELETE "/v1/rules/$RULE_ID" && RULE_ID=""
req POST /v1/rules "{\"hostId\":${HOST_ID:-0},\"mode\":\"map_local\",\"path\":\"/fixture\",\"localFile\":{\"content\":\"{\\\"fixture\\\":true}\"}}"
FIX_ID=$(python3 -c "import json,sys; d=json.load(open('$OUT/body')); print(d.get('id',''))" 2>/dev/null); FIX_PATH=$(python3 -c "import json; print(json.load(open('$OUT/body')).get('localFilePath',''))" 2>/dev/null); echo "  fixture rule id=$FIX_ID path=$FIX_PATH"
[ -n "$FIX_PATH" ] && echo "  fixture file: $(cat "$FIX_PATH" 2>/dev/null || echo '(unreadable from the shell — expected, it is in the app container)')"
[ -n "$FIX_ID" ] && req DELETE "/v1/rules/$FIX_ID" && FIX_ID=""
req POST /v1/patterns/test '{"pattern":"/users?*","url":"https://mcp-test.example.com/users?id=1"}'
req POST /v1/rules/from-session '{"uid":"00000000-0000-0000-0000-000000000000"}'
SESSION_UID=$(curl -s --max-time 20 -H "$H" "$B/v1/sessions?limit=1" | python3 -c "import json,sys; s=json.load(sys.stdin)['sessions']; print(s[0]['uid'] if s else '')")
echo "  (first session uid=$SESSION_UID)"
req POST /v1/rules/from-session "{\"uid\":\"$SESSION_UID\",\"responseStatus\":500,\"responseBody\":\"{\\\"error\\\":\\\"mocked\\\"}\"}"
MOCK_ID=$(python3 -c "import json; d=json.load(open('$OUT/body')); print(d.get('id',''))" 2>/dev/null); MOCK_HOST=$(python3 -c "import json; d=json.load(open('$OUT/body')); print(d.get('hostId',''))" 2>/dev/null)
req POST /v1/capture '{"action":"stop"}'
req POST /v1/sessions/clear
req PUT /v1/rules/1
req POST /v1/nope
echo "== cleanup"
[ -n "$FIX_ID" ] && req DELETE "/v1/rules/$FIX_ID"
[ -n "$RULE_ID" ] && req DELETE "/v1/rules/$RULE_ID"
[ -n "$HOST_ID" ] && req DELETE "/v1/hosts/$HOST_ID"
[ -n "$MOCK_ID" ] && req DELETE "/v1/rules/$MOCK_ID"
[ -n "$MOCK_HOST" ] && [ "$MOCK_HOST" != "$HOST_ID" ] && req DELETE "/v1/hosts/$MOCK_HOST"
req GET /v1/rules
req GET /v1/hosts
echo "== app log lines"; grep "^\[mcp\]" "$OUT/mcp-app-$MODE.out" | head -8
kill $(cat "$OUT/mcp-pid") 2>/dev/null
