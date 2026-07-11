# Multi-Agent Workflow Rules

> **Kit-owned file.** Overwritten verbatim by `init.sh --update`. To
> customize, edit the kit repo and redeploy — do not edit this copy.

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
  unavailable. Report the failure (quota / auth / network + fix) and let
  the user choose: wait / skip / explicitly accept a temporary solo review.
- Profile undeterminable → ask the user before reviewing.

## Workflow sizing (judge it yourself)

A `TASK_CLASSIFICATION` hint appears only for explicit user overrides —
`explicit_skip` / `explicit_full` — honor it. Otherwise use judgment:

- Small (trivial / mechanical / docs, or a code change meeting ALL of:
  ≤2 files, roughly ≤50 changed lines, no new dependency, no schema/data
  migration, no auth/payment/security surface, no public API or behavior
  contract change, nothing in the project CLAUDE.md "Project-specific
  constraints") → just do it, verify yourself (run the tests), brief
  summary. Do NOT invoke superpowers brainstorming / writing-plans / TDD
  for these: this section is a project instruction and, by superpowers'
  own precedence rule (project instructions > skills), it overrides those
  skills' auto-trigger descriptions for small tasks.
- Beyond the small criteria (feature-sized or multi-file work) → plan
  first (superpowers writing-plans), run a review on the plan, get user
  approval, implement.
- Large or risky (new deps, refactor, migration, auth/payment, novel
  architecture) → research (research-scout subagent) + brainstorm before
  planning; adversarial review for the plan.
- Genuinely ambiguous between small and feature-sized → ask the user one
  sizing question instead of silently running the full flow.

For feature-sized-or-larger plans, the plan presented for approval MUST
include a per-phase main-model proposal: recommended MAIN-conversation
model (e.g. Fable 5 vs Opus 4.8) + reasoning effort, a one-line
rationale, and the escalation trigger ("pull max if stuck on X").
Guidance: novel design / irreversible operations / root-cause debugging
→ strongest model, high effort; spec-locked implementation behind frozen
interfaces → one tier down. At each phase boundary during execution,
remind the user in one line: "next phase suggests <model>/<effort> —
switch with /model, or continue as-is." Advisory only — the user
executes the switch; never block on it. (Subagent tiers stay
kit-delegation's job.)

If `docs/specs/` contains a spec: it is the authoritative requirements
source — skip brainstorming, still derive a codebase-aware plan, and still
review the spec itself (it is an external artifact; isolation applies).

## Reviews that are NOT optional

- **Final review**: before declaring a task complete, if the session
  modified business-logic files not yet reviewed → run `/kit-review`. The
  Stop hook (`verify-final-review.sh`, when enabled) enforces this: it sees
  uncommitted changes AND commits made since session start, and it only
  accepts markers carrying a `reviewed-by=` evidence line — `/kit-review`
  writes that line after the review actually runs; a bare touch does not
  pass and is called out. v4.3: the gate auto-allows while the CUMULATIVE
  unreviewed change stays small (≤50 lines / ≤2 business files, no
  sensitive or protected path) — small tweaks accumulate and the review
  that fires once the threshold is crossed covers the whole batch. Do not
  run ceremonial reviews for changes under that threshold, and do not
  slice work to stay under it: sensitive paths (auth/payment/migration/
  protected-paths) are always size-blind.
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
