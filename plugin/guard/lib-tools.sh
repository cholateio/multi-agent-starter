#!/usr/bin/env bash
# plugin/guard/lib-tools.sh — the ONE external-tool resolver for the bash side
# (guard, session start); cli/paths.py find_tool() is the Python twin (review O3/F13).
#
#   kit_tools_dir <config-dir>      → config.toml `tools_dir` (~ expanded), else ~/.local/bin
#   kit_tool_path <name> <config-dir> → <tools_dir>/<name> when executable, else PATH, else rc 1
#
# tools_dir is where `kit setup --bin-dir` / `kit doctor --install` put the pinned,
# sha256-verified binaries; it wins over PATH so a PATH entry cannot shadow them.
kit_tools_dir() {
    local d
    d="$(sed -nE '/^[[:space:]]*\[/q; s/^[[:space:]]*tools_dir[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$1/config.toml" 2>/dev/null | head -n 1)"
    [[ "$d" == "~" || "$d" == "~/"* ]] && d="${HOME:-/nonexistent}${d:1}"
    printf '%s\n' "${d:-${HOME:-/nonexistent}/.local/bin}"
}
kit_tool_path() {
    local d g
    d="$(kit_tools_dir "$2")"
    [[ -x "$d/$1" ]] && { printf '%s\n' "$d/$1"; return 0; }
    g="$(command -v "$1" 2>/dev/null)" && { printf '%s\n' "$g"; return 0; }
    return 1
}
