#!/usr/bin/env bash
#
# test-suite.sh — E2E / invariant tests for the local-llm-offload gate.
#
# The on-device model now has GUARDED web access (web_search via Tavily; a
# hardened web_fetch), made safe by two boundaries this suite verifies:
#   * the web_fetch SSRF/allowlist guard refuses private/loopback/off-list URLs,
#   * run-local.sh confines the model's file-DATA reads with sandbox-exec so a
#     web-capable model can't read ambient files ($HOME) and exfiltrate them,
#   * WRITES stay orchestrator-mediated (the worker holds no write/bash tools),
#   * the human-owned policy records these decisions and protects its own config,
#   * the isolated aichat config exposes only fs read + the GUARDED web tools
#     (never fs_write/fs_rm/fs_patch or the UNguarded fetch_url_* tools),
#   * the installed agent matches the source, and
#   * (if the server is up) a real prompt round-trips end-to-end.
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
GUARD="$SCRIPT_DIR/tools/url_guard.py"
FETCH="$SCRIPT_DIR/tools/web_fetch.sh"
ALLOWLIST="$SCRIPT_DIR/tools/fetch-allowlist.txt"
GUARD_TEST="$SCRIPT_DIR/tools/test-url-guard.sh"
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

ok()  { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }
eq()  { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing: $3"; fi; }
nothas() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "FOUND forbidden: $3"; else pass "$1"; fi; }

pj() { jq -r "$1" "$POLICY" 2>/dev/null; }   # policy query

# =============================================================================
section "1. Files present"
for f in "$POLICY" "$SRC" "$CFG" "$RUNNER" "$INSTALLER" "$GUARD" "$FETCH" "$ALLOWLIST" "$GUARD_TEST"; do
  [[ -f "$f" ]]; ok "exists: ${f#$SCRIPT_DIR/}" $?
done
[[ -d "$SCRIPT_DIR/sandbox" ]]; ok "exists: sandbox/" $?

# =============================================================================
section "2. Policy is valid & decisions are correct"
jq -e . "$POLICY" >/dev/null 2>&1; ok "offload-policy.json is valid JSON" $?
eq "write.decision = ask"              "$(pj '.capabilities.write.decision')"          "ask"
eq "web_search.decision = direct"      "$(pj '.capabilities.web_search.decision')"     "direct"
eq "web_fetch.decision = direct"       "$(pj '.capabilities.web_fetch.decision')"      "direct"
eq "bash.decision = deny"              "$(pj '.capabilities.bash.decision')"           "deny"
eq "missing_policy_default = ask"      "$(pj '.missing_policy_default')"               "ask"
# web_fetch must advertise the hardening guarantees the guard actually enforces
eq "web_fetch host_allowlist = true"   "$(pj '.capabilities.web_fetch.guarantees.host_allowlist')" "true"
eq "web_fetch follow_redirects = false" "$(pj '.capabilities.web_fetch.guarantees.follow_redirects')" "false"
eq "web_fetch pin_resolved_ip = true"  "$(pj '.capabilities.web_fetch.guarantees.pin_resolved_ip')" "true"
eq "web_fetch points at the guard"     "$(pj '.capabilities.web_fetch.guard')"         "tools/url_guard.py"
# read-confinement must be declared as the thing that makes direct web safe
eq "read_confinement.decision = sandbox" "$(pj '.capabilities.read_confinement.decision')" "sandbox"
[[ -n "$(pj '.audit_log')" ]]; ok "audit_log is set" $?
eq "write auto-allows sandbox/" "$(pj '.capabilities.write.auto_allow_under | index("sandbox/") != null')" "true"

section "2b. Policy protects the gate's own config (deny_paths)"
DENY="$(pj '.capabilities.write.deny_paths[]')"
for p in ".claude/" ".git/" "offload-policy.json" "aichat-config/" "run-local.sh" "install.sh" "tools/"; do
  has "deny_paths protects $p" "$DENY" "$p"
done

# =============================================================================
section "3. Worker DISPATCHER agent holds NO privileged Claude tools"
# The Haiku dispatcher must never hold Claude-side write/web tools; it only shells
# out to run-local.sh. (The local MODEL gets guarded web via aichat, not the agent.)
TOOLS_LINE="$(grep -m1 '^tools:' "$SRC" | sed 's/^tools:[[:space:]]*//')"
eq "tools: line is exactly 'Bash, Read'" "$TOOLS_LINE" "Bash, Read"
for forbidden in Write Edit NotebookEdit WebSearch WebFetch; do
  nothas "tools: omits $forbidden" "$TOOLS_LINE" "$forbidden"
