#!/usr/bin/env bash
# tests/hooks-smoke.sh - behavioral tests for the kit's .claude/hooks/*.sh
#
# Same style as tests/smoke.sh: bash-only, PASS/FAIL per assertion, summary
# line, exit 1 on any failure. Differences: the hooks under test REQUIRE jq
# (they no-op without it), so this suite needs jq too - if jq is missing we
# print SKIP and exit 0 (that machine's hooks are no-ops anyway).
#
# Deliberately no `set -e`: we assert on exit codes of commands that are
# expected to fail.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$KIT_ROOT/.claude/hooks"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP hooks-smoke: jq not installed (kit hooks are no-ops without jq)"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP hooks-smoke: git not installed"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-hooks-smoke.XXXXXX")"
# unique per-run session-id prefix so /tmp marker files can't collide with
# real sessions or a parallel test run
SID_PREFIX="hooksmoke-$$"
cleanup() { rm -rf "$WORK" /tmp/claude-*-"${SID_PREFIX}"* 2>/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# git isolation (same pattern as tests/smoke.sh)
GIT_ID_CFG="$WORK/gitconfig-identity"
cat > "$GIT_ID_CFG" <<'EOF'
[user]
	name = Hooks Smoke
	email = hooks@example.test
EOF
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }
assert_contains() { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing text: [$3]"; fi; }
assert_not_contains() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "unexpectedly contains: [$3]"; else pass "$1"; fi; }
assert_file_exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi; }
assert_file_absent() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpectedly present: $2"; fi; }

# run_hook <hook-path> <stdin-json> [KIT_PROFILE value] [VAR=val ...]
# sets OUT (stdout), ERR (stderr) and CODE. Env is controlled: git/HOME
# isolation, an explicit KIT_PROFILE (default full), the kit toggles forced
# to their defaults (a developer's shell could carry KIT_PROTECT=off or the
# v4.8 KIT_REVIEW_GATE=off, which would silently pass every block test), and
# CLAUDE_PROJECT_DIR cleared so hooks fall back to the fixture cwd instead
# of the kit repo this suite runs from. Extra VAR=val args override any of
# these (env(1): later assignments win).
run_hook() {
  local hook="$1" json="$2" profile="${3:-full}"
  shift 3 2>/dev/null || shift $#
  OUT="$(printf '%s' "$json" | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID_CFG" \
        HOME="$FAKE_HOME" env KIT_PROFILE="$profile" KIT_PROTECT=on KIT_BREAKER=on \
        KIT_REVIEW_GATE=on CLAUDE_PROJECT_DIR= "$@" bash "$hook" 2>"$WORK/last-stderr")"
  CODE=$?
  ERR="$(cat "$WORK/last-stderr" 2>/dev/null)"
}

# valid_marker <path> <codex|solo>: write a v4.0 evidence marker (a bare
# touch no longer satisfies the Stop gate)
valid_marker() {
  printf 'reviewed-by=%s verdict=approve scope="smoke fixture" date=2026-01-01\n' "$2" > "$1"
}

# py_lines <n>: n lines of trivial python on stdout. v4.3: the Stop gate
# auto-allows small cumulative changes, so every block-expecting business
# fixture must exceed the threshold (150 lines since 2026-07-20) to keep testing
# the block path; 1-line fixtures now legitimately pass the gate.
py_lines() { local i; for ((i=1; i<=$1; i++)); do echo "print('line $i')"; done; }

# git_f: git against a fixture dir under the same isolation
git_f() {
  local d="$1"; shift
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID_CFG" HOME="$FAKE_HOME" git -C "$d" "$@"
}

# make_repo <dir>: fixture git repo with one initial commit (README.md only)
make_repo() {
  mkdir -p "$1"
  git_f "$1" init -q -b main
  echo "fixture" > "$1/README.md"
  git_f "$1" add -A
  git_f "$1" commit -q -m "fixture: initial"
}

# baseline helpers
baseline_head() { sed -n '1p' "$1" 2>/dev/null; }
baseline_tree() { sed -n '2p' "$1" 2>/dev/null; }

# ===========================================================================
# H0 - hooks must be executable (Claude Code invokes them directly; run_hook
# below uses `bash <hook>` and would mask a lost exec bit)
# ===========================================================================
for h in session-start.sh classify-task.sh verify-final-review.sh protect-paths.sh tool-breaker.sh; do
  if [ -x "$HOOKS/$h" ]; then pass "h0: exec bit on $h"; else fail "h0: exec bit on $h" "not executable"; fi
done

# Hooks ship ENABLED (v3.5+): settings must hold the kit events DIRECTLY
# under "hooks" — a leftover disabled-key or an extra nesting level would
# silently disable everything. v4.0 adds PreToolUse + PostToolUseFailure.
if jq -e '.hooks | has("SessionStart") and has("UserPromptSubmit") and has("Stop") and has("PreToolUse") and has("PostToolUseFailure")' \
     "$KIT_ROOT/.claude/settings.json" >/dev/null 2>&1; then
  pass "h0: settings ships kit hooks enabled with event keys directly"
else
  fail "h0: settings ships kit hooks enabled with event keys directly" "hooks key missing or missing an event"
fi

# ===========================================================================
# H1 - session-start.sh
# ===========================================================================
SS="$HOOKS/session-start.sh"
R1="$WORK/h1-repo"
make_repo "$R1"
SID1="${SID_PREFIX}-h1"
BASELINE1="/tmp/claude-kit-baseline-${SID1}"

run_hook "$SS" "{\"session_id\":\"${SID1}\",\"cwd\":\"${R1}\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
assert_eq "h1: exit 0" "$CODE" "0"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
EVT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)"
assert_eq "h1: hookEventName is SessionStart" "$EVT" "SessionStart"
assert_contains "h1: context announces full profile" "$CTX" "Active profile: full"
assert_contains "h1: context carries codex marker path" "$CTX" "/tmp/claude-codex-reviewed-${SID1}"
assert_contains "h1: context carries self marker path" "$CTX" "/tmp/claude-reviewed-${SID1}"
assert_contains "h1: context carries skip marker path" "$CTX" "/tmp/claude-skip-review-${SID1}"
assert_contains "h1: context carries defer path (v4.9)" "$CTX" "/tmp/claude-kit-defer-${SID1}"
assert_contains "h1: skip line covers model-judged mode (v4.9)" "$CTX" "model-judged"
assert_contains "h1: auto-loaded list includes project-manifest" "$CTX" "project-manifest"
assert_contains "h1: full context names codex reviewer" "$CTX" "reviewer=codex("
assert_not_contains "h1: full context has no researcher field" "$CTX" "researcher="
assert_not_contains "h1: full context has no gemini" "$CTX" "gemini"
assert_file_exists "h1: baseline recorded" "$BASELINE1"
HEAD1="$(git_f "$R1" rev-parse HEAD)"
assert_eq "h1: baseline line1 is session-start HEAD" "$(baseline_head "$BASELINE1")" "$HEAD1"
if baseline_tree "$BASELINE1" | grep -qE '^[0-9a-f]{40}$'; then
  pass "h1: baseline line2 is a tree hash"
else
  fail "h1: baseline line2 is a tree hash" "got [$(baseline_tree "$BASELINE1")]"
fi

# write-if-missing: resume/compact must not move an existing baseline
printf 'SENTINEL\n' > "$BASELINE1"
run_hook "$SS" "{\"session_id\":\"${SID1}\",\"cwd\":\"${R1}\",\"source\":\"resume\"}"
assert_eq "h1: rerun exit 0" "$CODE" "0"
assert_eq "h1: existing baseline untouched on rerun" "$(cat "$BASELINE1")" "SENTINEL"

# RE-ANCHOR (v4.0): compact/resume must inject the re-anchor block; a fresh
# startup must not (nothing has been squeezed out of context yet)
SID1E="${SID_PREFIX}-h1e"
run_hook "$SS" "{\"session_id\":\"${SID1E}\",\"cwd\":\"${R1}\",\"source\":\"compact\"}"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h1: compact source injects RE-ANCHOR" "$CTX" "RE-ANCHOR"
assert_contains "h1: re-anchor orders a constraints re-read" "$CTX" "Project-specific constraints"
run_hook "$SS" "{\"session_id\":\"${SID_PREFIX}-h1f\",\"cwd\":\"${R1}\",\"source\":\"resume\"}"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h1: resume source injects RE-ANCHOR" "$CTX" "RE-ANCHOR"
run_hook "$SS" "{\"session_id\":\"${SID_PREFIX}-h1g\",\"cwd\":\"${R1}\",\"source\":\"startup\"}"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_not_contains "h1: startup has no RE-ANCHOR" "$CTX" "RE-ANCHOR"

# solo profile announced
SID1B="${SID_PREFIX}-h1b"
run_hook "$SS" "{\"session_id\":\"${SID1B}\",\"cwd\":\"${R1}\"}" solo
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h1: solo profile announced" "$CTX" "Active profile: solo"
assert_not_contains "h1: solo context has no researcher mention" "$CTX" "researcher"

