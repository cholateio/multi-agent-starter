#!/usr/bin/env bash
#
# inject-rules.sh <core|judgment|subagent> — always-on kit rules (v5 §4.3, D6)
#
# A Claude Code plugin cannot ship rules/, its root CLAUDE.md is not loaded,
# and ~/.claude/rules would fire in every directory. The one documented
# carrier that kit.toml can gate is hook additionalContext, so the v4
# .claude/rules files ride in as:
#   SessionStart  core      = kit-workflow + kit-delegation
#   SessionStart  judgment  = kit-judgment + kit-evolution + project-manifest
#   SubagentStart subagent  = subagent-digest (SessionStart context does not
#                             reach subagents — Phase 0 spike, 2026-10-19)
# Each payload stays under the documented 10,000-char injection cap
# (tests: <= 9,500 per SessionStart group, <= 2,000 for the digest).
#
# Unknown group, missing rule file, non-kit directory, v4 layout, KIT=off,
# no jq → exit 0 with no output. A group is injected whole or not at all:
# a half-injected rule set would read as the complete one.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

GROUP="${1:-}"
case "$GROUP" in
    core)     FILES=(kit-workflow.md kit-delegation.md);                   EVENT=SessionStart ;;
    judgment) FILES=(kit-judgment.md kit-evolution.md project-manifest.md); EVENT=SessionStart ;;
    subagent) FILES=(subagent-digest.md);                                  EVENT=SubagentStart ;;
    *) exit 0 ;;
esac

INPUT=$(cat 2>/dev/null || echo '{}')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
# v5 activation gate: silent unless the project root carries kit.toml
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ=$(kit_project_root) || exit 0

RULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rules"   # rules ship beside the hook
for f in "${FILES[@]}"; do
    if [[ ! -r "$RULES_DIR/$f" ]]; then
        echo "KIT: inject-rules: missing $RULES_DIR/$f — group '$GROUP' not injected" >&2
        exit 0
    fi
done

BODY=$(cd "$RULES_DIR" && cat "${FILES[@]}"; printf x) || exit 0
BODY="${BODY%x}"   # keep trailing newlines byte-exact
CONTEXT="KIT_RULES[${GROUP}] (always-on; was .claude/rules in v4)
${BODY}"

jq -n --arg ctx "$CONTEXT" --arg evt "$EVENT" \
  '{hookSpecificOutput: {hookEventName: $evt, additionalContext: $ctx}}'
exit 0
