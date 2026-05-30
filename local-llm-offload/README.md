# local-offload — a Claude Code subagent that offloads to your local LLM

Lets the cloud Claude session hand **self-contained, lower-priority tasks** to
your on-device LLM (served by `mlx_lm.server` on `:8081`) to save tokens/cost.
The subagent's orchestrator runs on cheap **Haiku**; the actual work is done by
the local model via `aichat`.

## Files
| File | Purpose |
|------|---------|
| `local-offload.md`        | The Claude Code subagent definition (source; `__RUNNER__` is filled in at install). |
| `run-local.sh`            | Wrapper that sends a prompt to a local model via `aichat`. Also usable by hand. |
| `aichat-config/`          | Isolated `aichat` config used only by the wrapper. |
| `aichat-config/config.yaml` | Local-only client; **read-only** tools (`fs_ls`, `fs_cat`). |
| `aichat-config/functions` | Symlink → `~/llm-functions` (the built tool set). |
| `install.sh`              | Installs the agent into `~/.claude/agents` (or `--project`); also activates the git pre-commit hook. |
| `test-suite.sh`           | E2E / invariant tests that verify the gate is intact (see **Testing**). |
| `hooks/pre-commit`        | Tracked git hook that runs the suite (`--no-live`) on every commit. |

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

## Use the wrapper standalone
```bash
./run-local.sh "Draft a conventional-commit message for: add tilde expansion to fs tools"
./run-local.sh -m mlx:mlx-community/Qwen3-8B-4bit "Explain this code" -f ../mlx-server.sh
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
  `~/llm-functions` (`argc build`).
- Requires `mlx_lm.server` running on `:8081` (see `../mlx-server.sh`).