# non-git cwd: still valid JSON, no baseline written
NONGIT="$WORK/h1-nongit"
mkdir -p "$NONGIT"
SID1C="${SID_PREFIX}-h1c"
run_hook "$SS" "{\"session_id\":\"${SID1C}\",\"cwd\":\"${NONGIT}\"}"
assert_eq "h1: non-git exit 0" "$CODE" "0"
EVT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)"
assert_eq "h1: non-git still emits valid JSON" "$EVT" "SessionStart"
assert_file_absent "h1: non-git records no baseline" "/tmp/claude-kit-baseline-${SID1C}"

# kit-version surfaces in context when present
mkdir -p "$R1/.claude"
echo "v9.9.9 abcdef0 2026-01-01" > "$R1/.claude/kit-version"
SID1D="${SID_PREFIX}-h1d"
run_hook "$SS" "{\"session_id\":\"${SID1D}\",\"cwd\":\"${R1}\"}"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h1: kit version surfaced" "$CTX" "v9.9.9"
rm -rf "$R1/.claude"   # keep later fixtures clean

# ===========================================================================
# H2 - verify-final-review.sh
# ===========================================================================
VF="$HOOKS/verify-final-review.sh"
R2="$WORK/h2-repo"
make_repo "$R2"
SID2="${SID_PREFIX}-h2"
BASELINE2="/tmp/claude-kit-baseline-${SID2}"
CODEX_M2="/tmp/claude-codex-reviewed-${SID2}"
SELF_M2="/tmp/claude-reviewed-${SID2}"
BYPASS2="/tmp/claude-skip-review-${SID2}"
STOP_JSON="{\"session_id\":\"${SID2}\",\"cwd\":\"${R2}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"

# seed the baseline with the real session-start hook (integration!)
run_hook "$SS" "{\"session_id\":\"${SID2}\",\"cwd\":\"${R2}\"}"
assert_file_exists "h2 setup: baseline seeded by session-start" "$BASELINE2"

# (a) clean tree, fresh baseline -> allow silently
run_hook "$VF" "$STOP_JSON"
assert_eq "h2a: clean tree allows stop" "$CODE" "0"
assert_eq "h2a: no block JSON emitted" "$OUT" ""

# (b) uncommitted business file, no marker -> block (and stays blocked on rerun)
py_lines 200 > "$R2/app.py"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2b: exit 0 (block via JSON, not exit code)" "$CODE" "0"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2b: decision is block" "$DEC" "block"
assert_contains "h2b: reason names the file" "$REASON" "app.py"
assert_contains "h2b: reason points at /kit-review" "$REASON" "/kit-review"
# v4.0: the block message must NOT hand out the forgeable shortcut
assert_not_contains "h2b: no touch incantation in block message" "$REASON" "touch /tmp"
assert_contains "h2b: skip path routed through the skill" "$REASON" "/kit-skip-review"
if printf '%s\n' "$REASON" | grep -qE '^  - *$'; then
  fail "h2b: no empty entry in file list" "found a bare '  - ' line"
else
  pass "h2b: no empty entry in file list"
fi
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2b: uncertified state re-blocks on rerun" "$DEC" "block"

# (c) marker -> allow + consume + certify; SAME dirty state must not re-block
valid_marker "$CODEX_M2" codex
run_hook "$VF" "$STOP_JSON"
assert_eq "h2c: marker satisfies gate" "$OUT" ""
assert_file_absent "h2c: marker consumed" "$CODEX_M2"
assert_eq "h2c: baseline line1 advanced to HEAD" "$(baseline_head "$BASELINE2")" "$(git_f "$R2" rev-parse HEAD)"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2c: certified dirty state does not re-block" "$OUT" ""

# (c2) committing the certified state keeps the certification (content-addressed)
git_f "$R2" add -A && git_f "$R2" commit -q -m "fixture: certified change committed"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2c2: commit of certified content still allows" "$OUT" ""

# (c3) new edits after certification re-block
py_lines 200 >> "$R2/app.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2c3: post-certification edit blocks again" "$DEC" "block"
valid_marker "$SELF_M2" solo
run_hook "$VF" "$STOP_JSON"   # certify + settle for next scenarios
assert_eq "h2c3: self marker settles the state" "$OUT" ""

# (d) THE COMMIT BLIND SPOT: commit business change, then point baseline at
# the pre-commit HEAD (clean tree, no cert) -> must still block. The change
# is deliberately 1 line: a baseline with no tree hash (line2) is
# unmeasurable, so the v4.3 small-change gate must fail closed here.
PRE_HEAD="$(git_f "$R2" rev-parse HEAD)"
echo "print('committed change')" >> "$R2/app.py"
git_f "$R2" add -A && git_f "$R2" commit -q -m "fixture: business change"
printf '%s\n' "$PRE_HEAD" > "$BASELINE2"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2d: committed-but-unreviewed change blocks" "$DEC" "block"
assert_contains "h2d: reason names the committed file" "$REASON" "app.py"

# (e) review it -> allow, baseline advances past the commit, stays quiet
valid_marker "$SELF_M2" solo
run_hook "$VF" "$STOP_JSON"
assert_eq "h2e: marker satisfies gate after commit" "$OUT" ""
assert_eq "h2e: baseline advanced past the commit" "$(baseline_head "$BASELINE2")" "$(git_f "$R2" rev-parse HEAD)"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2e: reviewed commit does not re-block" "$OUT" ""

# (f) rename handling: staged rename must surface the NEW path, no '->' garbage
git_f "$R2" mv app.py renamed.py
run_hook "$VF" "$STOP_JSON"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_contains "h2f: rename reports new path" "$REASON" "renamed.py"
assert_not_contains "h2f: no arrow artifacts in file list" "$REASON" " -> "
git_f "$R2" mv renamed.py app.py   # restore

# (g) untracked file inside a NEW directory must be seen (porcelain -uall)
mkdir -p "$R2/newdir"
py_lines 200 > "$R2/newdir/deep.py"
run_hook "$VF" "$STOP_JSON"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_contains "h2g: file inside new directory is caught" "$REASON" "newdir/deep.py"
rm -rf "$R2/newdir"

# (h) trivial-only change -> allow
echo "docs tweak" >> "$R2/README.md"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2h: docs-only change allows stop" "$OUT" ""
git_f "$R2" checkout -q -- README.md

# (i) bypass flag: bare touch rejected (v4.0), user-approved line honored
py_lines 200 > "$R2/app2.py"
touch "$BYPASS2"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2i: bare-touched bypass still blocks" "$DEC" "block"
assert_contains "h2i: block calls out the approval-less flag" "$REASON" "no user-approval line"
assert_file_absent "h2i: approval-less flag consumed" "$BYPASS2"
printf 'user-approved date=2026-01-01 quote="smoke fixture"\n' > "$BYPASS2"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2i: user-approved bypass allows stop" "$OUT" ""
assert_file_absent "h2i: bypass flag consumed" "$BYPASS2"
assert_eq "h2i: bypass advances baseline" "$(baseline_head "$BASELINE2")" "$(git_f "$R2" rev-parse HEAD)"
rm -f "$R2/app2.py"

# (j) stop_hook_active -> allow unconditionally (loop guard), baseline untouched
echo "print('z')" > "$R2/app3.py"
printf 'STALE\n' > "$BASELINE2"
run_hook "$VF" "{\"session_id\":\"${SID2}\",\"cwd\":\"${R2}\",\"stop_hook_active\":true}"
assert_eq "h2j: stop_hook_active allows" "$OUT" ""
assert_eq "h2j: loop-guard exit does not touch baseline" "$(cat "$BASELINE2")" "STALE"
rm -f "$R2/app3.py" "$BASELINE2"

# (k) degraded mode: no baseline file at all + clean tree -> allow
run_hook "$VF" "$STOP_JSON"
assert_eq "h2k: no baseline + clean tree degrades to allow" "$OUT" ""

# (l) FAIL CLOSED: baseline exists but sha is unresolvable -> everything
# tracked is up for review; one review heals the baseline
printf '0123456789abcdef0123456789abcdef01234567\n' > "$BASELINE2"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2l: unresolvable baseline fails closed" "$DEC" "block"
assert_contains "h2l: fail-closed review scope covers tracked files" "$REASON" "app.py"
valid_marker "$CODEX_M2" codex
run_hook "$VF" "$STOP_JSON"
assert_eq "h2l: review heals the broken baseline" "$OUT" ""
assert_eq "h2l: healed baseline line1 is HEAD" "$(baseline_head "$BASELINE2")" "$(git_f "$R2" rev-parse HEAD)"

# (m) solo profile block message discloses reduced isolation
py_lines 200 >> "$R2/app.py"
run_hook "$VF" "$STOP_JSON" solo
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_contains "h2m: solo block mentions isolation OFF" "$REASON" "ISOLATION IS OFF"
assert_not_contains "h2m: solo block has no touch incantation" "$REASON" "touch /tmp"
git_f "$R2" checkout -q -- app.py

