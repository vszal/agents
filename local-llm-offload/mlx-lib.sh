# mlx-lib.sh — sourceable lifecycle helpers for the local MLX server (:8081).
#
#   source /path/to/mlx-lib.sh      # or: source ~/.local/bin/mlx-lib.sh
#
# The reusable core extracted from the skill-eval scripts: alias resolution
# (delegated to mlx-server.sh, the single source of truth), server start/stop,
# and a readiness wait. It knows NOTHING about evals, prompts, or output
# layouts — callers supply those. Single-GPU: only one model loads at a time,
# so run generations strictly sequentially; never start two servers.
#
# Bash 3.2 compatible (macOS default). Talks only to 127.0.0.1:8081.
#
# API:
#   mlx_resolve <alias|full-id>     -> echoes full HF id (nonzero if unknown)
#   mlx_list_aliases                -> echoes the "alias full-id" table
#   mlx_stop                        -> kill server + clients, wait for VRAM to free
#   mlx_start <alias> [logfile]     -> nohup-launch the server (returns immediately)
#   mlx_wait_up <id-substr> [secs]  -> poll until /v1/models reports the model
#   mlx_up                          -> 0 if the server answers /v1/models
#
# Tunables (env): MLX_PORT (8081), MLX_WAIT_SECS (120), MLX_FREE_WIRED_KB (300000).

MLX_PORT="${MLX_PORT:-8081}"
_MLX_SERVER="http://127.0.0.1:${MLX_PORT}/v1/models"

# Locate the sibling mlx-server.sh: prefer one next to this lib (clone layout),
# fall back to the ~/.local/bin symlink, then $PATH. So cloners work without the
# symlinks, and symlinked installs resolve through the canonical file.
_mlx_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_mlx_self" ]; do
  _t=$(readlink "$_mlx_self"); case "$_t" in /*) _mlx_self="$_t" ;; *) _mlx_self="$(dirname "$_mlx_self")/$_t" ;; esac
done
_MLX_DIR="$(cd "$(dirname "$_mlx_self")" && pwd)"
if   [ -x "$_MLX_DIR/mlx-server.sh" ];        then _MLX_LAUNCH="$_MLX_DIR/mlx-server.sh"
elif [ -x "$HOME/.local/bin/mlx-server.sh" ]; then _MLX_LAUNCH="$HOME/.local/bin/mlx-server.sh"
else _MLX_LAUNCH="mlx-server.sh"; fi
unset _mlx_self _t

mlx_resolve()      { "$_MLX_LAUNCH" --resolve "$1"; }
mlx_list_aliases() { "$_MLX_LAUNCH" --list-aliases; }

mlx_up() { curl -s -m4 "$_MLX_SERVER" >/dev/null 2>&1; }

# Stop the server and any in-flight clients, then wait for wired Metal memory to
# fall (MLX weights live in wired buffers, so `ps` RSS lies — use vm_stat).
mlx_stop() {
  pkill -f mlx_lm.server 2>/dev/null
  pkill -f post-local 2>/dev/null
  pkill -f aichat 2>/dev/null
  until ! pgrep -f mlx_lm.server >/dev/null; do sleep 1; done
  local floor="${MLX_FREE_WIRED_KB:-300000}" w
  for _ in $(seq 1 15); do
    w=$(vm_stat | awk '/wired/{gsub(/\./,"",$4); print $4}')
    [ "${w:-999999}" -lt "$floor" ] && break
    sleep 2
  done
}

# Launch the server for an alias in the background. Returns immediately; pair
# with mlx_wait_up. Logs to $2 (default /tmp/mlx-<alias>.log).
mlx_start() {
  local alias="${1:?mlx_start needs a model alias}"
  local log="${2:-/tmp/mlx-${alias}.log}"
  nohup "$_MLX_LAUNCH" "$alias" "$MLX_PORT" >"$log" 2>&1 &
}

# Poll /v1/models until it reports a model whose id contains <id-substr>.
# Returns nonzero on timeout. Pass a basename of the resolved id, e.g.
# "$(basename "$(mlx_resolve qwen14)")".
mlx_wait_up() {
  local want="${1:?mlx_wait_up needs an id substring}"
  local secs="${2:-${MLX_WAIT_SECS:-120}}" tries=$(( secs / 2 ))
  for _ in $(seq 1 "$tries"); do
    curl -s -m2 "$_MLX_SERVER" 2>/dev/null | grep -q "$want" && return 0
    sleep 2
  done
  return 1
}
