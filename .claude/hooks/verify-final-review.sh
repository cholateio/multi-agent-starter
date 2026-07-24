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
#   if the profile changed mid-session. v4.0: a marker only counts when its
#   first line is a "reviewed-by=..." evidence line (written by /kit-review);
#   a bare touch is discarded and called out in the block message.
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
# v4.3 small-change auto-allow: when the CUMULATIVE diff since the last
# certified tree stays within SMALL_MAX_LINES/SMALL_MAX_FILES across
# business files and touches no sensitive or protected path, the stop is
# allowed WITHOUT advancing the baseline — small changes accumulate until
# one review covers the whole batch. v4.5: test files count toward
# NEITHER cap (they are verification, not business logic — but sensitive-
# named test files stay size-blind). Sensitive paths and unmeasurable
# states (no baseline, binary rows) stay size-blind. See the
# small_change_allow section below.
#
# v4.8 turn-scoped enforcement: the gate is working-tree-scoped, so before
# v4.8 it re-fired on EVERY turn while unreviewed business code sat in the
# tree — a brainstorming / read-only turn on top of a prior unreviewed change
# got blocked over and over (receipt 2026-07-23: user reports the gate
# blocking repeatedly during brainstorming after an earlier feature was
# implemented but not yet reviewed). Fix: classify-task.sh (UserPromptSubmit)
# snapshots the working-tree hash at the START of each turn; the block only
# fires when THIS turn actually changed the tree. See the turn-scoped section
# just above the block. Content-addressed, so a dispatched subagent's edits
# count too. v4.8 also adds a user-only escape hatch, KIT_REVIEW_GATE=off,
# parallel to KIT_PROTECT / KIT_BREAKER.
#
# Reference: https://code.claude.com/docs/en/hooks#stop

set -uo pipefail

# Escape hatch (user-only), parallel to protect-paths' KIT_PROTECT and
# tool-breaker's KIT_BREAKER: start the session with KIT_REVIEW_GATE=off to
# disable this final-review Stop gate for that session (e.g. a pure
# exploration / brainstorming session). A model cannot flip it mid-session —
# hooks inherit the env Claude Code launched with, not the model's Bash
# exports.
[[ "${KIT_REVIEW_GATE:-on}" == "off" ]] && exit 0

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

CURRENT_TREE=$(working_tree_hash)

# advance_baseline: called ONLY on gate-satisfied exits (nothing to review /
# certified state / marker consumed / user bypass), so certified work doesn't
# re-trigger the gate at the next stop.
advance_baseline() {
    local head_sha
    head_sha=$(git rev-parse --verify HEAD 2>/dev/null || echo "unborn")
    printf '%s\n%s\n' "$head_sha" "${CURRENT_TREE}" >"$BASELINE_FILE" 2>/dev/null || true
}

# User bypass: honor and consume — but only with evidence (v4.0). After
# review markers got evidence-gated, a bare-touched skip flag would be the
# new cheapest forgery; same rule for it: first line must start with
# "user-approved" (written by /kit-skip-review after an explicit user
# request, or by the user's own hand — the format is documented in the kit
# README, which deployed projects don't carry).
INVALID_BYPASS=0
if [[ -f "$BYPASS_FLAG" ]]; then
    if head -n1 "$BYPASS_FLAG" 2>/dev/null | grep -q '^user-approved'; then
        rm -f "$BYPASS_FLAG"
        advance_baseline
        exit 0
    fi
    rm -f "$BYPASS_FLAG"
    INVALID_BYPASS=1
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

