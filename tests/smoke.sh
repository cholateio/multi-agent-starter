#!/usr/bin/env bash
# tests/smoke.sh - automated acceptance tests for init.sh (v3.2, spec §8, scenarios 1-7)
#
# bash-only, zero non-standard dependencies (no jq / shellcheck assumed - only
# git + coreutils, same as init.sh itself).
#
# Builds isolated fixture projects under a mktemp -d root and NEVER touches
# the kit repo working tree. Prints "PASS <name>" / "FAIL <name> (reason)" per
# assertion, then "passed N, failed M" - exits 1 if M > 0.
#
# Deliberately no `set -e`: several steps (git rev-list on an unborn branch,
# cmp -s, etc.) are EXPECTED to fail as part of what we're testing, and we
# need to capture their exit codes rather than have the harness abort.

set -uo pipefail

# ---------------------------------------------------------------------------
# locate the kit under test (tests/ is one level below the kit root)
# ---------------------------------------------------------------------------
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SH="$KIT_ROOT/init.sh"

if [ ! -x "$INIT_SH" ]; then
  echo "FAIL setup (init.sh not found/executable at $INIT_SH)"
  echo "passed 0, failed 1"
  exit 1
fi

# ---------------------------------------------------------------------------
# isolated root: everything lives here, cleaned up on exit (incl. failure)
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-smoke.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
# INT/TERM must actually terminate the script (not just clean up and keep
# going) - otherwise a Ctrl-C mid-run rips $WORK out from under the still-
# executing scenarios and produces a cascade of spurious FAILs. Exiting here
# still triggers the EXIT trap above, so cleanup runs exactly once either way.
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# a fully self-contained PATH: symlinks to the real on-disk binaries for
# exactly the tools init.sh/git need, resolved with `type -P` (not
# `command -v`, which can report a shell *function* instead of a path - some
# interactive shells wrap `find`/`grep` etc.). This directory is the *only*
# thing on PATH for child processes below, so host state (e.g. mise being
# installed or not, extra PATH entries) can never leak in.
# ---------------------------------------------------------------------------
TOOLBIN="$WORK/toolbin"
mkdir -p "$TOOLBIN"
for t in bash sh env git mkdir cp rm cat date find cmp diff grep sed mktemp \
         chmod ls dirname basename cut mv touch sort head wc rmdir tr; do
  p="$(type -P "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$TOOLBIN/$t"
done
NOMISE_PATH="$TOOLBIN"

# "has mise" PATH: prepend a directory with a fake, do-nothing `mise` stub.
# init.sh only ever does `command -v mise` - it never executes it - so the
# stub's body is irrelevant as long as it's executable and named `mise`.
MISE_STUB_DIR="$WORK/mise-stub"
mkdir -p "$MISE_STUB_DIR"
cat > "$MISE_STUB_DIR/mise" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MISE_STUB_DIR/mise"
MISE_PATH="$MISE_STUB_DIR:$TOOLBIN"

# ---------------------------------------------------------------------------
# git isolation: GIT_CONFIG_NOSYSTEM + a controlled GIT_CONFIG_GLOBAL file so
# the host's real ~/.gitconfig (gpgsign, aliases, credential helpers, ...)
# can never interfere. One file carries a throwaway test identity; a second,
# empty file simulates "no identity configured" for scenario 7.
# ---------------------------------------------------------------------------
GIT_ID_CFG="$WORK/gitconfig-identity"
cat > "$GIT_ID_CFG" <<'EOF'
[user]
	name = Smoke Test
	email = smoke@example.test
EOF

GIT_EMPTY_CFG="$WORK/gitconfig-empty"
: > "$GIT_EMPTY_CFG"

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

# ---------------------------------------------------------------------------
# counters + PASS/FAIL/report primitives
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }

# report: $1 name  $2 exit-code-of-a-just-run-command (0 = success)  $3 reason-if-fail
report() {
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "$3"; fi
}

