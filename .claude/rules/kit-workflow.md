# Multi-Agent Workflow Rules

> **Kit-owned.** Do not edit this copy — customize in the kit repo, then
> `init.sh --update`.

## Profiles: who reviews is the whole point

The `KIT_PROFILE` env var selects the per-machine profile (default `full`).
When hooks are enabled, the SessionStart KIT_CONTEXT block announces the
active profile, reviewer availability, and this session's review-marker
paths — trust it over guessing.

| Profile | "run a review" resolves to |
|---------|----------------------------|
| `full`  | `/codex:review` — cross-model, real isolation. `/codex:adversarial-review` for high-stakes work. |
| `solo`  | fresh-context `solo-reviewer` subagent — state/time isolation ONLY. Always tell the user: "cross-model isolation is OFF". |

Prefer `/kit-review`: it resolves the profile AND touches the review marker
the Stop gate checks. `/kit-skip-review` only on explicit user request.

**Isolation landmines (never do these):**

- Same model writes + same model reviews, presented as real isolation.
- (full) Reviewing codex-written code (`/codex:rescue` output) with codex
  again — zero isolation. Main Claude or the user reviews it instead.
- Silently falling back from codex review to self-review when codex is
  unavailable — report the failure (quota / auth / network + fix) and let the
  user choose: wait / skip / accept a temporary solo review.
- Profile undeterminable → ask the user before reviewing.

## Workflow sizing (judge it yourself)

A `TASK_CLASSIFICATION` hint appears only for explicit user overrides —
`explicit_skip` / `explicit_full` — honor it. Otherwise use judgment:

- Small (trivial / mechanical / docs, or a code change meeting ALL of:
  ≤4 files and roughly ≤50 changed lines — test files count toward
  neither — no new dependency, no schema/data
  migration, no auth/payment/security surface, no public API or behavior
  contract change, nothing in the project CLAUDE.md "Project-specific
  constraints") → just do it, verify yourself (run the tests), brief
  summary. Do NOT invoke superpowers brainstorming / writing-plans / TDD
  for these — this section overrides those skills' auto-triggers
  (superpowers' own precedence: project instructions > skills).
- Beyond the small criteria (feature-sized or multi-file work) → plan
  first (superpowers writing-plans), run a review on the plan, get user
  approval, implement.
- Large or risky (new deps, refactor, migration, auth/payment, novel
  architecture) → research (research-scout subagent) + brainstorm before
  planning; adversarial review for the plan.
- Genuinely ambiguous between small and feature-sized → ask the user one
  sizing question instead of silently running the full flow.

For feature-sized-or-larger plans, the plan presented for approval MUST
include, per phase: recommended MAIN-conversation model (e.g. Fable 5 vs
Opus 4.8) + reasoning effort + a one-line rationale + the escalation
trigger ("pull max if stuck on X"). Novel design / irreversible ops /
root-cause debugging → strongest model, high effort; spec-locked
implementation behind frozen interfaces → one tier down. At each phase
boundary, remind the user in one line: "next phase suggests
<model>/<effort> — switch with /model, or continue as-is." Advisory only;
never block on it. (Subagent tiers stay kit-delegation's job.)

If `docs/specs/` contains a spec: it is the authoritative requirements
source — skip brainstorming, still derive a codebase-aware plan, and still
review the spec itself — isolation applies to it too.

## 註解紀律（代碼的讀者是 AI）

機隊代碼的主要讀者是未來的 AI session，不是人。註解只寫代碼顯示
不了的資訊：不變量/外部約束、跨檔耦合、非顯然的 why、附日期的收據
——其餘零註解。禁止敘述性註解（下一行在做什麼）與辯護性註解（對
reviewer 解釋改動為何正確）；那些歸 commit message 與 LESSONS。
docstring 只給 public API 寫契約（參數/回傳/raises）。

## Reviews that are NOT optional

- **Final review**: before declaring a task complete, if the session modified
  business-logic files not yet reviewed → run `/kit-review`. The Stop hook
  (`verify-final-review.sh`) sees committed and uncommitted work alike, and only
  accepts a marker carrying a `reviewed-by=` evidence line, which `/kit-review`
  writes after the review actually runs — a bare `touch` does not pass. The gate auto-allows while the CUMULATIVE
  unreviewed change stays small (≤50 lines / ≤4 business files — test files
  count toward neither — no sensitive
  or protected path): small tweaks accumulate, and the review that fires once
  the threshold is crossed covers the whole batch. Do not run ceremonial
  reviews under that threshold, and do not slice work to stay under it —
  sensitive paths (auth/payment/migration/protected-paths) are always
  size-blind.
- **Re-review scope**: round 1 covers the whole change set; later rounds scope
  to the fix delta, whatever depends on what the fix changed (callers of every
  touched function/type/interface — stale-green's front door), and the code the
  findings touched. Do NOT point the reviewer at the whole branch every round —
  re-scanning already-reviewed, unchanged code mines new angles out of old code
  and makes rounds breed rounds (receipt: 6 rounds on 3 small UI changes,
  2026-07-11). It narrows what gets RE-read, never what gets read: every line
  keeps its round-1 review, a fix wave that redesigns the approach earns a fresh
  whole-set round, and sensitive paths (auth/payment/migration/protected-paths)
  stay whole-set every round.
- **Phase-level review** during plan execution — always for: auth/authz/
  session, payment/billing/money, data migration/schema, and anything in
  the project CLAUDE.md "Project-specific constraints". Skip for docs,
  styling, and trivial glue.

## STOP and ask the user when

- A review flags a critical/high issue you can't resolve from context, or
  challenges the plan's premise.
- Research suggests a meaningfully better approach than the plan assumed.
- A phase would modify > 100 lines, or delete/rewrite > 30 existing lines.
- The change touches the project CLAUDE.md "Project-specific constraints".
- (full) codex unavailable — ask whether to proceed or wait.
