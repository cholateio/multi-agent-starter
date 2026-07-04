#!/usr/bin/env bash
#
# classify-task.sh — UserPromptSubmit hook (explicit overrides only)
#
# v3.3: the keyword heuristics (bug-fix / UI / refactor / feature detection)
# are gone — the model classifies task size from the prompt and
# .claude/rules/kit-workflow.md better than keyword grep ever did (a prompt
# mentioning "button" is not necessarily a small task). What remains is the
# one thing grep IS reliable at: the user's explicit, imperative override
# phrases, in either language. Descriptive size words ("this is a small
# change") deliberately do NOT trigger — only commands do.
#
# Output: JSON with hookSpecificOutput.additionalContext, or silent exit 0.
# Failures here must never block the user's prompt.
#
# Reference: https://code.claude.com/docs/en/hooks#userpromptsubmit

set -uo pipefail

# If jq is not available, silently skip — don't block prompts on missing tooling
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

INPUT=$(cat 2>/dev/null || echo '{}')
# The stdin field name has varied across Claude Code versions
# (.prompt / .user_input) — accept either.
PROMPT=$(echo "$INPUT" | jq -r '.prompt // .user_input // ""' 2>/dev/null || echo "")

if [[ -z "$PROMPT" ]]; then
    exit 0
fi

PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Explicit opt-out — imperative phrases only
if echo "$PROMPT_LOWER" | grep -qE '(just do it|skip plan|skip review|直接做|不要 plan|不需要 review)'; then
    cat <<'EOF'
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: explicit_skip — user explicitly opted out of the full workflow. Do the task directly; skip research, brainstorming and plan-review. Do NOT auto-trigger a review unless the task touches business logic AND the user did not also say to skip review."}}
EOF
    exit 0
fi

# Explicit opt-in — user wants the full workflow
if echo "$PROMPT_LOWER" | grep -qE '(full workflow|full review|cross.?model review|review the plan|完整流程|完整審查)'; then
    cat <<'EOF'
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TASK_CLASSIFICATION: explicit_full — user explicitly requested the full workflow: brainstorming/writing-plans, review the plan per the active profile (adversarial review if high-stakes), phase-level reviews, final review."}}
EOF
    exit 0
fi

# No explicit override → say nothing; the model judges task size itself.
exit 0