# (n) filename with a space survives the porcelain parse
py_lines 200 > "$R2/my app.py"
run_hook "$VF" "$STOP_JSON"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_contains "h2n: space-containing filename listed intact" "$REASON" "my app.py"
rm -f "$R2/my app.py"

# (o) tracked-but-gitignored file must stay inside the content hash: an edit
# to it must break the fast path and block (final-review round 2, P2)
echo "print('legacy')" > "$R2/legacy.py"
git_f "$R2" add -f legacy.py
echo "legacy.py" > "$R2/.gitignore"
git_f "$R2" add .gitignore
git_f "$R2" commit -q -m "fixture: tracked-but-ignored file"
valid_marker "$SELF_M2" solo
run_hook "$VF" "$STOP_JSON"   # certify the clean state (also heals baseline)
assert_eq "h2o setup: clean state certified" "$OUT" ""
py_lines 200 >> "$R2/legacy.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2o: edit to tracked-but-ignored file blocks" "$DEC" "block"
assert_contains "h2o: reason names the ignored-but-tracked file" "$REASON" "legacy.py"
git_f "$R2" checkout -q -- legacy.py
rm -f "$BASELINE2"

# (p) v4.0 anti-forgery: a BARE-TOUCHED marker must not pass — it is
# discarded, called out, and only an evidence marker heals the state
py_lines 200 >> "$R2/app.py"
touch "$CODEX_M2"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2p: bare-touched marker still blocks" "$DEC" "block"
assert_contains "h2p: block calls out the non-certifying marker" "$REASON" "did not certify"
assert_file_absent "h2p: evidence-less marker consumed" "$CODEX_M2"
# a blocked verdict is not a certification either
printf 'reviewed-by=codex verdict=blocked scope="smoke" date=2026-01-01\n' > "$CODEX_M2"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2p: blocked-verdict marker still blocks" "$DEC" "block"
assert_contains "h2p: block explains blocked verdicts don't certify" "$REASON" "verdict=blocked"
assert_file_absent "h2p: blocked-verdict marker consumed" "$CODEX_M2"
valid_marker "$CODEX_M2" codex
run_hook "$VF" "$STOP_JSON"
assert_eq "h2p: evidence marker passes the gate" "$OUT" ""
git_f "$R2" checkout -q -- app.py
rm -f "$BASELINE2"

# (q) v4.3 small-change auto-allow: small cumulative diffs pass WITHOUT
# advancing the baseline; accumulation past a threshold blocks; the review
# that fires then covers the whole batch
run_hook "$SS" "{\"session_id\":\"${SID2}\",\"cwd\":\"${R2}\"}"   # re-seed baseline at clean state
CERT_BEFORE="$(baseline_tree "$BASELINE2")"
py_lines 10 > "$R2/tweak.py"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q: small business change auto-allows" "$OUT" ""
assert_eq "h2q: small allow does NOT advance baseline" "$(baseline_tree "$BASELINE2")" "$CERT_BEFORE"
py_lines 10 > "$R2/tweak2.py"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q: second small change still allowed (cumulative 20 lines, 2 files)" "$OUT" ""
# v4.5: test files count toward NEITHER cap (receipt 2026-07-12: a margin
# tweak = 6 files / 55 lines, only 29 non-test, blocked on both caps)
py_lines 40 > "$R2/test_tweak.py"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q: test lines don't count (60 total lines, 20 business)" "$OUT" ""
# suffix-style test names count for the languages with that convention
# (codex review finding 2026-07-12); ABTest.ts is NOT such a language
for ((i=1; i<=40; i++)); do echo "class L$i {}"; done > "$R2/TweakTest.java"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q: suffix-style Java test file doesn't count" "$OUT" ""
rm -f "$R2/TweakTest.java"
for n in 3 4 5 6 7 8; do py_lines 5 > "$R2/tweak$n.py"; done
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q: test file doesn't count toward file cap (9 paths, 8 business)" "$OUT" ""
py_lines 5 > "$R2/tweak9.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2q: ninth business file crosses the file cap and blocks" "$DEC" "block"
for n in 3 4 5 6 7 8 9; do rm -f "$R2/tweak$n.py"; done
py_lines 145 >> "$R2/tweak.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2q: cumulative lines past the threshold block" "$DEC" "block"
valid_marker "$SELF_M2" solo
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q: one review covers the accumulated batch" "$OUT" ""
# cleanup: removing the untracked tweaks leaves a clean porcelain — the
# gate's "nothing to review" path advances the baseline by itself. NO
# marker here: on that path the marker check is never reached, so a
# marker written now would linger and falsely satisfy the next scenario.
rm -f "$R2/tweak.py" "$R2/tweak2.py" "$R2/test_tweak.py"
run_hook "$VF" "$STOP_JSON"
assert_eq "h2q cleanup: post-cleanup state certified" "$OUT" ""
assert_file_absent "h2q cleanup: no marker left behind" "$SELF_M2"

# (r) sensitive path stays size-blind: a 5-line auth change must block
py_lines 5 > "$R2/auth.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2r: tiny change on sensitive path still blocks" "$DEC" "block"
rm -f "$R2/auth.py"
# "oauth" must match even though "auth" inside it has no left delimiter
# (codex review finding 2026-07-10)
py_lines 5 > "$R2/oauth.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2r: tiny change on oauth path still blocks" "$DEC" "block"
rm -f "$R2/oauth.py"
# sensitive-named TEST files get no test exclusion: the sensitive check
# runs before the v4.5 test-path skip
py_lines 5 > "$R2/test_auth.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2r: tiny sensitive-named test file still blocks" "$DEC" "block"
rm -f "$R2/test_auth.py"

# (s) protected path stays size-blind: a 3-line change in a
# .claude/protected-paths zone must block
mkdir -p "$R2/.claude" "$R2/src/legacy"
echo "src/legacy/" > "$R2/.claude/protected-paths"
py_lines 3 > "$R2/src/legacy/pay.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2s: tiny change on protected path still blocks" "$DEC" "block"
rm -rf "$R2/src" "$R2/.claude"

# (t/u) v4.8 TURN-SCOPED enforcement + escape hatch. Uses a DEDICATED fresh
# fixture: R2's accumulated history (hundreds of committed "print('line N')"
# lines) would let a similar-looking 300-line change slip under the v4.3
# small-change threshold and mask the block — a clean baseline makes the diff
# genuinely exceed it.
R2T="$WORK/h2-turnscope"; make_repo "$R2T"
SID2T="${SID_PREFIX}-h2t"
BASELINE2T="/tmp/claude-kit-baseline-${SID2T}"
TURNSTART2T="/tmp/claude-kit-turnstart-${SID2T}"
CODEX_M2T="/tmp/claude-codex-reviewed-${SID2T}"
STOP2T="{\"session_id\":\"${SID2T}\",\"cwd\":\"${R2T}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
rm -f "$BASELINE2T" "$TURNSTART2T"
run_hook "$SS" "{\"session_id\":\"${SID2T}\",\"cwd\":\"${R2T}\"}"   # fresh baseline, clean tree
BT_BEFORE="$(baseline_tree "$BASELINE2T")"
# the big change is already in the tree at THIS turn's start: classify-task
# snapshots it, so the current tree equals the turn-start snapshot
py_lines 200 > "$R2T/app.py"
run_hook "$HOOKS/classify-task.sh" "{\"session_id\":\"${SID2T}\",\"cwd\":\"${R2T}\",\"prompt\":\"lets brainstorm the next feature\"}"
assert_file_exists "h2t: classify-task recorded a turn-start snapshot" "$TURNSTART2T"
run_hook "$VF" "$STOP2T"
assert_eq "h2t: no-change turn on a big unreviewed diff allows (turn-scoped)" "$OUT" ""
assert_eq "h2t: obligation preserved — baseline tree NOT advanced" "$(baseline_tree "$BASELINE2T")" "$BT_BEFORE"

# (t2) a turn that DOES change the tree still blocks: the current tree now
# diverges from the turn-start snapshot recorded above
py_lines 100 >> "$R2T/app.py"
run_hook "$VF" "$STOP2T"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2t2: a turn that changed the tree still blocks" "$DEC" "block"

# (t3) fail-closed: no turn-start snapshot at all -> block as before v4.8
rm -f "$TURNSTART2T"
run_hook "$VF" "$STOP2T"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2t3: absent snapshot fails closed (blocks)" "$DEC" "block"

# (u) v4.8 escape hatch: KIT_REVIEW_GATE=off disables the gate for the session
run_hook "$VF" "$STOP2T" full KIT_REVIEW_GATE=off
assert_eq "h2u: KIT_REVIEW_GATE=off disables the final-review gate" "$OUT" ""
run_hook "$VF" "$STOP2T"   # default (on) still blocks the same dirty state
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2u: gate ON by default still blocks the same dirty state" "$DEC" "block"

