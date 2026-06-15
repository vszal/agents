#!/usr/bin/env python3
"""url_guard.py — SSRF + allowlist guard for the local model's web_fetch tool.

Given a URL on argv[1], this validates it against the offload fetch policy and,
on success, prints a single line  `host\tport\tip`  that the caller pins curl to
(via `curl --resolve host:port:ip`). On any failure it writes a reason to stderr
and exits non-zero, so the fetch never runs.

Why this exists: the on-device model is read-only-fs + (now) web-capable, which
is an exfiltration/SSRF surface. This is the choke point that makes web_fetch
safe to hand the model directly:

  1. scheme must be http/https; no `user@host` userinfo (a classic allowlist
     bypass: http://allowed.com@evil.com/).
  2. host must match OFFLOAD_FETCH_ALLOWLIST (exact or dotted-suffix). Empty
     allowlist => deny everything (fail closed).
  3. the host is resolved HERE, and EVERY returned address must be public —
     private / loopback / link-local / reserved / multicast / unspecified are
     refused (covers 127/8, 10/8, 172.16/12, 192.168/16, 169.254/16 incl. the
     cloud-metadata IP, ::1, fc00::/7, fe80::/10, IPv4-mapped IPv6, ...).
  4. exactly one validated address is printed and pinned, so curl cannot be
     steered to a different (internal) IP via a DNS-rebinding race (TOCTOU).

The caller additionally passes `--max-redirs 0`, so a 3xx to an internal host
can't smuggle past this check after the fact.
"""
import ipaddress
import os
import socket
import sys
from urllib.parse import urlsplit


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    sys.stderr.write("web_fetch refused: %s\n" % msg)
    raise SystemExit(1)


def parse_allowlist(raw: str) -> list[str]:
    # space-, comma-, or newline-separated host suffixes; normalize + drop dots.
    return [a.strip().lower().lstrip(".") for a in raw.replace(",", " ").split() if a.strip()]


def host_allowed(host: str, allow: list[str]) -> bool:
    return any(host == d or host.endswith("." + d) for d in allow)


def is_public(ip: ipaddress._BaseAddress) -> bool:
    # Decode IPv4-mapped IPv6 (::ffff:a.b.c.d) back to v4 before judging it,
    # otherwise a mapped loopback could read as "global".
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_global and not (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    )


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        die("usage: url_guard.py <url>")
    url = argv[1]
    allow = parse_allowlist(os.environ.get("OFFLOAD_FETCH_ALLOWLIST", ""))

    p = urlsplit(url)
    if p.scheme not in ("http", "https"):
        die("scheme must be http/https (got %r)" % p.scheme)
    if "@" in p.netloc:
        die("userinfo (@) in authority is not allowed")
    host = (p.hostname or "").lower()
    if not host:
        die("no host in URL")
    try:
        port = p.port or (443 if p.scheme == "https" else 80)
    except ValueError:
        die("invalid port")

    if not allow:
        die("OFFLOAD_FETCH_ALLOWLIST is empty (fail closed)")
    if not host_allowed(host, allow):
        die("host %r is not on the allowlist" % host)

    # Resolve once, here, and require EVERY address to be public.
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        die("DNS resolution failed: %s" % e)

    pinned = None
    for _fam, _type, _proto, _canon, sa in infos:
        addr = ipaddress.ip_address(sa[0])
        if not is_public(addr):
            die("%s resolves to non-public address %s" % (host, addr))
        if pinned is None:
            pinned = sa[0]
    if pinned is None:
        die("no usable address for %s" % host)

    sys.stdout.write("%s\t%d\t%s\n" % (host, port, pinned))


if __name__ == "__main__":
    main(sys.argv)
