#!/usr/bin/env bash
#
# tool-breaker.sh — circuit breaker + tool-call telemetry (dual event)
#
# Registered under TWO hook events (settings.json), branching on
# hook_event_name:
#
#   PreToolUse (matcher "*") — HARD breaker + telemetry:
#     The highest-signal collapse pattern of a long-context model is the
#     retry spiral: the exact same tool call, same arguments, over and over.
#     3rd consecutive IDENTICAL call (tool_name + tool_input hash, no other
#     call in between) → deny with a stop-and-think message. Polling-type
#     tools are exempt (legitimately repeat identical calls) and do not
#     touch the counter either way.
#
#   PostToolUseFailure (matcher "*") — SOFT warning + telemetry:
#     Fires after a tool call FAILS (verified: PostToolUse itself only fires
#     on success). The tool already ran, so blocking is physically
#     impossible — when failures get dense (>=3 among the last 12 telemetry
#     events) exit 2 surfaces a diagnose-before-retrying warning to the
#     model via stderr.
#     Version note: PostToolUseFailure needs a recent Claude Code (verified
#     present in v2.1.201's event registry alongside all other hook events).
#     Older versions simply never dispatch it — the PreToolUse half of this
#     script still works there; degradation is silent and harmless.
#
# Telemetry: every event appends one JSON line to
#   /tmp/claude-kit-toollog-<session_id>.jsonl
# {ts, e: call|deny|fail, t: tool_name, h: input-hash, n: repeat-count}.
# Hashes only — tool_input content is never logged (secrets). The log is
# the post-hoc audit trail for "when did the session start collapsing"
# and for cross-checking review-marker honesty.
#
# Escape hatch (user-only): launch the session with KIT_BREAKER=off.
# Failures here must never break the tool flow: every unexpected path
# exits 0. Reference: https://code.claude.com/docs/en/hooks

set -uo pipefail

[[ "${KIT_BREAKER:-on}" == "off" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# sha1 of stdin, portable: GNU sha1sum, BSD/macOS shasum, else cksum (weaker,
# but equality detection is all the breaker needs).
hash_stdin() {
    if command -v sha1sum >/dev/null 2>&1; then
        sha1sum | cut -c1-12
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 1 | cut -c1-12
    else
        cksum | tr ' \t' '--'
    fi
}

INPUT=$(cat 2>/dev/null || echo '{}')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

LOG="/tmp/claude-kit-toollog-${SESSION_ID}.jsonl"
STATE="/tmp/claude-kit-lastcall-${SESSION_ID}"
TS=$(date +%H:%M:%S 2>/dev/null || echo "-")

log_event() {  # $1=e  $2=h  $3=n
    jq -cn --arg ts "$TS" --arg e "$1" --arg t "$TOOL" --arg h "$2" --arg n "$3" \
        '{ts:$ts, e:$e, t:$t, h:$h, n:($n|tonumber? // 0)}' >>"$LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------- failures
if [[ "$EVENT" == "PostToolUseFailure" ]]; then
    log_event "fail" "-" 0
    # grep -c prints a count even with zero matches (exit 1) — don't `|| echo`
    # here or the substitution would capture "0\n0" and break the -ge test.
    RECENT_FAILS=$(tail -n 12 "$LOG" 2>/dev/null | grep -c '"e":"fail"' 2>/dev/null)
    RECENT_FAILS=${RECENT_FAILS:-0}
    if [[ "$RECENT_FAILS" -ge 3 ]]; then
        echo "kit tool-breaker: ${RECENT_FAILS} tool failures among your recent calls. STOP retrying. Diagnose in one sentence WHY the calls are failing before the next attempt. If the same subtask keeps failing, escalate per kit-delegation.md (hand it up WITH the error log). Blind retries burn context and deepen the failure." >&2
        exit 2
    fi
    exit 0
fi

# ------------------------------------------------------------------ calls
[[ "$EVENT" != "PreToolUse" ]] && exit 0

# Polling-type tools legitimately repeat identical calls; they neither
# increment nor reset the consecutive-identical counter.
case "$TOOL" in
    TaskOutput|TaskGet|TaskList|TaskStop|Monitor|BashOutput|AskUserQuestion)
        log_event "call" "poll" 0
        exit 0
        ;;
esac

INPUT_C=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo '{}')
HASH=$(printf '%s|%s' "$TOOL" "$INPUT_C" | hash_stdin 2>/dev/null)
[[ -z "$HASH" ]] && exit 0

N=1
if [[ -f "$STATE" ]]; then
    read -r LAST_HASH LAST_N < "$STATE" 2>/dev/null || { LAST_HASH=""; LAST_N=0; }
    [[ "$LAST_HASH" == "$HASH" ]] && N=$((LAST_N + 1))
fi
printf '%s %s\n' "$HASH" "$N" >"$STATE" 2>/dev/null || true
log_event "call" "$HASH" "$N"

if [[ "$N" -ge 3 ]]; then
    log_event "deny" "$HASH" "$N"
    jq -n --arg r "CIRCUIT BREAKER (kit tool-breaker): this is consecutive IDENTICAL call #${N} to ${TOOL} — same tool, exact same arguments, nothing else in between. Two identical attempts already failed to give you what you wanted; a third repetition will not either. Before ANY further tool call: (1) state in one sentence why the previous attempts did not satisfy you; (2) change something real — different arguments, a different tool, or escalate per kit-delegation.md (2 strikes on one subtask → hand it up WITH the error log). This exact call stays blocked until it differs." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
fi

exit 0
