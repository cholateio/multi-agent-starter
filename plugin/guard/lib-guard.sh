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
    # caller env that could reshape what the guard reads (final review C2):
    # git's own output is pinned by explicit flags on every git call below
    unset GIT_DIFF_OPTS GIT_EXTERNAL_DIFF GREP_OPTIONS GREP_COLOR GREP_COLORS
}

# guard_env_class <basename> → "block" | "warn" | "" (review F4). `.env` and
# `.env.<name>` hold real values (.env.test / .env.development included — they
# often do); a template whose LAST suffix is example/sample/template/dist/defaults
# is fine (.env.local.example too); direnv's `.envrc` is a warning (it may export
# secrets, but is routinely tracked). Mirrors the kit .gitignore block, CI, audit A4.
guard_env_class() {
    case "$1" in
        .envrc) echo warn ;;
        .env) echo block ;;
        .env.*) case "${1##*.}" in example|sample|template|dist|defaults) ;; *) echo block ;; esac ;;
    esac
}

# R2 forbidden paths (design §7.2; same groups as kit audit A4). Without
# kit.toml only the .env* group applies, and only to paths being committed /
# added in the pushed range — not tree-wide (a non-kit fork tracking .env.test
# is not re-blocked on every push; review F4). kit.toml [privacy] allow_paths
# exempts an .env file.
guard_r2_match() {  # $1 has_kit (0/1)  $2 repo-relative path  [$3 allow_paths csv]  [$4 tree|range]
    local p="$2" base="${2##*/}" g
    if [[ "$(guard_env_class "$base")" == block ]]; then
        [[ "${4:-range}" == tree && "$1" != 1 ]] && return 1
        local -a ap=(); IFS=',' read -ra ap <<< "${3:-}"
        for g in "${ap[@]}"; do [[ -n "$g" && "$p" == $g ]] && return 1; done
        echo ".env*"; return 0
    fi
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

# guard_kit_toml_before <revs-file> <rsha>: print the kit.toml the remote's old tip,
# a boundary commit of the pushed range, or any commit inside the range carried;
# return 1 when none did (the repo never was a kit repo on this path).
guard_kit_toml_before() {
    local revs="$1" rsha="${2:-}" b cand
    if [[ -n "$rsha" && ! "$rsha" =~ ^0+$ ]] && git cat-file -e "${rsha}^{commit}" 2>/dev/null \
       && git show "$rsha:kit.toml" 2>/dev/null; then return 0; fi
    while IFS= read -r b; do
        git show "$b:kit.toml" 2>/dev/null && return 0
    done < <(git rev-list --boundary --stdin < "$revs" 2>/dev/null | sed -n 's/^-//p' | head -n 50)
    while IFS= read -r cand; do
        git show "$cand:kit.toml" 2>/dev/null && return 0
        git show "$cand^:kit.toml" 2>/dev/null && return 0
    done < <(git log --format=%H --no-renames --stdin -- kit.toml < "$revs" 2>/dev/null | head -n 50)
    return 1
}

guard_gitleaks_bin() {  # the pinned install (kit doctor --install) wins over PATH (final review I4)
    local g
    [[ -x "${HOME:-/nonexistent}/.local/bin/gitleaks" ]] && { echo "$HOME/.local/bin/gitleaks"; return 0; }
    g="$(command -v gitleaks 2>/dev/null)" && { echo "$g"; return 0; }
    return 1
}

# guard_gitleaks_stream <stream-file> <gitleaksignore-file|"">
# R1 over the guard's OWN hardened added-line stream via `gitleaks stdin`
# (final review C2/I1/M1): no second `git diff` / `git log` that the caller's
# config (color.ui=always, log.showRoot=false, …) or attributes (-diff in
# .git/info/attributes / core.attributesFile) could blind; merge resolutions
# included. Each hit maps back to path:line[@commit] through the stream.
# .gitleaksignore: only the COMMITTED one counts (index / pushed tree), matched
# as `path:rule:line` or `commit:path:rule:line` — an untracked file is ignored.
# Return 0 = scanned, 2 = gitleaks missing / crashed (caller applies R8).
guard_gitleaks_stream() {
    local stream="$1" ign="${2:-}" gl rc td
    gl="$(guard_gitleaks_bin)" || { GL_STATUS="gitleaks not in PATH"; return 2; }
    td="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard-gl.XXXXXX")" || { GL_STATUS="mktemp failed"; return 2; }
    mkdir -p "$td/noignore"
    awk -v M="$td/meta" -v C="$td/content" '{
        p1 = index($0, "\t"); r1 = substr($0, p1 + 1); p2 = index(r1, "\t"); r2 = substr(r1, p2 + 1); p3 = index(r2, "\t")
        if (!p1 || !p2 || !p3) next
        print substr($0, 1, p1 - 1) "\t" substr(r1, 1, p2 - 1) "\t" substr(r2, 1, p3 - 1) > M
        print substr(r2, p3 + 1) > C }' "$stream"
    : >> "$td/content"; : >> "$td/meta"
    "$gl" stdin --config "$GUARD_DIR/gitleaks.toml" --gitleaks-ignore-path "$td/noignore" --no-banner --redact \
        --log-level error --exit-code 7 --report-format json --report-path "$td/rep" < "$td/content" >/dev/null 2>&1
    rc=$?
    if [[ $rc -ne 0 && $rc -ne 7 ]]; then rm -rf "$td"; GL_STATUS="gitleaks failed (exit $rc)"; return 2; fi
    if [[ $rc -eq 7 ]]; then
        local n=0 line rule path lno tag where
        if command -v jq >/dev/null 2>&1; then
            while IFS=$'\x1f' read -r line rule; do
                IFS=$'\t' read -r path lno tag <<< "$(sed -n "${line}p" "$td/meta")"
                n=$((n + 1))
                if [[ -n "$ign" && -s "$ign" ]] && grep -qxF -e "$path:$rule:$lno" -e "$tag:$path:$rule:$lno" "$ign" 2>/dev/null; then
                    continue
                fi
                where="$path:$lno"; [[ -n "$tag" ]] && where+=" @${tag:0:7}"
                guard_add BLOCK "R1 secret" "$where" "gitleaks rule $rule (value redacted)"
            done < <(jq -r '.[] | [(.StartLine|tostring), .RuleID] | join("\u001f")' "$td/rep" 2>/dev/null)
        fi
        [[ $n -gt 0 ]] || guard_add BLOCK "R1 secret" "(see gitleaks)" "gitleaks reported a secret (report unreadable)"
    fi
    rm -rf "$td"
    return 0
}