# (t4) invalid evidence on an UNCHANGED-tree turn must still block — the
# turn-scoped allowance must not swallow the anti-forgery block + STALE_NOTE
run_hook "$HOOKS/classify-task.sh" "{\"session_id\":\"${SID2T}\",\"cwd\":\"${R2T}\",\"prompt\":\"snapshot the current tree\"}"
touch "$CODEX_M2T"   # bare marker == invalid evidence (no reviewed-by line)
run_hook "$VF" "$STOP2T"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2t4: invalid marker on an unchanged tree still blocks (anti-forgery)" "$DEC" "block"
assert_contains "h2t4: block still surfaces the STALE_NOTE" "$REASON" "did not certify"
assert_file_absent "h2t4: invalid marker consumed" "$CODEX_M2T"

# (t5) commit-only turn must NOT escape: a dirty unreviewed change at turn
# start that is only committed has an identical tree content hash before/after
# (commit doesn't change content) but HEAD moved — the turn-scope check must
# see the HEAD move and still block (codex P1, round 2)
rm -f "$CODEX_M2T"
git_f "$R2T" reset -q --hard HEAD && git_f "$R2T" clean -fdq
rm -f "$BASELINE2T" "$TURNSTART2T"
run_hook "$SS" "{\"session_id\":\"${SID2T}\",\"cwd\":\"${R2T}\"}"   # fresh baseline, clean tree
py_lines 200 > "$R2T/app.py"                                        # big dirty unreviewed change
run_hook "$HOOKS/classify-task.sh" "{\"session_id\":\"${SID2T}\",\"cwd\":\"${R2T}\",\"prompt\":\"commit it\"}"
git_f "$R2T" add -A && git_f "$R2T" commit -q -m "commit-only turn"  # HEAD moves, tree content identical
run_hook "$VF" "$STOP2T"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2t5: commit-only turn (HEAD moved, tree hash same) still blocks" "$DEC" "block"
# and reviewing it settles the commit
valid_marker "$CODEX_M2T" codex
run_hook "$VF" "$STOP2T"
assert_eq "h2t5: reviewing the commit-only change satisfies the gate" "$OUT" ""

git_f "$R2T" reset -q --hard HEAD && git_f "$R2T" clean -fdq
rm -f "$BASELINE2T" "$TURNSTART2T" "$CODEX_M2T"

# (t6) turn-scoping must work in an UNBORN repo (no commits yet — a brand-new
# project, the kit's own starting state). Plain `git rev-parse HEAD` prints the
# literal "HEAD" in an unborn repo, so writer and reader must both use the
# quiet --verify form to agree on the "unborn" sentinel (codex P2, round 3).
R2U="$WORK/h2-unborn"; mkdir -p "$R2U"; git_f "$R2U" init -q -b main
SID2U="${SID_PREFIX}-h2u2"
BASELINE2U="/tmp/claude-kit-baseline-${SID2U}"
TURNSTART2U="/tmp/claude-kit-turnstart-${SID2U}"
STOP2U="{\"session_id\":\"${SID2U}\",\"cwd\":\"${R2U}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
rm -f "$BASELINE2U" "$TURNSTART2U"
run_hook "$SS" "{\"session_id\":\"${SID2U}\",\"cwd\":\"${R2U}\"}"   # baseline on an unborn repo
py_lines 200 > "$R2U/app.py"   # big unreviewed change, still uncommitted (unborn)
run_hook "$HOOKS/classify-task.sh" "{\"session_id\":\"${SID2U}\",\"cwd\":\"${R2U}\",\"prompt\":\"brainstorm\"}"
assert_eq "h2t6: unborn HEAD serialized as the clean 'unborn' sentinel" "$(sed -n '2p' "$TURNSTART2U" 2>/dev/null)" "unborn"
run_hook "$VF" "$STOP2U"
assert_eq "h2t6: no-change turn in an unborn repo allows (turn-scoped)" "$OUT" ""
py_lines 100 >> "$R2U/app.py"   # this turn changes the tree
run_hook "$VF" "$STOP2U"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2t6: tree change in an unborn repo still blocks" "$DEC" "block"
rm -f "$BASELINE2U" "$TURNSTART2U"

# ===========================================================================
# G - verify-final-review.sh v4.9 decision-point gate: defer / model-skip /
#     sensitive floor / audit fail-closed. Written RED-first (before the v4.9
#     hook change). g12/g13 double as receipts for two PRE-existing holes:
#     extension-filtered sensitive scan (SQL blind spot) and pre-filter
#     head-50 truncation.
# ===========================================================================
RG="$WORK/g-repo"; make_repo "$RG"
SIDG="${SID_PREFIX}-g"
BASELINEG="/tmp/claude-kit-baseline-${SIDG}"
CODEX_MG="/tmp/claude-codex-reviewed-${SIDG}"
SELF_MG="/tmp/claude-reviewed-${SIDG}"
BYPASSG="/tmp/claude-skip-review-${SIDG}"
DEFERG="/tmp/claude-kit-defer-${SIDG}"
SKIPLOGG="/tmp/claude-kit-skiplog-${SIDG}.jsonl"
TURNSTARTG="/tmp/claude-kit-turnstart-${SIDG}"
STOPG="{\"session_id\":\"${SIDG}\",\"cwd\":\"${RG}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
run_hook "$SS" "{\"session_id\":\"${SIDG}\",\"cwd\":\"${RG}\"}"

# g1: >150-line unreviewed batch blocks and offers all three settlements
py_lines 200 > "$RG/feature.py"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g1: batch over threshold blocks" "$DEC" "block"
assert_contains "g1: offers the review path" "$REASON" "/kit-review"
assert_contains "g1: offers the skip path" "$REASON" "/kit-skip-review"
assert_contains "g1: offers the defer path (teach line)" "$REASON" "deferred-by=model"

# g2: a valid defer settles the block; hook stamps measured lines + audits
printf 'deferred-by=model reason=feature-mid-flight\n' > "$DEFERG"
run_hook "$VF" "$STOPG"
assert_eq "g2: valid defer allows the stop" "$OUT" ""
assert_contains "g2: hook stamped measured lines into the defer" "$(cat "$DEFERG" 2>/dev/null)" "lines="
assert_contains "g2: hook stamped the business-file count too" "$(cat "$DEFERG" 2>/dev/null)" "files="
assert_contains "g2: defer stamp audited in skiplog" "$(cat "$SKIPLOGG" 2>/dev/null)" "defer-stamp"
py_lines 10 >> "$RG/feature.py"
run_hook "$VF" "$STOPG"
assert_eq "g2: +10 lines under the leash stays quiet" "$OUT" ""

# g3: growth >=150 past the stamp re-blocks and consumes the defer
py_lines 200 >> "$RG/feature.py"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g3: growth past the leash re-blocks" "$DEC" "block"
assert_file_absent "g3: expired defer consumed" "$DEFERG"
assert_contains "g3: reason notes the defer expiry" "$REASON" "defer expired"
assert_contains "g3: expiry audited in skiplog" "$(cat "$SKIPLOGG" 2>/dev/null)" "defer-expired"

# g7: a review marker clears an active defer along with the obligation
printf 'deferred-by=model reason=still-mid-flight\n' > "$DEFERG"
run_hook "$VF" "$STOPG"
assert_eq "g7 setup: re-defer allowed" "$OUT" ""
valid_marker "$CODEX_MG" codex
run_hook "$VF" "$STOPG"
assert_eq "g7: marker satisfies gate over an active defer" "$OUT" ""
assert_file_absent "g7: certification cleared the defer file" "$DEFERG"

# g8: malformed defer must surface its block even on an unchanged-tree turn
# (turn-scoped pass must not swallow the "your defer did not count" feedback)
py_lines 200 > "$RG/feature2.py"
run_hook "$HOOKS/classify-task.sh" "{\"session_id\":\"${SIDG}\",\"cwd\":\"${RG}\",\"prompt\":\"hello\"}"
assert_file_exists "g8 setup: turn-start snapshot taken" "$TURNSTARTG"
printf 'deferred-by=model reason=\n' > "$DEFERG"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g8: malformed defer blocks despite unchanged tree" "$DEC" "block"
assert_contains "g8: reason names the invalid defer" "$REASON" "invalid defer"
assert_file_absent "g8: malformed defer consumed" "$DEFERG"
rm -f "$TURNSTARTG"

# g9: pre-stamped defer (stamp above measured total) is tampering -> invalid
printf 'deferred-by=model reason=x\nlines=999999\n' > "$DEFERG"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g9: pre-stamped defer blocks" "$DEC" "block"
assert_contains "g9: reason names the invalid defer" "$REASON" "invalid defer"
assert_file_absent "g9: tampered defer consumed" "$DEFERG"
valid_marker "$SELF_MG" solo
run_hook "$VF" "$STOPG"
assert_eq "g9 cleanup: state certified" "$OUT" ""

