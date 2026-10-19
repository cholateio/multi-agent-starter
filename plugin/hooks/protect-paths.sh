#!/usr/bin/env bash
#
# protect-paths.sh — PreToolUse hook (matcher: Edit|Write|NotebookEdit)
#
# Deterministic no-touch-zone enforcement. Intercepts file-modification
# tool calls that target:
#   1. kit-owned files (v5): anything under the kit plugin root
#      ($CLAUDE_PLUGIN_ROOT, plus this hook's own plugin dir as a fallback)
#      or the kit's machine config (~/.config/kit, and $KIT_CONFIG_HOME when
#      set: config.toml, privacy.local.toml, git-hooks shims) — escalated
#      to the USER via permissionDecision "ask": the model may not modify
#      the harness that governs it on its own (kit-evolution rules), but a
#      present user can approve a legitimate edit with one click.
#      Unattended sessions have nobody to approve — "ask" degrades to a
#      block there, which is exactly the intent. A target that is ALSO
#      inside the project is exempt: when the kit repo itself is the
#      project, the plugin lives in it and editing it is the whole point.
#      (v4's "kit repo = init.sh + VERSION + templates/" detection is gone:
#      projects no longer carry kit files under .claude/.)
#      kit.toml is deliberately NOT kit-owned: it is project-owned and the
#      workflow requires the model to ADD protected entries; loosening it
#      is caught by the Stop gate (kit.toml is a sensitive path there).
#   2. project-declared no-touch zones: kit.toml `protected = [...]`, one
#      quoted glob per line (lib.sh kit_toml_protected; a malformed array
#      fails OPEN to "no zones" with a stderr diagnosis — kit doctor flags
#      it). Patterns match repo-relative paths; `*` crosses `/` (bash
#      [[ == ]] semantics), so `src/legacy/*` covers the whole subtree; a
#      trailing slash means the subtree. Target paths are
#      dot-segment-normalized first — `src/./x` and `src/../x` cannot slip
#      past the patterns.
#
# Escape hatch (user-only): launch the session with KIT_PROTECT=off.
# A model cannot flip this for the running session — hooks inherit the env
# Claude Code was started with, not the model's Bash exports.
#
# Known limit (documented in docs/harness-diagnosis.md): Bash is a side
# door — `sed -i`, `echo >`, `rm` bypass Edit/Write tools. Command-string
# parsing is too false-positive-prone to enforce here; the tool log
# (tool-breaker.sh) keeps an audit trail instead.
#
# Failures must never break the tool flow — every path falls through to
# exit 0 (allow). Reference: https://code.claude.com/docs/en/hooks#pretooluse

set -uo pipefail

[[ "${KIT_PROTECT:-on}" == "off" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || echo '{}')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
# v5 activation gate: silent unless the project root carries kit.toml
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ=$(kit_project_root) || exit 0
TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null || echo "")
[[ -z "$TARGET" ]] && exit 0

# Collapse '', '.' and '..' path segments WITHOUT touching the filesystem
# (realpath -m is not portable to stock macOS bash environments). Keeps the
# match immune to dot-segment smuggling like src/../.claude/settings.json.
norm_path() {  # $1 = absolute-ish path -> normalized absolute path on stdout
    local part
    local -a out=()
    local IFS='/'
    for part in $1; do
        case "$part" in
            ''|'.') ;;
            '..') [[ ${#out[@]} -gt 0 ]] && out=("${out[@]:0:$((${#out[@]} - 1))}") ;;
            *)    out+=("$part") ;;
        esac
    done
    (IFS='/'; printf '/%s\n' "${out[*]}")
}

# Normalize PROJ itself first — a trailing slash or dot segment in
# .cwd/CLAUDE_PROJECT_DIR would otherwise break the prefix match below and
# silently disable every protection (REL would stay absolute).
[[ "$PROJ" != /* ]] && PROJ="$(pwd 2>/dev/null || echo /)/$PROJ"
PROJ="$(norm_path "$PROJ")"

# Absolutize against PROJ, normalize, then re-relativize when inside PROJ.
ABS="$TARGET"
[[ "$ABS" != /* ]] && ABS="$PROJ/$ABS"
ABS="$(norm_path "$ABS")"
REL="$ABS"
case "$ABS" in
    "$PROJ"/*) REL="${ABS#"$PROJ"/}" ;;
esac

deny() {  # $1 = reason — hard wall (project-declared no-touch zones)
    jq -n --arg r "$1" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

ask() {  # $1 = reason — escalate to the user (kit-owned harness files)
    jq -n --arg r "$1" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
    exit 0
}

# --- 1. kit-owned files: plugin root / kit machine config, outside the project ---
in_dir() {  # $1 = normalized abs path  $2 = dir (may be empty) -> 0 if $1 is under $2
    [[ -n "$2" ]] || return 1
    local d; d="$(norm_path "$2")"
    [[ "$d" != "/" && "$1" == "$d"/* ]]
}
case "$ABS" in
    "$PROJ"/*) ;;   # inside the project (e.g. the kit repo developing its own plugin)
    *)
        SELF_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
        if in_dir "$ABS" "${CLAUDE_PLUGIN_ROOT:-}" || in_dir "$ABS" "$SELF_PLUGIN" \
           || in_dir "$ABS" "${KIT_CONFIG_HOME:-}" || in_dir "$ABS" "${HOME:+$HOME/.config/kit}"; then
            ask "kit protect-paths: '$ABS' is a kit-owned file (kit plugin or ~/.config/kit) — the model may not modify the harness that governs it on its own (kit-evolution rules). USER: approve ONLY if you explicitly asked for this exact change; otherwise deny — edit it in the kit repo, then /reload-plugins. Unattended sessions: this stays blocked, as intended."
        fi
        ;;
esac

# --- 2. project-declared no-touch zones (kit.toml [protected]) ---
PROTECTED="$(kit_toml_protected "$PROJ")"   # rc 2 = malformed: fail open, lib.sh diagnosed on stderr
while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    [[ "$pat" == */ ]] && pat="${pat}*"  # dir/ means the whole subtree
    # shellcheck disable=SC2053  # unquoted RHS is the point: glob match
    if [[ "$REL" == $pat ]]; then
        deny "BLOCKED (kit protect-paths): '$REL' matches protected pattern '$pat' in kit.toml [protected] — a project no-touch zone (see AGENTS.md 'Constraints'). Do NOT route around this via Bash; the tool log is audited and that counts as a violation. If this change is genuinely required, STOP and ask the user (/kit:judgment R3.1)."
    fi
done <<< "$PROTECTED"

exit 0
