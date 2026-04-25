#!/usr/bin/env bash
#
# verify-final-review.sh — Stop hook
#
# Blocks turn-end if the session modified business-logic-bearing files
# but `/codex:review` was never run on those changes.
#
# This is the strongest discipline mechanism in the kit: it ensures the
# "every meaningful change gets cross-model review" promise can't be forgotten.
#
# Behavior:
#   - If session changes are trivial (UI, docs, configs only) → allow stop
#   - If session changes business logic AND review was already run → allow stop
#   - If session changes business logic AND no review was run → BLOCK stop
#     and inject a message asking Claude to run /codex:review first
#   - If user explicitly said "skip review" earlier → allow stop (honor user)
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

# Marker file: written by users or earlier in session if they want to bypass
BYPASS_FLAG="/tmp/claude-skip-review-$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)"
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

# List files modified since session start (best-effort: uncommitted + recent commits)
# We check both staged and unstaged changes since hook can't track session boundary precisely.
CHANGED_FILES=$(git status --porcelain 2>/dev/null | awk '{print $2}' | head -50)

if [[ -z "$CHANGED_FILES" ]]; then
    # Nothing changed → nothing to review
    exit 0
fi

# Filter to business-logic-bearing files
# Languages and patterns considered "business logic" by default
BUSINESS_LOGIC_REGEX='\.(py|ts|tsx|js|jsx|go|rs|rb|java|kt|swift|cs|php|ex|exs|clj|scala|cpp|c|h|hpp|sh)$'
SKIP_REGEX='(^|/)(\.claude/|node_modules/|dist/|build/|\.next/|target/|\.git/|vendor/|__pycache__/)'

BUSINESS_FILES=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Skip non-business-logic extensions
    if ! echo "$f" | grep -qE "$BUSINESS_LOGIC_REGEX"; then
        continue
    fi
    # Skip generated/vendor directories
    if echo "$f" | grep -qE "$SKIP_REGEX"; then
        continue
    fi
    BUSINESS_FILES="${BUSINESS_FILES}${f}\n"
done <<< "$CHANGED_FILES"

# If no business-logic files changed → nothing to enforce
if [[ -z "$BUSINESS_FILES" ]]; then
    exit 0
fi

# Check if /codex:review was run in this session
# Strategy: look for a marker file written when /codex:review completes
REVIEW_MARKER="/tmp/claude-codex-reviewed-$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)"
if [[ -f "$REVIEW_MARKER" ]]; then
    # Review was already run — allow stop
    rm -f "$REVIEW_MARKER"
    exit 0
fi

# === Block the stop ===
# Construct a polite but firm message for Claude
FILE_LIST=$(echo -e "$BUSINESS_FILES" | head -10 | sed 's/^/  - /')

cat <<EOF
{
  "decision": "block",
  "reason": "Final review check: this session modified business-logic files but /codex:review has not been run on them yet. Per CLAUDE.md, run /codex:review on these changes before completing the turn.\n\nFiles modified:\n${FILE_LIST}\n\nIf you (or the user) explicitly want to skip this review, write 'touch ${BYPASS_FLAG}' (the user can do this) and try again. Otherwise: run /codex:review now."
}
EOF
exit 0