# g10: sensitive batch cannot defer (floor covers defer, not just skip)
py_lines 160 > "$RG/auth_handler.py"
printf 'deferred-by=model reason=mid-flight\n' > "$DEFERG"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g10: sensitive defer blocks" "$DEC" "block"
assert_contains "g10: reason states the sensitive-defer floor" "$REASON" "cannot defer"
assert_file_absent "g10: sensitive defer consumed" "$DEFERG"

# g5: model-skip on a sensitive batch is rejected + audited
printf 'skipped-by=model reason=throwaway scope=160lines/1file\n' > "$BYPASSG"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g5: model-skip on sensitive batch blocks" "$DEC" "block"
assert_contains "g5: floor language present" "$REASON" "only the USER can skip"
assert_file_absent "g5: rejected flag consumed" "$BYPASSG"
assert_contains "g5: rejection audited" "$(cat "$SKIPLOGG" 2>/dev/null)" "model-skip-rejected"

# g6: user-approved still overrides the floor, and the override is audited
printf 'user-approved date=2026-01-01 quote="smoke fixture"\n' > "$BYPASSG"
run_hook "$VF" "$STOPG"
assert_eq "g6: user-approved on sensitive batch allows" "$OUT" ""
assert_file_absent "g6: bypass flag consumed" "$BYPASSG"
assert_contains "g6: sensitive user-skip audited" "$(cat "$SKIPLOGG" 2>/dev/null)" "user-skip-sensitive"

# g4: model-skip on a non-sensitive batch is honored + audited
py_lines 200 > "$RG/scratch_tool.py"
printf 'skipped-by=model reason=one-off-analysis-script scope=200lines/1file\n' > "$BYPASSG"
run_hook "$VF" "$STOPG"
assert_eq "g4: model-skip on non-sensitive batch allows" "$OUT" ""
assert_file_absent "g4: flag consumed" "$BYPASSG"
assert_eq "g4: model-skip advances baseline" "$(baseline_head "$BASELINEG")" "$(git_f "$RG" rev-parse HEAD)"
assert_contains "g4: skip audited with its reason" "$(cat "$SKIPLOGG" 2>/dev/null)" "one-off-analysis-script"

# g11: model-skip missing the scope field is malformed -> rejected + audited
py_lines 200 > "$RG/scratch2.py"
printf 'skipped-by=model reason=no-scope-given\n' > "$BYPASSG"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "g11: scope-less model-skip blocks" "$DEC" "block"
assert_file_absent "g11: malformed flag consumed" "$BYPASSG"
assert_contains "g11: malformed skip audited as rejected" "$(cat "$SKIPLOGG" 2>/dev/null)" "model-skip-rejected"
valid_marker "$SELF_MG" solo
run_hook "$VF" "$STOPG"
assert_eq "g11 cleanup: state certified" "$OUT" ""

# g15: protected-paths hit counts as floor (not only the sensitive regex)
mkdir -p "$RG/.claude" "$RG/vault"
printf 'vault/\n' > "$RG/.claude/protected-paths"
py_lines 200 > "$RG/vault/core.py"
printf 'skipped-by=model reason=throwaway scope=200lines/1file\n' > "$BYPASSG"
run_hook "$VF" "$STOPG"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g15: model-skip on protected-path batch blocks" "$DEC" "block"
assert_contains "g15: floor language present" "$REASON" "only the USER can skip"
assert_contains "g15: protected rejection audited" "$(cat "$SKIPLOGG" 2>/dev/null)" "model-skip-rejected"
valid_marker "$SELF_MG" solo
run_hook "$VF" "$STOPG"
assert_eq "g15 cleanup: state certified" "$OUT" ""

# g12: sensitive scan must run BEFORE the extension filter — an SQL-only
# migration batch must block (pre-existing hole: .sql is not a "business"
# extension, so today the gate advances the baseline right past it)
RG3="$WORK/g-repo-sql"; make_repo "$RG3"
SIDG3="${SID_PREFIX}-gsql"
STOPG3="{\"session_id\":\"${SIDG3}\",\"cwd\":\"${RG3}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
run_hook "$SS" "{\"session_id\":\"${SIDG3}\",\"cwd\":\"${RG3}\"}"
mkdir -p "$RG3/migrations"
for i in $(seq 1 200); do echo "ALTER TABLE t ADD COLUMN c$i integer;"; done > "$RG3/migrations/001.sql"
run_hook "$VF" "$STOPG3"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g12: migration-SQL-only batch blocks" "$DEC" "block"
assert_contains "g12: reason names the sql file" "$REASON" "migrations/001.sql"

# g13: business filter must run before any truncation — 60 早序 junk files
# must not push a sensitive business file out of the gate's view
RG4="$WORK/g-repo-trunc"; make_repo "$RG4"
SIDG4="${SID_PREFIX}-gtrunc"
STOPG4="{\"session_id\":\"${SIDG4}\",\"cwd\":\"${RG4}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
run_hook "$SS" "{\"session_id\":\"${SIDG4}\",\"cwd\":\"${RG4}\"}"
for i in $(seq -w 1 60); do echo "note $i" > "$RG4/aaa_note_$i.txt"; done
py_lines 160 > "$RG4/auth_zz.py"
run_hook "$VF" "$STOPG4"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g13: sensitive file behind 60 junk paths still blocks" "$DEC" "block"
assert_contains "g13: reason names the hidden business file" "$REASON" "auth_zz.py"

# g14/g16: unmeasurable state (no baseline) fail-closed for BOTH new doors
RG2="$WORK/g-repo-nobase"; make_repo "$RG2"
SIDG2="${SID_PREFIX}-gnobase"
BYPASSG2="/tmp/claude-skip-review-${SIDG2}"
DEFERG2="/tmp/claude-kit-defer-${SIDG2}"
SKIPLOGG2="/tmp/claude-kit-skiplog-${SIDG2}.jsonl"
STOPG2="{\"session_id\":\"${SIDG2}\",\"cwd\":\"${RG2}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
py_lines 200 > "$RG2/f.py"
printf 'skipped-by=model reason=x scope=200/1\n' > "$BYPASSG2"
run_hook "$VF" "$STOPG2"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "g14: model-skip with no baseline fails closed" "$DEC" "block"
assert_file_absent "g14: flag consumed" "$BYPASSG2"
assert_contains "g14: rejection audited" "$(cat "$SKIPLOGG2" 2>/dev/null)" "model-skip-rejected"
printf 'deferred-by=model reason=x\n' > "$DEFERG2"
run_hook "$VF" "$STOPG2"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g16: defer with no baseline fails closed" "$DEC" "block"
assert_file_absent "g16: unmeasurable defer consumed" "$DEFERG2"
assert_contains "g16: reason says the batch is not measurable" "$REASON" "not measurable"

# g17: audit fail-closed — unwritable skiplog voids a model-skip
RG5="$WORK/g-repo-audit"; make_repo "$RG5"
SIDG5="${SID_PREFIX}-gaudit"
BYPASSG5="/tmp/claude-skip-review-${SIDG5}"
SKIPLOGG5="/tmp/claude-kit-skiplog-${SIDG5}.jsonl"
STOPG5="{\"session_id\":\"${SIDG5}\",\"cwd\":\"${RG5}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
run_hook "$SS" "{\"session_id\":\"${SIDG5}\",\"cwd\":\"${RG5}\"}"
py_lines 200 > "$RG5/tool.py"
mkdir -p "$SKIPLOGG5"   # a directory at the log path makes appends fail
printf 'skipped-by=model reason=throwaway scope=200/1\n' > "$BYPASSG5"
run_hook "$VF" "$STOPG5"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g17: unwritable audit log voids the model-skip" "$DEC" "block"
assert_contains "g17: reason names the unwritable audit log" "$REASON" "audit log unwritable"
assert_file_absent "g17: flag consumed" "$BYPASSG5"
rmdir "$SKIPLOGG5" 2>/dev/null

# g18: enumeration failure must not certify — corrupt real index makes
# `git status` fail while the temp-index tree hash still works; an empty
# changed list must fall through to a block, never advance the baseline
RG6="$WORK/g-repo-scan"; make_repo "$RG6"
SIDG6="${SID_PREFIX}-gscan"
BASELINEG6="/tmp/claude-kit-baseline-${SIDG6}"
STOPG6="{\"session_id\":\"${SIDG6}\",\"cwd\":\"${RG6}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
run_hook "$SS" "{\"session_id\":\"${SIDG6}\",\"cwd\":\"${RG6}\"}"
py_lines 200 > "$RG6/f.py"
BT6_BEFORE="$(baseline_tree "$BASELINEG6")"
printf 'garbage-not-an-index' > "$RG6/.git/index"
run_hook "$VF" "$STOPG6"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g18: scan failure blocks instead of certifying" "$DEC" "block"
assert_contains "g18: reason names the enumeration failure" "$REASON" "enumeration failed"
assert_eq "g18: baseline NOT advanced on scan failure" "$(baseline_tree "$BASELINEG6")" "$BT6_BEFORE"

