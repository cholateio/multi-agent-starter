#!/usr/bin/env bash
#
# session-start.sh — SessionStart hook (kit self-onboarding)
#
# Two jobs, both cheap:
#   1. Inject dynamic kit context into the session: active KIT_PROFILE,
#      reviewer availability, kit version, and this session's
#      review-marker paths. Claude cannot know its own session_id any other
#      way — the /kit-review and /kit-skip-review skills rely on this
#      broadcast to write their evidence lines to the right marker files.
#   2. Record the review-gate baseline that verify-final-review.sh checks:
#      line1 = HEAD at session start (closes the "committed changes are
#      invisible to git status" blind spot), line2 = a content hash of the
#      working tree (so pre-existing dirt and already-certified states
#      don't re-trigger the gate).
#
# Output: JSON with hookSpecificOutput.additionalContext (exit 0).
# Failures must never break session start — every path falls through to exit 0.
#
# Reference: https://code.claude.com/docs/en/hooks#sessionstart

set -uo pipefail

# Consistent with the other kit hooks: no jq → no-op. (The Stop hook then
# simply never finds a baseline and degrades to its porcelain-only view.)
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
# Normalize once — a relative cwd must not get double-applied later.
CWD=$(cd "$CWD" 2>/dev/null && pwd || echo "")
PROFILE="${KIT_PROFILE:-full}"

# Content-addressed snapshot of the working tree (tracked + untracked,
# .gitignore honored): stage everything into a throwaway index and hash it.
# Prints a tree sha, or nothing on failure.
# (Kept in sync with the copy in verify-final-review.sh.)
working_tree_hash() {
    local idx tree
    idx=$(mktemp "${TMPDIR:-/tmp}/claude-kit-idx.XXXXXX" 2>/dev/null) || return 0
    rm -f "$idx"
    # Seed from HEAD so tracked-but-gitignored files stay tracked in the
    # throwaway index — from an empty index `git add -A` would treat them
    # as untracked and skip them, blinding the hash to their edits.
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null
    fi
    GIT_INDEX_FILE="$idx" git add -A 2>/dev/null \
        && tree=$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null) \
        && printf '%s\n' "$tree"
    rm -f "$idx" "$idx.lock"
    return 0
}

# --- record the review-gate baseline ---
# write-if-missing: SessionStart also fires on resume/compact for the same
# session_id, and those must not move an established baseline mid-session.
BASELINE_FILE="/tmp/claude-kit-baseline-${SESSION_ID}"
if [[ -n "$CWD" && ! -f "$BASELINE_FILE" ]] && cd "$CWD" 2>/dev/null \
   && git rev-parse --git-dir >/dev/null 2>&1; then
    HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unborn")
    printf '%s\n%s\n' "$HEAD_SHA" "$(working_tree_hash)" >"$BASELINE_FILE" 2>/dev/null || true
fi

# --- dynamic context ---
KIT_VERSION=$(cut -d' ' -f1 "$CWD/.claude/kit-version" 2>/dev/null || echo "unknown")
if [[ "$PROFILE" == "full" ]]; then
    command -v codex >/dev/null 2>&1 && CODEX="available" || CODEX="MISSING"
    TOOLS="reviewer=codex(${CODEX})"
else
    TOOLS="no external reviewer; reviews are same-model self-reviews (state/time isolation only)"
fi

CONTEXT="KIT_CONTEXT (multi-agent kit ${KIT_VERSION})
- Active profile: ${PROFILE} — ${TOOLS}
- Stop-gate files for THIS session (a bare touch NEVER passes the gate — each needs its evidence line, and only the named skill writes it):
  - cross-model review done:  /tmp/claude-codex-reviewed-${SESSION_ID}   (written by /kit-review)
  - solo self-review done:    /tmp/claude-reviewed-${SESSION_ID}   (written by /kit-review)
  - user-approved gate skip:  /tmp/claude-skip-review-${SESSION_ID}   (written by /kit-skip-review, ONLY after an explicit user request)
- Use /kit-review to run the profile-correct review (it records the evidence marker).
- Workflow rules: .claude/rules/ (auto-loaded: kit-workflow, kit-delegation, kit-evolution)."

# RE-ANCHOR: compact/resume are when a drifting model is most dangerous —
# the plan details and no-touch zones were just squeezed out of context.
# Startup doesn't need this (everything is still fresh).
if [[ "$SOURCE" == "compact" || "$SOURCE" == "resume" ]]; then
    CONTEXT="${CONTEXT}

RE-ANCHOR (context was just ${SOURCE}ed — memory of this session is lossy now). BEFORE the next file modification:
1. Re-read CLAUDE.md 'Project-specific constraints' (the no-touch zones).
2. Re-read the active plan / progress doc if one exists (docs/plans/, docs/specs/, .superpowers/).
3. State in ONE sentence which phase you are in and which files are already DONE — completed work is off-limits unless the plan says otherwise.
Do not rely on your summarized memory for any of the above — re-read the files."
fi

jq -n --arg ctx "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
