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

# run_hook <hook-path> <stdin-json> [KIT_PROFILE value]
# sets OUT (stdout) and CODE. Env is controlled: only PATH/HOME/git isolation
# and an explicit KIT_PROFILE (default full) reach the hook.
run_hook() {
  local hook="$1" json="$2" profile="${3:-full}"
  OUT="$(printf '%s' "$json" | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID_CFG" \
        HOME="$FAKE_HOME" KIT_PROFILE="$profile" bash "$hook" 2>/dev/null)"
  CODE=$?
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

# solo profile announced
SID1B="${SID_PREFIX}-h1b"
run_hook "$SS" "{\"session_id\":\"${SID1B}\",\"cwd\":\"${R1}\"}" solo
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
assert_contains "h1: solo profile announced" "$CTX" "Active profile: solo"

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

# --- H2 inserted here by Task 2 ---

# --- H3 inserted here by Task 3 ---

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