# g19/g20/g21: tampered/limit defer stamps must degrade to block, never crash
RG7="$WORK/g-repo-stamp"; make_repo "$RG7"
SIDG7="${SID_PREFIX}-gstamp"
DEFERG7="/tmp/claude-kit-defer-${SIDG7}"
SELF_MG7="/tmp/claude-reviewed-${SIDG7}"
STOPG7="{\"session_id\":\"${SIDG7}\",\"cwd\":\"${RG7}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
run_hook "$SS" "{\"session_id\":\"${SIDG7}\",\"cwd\":\"${RG7}\"}"
py_lines 410 > "$RG7/big.py"
# g19: zero-padded stamp (octal trap) — numerically valid, leash long blown:
# the hook must EMIT BLOCK JSON, not die on an arithmetic error (fail-open)
printf 'deferred-by=model reason=x\nlines=008\nfiles=001\n' > "$DEFERG7"
run_hook "$VF" "$STOPG7"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "g19: hook exits 0 on zero-padded stamp" "$CODE" "0"
assert_eq "g19: zero-padded stamp still yields a block decision" "$DEC" "block"
assert_file_absent "g19: defer consumed" "$DEFERG7"
# g20: absurd-length digit string is not a stamp the hook could have written
printf 'deferred-by=model reason=x\nlines=999999999999\nfiles=1\n' > "$DEFERG7"
run_hook "$VF" "$STOPG7"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g20: overlong stamp blocks" "$DEC" "block"
assert_contains "g20: reason names the invalid defer" "$REASON" "invalid defer"
assert_file_absent "g20: tampered defer consumed" "$DEFERG7"
# g21: the file-count leash — 9 one-line business files after a valid defer
# must expire it even though line growth stays far under 150
printf 'deferred-by=model reason=mid-flight\n' > "$DEFERG7"
run_hook "$VF" "$STOPG7"
assert_eq "g21 setup: defer stamped and allowed" "$OUT" ""
for i in $(seq 1 9); do echo "print('pad $i')" > "$RG7/pad_$i.py"; done
run_hook "$VF" "$STOPG7"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "g21: file-count growth past the leash re-blocks" "$DEC" "block"
assert_contains "g21: expiry note mentions the file leash" "$REASON" "business files"
assert_file_absent "g21: expired defer consumed" "$DEFERG7"
valid_marker "$SELF_MG7" solo
run_hook "$VF" "$STOPG7"
assert_eq "g21 cleanup: state certified" "$OUT" ""

# ===========================================================================
# H3 - classify-task.sh (explicit overrides + per-turn judgment digest)
# ===========================================================================
CT="$HOOKS/classify-task.sh"

ct_ctx() {  # $1 = prompt json string value (plain text, no quotes inside)
  run_hook "$CT" "{\"session_id\":\"${SID_PREFIX}-h3\",\"prompt\":\"$1\"}"
  CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
}

ct_ctx "just do it please"
assert_contains "h3: 'just do it' -> explicit_skip" "$CTX" "explicit_skip"
assert_contains "h3: override still carries judgment digest" "$CTX" "KIT_JUDGMENT"
ct_ctx "直接做,不用問"
assert_contains "h3: zh skip phrase -> explicit_skip" "$CTX" "explicit_skip"
ct_ctx "please run the full workflow on this"
assert_contains "h3: 'full workflow' -> explicit_full" "$CTX" "explicit_full"
ct_ctx "這個要走完整流程"
assert_contains "h3: zh full phrase -> explicit_full" "$CTX" "explicit_full"

# heuristic branches are GONE: these used to classify, now must emit the
# digest ONLY (v4.1) — never a TASK_CLASSIFICATION
ct_ctx "fix this bug in the login flow"
assert_not_contains "h3: bug-fix prompt no longer classified" "$CTX" "TASK_CLASSIFICATION"
assert_contains "h3: ordinary prompt gets judgment digest" "$CTX" "KIT_JUDGMENT"
ct_ctx "change the button color to blue"
assert_not_contains "h3: UI prompt no longer classified" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "refactor the payment module"
assert_not_contains "h3: refactor prompt no longer classified" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "implement a new feature for exports"
assert_not_contains "h3: feature prompt no longer classified" "$CTX" "TASK_CLASSIFICATION"

# v4.3 descriptive-context guard: sentences DESCRIBING the workflow must
# not classify (real misfire 2026-07-10: "一直在走完整流程" -> explicit_full)
ct_ctx "我發現模型常常會到最後變成一直在走完整流程"
assert_not_contains "h3: descriptive zh full-workflow sentence not classified" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "it keeps running the full review on tiny fixes"
assert_not_contains "h3: descriptive en full-review sentence not classified" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "模型總是不需要 review 就出事"
assert_not_contains "h3: descriptive zh skip sentence not classified as skip" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "the model always says skip review"
assert_not_contains "h3: reported speech skip phrase not classified (codex finding)" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "請走完整流程"
assert_contains "h3: imperative zh full phrase still classifies" "$CTX" "explicit_full"

# descriptive size words are NOT explicit overrides (round 1, P2)
ct_ctx "this should be a small change in the auth middleware"
assert_not_contains "h3: descriptive 'small change' does not opt out" "$CTX" "TASK_CLASSIFICATION"
ct_ctx "we need a quick fix for the login bug"
assert_not_contains "h3: descriptive 'quick fix' does not opt out" "$CTX" "TASK_CLASSIFICATION"

# field-name tolerance: user_input instead of prompt
run_hook "$CT" "{\"session_id\":\"${SID_PREFIX}-h3\",\"user_input\":\"just do it\"}"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h3: .user_input field accepted" "$CTX" "explicit_skip"

# empty / missing prompt -> fully silent (no digest on empty input)
run_hook "$CT" "{}"
assert_eq "h3: empty input silent" "$OUT" ""

# v4.8: classify-task snapshots the working tree at turn start (feeds the
# Stop gate's turn-scoped enforcement). Runs regardless of prompt content.
CT_R="$WORK/h3-turnstart-repo"; make_repo "$CT_R"
CT_SID="${SID_PREFIX}-h3ts"; CT_TS="/tmp/claude-kit-turnstart-${CT_SID}"
rm -f "$CT_TS"
run_hook "$CT" "{\"session_id\":\"${CT_SID}\",\"cwd\":\"${CT_R}\",\"prompt\":\"hello\"}"
assert_file_exists "h3: classify-task writes turn-start snapshot in a git repo" "$CT_TS"
if sed -n '1p' "$CT_TS" 2>/dev/null | grep -qE '^[0-9a-f]{40}$'; then
  pass "h3: snapshot is a tree hash"
else
  fail "h3: snapshot is a tree hash" "got [$(cat "$CT_TS" 2>/dev/null)]"
fi
# rewritten every prompt (NOT write-if-missing): an edit changes the hash
FIRST_TS="$(cat "$CT_TS" 2>/dev/null)"
py_lines 3 > "$CT_R/new.py"
run_hook "$CT" "{\"session_id\":\"${CT_SID}\",\"cwd\":\"${CT_R}\",\"prompt\":\"again\"}"
if [ "$(cat "$CT_TS" 2>/dev/null)" != "$FIRST_TS" ]; then
  pass "h3: snapshot rewritten each prompt (reflects the new edit)"
else
  fail "h3: snapshot rewritten each prompt" "hash unchanged after an edit"
fi
# snapshotting must not disturb the classification/digest output
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h3: snapshot side-channel leaves the digest intact" "$CTX" "KIT_JUDGMENT"
# non-git cwd: no snapshot, no error
NG="$WORK/h3-nongit-ts"; mkdir -p "$NG"; NG_SID="${SID_PREFIX}-h3ng"
run_hook "$CT" "{\"session_id\":\"${NG_SID}\",\"cwd\":\"${NG}\",\"prompt\":\"hi\"}"
assert_eq "h3: non-git classify still exit 0" "$CODE" "0"
assert_file_absent "h3: non-git writes no snapshot" "/tmp/claude-kit-turnstart-${NG_SID}"
# gate disabled: the snapshot is unused work, so it must be skipped — but the
# judgment digest must still be emitted (codex finding, 2026-07-24)
GOFF_SID="${SID_PREFIX}-h3goff"; GOFF_TS="/tmp/claude-kit-turnstart-${GOFF_SID}"
rm -f "$GOFF_TS"
run_hook "$CT" "{\"session_id\":\"${GOFF_SID}\",\"cwd\":\"${CT_R}\",\"prompt\":\"hi\"}" full KIT_REVIEW_GATE=off
assert_file_absent "h3: gate-off skips the unused turn snapshot" "$GOFF_TS"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h3: gate-off still emits the judgment digest" "$CTX" "KIT_JUDGMENT"
# fail-closed: a recompute that can't run (non-git cwd) CLEARS a stale prior
# snapshot rather than leaving it for the Stop gate to misread (codex finding)
STALE_SID="${SID_PREFIX}-h3stale"; STALE_TS="/tmp/claude-kit-turnstart-${STALE_SID}"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$STALE_TS"
run_hook "$CT" "{\"session_id\":\"${STALE_SID}\",\"cwd\":\"${NG}\",\"prompt\":\"hi\"}"
assert_file_absent "h3: stale snapshot cleared when recompute can't run" "$STALE_TS"

