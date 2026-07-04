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
# Session baseline (/tmp/claude-kit-baseline-<session_id>, written by
# session-start.sh and re-written here on gate-satisfied exits):
#   line1 = HEAD sha at session start / last certification ("unborn" if none)
#   line2 = content hash of the working tree at that moment (git write-tree
#           of a throwaway staged-everything index), possibly empty
#
# What counts as "modified in this session":
#   - uncommitted changes (git status --porcelain -uall), PLUS
#   - commits made since baseline line1 (git diff --name-only BASE HEAD).
#   Fast path: if the current working-tree hash equals baseline line2, the
#   exact current state was already certified (reviewed / bypassed / clean)
#   → allow. Content-addressing means "review, then commit" stays certified.
#   No baseline file at all (SessionStart hook disabled, no jq, ...) →
#   degrade to the porcelain-only view. A baseline whose sha no longer
#   resolves (gc, tampering) FAILS CLOSED: diff against the empty tree, so
#   everything tracked is up for review until one review/bypass heals it.
#
# Reference: https://code.claude.com/docs/en/hooks#stop

set -uo pipefail

# If jq is not available, silently allow — don't block stop on missing tooling
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

INPUT=$(cat 2>/dev/null || echo '{}')

# Avoid infinite loops: if stop_hook_active is already true, just allow.
# Deliberately NO baseline advance on this exit — it doesn't certify the
# changes as reviewed, it only breaks the block-loop.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

PROFILE="${KIT_PROFILE:-full}"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Skip if not a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

BASELINE_FILE="/tmp/claude-kit-baseline-${SESSION_ID}"
BYPASS_FLAG="/tmp/claude-skip-review-${SESSION_ID}"
CODEX_MARKER="/tmp/claude-codex-reviewed-${SESSION_ID}"
SELF_MARKER="/tmp/claude-reviewed-${SESSION_ID}"
# git's canonical empty-tree object — the fail-closed diff base
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# Content-addressed snapshot of the working tree (tracked + untracked,
# .gitignore honored): stage everything into a throwaway index and hash it.
# Prints a tree sha, or nothing on failure.
# (Kept in sync with the copy in session-start.sh.)
working_tree_hash() {
    local idx tree
    idx=$(mktemp "${TMPDIR:-/tmp}/claude-kit-idx.XXXXXX" 2>/dev/null) || return 0
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git add -A 2>/dev/null \
        && tree=$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null) \
        && printf '%s\n' "$tree"
    rm -f "$idx" "$idx.lock"
    return 0
}

CURRENT_TREE=$(working_tree_hash)

# advance_baseline: called ONLY on gate-satisfied exits (nothing to review /
# certified state / marker consumed / user bypass), so certified work doesn't
# re-trigger the gate at the next stop.
advance_baseline() {
    local head_sha
    head_sha=$(git rev-parse HEAD 2>/dev/null || echo "unborn")
    printf '%s\n%s\n' "$head_sha" "${CURRENT_TREE}" >"$BASELINE_FILE" 2>/dev/null || true
}

# User bypass: honor and consume
if [[ -f "$BYPASS_FLAG" ]]; then
    rm -f "$BYPASS_FLAG"
    advance_baseline
    exit 0
fi

BASE=""
CERT_TREE=""
if [[ -f "$BASELINE_FILE" ]]; then
    BASE=$(sed -n '1p' "$BASELINE_FILE" 2>/dev/null)
    CERT_TREE=$(sed -n '2p' "$BASELINE_FILE" 2>/dev/null)
fi

# Fast path: the exact current working-tree content was already certified
# (session start / a past review / a bypass). Covers "reviewed, then merely
# committed" too — committing doesn't change the content hash.
if [[ -n "$CURRENT_TREE" && "$CURRENT_TREE" == "$CERT_TREE" ]]; then
    advance_baseline
    exit 0
fi

# --- collect this session's changed files ---
# Uncommitted (staged + unstaged + untracked; -uall so files inside brand-new
# directories are listed individually). Porcelain v1 lines are "XY path";
# strip the 3-char prefix. Renames are "XY old -> new"; keep the new path.
# git C-quotes unusual paths (spaces, ...): strip the outer quotes last so
# the extension filter still matches. (A filename that itself contains
# " -> " would be mangled — acceptable for a best-effort gate.)
UNCOMMITTED=$(git status --porcelain -uall 2>/dev/null | sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"\(.*\)"$/\1/')

# Committed since the baseline, if one was recorded
COMMITTED=""
if [[ -f "$BASELINE_FILE" ]] && git rev-parse --verify HEAD >/dev/null 2>&1; then
    [[ -z "$BASE" || "$BASE" == "unborn" ]] && BASE="$EMPTY_TREE"
    # Fail closed on an unresolvable baseline sha (gc'd object, tampering):
    # diff against the empty tree instead, so everything tracked is up for
    # review — one review/bypass then heals the baseline.
    if [[ "$BASE" != "$EMPTY_TREE" ]] \
       && ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
        BASE="$EMPTY_TREE"
    fi
    COMMITTED=$(git diff --name-only "$BASE" HEAD 2>/dev/null | sed -e 's/^"\(.*\)"$/\1/' || echo "")
fi

CHANGED_FILES=$(printf '%s\n%s\n' "$UNCOMMITTED" "$COMMITTED" | grep -v '^$' | sort -u | head -50)
if [[ -z "$CHANGED_FILES" ]]; then
    advance_baseline
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
    advance_baseline
    exit 0
fi

# A review counts if EITHER marker exists (see header)
if [[ -f "$CODEX_MARKER" || -f "$SELF_MARKER" ]]; then
    rm -f "$CODEX_MARKER" "$SELF_MARKER"
    advance_baseline
    exit 0
fi

# === Block the stop ===
FILE_LIST=$(echo -e "$BUSINESS_FILES" | grep -v '^$' | head -10 | sed 's/^/  - /')

if [[ "$PROFILE" == "solo" ]]; then
    REASON=$(cat <<EOF
Final review check (solo profile): this session modified business-logic files but no review was run.

CROSS-MODEL ISOLATION IS OFF in the solo profile. Run /kit-review (or spawn the solo-reviewer subagent yourself) to review the changes with clean state — state/time isolation only, NOT model isolation — and say that limitation to the user. When the review is done, run 'touch ${SELF_MARKER}' and end the turn again.

Files modified:
${FILE_LIST}

To skip the review entirely (the user's call, not yours): 'touch ${BYPASS_FLAG}' and try again.
EOF
)
else
    REASON=$(cat <<EOF
Final review check: this session modified business-logic files that have not been reviewed yet. Run /kit-review (resolves to /codex:review in the full profile) on these changes now. When the review is done, run 'touch ${CODEX_MARKER}' so the gate records it, then end the turn again.

Files modified:
${FILE_LIST}

To skip the review entirely (the user's call, not yours): 'touch ${BYPASS_FLAG}' and try again.
EOF
)
fi

# jq --arg guarantees correct escaping of newlines and special characters
jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
