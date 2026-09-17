#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

GRAYLOG_URL="${GRAYLOG_URL:-http://localhost:9000}"
GRAYLOG_USER="${GRAYLOG_USER:-admin}"

echo "======================================"
echo " Graylog MikroTik Configuration Setup"
echo "======================================"

if [ -z "${GRAYLOG_PASSWORD:-}" ]; then
    read -rsp "Graylog admin password: " GRAYLOG_PASSWORD
    echo
fi

api() {
    curl -fsS \
      -u "${GRAYLOG_USER}:${GRAYLOG_PASSWORD}" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -H 'X-Requested-By: deployment-script' \
      "$@"
}

echo "Waiting for Graylog API..."

until api "${GRAYLOG_URL}/api/" >/dev/null 2>&1; do
    sleep 5
done

echo "Graylog API ready."

# --------------------------------------------------
# 1. Syslog UDP Input
# --------------------------------------------------

echo
echo "[1/5] Checking MikroTik Syslog input..."

INPUTS="$(api "${GRAYLOG_URL}/api/system/inputs")"

INPUT_ID="$(
python3 -c '
import json,sys
d=json.load(sys.stdin)
for x in d.get("inputs", []):
    if x.get("title") == "MikroTik-Syslog":
        print(x.get("id",""))
        break
' <<< "$INPUTS"
)"

if [ -z "$INPUT_ID" ]; then
    echo "Creating MikroTik-Syslog input..."

    cat > /tmp/mikrotik-input.json <<'JSON'
{
  "title": "MikroTik-Syslog",
  "type": "org.graylog2.inputs.syslog.udp.SyslogUDPInput",
  "global": true,
  "configuration": {
    "bind_address": "0.0.0.0",
    "port": 514,
    "recv_buffer_size": 262144,
    "number_worker_threads": 2,
    "timezone": "NotSet",
    "override_source": null,
    "charset_name": "UTF-8",
    "force_rdns": false,
    "allow_override_date": true,
    "expand_structured_data": false,
    "store_full_message": false
  }
}
JSON

    INPUT_RESULT="$(
        api -X POST \
          --data-binary @/tmp/mikrotik-input.json \
          "${GRAYLOG_URL}/api/system/inputs"
    )"

    echo "Input created."
else
    echo "Input already exists: $INPUT_ID"
fi

# --------------------------------------------------
# 2. Stream
# --------------------------------------------------

echo
echo "[2/5] Checking MikroTik Logs stream..."

STREAMS="$(api "${GRAYLOG_URL}/api/streams")"

STREAM_ID="$(
python3 -c '
import json,sys
d=json.load(sys.stdin)
streams=d.get("streams", d if isinstance(d,list) else [])
for x in streams:
    if x.get("title") == "MikroTik Logs":
        print(x.get("id",""))
        break
' <<< "$STREAMS"
)"

if [ -z "$STREAM_ID" ]; then
    echo "Creating MikroTik Logs stream..."

    # Use the default index set from the existing Default Stream.
    INDEX_SET_ID="$(
    python3 -c '
import json,sys
d=json.load(sys.stdin)
streams=d.get("streams", d if isinstance(d,list) else [])
for x in streams:
    if x.get("is_default") is True or x.get("title") == "Default Stream":
        print(x.get("index_set_id",""))
        break
' <<< "$STREAMS"
    )"

    if [ -z "$INDEX_SET_ID" ]; then
        echo "ERROR: Could not determine default index set."
        exit 1
    fi

    cat > /tmp/mikrotik-stream-create.json <<JSON
{
  "title": "MikroTik Logs",
  "description": "Centralized MikroTik firewall, VPN and audit logs",
  "matching_type": "AND",
  "remove_matches_from_default_stream": false,
  "index_set_id": "${INDEX_SET_ID}",
  "rules": []
}
JSON

    STREAM_RESULT="$(
        api -X POST \
          --data-binary @/tmp/mikrotik-stream-create.json \
          "${GRAYLOG_URL}/api/streams"
    )"

    STREAM_ID="$(
        python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("stream_id") or d.get("id") or "")
' <<< "$STREAM_RESULT"
    )"

    echo "Stream created: $STREAM_ID"
