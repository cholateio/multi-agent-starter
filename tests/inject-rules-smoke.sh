#!/usr/bin/env bash
# tests/inject-rules-smoke.sh - plugin/hooks/inject-rules.sh (v5 §4.3, D6).
# The plugin cannot ship rules/, so the always-on rules ride SessionStart
# additionalContext in two groups (each <= 9,500 chars), plus a <= 2,000-char
# digest on SubagentStart (Phase 0 spike: hook context does not reach
# subagents; SubagentStart additionalContext does).
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$KIT_ROOT/plugin"
IR="$PLUGIN/hooks/inject-rules.sh"

if ! command -v jq >/dev/null 2>&1; then echo "SKIP inject-rules-smoke: jq not installed"; exit 0; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-inject-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }

KITDIR="$WORK/kit-proj";  mkdir -p "$KITDIR"; printf 'kit = 5\nvisibility = "public"\nprotected = [\n]\n' > "$KITDIR/kit.toml"
NOKIT="$WORK/plain";      mkdir -p "$NOKIT"
V4DIR="$WORK/v4";         mkdir -p "$V4DIR/.claude"; cp "$KITDIR/kit.toml" "$V4DIR/"; echo "v4.10.0" > "$V4DIR/.claude/kit-version"

# run_ir <cwd> <group...> [-- VAR=val ...] : sets OUT, CODE
run_ir() {
  local cwd="$1"; shift
  local -a args=() envs=()
  while [ $# -gt 0 ]; do [ "$1" = "--" ] && { shift; envs=("$@"); break; }; args+=("$1"); shift; done
  OUT="$(printf '{"session_id":"irsmoke","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$cwd" \
        | env HOME="$WORK/home" KIT=on KIT_CONFIG_HOME= CLAUDE_PROJECT_DIR= CLAUDE_PLUGIN_ROOT="$PLUGIN" "${envs[@]}" bash "$IR" "${args[@]}" 2>/dev/null)"
  CODE=$?
}

check_group() {  # $1 = group  $2 = expected hookEventName  $3 = char cap  $4.. = rule files
  local g="$1" evt="$2" cap="$3"; shift 3
  run_ir "$KITDIR" "$g"
  assert_eq "i-$g: exit 0" "$CODE" "0"
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | type == "string"' >/dev/null 2>&1; then
    pass "i-$g: stdout is JSON with additionalContext"
  else
    fail "i-$g: stdout is JSON with additionalContext" "got [${OUT:0:120}]"
  fi
  assert_eq "i-$g: hookEventName" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)" "$evt"
  printf '%s' "$OUT" | jq -j '.hookSpecificOutput.additionalContext // ""' > "$WORK/ctx-$g" 2>/dev/null
  assert_eq "i-$g: first line is the KIT_RULES header" "$(head -n 1 "$WORK/ctx-$g")" "KIT_RULES[$g] (always-on; was .claude/rules in v4)"
  ( cd "$PLUGIN/rules" && cat "$@" ) > "$WORK/want-$g"
  if tail -n +2 "$WORK/ctx-$g" | cmp -s - "$WORK/want-$g"; then
    pass "i-$g: body equals the rule files verbatim ($*)"
  else
    fail "i-$g: body equals the rule files verbatim" "cmp differs"
  fi
  local n; n=$(wc -m < "$WORK/ctx-$g" | tr -d ' ')
  if [ "$n" -gt 0 ] && [ "$n" -le "$cap" ]; then pass "i-$g: payload ${n} chars <= ${cap}"; else fail "i-$g: payload <= ${cap}" "${n} chars"; fi
}

# I1/I2/I6 - groups, verbatim content, per-payload char caps
check_group core      SessionStart  9500 kit-workflow.md kit-delegation.md
check_group judgment  SessionStart  9500 kit-judgment.md kit-evolution.md project-manifest.md
check_group subagent  SubagentStart 2000 subagent-digest.md

# I3 - activation gate: silent outside kit projects, on v4 layouts, with KIT=off
for g in core judgment subagent; do
  run_ir "$NOKIT" "$g";            assert_eq "i3-$g: no kit.toml -> silent exit 0" "$CODE|$OUT" "0|"
  run_ir "$V4DIR" "$g";            assert_eq "i3-$g: v4 layout -> silent exit 0" "$CODE|$OUT" "0|"
  run_ir "$KITDIR" "$g" -- KIT=off; assert_eq "i3-$g: KIT=off -> silent exit 0" "$CODE|$OUT" "0|"
done

# I5 - unknown / missing / path-like group -> exit 0, no output
run_ir "$KITDIR" bogus;            assert_eq "i5: unknown group silent" "$CODE|$OUT" "0|"
run_ir "$KITDIR";                  assert_eq "i5: missing group silent" "$CODE|$OUT" "0|"
run_ir "$KITDIR" "../rules/kit-workflow"; assert_eq "i5: path-like group silent" "$CODE|$OUT" "0|"

# I7 - a missing rule file must not inject a partial group (fail silent, not half-truth)
FAKEP="$WORK/fakeplugin"; mkdir -p "$FAKEP/hooks" "$FAKEP/rules"
cp "$PLUGIN/hooks/inject-rules.sh" "$PLUGIN/hooks/lib.sh" "$FAKEP/hooks/"
cp "$PLUGIN/rules/kit-workflow.md" "$FAKEP/rules/"
OUT="$(printf '{"cwd":"%s"}' "$KITDIR" | env KIT=on CLAUDE_PROJECT_DIR= CLAUDE_PLUGIN_ROOT="$FAKEP" bash "$FAKEP/hooks/inject-rules.sh" core 2>"$WORK/err7")"; CODE=$?
assert_eq "i7: missing rule file -> no partial injection" "$CODE|$OUT" "0|"
if grep -q 'kit-delegation.md' "$WORK/err7"; then pass "i7: missing file named on stderr"; else fail "i7: missing file named on stderr" "$(cat "$WORK/err7")"; fi

# I8 - hooks.json wiring: SessionStart runs core + judgment BEFORE session-start.sh; SubagentStart runs subagent
HJ="$PLUGIN/hooks/hooks.json"
SS_CMDS="$(jq -r '.hooks.SessionStart[0].hooks[].command' "$HJ" 2>/dev/null | tr '\n' '|')"
case "$SS_CMDS" in
  *"inject-rules.sh\" core|"*"inject-rules.sh\" judgment|"*"session-start.sh\"|"*) pass "i8: SessionStart order core, judgment, session-start" ;;
  *) fail "i8: SessionStart order core, judgment, session-start" "got [$SS_CMDS]" ;;
esac
assert_eq "i8: SessionStart matcher" "$(jq -r '.hooks.SessionStart[0].matcher' "$HJ")" "startup|resume|clear|compact|fork"
if jq -r '.hooks.SubagentStart[0].hooks[].command' "$HJ" 2>/dev/null | grep -q 'inject-rules.sh" subagent$'; then
  pass "i8: SubagentStart injects the subagent digest"
else
  fail "i8: SubagentStart injects the subagent digest" "entry missing"
fi

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
