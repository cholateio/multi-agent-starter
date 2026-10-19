#!/usr/bin/env bash
#
# verify-final-review.sh — Stop hook (profile-aware review gate)
#
# Blocks turn-end when the session holds unreviewed business-logic changes.
# v4.9 decision-point model: when the cumulative batch crosses the small
# threshold the gate blocks ONCE and demands a decision — review (/kit-review),
# defer (mid-flight; quiet until the batch grows another threshold), or skip
# (/kit-skip-review; model-judged for non-sensitive batches, USER-only for
# sensitive/protected ones). Receipts: per-turn re-block noise 2026-08-02;
# Claude Code force-allows after 8 consecutive Stop blocks (official docs).
#
# Layout invariant: COMPUTE THEN DECIDE. All batch facts (changed set,
# business/sensitive classification, measured cumulative size) are computed
# before any settlement branch runs — settlement validity depends on them
# (the floor re-checks batch content; it never trusts a flag's self-report).
#
# Cross-file couplings:
#   - Baseline file (line1 = HEAD sha at last certification, line2 = content
#     hash of the working tree) is written by session-start.sh (write-if-
#     missing) and re-written here on certifying exits. working_tree_hash()
#     is kept in sync with the copy in session-start.sh.
#   - Turn-start snapshot (tree hash + HEAD) is written by classify-task.sh
#     every prompt; the gate only interrupts a turn that actually changed
#     the tree (obligation persists via the un-advanced baseline).
#   - Markers are written by /kit-review, bypass flags by /kit-skip-review,
#     defer files by the model (format taught in the block message).
#   - skiplog JSONL is this gate's own audit trail; model-initiated
#     settlements take effect only if their audit line was written.
# Fail-closed stance: unresolvable baseline diffs against the empty tree;
# unmeasurable batches (no cert tree, binary rows, scan failures) refuse
# small-allow, defer and model-skip. /tmp volatility is an accepted limit.
#
# Reference: https://code.claude.com/docs/en/hooks#stop

set -uo pipefail

# User-only escape hatch (env is fixed at Claude Code launch; a model's Bash
# export cannot flip it mid-session).
[[ "${KIT_REVIEW_GATE:-on}" == "off" ]] && exit 0

# No jq -> the kit's hooks are no-ops on this machine; don't block on tooling.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

INPUT=$(cat 2>/dev/null || echo '{}')

# Loop guard: a stop that follows our own block must pass. Deliberately no
# baseline advance — it breaks the loop, it does not certify anything.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

PROFILE="${KIT_PROFILE:-full}"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
cd "$PROJECT_DIR" 2>/dev/null || exit 0

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

BASELINE_FILE="/tmp/claude-kit-baseline-${SESSION_ID}"
BYPASS_FLAG="/tmp/claude-skip-review-${SESSION_ID}"
CODEX_MARKER="/tmp/claude-codex-reviewed-${SESSION_ID}"
SELF_MARKER="/tmp/claude-reviewed-${SESSION_ID}"
DEFER_FILE="/tmp/claude-kit-defer-${SESSION_ID}"
SKIPLOG="/tmp/claude-kit-skiplog-${SESSION_ID}.jsonl"
TURNSTART_FILE="/tmp/claude-kit-turnstart-${SESSION_ID}"
# git's canonical empty-tree object — the fail-closed diff base
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# Content-addressed snapshot of the working tree (tracked + untracked,
# .gitignore honored). Prints a tree sha, or nothing on failure.
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

# advance_baseline: ONLY on certifying exits (review / bypass / nothing to
# review). Certification settles any pending defer along with the batch.
advance_baseline() {
    local head_sha
    head_sha=$(git rev-parse --verify HEAD 2>/dev/null || echo "unborn")
    printf '%s\n%s\n' "$head_sha" "${CURRENT_TREE}" >"$BASELINE_FILE" 2>/dev/null || true
    rm -f "$DEFER_FILE"
}

BASE=""
CERT_TREE=""
if [[ -f "$BASELINE_FILE" ]]; then
    BASE=$(sed -n '1p' "$BASELINE_FILE" 2>/dev/null)
    CERT_TREE=$(sed -n '2p' "$BASELINE_FILE" 2>/dev/null)
