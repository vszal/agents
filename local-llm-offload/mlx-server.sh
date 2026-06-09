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
#
# Aliases: gemma12 (default), qwen14, qwencoder14, qwen4, qwen06, phi4, mistral, gemma27. '/' ⇒ full id.
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

# --- args ---------------------------------------------------------------
MODEL_ARG="${1:-gemma12}"
PORT="${2:-8081}"

# Resolve short aliases → full HF ids. A value containing '/' is used verbatim.
case "$MODEL_ARG" in
  */*)    MODEL="$MODEL_ARG" ;;
  qwen14) MODEL="mlx-community/Qwen3-14B-4bit" ;;
  qwencoder14) MODEL="mlx-community/Qwen2.5-Coder-14B-Instruct-4bit" ;;
  qwen4)  MODEL="mlx-community/Qwen3-4B-4bit" ;;
  qwen06) MODEL="mlx-community/Qwen3-0.6B-4bit" ;;
  phi4)   MODEL="mlx-community/phi-4-4bit" ;;
  mistral) MODEL="mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit" ;;
  gemma27) MODEL="mlx-community/gemma-3-text-27b-it-4bit" ;;
  gemma12) MODEL="rajaschitnis/gemma-4-12b-it-text-only-4bit-mlx" ;;
  *)      echo "unknown model alias '$MODEL_ARG' (use a full org/model id or a known alias)" >&2; exit 2 ;;
esac

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
