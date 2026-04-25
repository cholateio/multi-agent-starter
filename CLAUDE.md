# [PROJECT NAME]

> CLAUDE.md template (v3). Replace [PLACEHOLDERS] with project-specific
> content on first use. The "Multi-Agent Workflow Rules" section is
> generic and rarely needs editing.

## Project goal

[一段話描述這個專案是什麼、核心目的。
 例：「給小型團隊用的 expense tracking SaaS。優先考量易於 self-host。」]

## Stack

[實際 stack 列出。例：]
- Language: [e.g. Python 3.12 / TypeScript 5.4 / Go 1.22]
- Framework: [e.g. FastAPI / Next.js 14 / none]
- Datastore: [e.g. PostgreSQL 16 / SQLite / none]
- Build/run: [e.g. pnpm / make / cargo]
- Test: [e.g. pytest / vitest / cargo test]

## File layout

[新專案首次架構決策後填入。既有專案直接貼 `tree -L 2` 結果。]

```
<project-root>/
├── CLAUDE.md
├── docs/
│   ├── decisions/    ← ADRs
│   └── plans/        ← saved plans from superpowers
├── plans/            ← (alternative location for superpowers plans)
├── .claude/          ← multi-agent workflow infrastructure
└── [your actual source dirs]
```

## Coding standards

[實際 standards 列出。例：]
- [e.g. "Functions: single responsibility, <=50 lines"]
- [e.g. "No `any` types — use `unknown` + type guards"]
- [e.g. "Error handling: Result type, never raw exceptions across module boundaries"]

## Project-specific constraints

[此專案特殊規則。對既有專案這是最重要的段落。例：]
- [e.g. "src/legacy/payment/ — 不可修改，會破壞舊金流整合"]
- [e.g. "All DB writes 必須走 src/db/ 的 repository pattern"]
- [e.g. "Public API surface 在 api/v1/ — breaking change 需要 versioning"]

[新專案初期可留空，由實際使用累積補充。]

---

# Multi-Agent Workflow Rules

> 以下為通用協作規則。除非專案有特殊需求，否則不需要編輯。

## 三方協作概念

This project orchestrates three external AI capabilities:

- **Gemini CLI** (research scout): 蒐集網路資源、整合外部資訊。**只做研究，不寫 code、不 review**。
- **Superpowers** (architect + worker): brainstorm、寫 plan、執行 plan。Claude 的主要規劃和實作流程。
- **Codex Plugin** (reviewer): 跨模型 code review、adversarial challenge。**只做 review，不寫 code**。

Main Claude orchestrates these three based on task type.

## Task-size classification (重要)

The task classifier hook (`.claude/hooks/classify-task.sh`) may inject a
`TASK_CLASSIFICATION` hint into context. Honor it.

If no hint is present, classify yourself using these rules:

| Signal | Classification |
|--------|---------------|
| User said "just do it" / "quick" / "small" | `small_task` |
| User said "full workflow" / "review the plan" | `explicit_full` |
| Estimated change < 30 lines, single file, single concern | `small_task` |
| UI tweak / CSS / copy edit / formatting | `small_task` |
| Bug fix without business logic change | `small_task` |
| New feature, single file, < 100 lines | `medium_task` |
| New feature, multiple files OR new dependencies | `large_task` |
| Refactor, schema migration, auth/payment changes | `large_task` |

### What to run for each classification

**small_task**: Just do it.
- Skip research-before-planning, superpowers brainstorming, superpowers writing-plans
- Make the change directly
- After change: brief summary
- NO automatic codex review (unless task touched business logic — see "Final review trigger" below)

**medium_task**: Light workflow.
- Skip research (unless task involves a new external API/library)
- Use superpowers:writing-plans (skip brainstorming for clarity-low cases)
- Run `/codex:review` on the plan
- User approves
- Implement
- Final review per the rules below

**large_task**: Full workflow.
- Trigger `research-before-planning` skill if task involves: external libraries,
  security, performance-critical paths, novel architecture
- Use superpowers:brainstorming → writing-plans
- Run `/codex:review` on the plan (and `/codex:adversarial-review` if high-stakes)
- User approves
- superpowers:executing-plans with phase-level review (see below)
- Final review

### Phase-level review during executing-plans

When superpowers completes a phase, decide whether to run `/codex:review`:

