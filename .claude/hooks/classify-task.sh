#!/usr/bin/env bash
#
# classify-task.sh — UserPromptSubmit hook (explicit overrides + judgment digest)
#
# v3.3: the keyword heuristics (bug-fix / UI / refactor / feature detection)
# are gone — the model classifies task size from the prompt and
# .claude/rules/kit-workflow.md better than keyword grep ever did (a prompt
# mentioning "button" is not necessarily a small task). What remains is the
# one thing grep IS reliable at: the user's explicit, imperative override
# phrases, in either language. Descriptive size words ("this is a small
# change") deliberately do NOT trigger — only commands do.
#
# v4.3: descriptive-context guard — the override greps now run on a masked
# copy of the prompt with "frequency marker + trigger phrase" spans removed,
# so describing the workflow no longer classifies (see inline comment).
#
# v4.1: every non-empty prompt also gets a one-line KIT_JUDGMENT digest —
# a deterministic per-turn re-fire of the kit-judgment red flags
# (.claude/rules/kit-judgment.md), independent of context length. Idea from
# fable-soul's enforcement hook, relocated from Stop (where exit-0 stdout
# never reaches the model — it is transcript-only per the hooks docs) to
# UserPromptSubmit, where additionalContext does enter model context.
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

# One line, ~40 tokens. Reminders, not rules — the rules live in
# .claude/rules/kit-judgment.md. Keep the two in sync.
DIGEST="KIT_JUDGMENT: done-claims need run evidence (else say 'changed but not verified'); a checkable claim gets checked, not hedged; an unconfirmed problem is not a finding; a change after a green test resets that verification."

# v4.3 descriptive-context guard: a sentence DESCRIBING the workflow
# ("模型一直在走完整流程", "it keeps running the full review") is not a
# command, but the plain grep can't tell — real misfire recorded
# 2026-07-10 (tests/evals.md). Mask "frequency/progressive marker +
# trigger phrase" spans before the positive greps so only imperative
# usages survive. Guards BOTH classes — a descriptive misfire on
# explicit_skip is the dangerous direction. Literal alternations only
# (C-locale + BSD sed -E safe); a suppressed prompt just falls back to
# the model's own kit-workflow sizing judgment.
# Bounded free gap between marker and phrase instead of a verb whitelist —
# a gerund list can't cover reporting verbs ("always SAYS skip review",
# codex review finding 2026-07-10). Gap classes are ASCII-only: a negated
# class with multibyte members would exclude bytes shared by CJK chars in
# the C locale. Trade-off: an imperative that itself contains a frequency
# adverb ("please always run the full workflow") is also suppressed and
# falls back to the model's own sizing judgment — acceptable direction.
MASKED=$(echo "$PROMPT_LOWER" | sed -E \
  -e 's/(一直|總是|老是|常常|每次都)[^.;!?,]{0,15}(完整流程|完整審查|直接做|不要 plan|不需要 review|full workflow|full review|cross.?model review|review the plan|skip review|skip plan|just do it)//g' \
  -e 's/(keeps?|kept|always|constantly|ends? up)[a-z ]{0,24}(full (workflow|review)|cross.?model review|review the plan|skip review|skip plan|just do it)//g')

CLASS=""
# Explicit opt-out — imperative phrases only
if echo "$MASKED" | grep -qE '(just do it|skip plan|skip review|直接做|不要 plan|不需要 review)'; then
    CLASS="TASK_CLASSIFICATION: explicit_skip — user explicitly opted out of the full workflow. Do the task directly; skip research, brainstorming and plan-review. Do NOT auto-trigger a review unless the task touches business logic AND the user did not also say to skip review."
# Explicit opt-in — user wants the full workflow
elif echo "$MASKED" | grep -qE '(full workflow|full review|cross.?model review|review the plan|完整流程|完整審查)'; then
    CLASS="TASK_CLASSIFICATION: explicit_full — user explicitly requested the full workflow: brainstorming/writing-plans, review the plan per the active profile (adversarial review if high-stakes), phase-level reviews, final review."
fi

if [[ -n "$CLASS" ]]; then
    CTX="${CLASS}

${DIGEST}"
else
    CTX="$DIGEST"
fi

jq -n --arg ctx "$CTX" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