assert_eq() {  # $1 name  $2 actual  $3 expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}

assert_file_exists() {  # $1 name  $2 path
  if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi
}

assert_file_absent() {  # $1 name  $2 path
  if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpectedly present: $2"; fi
}

assert_contains() {  # $1 name  $2 haystack  $3 fixed-string needle
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing text: [$3]"; fi
}

assert_not_contains() {  # $1 name  $2 haystack  $3 fixed-string needle
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "unexpectedly contains: [$3]"; else pass "$1"; fi
}

assert_regex() {  # $1 name  $2 haystack  $3 ERE
  if printf '%s\n' "$2" | grep -qE -- "$3"; then pass "$1"; else fail "$1" "no match for /$3/"; fi
}

assert_not_regex() {  # $1 name  $2 haystack  $3 ERE
  if printf '%s\n' "$2" | grep -qE -- "$3"; then fail "$1" "unexpectedly matched /$3/"; else pass "$1"; fi
}

# ---------------------------------------------------------------------------
# scenario-scoped output capture, dumped only if the scenario had a failure
# ---------------------------------------------------------------------------
scenario_start() { SCEN_OUT=""; SCEN_START=$FAIL_COUNT; }

scenario_end() {  # $1 label
  if [ "$FAIL_COUNT" -gt "$SCEN_START" ]; then
    echo "----- output dump: $1 -----"
    printf '%s\n' "$SCEN_OUT"
    echo "----- end dump: $1 -----"
  fi
}

# init_run: run init.sh under full isolation.
#   $1 = GIT_CONFIG_GLOBAL file to use
#   $2 = "nomise" | "mise"
#   $3.. = args to init.sh
# sets OUT (combined stdout+stderr) and CODE (exit code); appends to SCEN_OUT.
init_run() {
  local gitcfg="$1" pathmode="$2" p
  shift 2
  case "$pathmode" in
    nomise) p="$NOMISE_PATH" ;;
    mise)   p="$MISE_PATH" ;;
    *) echo "init_run: bad pathmode [$pathmode]" >&2; return 90 ;;
  esac
  OUT="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$gitcfg" HOME="$FAKE_HOME" PATH="$p" "$INIT_SH" "$@" 2>&1)"
  CODE=$?
  SCEN_OUT="${SCEN_OUT:+$SCEN_OUT$'\n'}--- init.sh $* (exit $CODE) ---
$OUT"
}

# git_ctl: run git against a fixture dir under the same isolation as init_run
# (so host gitconfig - e.g. commit.gpgsign - can never break fixture setup).
git_ctl() {
  local d="$1"
  shift
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID_CFG" HOME="$FAKE_HOME" PATH="$NOMISE_PATH" \
    git -C "$d" "$@"
}

# ===========================================================================
# scenario 1 - new project install
# ===========================================================================
scenario_start
S1="$WORK/s1"
init_run "$GIT_ID_CFG" nomise "$S1"
assert_eq "s1: exit code 0" "$CODE" "0"
assert_file_exists "s1: README.md exists" "$S1/README.md"
assert_file_exists "s1: .gitignore exists" "$S1/.gitignore"
assert_file_exists "s1: CLAUDE.md exists" "$S1/CLAUDE.md"
assert_file_exists "s1: .claude/rules/kit-workflow.md exists" "$S1/.claude/rules/kit-workflow.md"
assert_file_exists "s1: docs/specs/.gitkeep exists" "$S1/docs/specs/.gitkeep"
assert_file_exists "s1: .claude/kit-version exists" "$S1/.claude/kit-version"
assert_file_absent "s1: no PROMPTING.md" "$S1/PROMPTING.md"
BRANCH="$(git_ctl "$S1" symbolic-ref --short HEAD 2>/dev/null)" || BRANCH="ERR"
assert_eq "s1: branch is main" "$BRANCH" "main"
REVCOUNT="$(git_ctl "$S1" rev-list --count HEAD 2>/dev/null)" || REVCOUNT="ERR"
assert_eq "s1: exactly 1 commit" "$REVCOUNT" "1"
assert_contains "s1: mode detected as new" "$OUT" "mode: new"
# kit-version content: "v<VERSION> <sha-or-unknown> <YYYY-MM-DD>", e.g.
# "v3.2.0 ed4dd86 2026-07-04" - built from the kit repo's own VERSION file
# so this doesn't need hand-updating on every release bump.
KVER_ESC="$(sed 's/\./\\./g' "$KIT_ROOT/VERSION" 2>/dev/null || echo '0\.0\.0')"
KVER_REGEX="^v${KVER_ESC} ([0-9a-f]+|unknown) [0-9]{4}-[0-9]{2}-[0-9]{2}\$"
assert_regex "s1: kit-version content format" "$(cat "$S1/.claude/kit-version" 2>/dev/null)" "$KVER_REGEX"
# kit-version is now written BEFORE the initial commit, so a fresh install's
# working tree must be fully clean (nothing left untracked/uncommitted).
PORCELAIN="$(git_ctl "$S1" status --porcelain 2>&1)"
assert_eq "s1: git status is clean after install (kit-version committed)" "$PORCELAIN" ""
scenario_end "scenario 1: new project install"

