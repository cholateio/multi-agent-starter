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
RULES_BYTES=$(cat "$KIT_ROOT/plugin/rules/"*.md 2>/dev/null | wc -c | tr -d ' ')
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
