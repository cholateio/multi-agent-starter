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
# once under prev/. A symlink is stored AS a symlink (its target), never followed.
# Files over 8 MiB and files beyond the first 2000 are NOT stored: they are listed in
# <store>/omitted and named in a WARNING (when the list changes, and on every
# `kit guard status`) — the store never claims to protect them (review R3-3).
# A stored file that is gone from the work tree while HEAD does not track it was
# deleted by the owner — or removed by a reset / stash / clean that runs no hook: it
# moves to <store>/trash/<path>.~<timestamp>~ and is never put back by a checkout
# (review N2). Trash keeps the last 5 generations per path (an identical copy is not
# stored twice), and every snapshot caller says so in one line (review R4-4).
# The store root is mode 700 (review R3-9).
#
#   localfiles.sh snapshot [--report]         kit migrate / kit guard status (--report) / session start
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
LF_TRASH_KEEP=5

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
# the store holds PROJECT.toml / LESSONS / plan copies: private (hard links share the
# work-tree inode, so only the directory can be locked down)
mkdir -p "$STATE/localfiles" 2>/dev/null && chmod 700 "$STATE/localfiles" 2>/dev/null

lf_tracked_in() {  # $1 commit → tracked local-only paths (one per line)
    [[ -n "$1" ]] || return 0
    git -c core.quotePath=false ls-tree -r --name-only "$1" -- "${LF_PATHS[@]}" 2>/dev/null
}
lf_here() { [[ -e "$1" || -L "$1" ]]; }
lf_same() {  # same inode (hard link), or two symlinks with the same target
    if [[ -L "$1" || -L "$2" ]]; then
        [[ -L "$1" && -L "$2" && "$(readlink "$1")" == "$(readlink "$2")" ]]
    else
        [[ -e "$1" && -e "$2" && "$1" -ef "$2" ]]
    fi
}
lf_differs() {  # content (or link target) differs
    if [[ -L "$1" || -L "$2" ]]; then ! lf_same "$1" "$2"; else ! cmp -s "$1" "$2"; fi
}
lf_link() {  # $1 src $2 dest: hard link (atomic replace), else copy; a symlink is copied as a symlink
    mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
    rm -f "$2.kit-tmp"
    if [[ -L "$1" ]]; then
        cp -P "$1" "$2.kit-tmp" 2>/dev/null || return 1
    else
        ln "$1" "$2.kit-tmp" 2>/dev/null || cp -p "$1" "$2.kit-tmp" 2>/dev/null || return 1
    fi
    mv -f "$2.kit-tmp" "$2"
}
lf_store_list() { find "$FILES" \( -type f -o -type l \) ! -name '*.kit-tmp' -print0 2>/dev/null; }
lf_when() { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c %y "$1" 2>/dev/null | cut -c1-16; }