# ===========================================================================
# scenario 2 - install is idempotent on rerun (same dir as scenario 1)
#
# note: rerunning plain install mode on an already-populated dir is NOT a
# byte-for-byte no-op: whenever target/CLAUDE.md already exists, init.sh
# unconditionally (re)writes CLAUDE.md.from-kit alongside it (design doc
# 2026-07-04-kit-v3.2-bootstrap-and-docs-design.md line 62: "CLAUDE.md ...
# 存在時仍沿用現行邏輯另存 CLAUDE.md.from-kit"). That's intentional,
# inherited behaviour, not a T4 bug - so "idempotent" here means "no *other*
# new files, all real content untouched, and CLAUDE.md.from-kit == the kit's
# own CLAUDE.md" rather than "literally zero new files".
# ===========================================================================
scenario_start
CKSUM_README_1="$(cksum "$S1/README.md")"
CKSUM_CLAUDE_1="$(cksum "$S1/CLAUDE.md")"
CKSUM_KWF_1="$(cksum "$S1/.claude/rules/kit-workflow.md")"
FILELIST_BEFORE="$(find "$S1" -type f | sort)"
init_run "$GIT_ID_CFG" nomise "$S1"
assert_eq "s2: exit code 0" "$CODE" "0"
assert_not_regex "s2: no '+ ' (copied) lines in output" "$OUT" '^  \+ '
assert_contains "s2: mode detected as existing" "$OUT" "mode: existing"
assert_eq "s2: README.md checksum unchanged" "$(cksum "$S1/README.md")" "$CKSUM_README_1"
assert_eq "s2: CLAUDE.md checksum unchanged" "$(cksum "$S1/CLAUDE.md")" "$CKSUM_CLAUDE_1"
assert_eq "s2: kit-workflow.md checksum unchanged" "$(cksum "$S1/.claude/rules/kit-workflow.md")" "$CKSUM_KWF_1"
FILELIST_AFTER="$(find "$S1" -type f -not -name 'CLAUDE.md.from-kit' | sort)"
assert_eq "s2: no new files besides CLAUDE.md.from-kit" "$FILELIST_AFTER" "$FILELIST_BEFORE"
cmp -s "$KIT_ROOT/CLAUDE.md" "$S1/CLAUDE.md.from-kit"
report "s2: CLAUDE.md.from-kit matches kit's CLAUDE.md" $? "content differs from $KIT_ROOT/CLAUDE.md"
scenario_end "scenario 2: idempotent reinstall"

