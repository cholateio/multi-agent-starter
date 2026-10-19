#!/usr/bin/env bash
# plugin/guard/pre-push.sh — kit v5 local guard, push side: the leak boundary (design §7.2).
# Run by the global git-hooks shim for EVERY repo. stdin: <lref> <lsha> <rref> <rsha> per ref.
#
#   R2 forbidden paths in the WHOLE pushed tree (catches long-tracked files) and
#      in every commit of the pushed range (a path added then deleted still
#      reaches the remote's history)                                   block
#   R3–R7 privacy rules on the added lines of EVERY commit in the range,
#      merge resolutions included (remerge diff)                         block/warn
#   R1 gitleaks over the range; missing / crashed gitleaks → R8 block
#
# Range = <lsha> minus what THIS remote already has (its remote-tracking refs and
# the old remote value when known locally). Commits that only exist on another
# remote are scanned again: a private remote having them says nothing about
# this one. Deleting a remote ref is never blocked.
# kit.toml (visibility, allow_*) is read from the pushed tree — what the remote gets.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-guard.sh"
guard_init pre-push
REMOTE="${1:-}"
SRC="${TOP:-$(git rev-parse --absolute-git-dir 2>/dev/null)}"
T_START=$(date +%s)
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard-pp.XXXXXX")"; trap 'rm -rf "$TMPD"' EXIT
guard_load_privacy

scanned=0 gl_ok=1
GLBIN="$(guard_gitleaks_bin)" || gl_ok=0
while read -r lref lsha rref rsha; do
    [[ -n "${lref:-}" && -n "${lsha:-}" ]] || continue
    [[ "$lsha" =~ ^0+$ ]] && continue                                # ref deletion
    if ! c="$(git rev-parse --verify -q "${lsha}^{commit}")"; then
        guard_add BLOCK "R0 guard-error" "$lref" "pushed object is not a commit — the guard cannot scan it"
        continue
    fi
    scanned=1
    excl=(--not)
    [[ -n "$REMOTE" ]] && excl+=("--remotes=$REMOTE")
    if [[ -n "${rsha:-}" && ! "$rsha" =~ ^0+$ ]] && git cat-file -e "${rsha}^{commit}" 2>/dev/null; then excl+=("$rsha"); fi

    HAS_KIT=0; KT=""
    if KT="$(git show "$c:kit.toml" 2>/dev/null)"; then HAS_KIT=1
    elif [[ -n "$TOP" && -f "$TOP/kit.toml" ]]; then HAS_KIT=1; KT=""; fi
    VIS="$(printf '%s\n' "$KT" | privacy_kt_visibility)"
    ALLOW_LITS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_literals)"
    ALLOW_PATHS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_paths)"

    # R2: whole pushed tree, then every path added inside the range
    while IFS= read -r -d '' p; do
        g="$(guard_r2_match "$HAS_KIT" "$p")" && guard_add BLOCK "R2 forbidden-path" "$p" "tracked in the pushed tree — $g is local-only (design §7.2)"
    done < <(git -c core.quotePath=false ls-tree -r -z --name-only "$c" 2>/dev/null)
    while IFS= read -r -d '' p; do
        [[ -n "$p" ]] || continue
        p="${p#$'\n'}"
        g="$(guard_r2_match "$HAS_KIT" "$p")" && guard_add BLOCK "R2 forbidden-path" "$p" "added inside the pushed range (history keeps it) — $g is local-only"
    done < <(git -c core.quotePath=false log -z --format= --name-only --no-renames --diff-filter=ACMRT "$c" "${excl[@]}" 2>/dev/null)

    # R3–R7: added lines of every commit in the range (merges: remerge diff)
    logargs=(-c core.quotePath=false log -p -U0 -M --no-color --no-ext-diff --no-textconv
             --src-prefix=a/ --dst-prefix=b/ --format=$'\x01C %H')
    if GIT_ATTR_SOURCE="$GUARD_EMPTY_TREE" git "${logargs[@]}" --diff-merges=remerge "$c" "${excl[@]}" > "$TMPD/log" 2>"$TMPD/err" \
       || GIT_ATTR_SOURCE="$GUARD_EMPTY_TREE" git "${logargs[@]}" --diff-merges=first-parent "$c" "${excl[@]}" > "$TMPD/log" 2>"$TMPD/err"; then
        guard_diff_stream < "$TMPD/log" | privacy_scan_stream push "$VIS" "$ALLOW_LITS" "$ALLOW_PATHS" > "$TMPD/scan"
        guard_add_scan < "$TMPD/scan"
    else
        guard_add BLOCK "R0 guard-error" "$lref" "could not read the pushed range: $(head -c 200 "$TMPD/err")"
    fi

    # R1
    if [[ $gl_ok -eq 1 ]] && ! guard_run_gitleaks git --log-opts="$c ${excl[*]}" "$SRC"; then gl_ok=0; fi
done

if [[ $scanned -eq 1 && $gl_ok -eq 0 ]]; then
    guard_add BLOCK "R8 gitleaks-missing" "(push)" "gitleaks required for push (${GL_STATUS:-gitleaks not in PATH}) — secrets cannot be scanned at the leak boundary"
fi
T_SPENT=$(( $(date +%s) - T_START ))
[[ $T_SPENT -gt 10 ]] && echo "KIT GUARD: slow push scan (${T_SPENT}s)" >&2
guard_finish
exit $?
