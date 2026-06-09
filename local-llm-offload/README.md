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
| `run-local.sh`            | Wrapper that sends a prompt to a local model via `aichat` (the **tool-calling** path). Also usable by hand. |
| `aichat-config/`          | Isolated `aichat` config used only by the wrapper. |
| `aichat-config/config.yaml` | Local-only client; **read-only** tools (`fs_ls`, `fs_cat`). |
| `aichat-config/functions` | Symlink → `~/llm-functions` (the built tool set). |
| `install.sh`              | Installs the agent into `~/.claude/agents` (or `--project`); also activates the git pre-commit hook. |
| `mlx-server.sh`           | **Canonical** launcher for the local model server on `:8081` (Apple Silicon / `mlx_lm`). Symlinked as `~/.local/bin/mlx-server.sh`; also used by the skill-eval scripts. Aliases incl. `gemma12` (default). |
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

3. **The `fs_*` tool set** (`fs_ls`, `fs_cat`) built via `llm-functions`. These
   are the only tools the local model gets, and they're **read-only**:
   ```bash
   git clone --depth 1 https://github.com/sigoden/llm-functions.git ~/llm-functions
   cd ~/llm-functions
   printf '%s\n' fs_ls.sh fs_cat.sh > tools.txt   # read-only tools only
   argc build                                     # generates functions.json + bin/
   ```
   Then point this repo's isolated config at that tool set (the symlink is
   git-ignored because it's an absolute local path):
   ```bash
   ln -s ~/llm-functions <repo>/local-llm-offload/aichat-config/functions
   ```
   > Do **not** add `fs_write`/`fs_rm`/`fs_patch` here. In non-interactive
   > (agent) calls aichat's approval prompt is skipped, so any mutating tool
   > would run unguarded. Writes go through the orchestrator instead — see
   > `ORCHESTRATION.md` and `offload-policy.json`.

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
| **`run-local.sh`** (aichat) | `aichat` + `llm-functions` tool build | `fs_ls`/`fs_cat` (read-only) | **Only when the local model needs tools** — i.e. it must read files itself mid-task (agentic file lookup), via `aichat`'s isolated config. |

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

## Safety / design notes
- **Local only.** The offload config has no cloud client — it cannot spend
  cloud tokens.
- **Read-only tools.** Only `fs_ls`/`fs_cat` are exposed. The approval guards
  in `llm-functions` skip prompting when there's no TTY (as in an agent call),
  so write/delete tools are deliberately *not* enabled here. To give file
  context, prefer `-f <path>`.
- **Stateless.** The local model can't see the Claude conversation; the agent
  always sends a fully self-contained prompt.
- **Failure is loud.** If `:8081` is down or output is empty, the agent reports
  it rather than silently doing the task in cloud Claude.

## Customize
- Sync available models: the `models:` registry in `aichat-config/config.yaml` is
  generated from the live server — run `./sync-models.sh` after the served model
  set changes (it reads `:8081/v1/models` and rewrites that block).
- Change the default model: edit `model:` in `aichat-config/config.yaml` or pass
  `-m` to the wrapper.
- Add tools: they must be read-only and listed in `use_tools:`; build them in
  `~/llm-functions` (`argc build`). See **Prerequisites & first-time setup**.
- Requires a model server on `:8081` (see `./mlx-server.sh` and
  **Prerequisites & first-time setup**).