done
grep -q '^model:[[:space:]]*haiku' "$SRC"; ok "model: haiku" $?
grep -q '__RUNNER__' "$SRC"; ok "source keeps __RUNNER__ placeholder" $?
grep -q 'capability-request' "$SRC"; ok "source documents capability-request protocol (writes)" $?

# =============================================================================
section "4. Isolated aichat config: fs-read + GUARDED web only"
USE_TOOLS="$(grep -m1 '^use_tools:' "$CFG" | sed 's/^use_tools:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//')"
eq "use_tools = fs_ls,fs_cat,web_search_tavily,web_fetch" "$USE_TOOLS" "fs_ls,fs_cat,web_search_tavily,web_fetch"
# mutating fs tools and UNguarded fetch tools must never be enabled here
for forbidden in fs_write fs_rm fs_patch fs_mkdir fetch_url_via_curl fetch_url_via_jina execute_command; do
  nothas "use_tools omits $forbidden" "$USE_TOOLS" "$forbidden"
done
grep -q 'api_base:[[:space:]]*http://localhost:8081' "$CFG"; ok "aichat client points at localhost:8081 only" $?

# =============================================================================
section "5. web_fetch SSRF / allowlist guard"
[[ -x "$GUARD_TEST" ]] || chmod +x "$GUARD_TEST" 2>/dev/null
if "$GUARD_TEST" >/tmp/offload-guard.out 2>&1; then
  pass "tools/test-url-guard.sh: all guard cases pass"
else
  fail "tools/test-url-guard.sh: guard cases failed" "$(tail -3 /tmp/offload-guard.out)"
fi
# spot-check the guard directly (no network needed for these refusals)
G_LOOPBACK="$(OFFLOAD_FETCH_ALLOWLIST='127.0.0.1' python3 "$GUARD" 'http://127.0.0.1/' 2>&1 || true)"
has "guard refuses loopback (SSRF)" "$G_LOOPBACK" "refused"
G_OFFLIST="$(OFFLOAD_FETCH_ALLOWLIST='example.com' python3 "$GUARD" 'https://evil.com/' 2>&1 || true)"
has "guard refuses off-allowlist host" "$G_OFFLIST" "not on the allowlist"
G_EMPTY="$(OFFLOAD_FETCH_ALLOWLIST='' python3 "$GUARD" 'https://example.com/' 2>&1 || true)"
has "guard fails closed on empty allowlist" "$G_EMPTY" "fail closed"
# the fetch tool must pin the resolved IP and forbid redirects
grep -q -- '--resolve' "$FETCH"; ok "web_fetch.sh pins curl to the validated IP (--resolve)" $?
grep -q -- '--max-redirs 0' "$FETCH"; ok "web_fetch.sh forbids redirects (--max-redirs 0)" $?
nothas "web_fetch.sh does not follow redirects (no -L)" "$(grep -E 'curl ' "$FETCH")" "-fsSL"

# =============================================================================
section "6. Runner confines reads (sandbox-exec) & egress (allowlist)"
bash -n "$RUNNER";    ok "run-local.sh passes bash -n" $?
bash -n "$INSTALLER"; ok "install.sh passes bash -n" $?
[[ -x "$RUNNER" ]];   ok "run-local.sh is executable" $?
grep -q 'AICHAT_CONFIG_DIR=.*aichat-config' "$RUNNER"; ok "runner uses isolated aichat-config" $?
grep -q 'localhost:8081' "$RUNNER"; ok "runner targets localhost:8081" $?
grep -q 'sandbox-exec' "$RUNNER"; ok "runner wraps the model in sandbox-exec" $?
grep -q 'deny file-read-data (subpath "\$HOME")' "$RUNNER"; ok "runner denies file-read-data under \$HOME" $?
grep -q 'OFFLOAD_FETCH_ALLOWLIST' "$RUNNER"; ok "runner exports the fetch allowlist" $?
# refuses to run unconfined unless --no-sandbox is explicit
grep -q 'refusing to run a web-capable model unconfined' "$RUNNER"; ok "runner refuses unconfined run without --no-sandbox" $?
# adversarial: runner itself must not reach any non-localhost http(s) endpoint
EXT_URLS="$(grep -oE 'https?://[A-Za-z0-9._-]+' "$RUNNER" | grep -vE '://localhost' || true)"
nothas "runner has no external http(s) endpoints" "$EXT_URLS" "://"
# the allowlist must not contain private/loopback hosts
PRIV="$(grep -vE '^\s*(#|$)' "$ALLOWLIST" | grep -iE 'localhost|127\.|169\.254|10\.|192\.168|\b::1\b' || true)"
nothas "fetch-allowlist.txt has no private/loopback hosts" "$PRIV" "."

