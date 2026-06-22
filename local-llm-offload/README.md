# local-offload — a Claude Code subagent that offloads to your local LLM

Lets the cloud Claude session hand **self-contained, lower-priority tasks** to
your on-device LLM (served by `mlx_lm.server` on `:8081`) to save tokens/cost.
The subagent's orchestrator runs on cheap **Haiku**; the actual work is done by
the local model via one of two clients — see **Two client paths** below.

## Files
| File | Purpose |
|------|---------|
| `local-offload.md`        | The Claude Code subagent definition (source; `__RUNNER__` is filled in at install). |
| `post-local.py`           | **Simplified** direct-HTTP client (no `aichat`, no tools). Default for text-only tasks + all eval generation. |
| `run-local.sh`            | Wrapper that sends a prompt to a local model via `aichat` (the **tool-calling** path), confining the model's file reads with `sandbox-exec`. Also usable by hand. |
| `aichat-config/`          | Isolated `aichat` config used only by the wrapper. |
| `aichat-config/config.yaml` | Local-only client; non-mutating tools (`fs_ls`, `fs_cat`, `web_search_tavily`, guarded `web_fetch`, `load_skill`). |
| `tools/load_skill.sh`     | Read-only tool: return an agent skill's `SKILL.md` by name (or list skills) from `OFFLOAD_SKILL_ROOTS`; name-sanitized against path traversal. |
| `aichat-config/functions` | Symlink → `~/llm-functions` (the built tool set). |
| `tools/url_guard.py`      | SSRF + allowlist guard for `web_fetch` (the security core; unit-tested). |
| `tools/web_fetch.sh`      | Hardened single-URL fetch tool: allowlist + SSRF guard, pinned IP, no redirects. |
| `tools/fetch-allowlist.txt` | Host suffixes the model may `web_fetch` (override with `OFFLOAD_FETCH_ALLOWLIST`). |
| `tools/test-url-guard.sh` | Offline unit tests for the SSRF/allowlist guard. |
| `install.sh`              | Installs the agent into `~/.claude/agents` (or `--project`); also activates the git pre-commit hook. |
| `mlx-server.sh`           | **Canonical** launcher for the local model server on `:8081` (Apple Silicon / `mlx_lm`). Symlinked as `~/.local/bin/mlx-server.sh`. Holds the **single source of truth for model aliases** (`--resolve`/`--list-aliases`); also used by the batch runner and the skill-eval scripts. Aliases incl. `gemma12` (default). |
| `mlx-lib.sh`              | Sourceable lifecycle helpers (`mlx_resolve`/`mlx_start`/`mlx_stop`/`mlx_wait_up`) extracted for reuse. Eval-agnostic. Symlinked as `~/.local/bin/mlx-lib.sh`. |
| `run-batch.sh`            | Run one model over **many prompt files, sequentially** (single-GPU), managing the server's lifecycle. The generic batch tool; see **Batch a local model**. |
| `sync-models.sh`          | Rewrites the `models:` block in `aichat-config/config.yaml` from the live server. |
| `test-suite.sh`           | E2E / invariant tests that verify the gate is intact (see **Testing**). |
| `hooks/pre-commit`        | Tracked git hook that runs the suite (`--no-live`) on every commit. |

## Prerequisites & first-time setup
You need three things on your machine; the agent itself ships here.

1. **A local model server on `:8081`** (OpenAI-compatible). On Apple Silicon:
   ```bash
   pip install mlx-lm
   ./mlx-server.sh                 # serves mlx-community/Qwen3-14B-4bit on :8081
   ```
   On other hardware, run any OpenAI-compatible server on `:8081` instead
   (llama.cpp's `llama-server`, vLLM, Ollama's OpenAI endpoint, …).

2. **`aichat`** — the client the wrapper drives: <https://github.com/sigoden/aichat>.