# --- v4.3 small-change auto-allow --------------------------------------
# Tuning-phase reality: a 5-line tweak should not force a cross-model
# review. The gate measures the CUMULATIVE change since the last certified
# tree (baseline line2 -> current tree) with git numstat — committed,
# uncommitted and untracked all in one content-addressed diff. Small
# changes pass WITHOUT advancing the baseline, so they keep accumulating;
# the review that fires once the threshold is crossed covers the whole
# batch (deliberate: no salami-slicing past the review). The threshold is
# git-measured — the model calling a change "small" has no effect.
# Fail closed: no baseline, unresolvable CERT_TREE, or a binary numstat
# row ("-") all fall through to the size-blind block below.
# 2026-07-20: 50/4 was tuned for "one task per session". It mis-serves the
# actual dominant workload — continuous UI tuning, where every edit is
# genuinely small but the session total crosses 50 by mid-afternoon, so the
# review fires on whichever 3-line tweak happens to be last (receipt
# 2026-07-20: user reports the gate triggering on pre-commit micro-edits in
# established projects). Raised to 150/8. The accumulation design is
# deliberately kept: sensitive and protected paths stay size-blind below,
# so this loosens only the non-sensitive tuning path.
SMALL_MAX_LINES=150
SMALL_MAX_FILES=8
# v4.5: test files count toward NEITHER cap. The gate guards unreviewed
# BUSINESS logic; "one component + its tests" was the most common false
# trigger (receipt 2026-07-12: a margin tweak touched 6 files / 55 lines,
# only 29 of them non-test — blocked on both caps). Excluded tests still
# ride along in the batch the next triggered review covers. Order matters
# in the loop below: the sensitive check runs BEFORE this exclusion, so
# auth/payment-named test files (test_auth.py) stay size-blind.
# Suffix-style names (FooTest.java, FooTests.cs, FooSpec.scala — codex
# review finding, 2026-07-12) are recognized only for the languages where
# that convention holds, so business names like ABTest.ts stay counted.
TEST_PATH_REGEX='(^|/)(tests?|__tests__|__mocks__|spec)/|(^|/)(test|spec)_[^/]*$|_(test|spec)\.[^/.]+$|\.(test|spec)\.[^/.]+$|(^|/)conftest\.py$|(Test|Tests|Spec)\.(java|kt|kts|scala|cs|swift)$'
# Sensitive stems stay size-blind. No right boundary on purpose: "auth"
# catches authentication/authorize (and false-positives like authors.py —
# acceptable, it errs toward review). "oauth"/"sso" listed explicitly:
# the left-delimiter requirement means "auth" does NOT match inside
# "oauth.py" (codex review finding, 2026-07-10).
SENSITIVE_PATH_REGEX='(^|[/_.-])(auth|oauth|sso|login|password|payment|billing|migrat|security|secret|crypto)'

