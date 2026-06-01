#!/usr/bin/env bash
#
# run-local.sh — Offload a task to a LOCAL LLM via aichat.
# Used by the Claude "local-offload" subagent, but also runnable by hand.
#
# Usage:
#   run-local.sh [-m MODEL] [-f FILE]... "the task ..."
#   echo "the task" | run-local.sh [-m MODEL]
#
# Options:
#   -m, --model MODEL   aichat model id (default: the model the server is serving)
#   -f, --file  FILE    Include a file/dir/URL as context (repeatable)
#   -s, --stream        Stream tokens to stdout as generated (default: buffered).
#                       Use to peek at incremental output of slow runs; pairs with
#                       stdbuf -oL so a redirected file grows in near-real-time.
#   -l, --list          List local models currently loaded on :8081 and exit
#   -h, --help          Show this help
#
# Notes:
#   * Uses an ISOLATED aichat config (./aichat-config) that exposes only
#     read-only fs tools (fs_ls, fs_cat) — never writes or deletes.
#   * Talks to the local mlx_lm server on :8081 only (no cloud).
#
set -euo pipefail

# Resolve through symlinks so $SCRIPT_DIR is the real source dir (and thus
# aichat-config/) even when invoked via a ~/.local/bin symlink.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export AICHAT_CONFIG_DIR="$SCRIPT_DIR/aichat-config"

SERVER="http://localhost:8081"
MODEL=""   # empty => auto-resolve from the live server (see resolve_default_model)
FILES=()
PROMPT=""
STREAM=0   # 0 => --no-stream (buffered); 1 => stream tokens to stdout as they arrive

# Print the leading header comment block (skip shebang, stop at first code line).
print_help() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

# Fail fast with a friendly message if the local model server isn't up.
check_server() {
  if ! curl -fsS -m 3 -o /dev/null "$SERVER/v1/models" 2>/dev/null; then
    {
      echo "error: local LLM server not reachable at $SERVER"
      echo "The mlx_lm server appears to be down. Start it with, e.g.:"
      echo "    $SCRIPT_DIR/mlx-server.sh"
      echo "then retry."
    } >&2
    exit 3
  fi
}

# Resolve the model to use when -m is omitted: the model the server was launched
# with (its --model arg), falling back to the first model the API reports.
# aichat addresses local models with the `mlx:` client prefix.
resolve_default_model() {
  local m
  m=$(ps aux | grep -E '[m]lx_lm\.server|[l]lama-server' | grep -- '--model' \
      | sed 's/.*--model //' | awk '{print $1}' | head -1)
  if [[ -z "$m" ]]; then
    m=$(curl -fsS -m 3 "$SERVER/v1/models" 2>/dev/null | jq -r '.data[0].id // empty')
  fi
  [[ -n "$m" ]] || { echo "error: could not determine a default model from $SERVER" >&2; exit 3; }
  [[ "$m" == mlx:* ]] && echo "$m" || echo "mlx:$m"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model) MODEL="$2"; shift 2 ;;
    -f|--file)  FILES+=("$2"); shift 2 ;;
    -s|--stream) STREAM=1; shift ;;
    -l|--list)  check_server; curl -s "$SERVER/v1/models" | jq -r '.data[].id'; exit 0 ;;
    -h|--help)  print_help; exit 0 ;;
    --)         shift; PROMPT="$*"; break ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          PROMPT="${PROMPT:+$PROMPT }$1"; shift ;;
  esac
done

# Allow the prompt to arrive on stdin (e.g. piped from another command).
if [[ -z "$PROMPT" && ! -t 0 ]]; then PROMPT="$(cat)"; fi
if [[ -z "$PROMPT" ]]; then print_help; exit 1; fi

if ! command -v aichat >/dev/null 2>&1; then
  echo "error: 'aichat' not found in PATH; install it to run local offload." >&2
  exit 4
fi

check_server

[[ -n "$MODEL" ]] || MODEL="$(resolve_default_model)"

if [[ "$STREAM" -eq 1 ]]; then
  args=(--model "$MODEL")           # stream tokens; aichat streams by default
else
  args=(--no-stream --model "$MODEL")
fi
for f in "${FILES[@]:-}"; do [[ -n "$f" ]] && args+=(--file "$f"); done
args+=("$PROMPT")

# In streaming mode, force line-buffered stdout (via stdbuf if present) so a
# redirected file grows in near-real-time instead of in big libc-buffered chunks.
if [[ "$STREAM" -eq 1 ]] && command -v stdbuf >/dev/null 2>&1; then
  exec stdbuf -oL aichat "${args[@]}"
fi
exec aichat "${args[@]}"
