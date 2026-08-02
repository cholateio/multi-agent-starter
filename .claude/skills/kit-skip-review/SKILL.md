---
name: kit-skip-review
description: Record a skip of the kit's final-review Stop gate for the current
  session. Two modes — user mode (the user explicitly asked to skip) and,
  since v4.9, model mode (you judge a NON-SENSITIVE batch not review-worthy;
  audited, hook-enforced floor). When in doubt, defer instead of skipping.
---

# /kit-skip-review — gate skip (user-approved or model-judged)

The Stop hook (`verify-final-review.sh`) blocks turn-end when business-logic
changes crossed the review threshold. This skill records a decision to waive
that review once. The flag path is in KIT_CONTEXT (session start).

## Mode 1 — user mode (the user said to skip)

1. Triggered by an explicit user request ("skip review", "這次不用 review").
2. Write the flag; first line must start with `user-approved`:
   `echo "user-approved date=<YYYY-MM-DD> quote=\"<the user's actual words>\"" > /tmp/claude-skip-review-<session_id>`
   The quote field is the audit trail — the user's real words, never a
   paraphrase you wish they had said.
3. This mode can settle ANY batch, including sensitive/protected ones (the
   gate logs sensitive user-skips to the session skiplog).

## Mode 2 — model mode (v4.9: your own judgment, audited)

Use when YOU judge the batch not worth a review: throwaway or experimental
code, a one-off analysis script, scratch work that will never be depended on.

1. Hard floor (hook re-checks batch content; the flag's self-report counts
   for nothing): batches touching sensitive paths
   (auth/payment/migration/security/…), protected-paths, or that are not
   measurable (no baseline / binary) CANNOT be model-skipped — the gate
   rejects the flag, audits the attempt, and re-blocks. Those need
   /kit-review or the user's word.
2. Write the flag; both fields are mandatory:
   `echo "skipped-by=model reason=<one line: why not review-worthy> scope=<N lines/M files>" > /tmp/claude-skip-review-<session_id>`
3. The gate honors it ONLY after appending the reason/scope to the session
   skiplog (`/tmp/claude-kit-skiplog-<session_id>.jsonl`) — audit-fail-closed.
   Reasons are sampled against the actual diff; a reason that misdescribes
   the batch is the fastest way to lose this privilege.
4. Judgment guide: skip is for "this code does not deserve review", defer is
   for "review later, when the feature settles". If you hesitate between
   them, defer (the block message shows the defer one-liner).

## After either mode

Tell the user what was skipped and why (one line). The flag is consumed at
the next turn-end; later batches are gated again.
