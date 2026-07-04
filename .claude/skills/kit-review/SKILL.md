---
name: kit-review
description: Run the kit's profile-aware review on the current change set and
  record it for the Stop-hook gate. full profile -> cross-model /codex:review;
  solo profile -> fresh-context solo-reviewer subagent (state/time isolation
  only, disclosed to the user). Use when a change set needs its kit review,
  when the user says "review this", or when the Stop hook blocked the turn
  asking for a review.
---

# /kit-review — profile-aware review

One skill, one promise: the review that runs matches the active profile, and
the Stop-hook gate learns about it (evidence marker written) so it won't
re-block.

## Steps

1. **Resolve the active profile**: `KIT_PROFILE` env var, default `full`.
   If hooks are enabled, the session-start KIT_CONTEXT block already
   announced it, along with this session's exact marker paths.

2. **Run the review**:
   - **full** → invoke `/codex:review` on the change set
     (`/codex:adversarial-review` instead for high-stakes work: auth,
     payments, schema/data migration, security boundaries).
   - **solo** → spawn the `solo-reviewer` subagent on the diff, and tell the
     user plainly: "solo profile: cross-model isolation is OFF — this is a
     same-model self-review (state/time isolation only)."

3. **Handle findings before claiming done**: fix or explicitly defer each
   finding and report the outcome to the user. Never silently absorb
   findings.

4. **Write the evidence marker** so the Stop gate records the review. Exact
   paths are in KIT_CONTEXT (session start). One line, no more:
   - full:
     `echo "reviewed-by=codex verdict=<approve|with-fixes> scope=\"<one line: what was reviewed>\" date=<YYYY-MM-DD>" > /tmp/claude-codex-reviewed-<session_id>`
   - solo:
     `echo "reviewed-by=solo verdict=<approve|with-fixes> scope=\"<one line>\" date=<YYYY-MM-DD>" > /tmp/claude-reviewed-<session_id>`

   If the review verdict is **Blocked**, do NOT write the marker — the gate
   rejects `verdict=blocked` by design. Fix the blocking findings, then
   re-run /kit-review and record the passing verdict.

   A bare `touch` does NOT pass the gate (v4.0). NEVER write this line
   without having actually run the review in this session — the marker is
   an audit record, cross-checkable against the session tool log
   (/tmp/claude-kit-toollog-<session_id>.jsonl). Faking it is the single
   fastest way to corrupt this harness.

   The marker certifies the working-tree state at the moment the turn ends —
   small finding-fixes made between review and turn-end ride along with it.
   If the fix wave after a review is substantial, re-run /kit-review instead
   of riding the marker.

## Reviewer unavailable?

full profile with codex missing / quota exhausted / auth broken: do NOT
silently fall back to a Claude self-review — that breaks the isolation
guarantee. Report the failure (quota / auth / network, plus the fix) and ask
the user: wait, skip, or explicitly accept a temporary solo-style
self-review.