# matches_protected <path>: 0 if the path hits a .claude/protected-paths
# glob (same semantics as protect-paths.sh: `*` crosses `/`, trailing
# slash means the subtree).
matches_protected() {
    local pat list=".claude/protected-paths"
    [[ -f "$list" ]] || return 1
    while IFS= read -r pat; do
        pat="${pat%%#*}"
        pat="${pat#"${pat%%[![:space:]]*}"}"
        pat="${pat%"${pat##*[![:space:]]}"}"
        [[ -z "$pat" ]] && continue
        [[ "$pat" == */ ]] && pat="${pat}*"
        # shellcheck disable=SC2053  # unquoted RHS is the point: glob match
        [[ "$1" == $pat ]] && return 0
    done < "$list"
    return 1
}

# small_change_allow: 0 if the cumulative certified-tree diff qualifies.
small_change_allow() {
    local numstat add del path total=0 files=0
    [[ -n "$CERT_TREE" && -n "$CURRENT_TREE" ]] || return 1
    git rev-parse --verify --quiet "${CERT_TREE}^{tree}" >/dev/null 2>&1 || return 1
    # --no-renames keeps a rename deterministic: full delete + full add
    # (a renamed file counts big and gets reviewed — conservative).
    numstat=$(git diff --no-renames --numstat "$CERT_TREE" "$CURRENT_TREE" 2>/dev/null) || return 1
    while IFS=$'\t' read -r add del path; do
        [[ -z "$path" ]] && continue
        path="${path#\"}"; path="${path%\"}"
        echo "$path" | grep -qE "$BUSINESS_LOGIC_REGEX" || continue
        echo "$path" | grep -qE "$SKIP_REGEX" && continue
        [[ "$add" == "-" || "$del" == "-" ]] && return 1   # binary: fail closed
        echo "$path" | grep -qiE "$SENSITIVE_PATH_REGEX" && return 1
        matches_protected "$path" && return 1
        echo "$path" | grep -qE "$TEST_PATH_REGEX" && continue
        total=$((total + add + del))
        files=$((files + 1))
    done <<< "$numstat"
    # files may be 0 when the touched business files are net-identical to
    # the certified tree — nothing to review, allow.
    [[ "$files" -le "$SMALL_MAX_FILES" && "$total" -le "$SMALL_MAX_LINES" ]]
}

# A review counts if EITHER marker exists AND carries an evidence line
# ("reviewed-by=..." — written by /kit-review after the review actually
# ran). v4.0: a bare `touch` no longer satisfies the gate; the old block
# message used to hand out the touch command, making the forged shortcut
# cheaper than the real review. Markers still certify the tree state at
# THIS stop (finding-fixes ride along; /kit-review says to re-review
# substantial fix waves) — the evidence line adds friction plus an audit
# trail, not cryptography (see docs/harness-diagnosis.md, limit 2).
marker_valid() {
    local first
    [[ -f "$1" ]] || return 1
    first=$(head -n1 "$1" 2>/dev/null)
    printf '%s' "$first" | grep -qE '^reviewed-by=[^[:space:]]+' || return 1
    # verdict=blocked is not a certification: blocking findings must be
    # fixed and the review re-run — a blocked review passing the gate would
    # advance the baseline past unresolved findings.
    [[ "$first" != *"verdict=blocked"* ]]
}
INVALID_MARKER=0
for m in "$CODEX_MARKER" "$SELF_MARKER"; do
    if [[ -f "$m" ]] && ! marker_valid "$m"; then
        INVALID_MARKER=1
    fi
done
if marker_valid "$CODEX_MARKER" || marker_valid "$SELF_MARKER"; then
    rm -f "$CODEX_MARKER" "$SELF_MARKER"
    advance_baseline
    exit 0
fi
# Consume evidence-less markers so they don't linger; the block message
# below tells the model why its marker didn't count.
rm -f "$CODEX_MARKER" "$SELF_MARKER"

# Cumulative change still small (v4.3) -> allow, but do NOT advance the
# baseline: the change keeps counting toward the next review.
if small_change_allow; then
    exit 0
fi

# v4.8 turn-scoped enforcement: at a turn boundary the gate fires only when
# THIS turn actually changed the working tree. classify-task.sh
# (UserPromptSubmit) snapshots the tree hash at the START of every turn; if
# the tree is byte-identical now, this was a conversation / brainstorm /
# read-only turn and a pending review obligation must NOT interrupt it. The
# obligation is preserved on purpose — the baseline is NOT advanced, so the
# next turn that touches code (or a review) still settles the whole batch.
# Content-addressed on the tree, so a dispatched subagent's edits count too
# (the main transcript would not show them as Edit/Write tool calls).
# BOTH the tree content hash AND HEAD must be unchanged: content addressing is
# commit-agnostic, so a commit-only turn (HEAD moves, tree content identical)
# would otherwise slip a dirty unreviewed change into a commit — reopening the
# very commit blind spot the gate exists to close (codex review finding,
# 2026-07-23). The certified-tree fast path above still allows the legitimate
# reviewed-then-committed turn.
# Fail-closed: no turn-start snapshot (hook disabled, first stop before any
# prompt, or a legacy 1-line snapshot straddling an update) falls through to
# the block below.
# Exception: an invalid marker or bypass consumed this turn (INVALID_MARKER /
# INVALID_BYPASS) must still surface its block + STALE_NOTE even on an
# unchanged tree — silently allowing it would suppress the "your evidence did
# not count" feedback and weaken the anti-forgery contract (codex review
# finding, 2026-07-23).
#
# KNOWN GAP (accepted tradeoff, user-approved 2026-07-24; codex P1 flagged it):
# an unchanged-tree turn is allowed even if it DECLARES THE TASK COMPLETE — the
# hook cannot tell a "done" turn from brainstorming by tree state alone, so a
# completion claim made without a further edit can end the turn without
# /kit-review. This is the price of not blocking every brainstorming turn. It
# is NOT unguarded: (1) the very next turn that touches code re-blocks the whole
# pending batch, and (2) the prose layer still requires review before "done"
# (kit-workflow "Final review"; kit-judgment verified/unverified). Enforcing it
# in the hook would need fragile completion-language detection that reintroduces
# the false-blocks this feature removed. Sensitive paths are unaffected — they
# stay size-blind above and get phase-level review during the work.
TURNSTART_FILE="/tmp/claude-kit-turnstart-${SESSION_ID}"
if [[ "$INVALID_MARKER" -eq 0 && "$INVALID_BYPASS" -eq 0 \
      && -n "$CURRENT_TREE" && -f "$TURNSTART_FILE" ]]; then
    TURNSTART_TREE=$(sed -n '1p' "$TURNSTART_FILE" 2>/dev/null)
    TURNSTART_HEAD=$(sed -n '2p' "$TURNSTART_FILE" 2>/dev/null)
    CURRENT_HEAD=$(git rev-parse --verify HEAD 2>/dev/null || echo "unborn")
    if [[ -n "$TURNSTART_TREE" && "$CURRENT_TREE" == "$TURNSTART_TREE" \
          && -n "$TURNSTART_HEAD" && "$TURNSTART_HEAD" == "$CURRENT_HEAD" ]]; then
        exit 0
    fi
fi

# === Block the stop ===
FILE_LIST=$(echo -e "$BUSINESS_FILES" | grep -v '^$' | head -10 | sed 's/^/  - /')

# v4.0: the block message deliberately contains NO marker-writing command.
# /kit-review knows the evidence format; teaching it here would make the
# forged marker cheaper than the real review again.
STALE_NOTE=""
if [[ "$INVALID_MARKER" -eq 1 ]]; then
    STALE_NOTE="
NOTE: a review marker WAS present but did not certify (bare touch, or verdict=blocked). It has been discarded — a blocked review means the blocking findings must be fixed and /kit-review re-run; only a passing evidence marker satisfies this gate.
"
fi
if [[ "$INVALID_BYPASS" -eq 1 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: a skip flag WAS present but carried no user-approval line (a bare touch?). It has been discarded — only /kit-skip-review (after an EXPLICIT user request) writes a valid one.
"
fi

if [[ "$PROFILE" == "solo" ]]; then
    REASON=$(cat <<EOF
Final review check (solo profile): this session modified business-logic files but no review was run.
${STALE_NOTE}
CROSS-MODEL ISOLATION IS OFF in the solo profile. Run /kit-review now — it spawns the fresh-context solo-reviewer (state/time isolation only, NOT model isolation; say that limitation to the user), then records the evidence marker this gate accepts. Do NOT write the marker without actually running the review: markers are audited against the session tool log.

Files modified:
${FILE_LIST}

If the USER explicitly said to skip this review, run /kit-skip-review (user-approved bypass). Never self-approve a skip to end the turn.
EOF
)
else
    REASON=$(cat <<EOF
Final review check: this session modified business-logic files that have not been reviewed yet.
${STALE_NOTE}
Run /kit-review now — in the full profile it resolves to /codex:review, and after the review actually runs it records the evidence marker this gate accepts. Do NOT write the marker without running the review: markers are audited against the session tool log.

Files modified:
${FILE_LIST}

If the USER explicitly said to skip this review, run /kit-skip-review (user-approved bypass). Never self-approve a skip to end the turn.
EOF
)
fi

# jq --arg guarantees correct escaping of newlines and special characters
jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
