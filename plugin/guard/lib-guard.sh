#!/usr/bin/env bash
# plugin/guard/lib-guard.sh — shared plumbing for pre-commit.sh / pre-push.sh (design §7).
# bash + git + jq (optional) only. Sources lib-privacy.sh.
#
#   guard_init <hook>          GUARD_DIR TOP REPO_ID CFG_DIR STATE_DIR PRIV_FILE HOOK
#   guard_r2_match <has_kit> <path> → prints the R2 group label if forbidden
#   guard_gitleaks_bin         → path to gitleaks or empty
#   guard_add <BLOCK|WARN> <rule tag> <where> <why>     collect a finding
#   guard_finish               print findings, consume a bypass / log, exit code
#
# Config dir: KIT_GUARD_CONFIG_DIR (exported by the shim from its own location,
# overriding anything inherited), else KIT_CONFIG_HOME, else ~/.config/kit.
# State dir:  KIT_STATE_HOME, else ~/.local/state/kit (audit.jsonl, bypass-<repo-id>).
# KIT_GUARD=off is deliberately NOT honoured (design §7.4): the only bypass is
# the user-only `kit guard bypass "<reason>"` (single-use, 10 minutes, audited).

GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-privacy.sh
source "$GUARD_DIR/lib-privacy.sh"

GUARD_EMPTY_TREE=""
guard_init() {
    HOOK="$1"
    TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
    local id_src="$TOP"
    [[ -n "$id_src" ]] || id_src="$(git rev-parse --absolute-git-dir 2>/dev/null)"
    REPO_ID="$(printf '%s' "$id_src" | sha1sum | cut -c1-12)"
    REPO_LABEL="${id_src:-unknown}"
    CFG_DIR="${KIT_GUARD_CONFIG_DIR:-${KIT_CONFIG_HOME:-${HOME:-/nonexistent}/.config/kit}}"
    STATE_DIR="${KIT_STATE_HOME:-${HOME:-/nonexistent}/.local/state/kit}"
    PRIV_FILE="$CFG_DIR/privacy.local.toml"
    GUARD_EMPTY_TREE="$(git hash-object -t tree /dev/null 2>/dev/null)"
    G_FIND=(); G_WARNED_PRIV=0
}

