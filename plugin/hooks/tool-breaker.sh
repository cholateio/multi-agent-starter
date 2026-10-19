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

# ------------------------------------------------- guard-preserve (D13, v5)
# The global git guard (core.hooksPath → kit shims → plugin/guard) cannot
# stop git's own bypasses. The model's Bash calls ARE visible here, so its
# routes around the guard are denied: --no-verify (any git subcommand,
# abbreviations included), `git commit -n` (= --no-verify; `git push -n` is a
# dry run and stays allowed), KIT_GUARD= (never honored by the guard anyway),
# any core.hooksPath touch, and overriding the config that carries it
# (GIT_CONFIG_GLOBAL/COUNT/PARAMETERS=, HOME=/XDG_CONFIG_HOME= on a
# commit/push, env -i / env -u HOME / unset HOME before one, -c include.path=;
# KIT_STATE_HOME= too — it moves where the guard looks for a bypass file),
# arming a bypass (`kit guard bypass`, writing a guard/bypass-<id> file), and
# direct writes to the guard's inputs (shims, git config, privacy.local.toml,
# kit config.toml, plugin/guard/). The only model route is asking the USER for
# `kit guard bypass "<reason>"` (10-minute, single-use, audited). Humans
# keep `--no-verify` — the audit catches that after the fact.
# Scope (Phase 3 ruling R-guard-scope): the global git guard covers EVERY
# repo, so guard-preserve runs in every directory — before the kit.toml
# activation gate, for Bash PreToolUse only, without telemetry outside kit
# projects. The user-only switches KIT=off / KIT_BREAKER=off still silence it.
# Runs independently of the pipe-guard waivers (an echo/heredoc/pipefail
# prefix exempts nothing here). Text is flattened first: a quoted span that
# is ONE plain token is unquoted (`"--no-verify"`, `--no-"verify"` reach git
# as the flag) while a span with spaces becomes placeholder Q (a commit
# message mentioning the flag is data); backslash escapes are resolved.
# When a nested shell / eval / xargs is involved, the fully unquoted text is
# scanned too (deny direction). Anti-footgun, not anti-evasion: variables,
# aliases and scripts are out of scope (v4.9 threat boundary).
guard_flatten() {  # stdin: raw command → stdout: flattened single line
    tr '\n' ';' | awk '
        function flush(tok) { if (tok != "" && tok ~ /^[A-Za-z0-9_.=\/:@+,-]*$/) return tok; return "Q" }
        { out=""; st=0; tok=""; len=length($0)
          for(i=1;i<=len;i++){ c=substr($0,i,1)
            if(st==0){
              if(c=="\\"){i++; out=out substr($0,i,1); continue}
              if(c=="$" && substr($0,i+1,1)=="\047"){st=3; i++; tok=""; continue}
              if(c=="\047"){st=1; tok=""; continue}
              if(c=="\""){st=2; tok=""; continue}
              out=out c; continue }
            if(st==1){ if(c=="\047"){st=0; out=out flush(tok)} else tok=tok c; continue }
            if(st==2){ if(c=="\\"){i++; tok=tok substr($0,i,1); continue}
                       if(c=="\""){st=0; out=out flush(tok)} else tok=tok c; continue }
            if(st==3){ if(c=="\\"){i++; tok=tok substr($0,i,1); continue}
                       if(c=="\047"){st=0; out=out flush(tok)} else tok=tok c; continue }
          }
          if(st!=0) out=out "Q"
          print out }' 2>/dev/null
}
GP_SEP='(^|[;&|(`[:space:]])'
GP_NEST='(^|[;&|(`[:space:]])((bash|sh|zsh|dash|ksh)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c|eval|xargs|script)([[:space:]]|$)'
# guard_unquote1: remove ONE level of shell quoting, keeping quoted text verbatim
# (inner quotes survive for the next guard_flatten); newlines become ';'
guard_unquote1() {
    tr '\n' ';' | awk '
        { out=""; st=0; len=length($0)
          for(i=1;i<=len;i++){ c=substr($0,i,1)
            if(st==0){
              if(c=="\\"){i++; out=out substr($0,i,1); continue}
              if(c=="$" && substr($0,i+1,1)=="\047"){st=3; i++; continue}
              if(c=="\047"){st=1; continue}
              if(c=="\""){st=2; continue}
              out=out c; continue }
            if(st==1){ if(c=="\047") st=0; else out=out c; continue }
            if(st==2){ if(c=="\\"){ n=substr($0,i+1,1); if(n=="\""||n=="\\"||n=="$"||n=="`"){i++; out=out n} else out=out c; continue }
                       if(c=="\"") st=0; else out=out c; continue }
            if(st==3){ if(c=="\\"){i++; out=out substr($0,i,1); continue}
                       if(c=="\047") st=0; else out=out c; continue }
          }
          print out }' 2>/dev/null
}
# the git token may carry a path (/usr/bin/git, ./git); wrappers like
# `command git` / `env git` / `\git` are covered by GP_SEP + flattening
GP_GSEP='(^|[;&|(`[:space:]]|/)'
GP_GLOBAL='([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--[A-Za-z][A-Za-z-]*(=[^[:space:];&|]*)?|-[A-Za-z]))*'
GP_CFG="${GP_GSEP}git${GP_GLOBAL}[[:space:]]+config[[:space:]]([^;&|]*[[:space:]])?"
# PATH is not here (review F7, R3-1): the guard resolves gitleaks ONLY from config.toml
# tools_dir / a recorded gitleaks_path, never PATH, and `export PATH=~/.local/bin:$PATH` is routine
GP_ENVV='(HOME|XDG_CONFIG_HOME|KIT_STATE_HOME|GIT_CONFIG_(GLOBAL|COUNT|PARAMETERS))'
GP_GITCP="([^[:space:];&|]*/)?git([[:space:]][^;&|]*)?[[:space:]](commit|push)([[:space:]]|\$)"
# Guard inputs a Bash command must not WRITE (reads stay allowed): the guard's state
# (bypass-<id>, audit.jsonl), the git-hooks shims, git config files (they carry
# core.hooksPath), privacy.local.toml, the kit config.toml (kit_root → the guard
# scripts), the guard scripts themselves (plugin/guard/) and the Claude hooks that
# enforce all this — activation gate (lib.sh) + this breaker (plugin/hooks/; review R3-9).
# … and the scanner binaries the guard runs (review R4-1): ~/.local/bin/{gitleaks,osv-scanner},
# <tools_dir>/… and the gitleaks_path / osv_scanner_path recorded in config.toml. The guard
# also hash-checks them before each run (a replaced binary = R8, push blocked), so this
# only keeps a `cp stub ~/.local/bin/gitleaks` from turning into a blocked push.
GP_TOOLS='(gitleaks|osv-scanner)([^A-Za-z0-9_.-]|$)'
gp_re_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }
gp_path_re() {  # $1 absolute path → regex for it, also spelled ~/… / $HOME/… / ${HOME}/… under HOME
    local p="$1" h="${HOME:-}"
    if [[ -n "$h" && "$p" == "$h"/* ]]; then
        printf '(~|\\$HOME|\\$\\{HOME\\}|%s)/%s' "$(gp_re_escape "$h")" "$(gp_re_escape "${p#"$h"/}")"
    else gp_re_escape "$p"; fi
}
gp_tool_paths() {
    local cfg="${KIT_CONFIG_HOME:-${HOME:-/nonexistent}/.config/kit}/config.toml" k v out=""
    [[ -f "$cfg" ]] || return 0
    for k in tools_dir gitleaks_path osv_scanner_path; do
        v="$(sed -nE '/^[[:space:]]*\[/q; s/^[[:space:]]*'"$k"'[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$cfg" 2>/dev/null | head -n 1)"
        [[ "$v" == "~/"* ]] && v="${HOME:-/nonexistent}${v:1}"
        [[ "$v" == /?* ]] || continue
        if [[ "$k" == tools_dir ]]; then out+="|$(gp_path_re "${v%/}")/${GP_TOOLS}"
        else out+="|$(gp_path_re "$v")([^A-Za-z0-9_.-]|\$)"; fi
    done
    printf '%s' "$out"
}
GP_PROT="(kit/guard|kit/git-hooks|guard/bypass-|bypass-[0-9a-f]{6,}|guard/audit\\.jsonl|\\.gitconfig|\\.git/config|/git/config|config\\.worktree|privacy\\.local\\.toml|kit/config\\.toml|plugin/guard/|plugin/hooks/|\\.local/bin/${GP_TOOLS}$(gp_tool_paths))"
# guard_write_hit <flattened text>: 0 when a simple command WRITES a protected path.
# Per command segment (split on ; && || | &): a redirect whose target is protected,
# or a write verb whose written operand is protected — rm/mv/touch/truncate/chmod/
# chown/tee/shred/unlink: any operand; cp/ln/install/rsync: the destination (last
# operand); sed/perl/ruby only with -i/--in-place; dd of=; any --output=. A mention
# elsewhere in the line (`rm -rf dist && cat .git/config`) is not a write (review F7).
guard_write_hit() {
    printf '%s' "$1" | grep -qE "$GP_PROT" || return 1
    local seg w last
    while IFS= read -r seg || [[ -n "$seg" ]]; do
        printf '%s' "$seg" | grep -qE "$GP_PROT" || continue
        printf '%s' "$seg" | grep -qE ">[[:space:]]*[^[:space:]]*${GP_PROT}" && return 0
        printf '%s' "$seg" | grep -qE "(^|[[:space:]])(of=|--output[=[:space:]])[^[:space:]]*${GP_PROT}" && return 0
        # the command word: skip assignments and transparent wrappers, then its basename
        read -ra w <<< "$seg"
        local i=0
        while [[ $i -lt ${#w[@]} ]] && [[ "${w[$i]}" =~ ^([A-Za-z_][A-Za-z0-9_]*=.*|\(|sudo|command|env|nohup|time|exec|builtin|-.*)$ ]]; do i=$((i + 1)); done
        [[ $i -lt ${#w[@]} ]] || continue
        local verb="${w[$i]##*/}" rest="${w[*]:$((i + 1))}"
        last="${w[${#w[@]}-1]}"
        case "$verb" in
            rm|mv|touch|truncate|chmod|chown|chgrp|tee|shred|unlink)
                printf '%s' "$rest" | grep -qE "$GP_PROT" && return 0 ;;
            cp|ln|install|rsync)
                printf '%s' "$last" | grep -qE "$GP_PROT" && [[ $((i + 1)) -lt ${#w[@]} ]] && return 0 ;;
            sed|perl|ruby)
                printf ' %s ' "$rest" | grep -qE '[[:space:]](-[A-Za-z]*i[^[:space:]]*|--in-place[^[:space:]]*)[[:space:]]' \
                    && printf '%s' "$rest" | grep -qE "$GP_PROT" && return 0 ;;
        esac
    done < <(printf '%s' "$1" | sed -E 's/[0-9]*>&[0-9-]+//g; s/&>/>/g; s/(\|\||&&|[;|&])/\n/g')
    return 1
}
guard_preserve_hit() {  # $1 = flattened text → 0 if it bypasses the guard
    local t="$1"
    # --no-verify on any git subcommand (git accepts unique abbreviations)
    printf '%s' "$t" | grep -qE "${GP_GSEP}git[[:space:]]([^;&|]*[[:space:]])?--no-veri[a-z]*([=[:space:]]|\$)" && return 0
    # git commit -n (= --no-verify), clustered short flags included
    # (letters before the n must be flag letters, not -m/-F/-c/-C/-t/-u/-S whose value
    # follows attached: `-uno` / `-mnote` are not -n — review F7)
    printf '%s' "$t" | grep -qE "${GP_GSEP}git${GP_GLOBAL}[[:space:]]+commit([[:space:]]+[^;&|]*)?[[:space:]]-[abd-ln-sv-zA-BD-EG-RT-Z]*n[A-Za-z]*([[:space:]]|\$)" && return 0
    # the bypass itself is USER-only (design §7.4): `kit guard bypass`, or
    # forging its state file (<state>/guard/bypass-<repo-id>) by hand
    printf '%s' "$t" | grep -qE "${GP_GSEP}kit[[:space:]]+guard[[:space:]]+bypass([[:space:]]|\$)" && return 0
    # … or writing the guard's own inputs (final review I4; review F6/F7)
    guard_write_hit "$t" && return 0
    # git send-pack pushes without running pre-push
    printf '%s' "$t" | grep -qE "${GP_GSEP}git(${GP_GLOBAL}[[:space:]]+|-)send-pack([[:space:]]|\$)" && return 0
    # KIT_GUARD= as an assignment (prefix, export, env) — a grep for it is fine
    printf '%s' "$t" | grep -qE '(^|[;&|(`])[[:space:]]*((export|env|declare[[:space:]]+-x)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*KIT_GUARD=' && return 0
    # core.hooksPath WRITES only (reads like `git config --get` stay allowed):
    # key followed by a value, --unset/--add/--replace-all/unset/set,
    # --remove-section/--rename-section core, per-command -c / --config-env,
    # GIT_CONFIG_KEY_n / GIT_CONFIG_PARAMETERS carrying the key
    printf '%s' "$t" | grep -qiE "${GP_CFG}core\.hookspath[[:space:]]+[^-;&|[:space:]]" && return 0
    printf '%s' "$t" | grep -qiE "${GP_CFG}(--unset(-all)?|--replace-all|--add|unset|set)[[:space:]]([^;&|]*[[:space:]])?core\.hookspath" && return 0
    printf '%s' "$t" | grep -qiE "${GP_CFG}-?-?(remove|rename)-section[[:space:]]+core([[:space:]]|\$)" && return 0
    printf '%s' "$t" | grep -qiE '(^|[[:space:]])(-c[[:space:]]*|--config-env[=[:space:]])core\.hookspath=' && return 0
    printf '%s' "$t" | grep -qiE 'GIT_CONFIG_[A-Z0-9_]*=[^[:space:]]*core\.hookspath' && return 0
    # an included config file can carry core.hooksPath too (review F1): per-command
    # -c / --config-env include[If.<cond>].path=, GIT_CONFIG_KEY_n, or a persistent write
    printf '%s' "$t" | grep -qiE '(^|[[:space:]])(-c[[:space:]]*|--config-env[=[:space:]])include(if\.[^[:space:]]*)?\.path=' && return 0
    printf '%s' "$t" | grep -qiE 'GIT_CONFIG_[A-Z0-9_]*=[^[:space:]]*include(if\.[^[:space:]]*)?\.path' && return 0
    printf '%s' "$t" | grep -qiE "${GP_CFG}include(if\.[^[:space:]]*)?\.path[[:space:]]+[^-;&|[:space:]]" && return 0
    # running git without HOME finds no global config, hence no hooksPath (review F1):
    # env -i / env - / --ignore-environment / -u HOME / --unset=HOME, or `unset HOME` first
    printf '%s' "$t" | grep -qE "${GP_SEP}env[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*i[A-Za-z]*|-|--ignore-environment|-[A-Za-z]*u[[:space:]]*HOME|--unset[=[:space:]]*HOME)[[:space:]]([^;&|]*[[:space:]])?${GP_GITCP}" && return 0
    printf '%s' "$t" | grep -qE "${GP_SEP}unset[[:space:]]+(-[a-z][[:space:]]+)*([^;&|]*[[:space:]])?HOME([[:space:]]|[;&|]|\$).*${GP_SEP}${GP_GITCP}" && return 0
    # redirecting the config that carries the global hooksPath, for a commit/push:
    # prefix assignment on the git command itself ...
    printf '%s' "$t" | grep -qE "${GP_SEP}${GP_ENVV}=[^[:space:]]*[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*${GP_GITCP}" && return 0
    # ... or a persistent one (export / bare assignment statement) before a later commit/push
    printf '%s' "$t" | grep -qE "${GP_SEP}(export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)?${GP_ENVV}=[^[:space:];&|]*[[:space:]]*(;|&&|\|\|).*${GP_SEP}${GP_GITCP}" && return 0
    return 1
}
guard_preserve_cmd_hit() {  # $1 = raw Bash command → 0 if it bypasses the guard
    local cmd="${1//$'\\\n'/ }"   # bash joins backslash-newline continuations: so do we
    [[ -n "$cmd" ]] || return 1
    local flat
    flat=$(printf '%s' "$cmd" | guard_flatten)
    guard_preserve_hit "$flat" && return 0
    # a pseudo-terminal wrapper (pty.spawn, unbuffer, expect, script, socat)
    # around `guard … bypass` — kit guard bypass refuses to run without a TTY
    local bare; bare="$(printf '%s' "$cmd" | tr '\n' ';' | tr -d "\"'\\\\")"
    if printf '%s' "$bare" | grep -qE 'guard[^A-Za-z0-9]{1,8}bypass' \
       && printf '%s' "$bare" | grep -qE '(pty|unbuffer|expect|script|socat|python|perl|ruby|node)'; then
        return 0
    fi
    # nested shell code (bash/sh -c, eval, xargs, script): strip ONE quoting level and
    # scan again, as the inner shell will see it; go one level deeper only while the
    # text still holds another nested shell (a commit message that merely mentions
    # --no-verify inside bash -c '…' stays data — review F7)
    local lvl="$cmd" k nest
    for k in 1 2 3; do
        nest=$(printf '%s' "$flat" | sed 's/[[:space:]]/  /g' | grep -oE "${GP_NEST}" | wc -l)
        [[ $nest -ge $k ]] || break
        lvl=$(printf '%s' "$lvl" | guard_unquote1)
        flat=$(printf '%s' "$lvl" | guard_flatten)
        guard_preserve_hit "$flat" && return 0
    done
    return 1
}
guard_preserve_deny() {
    jq -n --arg r 'kit guard-preserve: bypassing the commit/push guard is USER-only. If this is genuinely needed, ask the user to run: kit guard bypass "<reason>" (10-minute, single-use, audited). Do not retry with --no-verify, KIT_GUARD=, or core.hooksPath.' \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

INPUT=$(cat 2>/dev/null || echo '{}')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
# v5 activation gate: silent unless the project root carries kit.toml —
# except guard-preserve, which runs everywhere (R-guard-scope, see above)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if ! PROJ=$(kit_project_root); then
    if [[ "${KIT:-on}" != "off" && "$EVENT" == "PreToolUse" ]] \
       && [[ "$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" == "Bash" ]] \
       && guard_preserve_cmd_hit "$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"; then
        guard_preserve_deny
    fi
    exit 0
fi
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

LOG="/tmp/claude-kit-toollog-${SESSION_ID}.jsonl"
STATE="/tmp/claude-kit-lastcall-${SESSION_ID}"
TS=$(date +%H:%M:%S 2>/dev/null || echo "-")

log_event() {  # $1=e  $2=h  $3=n  [$4=k (kind, v4.10; omitted on legacy events)]
    jq -cn --arg ts "$TS" --arg e "$1" --arg t "$TOOL" --arg h "$2" --arg n "$3" --arg k "${4:-}" \
        '{ts:$ts, e:$e, t:$t, h:$h, n:($n|tonumber? // 0)} + (if $k == "" then {} else {k:$k} end)' \
        >>"$LOG" 2>/dev/null || true
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

# ---------------------------------------------------- verifier-pipe guard
# v4.10: a piped test runner reports the FILTER's exit code, not the test's;
# chaining git commit/push onto that green-looking pipe shipped unverified
# work 3x in one real session (local-b 2026-07; fleet receipt 2026-08-02,
# 10/13 projects hit lying-verification-pipelines). Runs AFTER state update
# and call logging (a guarded attempt still participates in the spiral
# chain) and BEFORE the generic N>=3 deny (the specific message must win).
# Four stages; stages 1-3 implement prefer-false-negatives. Anti-footgun,
# NOT anti-evasion: deliberate quote-splitting / cross-call splitting /
# bash -c nesting are out of scope — a Bash-holding model can already
# rewrite the gate baseline directly (v4.9 threat boundary; same criterion
# as the standing "no Bash command-parsing protection" decision).
PIPE_GUARD_RUNNER='(pytest|vitest|jest|go test|cargo test|npm (test|run test)|bash [^ ]*tests?/[^ ]*\.sh)'
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
if [[ "$TOOL" == "Bash" && -n "$CMD" ]] \
   && ! printf '%s' "$CMD" | grep -q '<<' \
   && ! printf '%s' "$CMD" | grep -qE '^[[:space:]]*(echo|printf)\b' \
   && ! printf '%s' "$CMD" | grep -q 'pipefail'; then
    # quote_neutralize: bounded state machine (plain/single/double/ansi-c,
    # backslash-aware) replaces each quoted span with placeholder Q —
    # replacement, not deletion, keeps word positions so stripped spans
    # cannot synthesize a phantom "&& git commit". Unterminated quotes
    # swallow the tail (false-negative direction, accepted).
    # POSIX-portable char walk: substr(), octal \047 — FS="" per-char
    # splitting and \x27 are gawk extensions and silently no-op the
    # neutralizer under POSIXLY_CORRECT (codex final-review finding
    # 2026-08-02: quoted data turned back into shell structure).
    CMD_FLAT=$(printf '%s' "$CMD" | tr '\n' ';' | awk '
        { out=""; st=0; len=length($0)
          for(i=1;i<=len;i++){ c=substr($0,i,1)
            if(st==0){
              if(c=="\\"){i++; out=out "C"; continue}
              if(c=="$" && substr($0,i+1,1)=="\047"){st=3; i++; out=out "Q"; continue}
              if(c=="\047"){st=1; out=out "Q"; continue}
              if(c=="\""){st=2; out=out "Q"; continue}
              out=out c; continue }
            if(st==1){ if(c=="\047") st=0; continue }
            if(st==2){ if(c=="\\"){i++; continue} if(c=="\"") st=0; continue }
            if(st==3){ if(c=="\\"){i++; continue} if(c=="\047") st=0; continue }
          }
          print out }' 2>/dev/null)
    if [[ -n "$CMD_FLAT" ]] && printf '%s' "$CMD_FLAT" | grep -qE "(^|[;&([:space:]])${PIPE_GUARD_RUNNER}[^|;&]*[^|]\|[^|].*(&&|;)[[:space:]]*git (commit|push)"; then
        log_event "deny" "$HASH" "$N" "pipe-guard"
        jq -n --arg r "verifier-pipe guard (kit tool-breaker): a piped test runner hides its exit code — the pipeline reports the FILTER's status, so the test can fail while the command looks green, and the chained git commit/push would ship unverified work. Fix either way: (1) run the test bare and commit only after it exits 0, or (2) prefix with 'set -o pipefail;' so the pipe propagates the test's exit code." \
          '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
        exit 0
    fi
fi

# guard-preserve (definitions + scope note above the activation gate)
if [[ "$TOOL" == "Bash" ]] && guard_preserve_cmd_hit "$CMD"; then
    log_event "deny" "$HASH" "$N" "guard-preserve"
    guard_preserve_deny
    exit 0
fi

if [[ "$N" -ge 3 ]]; then
    log_event "deny" "$HASH" "$N"
    jq -n --arg r "CIRCUIT BREAKER (kit tool-breaker): this is consecutive IDENTICAL call #${N} to ${TOOL} — same tool, exact same arguments, nothing else in between. Two identical attempts already failed to give you what you wanted; a third repetition will not either. Before ANY further tool call: (1) state in one sentence why the previous attempts did not satisfy you; (2) change something real — different arguments, a different tool, or escalate per kit-delegation.md (2 strikes on one subtask → hand it up WITH the error log). This exact call stays blocked until it differs." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
fi

exit 0
