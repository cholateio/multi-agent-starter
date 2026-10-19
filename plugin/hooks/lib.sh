#!/usr/bin/env bash
#
# lib.sh — shared helpers for the kit plugin hooks (sourced, never run).
#
# v5 activation gate: the plugin's hooks fire in EVERY directory (Claude Code
# has no per-directory hook enablement), so every hook sources this file and
# runs, right after parsing CWD from stdin:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#     PROJ=$(kit_project_root) || exit 0
#
# Pure bash + sed: no jq, no git, no python — this runs before every tool call.

# kit_project_root: print the kit project root and return 0, or return 1 when
# the kit must stay silent here.
#   - KIT=off (user-only master switch: hooks inherit Claude's launch env)
#   - no kit.toml at the project root (CLAUDE_PROJECT_DIR, else the caller's
#     $CWD) → not a kit project. Root only, no upward search (design §4.2).
#   - .claude/kit-version present → half-migrated v4 project whose own
#     settings.json hooks are still wired; yield so the Stop gate / breaker
#     don't fire twice. `kit migrate` removes the file.
kit_project_root() {
    [[ "${KIT:-on}" == "off" ]] && return 1
    local root="${CLAUDE_PROJECT_DIR:-${CWD:-}}"
    [[ -n "$root" && -f "$root/kit.toml" ]] || return 1
    if [[ -f "$root/.claude/kit-version" ]]; then
        echo "KIT: v4 layout detected (.claude/kit-version), plugin hooks yield; run: kit migrate ." >&2
        return 1
    fi
    printf '%s' "$root"
}

# kit_toml_scalar <root> <key>: first top-level `key = value` (quotes and a
# trailing comment stripped). Missing file / key → empty string.
kit_toml_scalar() {
    local f="$1/kit.toml" key="$2"
    [[ -f "$f" ]] || return 0
    sed -nE "/^[[:space:]]*\\[/q; s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#]*)[\"']?.*/\\1/p" "$f" 2>/dev/null \
        | head -n 1 | sed -E 's/[[:space:]]+$//'
}

# kit_toml_protected <root>: print the top-level `protected = [ ... ]` entries,
# one per line (quotes and commas stripped; blank and full-line `#` lines
# skipped; a comment on the `protected = [` header line is allowed).
# Contract (D7): one entry per line, no inline comments on entry lines. A
# violation — inline comment, bare (unquoted) token, unterminated array —
# prints NOTHING, diagnoses on stderr and returns 2: the hooks fail open to
# "no protected paths" instead of half-parsing, and `kit doctor` flags the
# file. Missing file / key → no output, return 0.
kit_toml_protected() {
    local f="$1/kit.toml" line rest state=0 c q i item
    local -a out=()
    [[ -f "$f" ]] || return 0
    _ktp_bad() { echo "KIT: kit.toml protected: $1 — protected list ignored; run: kit doctor" >&2; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $state -eq 0 ]]; then
            [[ "$line" =~ ^[[:space:]]*\[ ]] && break          # first table ends top level
            [[ "$line" =~ ^[[:space:]]*protected[[:space:]]*=[[:space:]]*\[(.*)$ ]] || continue
            state=1
            rest="${BASH_REMATCH[1]}"
            # header-line comment allowed only when no entry precedes it
            if [[ "$rest" =~ ^[[:space:]]*# ]]; then continue; fi
        else
            rest="$line"
            [[ "$rest" =~ ^[[:space:]]*(#.*)?$ ]] && continue  # blank / full-line comment
        fi
        # walk the line: quoted items, commas, closing bracket
        i=0; q=""; item=""
        while [[ $i -lt ${#rest} ]]; do
            c="${rest:$i:1}"
            if [[ -n "$q" ]]; then
                if [[ "$c" == "$q" ]]; then out+=("$item"); item=""; q=""
                else item+="$c"; fi
            else
                case "$c" in
                    '"'|"'") q="$c" ;;
                    ','|' '|$'\t'|$'\r') ;;
                    ']') state=2; break ;;
                    '#') _ktp_bad "inline comment on an entry line"; return 2 ;;
                    *) _ktp_bad "unquoted token in array"; return 2 ;;
                esac
            fi
            i=$((i + 1))
        done
        if [[ -n "$q" ]]; then _ktp_bad "unterminated string"; return 2; fi
        if [[ $state -eq 2 ]]; then
            # anything after `]` other than whitespace / a comment is malformed
            rest="${rest:$((i + 1))}"
            if [[ ! "$rest" =~ ^[[:space:]]*(#.*)?$ ]]; then _ktp_bad "text after closing bracket"; return 2; fi
            break
        fi
    done < "$f"
    if [[ $state -eq 1 ]]; then _ktp_bad "unterminated array"; return 2; fi
    [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
    return 0
}

# kit_profile: KIT_PROFILE env (non-empty) > `profile` in
# ${KIT_CONFIG_HOME:-$HOME/.config/kit}/config.toml > "full".
kit_profile() {
    if [[ -n "${KIT_PROFILE:-}" ]]; then printf '%s' "$KIT_PROFILE"; return 0; fi
    local cfg="${KIT_CONFIG_HOME:-${HOME:-}/.config/kit}/config.toml" p=""
    if [[ -f "$cfg" ]]; then
        p=$(sed -nE '/^[[:space:]]*\[/q; s/^[[:space:]]*profile[[:space:]]*=[[:space:]]*"?([A-Za-z0-9_-]*)"?.*/\1/p' "$cfg" 2>/dev/null | head -n 1)
    fi
    printf '%s' "${p:-full}"
}