else
    echo "Stream already exists: $STREAM_ID"
fi

# --------------------------------------------------
# 3. Pipeline Rules
# --------------------------------------------------

echo
echo "[3/5] Importing V15 pipeline rules..."

python3 - "$GRAYLOG_URL" "$GRAYLOG_USER" "$GRAYLOG_PASSWORD" <<'PY'
import json
import sys
import urllib.request
import base64

base, user, password = sys.argv[1:4]

with open("graylog/pipeline-rules.json") as f:
    all_rules = json.load(f)

with open("graylog/pipeline.json") as f:
    pipeline = json.load(f)

# Only import rules actually referenced by stable V15.
source = pipeline["source"]

active_rules = [
    r for r in all_rules
    if f'rule "{r["title"]}"' in source
]

auth = base64.b64encode(
    f"{user}:{password}".encode()
).decode()

def request(method, path, payload=None):
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()

    req = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Basic " + auth,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Requested-By": "deployment-script"
        }
    )

    with urllib.request.urlopen(req) as r:
        body = r.read().decode()
        return json.loads(body) if body else {}

existing = request("GET", "/api/system/pipelines/rule")

existing_by_title = {
    r["title"]: r
    for r in existing
}

for rule in active_rules:
    payload = {
        "title": rule["title"],
        "description": rule.get("description", ""),
        "source": rule["source"]
    }

    current = existing_by_title.get(rule["title"])

    if current:
        rid = current["id"]
        request(
            "PUT",
            f"/api/system/pipelines/rule/{rid}",
            payload
        )
        print("Updated rule:", rule["title"])
    else:
        request(
            "POST",
            "/api/system/pipelines/rule",
            payload
        )
        print("Created rule:", rule["title"])
PY

# --------------------------------------------------
# 4. Pipeline
# --------------------------------------------------

echo
echo "[4/5] Creating/updating MikroTik pipeline..."

PIPELINES="$(api "${GRAYLOG_URL}/api/system/pipelines/pipeline")"

PIPELINE_ID="$(
python3 -c '
import json,sys
d=json.load(sys.stdin)
for x in d:
    if x.get("title") == "MikroTik Log Processing":
        print(x.get("id",""))
        break
' <<< "$PIPELINES"
)"

PIPELINE_PAYLOAD="$(
python3 - <<'PY'
import json

with open("graylog/pipeline.json") as f:
    d=json.load(f)

print(json.dumps({
    "title": d["title"],
    "description": d["description"],
    "source": d["source"]
}))
PY
)"

if [ -z "$PIPELINE_ID" ]; then
    RESULT="$(
        api -X POST \
          --data "$PIPELINE_PAYLOAD" \
          "${GRAYLOG_URL}/api/system/pipelines/pipeline"
    )"

    PIPELINE_ID="$(
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' \
      <<< "$RESULT"
    )"

    echo "Pipeline created: $PIPELINE_ID"
else
    api -X PUT \
      --data "$PIPELINE_PAYLOAD" \
      "${GRAYLOG_URL}/api/system/pipelines/pipeline/${PIPELINE_ID}" \
      >/dev/null

    echo "Pipeline updated: $PIPELINE_ID"
fi

# --------------------------------------------------
# 5. Connect Pipeline -> Stream
# --------------------------------------------------

echo
echo "[5/5] Connecting pipeline to stream..."

cat > /tmp/mikrotik-pipeline-connection.json <<JSON
{
  "stream_id": "${STREAM_ID}",
  "pipeline_ids": [
    "${PIPELINE_ID}"
  ]
}
JSON

api -X POST \
  --data-binary @/tmp/mikrotik-pipeline-connection.json \
  "${GRAYLOG_URL}/api/system/pipelines/connections/to_stream" \
  >/dev/null

echo
echo "======================================"
echo " Graylog MikroTik setup complete"
echo "======================================"
echo
echo "Input    : MikroTik-Syslog UDP/514"
echo "Stream   : MikroTik Logs"
echo "Pipeline : MikroTik Log Processing"
echo
echo "Open Graylog:"
echo "  http://SERVER_IP:9000"
echo

unset GRAYLOG_PASSWORD