# v4.9 defer reminder rides the SAME single JSON context (a second output
# document would corrupt the hook protocol — codex finding 2026-08-02)
DR_SID="${SID_PREFIX}-h3defer"
DR_DEFER="/tmp/claude-kit-defer-${DR_SID}"
printf 'deferred-by=model reason=x\n' > "$DR_DEFER"
run_hook "$CT" "{\"session_id\":\"${DR_SID}\",\"prompt\":\"hello\"}"
DR_CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h3: defer reminder present when defer file exists" "$DR_CTX" "deferred unreviewed batch"
assert_contains "h3: reminder shares the digest context (merged, not appended)" "$DR_CTX" "KIT_JUDGMENT"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  pass "h3: defer-reminder output is a single valid JSON doc"
else
  fail "h3: defer-reminder output is a single valid JSON doc" "jq parse failed on stdout"
fi
rm -f "$DR_DEFER"
run_hook "$CT" "{\"session_id\":\"${DR_SID}\",\"prompt\":\"hello\"}"
DR_CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_not_contains "h3: no reminder without a defer file" "$DR_CTX" "deferred unreviewed batch"

# ===========================================================================
# H4 - protect-paths.sh (v4.0 no-touch-zone enforcement)
# ===========================================================================
PP="$HOOKS/protect-paths.sh"
R4="$WORK/h4-repo"
make_repo "$R4"
# the hook matches paths, it never stats targets — only .claude/ (for the
# protected-paths list written below) needs to actually exist
mkdir -p "$R4/.claude"

pp_json() {  # $1 = file_path value  [$2 = tool_input key, default file_path]
  local key="${2:-file_path}"
  printf '{"session_id":"%s-h4","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"%s":"%s"}}' \
    "$SID_PREFIX" "$R4" "$key" "$1"
}
pp_decision() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null; }
pp_reason()   { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# kit-owned defaults (fixture is NOT a kit repo -> default set active).
# kit-owned files escalate to the USER ("ask"): approvable when present,
# effectively blocked unattended — NOT a hard deny (that's for user zones).
run_hook "$PP" "$(pp_json "$R4/.claude/rules/kit-workflow.md")"
assert_eq "h4: kit-owned rules file escalates to ask" "$(pp_decision)" "ask"
assert_contains "h4: kit-owned ask cites kit-evolution" "$(pp_reason)" "kit-evolution"
run_hook "$PP" "$(pp_json "$R4/.claude/settings.json")"
assert_eq "h4: settings.json escalates to ask (harness wiring)" "$(pp_decision)" "ask"
run_hook "$PP" "$(pp_json "$R4/.claude/scripts/helper.sh")"
assert_eq "h4: scripts dir escalates to ask (kit-owned)" "$(pp_decision)" "ask"
# protected-paths is PROJECT-owned: the workflow tells the model to ADD
# entries (CLAUDE.md constraints sync), so it must NOT be hard-denied
run_hook "$PP" "$(pp_json "$R4/.claude/protected-paths")"
assert_eq "h4: protected-paths list itself editable (project-owned)" "$OUT" ""
run_hook "$PP" "$(pp_json "$R4/src/ok.py")"
assert_eq "h4: normal file allowed" "$OUT" ""
# dot-segment smuggling must not slip past normalization
run_hook "$PP" "$(pp_json "$R4/src/../.claude/settings.json")"
assert_eq "h4: dot-dot smuggling to kit file still caught" "$(pp_decision)" "ask"

# user-declared zones: trailing-slash subtree, glob, comments, blanks
cat > "$R4/.claude/protected-paths" <<'EOF'
# no-touch zones (smoke fixture)
src/legacy/

*.secret
EOF
run_hook "$PP" "$(pp_json "$R4/src/legacy/deep/pay.py")"
assert_eq "h4: trailing-slash pattern covers subtree" "$(pp_decision)" "deny"
run_hook "$PP" "$(pp_json "$R4/src/./legacy/./deep/pay.py")"
assert_eq "h4: single-dot segments normalized before match" "$(pp_decision)" "deny"
assert_contains "h4: user-zone deny names the pattern" "$(pp_reason)" "src/legacy/"
assert_contains "h4: user-zone deny routes to the user" "$(pp_reason)" "ask the user"
run_hook "$PP" "$(pp_json "$R4/config.secret")"
assert_eq "h4: glob pattern matches" "$(pp_decision)" "deny"
run_hook "$PP" "$(pp_json "$R4/src/ok.py")"
assert_eq "h4: unlisted file still allowed with list present" "$OUT" ""
run_hook "$PP" "$(pp_json "src/legacy/x.py")"
assert_eq "h4: already-relative path matched too" "$(pp_decision)" "deny"
# a trailing slash in cwd must not break the prefix match (silent fail-open)
run_hook "$PP" "$(printf '{"session_id":"%s-h4","cwd":"%s/","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/src/legacy/deep/pay.py"}}' "$SID_PREFIX" "$R4" "$R4")"
assert_eq "h4: trailing-slash cwd still enforced" "$(pp_decision)" "deny"
run_hook "$PP" "$(pp_json "$R4/src/legacy/nb.ipynb" notebook_path)"
assert_eq "h4: notebook_path field covered" "$(pp_decision)" "deny"

# user-only escape hatch
run_hook "$PP" "$(pp_json "$R4/src/legacy/deep/pay.py")" full KIT_PROTECT=off
assert_eq "h4: KIT_PROTECT=off disables enforcement" "$OUT" ""

# kit repo detection: default set off, user list still enforced; a deployed
# project (has .claude/kit-version) is NEVER treated as the kit repo even if
# it happens to ship init.sh/VERSION/templates of its own
touch "$R4/init.sh" "$R4/VERSION"
mkdir -p "$R4/templates"
run_hook "$PP" "$(pp_json "$R4/.claude/rules/kit-workflow.md")"
assert_eq "h4: kit repo may edit kit-owned files" "$OUT" ""
run_hook "$PP" "$(pp_json "$R4/src/legacy/deep/pay.py")"
assert_eq "h4: user zones still enforced inside kit repo" "$(pp_decision)" "deny"
echo "v9.9.9 abcdef0 2026-01-01" > "$R4/.claude/kit-version"
run_hook "$PP" "$(pp_json "$R4/.claude/rules/kit-workflow.md")"
assert_eq "h4: kit-version sentinel overrides lookalike kit repo" "$(pp_decision)" "ask"
rm -f "$R4/init.sh" "$R4/VERSION" "$R4/.claude/kit-version"; rmdir "$R4/templates"

# malformed / empty input -> silent allow
run_hook "$PP" "{}"
assert_eq "h4: empty input silent" "$OUT" ""
assert_eq "h4: empty input exit 0" "$CODE" "0"

# ===========================================================================
# H5 - tool-breaker.sh (v4.0 retry-spiral breaker + telemetry)
# ===========================================================================
TB="$HOOKS/tool-breaker.sh"

tb_call() {  # $1 = session-id suffix  $2 = tool_name  $3 = command string
  printf '{"session_id":"%s-%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"%s"}}' \
    "$SID_PREFIX" "$1" "$WORK" "$2" "$3"
}
tb_fail() {  # $1 = session-id suffix  $2 = tool_name
  printf '{"session_id":"%s-%s","cwd":"%s","hook_event_name":"PostToolUseFailure","tool_name":"%s"}' \
    "$SID_PREFIX" "$1" "$WORK" "$2"
}
tb_decision() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null; }

# identical x2 allowed, x3 denied, different call resets
run_hook "$TB" "$(tb_call h5 Bash 'make test')"
assert_eq "h5: 1st call allowed" "$OUT" ""
run_hook "$TB" "$(tb_call h5 Bash 'make test')"
assert_eq "h5: 2nd identical allowed" "$OUT" ""
run_hook "$TB" "$(tb_call h5 Bash 'make test')"
assert_eq "h5: 3rd identical denied" "$(tb_decision)" "deny"
assert_contains "h5: deny message is the circuit breaker" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')" "CIRCUIT BREAKER"
run_hook "$TB" "$(tb_call h5 Bash 'make test-v2')"
assert_eq "h5: changed arguments reset the breaker" "$OUT" ""
LOG5="/tmp/claude-kit-toollog-${SID_PREFIX}-h5.jsonl"
assert_file_exists "h5: telemetry log written" "$LOG5"
if grep -q '"e":"deny"' "$LOG5" 2>/dev/null; then
  pass "h5: deny event logged"
else
  fail "h5: deny event logged" "no deny line in $LOG5"
