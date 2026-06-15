# Orchestration playbook — gating the offload agent's privileged requests

For the **orchestrator**: the cloud Claude session that spawns the `local-offload`
subagent. It defines how to safely fulfill privileged actions the local model cannot
perform itself. (Autonomous/cron mode is a *separate* design — see "Not this" below.)

## Roles

- **Authority** — the human. Owns `offload-policy.json`. Approves `ask` requests.
- **Orchestrator** — the cloud Claude session (you, reading this). Holds the privileged
  tools (Write/Edit; web later). Reviews requests, applies policy, executes, loops results back.
- **Worker** — the `local-offload` subagent (Haiku dispatcher) + the on-device model it
  calls via `run-local.sh`. The local model has **read-only fs** (`fs_ls`, `fs_cat`) and
  **guarded web** (`web_search_tavily`, hardened `web_fetch`); the subagent itself has only
  `Bash, Read`. Neither can write files — that they can only *request*.

The boundary now has two parts:
- **Writes**: enforced by **tool absence** — there is no write/bash tool for the worker to
  misuse; the orchestrator is the only party that can write.
- **Web**: enforced by **guards + a sandbox**, not absence. `web_fetch` is allowlist- and
  SSRF-restricted (`tools/url_guard.py`), and `run-local.sh` confines the model's file
  reads with `sandbox-exec` so a web-capable model can't read the user's private files to
  exfiltrate them. The orchestrator no longer mediates web.

## Protocol

The local model is told (via the agent prompt) to emit privileged needs as fenced JSON
blocks tagged `capability-request`, which surface through the subagent's reply:

```capability-request
{ "id": "r1", "capability": "write", "path": "sandbox/out.md", "content": "...full file body..." }
```

Capability today (mediated):
- `write` — needs `path` + complete `content`. The worker has no write tool, so this is
  the one thing it must request and YOU fulfill.

Web is **no longer** a capability-request — the on-device model has its own guarded
`web_search` / `web_fetch` and calls them directly (policy `decision: direct`). You don't
run searches or fetches on its behalf; the guards + sandbox (see Worker role) keep it safe.
If a fetch fails because the host isn't on `tools/fetch-allowlist.txt`, that's the user's
call to widen — don't fetch it yourself to route around the guard.

## Fulfillment loop

1. **Parse** every `capability-request` block from the worker's reply.
2. **Resolve** the `write` request's `decision` in `offload-policy.json`:
   - `allow`        → proceed (still honoring `deny_paths`).
   - `ask`          → escalate to the human (AskUserQuestion or y/N), showing the target
     path + a content preview.
   - `deny`         → refuse; tell the worker why.
   - **write override:** if `path` is under any `auto_allow_under` prefix AND not under
     any `deny_paths` entry, treat as `allow` without asking.
   - **deny_paths are absolute:** never write them on the worker's behalf, even if the
     human says yes in passing — confirm explicitly out-of-band first.
   - If the policy file is missing/unparseable, use `missing_policy_default` (`ask`).
3. **Execute** the approved write with your Write/Edit tools.
4. **Audit** — append one line per request to the `audit_log` path:
   `ISO8601 | id | capability | decision | target | approver(auto|human)`.
5. **Return** results to the worker (continue the same subagent via SendMessage):

```capability-result
{ "id": "r1", "status": "fulfilled", "path": "sandbox/out.md" }
{ "id": "r2", "status": "denied", "reason": "path under deny_paths" }
```

6. Repeat until the worker emits no more requests, then surface its final output.

## Hard rules

- Never add Write/Edit tools to the worker's `tools:` list. Writes stay mediated by you.
- For the model's `aichat-config`, expose only **non-mutating** tools: read-only fs plus
  the *guarded* web tools. Never enable `fs_write`/`fs_rm`/`fs_patch`, and never enable the
  **unguarded** `fetch_url_via_curl`/`fetch_url_via_jina` — `web_fetch` (with its allowlist
  + SSRF guard) is the only fetch tool allowed.
- Never disable the read-confinement sandbox for web-enabled runs (`--no-sandbox` is for
  trusted, local-only debugging). It's what stops a web-capable model from exfiltrating the
  user's files.
- Never write `deny_paths` for the worker; they protect the gate's own config — including
  `tools/` (the SSRF guard) and `aichat-config/`.
- Keep the fetch allowlist (`tools/fetch-allowlist.txt`) tight and free of private/loopback
  hosts; widening it is the human's decision.

## Not this (autonomous/cron mode)

This playbook is for **supervised** runs where a human can answer `ask`. A cron job has
nobody to ask, so the same gate can't apply — `ask` would have to degrade to deny. The
autonomous design (deterministic guardrailed tools + `sandbox-exec` kernel confinement +
budgets) is deferred and not built here.
