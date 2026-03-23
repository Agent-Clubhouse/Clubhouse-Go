#!/bin/bash
# Debug script to test the Annex permission-response endpoint
# Usage: ./debug_permission.sh <host> <port> <token> <agent_id> <request_id>
#
# To get these values:
# 1. host/port: from mDNS discovery or server logs
# 2. token: pair first with: curl -s -X POST http://host:port/pair -H 'Content-Type: application/json' -d '{"pin":"123456"}'
# 3. agent_id/request_id: from the permission:request WebSocket event (visible in Xcode console logs)

set -e

HOST="${1:?Usage: $0 <host> <port> <token> <agent_id> <request_id>}"
PORT="${2:?}"
TOKEN="${3:?}"
AGENT_ID="${4:?}"
REQUEST_ID="${5:?}"

BASE="http://${HOST}:${PORT}"

echo "=== Annex Permission Debug ==="
echo "Server: ${BASE}"
echo "Agent:  ${AGENT_ID}"
echo "ReqID:  ${REQUEST_ID}"
echo ""

# 1. Check server status
echo "--- GET /api/v1/status ---"
curl -s -w "\nHTTP Status: %{http_code}\n" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/api/v1/status" | python3 -m json.tool 2>/dev/null || true
echo ""

# 2. Check agent exists and get its execution mode
echo "--- Looking up agent across projects ---"
PROJECTS=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/api/v1/projects")
echo "Projects: ${PROJECTS}" | python3 -m json.tool 2>/dev/null || echo "${PROJECTS}"
echo ""

# Try each project to find the agent
for PROJ_ID in $(echo "${PROJECTS}" | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null); do
  echo "--- GET /api/v1/projects/${PROJ_ID}/agents ---"
  AGENTS=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/api/v1/projects/${PROJ_ID}/agents")
  # Check if our agent is in this project
  FOUND=$(echo "${AGENTS}" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
for a in agents:
    if a['id'] == '${AGENT_ID}':
        print(json.dumps(a, indent=2))
        break
" 2>/dev/null)
  if [ -n "${FOUND}" ]; then
    echo "Found agent:"
    echo "${FOUND}"
    EXEC_MODE=$(echo "${FOUND}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('executionMode', 'null'))" 2>/dev/null)
    echo ""
    echo "executionMode: ${EXEC_MODE}"
    break
  fi
done
echo ""

# 3. Send permission response (hook-based endpoint)
BODY='{"requestId":"'"${REQUEST_ID}"'","decision":"allow"}'
echo "--- POST /api/v1/agents/${AGENT_ID}/permission-response ---"
echo "Request body: ${BODY}"
echo ""
echo "Response:"
curl -s -v -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${BODY}" \
  "${BASE}/api/v1/agents/${AGENT_ID}/permission-response" 2>&1
echo ""
echo ""

# 4. Also try structured endpoint for comparison
STRUCT_BODY='{"requestId":"'"${REQUEST_ID}"'","approved":true}'
echo "--- POST /api/v1/agents/${AGENT_ID}/structured-permission ---"
echo "Request body: ${STRUCT_BODY}"
echo ""
echo "Response:"
curl -s -v -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${STRUCT_BODY}" \
  "${BASE}/api/v1/agents/${AGENT_ID}/structured-permission" 2>&1
echo ""
