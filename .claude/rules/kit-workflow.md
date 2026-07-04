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

- Trivial / mechanical / docs → just do it, brief summary.
- Real feature or multi-file change → plan first (superpowers
  writing-plans), run a review on the plan, get user approval, implement.
- Large or risky (new deps, refactor, migration, auth/payment, novel
  architecture) → research (research-scout subagent) + brainstorm before
  planning; adversarial review for the plan.

If `docs/specs/` contains a spec: it is the authoritative requirements
source — skip brainstorming, still derive a codebase-aware plan, and still
review the spec itself (it is an external artifact; isolation applies).

## Reviews that are NOT optional

- **Final review**: before declaring a task complete, if the session
  modified business-logic files not yet reviewed → run `/kit-review`. The
  Stop hook (`verify-final-review.sh`, when enabled) enforces this: it sees
  uncommitted changes AND commits made since session start, and its block
  message names the marker to touch after the review.
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