declare -A G_SEEN=()
guard_add() {  # dedupes: a push of several refs scans shared commits more than once
    local k="$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"
    [[ -n "${G_SEEN[$k]:-}" ]] && return 0
    G_SEEN[$k]=1; G_FIND+=("$k")
}

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
    local f="$STATE_DIR/guard/bypass-$REPO_ID" exp reason now armed
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
    # final review I4: only `kit guard bypass` arms a bypass — it never sets an
    # expiry beyond 10 minutes and always logs a matching bypass-armed entry
    armed="$(tail -n 500 "$STATE_DIR/guard/audit.jsonl" 2>/dev/null | grep -F '"action":"bypass-armed"' \
             | grep -F "\"repo\":$(_guard_json_str "$REPO_LABEL")" | grep -F "\"expires\":$exp" | tail -n 1)"
    if [[ "$exp" -gt $((now + 610)) || -z "$armed" ]]; then
        echo "KIT GUARD: bypass file rejected — not armed by 'kit guard bypass' (no matching audit entry or expiry beyond 10 min)" >&2
        guard_audit "bypass" "" "bypass-rejected" "$reason"
        return 1
    fi
    BYPASS_REASON="$reason"
    return 0
}

guard_fix_line() {  # $1 rule id → one fix line
    case "$1" in
        R1) echo "fix: remove the secret (rotate it if it ever left this machine); false positive → 'gitleaks:allow' on the line or a .gitleaksignore entry" ;;
        R2) echo "fix: keep it local — git rm --cached <path> (the kit .gitignore block lists these paths)" ;;
        R3|R4|R5) echo "fix: remove the value (use \$HOME / env vars / a placeholder); deliberate → kit.toml [privacy] allow_paths / allow_literals (by NAME) — 'kit-privacy: allow' covers warn-level rules only" ;;
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
    local hidden=0
    for f in "${G_FIND[@]}"; do
        IFS=$'\x1f' read -r act tag where why <<< "$f"
        # "(+N more line(s))" summaries of the per-rule cap are always shown
        if [[ $shown -ge $GUARD_SHOW_MAX && "$where" != "(+"* ]]; then hidden=$((hidden + 1)); continue; fi
        shown=$((shown + 1))
        if [[ "$act" == BLOCK ]]; then echo "KIT GUARD BLOCKED [$tag] $where — $why" >&2
        else echo "KIT GUARD WARN [$tag] $where — $why" >&2; fi
    done
    [[ $hidden -gt 0 ]] && echo "KIT GUARD: … and $hidden more finding(s)" >&2
    # consumed inline allow markers are never silent (review O9): one audit line each
    local nm=0
    for f in "${G_FIND[@]}"; do
        IFS=$'\x1f' read -r act tag where why <<< "$f"
        [[ "$tag" == *" allow-marker" ]] || continue
        nm=$((nm + 1)); [[ $nm -le 200 ]] && guard_audit "${tag%% *}" "$where" "allow-marker"
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

