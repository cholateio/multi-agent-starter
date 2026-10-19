#!/usr/bin/env bash
# tests/smoke.sh - v5 repo-level smoke: init.sh redirect stub + rules budget.
# (The v4 init.sh scenarios s1-s8 were removed with init.sh's deploy logic;
# `kit init` / `kit migrate` get their own smokes in Phase 3.)
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }

# ---------------------------------------------------------------- kit init
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n' > "$W/gitconfig"
ki() { env HOME="$W/home" KIT_CONFIG_HOME="$W/home/.config/kit" GIT_CONFIG_GLOBAL="$W/gitconfig" \
           GIT_CONFIG_NOSYSTEM=1 python3 "$KIT_ROOT/bin/kit" init "$@" 2>&1; }
g() { GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1 git -C "$@"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3]"; fi; }
sums() { (cd "$1" && find . -path ./.git -prune -o -type f -print | sort | xargs cksum); }

# i1: empty dir, public (default)
OUT="$(ki "$W/p1")"; CODE=$?
[ "$CODE" -eq 0 ] && pass "i1: exit 0" || fail "i1: exit 0" "got $CODE: $OUT"
for f in CLAUDE.md kit.toml .gitignore PROJECT.toml LICENSE; do
  [ -f "$W/p1/$f" ] && pass "i1: $f laid down" || fail "i1: $f laid down" "missing"
done
has "i1: kit.toml visibility public" "$(cat "$W/p1/kit.toml" 2>/dev/null)" 'visibility = "public"'
has "i1: kit.toml license MIT" "$(cat "$W/p1/kit.toml" 2>/dev/null)" 'license = "MIT"'
has "i1: CLAUDE.md stub imports AGENTS.md" "$(head -1 "$W/p1/CLAUDE.md" 2>/dev/null)" "@AGENTS.md"
has "i1: LICENSE has the year" "$(cat "$W/p1/LICENSE" 2>/dev/null)" "$(date +%Y) Test User"
[ "$(g "$W/p1" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = "1" ] && pass "i1: one bootstrap commit" || fail "i1: one bootstrap commit" "$(g "$W/p1" log --oneline 2>&1)"
has "i1: commit subject" "$(g "$W/p1" log -1 --format=%s 2>/dev/null)" "chore: bootstrap with multi-agent-kit v5"
has "i1: prints bootstrap prompt" "$OUT" "bootstrap prompt"
has "i1: gitignore has the kit block" "$(cat "$W/p1/.gitignore" 2>/dev/null)" "# >>> kit v5"
[ -z "$(g "$W/p1" status --porcelain 2>/dev/null)" ] && pass "i1: tree clean after bootstrap" || fail "i1: tree clean after bootstrap" "dirty"
[ -z "$(g "$W/p1" ls-files PROJECT.toml 2>/dev/null)" ] && pass "i1: PROJECT.toml not committed (local only)" || fail "i1: PROJECT.toml not committed (local only)" "tracked"

# i2: private, no license
OUT="$(ki "$W/p2" --private --license none)"
has "i2: kit.toml visibility private" "$(cat "$W/p2/kit.toml" 2>/dev/null)" 'visibility = "private"'
has "i2: kit.toml license none" "$(cat "$W/p2/kit.toml" 2>/dev/null)" 'license = "none"'
[ ! -e "$W/p2/LICENSE" ] && pass "i2: no LICENSE" || fail "i2: no LICENSE" "exists"
[ ! -e "$W/p2/.github/workflows/kit-guard.yml" ] && pass "i2: no workflow" || fail "i2: no workflow" "exists"
has "i2: README from the private template" "$OUT" "README.private.md"

# i3: re-run → nothing changes
BEFORE="$(sums "$W/p1")"; HEAD1="$(g "$W/p1" rev-parse HEAD)"
OUT="$(ki "$W/p1")"
[ "$(sums "$W/p1")" = "$BEFORE" ] && pass "i3: rerun leaves every file unchanged" || fail "i3: rerun leaves every file unchanged" "cksum differs"
[ "$(g "$W/p1" rev-parse HEAD)" = "$HEAD1" ] && pass "i3: rerun makes no commit" || fail "i3: rerun makes no commit" "new commit"

# i4: existing .gitignore keeps custom lines, gains the block once
mkdir -p "$W/p4"; printf 'my-secret-dir/\n*.cache\n' > "$W/p4/.gitignore"
ki "$W/p4" >/dev/null; ki "$W/p4" >/dev/null
has "i4: custom line kept" "$(cat "$W/p4/.gitignore")" "my-secret-dir/"
[ "$(grep -c '^# >>> kit v5' "$W/p4/.gitignore")" = "1" ] && pass "i4: kit block exactly once" || fail "i4: kit block exactly once" "$(grep -c '^# >>> kit v5' "$W/p4/.gitignore")"

# i5: existing git repo → no extra commit
mkdir -p "$W/p5"; g "$W/p5" init -q -b main; echo x > "$W/p5/x"; g "$W/p5" add x; g "$W/p5" commit -q -m first
ki "$W/p5" >/dev/null
[ "$(g "$W/p5" log --oneline | wc -l | tr -d ' ')" = "1" ] && pass "i5: existing repo gets no commit" || fail "i5: existing repo gets no commit" "extra commit"
[ -f "$W/p5/kit.toml" ] && pass "i5: files still laid down" || fail "i5: files still laid down" "no kit.toml"

# s0: init.sh stub exits 2 with the v5 message
OUT="$(bash "$KIT_ROOT/init.sh" /tmp/kit-smoke-never 2>&1)"; CODE=$?
if [ "$CODE" -eq 2 ]; then pass "s0: init.sh stub exits 2"; else fail "s0: init.sh stub exits 2" "got $CODE"; fi
if printf '%s' "$OUT" | grep -qF "multi-agent-kit v5: run 'kit setup'"; then
  pass "s0: init.sh stub prints v5 message"
else
  fail "s0: init.sh stub prints v5 message" "got [$OUT]"
fi
if [ ! -e /tmp/kit-smoke-never ]; then pass "s0: init.sh stub creates nothing"; else fail "s0: init.sh stub creates nothing" "dir exists"; fi

# budget: plugin/rules is injected into EVERY session — a fixed context tax.
# Cap 20480 bytes (v4.9 ratchet: cap = min(old cap, ceil100(actual x 1.05)); never raised).
# v5: subagent-digest.md rides SubagentStart only (own <= 2,000-char cap in
# plugin-validate pv8); every other rules file counts, new ones included.
RULES_BYTES=$(find "$KIT_ROOT/plugin/rules" -maxdepth 1 -name '*.md' ! -name 'subagent-digest.md' -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
RULES_CAP=20480
if [ "${RULES_BYTES:-0}" -gt 0 ] && [ "${RULES_BYTES:-0}" -le "$RULES_CAP" ]; then
  pass "budget: rules/ total ${RULES_BYTES}B within ${RULES_CAP}B cap"
else
  fail "budget: rules/ total within cap" "got ${RULES_BYTES}B > ${RULES_CAP}B (or empty) — slim before adding"
fi

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
