#!/usr/bin/env bash
#
# classify-task.sh — UserPromptSubmit hook
#
# Inspects user's prompt and injects a TASK_CLASSIFICATION hint into context
# so main Claude knows which workflow path to take.
#
# Output format: JSON to stdout with `additionalContext` field, OR exit 0 silently.
# Failures here should not block the user prompt — fall through silently.
#
# Reference: https://code.claude.com/docs/en/hooks#userpromptsubmit

set -uo pipefail

# If jq is not available, silently skip — don't block prompts on missing tooling
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Read input JSON from stdin (silently ignore parse errors)
INPUT=$(cat 2>/dev/null || echo '{}')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || echo "")

# If no prompt or jq failed, exit silently
if [[ -z "$PROMPT" ]]; then
    exit 0
fi

# Lowercase for matching
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# === Classification rules (order matters: most specific first) ===

# Explicit user override — they said "skip" / "just do it"
if echo "$PROMPT_LOWER" | grep -qE '(just do it|skip plan|skip review|quick fix|small change|直接做|不要 plan|不需要 review)'; then
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: explicit_skip — user explicitly opted out of full workflow. Just do the task directly. Skip research, brainstorming, plan-review. Do NOT auto-trigger /codex:review unless task touches business logic AND user did not say skip review."}}
EOF
    exit 0
fi

# Explicit user override — they want full workflow
if echo "$PROMPT_LOWER" | grep -qE '(full workflow|full review|cross.?model review|review the plan|use plan.?with.?review|完整流程|完整審查)'; then
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: explicit_full — user explicitly requested full workflow. Engage superpowers brainstorming + writing-plans, run /codex:review on plan, run /codex:adversarial-review if high-stakes."}}
EOF
    exit 0
fi

# Detect bug fix patterns
if echo "$PROMPT_LOWER" | grep -qE '\b(fix|debug|修|修復|debug|bug)\b'; then
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: bug_fix — investigate root cause, apply fix, summarize. Skip planning. After fix: if change touched business logic or shared code, run /codex:review; otherwise just summarize. Always check for regressions in nearby code."}}
EOF
    exit 0
fi

# Detect small UI / cosmetic tasks
if echo "$PROMPT_LOWER" | grep -qE '\b(button|color|colour|css|style|class|text|copy|wording|font|margin|padding|樣式|顏色|文字)\b' \
   && echo "$PROMPT_LOWER" | grep -qE '\b(add|change|update|fix|adjust|tweak|加|改|調整)\b'; then
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: small_task — looks like a UI/cosmetic tweak. Skip superpowers brainstorming/planning. Just make the change directly. Brief summary at the end. NO automatic /codex:review."}}
EOF
    exit 0
fi

# Detect refactor explicitly
if echo "$PROMPT_LOWER" | grep -qE '\b(refactor|rewrite|restructure|migrate|重構|改寫|遷移)\b'; then
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: large_task_refactor — refactoring. Use full superpowers workflow: brainstorming, writing-plans, /codex:review on plan. Consider /codex:adversarial-review. Ensure tests exist before changing code (write them first if not). Phase-level /codex:review on each phase."}}
EOF
    exit 0
fi

# Detect explicit large-feature signals
if echo "$PROMPT_LOWER" | grep -qE '\b(new feature|add.*feature|implement|build a|design.*system|新功能|實作|設計.*系統)\b'; then
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: feature — likely medium or large task. Use superpowers writing-plans (consider brainstorming for large/unclear scope). Run /codex:review on plan. Trigger research-before-planning if task involves new external dependencies, security, or performance-critical paths."}}
EOF
    exit 0
fi

# Default: no classification injected, let Claude judge from prompt + CLAUDE.md
exit 0
