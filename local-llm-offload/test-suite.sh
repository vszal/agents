#!/usr/bin/env bash
#
# test-suite.sh — E2E / invariant tests for the local-llm-offload gate.
#
# Run this regularly (and after ANY change to the agent, policy, runner, or
# aichat config) to confirm the security boundary is still intact:
#   * the worker holds no write/web tools,
#   * the human-owned policy still gates writes and web access,
#   * the gate's own config files are protected from the worker,
#   * the isolated aichat config exposes only read-only fs tools,
#   * the installed agent matches the source (runner path resolved), and
#   * (if the local model server is up) a real prompt round-trips end-to-end.
#
# Usage:
#   ./test-suite.sh            # full suite; live tests auto-skip if :8081 down
#   ./test-suite.sh --no-live  # static/security invariants only
#   ./test-suite.sh --live     # fail (don't skip) if the live server is down
#
# Exit code: 0 if no test FAILED (skips are OK), 1 otherwise.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

POLICY="$SCRIPT_DIR/offload-policy.json"
SRC="$SCRIPT_DIR/local-offload.md"
CFG="$SCRIPT_DIR/aichat-config/config.yaml"
RUNNER="$SCRIPT_DIR/run-local.sh"
INSTALLER="$SCRIPT_DIR/install.sh"
INSTALLED="$HOME/.claude/agents/local-offload.md"
SERVER="http://localhost:8081"

LIVE_MODE="auto"   # auto | on | off
case "${1:-}" in
  --no-live) LIVE_MODE="off" ;;
  --live)    LIVE_MODE="on"  ;;
  "" )       ;;
  *) echo "unknown arg: $1 (use --live | --no-live)"; exit 2 ;;
esac

# ---- tiny test harness -------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; R=""; Y=""; B=""; Z=""; fi

section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$Y" "$Z" "$1"; }

# ok "desc" <exit status>  — pass if status==0
ok()  { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }
# eq "desc" actual expected
eq()  { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi; }
# has "desc" haystack needle  — pass if needle present
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing: $3"; fi; }
# nothas "desc" haystack needle — pass if needle ABSENT (negative/adversarial)
nothas() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "FOUND forbidden: $3"; else pass "$1"; fi; }

pj() { jq -r "$1" "$POLICY" 2>/dev/null; }   # policy query

# =============================================================================
section "1. Files present"
for f in "$POLICY" "$SRC" "$CFG" "$RUNNER" "$INSTALLER"; do
  [[ -f "$f" ]]; ok "exists: ${f#$SCRIPT_DIR/}" $?
done
[[ -d "$SCRIPT_DIR/sandbox" ]]; ok "exists: sandbox/" $?

# =============================================================================
section "2. Policy is valid & decisions are correct"
jq -e . "$POLICY" >/dev/null 2>&1; ok "offload-policy.json is valid JSON" $?
eq "write.decision = ask"          "$(pj '.capabilities.write.decision')"      "ask"
eq "web_search.decision = orchestrator" "$(pj '.capabilities.web_search.decision')" "orchestrator"
eq "web_fetch.decision = deny"     "$(pj '.capabilities.web_fetch.decision')"  "deny"
eq "bash.decision = deny"          "$(pj '.capabilities.bash.decision')"       "deny"
eq "missing_policy_default = ask"  "$(pj '.missing_policy_default')"           "ask"
eq "web_search.fetch_urls = false" "$(pj '.capabilities.web_search.fetch_urls')" "false"
[[ "$(pj '.capabilities.web_search.exfil_guard | type')" == "object" ]]; ok "web_search has exfil_guard" $?
[[ -n "$(pj '.audit_log')" ]]; ok "audit_log is set" $?
eq "write auto-allows sandbox/" "$(pj '.capabilities.write.auto_allow_under | index("sandbox/") != null')" "true"

section "2b. Policy protects the gate's own config (deny_paths)"
DENY="$(pj '.capabilities.write.deny_paths[]')"
for p in ".claude/" ".git/" "offload-policy.json" "aichat-config/" "run-local.sh" "install.sh"; do
  has "deny_paths protects $p" "$DENY" "$p"
done

# =============================================================================
section "3. Worker agent source holds NO privileged tools"
TOOLS_LINE="$(grep -m1 '^tools:' "$SRC" | sed 's/^tools:[[:space:]]*//')"
eq "tools: line is exactly 'Bash, Read'" "$TOOLS_LINE" "Bash, Read"
for forbidden in Write Edit NotebookEdit web_search web_fetch WebSearch WebFetch; do
  nothas "tools: omits $forbidden" "$TOOLS_LINE" "$forbidden"
done
grep -q '^model:[[:space:]]*haiku' "$SRC"; ok "model: haiku" $?
grep -q '__RUNNER__' "$SRC"; ok "source keeps __RUNNER__ placeholder" $?
grep -q 'capability-request' "$SRC"; ok "source documents capability-request protocol" $?

# =============================================================================
section "4. Isolated aichat config exposes ONLY read-only fs tools"
USE_TOOLS="$(grep -m1 '^use_tools:' "$CFG" | sed 's/^use_tools:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//')"
eq "use_tools = fs_ls,fs_cat" "$USE_TOOLS" "fs_ls,fs_cat"
for forbidden in fs_write fs_rm fs_patch fs_mkdir web_search fetch_url execute_command; do
  nothas "use_tools omits $forbidden" "$USE_TOOLS" "$forbidden"
