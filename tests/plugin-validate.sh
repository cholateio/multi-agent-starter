#!/usr/bin/env bash
# tests/plugin-validate.sh - structural assertions on plugin/ and the marketplace manifest.
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 1
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }

# (1) claude plugin validate --strict
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate ./plugin --strict >/dev/null 2>&1; then pass "pv1: claude plugin validate --strict"
  else fail "pv1: claude plugin validate --strict" "non-zero exit"; fi
else
  echo "SKIP pv1: claude not on PATH"
fi

# (2) versions equal
V_FILE="$(tr -d '[:space:]' < VERSION)"
V_PLUGIN="$(jq -r '.version' plugin/.claude-plugin/plugin.json)"
V_MKT="$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)"
if [ "$V_FILE" = "$V_PLUGIN" ] && [ "$V_FILE" = "$V_MKT" ]; then pass "pv2: VERSION == plugin.json == marketplace ($V_FILE)"
else fail "pv2: version triple" "VERSION=$V_FILE plugin=$V_PLUGIN marketplace=$V_MKT"; fi

# (3) marketplace source
SRC="$(jq -r '.plugins[0].source' .claude-plugin/marketplace.json)"
if [ "$SRC" = "./plugin" ]; then pass "pv3: marketplace source is ./plugin"; else fail "pv3: marketplace source" "got [$SRC]"; fi

# (4) every hooks.json command's script exists and is executable
BAD=""
while IFS= read -r cmd; do
  for rel in $(printf '%s' "$cmd" | grep -o '\${CLAUDE_PLUGIN_ROOT}/[^" ]*' | sed 's#\${CLAUDE_PLUGIN_ROOT}/##'); do
    [ -x "plugin/$rel" ] || BAD="$BAD $rel"
  done
done < <(jq -r '.. | objects | select(.type=="command") | .command' plugin/hooks/hooks.json)
if [ -z "$BAD" ]; then pass "pv4: hooks.json commands exist and are executable"; else fail "pv4: hooks.json commands" "missing/not executable:$BAD"; fi

# (5) rules total bytes <= 20480 (main-session payload; the SubagentStart
# digest has its own cap in pv8; any other new rules file counts here)
RB=$(find plugin/rules -maxdepth 1 -name '*.md' ! -name 'subagent-digest.md' -exec cat {} + | wc -c | tr -d ' ')
if [ "$RB" -le 20480 ]; then pass "pv5: rules total ${RB}B <= 20480B"; else fail "pv5: rules total" "${RB}B > 20480B"; fi

# (6) injection segments <= 9500 chars
seg() { local t=0 f n; for f in "$@"; do n=$(wc -m < "plugin/rules/$f.md"); t=$((t + n)); done; echo "$t"; }
CORE=$(seg kit-workflow kit-delegation)
JUDG=$(seg kit-judgment kit-evolution project-manifest)
if [ "$CORE" -le 9500 ]; then pass "pv6: core segment ${CORE} chars <= 9500"; else fail "pv6: core segment" "${CORE} > 9500"; fi
if [ "$JUDG" -le 9500 ]; then pass "pv6: judgment segment ${JUDG} chars <= 9500"; else fail "pv6: judgment segment" "${JUDG} > 9500"; fi

# (8) SubagentStart digest <= 2000 chars (design §4.3 (c))
DG=$(wc -m < plugin/rules/subagent-digest.md 2>/dev/null | tr -d ' ')
if [ -n "$DG" ] && [ "$DG" -gt 0 ] && [ "$DG" -le 2000 ]; then pass "pv8: subagent digest ${DG} chars <= 2000"; else fail "pv8: subagent digest" "${DG:-missing} chars"; fi

# (7) each skill has name: equal to its directory
for d in plugin/skills/*/; do
  n="$(basename "$d")"
  got="$(sed -n '/^---$/,/^---$/p' "$d/SKILL.md" 2>/dev/null | sed -n 's/^name: *//p' | head -1)"
  if [ "$got" = "$n" ]; then pass "pv7: skill $n name matches dir"; else fail "pv7: skill $n" "name=[$got]"; fi
done

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
