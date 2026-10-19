#!/usr/bin/env bash
# plugin/guard/lib-tools.sh — the ONE external-tool resolver for the bash side
# (guard, session start); cli/paths.py find_tool() is the Python twin (review O3/F13).
#
#   kit_cfg_str <config-dir> <key>      → a top-level string from config.toml (before any [table])
#   kit_tools_dir <config-dir>          → config.toml `tools_dir` (~ expanded, absolute only), else ~/.local/bin
#   kit_tool_path <name> <config-dir>   → <tools_dir>/<name> when executable, else the absolute
#                                         `<name>_path` (dashes → _) recorded in config.toml, else rc 1
#
# NEVER the caller's PATH (review R3-1): `PATH=/tmp/x:$PATH git push` with a stub
# `gitleaks` that exits 0 would switch R1 off. tools_dir is where `kit setup --bin-dir`
# / `kit doctor --install` put the pinned, sha256-verified binaries; `<name>_path` is
# a PATH binary of the pinned version that setup / doctor --install found and
# recorded after a version check. Both live in config.toml, which the model cannot
# write (tool-breaker / protect-paths). Not found → the guard's R8 semantics.
kit_cfg_str() {
    sed -nE '/^[[:space:]]*\[/q; s/^[[:space:]]*'"$2"'[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$1/config.toml" 2>/dev/null | head -n 1
}
kit_tools_dir() {
    local d
    d="$(kit_cfg_str "$1" tools_dir)"
    [[ "$d" == "~" || "$d" == "~/"* ]] && d="${HOME:-/nonexistent}${d:1}"
    [[ "$d" == /* ]] || d=""          # a relative dir would depend on the hook's cwd
    printf '%s\n' "${d:-${HOME:-/nonexistent}/.local/bin}"
}
kit_tool_path() {
    local d p
    d="$(kit_tools_dir "$2")"
    [[ -f "$d/$1" && -x "$d/$1" ]] && { printf '%s\n' "$d/$1"; return 0; }
    p="$(kit_cfg_str "$2" "${1//-/_}_path")"
    [[ "$p" == "~/"* ]] && p="${HOME:-/nonexistent}${p:1}"
    [[ "$p" == /* && -f "$p" && -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    return 1
}
