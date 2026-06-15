#!/usr/bin/env bash
set -euo pipefail

# @describe Fetch the readable text of a single http(s) web page. The host must
# be on the offload fetch allowlist, redirects are NOT followed, and any URL that
# resolves to a private / loopback / link-local / metadata address is refused
# (SSRF guard). Use to read a specific, known page — not for general browsing.
# @option --url! The absolute http(s) URL to fetch.

# @env LLM_OUTPUT=/dev/stdout The output path
# @env OFFLOAD_FETCH_ALLOWLIST The space/comma/newline-separated allowed host
#   suffixes (e.g. "example.com docs.python.org"). Empty => every fetch is denied.

# Resolve next to this script even when invoked from the llm-functions bin dir.
GUARD="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/url_guard.py"

main() {
    local line host port ip
    # The guard validates scheme/allowlist/SSRF and prints  host\tport\tip  to pin.
    # On refusal it exits non-zero (reason on stderr) and we stop here — fail closed.
    if ! line="$(python3 "$GUARD" "$argc_url")"; then
        exit 1
    fi
    IFS=$'\t' read -r host port ip <<<"$line"

    # Pin curl to the validated IP (defeats DNS-rebinding) and forbid redirects
    # (a 3xx could otherwise point at an internal host after the check). Cap time
    # and size. Then strip HTML to readable text with stdlib only (no pandoc dep).
    curl -fsS --max-redirs 0 --max-time 20 --max-filesize 5000000 \
         --resolve "$host:$port:$ip" "$argc_url" \
      | python3 -c '
import sys, re
from html.parser import HTMLParser
class Strip(HTMLParser):
    SKIP = {"script", "style", "noscript", "head"}
    def __init__(self):
        super().__init__(); self.buf = []; self.depth = 0
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP: self.depth += 1
    def handle_endtag(self, tag):
        if tag in self.SKIP and self.depth: self.depth -= 1
    def handle_data(self, data):
        if not self.depth and data.strip(): self.buf.append(data.strip())
p = Strip(); p.feed(sys.stdin.read())
sys.stdout.write(re.sub(r"\n{3,}", "\n\n", "\n".join(p.buf)))
' >> "$LLM_OUTPUT"
}

eval "$(argc --argc-eval "$0" "$@")"
