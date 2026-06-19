#!/usr/bin/env bash
# run-batch.sh — Run one local model over many prompt files, sequentially.
#
# The generic, eval-agnostic batch pattern: bring up a model on :8081, send each
# input file to it via post-local.py (one HTTP POST each, in order — the server's
# single GPU means no concurrency), collect the answers, then bring the server
# down. Because calls are sequential and share a leading prefix, the server's
# prompt cache makes repeated runs cheap (keep the variable part of each input
# late). For eval-specific layouts/grading, see the skill-evaluation-tools repo,
# which sources mlx-lib.sh and supplies its own loop.
#
# Usage:
#   run-batch.sh [opts] <alias|full-id> <input-file>...
#
# Options:
#   -o, --out-dir DIR   Write <input-basename>.answer.md per file into DIR.
#                       Default: print each answer to stdout (separated by a header).
#   -p, --prompt TEXT   Instruction appended after each file's contents.
#   -m, --max-tokens N  Forwarded to post-local.py (default: its own default).
#   -t, --temp T        Forwarded to post-local.py.
#       --keep-server   Use an already-running :8081 as-is; don't stop/start it.
#   -h, --help          This help.
#
# Examples:
#   run-batch.sh qwen14 prompts/*.txt
#   run-batch.sh -o out -p "Summarize in 3 bullets." gemma12 notes/*.md
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=mlx-lib.sh
source "$HERE/mlx-lib.sh"
POST="$HERE/post-local.py"; [ -x "$POST" ] || POST="$HOME/.local/bin/post-local.py"

OUTDIR=""; PROMPT=""; MAXTOK=""; TEMP=""; MANAGE=1
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out-dir)   OUTDIR="${2:?}"; shift 2 ;;
    -p|--prompt)    PROMPT="${2:?}"; shift 2 ;;
    -m|--max-tokens) MAXTOK="${2:?}"; shift 2 ;;
    -t|--temp)      TEMP="${2:?}"; shift 2 ;;
    --keep-server)  MANAGE=0; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    --)             shift; break ;;
    -*)             echo "unknown option: $1" >&2; exit 2 ;;
    *)              break ;;
  esac
done

ALIAS="${1:?need a model alias or full id}"; shift || true
[ $# -gt 0 ] || { echo "need at least one input file" >&2; exit 2; }
ID=$(mlx_resolve "$ALIAS") || { echo "unknown model alias '$ALIAS'" >&2; exit 2; }
[ -n "$OUTDIR" ] && mkdir -p "$OUTDIR"

post_args=(-m "mlx:$ID")
[ -n "$MAXTOK" ] && post_args+=(--max-tokens "$MAXTOK")
[ -n "$TEMP" ]   && post_args+=(--temp "$TEMP")

if [ "$MANAGE" -eq 1 ]; then
  trap 'mlx_stop' EXIT
  echo ">> starting $ALIAS ($ID) on :${MLX_PORT}"
  mlx_stop; mlx_start "$ALIAS"
  mlx_wait_up "$(basename "$ID")" || { echo "!! server never came up for $ALIAS" >&2; exit 1; }
else
  mlx_up || { echo "!! no server on :${MLX_PORT} (and --keep-server set)" >&2; exit 1; }
fi
echo ">> server up; ${#} input file(s)"

rc=0
for f in "$@"; do
  [ -f "$f" ] || { echo "!! no such file: $f" >&2; rc=1; continue; }
  if [ -n "$OUTDIR" ]; then
    out="$OUTDIR/$(basename "$f").answer.md"
    "$POST" "${post_args[@]}" -f "$f" ${PROMPT:+"$PROMPT"} > "$out" 2>"$out.err" \
      && printf '%-50s %8s bytes\n' "$(basename "$f")" "$(wc -c < "$out")" \
      || { echo "!! failed: $f (see $out.err)" >&2; rc=1; }
  else
    echo "===== $f ====="
    "$POST" "${post_args[@]}" -f "$f" ${PROMPT:+"$PROMPT"} || rc=1
    echo
  fi
done
exit "$rc"