3. **The tool set** built via `llm-functions`: read-only `fs_ls`/`fs_cat`, plus
   the model's **guarded web tools** `web_search_tavily` and `web_fetch`:
   ```bash
   git clone --depth 1 https://github.com/sigoden/llm-functions.git ~/llm-functions
   cd ~/llm-functions
   printf '%s\n' fs_ls.sh fs_cat.sh web_search_tavily.sh web_fetch.sh > tools.txt
   argc build                                     # generates functions.json + bin/
   ```
   Then point this repo's isolated config at that tool set (the symlink is
   git-ignored because it's an absolute local path):
   ```bash
   ln -s ~/llm-functions <repo>/local-llm-offload/aichat-config/functions
   ```
   `install.sh` copies the **hardened** `web_fetch.sh` + `url_guard.py` into the
   build for you and adds the two web tools to `tools.txt` (it won't remove
   anything else you build there). For `web_search`, set `TAVILY_API_KEY` in your
   environment.
   > Do **not** add `fs_write`/`fs_rm`/`fs_patch` (mutating) or
   > `fetch_url_via_curl`/`fetch_url_via_jina` (UNguarded arbitrary fetch) to the
   > offload model. The isolated `use_tools:` line is what restricts the model to
   > read-only fs + the *guarded* web tools; writes go through the orchestrator
   > (see `ORCHESTRATION.md` + `offload-policy.json`), and `web_fetch` is allowed
   > only via the allowlist/SSRF guard in `tools/`.

Once the server is up:
```bash
./sync-models.sh    # write the served models into aichat-config/config.yaml
./run-local.sh -l   # sanity-check: list models the server reports
```

## Install
```bash
./install.sh            # global: ~/.claude/agents/local-offload.md
./install.sh --project  # this repo: ./.claude/agents/local-offload.md
```
Then in Claude Code, ask it to *"offload this to the local model"*, or invoke
the `@local-offload` subagent directly. Claude may also auto-delegate based on
the agent's description.

`install.sh` also activates the git pre-commit hook
(`git config core.hooksPath hooks`) — see **Testing**.

## Testing
`test-suite.sh` checks the security invariants that keep the gate real: the
worker holds no write/web tools, the policy still gates writes/web, the gate's
own config is protected, the isolated `aichat` config is read-only, the
installed agent matches source, and (if `:8081` is up) a real prompt
round-trips end-to-end. Run it after any change to the agent, policy, runner,
or `aichat` config.

```bash
./test-suite.sh            # full suite; live tests auto-skip if :8081 is down
./test-suite.sh --no-live  # static/security invariants only (no model server)
./test-suite.sh --live     # treat a down server as a FAILURE, not a skip
```
Exit code is `0` only if nothing FAILED (skips don't fail it), so it drops
straight into CI or a hook.

**Pre-commit hook.** `hooks/pre-commit` runs `./test-suite.sh --no-live` on
every commit and blocks it if any invariant fails, so a weakened gate can't be
committed. It's tracked in-repo and activated by `install.sh` (or manually:
`git config core.hooksPath hooks`). It skips live tests so commits never depend
on the local server being up. Bypass in a pinch with `git commit --no-verify`.

## Two client paths
Pick the client by whether the local model needs **tools / function calling**:

| Client | Deps | Tools? | Use for |
|--------|------|--------|---------|
| **`post-local.py`** | mlx-lm + Python stdlib only | none | **The default — fully self-contained.** Text-only, self-contained prompts: drafting, summarizing, eval generation. Plain HTTP to `:8081`; no `function_calling`, so no tool-call aborts, and it rides the server's prompt-cache prefix reuse (a shared leading prefix is prefilled once, then near-free). |
| **`run-local.sh`** (aichat) | `aichat` + `llm-functions` tool build | `fs_ls`/`fs_cat` + guarded `web_search`/`web_fetch` + `load_skill` | **When the local model needs tools** — read files itself mid-task, search/fetch the web, or load an agent skill by name. Runs sandbox-confined via `aichat`'s isolated config. |

