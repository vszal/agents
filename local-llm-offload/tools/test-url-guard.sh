#!/usr/bin/env bash
#
# test-url-guard.sh — offline unit tests for the web_fetch SSRF/allowlist guard.
# No network egress and no model server needed: every case is decided by
# url_guard.py from the URL + allowlist alone (DNS may be hit for hostname cases,
# so those use names that resolve to fixed addresses or are covered by IP-literal
# cases that need no DNS).
#
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/url_guard.py"

PASS=0; FAIL=0
if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Z=$'\033[0m'; else G=""; R=""; Z=""; fi

# allow "desc" ALLOWLIST URL  — expect ACCEPT (exit 0, prints a pin line)
allow() {
  local out; out="$(OFFLOAD_FETCH_ALLOWLIST="$2" python3 "$GUARD" "$3" 2>/dev/null)"
  if [[ $? -eq 0 && -n "$out" ]]; then PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"
  else FAIL=$((FAIL+1)); printf '  %sFAIL%s %s (expected ACCEPT, got refusal)\n' "$R" "$Z" "$1"; fi
}
# deny "desc" ALLOWLIST URL  — expect REFUSE (non-zero, nothing on stdout)
deny() {
  local out; out="$(OFFLOAD_FETCH_ALLOWLIST="$2" python3 "$GUARD" "$3" 2>/dev/null)"
  if [[ $? -ne 0 && -z "$out" ]]; then PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"
  else FAIL=$((FAIL+1)); printf '  %sFAIL%s %s (expected REFUSE, got accept: %s)\n' "$R" "$Z" "$1" "$out"; fi
}

echo "== allowlist =="
deny  "empty allowlist denies all (fail closed)"     ""             "https://example.com/"
deny  "host not on allowlist"                        "example.com"  "https://evil.com/"
allow "exact host on allowlist"                      "example.com"  "https://example.com/"
allow "dotted subdomain of allowlisted host"         "example.com"  "https://www.example.com/x"
deny  "suffix-but-not-dotted is NOT a match"         "example.com"  "https://notexample.com/"
deny  "evilexample.com is not example.com"           "example.com"  "https://evilexample.com/"

echo "== scheme / authority bypasses =="
deny  "file:// scheme refused"                       "example.com"  "file:///etc/passwd"
deny  "gopher:// scheme refused"                     "example.com"  "gopher://example.com/"
deny  "userinfo@ bypass refused"                     "example.com"  "https://example.com@evil.com/"
deny  "userinfo@ (allowed as creds) refused"         "evil.com"     "https://example.com@evil.com/"

echo "== SSRF: private / loopback / link-local IP literals =="
deny  "loopback 127.0.0.1"                           "127.0.0.1"    "http://127.0.0.1/"
deny  "loopback ipv6 ::1"                            "::1"          "http://[::1]/"
deny  "private 10/8"                                 "10.0.0.5"     "http://10.0.0.5/"
deny  "private 192.168/16"                           "192.168.1.1"  "http://192.168.1.1/"
deny  "private 172.16/12"                            "172.16.9.9"   "http://172.16.9.9/"
deny  "link-local / cloud metadata 169.254.169.254"  "169.254.169.254" "http://169.254.169.254/latest/meta-data/"
deny  "unspecified 0.0.0.0"                          "0.0.0.0"      "http://0.0.0.0/"
deny  "ipv4-mapped ipv6 loopback"                    "::ffff:127.0.0.1" "http://[::ffff:127.0.0.1]/"
deny  "ula ipv6 fc00::/7"                            "fc00::1"      "http://[fc00::1]/"
deny  "link-local ipv6 fe80::/10"                    "fe80::1"      "http://[fe80::1]/"

echo
printf '%s%d passed%s, %s%d failed%s\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z"
[[ "$FAIL" -eq 0 ]]
