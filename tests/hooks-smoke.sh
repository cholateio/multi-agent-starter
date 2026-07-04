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
# isolation, an explicit KIT_PROFILE (default full), v4.0 kit toggles forced
# to their defaults (a developer's shell could carry KIT_PROTECT=off), and
# CLAUDE_PROJECT_DIR cleared so hooks fall back to the fixture cwd instead
# of the kit repo this suite runs from. Extra VAR=val args override any of
# these (env(1): later assignments win).
run_hook() {
  local hook="$1" json="$2" profile="${3:-full}"
  shift 3 2>/dev/null || shift $#
  OUT="$(printf '%s' "$json" | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID_CFG" \
        HOME="$FAKE_HOME" env KIT_PROFILE="$profile" KIT_PROTECT=on KIT_BREAKER=on \
        CLAUDE_PROJECT_DIR= "$@" bash "$hook" 2>"$WORK/last-stderr")"
  CODE=$?
  ERR="$(cat "$WORK/last-stderr" 2>/dev/null)"
}

# valid_marker <path> <codex|solo>: write a v4.0 evidence marker (a bare
# touch no longer satisfies the Stop gate)
valid_marker() {
  printf 'reviewed-by=%s verdict=approve scope="smoke fixture" date=2026-01-01\n' "$2" > "$1"
}

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
echo "print('x')" > "$R2/app.py"
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
echo "print('more')" >> "$R2/app.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
assert_eq "h2c3: post-certification edit blocks again" "$DEC" "block"
valid_marker "$SELF_M2" solo
run_hook "$VF" "$STOP_JSON"   # certify + settle for next scenarios
assert_eq "h2c3: self marker settles the state" "$OUT" ""

# (d) THE COMMIT BLIND SPOT: commit business change, then point baseline at
# the pre-commit HEAD (clean tree, no cert) -> must still block
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
echo "print('hidden')" > "$R2/newdir/deep.py"
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
echo "print('y')" > "$R2/app2.py"
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
echo "print('s')" >> "$R2/app.py"
run_hook "$VF" "$STOP_JSON" solo
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_contains "h2m: solo block mentions isolation OFF" "$REASON" "ISOLATION IS OFF"
assert_not_contains "h2m: solo block has no touch incantation" "$REASON" "touch /tmp"
git_f "$R2" checkout -q -- app.py

# (n) filename with a space survives the porcelain parse
echo "x" > "$R2/my app.py"
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
echo "print('edited')" >> "$R2/legacy.py"
run_hook "$VF" "$STOP_JSON"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "h2o: edit to tracked-but-ignored file blocks" "$DEC" "block"
assert_contains "h2o: reason names the ignored-but-tracked file" "$REASON" "legacy.py"
git_f "$R2" checkout -q -- legacy.py
rm -f "$BASELINE2"

# (p) v4.0 anti-forgery: a BARE-TOUCHED marker must not pass — it is
# discarded, called out, and only an evidence marker heals the state
echo "print('forged')" >> "$R2/app.py"
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

# ===========================================================================
# H3 - classify-task.sh (explicit overrides only)
# ===========================================================================
CT="$HOOKS/classify-task.sh"

ct_ctx() {  # $1 = prompt json string value (plain text, no quotes inside)
  run_hook "$CT" "{\"session_id\":\"${SID_PREFIX}-h3\",\"prompt\":\"$1\"}"
  CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
}

ct_ctx "just do it please"
assert_contains "h3: 'just do it' -> explicit_skip" "$CTX" "explicit_skip"
ct_ctx "直接做,不用問"
assert_contains "h3: zh skip phrase -> explicit_skip" "$CTX" "explicit_skip"
ct_ctx "please run the full workflow on this"
assert_contains "h3: 'full workflow' -> explicit_full" "$CTX" "explicit_full"
ct_ctx "這個要走完整流程"
assert_contains "h3: zh full phrase -> explicit_full" "$CTX" "explicit_full"

# heuristic branches are GONE: these used to classify, now must stay silent
ct_ctx "fix this bug in the login flow"
assert_eq "h3: bug-fix prompt no longer classified" "$OUT" ""
ct_ctx "change the button color to blue"
assert_eq "h3: UI prompt no longer classified" "$OUT" ""
ct_ctx "refactor the payment module"
assert_eq "h3: refactor prompt no longer classified" "$OUT" ""
ct_ctx "implement a new feature for exports"
assert_eq "h3: feature prompt no longer classified" "$OUT" ""

# descriptive size words are NOT explicit overrides (round 1, P2)
ct_ctx "this should be a small change in the auth middleware"
assert_eq "h3: descriptive 'small change' does not opt out" "$OUT" ""
ct_ctx "we need a quick fix for the login bug"
assert_eq "h3: descriptive 'quick fix' does not opt out" "$OUT" ""

# field-name tolerance: user_input instead of prompt
run_hook "$CT" "{\"session_id\":\"${SID_PREFIX}-h3\",\"user_input\":\"just do it\"}"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h3: .user_input field accepted" "$CTX" "explicit_skip"

# empty / missing prompt -> silent
run_hook "$CT" "{}"
assert_eq "h3: empty input silent" "$OUT" ""

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

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
