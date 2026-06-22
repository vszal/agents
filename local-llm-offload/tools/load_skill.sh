#!/usr/bin/env bash
set -euo pipefail

# @describe Load an agent "skill" (a reusable instruction set) by name and return
# its SKILL.md so you can follow it. Call with NO --name to LIST the available
# skills (slug + one-line description) for discovery; call with --name <slug> to
# print that one skill's full SKILL.md. Read-only: it never writes or fetches.
# @option --name The skill slug to load (e.g. token-efficiency). Omit to list all.

# @env LLM_OUTPUT=/dev/stdout The output path
# @env OFFLOAD_SKILL_ROOTS The space/colon/comma/newline-separated dirs to search;
#   each holds <slug>/SKILL.md. Unset => a built-in default of the user's skill dirs.

# Default roots if the runner didn't pin them. These hold read-only skill TEXT.
DEFAULT_ROOTS="$HOME/.claude/skills $HOME/.agents/skills"

# Normalize the (multi-delimiter) root list to whitespace-separated tokens.
roots() { printf '%s' "${OFFLOAD_SKILL_ROOTS:-$DEFAULT_ROOTS}" | tr ':,\n' '   '; }

# No name => discovery: one "slug<TAB>description" line per skill. A slug found in
# more than one root is listed once (first root wins, matching load_one's search).
list_skills() {
    local r d slug desc found=0 seen=" "
    {
        for r in $(roots); do
            [[ -d "$r" ]] || continue
            for d in "$r"/*/; do
                [[ -f "$d/SKILL.md" ]] || continue
                slug="$(basename "$d")"
                case "$seen" in *" $slug "*) continue ;; esac
                seen="$seen$slug "
                desc="$(sed -n 's/^description:[[:space:]]*//p' "$d/SKILL.md" | head -1)"
                printf '%s\t%s\n' "$slug" "$desc"
                found=1
            done
        done
    } >> "$LLM_OUTPUT"
    [[ "$found" -eq 1 ]] || { echo "load_skill: no skills found under: $(roots)" >&2; exit 1; }
}

# With a name => print that skill's SKILL.md body.
load_one() {
    local name="$1" r path real
    # Sanitize to a bare slug: no separators, no path traversal. Fail closed.
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || "$name" == *..* ]]; then
        echo "load_skill refused: invalid skill name '$name' (allowed: A-Z a-z 0-9 . _ -, no '..')" >&2
        exit 1
    fi
    for r in $(roots); do
        [[ -d "$r" ]] || continue
        path="$r/$name/SKILL.md"
        [[ -f "$path" ]] || continue
        # Defense in depth: the resolved file must still sit under this root.
        real="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/SKILL.md" || continue
        case "$real" in
            "$r"/*) cat "$path" >> "$LLM_OUTPUT"; return 0 ;;
        esac
    done
    echo "load_skill: skill '$name' not found under: $(roots)" >&2
    exit 1
}

main() {
    if [[ -z "${argc_name:-}" ]]; then list_skills; else load_one "$argc_name"; fi
}

eval "$(argc --argc-eval "$0" "$@")"
