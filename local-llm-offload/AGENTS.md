# AGENTS.md — local-llm-offload

Orientation for an agent working in this directory. Read this before changing
anything; the security boundary here is load-bearing and tested.

## What this is
A Claude Code subagent (`local-offload`) that hands **self-contained, lower-priority
tasks** to an on-device LLM (served by `mlx_lm.server` on `:8081`) to save cloud
cost/tokens. A cheap **Haiku** dispatcher forwards a fully-specified prompt to the
local model and returns its output — it does not solve the task itself.

## Two client paths (pick by whether the model needs tools)
- **`post-local.py`** — default. Plain HTTP to `:8081`, no `aichat`, no tools. For
  text-only self-contained prompts (drafting, summarizing, eval generation).
- **`run-local.sh`** — the tool-calling path via `aichat`. Use when the model must
  read files itself, or **search/fetch the web**. Runs the model under `sandbox-exec`.

## The trust model (this is the point — don't weaken it)
The local model is treated as **untrusted**. It has only **non-mutating** tools:
`fs_ls`/`fs_cat` (read-only) + guarded `web_search_tavily` + guarded `web_fetch`.
Two boundaries keep that safe:

1. **Reads are confined.** `run-local.sh` wraps the model in a Seatbelt profile:
   `allow default`, then **deny `file-read-data` under `$HOME`**, re-allowing only
   `aichat-config/`, the tool build, `tools/`, caches, and the **per-task** roots
   (`-f` files + `--read-root` dirs). So a web-capable model can't read your private
   files (`~/.ssh`, `~/.aws`, `~/Code` source) to exfiltrate them. It refuses to run
   unconfined unless `--no-sandbox` is passed.
2. **Web egress is guarded.** `tools/url_guard.py` enforces an http(s)-only host
   **allowlist** (`tools/fetch-allowlist.txt`), refuses any URL that resolves to a
   private/loopback/link-local/metadata address (SSRF), pins curl to the validated
   IP (no DNS-rebinding), and forbids redirects.

**Writes are still orchestrator-mediated**: the worker has no write/bash tool. It
emits a fenced `capability-request{write,...}` block; the orchestrator (cloud Claude)
applies `offload-policy.json` and fulfills/asks/denies. Web is NOT a capability-request
anymore — the model calls it directly.

Residual outbound channels (accepted): the search *query string* and the *prompt* the
orchestrator hands the model. Keep task prompts free of secrets.

## Key files
| File | Role |
|------|------|
| `local-offload.md`        | Subagent definition (source; `__RUNNER__` resolved at install). Tools: `Bash, Read`; model: haiku. |
| `run-local.sh`            | aichat wrapper; builds the sandbox profile; exports the fetch allowlist. |
| `post-local.py`           | No-tools direct-HTTP client (default path). |
| `aichat-config/config.yaml` | Isolated aichat config. `use_tools:` is what restricts the model's tools. |
| `aichat-config/functions` | Symlink → `~/llm-functions` (git-ignored; recreate per README). |
| `tools/url_guard.py`      | SSRF + allowlist guard — the security core. |
| `tools/web_fetch.sh`      | Hardened single-URL fetch (uses the guard). |
| `tools/fetch-allowlist.txt` | Allowed `web_fetch` host suffixes. |
| `offload-policy.json`     | Human-owned policy: write/web/bash decisions + `deny_paths`. |
| `ORCHESTRATION.md`        | Playbook for the orchestrator (how to fulfill write requests). |
| `test-suite.sh`           | Invariant + E2E tests; `hooks/pre-commit` runs it `--no-live`. |
| `install.sh`              | Installs the agent + provisions the web tools into `~/llm-functions`. |
| `mlx-server.sh`           | Launches the local model server on `:8081`. |

## Rules for agents editing this directory
- **Run `./test-suite.sh` after any change** to the agent, policy, runner, config, or
  `tools/`. The pre-commit hook runs `--no-live` and blocks a weakened gate.
- Expose only **non-mutating** tools in `use_tools:`. Never add `fs_write`/`fs_rm`/
  `fs_patch`, and never the **unguarded** `fetch_url_via_curl`/`fetch_url_via_jina` —
  `web_fetch` is the only fetch tool.
- Never disable the sandbox for web-enabled runs. Never write `deny_paths` (they protect
  this gate's own config, including `tools/`). Keep the allowlist free of private hosts.
- Prerequisites for the live path: `mlx_lm.server` on `:8081`, `aichat` + the
  `~/llm-functions` build, and `TAVILY_API_KEY` for `web_search`. See `README.md`.

## Quick start
```bash
./mlx-server.sh                 # serve a model on :8081
./run-local.sh -l               # list served models
./run-local.sh "Draft a commit message for: add tilde expansion"
./test-suite.sh                 # full suite (live tests auto-skip if :8081 down)
```
See `README.md` for full setup, `ORCHESTRATION.md` for the orchestrator's role.
