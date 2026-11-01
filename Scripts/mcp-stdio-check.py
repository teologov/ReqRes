#!/usr/bin/env python3
#
#  mcp-stdio-check.py — drive the reqres-mcp stdio server over JSON-RPC against
#  a running DEBUG build: initialize, tools/list, then list_hosts, test_pattern,
#  add_host (approved through the sheet), list_rules, create_rule (expects the
#  hostId validation error), remove_host. Prints one line per step.
#
#  Usage:  Scripts/mcp-stdio-check.py <ReqRes.app> <reqres-mcp binary> <pid-file>
#  The helper must be signed with the sandbox + app-group entitlements (the
#  bundled one at <ReqRes.app>/Contents/MacOS/reqres-mcp is); run from a shell
#  that may spawn it. The app it launches is its own (pid written to <pid-file>).
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
import json, os, subprocess, sys, time
app = subprocess.Popen([sys.argv[1] + "/Contents/MacOS/ReqRes"], env={**os.environ, "REQRES_MCP_BRIDGE": "1", "REQRES_MCP_AUTO_CONSENT": "allow"}, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
for _ in range(40):
    line = app.stdout.readline()
    if "bridge port=" in line: break
    time.sleep(0.25)
time.sleep(2)  # let bootstrap load hosts
open(sys.argv[3], "w").write(str(app.pid))
mcp = subprocess.Popen([sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def call(msg):
    mcp.stdin.write(json.dumps(msg) + "\n"); mcp.stdin.flush()
    while True:
        line = mcp.stdout.readline()
        if not line: return None
        try: return json.loads(line)
        except json.JSONDecodeError: continue
r = call({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}})
print("initialize ->", r["result"]["serverInfo"] if r and "result" in r else r)
mcp.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"}) + "\n"); mcp.stdin.flush()
r = call({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
tools = [t["name"] for t in r["result"]["tools"]] if r and "result" in r else r
print("tools/list ->", len(tools) if isinstance(tools, list) else tools, tools)
for name, args in [("list_hosts", {}), ("test_pattern", {"pattern": "/users?*", "url": "https://a.com/users?id=1"}),
                   ("add_host", {"host": "stdio-test.example.com"}), ("list_rules", {}), ("create_rule", {"mode": "override", "path": "/x"})]:
    r = call({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":name,"arguments":args}})
    res = r.get("result", r) if r else r
    text = res["content"][0]["text"] if isinstance(res, dict) and "content" in res else res
    print(f"{name} -> isError={res.get('isError') if isinstance(res, dict) else '?'}: {str(text)[:160]}")
    if name == "add_host":
        import re
        m = re.search(r"#(\d+)", str(text)); host_id = m.group(1) if m else None
host_id = host_id if "host_id" in dir() else None
if host_id:
    r = call({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"remove_host","arguments":{"id": int(host_id)}}})
    print("remove_host ->", r["result"]["content"][0]["text"] if r and "result" in r else r)
mcp.stdin.close()
try: mcp.wait(timeout=8)
except Exception: print("reqres-mcp did not exit on stdin EOF within 8s"); mcp.kill()
app.terminate()
