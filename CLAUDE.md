# [PROJECT NAME]

> CLAUDE.md (kit v3.1, profile-aware). Fill the [PLACEHOLDERS] below on first
> use - or just run `claude` and paste the bootstrap prompt from PROMPTING.md
> (section 0) and let it fill them for you.
> The "Multi-Agent Workflow Rules" half is generic and rarely needs editing.

## Project goal

[一句話描述這個專案是什麼、核心目的。
 例：「給小型團隊用的 expense tracking SaaS，優先 self-host。」]

## Stack

- Language: [e.g. Python 3.12 / TypeScript 5.4 / Go 1.22]
- Framework: [e.g. FastAPI / Next.js 14 / none]
- Datastore: [e.g. PostgreSQL 16 / SQLite / none]
- Build/run: [e.g. pnpm / make / cargo]
- Test: [e.g. pytest / vitest / cargo test]

## File layout

[新專案首次架構決策後填入；既有專案貼 `tree -L 2`。]

## Coding standards

[實際 standards。例：functions single-responsibility / no `any` / Result types。]

## Project-specific constraints

[此專案特殊規則 - 對既有專案這是最重要的段落。例：
 - `src/legacy/payment/` 不可修改，會破壞舊金流
 - 所有 DB writes 必須走 repository pattern
 新專案可留空，由使用累積。]

---

# Multi-Agent Workflow Rules

> 通用協作規則。除非專案特殊，否則不需編輯。

## Active profile (KIT_PROFILE)

This kit runs in one of two profiles, selected per-machine by the
`KIT_PROFILE` environment variable (default `full`):

| Profile | Research | Plan + execute | Reviewer (the isolation guarantee) |
|---------|----------|----------------|------------------------------------|
| `full`  | Gemini scout | Superpowers | **Codex Plugin** - different model = real isolation |
| `solo`  | none (your own search) | Superpowers | **fresh-context Claude subagent** - state/time isolation ONLY, NOT model isolation |

Wherever these rules say **"run a review"**, resolve it by the active profile:

- **full** -> invoke the Codex Plugin: `/codex:review` (and
  `/codex:adversarial-review` for high-stakes work).
- **solo** -> spawn a fresh-context subagent to review the diff with clean
  state, AND say plainly to the user: *"solo profile: cross-model isolation is
  OFF - this is a same-model self-review (state/time isolation only)."*
  Never present a solo self-review as if it were cross-model review.

If you cannot determine the active profile, ask the user before reviewing.

## Three-capability orchestration

- **Gemini** (research scout, full only): web research / external info. Never
  writes code, never reviews.
- **Superpowers** (architect + worker): brainstorm, writing-plans,
  executing-plans. The primary planning/implementation flow in both profiles.
- **Reviewer** (per active profile, see table above): cross-model review in
  full, fresh-context self-review in solo. Never writes code.

Main Claude orchestrates these based on task type.

## Spec-driven entry (if a blueprint exists)

If `docs/specs/` contains a spec/blueprint:

- Treat it as the **authoritative requirements source**.
- **Skip brainstorming** - scope was already converged externally.
- Still run writing-plans to derive a codebase-aware plan.
- **Still review the spec itself** (prefer adversarial) before implementing.
  The spec is an external artifact written by another author/model, so the
  isolation principle applies to it exactly as it applies to a plan.

## Task-size classification

A `classify-task.sh` hook may inject a `TASK_CLASSIFICATION` hint. Honor it.
Otherwise classify yourself:

| Signal | Classification |
|--------|----------------|
| "just do it" / "quick" / "small" | `small_task` |
| "full workflow" / "review the plan" | `explicit_full` |
| < 30 lines, single file, single concern | `small_task` |
| UI / CSS / copy / formatting | `small_task` |
| bug fix without business-logic change | `small_task` |
| new feature, single file, < 100 lines | `medium_task` |
| new feature, multiple files OR new deps | `large_task` |
| refactor, schema migration, auth/payment | `large_task` |

### What to run for each

- **small_task**: just do it; skip planning; brief summary. No review unless it
  touched business logic (see Final review trigger).
- **medium_task**: superpowers:writing-plans -> run a review on the plan ->
  user approves -> implement -> final review.
- **large_task**: research-before-planning if it involves new libs / security /
  perf-critical / novel architecture -> superpowers:brainstorming ->
  writing-plans -> review the plan (adversarial if high-stakes) -> user approves
  -> executing-plans with phase-level review -> final review.

### Phase-level review during executing-plans

- **MUST review**: auth / authz / session; payment / billing / money;
  data migration / schema; anything in "Project-specific constraints".
- **Recommend (default yes)**: user-visible business logic; algorithms / state
  machines / concurrency; input validation / security boundaries; phase >= 100 lines.
- **Skip**: UI / styling / docs; simple glue / CRUD / type defs; < 50 lines, no
  business logic.

### Final review trigger

Before declaring the task complete, ask: *did this session modify
business-logic-bearing files that haven't been reviewed yet?* If yes -> run a
review (per active profile) on the full change set before summarizing. The Stop
hook (`verify-final-review.sh`) enforces this when enabled.

## Cross-model isolation principle

PRIMARY question: **"is the reviewer a different model than the writer?"** -
not "which specialist fits this task?".

- **full**: writer (main Claude) != reviewer (Codex) -> real isolation.
- **solo**: writer and reviewer are both Claude -> model isolation is OFF; you
  only get state/time isolation from the fresh subagent. Say so to the user.

### Anti-pattern (never do this)

Same model writes + same model reviews, presented as isolation. In full, never
review codex-written code (e.g. from `/codex:rescue`) with codex again - that's
zero isolation. Defer to user judgment or have main Claude review it.

## When to STOP and ask the user

- Research findings suggest a meaningfully better approach than the plan assumed.
- A review flagged a `critical`/`high` issue you can't resolve from context.
- Adversarial review challenged a fundamental premise.
- Phase will modify > [default 100] lines, or delete/rewrite > 30 existing lines.
- Touches anything in "Project-specific constraints".
- (full) Codex/Gemini unavailable - ask whether to proceed or wait.

## Service unavailability handling

When a tool fails: report clearly (never silently skip), categorize (quota /
auth / network) with the fix, and ask the user: skip / wait+retry / (research
only) proceed without it.

**full profile:** do NOT auto-fall-back from `/codex:review` to Claude
self-review silently - that breaks the isolation guarantee; the user must
explicitly accept it (which is effectively a temporary switch to solo).
**solo profile:** self-review is the declared default, not a silent fallback -
but still state that isolation is reduced.

## Inventory (profile-gated)

- Skill `research-before-planning` - full only (uses gemini scout).
- Subagent `gemini-research-scout` - full only.
- Hook `classify-task.sh` (UserPromptSubmit) - both profiles.
- Hook `verify-final-review.sh` (Stop) - both; reads `KIT_PROFILE` to decide
  which review path to enforce.

## NOT available (intentionally)

`codex-coder`/`codex-reviewer` subagents, bash wrappers for codex, or a
`plan-with-review` skill - all replaced by the official Codex Plugin (full) and
superpowers writing-plans.
