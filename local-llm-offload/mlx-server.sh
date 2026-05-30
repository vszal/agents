#!/usr/bin/env bash
#
# mlx-server.sh — start an OpenAI-compatible local LLM server via mlx_lm.
#
# This is the model server the offload agent talks to on :8081. It is the only
# backend run-local.sh contacts (see config.yaml's api_base). Apple Silicon only
# (mlx). On other hardware, run any OpenAI-compatible server on :8081 instead
# (e.g. llama.cpp's llama-server, vLLM, Ollama's OpenAI endpoint).
#
# Prereqs:  pip install mlx-lm   (https://github.com/ml-explore/mlx-lm)
#
# Usage:
#   ./mlx-server.sh                         # default model on :8081
#   ./mlx-server.sh mlx-community/Qwen3-8B-4bit
#   ./mlx-server.sh <model> <port>
#
# After it's up, point the agent at it and sync the model list:
#   ./sync-models.sh           # rewrites the models: block in aichat-config/config.yaml
#   ./run-local.sh -l          # list models the server reports right now
#
set -euo pipefail

MODEL="${1:-mlx-community/Qwen3-14B-4bit}"
PORT="${2:-8081}"

command -v mlx_lm.server >/dev/null 2>&1 || {
  echo "error: mlx_lm.server not found. Install with: pip install mlx-lm" >&2
  echo "(Apple Silicon only; on other hardware run any OpenAI-compatible server on :$PORT)" >&2
  exit 1
}

echo "Starting mlx_lm.server  model=$MODEL  port=$PORT"
exec mlx_lm.server --model "$MODEL" --port "$PORT"
