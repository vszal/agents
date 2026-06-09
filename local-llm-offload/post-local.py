#!/usr/bin/env python3
"""post-local.py — Offload one task to the LOCAL mlx_lm server via plain HTTP.

Replaces the old aichat-based run-local.sh. The mlx_lm.server is pure inference
(no tool calling), so this just composes a chat request and prints the answer —
no function_calling, no fs tools, no 0-byte tool-abort surprises (the reason we
moved off aichat). Talks only to the local server on :8081.

Bonus: because we POST the full prompt directly, the server's prompt cache
(--prompt-cache-size) auto-reuses any shared leading prefix across sequential
calls — e.g. a skill-guidance block shared by every eval input (~30s first
call, ~2s thereafter). Keep the variable part (the user request) late in the
input and run calls sequentially to benefit.

Usage:
  post-local.py [-m MODEL] [-f FILE]... [--max-tokens N] [--temp T] [-s] "task"
  echo "task" | post-local.py [-m MODEL]
  post-local.py -l           # list models the server has loaded

Options:
  -m, --model MODEL    Served model id (a leading 'mlx:' is stripped). Default:
                       whatever the server reports at /v1/models.
  -f, --file  FILE     Prepend a file's contents as context (repeatable).
  --max-tokens N       Max generated tokens (default 1500).
  --temp T             Sampling temperature (default 0.3).
  -s, --stream         Stream tokens to stdout as they arrive.
  -l, --list           List loaded models and exit.
  -h, --help           This help.
"""
import sys, os, json, argparse, urllib.request, urllib.error

SERVER = "http://127.0.0.1:8081"

def die(msg, code=1):
    print(msg, file=sys.stderr); sys.exit(code)

def server_models():
    try:
        with urllib.request.urlopen(SERVER + "/v1/models", timeout=4) as r:
            return [m["id"] for m in json.load(r).get("data", [])]
    except Exception as e:
        die(f"error: local mlx server not reachable at {SERVER} ({e}); start it with mlx-server.sh", 3)

def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("-m", "--model", default="")
    p.add_argument("-f", "--file", action="append", default=[])
    p.add_argument("--max-tokens", type=int, default=1500)
    p.add_argument("--temp", type=float, default=0.3)
    p.add_argument("-s", "--stream", action="store_true")
    p.add_argument("-l", "--list", action="store_true")
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("prompt", nargs="*", default=[])
    a = p.parse_args()

    if a.help:
        print(__doc__); return
    if a.list:
        print("\n".join(server_models())); return

    model = a.model[4:] if a.model.startswith("mlx:") else a.model
    if not model:
        ms = server_models(); model = ms[0] if ms else die("error: no model on server", 3)

    parts = []
    for f in a.file:
        try:
            parts.append(open(os.path.expanduser(f)).read())
        except OSError as e:
            die(f"error: cannot read file {f}: {e}", 1)
    prompt = " ".join(a.prompt).strip()
    if not prompt and not sys.stdin.isatty():
        prompt = sys.stdin.read().strip()
    if prompt:
        parts.append(prompt)
    content = "\n\n".join(p for p in parts if p)
    if not content:
        die(__doc__, 1)

    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": a.max_tokens,
        "temperature": a.temp,
        "stream": a.stream,
    }).encode()
    req = urllib.request.Request(SERVER + "/v1/chat/completions", body,
                                 {"Content-Type": "application/json"})
    try:
        if a.stream:
            with urllib.request.urlopen(req, timeout=600) as r:
                for raw in r:
                    line = raw.decode("utf-8").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        delta = json.loads(data)["choices"][0]["delta"].get("content", "")
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
                    sys.stdout.write(delta); sys.stdout.flush()
                sys.stdout.write("\n")
        else:
            with urllib.request.urlopen(req, timeout=600) as r:
                msg = json.load(r)["choices"][0]["message"]
                # reasoning models (e.g. gemma-4) put the answer in content, but if
                # thinking wasn't disabled they may emit only `reasoning` — fall back to
                # it rather than KeyError-ing on a missing content key.
                print(msg.get("content") or msg.get("reasoning") or "")
    except urllib.error.URLError as e:
        die(f"error: request to {SERVER} failed: {e}", 3)

if __name__ == "__main__":
    main()