snapshot() {
    local p n=0 size report="${1:-}"
    local -a omitted=()
    # untracked (index) local-only files in the work tree; never .claude/worktrees
    while IFS= read -r -d '' p; do
        [[ "$p" == .claude/worktrees/* ]] && continue
        [[ -L "$p" || -f "$p" ]] || continue
        n=$((n + 1))
        if [[ $n -gt $LF_MAX_FILES ]]; then omitted+=("$p (beyond the first $LF_MAX_FILES files)"); continue; fi
        if [[ ! -L "$p" ]]; then
            size=$(stat -c %s "$p" 2>/dev/null || echo 0)
            if [[ $size -gt $LF_MAX_BYTES ]]; then omitted+=("$p (over 8 MiB)"); continue; fi
        fi
        lf_same "$p" "$FILES/$p" && continue
        if lf_here "$FILES/$p" && lf_differs "$p" "$FILES/$p"; then
            mkdir -p "$(dirname "$STORE/prev/$p")" && rm -f "$STORE/prev/$p" && cp -P -p "$FILES/$p" "$STORE/prev/$p" 2>/dev/null
        fi
        lf_link "$p" "$FILES/$p"
    done < <(git -c core.quotePath=false ls-files -z --others -- "${LF_PATHS[@]}" 2>/dev/null)
    prune
    [[ -d "$FILES" ]] && printf '%s\n' "$TOP" > "$STORE/repo" 2>/dev/null
    # files the store does NOT protect: never silent (review R3-3)
    local list="" old=""
    [[ ${#omitted[@]} -gt 0 ]] && list="$(printf '%s\n' "${omitted[@]}")"
    [[ -f "$STORE/omitted" ]] && old="$(cat "$STORE/omitted" 2>/dev/null)"
    if [[ -n "$list" ]]; then
        mkdir -p "$STORE" 2>/dev/null && printf '%s\n' "$list" > "$STORE/omitted" 2>/dev/null
        if [[ "$list" != "$old" || "$report" == --report ]]; then
            echo "kit: WARNING — ${#omitted[@]} local-only file(s) are NOT protected against a checkout of a pre-migration commit (not in the snapshot store): $(printf '%s\n' "$list" | head -n 5 | paste -sd ';' -)$([[ ${#omitted[@]} -gt 5 ]] && echo " …") — back them up yourself (full list: $STORE/omitted)" >&2
        fi
    else
        rm -f "$STORE/omitted" 2>/dev/null
    fi
    return 0
}

# lf_trash_gens <path> → its trash generations, oldest first (names sort by timestamp)
lf_trash_gens() {
    local d b f
    d="$(dirname "$STORE/trash/$1")"; b="$(basename "$1")"
    [[ -d "$d" ]] || return 0
    for f in "$d/$b".~*~; do [[ -e "$f" || -L "$f" ]] && printf '%s\n' "$f"; done | sort
}
lf_trashed() { [[ -n "$(lf_trash_gens "$1")" ]]; }
# lf_to_trash <path>: move the store copy to a new trash generation (unless the newest one
# is identical), then drop all but the newest LF_TRASH_KEEP generations
lf_to_trash() {
    local p="$1" t last n
    mkdir -p "$(dirname "$STORE/trash/$p")" 2>/dev/null || return 1
    # a single-generation trash from an older kit (trash/<path> itself) becomes the oldest one
    if [[ -f "$STORE/trash/$p" || -L "$STORE/trash/$p" ]]; then
        mv -f "$STORE/trash/$p" "$STORE/trash/$p.~00000000T000000000000000~" 2>/dev/null
    fi
    last="$(lf_trash_gens "$p" | tail -n 1)"
    if [[ -n "$last" ]] && lf_same_content "$FILES/$p" "$last"; then
        rm -f "$FILES/$p"
    else
        t="$(date +%Y%m%dT%H%M%S%N 2>/dev/null)"; [[ "$t" =~ ^[0-9]{8}T[0-9]{15}$ ]] || t="$(date +%Y%m%dT%H%M%S)000000000"
        while [[ -e "$STORE/trash/$p.~$t~" || -L "$STORE/trash/$p.~$t~" ]]; do t="${t%?????????}$(printf '%09d' $(( 10#${t: -9} + 1 )))"; done
        mv -f "$FILES/$p" "$STORE/trash/$p.~$t~" 2>/dev/null || return 1
    fi
    n="$(lf_trash_gens "$p" | wc -l)"
    if [[ $n -gt $LF_TRASH_KEEP ]]; then
        lf_trash_gens "$p" | head -n $((n - LF_TRASH_KEEP)) | while IFS= read -r t; do rm -f "$t"; done
    fi
    return 0
}
lf_same_content() {  # two symlinks with one target, or two regular files with the same bytes
    if [[ -L "$1" || -L "$2" ]]; then lf_same "$1" "$2"; else cmp -s "$1" "$2"; fi
}

prune() {  # store entries gone from the work tree while HEAD does not track them → trash/
    [[ -d "$FILES" ]] || return 0
    local p now
    local -a moved=()
    now="$(lf_tracked_in HEAD)"
    while IFS= read -r -d '' p; do
        p="${p#"$FILES"/}"
        lf_here "$p" && continue
        printf '%s\n' "$now" | grep -qxF -- "$p" && continue
        lf_to_trash "$p" && moved+=("$p")
    done < <(lf_store_list)
    # one line from every snapshot caller (hooks, kit migrate, kit guard status, session start)
    [[ ${#moved[@]} -gt 0 ]] && echo "kit: ${#moved[@]} local-only file(s) gone from the work tree moved to $STORE/trash (${moved[*]:0:4}${moved[4]:+ …}; last $LF_TRASH_KEEP copies per file kept) — copy back what you still want; a checkout never restores them" >&2
    return 0
}

restore() {  # $1 = previous HEAD (may be empty)
    local prev="$1" p restored=() kept=() blob=() when=()
    [[ -n "$prev" && ! "$prev" =~ ^0+$ ]] || { snapshot; return 0; }
    local -A now=() before=()
    while IFS= read -r p; do now[$p]=1; done < <(lf_tracked_in HEAD)
    while IFS= read -r p; do before[$p]=1; done < <(lf_tracked_in "$prev")
    # 1) from the store
    if [[ -d "$FILES" ]]; then
        while IFS= read -r -d '' p; do
            p="${p#"$FILES"/}"
            if [[ -n "${now[$p]:-}" ]]; then
                lf_here "$p" && ! lf_same "$p" "$FILES/$p" && lf_differs "$p" "$FILES/$p" && kept+=("$p")
                continue
            fi
            if ! lf_here "$p" && [[ -n "${before[$p]:-}" ]]; then
                lf_link "$FILES/$p" "$p" && { restored+=("$p"); when+=("$p as of $(lf_when "$FILES/$p")"); }
            fi
        done < <(lf_store_list)
    fi
    # 2) no store copy: the previous HEAD's blob (e.g. the migration commit pulled into a
    # clone) — owner content only, never .claude/ (that would resurrect v4 kit files);
    # a tracked symlink (mode 120000) comes back as a symlink. Never from trash/: the
    # owner deleted those on purpose.
    local mode
    for p in "${!before[@]}"; do
        [[ -n "${now[$p]:-}" ]] && continue
        lf_here "$p" || lf_here "$FILES/$p" || lf_here "$STORE/trash/$p" || lf_trashed "$p" && continue
        [[ "$p" =~ $LF_BLOB_RE ]] || continue
        mkdir -p "$(dirname "$p")" 2>/dev/null
        mode="$(git ls-tree "$prev" -- "$p" 2>/dev/null | cut -d' ' -f1)"
        rm -f "$p.kit-tmp"
        if [[ "$mode" == 120000 ]]; then
            ln -s "$(git cat-file blob "$prev:$p" 2>/dev/null)" "$p.kit-tmp" 2>/dev/null && mv -f "$p.kit-tmp" "$p" && blob+=("$p")
        else
            git cat-file blob "$prev:$p" > "$p.kit-tmp" 2>/dev/null && mv -f "$p.kit-tmp" "$p" && blob+=("$p")
        fi
        rm -f "$p.kit-tmp"
    done
    snapshot
    if [[ ${#restored[@]} -gt 0 || ${#blob[@]} -gt 0 ]]; then
        local all=("${restored[@]}" "${blob[@]}")
        echo "kit: restored ${#all[@]} local-only file(s) this checkout removed (${all[*]:0:4}${all[4]:+ …}) — from $STORE${blob[0]:+ / the previous commit}" >&2
        # review N4: the store copy is as recent as the last in-place edit or snapshot — an
        # edit saved by rename (sed -i, atomic-save editors) after that time is not in it
        [[ ${#when[@]} -gt 0 ]] && echo "kit: store copies: $(printf '%s; ' "${when[@]:0:4}")(an edit saved by rename after that time is not in them — see $STORE/prev)" >&2
    fi
    if [[ ${#kept[@]} -gt 0 ]]; then
        echo "kit: ${#kept[@]} local-only file(s) now hold the version this commit tracks (${kept[*]:0:4}${kept[4]:+ …}); your own copies are kept in $FILES and come back when you return to a commit that does not track them" >&2
    fi
    return 0
}

trash_note() {  # `kit guard status`: what the owner deleted is still recoverable — say where
    [[ -d "$STORE/trash" ]] || return 0
    local p g=0
    local -A t=()
    while IFS= read -r -d '' p; do
        p="${p#"$STORE/trash"/}"; p="${p%.~*~}"; t[$p]=1; g=$((g + 1))
    done < <(find "$STORE/trash" \( -type f -o -type l \) -print0 2>/dev/null)
    local names=("${!t[@]}")
    [[ ${#names[@]} -gt 0 ]] && echo "kit: ${#names[@]} local-only file(s) gone from the work tree (deleted, or removed by a reset / stash / clean that runs no hook) are kept in $STORE/trash — $g timestamped cop$([[ $g -eq 1 ]] && echo y || echo ies), last $LF_TRASH_KEEP per file (${names[*]:0:4}${names[4]:+ …}) — copy back what you still want; a checkout never restores them" >&2
    return 0
}

case "$MODE" in
    snapshot) snapshot "${2:-}"; [[ "${2:-}" == --report ]] && trash_note ;;
    post-commit) snapshot ;;
    post-checkout) [[ "${4:-1}" == 1 ]] && restore "${2:-}" ;;
    post-merge|post-rewrite) restore "$(git rev-parse -q --verify ORIG_HEAD 2>/dev/null)" ;;
esac
exit 0
