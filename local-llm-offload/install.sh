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
chmod +x "$RUNNER" "$SCRIPT_DIR/tools/web_fetch.sh" "$SCRIPT_DIR/tools/url_guard.py" "$SCRIPT_DIR/tools/load_skill.sh" 2>/dev/null || true
sed "s#__RUNNER__#$RUNNER#g" "$SRC" > "$DEST"

# Provision the GUARDED web tools + the load_skill tool into the aichat tool set.
# The isolated config discovers tools through aichat-config/functions ->
# ~/llm-functions, so the hardened web_fetch (+ its url_guard.py), web_search_tavily,
# and load_skill must be built there. Best-effort: if llm-functions/argc aren't
# present, print instructions.
FUNCTIONS_DIR="$(readlink -f "$SCRIPT_DIR/aichat-config/functions" 2>/dev/null || true)"
provision_web_tools() {
  [[ -n "$FUNCTIONS_DIR" && -d "$FUNCTIONS_DIR/tools" ]] || {
    echo "NOTE: aichat-config/functions not linked to an llm-functions checkout;"
    echo "      see README 'Prerequisites' to build fs_* + the web/skill tools, then re-run."
    return; }
  cp "$SCRIPT_DIR/tools/web_fetch.sh" "$SCRIPT_DIR/tools/url_guard.py" \
     "$SCRIPT_DIR/tools/load_skill.sh" "$FUNCTIONS_DIR/tools/"
  chmod +x "$FUNCTIONS_DIR/tools/web_fetch.sh" "$FUNCTIONS_DIR/tools/url_guard.py" \
     "$FUNCTIONS_DIR/tools/load_skill.sh"
  # ADD the guarded web tools + load_skill to the build without disturbing whatever
  # else the user builds for their own aichat. (The OFFLOAD model is restricted to
  # fs read + guarded web + load_skill by `use_tools` in aichat-config, regardless
  # of the full build.)
  touch "$FUNCTIONS_DIR/tools.txt"
  for t in web_search_tavily.sh web_fetch.sh load_skill.sh; do
    grep -qxF "$t" "$FUNCTIONS_DIR/tools.txt" || echo "$t" >> "$FUNCTIONS_DIR/tools.txt"
  done
  if command -v argc >/dev/null 2>&1; then
    ( cd "$FUNCTIONS_DIR" && argc build >/dev/null 2>&1 ) \
      && echo "Tools           -> built into $FUNCTIONS_DIR (fs_ls,fs_cat,web_search_tavily,web_fetch,load_skill)" \
      || echo "WARN: 'argc build' failed in $FUNCTIONS_DIR — run it by hand."
  else
    echo "NOTE: 'argc' not found; run 'cd $FUNCTIONS_DIR && argc build' to finish the tools."
  fi
  [[ -n "${TAVILY_API_KEY:-}" ]] || echo "NOTE: web_search needs TAVILY_API_KEY in your environment (unset now)."
}
provision_web_tools

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
echo "Ensure mlx_lm.server is running on :8081 (see ./mlx-server.sh)."
