#!/usr/bin/env bash
# plugin/guard/localfiles.sh — keep a kit repo's local-only files safe across
# checkouts of commits that still TRACK them (review F3).
#
# After `kit migrate`, PROJECT.toml, docs/LESSONS.md, the plan dirs and .claude/
# are untracked + ignored, but every pre-migration commit still tracks them.
# `git checkout <old>` silently OVERWRITES ignored files with the tracked version
# and `git checkout <new>` then DELETES them (tracked before, not after) — the
# owner's current content is gone. Git has no pre-checkout hook, so this keeps a
# store that survives the overwrite:
#
#   <state>/localfiles/<repo-id>/files/<path>   (<state> = KIT_STATE_HOME or ~/.local/state/kit,
#                                                repo-id = the guard's: sha1(toplevel)[:12])
#
# Each untracked local-only file is HARD-LINKED into the store (a copy when the
# store is on another filesystem). Git replaces a file by unlink + create, so the
# store keeps the content — including edits made after the last snapshot, as long
# as the edit was in place (an editor that saves by rename breaks the link; the
# next snapshot re-links). The previous store version of a changed file is kept
# once under prev/.
#
#   localfiles.sh snapshot                    kit migrate / kit guard status / session start
#   localfiles.sh post-commit                 (snapshot)
#   localfiles.sh post-checkout <prev> <new> <flag>
#   localfiles.sh post-merge [squash]         (prev = ORIG_HEAD)
#   localfiles.sh post-rewrite [amend|rebase] (prev = ORIG_HEAD)
#
# On a checkout / merge / rewrite: a local-only path that the previous HEAD
# tracked, the new HEAD does not, and that is missing from the work tree comes
# back from the store (else from the previous HEAD's blob, e.g. after pulling the
# migration commit into another clone). A path the new HEAD tracks is left as git
# wrote it (the owner is looking at that commit) — the store copy waits.
# Active only in kit repos (kit.toml in the work tree / HEAD) or repos that
# already have a store. Never fails the git command: always exits 0.

set -uo pipefail
MODE="${1:-snapshot}"
LF_PATHS=(.claude PROJECT.toml CLAUDE.local.md docs/LESSONS.md docs/plans docs/superpowers/plans docs/decisions)
LF_BLOB_RE='^(PROJECT\.toml|CLAUDE\.local\.md|docs/LESSONS\.md|docs/plans/.+|docs/superpowers/plans/.+|docs/decisions/.+)$'
LF_MAX_BYTES=$((8 * 1024 * 1024))
LF_MAX_FILES=2000

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$TOP" ]] || exit 0
cd "$TOP" || exit 0
STATE="${KIT_STATE_HOME:-${HOME:-/nonexistent}/.local/state/kit}"
RID="$(printf '%s' "$TOP" | sha1sum | cut -c1-12)"
STORE="$STATE/localfiles/$RID"
FILES="$STORE/files"

if [[ ! -d "$FILES" && ! -f "$TOP/kit.toml" ]] && ! git cat-file -e HEAD:kit.toml 2>/dev/null; then
    exit 0
fi

lf_tracked_in() {  # $1 commit → tracked local-only paths (one per line)
    [[ -n "$1" ]] || return 0
    git -c core.quotePath=false ls-tree -r --name-only "$1" -- "${LF_PATHS[@]}" 2>/dev/null
}
lf_same() { [[ -e "$1" && -e "$2" && "$1" -ef "$2" ]]; }
lf_link() {  # $1 src $2 dest: hard link (atomic replace), else copy
    mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
    rm -f "$2.kit-tmp"
    ln "$1" "$2.kit-tmp" 2>/dev/null || cp -p "$1" "$2.kit-tmp" 2>/dev/null || return 1
    mv -f "$2.kit-tmp" "$2"
}

