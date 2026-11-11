# Multi-Agent Workflow Rules

> **Kit-owned.** Don't edit here — change plugin/rules in the kit repo, then /reload-plugins.

## Profiles: who reviews is the whole point

`KIT_PROFILE` (else `profile` in ~/.config/kit/config.toml) selects the profile
(default `full`). When hooks are
enabled, the SessionStart KIT_CONTEXT block announces the active profile,
reviewer availability, and this session's marker paths — trust it over guessing.

| Profile | "run a review" resolves to |
|---------|----------------------------|
| `full`  | cross-model codex review, run via `/kit:review`（adversarial variant for high-stakes work）— the raw `/codex:review` slash command is USER-only（`disable-model-invocation`）. |
| `solo`  | fresh-context `solo-reviewer` subagent — state/time isolation ONLY. Always tell the user: "cross-model isolation is OFF". |

Prefer `/kit:review`: it resolves the profile AND writes the marker the Stop
gate checks. `/kit:skip-review`: user mode on explicit request; model-judged
mode (v4.9) for non-sensitive batches only — sensitive/protected/unmeasurable
stay USER-only (the skill and the hook enforce the floor).

**Isolation landmines (never do these):**

- Same model writes + same model reviews, presented as real isolation.
- (full) Reviewing codex-written code (`/codex:rescue`) with codex again — zero
  isolation; main Claude or the user reviews it.
- Silently falling back from codex to self-review when codex is unavailable —
  report the failure (quota/auth/network + fix), let the user choose wait / skip
  / temporary solo review.
- Profile undeterminable → ask before reviewing.

## Workflow sizing (judge it yourself — by risk, not by size)

A `TASK_CLASSIFICATION` hint appears only for explicit user overrides —
`explicit_skip` / `explicit_full` — honor it. Otherwise use judgment:

- **Default → just do it.** Any change with no sensitive path (defined under
  "Final review" below), no new dependency, no public API or behavior-contract
  change, nothing irreversible. Line and file counts alone never trigger a
  plan. Verify yourself (run the tests), brief summary. For multi-step work say
  the plan in a few lines and proceed — no plan review, no approval wait.
- **Plan + user approval first** when the change touches a sensitive path,
  adds a dependency, changes a public API or behavior contract, does something
  irreversible, or is a cross-module redesign. Write the plan, run a review on
  it (adversarial for high stakes), get approval, implement. Unfamiliar
  library or novel architecture → research (research-scout subagent) first.
- Unsure which side → ask the user one question.

**Superpowers skills are tools, not gates.** Use brainstorming / writing-plans
/ TDD / subagent-driven-development when you judge they improve the result or
the user asks for them — not because a trigger description matches. This
overrides their "must invoke" auto-trigger (superpowers' own precedence:
user and project instructions > skills).

If `docs/specs/` or `docs/superpowers/specs/` has a spec: it is the authoritative requirements source —
skip brainstorming, still derive a codebase-aware plan, still review the spec
(isolation applies to it too).

## 註解紀律

只寫代碼顯示不了的：不變量/外部約束、跨檔耦合、非顯然的 why；不寫敘述性或
辯護性註解（歸 commit message／LESSONS）。**代碼內註解一律英文**，config／
secret 值行不放非 ASCII（見 LESSONS）；文件／prose／commit 用中文。

## Reviews that are NOT optional

- **Final review**: before declaring a task complete, settle every unreviewed
  business-logic batch AND any pending defer — via `/kit:review`, or a judged
  skip via `/kit:skip-review`. The Stop gate (v4.9) asks for ONE decision each
  time the cumulative unreviewed batch crosses the small threshold — review
  now / defer (feature mid-flight; the gate re-asks each threshold-distance) /
  skip (model-judged for non-sensitive batches, audited; mechanics are in the
  hook's block message). Do not run ceremonial reviews
  under the threshold, nor slice work to stay under it. **Sensitive paths** =
  auth/authz/session, payment, migration/schema, security/secrets, kit.toml and
  its [protected] paths, AGENTS.md Constraints. They are size-blind: no defer,
  no model-skip — review or the user's word only.
- **Re-review scope**: round 1 covers the whole change set; later rounds scope
  to the fix delta, whatever depends on it (callers of touched functions/types —
  stale-green's front door), and the code the findings touched. Do NOT point the
  reviewer at the whole branch every round — re-scanning unchanged, already-
  reviewed code breeds rounds (receipt 2026-07-11, evals.md). It narrows what
  gets RE-read, not what gets read: every line keeps
  its round-1 review; a redesign earns a fresh whole-set round; sensitive paths
  (as defined above) stay whole-set every round. Run each
  re-review in a FRESH context fed only the scoped delta + the findings to
  recheck — never resume/replay the original reviewer (receipt 2026-07-23).
- **Phase-level review** during plan execution is NOT per-task. Fire it only
  at (a) sensitive paths as defined above (always, size-blind) — and (b) a dependency boundary a
  later phase builds on. Ordinary phases batch into the Final review; per-task
  review re-covers it anyway (receipt 2026-07-23, evals.md).

## STOP and ask the user when

- A review flags a critical/high issue you can't resolve from context, or
  challenges the plan's premise.
- Research suggests a meaningfully better approach than the plan assumed.
- Executing an approved plan, a phase would delete/rewrite > 30 existing lines
  the plan did not forecast (= `/kit:judgment` R3.2).
- The change touches AGENTS.md "Constraints".
- (full) codex unavailable — ask whether to proceed or wait.