# R2 forbidden paths (design §7.2; same groups as kit audit A4). Without
# kit.toml only the .env* group applies (design: `.env*` 全 repo).
guard_r2_match() {  # $1 has_kit (0/1)  $2 repo-relative path
    local p="$2" base="${2##*/}"
    if [[ "$base" == .env* && "$base" != ".env.example" ]]; then echo ".env*"; return 0; fi
    [[ "$1" == 1 ]] || return 1
    case "$p" in
        .claude/*) echo ".claude/" ;;
        .superpowers/*) echo ".superpowers/" ;;
        docs/LESSONS.md) echo "docs/LESSONS.md" ;;
        docs/plans/*) echo "docs/plans/" ;;
        docs/superpowers/plans/*) echo "docs/superpowers/plans/" ;;
        docs/decisions/*) echo "docs/decisions/" ;;
        *)
            case "$base" in
                PROJECT.toml) echo "PROJECT.toml" ;;
                CLAUDE.local.md) echo "CLAUDE.local.md" ;;
                *.local.toml) echo "*.local.toml" ;;
                *) return 1 ;;
            esac ;;
    esac
}

guard_gitleaks_bin() {
    local g
    g="$(command -v gitleaks 2>/dev/null)" && { echo "$g"; return 0; }
    [[ -x "${HOME:-/nonexistent}/.local/bin/gitleaks" ]] && { echo "$HOME/.local/bin/gitleaks"; return 0; }
    return 1
}

# guard_run_gitleaks <mode-args...>: runs gitleaks with the kit config, adds R1
# findings. Return 0 = scanned, 2 = missing / crashed (caller applies R8).
guard_run_gitleaks() {
    local gl rep rc
    gl="$(guard_gitleaks_bin)" || { GL_STATUS="gitleaks not in PATH"; return 2; }
    rep="$(mktemp "${TMPDIR:-/tmp}/kit-guard-gl.XXXXXX")"
    "$gl" "$@" --config "$GUARD_DIR/gitleaks.toml" --no-banner --redact --log-level error \
        --exit-code 7 --report-format json --report-path "$rep" >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then rm -f "$rep"; return 0; fi
    if [[ $rc -ne 7 ]]; then rm -f "$rep"; GL_STATUS="gitleaks failed (exit $rc)"; return 2; fi
    local file line rule commit n=0
    if command -v jq >/dev/null 2>&1; then
        while IFS=$'\x1f' read -r file line rule commit; do
            n=$((n + 1))
            local where="$file:$line"; [[ -n "$commit" ]] && where+=" @${commit:0:7}"
            guard_add BLOCK "R1 secret" "$where" "gitleaks rule $rule (value redacted)"
        done < <(jq -r '.[] | [.File, (.StartLine|tostring), .RuleID, (.Commit // "")] | join("\u001f")' "$rep" 2>/dev/null)
    fi
    [[ $n -gt 0 ]] || guard_add BLOCK "R1 secret" "(see gitleaks)" "gitleaks reported a secret (report unreadable)"
    rm -f "$rep"
    return 0
}

guard_add() { G_FIND+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"); }

guard_add_scan() {  # stdin: privacy_scan_* output lines
    local act tag where why
    while IFS=$'\t' read -r act tag where why; do
        [[ -n "$act" ]] && guard_add "$act" "$tag" "$where" "$why"
    done
}

_guard_json_str() {  # minimal JSON string escaping without jq
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
    printf '"%s"' "$s"
}
guard_audit() {  # <rule> <path> <action> [reason]
    local d="$STATE_DIR/guard"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        printf '{"ts":%s,"repo":%s,"hook":%s,"rule":%s,"path":%s,"action":%s' \
            "$(_guard_json_str "$ts")" "$(_guard_json_str "$REPO_LABEL")" "$(_guard_json_str "$HOOK")" \
            "$(_guard_json_str "$1")" "$(_guard_json_str "$2")" "$(_guard_json_str "$3")"
        [[ -n "${4:-}" ]] && printf ',"reason":%s' "$(_guard_json_str "$4")"
        printf '}\n'
    } >> "$d/audit.jsonl" 2>/dev/null
}

# bypass (design §7.4): ~/.local/state/kit/guard/bypass-<repo-id> = {"expires": epoch, "reason": "..."}
# consumed by the first BLOCKED run of either hook; expired files are removed.
guard_bypass_consume() {
    local f="$STATE_DIR/guard/bypass-$REPO_ID" exp reason now
    [[ -f "$f" ]] || return 1
    exp="$(sed -nE 's/.*"expires"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$f" | head -n 1)"
    if command -v jq >/dev/null 2>&1; then reason="$(jq -r '.reason // ""' "$f" 2>/dev/null)"
    else reason="$(sed -nE 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$f" | head -n 1)"; fi
    now="$(date +%s)"
    rm -f "$f"
    if [[ -z "$exp" || "$exp" -le "$now" ]]; then
        echo "KIT GUARD: expired bypass for this repo removed (bypasses last 10 minutes)" >&2
        return 1
    fi
    BYPASS_REASON="$reason"
    return 0
}

guard_fix_line() {  # $1 rule id → one fix line
    case "$1" in
        R1) echo "fix: remove the secret (rotate it if it ever left this machine); false positive → 'gitleaks:allow' on the line or a .gitleaksignore entry" ;;
        R2) echo "fix: keep it local — git rm --cached <path> (the kit .gitignore block lists these paths)" ;;
        R3|R4|R5) echo "fix: remove the value (use \$HOME / env vars / a placeholder); deliberate → 'kit-privacy: allow' on the line, or kit.toml [privacy] allow_paths / allow_literals (by NAME)" ;;
        R8) echo "fix: kit doctor --install   (pinned, sha256-verified gitleaks)" ;;
    esac
}

# guard_finish: print findings (capped), apply bypass, log, exit status
GUARD_SHOW_MAX=40
guard_finish() {
    local f act tag where why nb=0 shown=0 total=${#G_FIND[@]}
    local -A rules=()
    for f in "${G_FIND[@]}"; do
        IFS=$'\x1f' read -r act tag where why <<< "$f"
        [[ "$act" == BLOCK ]] && { nb=$((nb + 1)); rules[${tag%% *}]=1; }
    done
    for f in "${G_FIND[@]}"; do
        IFS=$'\x1f' read -r act tag where why <<< "$f"
        if [[ $shown -ge $GUARD_SHOW_MAX ]]; then
            echo "KIT GUARD: … and $((total - shown)) more finding(s)" >&2; break
        fi
        shown=$((shown + 1))
        if [[ "$act" == BLOCK ]]; then echo "KIT GUARD BLOCKED [$tag] $where — $why" >&2
        else echo "KIT GUARD WARN [$tag] $where — $why" >&2; fi
    done
    [[ $nb -eq 0 ]] && return 0
    if guard_bypass_consume; then
        echo "KIT GUARD: bypass consumed — ${BYPASS_REASON} ($nb block(s) let through, logged)" >&2
        for f in "${G_FIND[@]}"; do
            IFS=$'\x1f' read -r act tag where why <<< "$f"
            [[ "$act" == BLOCK ]] && guard_audit "${tag%% *}" "$where" "bypass" "$BYPASS_REASON"
        done
        return 0
    fi
    local r
    for r in R1 R2 R3 R4 R5 R8; do [[ -n "${rules[$r]:-}" ]] && guard_fix_line "$r" >&2; done
    echo "bypass (user only): kit guard bypass \"<reason>\"   (run it yourself in a terminal; single-use, 10 min, audited)" >&2
    local n=0
    for f in "${G_FIND[@]}"; do
        IFS=$'\x1f' read -r act tag where why <<< "$f"
        [[ "$act" == BLOCK ]] || continue
        n=$((n + 1)); [[ $n -le 200 ]] && guard_audit "${tag%% *}" "$where" "block"
    done
    return 1
}

# guard_load_privacy: privacy.local.toml → PRIV_* (missing → warn once, R4/R5 off)
guard_load_privacy() {
    if ! privacy_load_local "$PRIV_FILE"; then
        echo "KIT GUARD WARN: $PRIV_FILE missing — personal literals (R4/R5) not checked; R3 knows only the OS user — run: kit setup" >&2
    fi
}

# added-line stream from a unified diff (-U0, a/ b/ prefixes) on stdin →
# path<TAB>lineno<TAB>tag<TAB>content. Commit markers "\x01C <sha>" set the tag.
guard_diff_stream() {
    awk '
        /^\001C / { tag = substr($0, 4, 7); inh = 0; next }
        /^diff --git / { inh = 0; path = ""; next }
        !inh && /^\+\+\+ / { p = substr($0, 5); if (p == "/dev/null") path = ""; else {
                              if (p ~ /^"/) { p = substr(p, 2, length(p) - 2) } sub(/^b\//, "", p); path = p }; next }
        /^@@/ { inh = 1; s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); split(s, a, /[ ,]/); ln = a[1] + 0; next }
        inh && /^\+/ { if (path != "") print path "\t" ln "\t" tag "\t" substr($0, 2); ln++; next }
        inh && /^[ ]/ { ln++; next }'
}