done
# local-only: the configured client base must be localhost:8081
grep -q 'api_base:[[:space:]]*http://localhost:8081' "$CFG"; ok "aichat client points at localhost:8081 only" $?

# =============================================================================
section "5. Runner & installer are sound"
bash -n "$RUNNER";    ok "run-local.sh passes bash -n" $?
bash -n "$INSTALLER"; ok "install.sh passes bash -n" $?
[[ -x "$RUNNER" ]];   ok "run-local.sh is executable" $?
grep -q 'AICHAT_CONFIG_DIR=.*aichat-config' "$RUNNER"; ok "runner uses isolated aichat-config" $?
grep -q 'localhost:8081' "$RUNNER"; ok "runner targets localhost:8081" $?
# adversarial: runner must not reach out to any non-localhost http(s) endpoint
EXT_URLS="$(grep -oE 'https?://[A-Za-z0-9._-]+' "$RUNNER" | grep -vE '://localhost' || true)"
nothas "runner has no external http(s) endpoints" "$EXT_URLS" "://"

# =============================================================================
section "6. Installed agent matches source (runner path resolved)"
if [[ -f "$INSTALLED" ]]; then
  if grep -q '__RUNNER__' "$INSTALLED"; then
    fail "installed agent has 0 unresolved __RUNNER__" "found placeholder; re-run ./install.sh"
  else
    pass "installed agent has 0 unresolved __RUNNER__"
  fi
  # the resolved runner invocation should point at a real, executable script
  RESOLVED="$(grep -oE '/[^ ]*run-local\.sh' "$INSTALLED" | head -1)"
  if [[ -n "$RESOLVED" && -x "$RESOLVED" ]]; then
    pass "installed runner path exists & is executable ($RESOLVED)"
  else
    fail "installed runner path exists & is executable" "resolved='$RESOLVED'"
  fi
  ITOOLS="$(grep -m1 '^tools:' "$INSTALLED" | sed 's/^tools:[[:space:]]*//')"
  eq "installed tools: = 'Bash, Read'" "$ITOOLS" "Bash, Read"
  grep -q 'capability-request' "$INSTALLED"; ok "installed agent documents capability-request" $?
  grep -q 'web_fetch' "$INSTALLED"; ok "installed agent notes web_fetch is denied" $?
else
  skip "installed agent not found at $INSTALLED (run ./install.sh)"
fi

# =============================================================================
section "7. Live end-to-end (local model on :8081)"
# pick an http client
HTTP=""
if command -v curl >/dev/null 2>&1; then HTTP="curl"
elif command -v python3 >/dev/null 2>&1; then HTTP="python3"; fi

server_up() {
  case "$HTTP" in
    curl)    curl -fsS -m 3 -o /dev/null "$SERVER/v1/models" 2>/dev/null ;;
    python3) python3 - "$SERVER/v1/models" <<'PY' 2>/dev/null
import sys,urllib.request
urllib.request.urlopen(sys.argv[1], timeout=3).read()
PY
    ;;
    *) return 2 ;;
  esac
}

if [[ "$LIVE_MODE" == "off" ]]; then
  skip "live tests disabled (--no-live)"
elif [[ -z "$HTTP" ]]; then
  if [[ "$LIVE_MODE" == "on" ]]; then fail "no http client (curl/python3) for --live"; else skip "no http client (curl/python3) — live tests skipped"; fi
elif ! server_up; then
  if [[ "$LIVE_MODE" == "on" ]]; then fail "local server unreachable at $SERVER (--live)"; else skip "local server down at $SERVER — live tests skipped (start mlx_lm.server)"; fi
elif ! command -v aichat >/dev/null 2>&1; then
  if [[ "$LIVE_MODE" == "on" ]]; then fail "aichat not in PATH (--live)"; else skip "aichat not installed — live round-trip skipped"; fi
else
  pass "local server reachable at $SERVER"
  # model list works
  LIST="$("$RUNNER" -l 2>/dev/null)"
  if [[ -n "$LIST" ]]; then pass "run-local.sh -l returns models ($(printf '%s' "$LIST" | wc -l | tr -d ' ') lines)"
  else fail "run-local.sh -l returns models" "empty output"; fi
  # real prompt round-trip on the smallest model if available, else default
  MODEL=""
  if printf '%s' "$LIST" | grep -q '0.6B'; then
    MODEL="mlx:$(printf '%s' "$LIST" | grep '0.6B' | head -1 | sed 's/^mlx://')"
  fi
  PROMPT='Reply with exactly the single word: PONG . No other text.'
  if [[ -n "$MODEL" ]]; then OUT="$("$RUNNER" -m "$MODEL" "$PROMPT" 2>/dev/null)"
  else OUT="$("$RUNNER" "$PROMPT" 2>/dev/null)"; fi
  if [[ -n "$OUT" ]]; then pass "round-trip returned non-empty output${MODEL:+ ($MODEL)}"
  else fail "round-trip returned non-empty output" "empty — check server/model"; fi
  # soft content check: nondeterministic, so a miss is a warning not a failure
  if printf '%s' "$OUT" | grep -qi 'PONG'; then pass "round-trip output contains expected token (PONG)"
  else skip "round-trip output lacked 'PONG' (model nondeterminism, not a gate failure)"; fi
fi

# =============================================================================
section "Summary"
printf '%s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$Y" "$SKIP" "$Z"
[[ "$FAIL" -eq 0 ]]
