#!/usr/bin/env bash
# plugin/guard/lib-tools.sh — the ONE external-tool resolver for the bash side
# (guard, session start); cli/paths.py find_tool() / tool_state() is the Python twin (review O3/F13).
#
#   kit_cfg_str <config-dir> <key>      → a top-level string from config.toml (before any [table])
#   kit_tools_dir <config-dir>          → config.toml `tools_dir` (~ expanded, absolute only), else ~/.local/bin
#   kit_sha256 <file>                   → its sha256 (/usr/bin/sha256sum, /bin/sha256sum, /usr/bin/shasum,
#                                         /usr/bin/openssl — absolute, never PATH), rc 1 when none works
#   kit_tool_resolve <name> <config-dir> → sets KIT_TOOL = the first of <tools_dir>/<name> and the
#                                         absolute `<name>_path` (dashes → _) whose sha256 equals the
#                                         recorded `<name>_sha256`; else KIT_TOOL="" + rc 1, and
#                                         KIT_TOOL_WHY = missing | unrecorded | replaced (no subshell)
#   kit_tool_path <name> <config-dir>   → the same, printed
#
# NEVER the caller's PATH (review R3-1): `PATH=/tmp/x:$PATH git push` with a stub
# `gitleaks` that exits 0 would switch R1 off. And never a binary by its location alone
# (review R4-1): tools_dir is writable by the owner's own processes, so `cp stub
# ~/.local/bin/gitleaks` would do the same. Trust = content: `kit setup` / `kit doctor
# --install` record `<name>_sha256` (the pin's sha256 of the binary) in config.toml only
# after installing the sha256-verified download, or after finding a binary whose sha256
# equals the pin — never by its version output. config.toml is a guard input the model
# cannot write (tool-breaker / protect-paths). No cache: hashing the ~22 MB gitleaks
# takes ~8 ms with SHA-NI (~50 ms without), and a cache would be one more file to forge.
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
kit_sha256() {
    # absolute paths from a fixed list (review R5-1): never PATH, never a shell function —
    # an exported `sha256sum` function printing the recorded pin would vouch for any stub
    local s h
    for h in /usr/bin/sha256sum /bin/sha256sum /usr/bin/shasum /usr/bin/openssl; do
        [[ -f "$h" && -x "$h" ]] || continue
        case "$h" in
            */sha256sum) s="$("$h" < "$1" 2>/dev/null)" ;;
            */shasum)    s="$("$h" -a 256 < "$1" 2>/dev/null)" ;;
            */openssl)   s="$("$h" dgst -sha256 -r < "$1" 2>/dev/null)" ;;
        esac
        s="${s%% *}"
        [[ "$s" =~ ^[0-9a-f]{64}$ ]] && { printf '%s\n' "$s"; return 0; }
    done
    return 1
}
# kit_tool_candidates <name> <config-dir> → the existing executable candidates, in order
kit_tool_candidates() {
    local d p
    d="$(kit_tools_dir "$2")"
    [[ -f "$d/$1" && -x "$d/$1" ]] && printf '%s\n' "$d/$1"
    p="$(kit_cfg_str "$2" "${1//-/_}_path")"
    [[ "$p" == "~/"* ]] && p="${HOME:-/nonexistent}${p:1}"
    [[ "$p" == /* && -f "$p" && -x "$p" && "$p" != "$d/$1" ]] && printf '%s\n' "$p"
    return 0
}
kit_tool_resolve() {
    local want c got any=0
    KIT_TOOL="" KIT_TOOL_WHY=missing
    want="$(kit_cfg_str "$2" "${1//-/_}_sha256")"
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        any=1
        [[ "$want" =~ ^[0-9a-f]{64}$ ]] || continue
        got="$(kit_sha256 "$c")" || continue
        [[ "$got" == "$want" ]] && { KIT_TOOL="$c" KIT_TOOL_WHY=ok; return 0; }
    done < <(kit_tool_candidates "$1" "$2")
    if [[ $any -eq 1 ]]; then
        if [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then KIT_TOOL_WHY=replaced; else KIT_TOOL_WHY=unrecorded; fi
    fi
    return 1
}
kit_tool_path() {
    kit_tool_resolve "$1" "$2" || return 1
    printf '%s\n' "$KIT_TOOL"
}