**Rule of thumb: use `post-local.py` unless you need tool/function calling.**
The simple path depends on nothing but the mlx-lm server you already run — no
`aichat` install, no `llm-functions`/`argc` tool build, no separate client
config. Only reach for `run-local.sh` when the local model genuinely needs the
`fs_*` tools; Qwen models in particular reflex to emit `fs_ls` calls that abort a
tools-enabled run with empty output, which is the other reason the no-tools path
is the default. Both clients take the same core flags (`-m`, `-f`, `-l`) and
talk only to `:8081`; the eval tooling (`run-eval-*.sh`) uses `post-local.py`.

## Use the wrapper standalone
```bash
./run-local.sh "Draft a conventional-commit message for: add tilde expansion to fs tools"
./run-local.sh -m mlx:mlx-community/Qwen3-8B-4bit "Explain this code" -f ./mlx-server.sh
./run-local.sh -l            # list models served on :8081 right now
echo "summarize" | ./run-local.sh
```

## Configure: models & aliases
`mlx-server.sh` is the **single source of truth** for short alias → full model
id. Every other tool (the batch runner, `mlx-lib.sh`, and any external consumer
like the skill-eval scripts) resolves aliases through it instead of hardcoding
ids — so when the served model set changes you edit **one** place.

```bash
./mlx-server.sh --list-aliases        # alias  full-id   (one per line)
./mlx-server.sh --resolve gemma12     # -> rajaschitnis/gemma-4-12b-it-text-only-4bit-mlx
./mlx-server.sh --resolve org/Foo-4bit  # any value with '/' passes through unchanged
```

- **Add / change / remove a model:** edit the `alias_table` heredoc near the top
  of `mlx-server.sh`. That's the only place ids live. (Per-model launch tweaks —
  prompt-cache reservation, `enable_thinking` — are the two `case "$MODEL"`
  blocks just below it.)
- **Default model:** the first positional arg to `mlx-server.sh` (default
  `gemma12`). For the offload *agent's* default, edit `model:` in
  `aichat-config/config.yaml` (or pass `-m`).
- **Reuse from your own scripts:** `source mlx-lib.sh` (or
  `~/.local/bin/mlx-lib.sh`) to get `mlx_resolve`, `mlx_start <alias>`,
  `mlx_wait_up <id-substr>`, and `mlx_stop` without re-implementing any of it.
  `mlx-lib.sh` finds its sibling `mlx-server.sh` automatically (clone or symlink).

