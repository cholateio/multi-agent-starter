# Multi-Agent Workflow Rules

> **Kit-owned.** Don't edit here — change in the kit repo, then `init.sh --update`.

## Profiles: who reviews is the whole point

The `KIT_PROFILE` env var selects the profile (default `full`). When hooks are
enabled, the SessionStart KIT_CONTEXT block announces the active profile,
reviewer availability, and this session's marker paths — trust it over guessing.

| Profile | "run a review" resolves to |
|---------|----------------------------|
| `full`  | `/codex:review` — cross-model, real isolation. `/codex:adversarial-review` for high-stakes work. |
| `solo`  | fresh-context `solo-reviewer` subagent — state/time isolation ONLY. Always tell the user: "cross-model isolation is OFF". |

Prefer `/kit-review`: it resolves the profile AND writes the marker the Stop
gate checks. `/kit-skip-review` only on explicit user request.

**Isolation landmines (never do these):**

- Same model writes + same model reviews, presented as real isolation.
- (full) Reviewing codex-written code (`/codex:rescue`) with codex again — zero
  isolation; main Claude or the user reviews it.
- Silently falling back from codex to self-review when codex is unavailable —
  report the failure (quota/auth/network + fix), let the user choose wait / skip
  / temporary solo review.
- Profile undeterminable → ask before reviewing.

## Workflow sizing (judge it yourself)

A `TASK_CLASSIFICATION` hint appears only for explicit user overrides —
`explicit_skip` / `explicit_full` — honor it. Otherwise use judgment:

- Small (trivial / mechanical / docs, or a code change meeting ALL of:
  ≤4 files and roughly ≤50 changed lines — test files count toward neither —
  no new dependency, no schema/migration, no auth/payment/security surface, no
  public API or behavior-contract change, nothing in the project CLAUDE.md
  "Project-specific constraints") → just do it, verify yourself (run the tests),
  brief summary. Do NOT invoke superpowers brainstorming / writing-plans / TDD
  for these — this section overrides those auto-triggers (superpowers' own
  precedence: project instructions > skills).
- Beyond the small criteria (feature-sized or multi-file work) → plan
  first (superpowers writing-plans), run a review on the plan, get user
  approval, implement.
- Large or risky (new deps, refactor, migration, auth/payment, novel arch) →
  research (research-scout subagent) + brainstorm before planning; adversarial
  review for the plan.
- Ambiguous between small and feature-sized → ask the user one sizing question
  instead of silently running the full flow.

For feature-sized+ plans, the approval plan MUST give, per phase: recommended
MAIN model (Fable 5 vs Opus 4.8) + reasoning effort + one-line rationale +
escalation trigger. Novel design / irreversible ops / root-cause debugging →
strongest model, high effort; spec-locked work behind frozen interfaces → one
tier down. At each phase boundary remind the user once: "next phase suggests
<model>/<effort> — /model or continue". Advisory; never block. (Subagent tiers
= kit-delegation.)

If `docs/specs/` has a spec: it is the authoritative requirements source —
skip brainstorming, still derive a codebase-aware plan, still review the spec
(isolation applies to it too).

## 註解紀律（代碼的讀者是 AI）

機隊代碼主要讀者是未來 AI session。註解只寫代碼顯示不了的四類：
不變量/外部約束、跨檔耦合、非顯然的 why、附日期收據——其餘零註解。禁止
敘述性（下一行做什麼）與辯護性（向 reviewer 解釋為何正確）註解，歸 commit
message／LESSONS。docstring 只給 public API 契約。**代碼內註解一律英文**——
非 ASCII 會滲進 byte 敏感語境（如 .env 值行，見 LESSONS）；文件／prose／
commit 用中文。

## Reviews that are NOT optional

- **Final review**: before declaring a task complete, if the session modified
  business-logic files not yet reviewed → run `/kit-review` (a bare `touch`
  marker does not pass; the gate sees committed + uncommitted work). The gate
  auto-allows while the CUMULATIVE unreviewed change stays small (≤150 lines /
  ≤8 business files — test files count toward neither — no sensitive or
  protected path): small tweaks accumulate; the review that fires once the
  threshold is crossed covers the whole batch. Do not run ceremonial reviews
  under that threshold, nor slice work to stay under it — sensitive paths
  (auth/payment/migration/protected-paths) are always size-blind.
- **Re-review scope**: round 1 covers the whole change set; later rounds scope
  to the fix delta, whatever depends on it (callers of touched functions/types —
  stale-green's front door), and the code the findings touched. Do NOT point the
  reviewer at the whole branch every round — re-scanning unchanged, already-
  reviewed code breeds rounds (receipt 2026-07-11: 6 rounds on 3 small UI
  changes). It narrows what gets RE-read, not what gets read: every line keeps
  its round-1 review; a redesign earns a fresh whole-set round; sensitive paths
  (auth/payment/migration/protected-paths) stay whole-set every round. Run each
  re-review in a FRESH context fed only the scoped delta + the findings to
  recheck — never resume/replay the original reviewer (receipt 2026-07-23:
  replaying 285 lines to recheck a 9KB delta = 148k).
- **Phase-level review** during plan execution is NOT per-task. Fire it only
  at (a) sensitive paths — auth/authz/session, payment, migration/schema,
  CLAUDE.md constraints (always, size-blind) — and (b) a dependency boundary a
  later phase builds on. Ordinary phases batch into the Final review; per-task
  review re-covers it anyway (receipt 2026-07-23: 9 redundant = 553k).

## STOP and ask the user when

- A review flags a critical/high issue you can't resolve from context, or
  challenges the plan's premise.
- Research suggests a meaningfully better approach than the plan assumed.
- A phase would modify > 100 lines, or delete/rewrite > 30 existing lines.
- The change touches the project CLAUDE.md "Project-specific constraints".
- (full) codex unavailable — ask whether to proceed or wait.
