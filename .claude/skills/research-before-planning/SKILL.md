---
name: research-before-planning
description: Use BEFORE engaging superpowers brainstorming/writing-plans when
  the task is `large_task` and involves unfamiliar libraries, security/auth,
  performance-critical paths, or novel architecture. Spawns gemini-research-scout
  to gather external resources, then hands off to superpowers with research as
  context.
---

# Research Before Planning

This skill runs ONCE before brainstorming/planning, ONLY for tasks that
benefit from external research. Most tasks skip this step.

## When this skill triggers

Trigger when ALL of these are true:
1. Task is classified as `large_task` (or `medium_task` involving new tech)
2. Task involves AT LEAST ONE of:
   - Unfamiliar library or framework (not yet seen in this codebase)
   - Security-sensitive territory (auth, crypto, secrets, payments)
   - Performance-critical paths
   - Novel architectural pattern
3. The user has not already supplied clear technical direction that makes
   research redundant

## When this skill should NOT trigger

- `small_task` / `bug_fix` / `medium_task` within known patterns
- Tasks where the user said "skip research" or "use what we already have"
- The codebase already has clear conventions for the tech in question

## Workflow

### Step 1 — Identify research questions

Before spawning the scout, write out 2-5 specific questions that, if
answered, would meaningfully improve the plan. Examples:

Good questions:
- "What's the current best practice for OAuth refresh token rotation in 2026?"
- "Are there known issues with using libsodium for our use case (small server, low traffic)?"
- "How do real-time collaborative editing apps handle conflict resolution today?"

Bad questions (too vague — gemini won't be able to answer usefully):
- "Tell me about authentication"
- "What's the best framework"

### Step 2 — Spawn the scout

Use `gemini-research-scout` subagent with the questions. Per
gemini-research-scout.md, supply:
- Topic
- Project context (1-3 sentences)
- Your specific questions
- Constraints to respect (existing stack, deployment target, etc.)

### Step 3 — Integrate research findings

When the scout returns:
- Read the summary carefully
- Note any findings that **contradict your prior assumption** about how to
  approach this task
- Note any **conditional warnings** ("if you choose X, watch out for Y")
- If a finding suggests a fundamentally different approach, **stop and
  ask the user** before proceeding to planning

### Step 4 — Hand off to superpowers

Begin superpowers brainstorming/writing-plans with research as initial
context. Reference the research summary when explaining technical choices
in the plan.

## Output format

Before handing off to superpowers, summarize to the user:

```
## Research findings (before planning)

I asked gemini-research-scout to investigate: <topic>

Key takeaways:
- <takeaway 1>
- <takeaway 2>
- <takeaway 3>

Implications for our plan:
- <implication>
- <implication>

Now proceeding to brainstorming/planning with these findings as context.
(Or: "Hold up — finding X suggests we should reconsider before planning.
 What do you think?")
```

## Failure handling

If `gemini-research-scout` returns an error:
- Tell the user: "Research scout unavailable: <reason>"
- Ask: "Proceed with planning without research, or wait?"
- Do NOT silently skip to planning without telling the user