## Batch a local model (`run-batch.sh`)
Run **many prompt files through one model, in order**, with the server brought
up and torn down for you. Because the single GPU forces sequential calls and the
inputs share a leading prefix, the server's prompt cache makes repeat runs cheap
(keep each input's variable part *late*). This is the generic, eval-agnostic
batch pattern — domain-specific harnesses (e.g. skill evals) layer their own
discovery/output on top of `mlx-lib.sh` rather than bending this tool.

```bash
./run-batch.sh qwen14 prompts/*.txt                       # answers to stdout
./run-batch.sh -o out -p "Summarize in 3 bullets." gemma12 notes/*.md
./run-batch.sh --keep-server gemma12 a.txt b.txt          # reuse a running :8081
```

| Option | Effect |
|--------|--------|
| `-o, --out-dir DIR` | Write `<input>.answer.md` per file into `DIR` (default: stdout). |
| `-p, --prompt TEXT` | Instruction appended after each file's contents. |
| `-m, --max-tokens N` / `-t, --temp T` | Forwarded to `post-local.py`. |
| `--keep-server` | Use an already-running `:8081` as-is (skip stop/start). |

By default it `mlx_stop` → `mlx_start <model>` → `mlx_wait_up` → POSTs each file
via `post-local.py` → `mlx_stop` on exit (an `EXIT` trap, so the server is
always cleaned up). Exit code is nonzero if any file failed.

## Safety / design notes
- **Local only.** The offload config has no cloud client — it cannot spend
  cloud tokens.
- **Non-mutating tools.** The model gets `fs_ls`/`fs_cat` (read-only), guarded web
  (`web_search_tavily`, `web_fetch`), and `load_skill` (read a `SKILL.md` by name).
  Mutating fs tools and the *unguarded* `fetch_url_via_*` tools are deliberately not
  enabled. Writes go through the orchestrator (capability-request). To give file
  context, use `-f`.
- **Skills are loadable, read-only.** `load_skill` reads only from
  `OFFLOAD_SKILL_ROOTS` (default `~/.claude/skills`, `~/.agents/skills`), which the
  sandbox re-allows for reading; names are sanitized to a slug so `..`/path traversal
  is refused. Skill text is treated as non-secret — keep secrets out of skill files.
  Only the `run-local.sh` (aichat) path has tools; `post-local.py` has none.
- **Per-workspace skills.** Pass `--skill-root <dir>` (repeatable) to scope a run to a
  workspace's skills, e.g. `./run-local.sh --skill-root "$PWD/.claude/skills" "<task>"`.
  Those dirs are prepended ahead of `OFFLOAD_SKILL_ROOTS` (a workspace skill shadows a
  same-named user one) and added to the sandbox read-allow set automatically. Add
  `--skill-root-only` to use **only** those dirs (no fall-through to the user defaults) —
  for testing a skill in isolation. It requires at least one `--skill-root`.
- **Reads are confined.** `run-local.sh` wraps the model in `sandbox-exec`
  (macOS Seatbelt): `file-read-data` under `$HOME` is denied, re-allowed only for
  `aichat-config/`, the tool build, `tools/`, caches, and the **per-task** roots
  (the `-f` files + any `--read-root` dirs). So a web-capable model can't read
  ambient files (`~/.ssh`, `~/.aws`, `~/Code` source) to exfiltrate them. The
  runner refuses to run unconfined unless you pass `--no-sandbox`.
- **Web egress is bounded.** `web_fetch` only reaches hosts on
  `tools/fetch-allowlist.txt` (override: `OFFLOAD_FETCH_ALLOWLIST`); any URL that
  resolves to a private/loopback/link-local address is refused, curl is pinned to
  the validated IP (no DNS-rebinding), and redirects are not followed
  (`tools/url_guard.py`). `web_search` (Tavily) needs `TAVILY_API_KEY`.
- **Residual channels** (accepted): the search *query string* and the *prompt*
  the orchestrator hands the model are still outbound paths — keep task prompts
  free of secrets.
- **Stateless.** The local model can't see the Claude conversation; the agent
  always sends a fully self-contained prompt.
- **Failure is loud.** If `:8081` is down or output is empty, the agent reports
  it rather than silently doing the task in cloud Claude.

## Customize
- Model aliases (add/remove/rename, default model): see **Configure: models &
  aliases** above — they live only in `mlx-server.sh`'s `alias_table`.
- Sync available models: the `models:` registry in `aichat-config/config.yaml` is
  generated from the live server — run `./sync-models.sh` after the served model
  set changes (it reads `:8081/v1/models` and rewrites that block).
- Change the default model: edit `model:` in `aichat-config/config.yaml` or pass
  `-m` to the wrapper.
- Add tools: they must be non-mutating and listed in `use_tools:`; build them in
  `~/llm-functions` (`argc build`). See **Prerequisites & first-time setup**.
- Web allowlist: edit `tools/fetch-allowlist.txt` (host suffixes) or set
  `OFFLOAD_FETCH_ALLOWLIST`. Never add private/loopback hosts — they're refused
  anyway by `tools/url_guard.py`.
- Requires a model server on `:8081` (see `./mlx-server.sh` and
  **Prerequisites & first-time setup**).
