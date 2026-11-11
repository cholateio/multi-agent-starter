---
name: grill
description: Interview the user before designing — use at the start of a new project, a cross-module redesign or a novel architecture, when handed a brief / spec / plan to build from, or when the user says "grill me". 開新專案、跨模組重設計、拿到一份需求說明要開始規劃時，先用本 skill 把需求問清楚再設計。
---

# Grill before design

> Kit-owned. Question rounds adapted from the `grilling` skill in mattpocock/skills (MIT).
> Receipt: tests/evals.md 2026-11-12 — a brief answered only what it was asked; rounds of numbered
> questions surfaced about three times as many hidden requirements as planning straight from the brief,
> but no configuration asked what the real product or the end state was. Round 0 exists for that.

A brief is the owner's first draft, not the requirements. Your job here is to find what it leaves out or
gets wrong before any design is written. Do not design, plan or write files until the last step.

## Before asking anything — look it up

Facts are yours to find; decisions are the owner's. Before round 0:

- Read `AGENTS.md` Constraints and `kit.toml` (`visibility`, `[protected]`). A public repo changes where
  screenshots, recordings, third-party binaries and secrets may live — design for it without asking.
- Check that everything the brief says is attached or already exists actually exists. A missing file is a
  question for round 0.
- Read the brief for internal contradictions (two different targets, a milestone that does not match the
  goal). Each one is a question, never a silent pick.

## Round 0 — intent (always first, one round)

Ask these in your own words, each with your best guess as the recommended answer:

1. **End state** — what does the finished thing let the owner do that they cannot do now? What would the
   final demo look like?
2. **The real product** — if the first target (this game, this vendor, this dataset) had to be swapped,
   what must survive unchanged? That part is the product; the rest is a plug-in.
3. **Who decides at run time** — the owner, a fixed program, or a model? How often may it stop and ask?
4. **Hard limits** — monthly money cap, what is already bought or built, what is lost or missing, what
   must never happen.
5. **Out of scope for good** — what the owner does not want even if it is easy.

## Rounds 1..n — the decision tree

Every decision branches into the decisions that depend on it. Each round, ask the whole frontier: every
question whose prerequisites are settled. A question that depends on an open one waits for a later round.

Format each question so that "yes" accepts your recommendation:

```
Q7 — <short title>: <the question, with the options if there are any>
→ <your recommended answer and the one-line reason>
```

- Number questions across the whole interview so the owner can answer "7 yes, 8 no — …".
- Batch. Aim for three or four rounds in total; the owner's replies are the expensive part.
- When an answer overturns something you assumed, say so and re-open the branches that depended on it.
- The owner may stop the interview at any point ("夠了"); go to the closing step with what you have.

## What you may not do

- Do not present an external claim (licence terms, protocol details, hardware behaviour) as checked unless
  you checked it in this session. Mark it `unverified` and say what would verify it.
- Do not fill an unanswered question with a default silently. Either ask it or list it under assumptions.

## Closing

When the frontier is empty, send one summary and wait for the owner's confirmation:

- decisions, each tagged **user 決定** or **我的決定** (yours are the ones the owner may overturn);
- assumptions still open and claims still `unverified`;
- what changed compared with the brief.

After confirmation, write the spec to `docs/specs/<date>-<topic>-design.md` with the same tags, then
continue with the normal kit workflow (plan + approval for anything in the plan-first tier).