# ===========================================================================
# scenario 3 - `--update` restores a tampered kit-owned file
# ===========================================================================
scenario_start
S3="$WORK/s3"
init_run "$GIT_ID_CFG" nomise "$S3"
report "s3 setup: initial install succeeded" "$CODE" "install failed: $OUT"
CKSUM_README_PRE="$(cksum "$S3/README.md")"
CKSUM_CLAUDE_PRE="$(cksum "$S3/CLAUDE.md")"
printf 'MUTATED CONTENT - --update must restore this file\n' > "$S3/.claude/rules/kit-workflow.md"
init_run "$GIT_ID_CFG" nomise "$S3" --update
assert_eq "s3: exit code 0" "$CODE" "0"
cmp -s "$KIT_ROOT/.claude/rules/kit-workflow.md" "$S3/.claude/rules/kit-workflow.md"
report "s3: kit-workflow.md restored to kit repo version" $? "content still differs from kit repo"
assert_eq "s3: README.md checksum unchanged" "$(cksum "$S3/README.md")" "$CKSUM_README_PRE"
assert_eq "s3: CLAUDE.md checksum unchanged" "$(cksum "$S3/CLAUDE.md")" "$CKSUM_CLAUDE_PRE"
assert_contains "s3: updated list names kit-workflow.md" "$OUT" "  + .claude/rules/kit-workflow.md"
assert_contains "s3: summary line shows updated 1" "$OUT" "updated 1, "
scenario_end "scenario 3: --update restores mutated kit file"

# ===========================================================================
# scenario 4 - dirty working tree only warns on `--update`, never blocks
# ===========================================================================
scenario_start
S4="$WORK/s4"
init_run "$GIT_ID_CFG" nomise "$S4"
report "s4 setup: initial install succeeded" "$CODE" "install failed: $OUT"
printf '\n<!-- uncommitted local edit -->\n' >> "$S4/README.md"
init_run "$GIT_ID_CFG" nomise "$S4" --update
assert_eq "s4: exit code 0" "$CODE" "0"
assert_contains "s4: dirty-tree warning shown" "$OUT" "warning: 建議先 commit 再 update"
scenario_end "scenario 4: dirty tree warning"

# ===========================================================================
# scenario 5 - v3.1 monolithic-CLAUDE.md project migrates via `--update`
# ===========================================================================
scenario_start
S5="$WORK/s5"
mkdir -p "$S5/.claude/hooks"
cat > "$S5/CLAUDE.md" <<'EOF'
# Fake Legacy Project

Some fake pre-existing project content that predates the kit-workflow split.

---

# Multi-Agent Workflow Rules

(old monolithic rules content that should now live in .claude/rules/kit-workflow.md)
EOF
cat > "$S5/PROMPTING.md" <<'EOF'
old prompting doc, orphaned as of v3.2
EOF
cat > "$S5/.claude/hooks/old-legacy-hook.sh" <<'EOF'
#!/usr/bin/env bash
echo "legacy hook the kit no longer ships"
EOF
chmod +x "$S5/.claude/hooks/old-legacy-hook.sh"

git_ctl "$S5" init -q -b main
report "s5 setup: git init" $? "git init failed"
git_ctl "$S5" add -A
report "s5 setup: git add" $? "git add failed"
git_ctl "$S5" commit -q -m "fixture: fake v3.1 project"
report "s5 setup: git commit" $? "git commit failed"

CKSUM_CLAUDE_PRE="$(cksum "$S5/CLAUDE.md")"
init_run "$GIT_ID_CFG" nomise "$S5" --update
assert_eq "s5: exit code 0" "$CODE" "0"
assert_file_exists "s5: kit-workflow.md deployed" "$S5/.claude/rules/kit-workflow.md"
assert_contains "s5: legacy-CLAUDE.md migration hint shown" "$OUT" "偵測到舊版單體 CLAUDE.md"
assert_contains "s5: PROMPTING.md orphan hint shown" "$OUT" "kit 已不再提供 PROMPTING.md"
assert_contains "s5: old-legacy-hook.sh flagged as non-kit file" "$OUT" "  - .claude/hooks/old-legacy-hook.sh"
assert_file_exists "s5: old-legacy-hook.sh still present (not deleted)" "$S5/.claude/hooks/old-legacy-hook.sh"
assert_eq "s5: CLAUDE.md checksum unchanged" "$(cksum "$S5/CLAUDE.md")" "$CKSUM_CLAUDE_PRE"

