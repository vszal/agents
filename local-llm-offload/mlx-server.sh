#!/usr/bin/env bash
# mlx-server.sh — Serves a local model via Apple MLX (mlx_lm.server) on :8081.
#
# Canonical launcher for the on-device LLM, shared via the ~/.local/bin/mlx-server.sh
# symlink. Consumers: the skill-eval scripts (run-eval-iteration.sh starts/stops it;
# run-eval-local.sh requires it up) and the local-offload agent (run-local.sh / post-local.py
# both POST to :8081). Also usable behind litellm (:8082) when driving Claude Code itself.
#
# Requires (Homebrew Python 3.11):
#   /opt/homebrew/bin/pip3 install 'mlx-lm>=0.31.0'
# First run downloads the model to ~/.cache/huggingface/hub/
#
# Usage:
#   ./mlx-server.sh                 # default model (gemma12 / gemma-4-12b) on :8081
#   ./mlx-server.sh phi4            # alias → mlx-community/phi-4-4bit
#   ./mlx-server.sh mistral 8081    # alias + explicit port
#   ./mlx-server.sh org/Model-4bit  # any full HF id (contains '/') used as-is
#   ./mlx-server.sh --resolve qwen14   # print full id for an alias, then exit
#   ./mlx-server.sh --list-aliases     # print the alias→id table, then exit
#
# Aliases: gemma12 (default), qwen14, qwencoder14, qwen4, qwen06, phi4, mistral, gemma27. '/' ⇒ full id.
#
# This file is the SINGLE SOURCE OF TRUTH for alias→id. Other tools must not
# re-hardcode ids: mlx-lib.sh and the skill-eval scripts resolve aliases by
# shelling out to `mlx-server.sh --resolve` / `--list-aliases` (via the
# ~/.local/bin symlink). Keep `alias_table` below as the only place ids live.
#
# Model options by RAM (M4 Max 24 GB / 20 GB GPU wired limit):
#
#   MODEL               SIZE    DECODE      NOTES
#   Qwen3-4B-4bit       ~2.3GB  ~178 tok/s  Recommended — fast, capable
#   Qwen3-8B-4bit       ~4.5GB  ~91 tok/s   Slower prefill, better quality
#   Qwen3-14B-4bit      ~7.9GB  ~135 tok/s  Best Qwen quality; supports tools
#   phi-4-4bit          ~7.7GB  ~185 tok/s  Diverse (non-Qwen) lineage, fastest
#   Mistral-Small-3.2   ~13GB   ~110 tok/s  24B dense; ~16GB peak wired
#   gemma-3-text-27b    ~15GB   —           27B; sliding-window attn keeps KV
#                                           small (~1GB), but needs 1GB cache.
#                                           This is the LARGEST that fits 24GB.
# DO NOT add Qwen3-32B-4bit (~18GB weights): it crashed the machine — wired
# peaked ~22.6GB (GQA KV has no sliding-window bound), exceeding the 24GB unit.
#  (decode rates above are PREFILL tok/s on an ~8.5K-token input, slim cache.)
#
# Speculative decoding: add --draft-model + --num-draft-tokens to boost
# decode speed 2-3x. Draft model must share the same tokenizer family.
#
# Memory budget (must stay < iogpu.wired_limit_mb ≈ 20GB):
#   weights + KV cache + prompt-cache reservation + OS/apps. A 5GB prompt-cache
#   reservation + an ~8GB resident model once wired Qwen near the ceiling and
#   forced swap, so the reservation now defaults small and PER-MODEL: 1GB for
#   the 15GB gemma-27b (tight), 1.5GB otherwise. Override with PROMPT_CACHE_BYTES.

# --- alias registry (single source of truth) ----------------------------
# One "alias full-id" per line (whitespace-separated; neither field has spaces).
# This is the ONLY place alias→id mappings live. Edit here when the served
# model set changes; every other consumer reads it via resolve_alias /
# `--resolve` / `--list-aliases`.
alias_table() {
  cat <<'EOF'
gemma12 rajaschitnis/gemma-4-12b-it-text-only-4bit-mlx
qwen14 mlx-community/Qwen3-14B-4bit
qwencoder14 mlx-community/Qwen2.5-Coder-14B-Instruct-4bit
qwen4 mlx-community/Qwen3-4B-4bit
qwen06 mlx-community/Qwen3-0.6B-4bit
phi4 mlx-community/phi-4-4bit
mistral mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit
gemma27 mlx-community/gemma-3-text-27b-it-4bit
EOF
}

# resolve_alias <alias|full-id> -> prints full HF id; nonzero if unknown.
# A value containing '/' is treated as a full id and used verbatim.
resolve_alias() {
  case "$1" in */*) printf '%s\n' "$1"; return 0 ;; esac
  local id
  id=$(alias_table | awk -v a="$1" '$1==a{print $2; exit}')
  [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
  return 1
}

# --- query subcommands (print and exit; no server launch) ----------------
case "${1:-}" in
  --resolve)
    resolve_alias "${2:?--resolve needs an alias}" \
      || { echo "unknown model alias '${2}'" >&2; exit 2; }
    exit 0 ;;
  --list-aliases) alias_table; exit 0 ;;
esac

# --- args ---------------------------------------------------------------
MODEL_ARG="${1:-gemma12}"
PORT="${2:-8081}"
MODEL=$(resolve_alias "$MODEL_ARG") \
  || { echo "unknown model alias '$MODEL_ARG' (use a full org/model id or a known alias)" >&2; exit 2; }

# Per-model prompt-cache reservation (bytes), overridable via env. Bigger
# weights get a smaller reservation to stay under the ~20GB wired ceiling.
case "$MODEL" in
  *gemma-3-text-27b*) DEFAULT_CACHE_BYTES=1073741824 ;;  # 1GB — 15GB weights, tight
  *)                  DEFAULT_CACHE_BYTES=1610612736 ;;  # 1.5GB
esac
PROMPT_CACHE_BYTES="${PROMPT_CACHE_BYTES:-$DEFAULT_CACHE_BYTES}"

# enable_thinking chat-template kwarg: Qwen3 and gemma-4 are reasoning models that
# accept it (render thinking off → clean answer in message.content). Other models
# don't reference it; passing it would be rejected, so only set it for these two.
EXTRA_ARGS=()
case "$MODEL" in
  *Qwen3*|*gemma-4-12b*) EXTRA_ARGS+=(--chat-template-args '{"enable_thinking":false}') ;;
esac

LOG_FILE="${HOME}/.config/llm-switch/mlx-server.log"
mkdir -p "$(dirname "${LOG_FILE}")"
echo "Logging to ${LOG_FILE}"
echo "Starting mlx_lm.server  model=${MODEL}  port=${PORT}  prompt_cache_bytes=${PROMPT_CACHE_BYTES}"

/opt/homebrew/bin/mlx_lm.server \
  --model "${MODEL}" \
  --host 127.0.0.1 \
  --port "${PORT}" \
  "${EXTRA_ARGS[@]}" \
  --max-tokens 4096 \
  --prompt-cache-size 4 \
  --prompt-cache-bytes "${PROMPT_CACHE_BYTES}" \
  2>&1 | tee "${LOG_FILE}"

# Draft model settings
  #--draft-model mlx-community/Qwen3-0.6B-4bit \
  #--num-draft-tokens 5 \
  #--prompt-cache-size 4 \
  #--prompt-cache-bytes 5368709120 \
