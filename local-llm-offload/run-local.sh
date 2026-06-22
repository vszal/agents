#!/usr/bin/env bash
#
# run-local.sh — Offload a task to a LOCAL LLM via aichat.
# Used by the Claude "local-offload" subagent, but also runnable by hand.
#
# Usage:
#   run-local.sh [-m MODEL] [-f FILE]... [--read-root DIR]... "the task ..."
#   echo "the task" | run-local.sh [-m MODEL]
#
# Options:
#   -m, --model MODEL    aichat model id (default: the model the server is serving)
#   -f, --file  FILE     Include a file/dir as context (repeatable). The file is
#                        also added to the sandbox read-allow set automatically.
#       --read-root DIR  Additionally allow the model to READ under DIR (repeatable).
#                        By default the model can read NOTHING outside the files you
#                        pass with -f — the on-device model + its fs_ls/fs_cat tools
#                        run inside a sandbox confined to the per-task paths.
#       --skill-root DIR Scope load_skill to a workspace: search DIR for <slug>/SKILL.md
#                        (repeatable). Prepended ahead of OFFLOAD_SKILL_ROOTS so a
#                        workspace skill shadows a same-named user one, and the dir is
#                        added to the sandbox read-allow set automatically.
#       --skill-root-only  Use ONLY the --skill-root dirs (no fall-through to the user's
#                        OFFLOAD_SKILL_ROOTS defaults). For testing a skill in isolation.
#                        Requires at least one --skill-root.
#   -s, --stream         Stream tokens to stdout as generated (default: buffered).
#       --no-sandbox     Disable the read-confinement sandbox (debugging only;
#                        prints a warning). Never use for untrusted/web-enabled runs.
#   -l, --list           List local models currently loaded on :8081 and exit
#   -h, --help           Show this help
#
# Notes:
#   * Uses an ISOLATED aichat config (./aichat-config). The model now has, besides
#     read-only fs (fs_ls, fs_cat): web_search (Tavily), a HARDENED web_fetch
#     (host allowlist + SSRF/private-IP guard — see tools/url_guard.py), and
#     load_skill (read a SKILL.md by name from OFFLOAD_SKILL_ROOTS; read-only).
#   * Web egress is bounded by tools/fetch-allowlist.txt (override with
#     OFFLOAD_FETCH_ALLOWLIST). web_search needs TAVILY_API_KEY in the environment.
#   * File-DATA reads are confined by macOS sandbox-exec to the per-task paths only,
#     so a web-capable model can't read ambient files and exfiltrate them.
#   * Talks to the local mlx_lm server on :8081 only (no cloud).
#
set -euo pipefail

# Resolve through symlinks so $SCRIPT_DIR is the real source dir (and thus
# aichat-config/ + tools/) even when invoked via a ~/.local/bin symlink.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export AICHAT_CONFIG_DIR="$SCRIPT_DIR/aichat-config"

SERVER="http://localhost:8081"
MODEL=""   # empty => auto-resolve from the live server (see resolve_default_model)
FILES=()
READ_ROOTS=()
SKILL_ROOTS=()   # per-workspace skill dirs from --skill-root; folded in after parsing
SKILL_ROOT_ONLY=0 # 1 => use ONLY --skill-root dirs (no fall-through to env defaults)
PROMPT=""
STREAM=0      # 0 => --no-stream (buffered); 1 => stream tokens as they arrive
SANDBOX=1     # 1 => confine file-data reads via sandbox-exec; 0 => --no-sandbox

# Egress allowlist for web_fetch: env override wins, else the repo default file.
if [[ -z "${OFFLOAD_FETCH_ALLOWLIST:-}" && -f "$SCRIPT_DIR/tools/fetch-allowlist.txt" ]]; then
  OFFLOAD_FETCH_ALLOWLIST="$(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/tools/fetch-allowlist.txt" | tr '\n' ' ')"
fi
export OFFLOAD_FETCH_ALLOWLIST="${OFFLOAD_FETCH_ALLOWLIST:-}"

# Skill roots the load_skill tool may read (read-only skill TEXT). Env override
# wins; default to the user's standard skill dirs. Per-workspace --skill-root dirs
# are prepended after arg parsing (below). All get re-allowed in the sandbox
# profile — without that the $HOME deny would make load_skill empty.
export OFFLOAD_SKILL_ROOTS="${OFFLOAD_SKILL_ROOTS:-$HOME/.claude/skills $HOME/.agents/skills}"

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