**MUST review** (no exceptions):
- Phase touched: auth, authorization, session management
- Phase touched: payment, billing, money calculations
- Phase touched: data migration, schema changes
- Phase modified anything in "Project-specific constraints"

**Recommend review (default to yes, ask if unclear)**:
- Phase touched: business logic that users will perceive
- Phase touched: algorithms, state machines, concurrency
- Phase touched: input validation, security boundaries
- Phase ≥ 100 lines

**Skip review**:
- Phase only changed: UI / styling / docs
- Phase only changed: simple glue code, CRUD, type definitions
- Phase < 50 lines and no business logic

### Final review trigger

Before declaring the entire task complete, evaluate:

```
Did this session modify business-logic-bearing files (.py, .ts, .js, .go, .rs, etc.)
that haven't been reviewed by /codex:review yet?
```

If YES → run `/codex:review` on the full change set before summarizing.

The Stop hook (`.claude/hooks/verify-final-review.sh`) enforces this — if you
forget, the hook will block your turn-end and remind you.

## Cross-model isolation principle

The PRIMARY question is "is the reviewer a different model than the writer?",
not "which specialist fits this task?".

- **Code written by main Claude → reviewed by Codex Plugin**: real isolation ✓
- **Code written by codex (via /codex:rescue) → NOT reviewed by codex again**:
  same model = no isolation. Defer to user judgment or accept the original.
- **Plan written by main Claude/superpowers → reviewed by Codex Plugin**: ✓

### Anti-pattern warning

NEVER do "same model writes + same model reviews". This was a documented
mistake from earlier kit versions. Codex writing code AND codex reviewing
code provides almost no isolation value.

## When to engage research-before-planning

Trigger when ANY of these apply for a `large_task`:

- Task involves a library/framework you've not seen used in this codebase
- Task involves security-sensitive territory (auth, crypto, secrets)
- Task involves performance-critical paths (you'd benefit from current benchmarks)
- Task involves novel architecture (you'd benefit from seeing how others did it)

DO NOT trigger for:
- Tasks within established patterns of this codebase (existing project)
- `small_task` or `medium_task` (overhead not justified)
- Tasks where the user already provided clear technical direction

## When to STOP and ask the user

Stop and ask the user (do NOT auto-proceed) when:

- Research-scout findings suggest a meaningfully better approach than the
  current plan assumed → reconfirm direction
- `/codex:review` flagged a `critical` or `high` issue you can't resolve
  from your context
- `/codex:adversarial-review` challenged a fundamental premise of the plan
- Phase will modify > [PROJECT-SPECIFIC LINE THRESHOLD, default 100] lines
- About to delete or rewrite > 30 existing lines
- Touches anything in "Project-specific constraints"
- Codex/Gemini are unavailable (quota/auth) — ask whether to proceed without
  cross-model review or wait

## Service unavailability handling

When a tool fails (codex quota exhausted, gemini API error, etc.):

1. **Report clearly to the user** — never silently skip
2. **Categorize the failure**:
   - Quota exhausted → suggest waiting or skipping this review
   - Auth issue → tell user to check `codex login` / `GEMINI_API_KEY`
   - Network → suggest retry
3. **Ask the user explicitly**:
   - (a) Skip this review and proceed (less safe — explain implication)
   - (b) Wait and retry in N minutes
   - (c) For research scout failures only: proceed without research
     (acceptable — research is nice-to-have, not gate)

Critical: do NOT auto-fall-back from `/codex:review` to "Claude self-review"
silently. That breaks the isolation guarantee. The user must explicitly accept
this fallback.

## Skills available

- `research-before-planning` — pre-brainstorming research via gemini scout

(Most workflow logic is in CLAUDE.md and hooks, not skills, in v3.)

## Subagents available

- `gemini-research-scout` — wraps gemini CLI for web research only

## Hooks active (see `.claude/settings.json`)

- `classify-task.sh` (UserPromptSubmit): auto-tags task size
- `verify-final-review.sh` (Stop): blocks turn-end if business logic
  unreviewed

## What main Claude does NOT have available (intentionally)

- `codex-coder` / `codex-reviewer` subagents — replaced by official
  Codex Plugin (`/codex:review`, `/codex:rescue`, etc.)
- Bash wrapper for codex — Codex Plugin handles delegation
- A `plan-with-review` skill — superpowers' writing-plans replaces it,
  combined with auto-trigger of `/codex:review` on the resulting plan
