#!/usr/bin/env python3
"""
Annex WebSocket Monitor — connects, pairs, and logs all events.
When a permission:request arrives, automatically sends an allow response
and logs the full HTTP exchange.

Usage:
  python3 debug_ws_monitor.py <host> <port> <pin>

Example:
  python3 debug_ws_monitor.py 192.168.1.100 52431 123456
"""

import asyncio
import json
import sys
import time
import urllib.request
import urllib.error

try:
    import websockets
except ImportError:
    print("Installing websockets...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "websockets", "-q"])
    import websockets


def http_request(url, method="GET", body=None, token=None):
    """Make an HTTP request and return (status, headers, body_text)."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as resp:
            body_text = resp.read().decode()
            return resp.status, dict(resp.headers), body_text
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        return e.code, dict(e.headers), body_text


def pair(host, port, pin):
    """Pair with server and return token."""
    url = f"http://{host}:{port}/pair"
    print(f"\n{'='*60}")
    print(f"POST {url}")
    print(f"Body: {json.dumps({'pin': pin})}")
    status, headers, body = http_request(url, "POST", {"pin": pin})
    print(f"Status: {status}")
    print(f"Response: {body}")
    if status == 200:
        return json.loads(body)["token"]
    else:
        print(f"Pairing failed!")
        sys.exit(1)


def send_permission_response(host, port, token, agent_id, request_id, decision="allow"):
    """Send permission response and log full exchange."""
    url = f"http://{host}:{port}/api/v1/agents/{agent_id}/permission-response"
    body = {"requestId": request_id, "decision": decision}

    print(f"\n{'='*60}")
    print(f"POST {url}")
    print(f"Headers: Authorization: Bearer {token[:8]}...")
    print(f"Body: {json.dumps(body, indent=2)}")
    print(f"{'='*60}")

    status, headers, resp_body = http_request(url, "POST", body, token)

    print(f"\nResponse Status: {status}")
    print(f"Response Headers:")
    for k, v in headers.items():
        print(f"  {k}: {v}")
    print(f"Response Body: {resp_body}")

    try:
        parsed = json.loads(resp_body)
        print(f"\nParsed Response:")
        print(json.dumps(parsed, indent=2))
        print(f"\nFields present: {list(parsed.keys())}")
        print(f"  'ok' present:        {'ok' in parsed}")
        print(f"  'delivered' present:  {'delivered' in parsed}")
        print(f"  'requestId' present:  {'requestId' in parsed}")
        print(f"  'decision' present:   {'decision' in parsed}")
    except json.JSONDecodeError:
        print(f"(not valid JSON)")

    return status, resp_body


async def monitor(host, port, token):
    """Connect WebSocket and monitor all events."""
    ws_url = f"ws://{host}:{port}/ws?token={token}"
    print(f"\nConnecting WebSocket: {ws_url}")

    async with websockets.connect(ws_url) as ws:
        print("WebSocket connected! Monitoring events...\n")

        async for message in ws:
            try:
                data = json.loads(message)
                msg_type = data.get("type", "unknown")
                seq = data.get("seq")
                ts = time.strftime("%H:%M:%S")

                if msg_type == "snapshot":
                    payload = data.get("payload", {})
                    projects = payload.get("projects", [])
                    agents = payload.get("agents", {})
                    pending = payload.get("pendingPermissions", [])
                    last_seq = payload.get("lastSeq")
                    print(f"[{ts}] snapshot: {len(projects)} projects, "
                          f"{sum(len(v) for v in agents.values())} agents, "
                          f"{len(pending)} pending permissions, lastSeq={last_seq}")
                    for p in pending:
                        print(f"  ⚠️  Pending: agent={p.get('agentId')} "
                              f"tool={p.get('toolName')} "
                              f"requestId={p.get('requestId')}")
                    # Print agent execution modes
                    for proj_id, agent_list in agents.items():
                        for a in agent_list:
                            print(f"  Agent: {a.get('name', a.get('id'))} "
                                  f"status={a.get('status')} "
                                  f"executionMode={a.get('executionMode')}")

                elif msg_type == "permission:request":
                    payload = data.get("payload", {})
                    agent_id = payload.get("agentId")
                    request_id = payload.get("requestId")
                    tool_name = payload.get("toolName")
                    timeout = payload.get("timeout")
                    deadline = payload.get("deadline")
                    print(f"\n[{ts}] 🔒 PERMISSION REQUEST seq={seq}")
                    print(f"  agentId:   {agent_id}")
                    print(f"  requestId: {request_id}")
                    print(f"  toolName:  {tool_name}")
                    print(f"  toolInput: {json.dumps(payload.get('toolInput'))}")
                    print(f"  message:   {payload.get('message')}")
                    print(f"  timeout:   {timeout}")
                    print(f"  deadline:  {deadline}")

                    # Auto-approve and log the exchange
                    print(f"\n  >>> Auto-sending ALLOW response...")
                    send_permission_response(host, port, token, agent_id, request_id, "allow")

                elif msg_type == "permission:response":
                    payload = data.get("payload", {})
                    print(f"[{ts}] ✅ PERMISSION RESPONSE seq={seq}")
                    print(f"  {json.dumps(payload, indent=2)}")

                elif msg_type == "hook:event":
                    payload = data.get("payload", {})
                    event = payload.get("event", {})
                    print(f"[{ts}] hook:{event.get('kind')} seq={seq} "
                          f"agent={payload.get('agentId')} "
                          f"tool={event.get('toolName')} "
                          f"verb={event.get('toolVerb')}")

                elif msg_type == "pty:data":
                    payload = data.get("payload", {})
                    preview = payload.get("data", "")[:80].replace("\n", "\\n")
                    print(f"[{ts}] pty:data seq={seq} agent={payload.get('agentId')} [{len(payload.get('data',''))} chars]: {preview}")

                elif msg_type == "structured:event":
                    payload = data.get("payload", {})
                    event = payload.get("event", {})
                    print(f"[{ts}] structured:{event.get('type')} seq={seq} "
                          f"agent={payload.get('agentId')} "
                          f"data={json.dumps(event.get('data'))[:100]}")

                else:
                    print(f"[{ts}] {msg_type} seq={seq} payload_keys={list(data.get('payload', {}).keys()) if isinstance(data.get('payload'), dict) else '...'}")

            except json.JSONDecodeError:
                print(f"[raw] {message[:200]}")


async def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)

    host, port, pin = sys.argv[1], sys.argv[2], sys.argv[3]

    token = pair(host, port, pin)
    print(f"\n✅ Paired! Token: {token[:8]}...")

    # Check status
    url = f"http://{host}:{port}/api/v1/status"
    status, _, body = http_request(url, "GET", token=token)
    print(f"Server status: {body}")

    await monitor(host, port, token)


if __name__ == "__main__":
    asyncio.run(main())
