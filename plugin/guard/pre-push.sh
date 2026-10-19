#!/usr/bin/env bash
# plugin/guard/pre-push.sh — kit v5 local guard, push side: the leak boundary (design §7.2).
# Run by the global git-hooks shim for EVERY repo. args: <remote> <url>;
# stdin: <lref> <lsha> <rref> <rsha> per ref.
#
#   R2 forbidden paths in the WHOLE pushed tree (catches long-tracked files) and
#      in every commit of the pushed range (a path added then deleted still
#      reaches the remote's history)                                   block
#   R1 + R3–R7 on the added lines of EVERY commit in the range (merge
#      resolutions via remerge diff), on commit / annotated-tag messages, on
#      file names added in the range and on the pushed ref names        block/warn
#   R8 gitleaks missing / crashed                                      block
#
# Range = <lsha> minus what the push URL ACTUALLY has: `git ls-remote <url>`
# (objects present locally) plus the old remote value. Remote-tracking refs are
# never trusted (final review C1): after `remote set-url`, with an extra pushurl
# (mirror) or for a URL that is not a named remote they describe a different
# repository. ls-remote gets a 5 s try and a 15 s retry (v5.0.1 review V1); when both fail,
# an existing ref is still bounded by its old value (^rsha) and a NEW ref (zero rsha) has no
# bound: its whole history is scanned (never weaker) but any block findings there — most
# likely history the remote has had for years — are folded into ONE BLOCK
# [R0 remote-unreachable] (user bypass) naming the causes, never a list of old R2/R3 lines.
# Deleting a remote ref is never blocked.
# A non-zero old value (rsha) that is NOT here — the remote moved on since the last fetch —
# is one BLOCK [R0 fetch-first], no scan of that ref, no bypass (v5.0.1): the range would
# otherwise be the whole history and re-report everything the remote has had for years.
# Its hint is an exact command: git fetch <the remote, or the push URL when that is not the
# remote's fetch URL> <the remote ref> (a --single-branch clone / narrowed refspec would not
# fetch that ref with a plain git fetch).
# kit.toml (visibility, allow_*) is read from the pushed tree — what the remote gets.
# A tip WITHOUT kit.toml whose remote old tip / range boundary / range history had one
# is still a kit push, and the removal is a BLOCK (user bypass only). A tip without
# kit.toml is also a kit push when any local branch tip or any advertised remote
# HEAD / branch / tag already present locally has kit.toml (review R3-2: orphan branches,
# unrelated history). Only then the network (review R4-3): the pushed ref's old remote tip
# when it is not here, and the remote HEAD while nothing says "kit" — shallow, blob-less,
# into a throwaway repo. An old tip that cannot be fetched (offline, the hook's own
# connection cannot authenticate) fails closed (BLOCK, user bypass only — R4-2); a new
# ref whose remote cannot be listed uses the local signals only.
# Every git call pins its output format explicitly (--no-color, prefixes, --root,
# --text, --format …): the caller's config cannot blind the scan (final review C2).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-guard.sh"
guard_init pre-push
REMOTE="${1:-}"; URL="${2:-${1:-}}"
T_START=$(date +%s)
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard-pp.XXXXXX")" || { echo "KIT GUARD BLOCKED [R0 guard-error] mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT
guard_load_privacy

# what the remote has: every advertised object that exists locally
REMOTE_HAS_OK=0
: > "$TMPD/remote-has"
# short, non-interactive (review F8): no credential / passphrase prompt (ssh BatchMode,
# appended to the user's own ssh command); a 5 s try, then one 15 s retry for a slow link
# (v5.0.1 review V1)
LS_TIMEOUT="${KIT_GUARD_LS_REMOTE_TIMEOUT:-5}"
LS_RETRY_TIMEOUT="${KIT_GUARD_LS_REMOTE_RETRY_TIMEOUT:-15}"
pp_ls_remote() {  # <seconds> → $TMPD/ls-remote; the status of git ls-remote
    local to="$1" sc TO=() SSHC=()
    command -v timeout >/dev/null 2>&1 && TO=(timeout -k 2 "$to")
    if [[ -z "${GIT_SSH:-}" ]]; then
        sc="${GIT_SSH_COMMAND:-$(git config --get core.sshCommand 2>/dev/null)}"
        SSHC=(GIT_SSH_COMMAND="${sc:-ssh} -o BatchMode=yes -o ConnectTimeout=$to")
    fi
    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false ${SSHC[@]+"${SSHC[@]}"} \
        ${TO[@]+"${TO[@]}"} git ls-remote "$URL" > "$TMPD/ls-remote" 2>/dev/null </dev/null
}
if [[ -n "$URL" ]] && { pp_ls_remote "$LS_TIMEOUT" || pp_ls_remote "$LS_RETRY_TIMEOUT"; }; then
    REMOTE_HAS_OK=1
    cut -f1 "$TMPD/ls-remote" | sort -u | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
        | awk '$2 != "missing" { print "^" $1 }' > "$TMPD/remote-has"
fi
[[ $REMOTE_HAS_OK -eq 1 ]] || echo "KIT GUARD: could not list the refs at the push URL (${LS_TIMEOUT}s, then ${LS_RETRY_TIMEOUT}s) — offline, a slow link, or a password / passphrase prompt the hook cannot show; an existing branch is checked from its old remote value, a new one over its whole history" >&2

# the exact command that fetches the remote's <ref>, for the fetch-first hint (review V2 /
# Codex): the remote name only when its fetch URL IS the push URL (else the push URL itself,
# any password stripped), always with the ref (a single-branch / narrowed refspec skips it)
pp_shq() { if [[ "$1" =~ ^[A-Za-z0-9_@%+=:,./~^-]+$ ]]; then printf '%s' "$1"; else printf "'%s'" "${1//\'/\'\\\'\'}"; fi; }
FETCH_FROM="$URL"
if [[ -n "$REMOTE" && "$REMOTE" != "$URL" ]] && git config --get "remote.$REMOTE.url" >/dev/null 2>&1 \
   && [[ "$(git remote get-url "$REMOTE" 2>/dev/null)" == "$URL" ]]; then
    FETCH_FROM="$REMOTE"
fi
FETCH_FROM="$(printf '%s' "$FETCH_FROM" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)([^/@:]*):[^/@]*@#\1\2@#')"

# pushed refs: bounded ones first, unbounded new ones (zero rsha while the remote could not be
# listed) last — a finding they share is then reported as itself by the bounded scan, not
# folded into R0 remote-unreachable (v5.0.1 review V1)
REFS=(); LATE=()
while IFS= read -r line || [[ -n "$line" ]]; do
    read -r _ _ _ rs _ <<< "$line"
    if [[ $REMOTE_HAS_OK -eq 0 && ( -z "${rs:-}" || "$rs" =~ ^0+$ ) ]]; then LATE+=("$line"); else REFS+=("$line"); fi
done
REFS+=(${LATE[@]+"${LATE[@]}"})

LOGFMT=(-c core.quotePath=false log --root --no-color --no-ext-diff --no-textconv --no-relative --no-show-signature)
scanned=0 gl_missing=0 n=0
for line in ${REFS[@]+"${REFS[@]}"}; do
    read -r lref lsha rref rsha _ <<< "$line"
    [[ -n "${lref:-}" && -n "${lsha:-}" ]] || continue
    [[ "$lsha" =~ ^0+$ ]] && continue                                # ref deletion
    if ! c="$(git rev-parse --verify -q "${lsha}^{commit}")"; then
        guard_add BLOCK "R0 guard-error" "$lref" "pushed object is not a commit — the guard cannot scan it"
        continue
    fi
    # the remote's current tip of this ref is not here (v5.0.1): someone — or a scheduled
    # workflow — pushed since the last fetch. Without it nothing marks the already-published
    # history as "the remote has it", the range would fall back to the whole history and
    # re-report every old finding. Block with the real reason instead — never scan less and
    # let it through: not even a user bypass lets this push go out unscanned.
    if [[ -n "${rsha:-}" && ! "$rsha" =~ ^0+$ ]] && ! GIT_NO_LAZY_FETCH=1 git cat-file -e "${rsha}^{commit}" 2>/dev/null; then
        G_NOBYPASS=1
        guard_add BLOCK "R0 fetch-first" "${rref#refs/heads/}" "the remote's ${rref#refs/heads/} is at ${rsha:0:12}, a commit this clone does not have (pushed since your last fetch — by someone else or a workflow), so the guard cannot tell what this push adds: fetch exactly that tip: git fetch $(pp_shq "${FETCH_FROM:-<remote>}") $(pp_shq "$rref") — then rebase or merge onto it (git rebase FETCH_HEAD) and push again; for an intended overwrite (force push) run the same fetch first, so the guard can compute the range"
        continue
    fi
    scanned=1; n=$((n + 1)); D="$TMPD/r$n"; mkdir -p "$D"; G0=${#G_FIND[@]}
    { printf '%s\n' "$c"; cat "$TMPD/remote-has"
      if [[ -n "${rsha:-}" && ! "$rsha" =~ ^0+$ ]]; then printf '^%s\n' "$rsha"; fi
    } > "$D/revs"

    HAS_KIT=0; KT=""; REMOVED=0
    if KT="$(git show "$c:kit.toml" 2>/dev/null)"; then HAS_KIT=1
    else
        # the tip has no kit.toml: is this still a kit push? (review O5, R3-2, R4-2, R4-3)
        RSHA_GONE=0
        [[ -n "${rsha:-}" && ! "$rsha" =~ ^0+$ ]] && ! guard_inspectable "$rsha" && RSHA_GONE=1
        if KT="$(guard_kit_toml_before "$D/revs" "${rsha:-}")"; then REMOVED=1
        else
            # 1) local evidence, no network: local branch tips, advertised objects already here
            if KT="$(guard_kit_toml_elsewhere "$( [[ $REMOTE_HAS_OK -eq 1 ]] && echo "$TMPD/ls-remote")")"; then HAS_KIT=1; fi
            # 2) then fetch only what is needed (shallow, throwaway repo): the remote's old tip of
            #    THIS ref when it is not here — it may hold a kit.toml this push removes — and the
            #    remote HEAD while nothing says "kit" yet. Never the whole advertised namespace.
            HSHA=""
            if [[ $HAS_KIT -eq 0 && $REMOTE_HAS_OK -eq 1 ]]; then
                HSHA="$(awk -F'\t' '$2 == "HEAD" { print $1; exit }' "$TMPD/ls-remote")"
                [[ -n "$HSHA" ]] && guard_inspectable "$HSHA" && HSHA=""
            fi
            if [[ $RSHA_GONE -eq 1 || -n "$HSHA" ]]; then
                SPECS=()
                [[ $RSHA_GONE -eq 1 ]] && SPECS+=("+${rref}:refs/kit-probe/old")
                [[ -n "$HSHA" ]] && SPECS+=("+HEAD:refs/kit-probe/head")
                guard_probe "$URL" "${SPECS[@]}"
                if [[ $RSHA_GONE -eq 1 ]]; then
                    PRC=2; [[ "$(guard_probe_rev refs/kit-probe/old)" == "$rsha" ]] && { K2="$(guard_probe_kit_toml "$rsha")"; PRC=$?; }
                    if [[ $PRC -eq 0 ]]; then KT="$K2"; REMOVED=1
                    elif [[ $PRC -eq 2 ]]; then
                        # R4-2: an old tip that cannot be inspected — whatever the reason (offline,
                        # the hook's own connection cannot authenticate) — fails closed
                        HAS_KIT=1
                        guard_add BLOCK "R2 kit-status-unknown" "$lref" "the pushed tip has no kit.toml and the remote's current ${rref} (${rsha:0:12}) is not here and could not be fetched to check whether it has one — git fetch the remote and push again; if intended, the user runs kit guard bypass"
                    fi
                fi
                if [[ -n "$HSHA" && $HAS_KIT -eq 0 && $REMOVED -eq 0 ]]; then
                    H2="$(guard_probe_rev refs/kit-probe/head)"; PRC=2
                    [[ -n "$H2" ]] && { K2="$(guard_probe_kit_toml "$H2")"; PRC=$?; }
                    if [[ $PRC -eq 0 ]]; then KT="$K2"; HAS_KIT=1
                    elif [[ $PRC -eq 2 ]]; then
                        HAS_KIT=1; KT=""      # fail closed: R2 applies, and the push needs the user
                        guard_add BLOCK "R2 kit-status-unknown" "$lref" "the pushed tip has no kit.toml and the remote's HEAD could not be fetched to check whether this is a kit repo — git fetch the remote and push again; if intended, the user runs kit guard bypass"
                    fi
                fi
            fi
            [[ $HAS_KIT -eq 0 && $REMOVED -eq 0 && -n "$TOP" && -f "$TOP/kit.toml" ]] && { HAS_KIT=1; KT=""; }
        fi
        if [[ $REMOVED -eq 1 ]]; then
            # the remote's old tip or the pushed history had kit.toml and the tip drops it:
            # still a kit repo, and the removal itself needs the user's bypass (review O5)
            HAS_KIT=1
            guard_add BLOCK "R2 kit.toml-removed" "kit.toml" "the pushed tip drops kit.toml that the remote / the pushed history had — that would switch the local-only path rule (R2) off; if intended, the user runs kit guard bypass"
        fi
    fi
    VIS="$(printf '%s\n' "$KT" | privacy_kt_visibility)"
    ALLOW_LITS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_literals)"
    ALLOW_PATHS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_paths)"

    # R2: whole pushed tree, then every path added inside the range
    while IFS= read -r -d '' p; do
        g="$(guard_r2_match "$HAS_KIT" "$p" "$ALLOW_PATHS" tree)" && guard_add BLOCK "R2 forbidden-path" "$p" "tracked in the pushed tree — $g is local-only (design §7.2)"
    done < <(git -c core.quotePath=false ls-tree -r -z --name-only --full-tree "$c" 2>/dev/null)
    : > "$D/names"
    while IFS= read -r -d '' p; do
        p="${p#$'\n'}"; [[ -n "$p" ]] || continue
        printf '%s\n' "$p" >> "$D/names"
        if g="$(guard_r2_match "$HAS_KIT" "$p" "$ALLOW_PATHS" range)"; then
            guard_add BLOCK "R2 forbidden-path" "$p" "added inside the pushed range (history keeps it) — $g is local-only"
        elif [[ "$(guard_env_class "${p##*/}")" == warn ]]; then
            guard_add WARN "R2 env-file" "$p" "direnv file pushed — make sure it exports no secrets"
        fi
    done < <(git "${LOGFMT[@]}" -z --format= --name-only --no-renames --diff-filter=ACMRT --stdin < "$D/revs" 2>/dev/null)

    # R1 + R3–R7 over one stream: added lines (merges: remerge diff), messages, names, ref name
    if GIT_ATTR_SOURCE="$GUARD_EMPTY_TREE" git "${LOGFMT[@]}" -p -U0 -M --text --src-prefix=a/ --dst-prefix=b/ \
            --format=$'\x01C %H' --diff-merges=remerge --stdin < "$D/revs" > "$D/log" 2>"$D/err" \
       || GIT_ATTR_SOURCE="$GUARD_EMPTY_TREE" git "${LOGFMT[@]}" -p -U0 -M --text --src-prefix=a/ --dst-prefix=b/ \
            --format=$'\x01C %H' --diff-merges=first-parent --stdin < "$D/revs" > "$D/log" 2>"$D/err"; then
        {
            guard_diff_stream < "$D/log"
            git "${LOGFMT[@]}" --format=$'\x01C %H%n%B' --no-patch --stdin < "$D/revs" 2>/dev/null \
                | tr '\000' '\002' | awk '/^\001C / { tag = substr($0, 4); n = 0; next } { print "(commit message)\t" (++n) "\t" tag "\t" $0 }'
            guard_text_lines "(file name)" "" < "$D/names"
            printf '%s\n' "${rref:-}" | guard_text_lines "(ref name)" ""
            if [[ "$(git cat-file -t "$lsha" 2>/dev/null)" == tag ]]; then
                git cat-file tag "$lsha" 2>/dev/null | awk 'b { print; next } /^$/ { b = 1 }' | guard_text_lines "(tag message)" ""
            fi
        } > "$D/stream"
        git show "$c:.gitleaksignore" > "$D/gitleaksignore" 2>/dev/null || : > "$D/gitleaksignore"
        guard_scan "$D/stream" push "$VIS" "$ALLOW_LITS" "$ALLOW_PATHS" "$D/gitleaksignore" || gl_missing=1
    else
        guard_add BLOCK "R0 guard-error" "$lref" "could not read the pushed range: $(head -c 200 "$D/err")"
    fi
    # a new ref whose remote could not be listed: nothing bounds its history, so the block
    # findings above are most likely what the remote has had for years — fold them into one
    # block that says so (v5.0.1 review V1); warnings and allow-marker audits stay as they are
    if [[ $REMOTE_HAS_OK -eq 0 && ( -z "${rsha:-}" || "$rsha" =~ ^0+$ ) ]]; then
        KEEP=(); NB=0; unset NR; declare -A NR=()
        for ((i = G0; i < ${#G_FIND[@]}; i++)); do
            IFS=$'\x1f' read -r act tag _ <<< "${G_FIND[i]}"
            if [[ "$act" == BLOCK ]]; then NB=$((NB + 1)); NR[$tag]=$(( ${NR[$tag]:-0} + 1 )); else KEEP+=("${G_FIND[i]}"); fi
        done
        if [[ $NB -gt 0 ]]; then
            G_FIND=("${G_FIND[@]:0:G0}" ${KEEP[@]+"${KEEP[@]}"})
            SUM=""; for tag in "${!NR[@]}"; do SUM+="${SUM:+, }$tag ×${NR[$tag]}"; done
            guard_add BLOCK "R0 remote-unreachable" "${rref#refs/heads/}" "a new ref, and the push URL could not be listed (${LS_TIMEOUT}s, then ${LS_RETRY_TIMEOUT}s), so nothing tells which of its history the remote already has; scanning ALL of it found: $SUM — most likely history the remote has had all along. Causes: offline or a slow link; an SSH key with a passphrase and no ssh-agent (the hook runs ssh in BatchMode and cannot prompt); a credential prompt. Fix: ssh-add (or reconnect) and push again — the guard then scans only what is new; if you are sure, the user bypasses it"
        fi
    fi
done

if [[ $scanned -eq 1 && $gl_missing -eq 1 ]]; then
    guard_add BLOCK "R8 gitleaks-missing" "(push)" "gitleaks required for push (${GL_STATUS:-gitleaks not found}) — secrets cannot be scanned at the leak boundary"
fi
T_SPENT=$(( $(date +%s) - T_START ))
[[ $T_SPENT -gt 10 ]] && echo "KIT GUARD: slow push scan (${T_SPENT}s)" >&2
guard_finish
exit $?