fi

# --- compute: this session's changed files ---------------------------------
# Uncommitted (staged + unstaged + untracked; -uall so files inside brand-new
# directories are listed individually). Porcelain v1 lines are "XY path";
# strip the 3-char prefix. Renames are "XY old -> new"; keep the new path.
# git C-quotes unusual paths: strip the outer quotes last so the extension
# filter still matches.
# SCAN_FAILED: an enumeration failure (corrupt real index, git error) must
# never look like "nothing changed" — an empty list would take the advance-
# baseline exits below and certify an unreviewed tree (adversarial review
# finding 2026-08-02, test g18). pipefail is set, so a git failure reaches
# the assignment's exit status.
SCAN_FAILED=0
UNCOMMITTED=$(git status --porcelain -uall 2>/dev/null | sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"\(.*\)"$/\1/') \
    || SCAN_FAILED=1

COMMITTED=""
if [[ -f "$BASELINE_FILE" ]] && git rev-parse --verify HEAD >/dev/null 2>&1; then
    [[ -z "$BASE" || "$BASE" == "unborn" ]] && BASE="$EMPTY_TREE"
    # Fail closed on an unresolvable baseline sha (gc'd object, tampering):
    # diff against the empty tree, so everything tracked is up for review.
    if [[ "$BASE" != "$EMPTY_TREE" ]] \
       && ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
        BASE="$EMPTY_TREE"
    fi
    COMMITTED=$(git diff --name-only "$BASE" HEAD 2>/dev/null | sed -e 's/^"\(.*\)"$/\1/') \
        || SCAN_FAILED=1
fi

# Enforcement scans the FULL set — truncating before the business filter let
# 50 early-sorting junk paths hide a sensitive business file and advance the
# baseline (codex finding 2026-08-02, test g13). Only FILE_LIST (display) is
# truncated, below.
CHANGED_FILES=$(printf '%s\n%s\n' "$UNCOMMITTED" "$COMMITTED" | grep -v '^$' | sort -u)

# --- compute: business / sensitive classification --------------------------
# Sensitive stems stay size-blind. No right boundary on purpose: "auth"
# catches authentication/authorize (and false-positives like authors.py —
# acceptable, it errs toward review). "oauth"/"sso" listed explicitly:
# the left-delimiter requirement means "auth" does NOT match inside
# "oauth.py" (codex review finding, 2026-07-10).
SENSITIVE_PATH_REGEX='(^|[/_.-])(auth|oauth|sso|login|password|payment|billing|migrat|security|secret|crypto)'

# matches_protected <path>: 0 if the path hits a .claude/protected-paths
# glob (same semantics as protect-paths.sh: `*` crosses `/`, trailing
# slash means the subtree). An absent list means "no protected paths"
# (normal), not a scan failure.
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

# The sensitive scan runs BEFORE the extension filter and over the full
# changed set: a migrations/001.sql batch has no "business" extension yet is
# exactly what the migration floor exists for (codex finding 2026-08-02,
# test g12). SENSITIVE_HIT gates skip/defer/small-allow.
BUSINESS_LOGIC_REGEX='\.(py|ts|tsx|js|jsx|go|rs|rb|java|kt|swift|cs|php|ex|exs|clj|scala|cpp|c|h|hpp|sh)$'
SKIP_REGEX='(^|/)(\.claude/|node_modules/|dist/|build/|\.next/|target/|\.git/|vendor/|__pycache__/)'

BUSINESS_FILES=""
SENSITIVE_HIT=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if echo "$f" | grep -qE "$SKIP_REGEX"; then
        continue
    fi
    # Inclusion only — the floor flag (SENSITIVE_HIT) is set exclusively by
    # batch_measure over the certified-tree diff: a sensitive file that was
    # already certified (reviewed/skipped) but is still uncommitted must not
    # poison every later batch (test g4).
    if echo "$f" | grep -qiE "$SENSITIVE_PATH_REGEX" || matches_protected "$f"; then
        BUSINESS_FILES="${BUSINESS_FILES}${f}\n"
        continue
    fi
    if ! echo "$f" | grep -qE "$BUSINESS_LOGIC_REGEX"; then
        continue
    fi
    BUSINESS_FILES="${BUSINESS_FILES}${f}\n"
done <<< "$CHANGED_FILES"

# --- compute: cumulative batch size since the certified tree ---------------
SMALL_MAX_LINES=150
SMALL_MAX_FILES=8
# Test files count toward NEITHER cap (verification, not business logic);
# sensitive-NAMED test files stay size-blind because the sensitive check
# runs first. Suffix-style names recognized only where that convention holds.
TEST_PATH_REGEX='(^|/)(tests?|__tests__|__mocks__|spec)/|(^|/)(test|spec)_[^/]*$|_(test|spec)\.[^/.]+$|\.(test|spec)\.[^/.]+$|(^|/)conftest\.py$|(Test|Tests|Spec)\.(java|kt|kts|scala|cs|swift)$'

# batch_measure: cumulative certified-tree -> current-tree numstat, business
# non-test lines/files. Sets BATCH_TOTAL/BATCH_FILES/BATCH_MEASURABLE and can
# raise SENSITIVE_HIT (batch may contain paths outside CHANGED_FILES after
# reverts). Any scan failure => not measurable (fail closed for small-allow,
# defer and model-skip alike).
BATCH_TOTAL=0
BATCH_FILES=0
BATCH_MEASURABLE=1
batch_measure() {
    local numstat add del path
    if [[ "$SCAN_FAILED" -eq 1 || -z "$CERT_TREE" || -z "$CURRENT_TREE" ]] \
       || ! git rev-parse --verify --quiet "${CERT_TREE}^{tree}" >/dev/null 2>&1; then
        BATCH_MEASURABLE=0
        return 0
    fi
    # --no-renames keeps a rename deterministic: full delete + full add
    # (a renamed file counts big and gets reviewed — conservative).
    numstat=$(git diff --no-renames --numstat "$CERT_TREE" "$CURRENT_TREE" 2>/dev/null) \
        || { BATCH_MEASURABLE=0; return 0; }
    while IFS=$'\t' read -r add del path; do
        [[ -z "$path" ]] && continue
        path="${path#\"}"; path="${path%\"}"
        echo "$path" | grep -qE "$SKIP_REGEX" && continue
        if echo "$path" | grep -qiE "$SENSITIVE_PATH_REGEX" || matches_protected "$path"; then
            SENSITIVE_HIT=1
        fi
        echo "$path" | grep -qE "$BUSINESS_LOGIC_REGEX" || continue
        [[ "$add" == "-" || "$del" == "-" ]] && { BATCH_MEASURABLE=0; continue; }
        echo "$path" | grep -qE "$TEST_PATH_REGEX" && continue
        BATCH_TOTAL=$((BATCH_TOTAL + add + del))
        BATCH_FILES=$((BATCH_FILES + 1))
    done <<< "$numstat"
}
batch_measure

# skiplog <kind> <reason> <scope>: append one audit line. Model-initiated
# settlements (model-skip, defer stamping) take effect ONLY if this write
# succeeds — an unwritable audit log voids the settlement (fail closed),
# otherwise "reasons are sampled monthly" would be a promise without data.
skiplog() {
    local line
    line=$(jq -cn --arg ts "$(date -Is 2>/dev/null || date 2>/dev/null || echo unknown)" \
        --arg kind "$1" --arg reason "${2:-}" --arg scope "${3:-}" \
        --arg total "${BATCH_TOTAL}" --arg files "${BATCH_FILES}" \
        --arg tree "${CURRENT_TREE:-}" \
        '{ts:$ts,kind:$kind,reason:$reason,scope:$scope,total:$total,files:$files,tree:$tree}' 2>/dev/null) \
        || return 1
    printf '%s\n' "$line" >> "$SKIPLOG" 2>/dev/null || return 1
}

# --- decide: bypass flag (user-approved, or v4.9 model-judged skip) --------
# The floor is enforced on BATCH CONTENT computed above — never on the flag's
# self-report. Sensitive/protected or unmeasurable batches: USER-only.
INVALID_BYPASS=0
if [[ -f "$BYPASS_FLAG" ]]; then
    FLAG_LINE=$(head -n1 "$BYPASS_FLAG" 2>/dev/null)
    rm -f "$BYPASS_FLAG"
    if printf '%s' "$FLAG_LINE" | grep -q '^user-approved'; then
        if [[ "$SENSITIVE_HIT" -eq 1 ]]; then
            skiplog user-skip-sensitive "$FLAG_LINE" "" || true
        fi
        advance_baseline
        exit 0
    elif printf '%s' "$FLAG_LINE" | grep -qE '^skipped-by=model reason=[^[:space:]].* scope=[^[:space:]]'; then
        SKIP_REASON=$(printf '%s' "$FLAG_LINE" | sed -n 's/^skipped-by=model reason=\(.*\) scope=.*/\1/p')
        SKIP_SCOPE=$(printf '%s' "$FLAG_LINE" | sed -n 's/.* scope=\(.*\)$/\1/p')
        if [[ "$SENSITIVE_HIT" -eq 1 || "$BATCH_MEASURABLE" -ne 1 ]]; then
            skiplog model-skip-rejected "$SKIP_REASON" "$SKIP_SCOPE" || true
            INVALID_BYPASS=2
        elif skiplog model-skip "$SKIP_REASON" "$SKIP_SCOPE"; then
            advance_baseline
            exit 0
        else
            INVALID_BYPASS=3
        fi
    elif printf '%s' "$FLAG_LINE" | grep -q '^skipped-by=model'; then
        # model-judged skip missing reason/scope: malformed, audit + reject
        skiplog model-skip-rejected "$FLAG_LINE" "" || true
        INVALID_BYPASS=1
    else
        INVALID_BYPASS=1
    fi
fi

# Fast path: the exact current working-tree content was already certified.
# Covers "reviewed, then merely committed" — content hash ignores commits.
if [[ -n "$CURRENT_TREE" && "$CURRENT_TREE" == "$CERT_TREE" ]]; then
    advance_baseline
    exit 0
fi

# Empty lists certify ONLY when enumeration actually succeeded (g18).
if [[ -z "$CHANGED_FILES" && "$SCAN_FAILED" -eq 0 ]]; then
    advance_baseline
    exit 0
fi

# Nothing business-bearing (and nothing sensitive — those were folded into
# BUSINESS_FILES above) -> nothing to enforce
if [[ -z "$BUSINESS_FILES" && "$SCAN_FAILED" -eq 0 ]]; then
    advance_baseline
    exit 0
fi

# --- decide: review markers -------------------------------------------------
# A marker counts only with a "reviewed-by=..." evidence line written by
# /kit-review after the review actually ran (v4.0: a bare touch is discarded;
# the block message never prints marker incantations). verdict=blocked does
# not certify. Markers are audit records — this gate's skiplog plus the tool
# telemetry (when enabled) make a forged one cross-checkable after the fact.
marker_valid() {
    local first
    [[ -f "$1" ]] || return 1
    first=$(head -n1 "$1" 2>/dev/null)
    printf '%s' "$first" | grep -qE '^reviewed-by=[^[:space:]]+' || return 1
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
rm -f "$CODEX_MARKER" "$SELF_MARKER"

# --- decide: active defer (v4.9) --------------------------------------------
# One decision per threshold-crossing: a valid defer keeps the gate quiet
# until the batch grows another SMALL_MAX_LINES, then the decision is asked
# again. Sensitive/protected and unmeasurable batches cannot defer. The hook
# stamps the measured total itself; a stamp it cannot have written (non-
# integer, above the measured total) is tampering and voids the defer.
INVALID_DEFER=0
DEFER_EXPIRED=0
DEFER_NOTE=""
if [[ -f "$DEFER_FILE" ]]; then
    DEFER_LINE=$(head -n1 "$DEFER_FILE" 2>/dev/null)
    if ! printf '%s' "$DEFER_LINE" | grep -qE '^deferred-by=model reason=[^[:space:]]'; then
        rm -f "$DEFER_FILE"; INVALID_DEFER=1
        DEFER_NOTE="invalid defer (malformed or empty reason) — it did not take effect."
    elif [[ "$SENSITIVE_HIT" -eq 1 ]]; then
        rm -f "$DEFER_FILE"; INVALID_DEFER=1
        DEFER_NOTE="this batch touches sensitive or protected paths — sensitive batches cannot defer; review or a USER-approved skip are the only settlements."
    elif [[ "$BATCH_MEASURABLE" -ne 1 ]]; then
        rm -f "$DEFER_FILE"; INVALID_DEFER=1
        DEFER_NOTE="the batch is not measurable (no certified baseline or binary rows) — cannot defer; fail-closed."
    else
        STAMP_L=$(sed -n 's/^lines=//p' "$DEFER_FILE" | head -n1)
        STAMP_F=$(sed -n 's/^files=//p' "$DEFER_FILE" | head -n1)
        # Stamps are validated as bounded canonical digits BEFORE any
        # arithmetic: bash reads a leading-zero operand as octal, and an
        # arithmetic error exits a non-interactive shell — a tampered stamp
        # like "008" would crash the hook into fail-open instead of blocking
        # (adversarial review finding 2026-08-02, tests g19/g20). 10# forces
        # base-10; the 9-digit bound keeps the arithmetic in range.
        stamp_ok() { printf '%s' "$1" | grep -qE '^[0-9]{1,9}$'; }
        if [[ -z "$STAMP_L" && -z "$STAMP_F" ]]; then
            if skiplog defer-stamp "$DEFER_LINE" "lines=$BATCH_TOTAL files=$BATCH_FILES" \
               && printf 'lines=%s\nfiles=%s\n' "$BATCH_TOTAL" "$BATCH_FILES" >> "$DEFER_FILE" 2>/dev/null; then
                exit 0
            fi
            rm -f "$DEFER_FILE"; INVALID_DEFER=1
            DEFER_NOTE="audit log unwritable — the defer was not stamped and did not take effect."
        elif ! stamp_ok "$STAMP_L" || ! stamp_ok "$STAMP_F" \
             || [[ $((10#$STAMP_L)) -gt "$BATCH_TOTAL" || $((10#$STAMP_F)) -gt "$BATCH_FILES" ]]; then
            rm -f "$DEFER_FILE"; INVALID_DEFER=1
            DEFER_NOTE="invalid defer (stamp is not one the hook could have written) — it did not take effect."
        elif [[ $((BATCH_TOTAL - 10#$STAMP_L)) -lt "$SMALL_MAX_LINES" \
                && $((BATCH_FILES - 10#$STAMP_F)) -le "$SMALL_MAX_FILES" ]]; then
            # Both leashes hold: <150 lines AND <=8 business files of growth
            # since the stamp. EITHER crossing re-asks — a lines-only leash
            # let unlimited near-empty business files ride a defer
            # (adversarial review finding 2026-08-02, test g21).
            exit 0
        else
            rm -f "$DEFER_FILE"; DEFER_EXPIRED=1
            skiplog defer-expired "$DEFER_LINE" "grew ${STAMP_L}L/${STAMP_F}F->${BATCH_TOTAL}L/${BATCH_FILES}F" || true
        fi
    fi
fi

# Cumulative change still small -> allow WITHOUT advancing the baseline:
# small changes accumulate; the decision that fires once the threshold is
# crossed covers the whole batch (no salami-slicing past the review).
if [[ "$BATCH_MEASURABLE" -eq 1 && "$SENSITIVE_HIT" -eq 0 \
      && "$BATCH_FILES" -le "$SMALL_MAX_FILES" && "$BATCH_TOTAL" -le "$SMALL_MAX_LINES" ]]; then
    exit 0
fi

# Turn-scoped enforcement: at a turn boundary the gate fires only when THIS
# turn actually changed the tree or HEAD (classify-task.sh snapshots both at
# turn start). The obligation is preserved — the baseline is NOT advanced.
# Exceptions: invalid/expired evidence consumed this turn (marker, bypass,
# defer) must surface its block even on an unchanged tree — silently allowing
# it would swallow the "your evidence did not count" feedback.
# KNOWN GAP (accepted, user-approved 2026-07-24): an unchanged-tree turn that
# DECLARES COMPLETION passes; tree state cannot distinguish it from a
# brainstorming turn. The next code-touching turn re-blocks the whole batch,
# and the prose layer still requires review-before-done. Sensitive paths are
# unaffected (size-blind above).
if [[ "$INVALID_MARKER" -eq 0 && "$INVALID_BYPASS" -eq 0 \
      && "$INVALID_DEFER" -eq 0 && "$DEFER_EXPIRED" -eq 0 \
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

STALE_NOTE=""
if [[ "$INVALID_MARKER" -eq 1 ]]; then
    STALE_NOTE="
NOTE: a review marker WAS present but did not certify (bare touch, or verdict=blocked). It has been discarded — a blocked review means the blocking findings must be fixed and /kit-review re-run; only a passing evidence marker satisfies this gate.
"
fi
if [[ "$INVALID_BYPASS" -eq 1 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: a skip flag WAS present but carried no user-approval line or was malformed (a model-judged skip needs both reason= and scope=). It has been discarded.
"
elif [[ "$INVALID_BYPASS" -eq 2 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: a model-judged skip flag was present, but this batch touches sensitive or protected paths, or is not measurable — only the USER can skip it (/kit-skip-review after an explicit user request). The flag has been discarded and the attempt audited.
"
elif [[ "$INVALID_BYPASS" -eq 3 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: a model-judged skip flag was present but the audit log unwritable — the skip did not take effect (model-initiated settlements are audit-fail-closed). The flag has been discarded.
"
fi
if [[ "$INVALID_DEFER" -eq 1 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: a defer file WAS present but ${DEFER_NOTE}
"
fi
if [[ "$DEFER_EXPIRED" -eq 1 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: defer expired — the batch grew ≥${SMALL_MAX_LINES} lines or >${SMALL_MAX_FILES} business files since it was deferred. Decide again: review now, re-defer with a fresh reason, or skip.
"
fi
if [[ "$SCAN_FAILED" -eq 1 ]]; then
    STALE_NOTE="${STALE_NOTE}
NOTE: changed-file enumeration failed (git status/diff error — corrupt index?). Fail-closed: nothing can be certified or settled until a review/bypass runs or the repo is repaired.
"
fi

SETTLEMENTS=$(cat <<EOF
Settle this batch with ONE of:
1. Review now: run /kit-review (it records the evidence marker this gate accepts). Do NOT write the marker without running the review — markers and skips are audit records (skiplog), cross-checked against session telemetry.
2. Defer (feature mid-flight, a review NOW would re-review churn): run
   echo "deferred-by=model reason=<one line: why mid-flight>" > ${DEFER_FILE}
   The gate stays quiet until the batch grows another ${SMALL_MAX_LINES} lines, then asks again. Sensitive batches cannot defer. Settle every defer (review or skip) before declaring the task done.
3. Skip (you judge this batch not review-worthy: throwaway/experimental code): run /kit-skip-review — model-judged mode is allowed for non-sensitive batches and is audited with your reason; sensitive/protected batches remain USER-only.
EOF
)

if [[ "$PROFILE" == "solo" ]]; then
    REASON=$(cat <<EOF
Final review check (solo profile): this session holds unreviewed business-logic changes past the small-change threshold.
${STALE_NOTE}
CROSS-MODEL ISOLATION IS OFF in the solo profile — /kit-review runs the fresh-context solo-reviewer (state/time isolation only; say that limitation to the user).

${SETTLEMENTS}

Files modified:
${FILE_LIST}
EOF
)
else
    REASON=$(cat <<EOF
Final review check: this session holds unreviewed business-logic changes past the small-change threshold.
${STALE_NOTE}
${SETTLEMENTS}

Files modified:
${FILE_LIST}
EOF
)
fi

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