fi
# privacy promise: hashes only, raw tool arguments never reach the log
if grep -q 'make test' "$LOG5" 2>/dev/null; then
  fail "h5: telemetry log carries no raw arguments" "found raw command text in $LOG5"
else
  pass "h5: telemetry log carries no raw arguments"
fi

# polling tools are exempt AND do not reset a building spiral
run_hook "$TB" "$(tb_call h5b Edit 'same')"
run_hook "$TB" "$(tb_call h5b Edit 'same')"
run_hook "$TB" "$(tb_call h5b TaskOutput 'poll')"
assert_eq "h5: polling tool exempt from breaker" "$OUT" ""
run_hook "$TB" "$(tb_call h5b Edit 'same')"
assert_eq "h5: poll between identical calls does not reset spiral" "$(tb_decision)" "deny"
run_hook "$TB" "$(tb_call h5c TaskOutput 'poll')"
run_hook "$TB" "$(tb_call h5c TaskOutput 'poll')"
run_hook "$TB" "$(tb_call h5c TaskOutput 'poll')"
assert_eq "h5: identical polling never denied" "$OUT" ""

# failure-density soft warning: 3rd recent failure -> exit 2 + stderr
run_hook "$TB" "$(tb_fail h5d Bash)"
assert_eq "h5: 1st failure quiet" "$CODE" "0"
run_hook "$TB" "$(tb_fail h5d Bash)"
assert_eq "h5: 2nd failure quiet" "$CODE" "0"
run_hook "$TB" "$(tb_fail h5d Bash)"
assert_eq "h5: 3rd failure warns via exit 2" "$CODE" "2"
assert_contains "h5: warning tells the model to stop retrying" "$ERR" "STOP retrying"

# a failure event must NOT reset a building identical-call spiral
run_hook "$TB" "$(tb_call h5f Bash 'same-cmd')"
run_hook "$TB" "$(tb_call h5f Bash 'same-cmd')"
run_hook "$TB" "$(tb_fail h5f Bash)"
run_hook "$TB" "$(tb_call h5f Bash 'same-cmd')"
assert_eq "h5: failure event does not reset the spiral counter" "$(tb_decision)" "deny"

# user-only escape hatch + malformed input
run_hook "$TB" "$(tb_call h5e Bash 'x')" full KIT_BREAKER=off
run_hook "$TB" "$(tb_call h5e Bash 'x')" full KIT_BREAKER=off
run_hook "$TB" "$(tb_call h5e Bash 'x')" full KIT_BREAKER=off
assert_eq "h5: KIT_BREAKER=off disables the breaker" "$OUT" ""
run_hook "$TB" "{}"
assert_eq "h5: empty input silent" "$OUT" ""
assert_eq "h5: empty input exit 0" "$CODE" "0"

# ===========================================================================
# V - verifier-pipe guard (v4.10, in tool-breaker.sh). RED-first. Receipt:
#     a piped test runner reports the FILTER's exit code; quant chained
#     `pytest | tail && git commit` 3x in one real session. Contract: four
#     stages (waivers -> newline fold -> quote neutralizer -> one ordered
#     regex); prefer false negatives; anti-footgun NOT anti-evasion
#     (deliberate quote-splitting is out of scope per the v4.9 threat
#     boundary — a Bash-holder can rewrite the baseline file directly).
# ===========================================================================
tbv() {  # $1 = session-id suffix  $2 = raw command (jq-escaped into JSON)
  jq -cn --arg sid "${SID_PREFIX}-$1" --arg cwd "$WORK" --arg cmd "$2" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd}}'
}
VLOG_SID() { printf '/tmp/claude-kit-toollog-%s-%s.jsonl' "$SID_PREFIX" "$1"; }

run_hook "$TB" "$(tbv v1 'pytest -q tests/ | tail -5 && git commit -m wip')"
assert_eq "v1: piped runner + commit chain denied" "$(tb_decision)" "deny"
REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
assert_contains "v1: reason teaches pipefail" "$REASON" "pipefail"
assert_contains "v1: reason names the exit-code mechanism" "$REASON" "exit code"

run_hook "$TB" "$(tbv v2 'set -o pipefail; pytest -q | tee out.log && git commit -m ok')"
assert_eq "v2: pipefail waives the guard" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v3 'pytest -q | tail -5')"
assert_eq "v3: no commit chain allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v4 'npm test | grep -v warn ; git push origin main')"
assert_eq "v4: npm test pipe + push denied" "$(tb_decision)" "deny"

run_hook "$TB" "$(tbv v5 'pytest -q || git commit -m fallback')"
assert_eq "v5: || is not a pipe" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v6 'cat data.txt | grep foo && git commit -m x')"
assert_eq "v6: non-runner pipe allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v7 'pytest -q tests/ | tail -5 && git commit -m wip')" full KIT_BREAKER=off
assert_eq "v7: KIT_BREAKER=off waives the guard" "$OUT" ""

assert_contains "v8: deny audited as e:deny" "$(cat "$(VLOG_SID v1)" 2>/dev/null)" '"e":"deny"'
assert_contains "v8: deny audited as k:pipe-guard" "$(cat "$(VLOG_SID v1)" 2>/dev/null)" '"k":"pipe-guard"'
assert_not_contains "v8: telemetry carries no raw command" "$(cat "$(VLOG_SID v1)" 2>/dev/null)" "tail -5"
assert_not_contains "v8: pre-guard events carry no k field" "$(cat "$(VLOG_SID v3)" 2>/dev/null)" '"k":'

run_hook "$TB" "$(tbv v9 "printf '%s' 'pytest | tail && git commit' > repro.txt && git commit -m docs")"
assert_eq "v9: printf-quoted shape allowed (waiver + anchor)" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v10 'cat <<EOF > doc.md
pytest | tail && git commit
EOF
git commit -m docs')"
assert_eq "v10: heredoc containing the shape allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v11 'git commit -m x && pytest -q | tail -3')"
assert_eq "v11: commit BEFORE the pipe allowed (ordering)" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v12 'pytest -q | tail -5
git commit -m y')"
assert_eq "v12: newline-separated commit denied (fold)" "$(tb_decision)" "deny"

run_hook "$TB" "$(tbv v13 'set +o pipefail; pytest -q | tail && git commit -m z')"
assert_eq "v13: set +o pipefail allowed — DOCUMENTED false negative" "$(tb_decision)" ""

# v14: a pipe-guard deny between two identical calls keeps the spiral
# invariant — the denied attempt was still logged as a call in between
run_hook "$TB" "$(tbv v14 'echo alpha')"
run_hook "$TB" "$(tbv v14 'pytest -q | tail && git commit -m spiral')"
run_hook "$TB" "$(tbv v14 'echo alpha')"
assert_eq "v14: guarded call between identical calls resets nothing wrongly" "$(tb_decision)" ""

# v15: repeated unsafe command keeps getting the SPECIFIC pipe-guard reason
run_hook "$TB" "$(tbv v15 'pytest -q | tail && git commit -m again')"
run_hook "$TB" "$(tbv v15 'pytest -q | tail && git commit -m again')"
run_hook "$TB" "$(tbv v15 'pytest -q | tail && git commit -m again')"
REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
assert_eq "v15: third unsafe call still denied" "$(tb_decision)" "deny"
assert_contains "v15: pipe-guard message wins over generic breaker" "$REASON" "pipefail"

# v16: polling exemption untouched (regression) — covered by h5 polling
# cases above; assert the guard did not add k to poll events
run_hook "$TB" "$(tb_call h5c TaskOutput 'poll')"
assert_eq "v16: polling still exempt" "$OUT" ""

run_hook "$TB" "$(tbv v17 "pytest -q | grep '&& git commit'")"
assert_eq "v17: quoted filter argument allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v18 "pytest -q | sed -n '/; git commit/p'")"
assert_eq "v18: quoted sed program allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v19 "FOO=' pytest -q | tail && git commit'; echo done")"
assert_eq "v19: quoted assignment allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v20 "pytest -q | tail && 'printf' git commit")"
assert_eq "v20: placeholder keeps word position (no phantom git)" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v21 "pytest -q | tail && g'it' commit -m x")"
assert_eq "v21: quote-split evasion allowed — OUT OF SCOPE (anti-footgun, not anti-evasion)" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v22 "pytest -q | tail && 'mytool' git commit")"
assert_eq "v22: quoted executable + git-looking args allowed" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v23 'pytest -q | grep "foo\" && git commit"')"
assert_eq "v23: escaped double quote stays data" "$(tb_decision)" ""

run_hook "$TB" "$(tbv v24 'pytest -q | tail && git commit -m "fix \"quoted\" msg"')"
assert_eq "v24: real commit with escaped-quote message denied" "$(tb_decision)" "deny"

run_hook "$TB" "$(tbv v25 "pytest -q | grep -F \$'foo\\' && git commit'")"
assert_eq "v25: ANSI-C quoted apostrophe stays data" "$(tb_decision)" ""

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