# added-line stream from a unified diff (-U0, -a, a/ b/ prefixes) on stdin →
# path<TAB>lineno<TAB>tag<TAB>content. Commit markers "\x01C <sha>" set the tag
# (full sha). The diff is produced with --text so attributes cannot hide a file;
# a file section whose lines carry a NUL byte is binary and dropped (design:
# binaries skip the content rules) — NULs are mapped to \002 first so every awk
# sees them. git appends a TAB to "+++ b/<path>" when the path has a space.
guard_diff_stream() {
    tr '\000' '\002' | awk '
        function flush() { if (!bin) for (i = 1; i <= nb; i++) print buf[i]; nb = 0; bin = 0 }
        /^\001C / { flush(); tag = substr($0, 4); inh = 0; next }
        /^diff --git / { flush(); inh = 0; path = ""; next }
        !inh && /^\+\+\+ / { p = substr($0, 5); sub(/\t$/, "", p)
                              if (p == "/dev/null") path = ""; else {
                              if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2); sub(/^b\//, "", p); path = p }; next }
        /^@@/ { inh = 1; s = $0; sub(/^@@@* -[0-9,]+ (-[0-9,]+ )*\+/, "", s); split(s, a, /[ ,]/); ln = a[1] + 0; next }
        inh && /^\+/ { if (path != "" && !bin) { if (index($0, "\002")) { bin = 1; nb = 0 } else buf[++nb] = path "\t" ln "\t" tag "\t" substr($0, 2) }; ln++; next }
        inh && /^-/ { if (index($0, "\002")) { bin = 1; nb = 0 }; next }
        inh && /^[ ]/ { ln++; next }
        END { flush() }'
}

# guard_text_lines <pseudo-path> <tag>: stdin text → stream lines (messages, names)
guard_text_lines() {
    tr '\000' '\002' | awk -v P="$1" -v T="$2" '{ print P "\t" NR "\t" T "\t" $0 }'
}

# guard_scan <stream-file> <mode> <vis> <allow_lits> <allow_paths> <gitleaksignore-file|"">
# privacy rules + R1 over one stream; return 2 when gitleaks is missing / crashed
guard_scan() {
    privacy_scan_stream "$2" "$3" "$4" "$5" < "$1" > "$1.scan"
    guard_add_scan < "$1.scan"
    guard_gitleaks_stream "$1" "${6:-}"
}
