#!/usr/bin/env bash
#
# sync-models.sh — Regenerate the aichat model registry from the LIVE server.
#
# The local model server (mlx_lm.server on :8081) is the source of truth for
# which models exist. This script reads /v1/models and rewrites the `models:`
# list under the `mlx` client in aichat-config/config.yaml so aichat can route
# to whatever is currently cached/served. Run it whenever the served set changes.
#
# Usage: sync-models.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/aichat-config/config.yaml"
SERVER="http://localhost:8081"
MAX_OUTPUT_TOKENS=8192

for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' not found in PATH" >&2; exit 4; }
done

if ! curl -fsS -m 3 -o /dev/null "$SERVER/v1/models" 2>/dev/null; then
  echo "error: local LLM server not reachable at $SERVER (start it, then retry)" >&2
  exit 3
fi

# The server's launch --model is the primary/default; fall back to "" (python
# then keeps whatever default is already in the config). Prefix with mlx:.
DEFAULT_MODEL=$(ps aux | grep -E '[m]lx_lm\.server|[l]lama-server' | grep -- '--model' \
  | sed 's/.*--model //' | awk '{print $1}' | head -1)
[[ -n "$DEFAULT_MODEL" && "$DEFAULT_MODEL" != mlx:* ]] && DEFAULT_MODEL="mlx:$DEFAULT_MODEL"

# Fetch live model ids, then rewrite the `models:` block (assumed to be the last
# block in the file) in place, and refresh the top-level `model:` default —
# preserving the header, other settings, and client config.
python3 - "$CONFIG" "$MAX_OUTPUT_TOKENS" "$SERVER/v1/models" "$DEFAULT_MODEL" <<'PY'
import json, sys, pathlib, urllib.request

config_path = pathlib.Path(sys.argv[1])
max_tokens = sys.argv[2]
default_model = sys.argv[4]
with urllib.request.urlopen(sys.argv[3], timeout=5) as r:
    ids = sorted(m["id"] for m in json.load(r)["data"])
if not ids:
    sys.exit("error: server returned no models")

lines = config_path.read_text().splitlines()
try:
    idx = next(i for i, l in enumerate(lines) if l.rstrip() == "  models:")
except StopIteration:
    sys.exit("error: could not find '  models:' block in " + str(config_path))

head = lines[: idx + 1]
# Refresh the top-level default `model:` to the server's primary, if known.
if default_model:
    head = [f"model: {default_model}" if l.startswith("model:") else l for l in head]
body = []
for mid in ids:
    body.append(f"  - name: {mid}")
    body.append(f"    max_output_tokens: {max_tokens}")
config_path.write_text("\n".join(head + body) + "\n")
print(f"synced {len(ids)} model(s) into {config_path.name}"
      + (f"; default = {default_model}" if default_model else "") + ":")
for mid in ids:
    print(f"  - {mid}")
PY