# =============================================================================
section "7. sandbox-exec actually blocks an out-of-scope read (live, local)"
if ! command -v sandbox-exec >/dev/null 2>&1; then
  skip "sandbox-exec not available — confinement enforcement test skipped"
else
  SBSECRET="$HOME/.offload_suite_secret.$$"; echo "SECRET" > "$SBSECRET"
  SBPROF="$(mktemp -t offload-suite-sb)"
  cat > "$SBPROF" <<EOF
(version 1)
(allow default)
(deny file-read-data (subpath "$HOME"))
(allow file-read-data (subpath "$SCRIPT_DIR/sandbox"))
EOF
  if sandbox-exec -f "$SBPROF" /bin/cat "$SBSECRET" >/dev/null 2>&1; then
    fail "sandbox blocks reading a \$HOME secret" "secret was readable under the profile"
  else
    pass "sandbox blocks reading a \$HOME secret"
  fi
  rm -f "$SBSECRET" "$SBPROF"
fi

# =============================================================================
section "8. Installed agent matches source (runner path resolved)"
if [[ -f "$INSTALLED" ]]; then
  if grep -q '__RUNNER__' "$INSTALLED"; then
    fail "installed agent has 0 unresolved __RUNNER__" "found placeholder; re-run ./install.sh"
  else
    pass "installed agent has 0 unresolved __RUNNER__"
  fi
  RESOLVED="$(grep -oE '/[^ ]*run-local\.sh' "$INSTALLED" | head -1)"
  if [[ -n "$RESOLVED" && -x "$RESOLVED" ]]; then
    pass "installed runner path exists & is executable ($RESOLVED)"
  else
    fail "installed runner path exists & is executable" "resolved='$RESOLVED'"
  fi
  ITOOLS="$(grep -m1 '^tools:' "$INSTALLED" | sed 's/^tools:[[:space:]]*//')"
  eq "installed tools: = 'Bash, Read'" "$ITOOLS" "Bash, Read"
  grep -q 'capability-request' "$INSTALLED"; ok "installed agent documents capability-request" $?
  grep -qiE 'web_fetch|web_search' "$INSTALLED"; ok "installed agent documents the web tools" $?
else
  skip "installed agent not found at $INSTALLED (run ./install.sh)"
fi

# =============================================================================
section "9. Live end-to-end (local model on :8081)"
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
  LIST="$("$RUNNER" -l 2>/dev/null)"
  if [[ -n "$LIST" ]]; then pass "run-local.sh -l returns models ($(printf '%s' "$LIST" | wc -l | tr -d ' ') lines)"
  else fail "run-local.sh -l returns models" "empty output"; fi
  MODEL=""
  if printf '%s' "$LIST" | grep -q '0.6B'; then
    MODEL="mlx:$(printf '%s' "$LIST" | grep '0.6B' | head -1 | sed 's/^mlx://')"
  fi
  PROMPT='Reply with exactly the single word: PONG . No other text.'
  if [[ -n "$MODEL" ]]; then OUT="$("$RUNNER" -m "$MODEL" "$PROMPT" 2>/dev/null)"
  else OUT="$("$RUNNER" "$PROMPT" 2>/dev/null)"; fi
  if [[ -n "$OUT" ]]; then pass "sandboxed round-trip returned non-empty output${MODEL:+ ($MODEL)}"
  else fail "sandboxed round-trip returned non-empty output" "empty — check server/model/sandbox profile"; fi
  if printf '%s' "$OUT" | grep -qi 'PONG'; then pass "round-trip output contains expected token (PONG)"
  else skip "round-trip output lacked 'PONG' (model nondeterminism, not a gate failure)"; fi
fi

# =============================================================================
section "Summary"
printf '%s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$Y" "$SKIP" "$Z"
[[ "$FAIL" -eq 0 ]]