snapshot() {
    local p n=0 size
    # untracked (index) local-only files in the work tree; never .claude/worktrees
    while IFS= read -r -d '' p; do
        [[ "$p" == .claude/worktrees/* ]] && continue
        [[ -f "$p" && ! -L "$p" ]] || continue
        n=$((n + 1)); [[ $n -le $LF_MAX_FILES ]] || break
        size=$(stat -c %s "$p" 2>/dev/null || echo 0)
        [[ $size -le $LF_MAX_BYTES ]] || continue
        lf_same "$p" "$FILES/$p" && continue
        if [[ -f "$FILES/$p" ]] && ! cmp -s "$p" "$FILES/$p"; then
            mkdir -p "$(dirname "$STORE/prev/$p")" && cp -p "$FILES/$p" "$STORE/prev/$p" 2>/dev/null
        fi
        lf_link "$p" "$FILES/$p"
    done < <(git -c core.quotePath=false ls-files -z --others -- "${LF_PATHS[@]}" 2>/dev/null)
    [[ -d "$FILES" ]] && printf '%s\n' "$TOP" > "$STORE/repo" 2>/dev/null
    return 0
}

restore() {  # $1 = previous HEAD (may be empty)
    local prev="$1" p restored=() kept=() blob=()
    [[ -n "$prev" && ! "$prev" =~ ^0+$ ]] || { snapshot; return 0; }
    local -A now=() before=()
    while IFS= read -r p; do now[$p]=1; done < <(lf_tracked_in HEAD)
    while IFS= read -r p; do before[$p]=1; done < <(lf_tracked_in "$prev")
    # 1) from the store
    if [[ -d "$FILES" ]]; then
        while IFS= read -r -d '' p; do
            p="${p#"$FILES"/}"
            if [[ -n "${now[$p]:-}" ]]; then
                [[ -e "$p" ]] && ! lf_same "$p" "$FILES/$p" && ! cmp -s "$p" "$FILES/$p" && kept+=("$p")
                continue
            fi
            if [[ ! -e "$p" && -n "${before[$p]:-}" ]]; then
                lf_link "$FILES/$p" "$p" && restored+=("$p")
            fi
        done < <(find "$FILES" -type f ! -name '*.kit-tmp' -print0 2>/dev/null)
    fi
    # 2) no store copy: the previous HEAD's blob (e.g. the migration commit pulled into a
    # clone) — owner content only, never .claude/ (that would resurrect v4 kit files)
    for p in "${!before[@]}"; do
        [[ -n "${now[$p]:-}" || -e "$p" || -e "$FILES/$p" ]] && continue
        [[ "$p" =~ $LF_BLOB_RE ]] || continue
        mkdir -p "$(dirname "$p")" 2>/dev/null
        git cat-file blob "$prev:$p" > "$p.kit-tmp" 2>/dev/null && mv -f "$p.kit-tmp" "$p" && blob+=("$p")
        rm -f "$p.kit-tmp"
    done
    snapshot
    if [[ ${#restored[@]} -gt 0 || ${#blob[@]} -gt 0 ]]; then
        local all=("${restored[@]}" "${blob[@]}")
        echo "kit: restored ${#all[@]} local-only file(s) this checkout removed (${all[*]:0:4}${all[4]:+ …}) — from $STORE${blob[0]:+ / the previous commit}" >&2
    fi
    if [[ ${#kept[@]} -gt 0 ]]; then
        echo "kit: ${#kept[@]} local-only file(s) now hold the version this commit tracks (${kept[*]:0:4}${kept[4]:+ …}); your own copies are kept in $FILES and come back when you return to a commit that does not track them" >&2
    fi
    return 0
}

missing_note() {  # snapshot callers that a person reads: name store files missing from the work tree
    [[ -d "$FILES" ]] || return 0
    local p miss=() now
    now="$(lf_tracked_in HEAD)"
    while IFS= read -r -d '' p; do
        p="${p#"$FILES"/}"
        [[ -e "$p" ]] && continue
        printf '%s\n' "$now" | grep -qxF -- "$p" && continue
        miss+=("$p")
    done < <(find "$FILES" -type f ! -name '*.kit-tmp' -print0 2>/dev/null)
    [[ ${#miss[@]} -gt 0 ]] && echo "kit: ${#miss[@]} local-only file(s) are missing from the work tree but kept in $FILES (${miss[*]:0:4}${miss[4]:+ …}) — copy back what you still want" >&2
    return 0
}

case "$MODE" in
    snapshot) snapshot; [[ "${2:-}" == --report ]] && missing_note ;;
    post-commit) snapshot ;;
    post-checkout) [[ "${4:-1}" == 1 ]] && restore "${2:-}" ;;
    post-merge|post-rewrite) restore "$(git rev-parse -q --verify ORIG_HEAD 2>/dev/null)" ;;
esac
exit 0
