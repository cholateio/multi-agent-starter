#!/usr/bin/env bash
#
# protect-paths.sh — PreToolUse hook (matcher: Edit|Write|NotebookEdit)
#
# Deterministic no-touch-zone enforcement. Intercepts file-modification
# tool calls that target:
#   1. kit-owned harness files (.claude/{rules,hooks,scripts,agents,skills,
#      docs}, settings.json, kit-version) — escalated to the USER via
#      permissionDecision "ask": the model may not modify the harness that
#      governs it on its own (.claude/rules/kit-evolution.md), but a present
#      user can approve a legitimate edit (update-config flows, permission
#      tweaks) with one click. Unattended sessions have nobody to approve —
#      "ask" degrades to a block there, which is exactly the intent. This
#      default set is SKIPPED inside the kit repo itself (detected by
#      init.sh + VERSION + templates/ at the root AND no .claude/kit-version
#      — deployed projects always have kit-version, the kit repo never
#      does), where editing those files is the whole point.
#      .claude/protected-paths is deliberately NOT in this set: it is
#      project-owned and the workflow (CLAUDE.md constraints sync) requires
#      the model to ADD entries; kit-evolution.md forbids weakening it and
#      deletions show up in git diff — procedural + audit, not a hard wall.
#   2. project-declared no-touch zones: .claude/protected-paths, one glob
#      per line (# comments and blank lines ignored). Patterns match
#      repo-relative paths; `*` crosses `/` (bash [[ == ]] semantics), so
#      `src/legacy/*` covers the whole subtree. Target paths are
#      dot-segment-normalized first — `src/./x` and `src/../.claude/x`
#      cannot slip past the patterns.
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
PROJ="${CLAUDE_PROJECT_DIR:-$CWD}"
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

# --- 1. kit-owned harness files (skipped inside the kit repo itself) ---
IS_KIT_REPO=0
if [[ -f "$PROJ/init.sh" && -f "$PROJ/VERSION" && -d "$PROJ/templates" && ! -f "$PROJ/.claude/kit-version" ]]; then
    IS_KIT_REPO=1
fi
if [[ "$IS_KIT_REPO" -eq 0 ]]; then
    case "$REL" in
        .claude/rules/*|.claude/hooks/*|.claude/scripts/*|.claude/agents/*|.claude/skills/*|.claude/docs/*|.claude/settings.json|.claude/kit-version)
            ask "kit protect-paths: '$REL' is a kit-owned harness file — the model may not modify the harness that governs it on its own (see .claude/rules/kit-evolution.md). USER: approve ONLY if you explicitly asked for this exact change (e.g. a settings/permissions tweak); otherwise deny and route the change through the kit repo + 'init.sh --update'. Unattended sessions: this stays blocked, as intended."
            ;;
    esac
fi

# --- 2. project-declared no-touch zones ---
LIST="$PROJ/.claude/protected-paths"
if [[ -f "$LIST" ]]; then
    while IFS= read -r pat; do
        pat="${pat%%#*}"                     # strip trailing comments
        pat="${pat#"${pat%%[![:space:]]*}"}" # ltrim
        pat="${pat%"${pat##*[![:space:]]}"}" # rtrim
        [[ -z "$pat" ]] && continue
        [[ "$pat" == */ ]] && pat="${pat}*"  # dir/ means the whole subtree
        # shellcheck disable=SC2053  # unquoted RHS is the point: glob match
        if [[ "$REL" == $pat ]]; then
            deny "BLOCKED (kit protect-paths): '$REL' matches protected pattern '$pat' in .claude/protected-paths — a project no-touch zone (see CLAUDE.md 'Project-specific constraints'). Do NOT route around this via Bash; the tool log is audited and that counts as a violation. If this change is genuinely required, STOP and ask the user (judgment-matrix R3.1)."
        fi
    done < "$LIST"
fi

exit 0