init_run "$GIT_ID_CFG" nomise "$S5" --update
assert_eq "s5: second --update exit code 0" "$CODE" "0"
assert_contains "s5: second --update is idempotent (updated 0)" "$OUT" "updated 0, "
scenario_end "scenario 5: v3.1 project migration"

# ===========================================================================
# scenario 6 - mise three-state handling (absent / present+no toml / present+toml)
# ===========================================================================
scenario_start
S6A="$WORK/s6a"
init_run "$GIT_ID_CFG" nomise "$S6A"
assert_eq "s6a: exit code 0" "$CODE" "0"
assert_file_absent "s6a: no mise present -> no mise.toml created" "$S6A/mise.toml"
assert_not_contains "s6a: no mise present -> output never mentions mise.toml" "$OUT" "mise.toml"
scenario_end "scenario 6a: mise absent"

scenario_start
S6B="$WORK/s6b"
init_run "$GIT_ID_CFG" mise "$S6B"
assert_eq "s6b: exit code 0" "$CODE" "0"
assert_file_exists "s6b: mise present, no toml -> mise.toml created" "$S6B/mise.toml"
cmp -s "$KIT_ROOT/templates/mise.toml" "$S6B/mise.toml"
report "s6b: mise.toml content matches templates/mise.toml" $? "content differs from templates/mise.toml"
assert_contains "s6b: copied list mentions mise.toml" "$OUT" "  + mise.toml"
scenario_end "scenario 6b: mise present, no existing toml"

scenario_start
S6C="$WORK/s6c"
mkdir -p "$S6C"
printf '# custom user mise config\n[tools]\nnode = "20"\n' > "$S6C/mise.toml"
CKSUM_MISE_PRE="$(cksum "$S6C/mise.toml")"
init_run "$GIT_ID_CFG" mise "$S6C"
assert_eq "s6c: exit code 0" "$CODE" "0"
assert_eq "s6c: existing custom mise.toml left untouched" "$(cksum "$S6C/mise.toml")" "$CKSUM_MISE_PRE"
assert_contains "s6c: skipped list mentions mise.toml" "$OUT" "  ~ mise.toml"
scenario_end "scenario 6c: mise present, existing custom toml"

# ===========================================================================
# scenario 7 - missing git identity: warn, skip commit, never block install
# ===========================================================================
scenario_start
S7="$WORK/s7"
init_run "$GIT_EMPTY_CFG" nomise "$S7"
assert_eq "s7: exit code 0" "$CODE" "0"
assert_contains "s7: [FIX] hint for git user.name shown" "$OUT" "[FIX] git user.name configured"
assert_contains "s7: [FIX] hint suggests git config --global user.name" "$OUT" 'git config --global user.name "Your Name"'
assert_contains "s7: [FIX] hint for git user.email shown" "$OUT" "[FIX] git user.email configured"
REV="$(git_ctl "$S7" rev-list --count HEAD 2>&1)"; REVCODE=$?
if [ "$REVCODE" -ne 0 ] || [ "$REV" = "0" ]; then
  pass "s7: no commit created (rev-list count 0 or failed)"
else
  fail "s7: no commit created (rev-list count 0 or failed)" "rev-list returned [$REV] rc=$REVCODE"
fi
assert_file_exists "s7: README.md still deployed" "$S7/README.md"
assert_file_exists "s7: CLAUDE.md still deployed" "$S7/CLAUDE.md"
assert_file_exists "s7: kit-workflow.md still deployed" "$S7/.claude/rules/kit-workflow.md"
scenario_end "scenario 7: missing git identity"

# ===========================================================================
# bonus (cheap) - --existing was removed in v3.2, must fail with a hint
# ===========================================================================
scenario_start
init_run "$GIT_ID_CFG" nomise "$WORK/does-not-matter" --existing
if [ "$CODE" -ne 0 ]; then
  pass "bonus: --existing exits non-zero"
else
  fail "bonus: --existing exits non-zero" "exit=0"
fi
assert_contains "bonus: error hints at auto-detection replacement" "$OUT" "自動偵測"
scenario_end "bonus: --existing removed"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
