#!/usr/bin/env bash
#
# verify-final-review.sh — Stop hook (profile-aware)
#
# Blocks turn-end if the session modified business-logic-bearing files
# but no review was run on those changes.
#
# This is the strongest discipline mechanism in the kit: it ensures the
# "every meaningful change gets reviewed" promise can't be forgotten.
#
# Profile-aware via KIT_PROFILE (default "full"):
#   - full: required review is cross-model /codex:review
#           (marker: /tmp/claude-codex-reviewed-<session_id>)
#   - solo: required review is a fresh-context Claude self-review
#           (marker: /tmp/claude-reviewed-<session_id>); the block message
#           reminds Claude that cross-model isolation is OFF.
#   Either marker satisfies the gate, so a full-profile review still counts
#   if the profile changed mid-session.
#
# Behavior:
#   - Trivial changes (UI, docs, configs only) → allow stop
#   - Business logic changed AND a review marker exists → allow stop
#   - Business logic changed AND no review marker → BLOCK stop
#   - User bypass flag present → allow stop (honor user)
#
# Reference: https://code.claude.com/docs/en/hooks#stop

set -uo pipefail

# If jq is not available, silently allow — don't block stop on missing tooling
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Read input
INPUT=$(cat 2>/dev/null || echo '{}')

# Avoid infinite loops: if stop_hook_active is already true, just allow
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

# Active profile (per-machine env var; default full)
PROFILE="${KIT_PROFILE:-full}"

# Session id (used for all marker files)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

# Marker file: written by users or earlier in session if they want to bypass
BYPASS_FLAG="/tmp/claude-skip-review-${SESSION_ID}"
if [[ -f "$BYPASS_FLAG" ]]; then
    rm -f "$BYPASS_FLAG"
    exit 0
fi

# Detect what files changed in this session via git
# (We rely on git because Claude Code doesn't surface a "session changes" list directly)
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Skip if not a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

# List files modified (best-effort: staged + unstaged)
CHANGED_FILES=$(git status --porcelain 2>/dev/null | awk '{print $2}' | head -50)
if [[ -z "$CHANGED_FILES" ]]; then
    exit 0
fi

# Filter to business-logic-bearing files
BUSINESS_LOGIC_REGEX='\.(py|ts|tsx|js|jsx|go|rs|rb|java|kt|swift|cs|php|ex|exs|clj|scala|cpp|c|h|hpp|sh)$'
SKIP_REGEX='(^|/)(\.claude/|node_modules/|dist/|build/|\.next/|target/|\.git/|vendor/|__pycache__/)'

BUSINESS_FILES=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! echo "$f" | grep -qE "$BUSINESS_LOGIC_REGEX"; then
        continue
    fi
    if echo "$f" | grep -qE "$SKIP_REGEX"; then
        continue
    fi
    BUSINESS_FILES="${BUSINESS_FILES}${f}\n"
done <<< "$CHANGED_FILES"

# If no business-logic files changed → nothing to enforce
if [[ -z "$BUSINESS_FILES" ]]; then
    exit 0
fi

# A review counts if EITHER marker exists:
#   full → /tmp/claude-codex-reviewed-<id>  (cross-model review)
#   solo → /tmp/claude-reviewed-<id>        (fresh-context self-review)
CODEX_MARKER="/tmp/claude-codex-reviewed-${SESSION_ID}"
SELF_MARKER="/tmp/claude-reviewed-${SESSION_ID}"
if [[ -f "$CODEX_MARKER" || -f "$SELF_MARKER" ]]; then
    rm -f "$CODEX_MARKER" "$SELF_MARKER"
    exit 0
fi

# === Block the stop ===
# Build the file list with real newlines (echo -e expands the \n we appended)
FILE_LIST=$(echo -e "$BUSINESS_FILES" | head -10 | sed 's/^/  - /')

if [[ "$PROFILE" == "solo" ]]; then
    REASON=$(cat <<EOF
Final review check (solo profile): this session modified business-logic files but no review was run.

CROSS-MODEL ISOLATION IS OFF in the solo profile. Spawn a fresh-context subagent to review the diff with clean state (this gives state/time isolation only, NOT model isolation), state that limitation to the user, then run 'touch ${SELF_MARKER}' and try ending the turn again.

Files modified:
${FILE_LIST}

To skip the review entirely: run 'touch ${BYPASS_FLAG}' and try again.
EOF
)
else
    REASON=$(cat <<EOF
Final review check: this session modified business-logic files but /codex:review has not been run on them yet. Per CLAUDE.md, run /codex:review on these changes before completing the turn.

Files modified:
${FILE_LIST}

If you (or the user) explicitly want to skip this review, run 'touch ${BYPASS_FLAG}' (the user can do this) and try again. Otherwise: run /codex:review now.
EOF
)
fi

# Emit valid JSON. Using jq --arg guarantees correct escaping of newlines and
# special characters (the previous hand-built heredoc produced invalid JSON
# whenever FILE_LIST contained more than one line).
jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