# Build a Seatbelt profile that lets aichat run normally but blocks the model
# from READING the user's private files. We start permissive (so dyld/system
# work without a fragile allowlist) and then DENY file-data reads under $HOME —
# where this user's secrets live (~/.ssh, ~/.aws, ~/Library keychains, ~/Code
# source) — re-allowing only the dirs aichat needs and the per-task roots.
# System files (/usr, /System, /Library) aren't secret, so they stay readable.
# Network egress is allowed here and filtered by the web_fetch guard instead
# (Seatbelt can't domain-filter, and :8081 must stay reachable).
build_sandbox_profile() {
  local f functions_dir; f="$(mktemp -t offload-sb)"
  functions_dir="$(readlink -f "$AICHAT_CONFIG_DIR/functions" 2>/dev/null || echo "$AICHAT_CONFIG_DIR/functions")"
  {
    cat <<EOF
(version 1)
(allow default)

; Confine the user's home: deny DATA reads under \$HOME, then re-allow only what
; aichat/the tools need + the per-task roots. (Directory listing also needs
; file-read-data, so the model's fs_ls/fs_cat can only reach re-allowed paths.)
(deny file-read-data (subpath "$HOME"))
(allow file-read-data
  (subpath "$AICHAT_CONFIG_DIR")
  (subpath "$functions_dir")
  (subpath "$SCRIPT_DIR/tools")
  (subpath "$HOME/.cache")
  (subpath "$HOME/Library/Caches"))
EOF
    # Skill roots (read-only): let the load_skill tool reach the skills it loads.
    # Skill text is non-secret instruction content; keep secrets out of skills.
    local sr srp
    for sr in ${OFFLOAD_SKILL_ROOTS:-}; do
      [[ -n "$sr" && -d "$sr" ]] || continue
      srp="$(cd "$sr" 2>/dev/null && pwd || echo "$sr")"
      printf '(allow file-read-data (subpath "%s"))\n' "$srp"
    done
    # Per-task read roots (TIGHTEST): explicit --read-root dirs are browsable;
    # each -f FILE is allowed as a single literal (not its whole directory).
    local r rp
    for r in "${READ_ROOTS[@]:-}"; do
      [[ -n "$r" ]] || continue
      rp="$(cd "$r" 2>/dev/null && pwd || echo "$r")"
      printf '(allow file-read-data (subpath "%s"))\n' "$rp"
    done
    for r in "${FILES[@]:-}"; do
      [[ -n "$r" ]] || continue
      rp="$(readlink -f "$r" 2>/dev/null || echo "$r")"
      printf '(allow file-read-data (literal "%s"))\n' "$rp"
    done
  } >"$f"
  echo "$f"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)    MODEL="$2"; shift 2 ;;
    -f|--file)     FILES+=("$2"); shift 2 ;;
    --read-root)   READ_ROOTS+=("$2"); shift 2 ;;
    --skill-root)  SKILL_ROOTS+=("$2"); shift 2 ;;
    --skill-root-only) SKILL_ROOT_ONLY=1; shift ;;
    -s|--stream)   STREAM=1; shift ;;
    --no-sandbox)  SANDBOX=0; shift ;;
    -l|--list)     check_server; curl -s "$SERVER/v1/models" | jq -r '.data[].id'; exit 0 ;;
    -h|--help)     print_help; exit 0 ;;
    --)            shift; PROMPT="$*"; break ;;
    -*)            echo "unknown option: $1" >&2; exit 2 ;;
    *)             PROMPT="${PROMPT:+$PROMPT }$1"; shift ;;
  esac
done

# Per-workspace skill roots (--skill-root): with --skill-root-only, use ONLY those
# (isolated skill testing — no fall-through to the user defaults); otherwise prepend
# them so workspace skills shadow same-named user ones. Either way build_sandbox_profile
# re-allows whatever OFFLOAD_SKILL_ROOTS ends up holding.
if [[ "$SKILL_ROOT_ONLY" -eq 1 ]]; then
  [[ "${#SKILL_ROOTS[@]}" -gt 0 ]] || {
    echo "error: --skill-root-only requires at least one --skill-root DIR" >&2; exit 2; }
  export OFFLOAD_SKILL_ROOTS="${SKILL_ROOTS[*]}"
elif [[ "${#SKILL_ROOTS[@]}" -gt 0 ]]; then
  export OFFLOAD_SKILL_ROOTS="${SKILL_ROOTS[*]} $OFFLOAD_SKILL_ROOTS"
fi

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

# Assemble the command, wrapped in sandbox-exec unless --no-sandbox was given.
cmd=(aichat "${args[@]}")
# In streaming mode, force line-buffered stdout so a redirected file grows live.
if [[ "$STREAM" -eq 1 ]] && command -v stdbuf >/dev/null 2>&1; then
  cmd=(stdbuf -oL "${cmd[@]}")
fi

if [[ "$SANDBOX" -eq 1 ]]; then
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    echo "error: sandbox-exec not found; refusing to run a web-capable model unconfined." >&2
    echo "       (Pass --no-sandbox to override, only for trusted local-only tasks.)" >&2
    exit 5
  fi
  PROFILE="$(build_sandbox_profile)"
  trap 'rm -f "$PROFILE"' EXIT
  exec sandbox-exec -f "$PROFILE" "${cmd[@]}"
fi

echo "warning: running WITHOUT read-confinement (--no-sandbox); the model can read any file your user can." >&2
exec "${cmd[@]}"
