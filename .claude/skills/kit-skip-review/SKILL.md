---
name: kit-skip-review
description: Record a USER-approved skip of the kit's final-review Stop gate
  for the current session. Only invoke when the user explicitly asked to skip
  the review (e.g. "skip review", "這次不用 review") — never self-invoke to
  get past a block.
---

# /kit-skip-review — user-approved gate bypass

The Stop hook (`verify-final-review.sh`) blocks turn-end when business-logic
files changed without a review. This skill records the user's decision to
waive that review once.

## Steps

1. **Verify this is the user's call.** This skill must be triggered by an
   explicit user request. If you (Claude) merely want to end the turn, the
   answer is /kit-review, not this skill.

2. **Write the bypass flag** for this session — the exact path is in
   KIT_CONTEXT (session start). The gate only accepts a flag whose first
   line starts with `user-approved` (a bare touch is discarded):
   `echo "user-approved date=<YYYY-MM-DD> quote=\"<the user's actual words>\"" > /tmp/claude-skip-review-<session_id>`
   The quote field is the audit trail — put the user's real words in it,
   never a paraphrase you wish they had said.

3. **Tell the user** the gate is bypassed for the next turn-end only — the
   hook consumes the flag when it fires, so later turns are gated again.
