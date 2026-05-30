#!/usr/bin/env bash
#
# install.sh — install the "local-offload" subagent into Claude Code.
#
# Generates an agent file with the runner's absolute path resolved in.
# Default target is the GLOBAL agents dir (~/.claude/agents) so the agent is
# available in every project. Pass --project to install into ./.claude/agents
# of the current repo instead.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-local.sh"
SRC="$SCRIPT_DIR/local-offload.md"

if [[ "${1:-}" == "--project" ]]; then
  DEST_DIR="$(pwd)/.claude/agents"
else
  DEST_DIR="$HOME/.claude/agents"
fi
DEST="$DEST_DIR/local-offload.md"

mkdir -p "$DEST_DIR"
chmod +x "$RUNNER"
sed "s#__RUNNER__#$RUNNER#g" "$SRC" > "$DEST"

# Activate the tracked git pre-commit hook (runs the invariant suite on commit).
# core.hooksPath is local config, so a fresh clone needs this; safe to re-run.
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  chmod +x "$SCRIPT_DIR/hooks/pre-commit" 2>/dev/null || true
  git -C "$SCRIPT_DIR" config core.hooksPath hooks
  echo "Git hook        -> core.hooksPath=hooks (pre-commit runs ./test-suite.sh --no-live)"
fi

echo "Installed agent -> $DEST"
echo "Runner          -> $RUNNER"
echo
echo "Use it in Claude Code:  ask Claude to 'offload this to the local model',"
echo "or invoke directly with the @local-offload subagent."
echo "Ensure mlx_lm.server is running on :8081 (see ../mlx-server.sh)."
