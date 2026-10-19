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
# A stored file that is gone from the work tree while HEAD does not track it:
#   - a git operation since the last snapshot went through a commit that tracks it
#     (checkout, rebase, pull, merge, cherry-pick, a hook-less reset — the operations
#     recorded in HEAD's reflog after the snapshot's mark, plus the hook's own previous
#     HEAD / rebased range) → git removed it: it comes back from the store (owner content
#     wins over the old tracked version git wrote on the way; v5.0.1)
#   - otherwise the owner deleted it (or a stash / clean that runs no hook): it moves to
#     <store>/trash/<path>.~<timestamp>~ and is never put back by a checkout (review N2).
# Trash keeps the last 5 generations per path (an identical copy is not stored twice), and
# every snapshot caller says so in one line (review R4-4).
# The store root is mode 700 (review R3-9).
#
#   localfiles.sh snapshot [--report]         kit migrate / kit guard status (--report) / session start
#   localfiles.sh post-commit                 (snapshot)
#   localfiles.sh pre-rebase …                (snapshot: the newest owner edits, before git touches the tree)
#   localfiles.sh post-checkout <prev> <new> <flag>
#   localfiles.sh post-merge [squash]         (prev = ORIG_HEAD)
#   localfiles.sh post-rewrite rebase         (prev = ORIG_HEAD, + the rebased range ORIG_HEAD..HEAD)
#   localfiles.sh post-rewrite amend          (snapshot: an amend never touches the work tree)
# While a rebase (or git am) is in progress every mode but post-rewrite does nothing: git
# runs post-checkout / post-commit for each step, and a snapshot there would see the
# intermediate tree (the rebase's post-rewrite, or the next snapshot point, settles it).
#
# On a checkout / merge / rewrite: a local-only path that the previous HEAD (or a
# commit the operation went through, see above) tracked, the new HEAD does not, and
# that is missing from the work tree comes back from the store (else from the previous
# HEAD's blob, e.g. after pulling the migration commit into another clone). A path the new HEAD tracks is left as git
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
# lf_busy: a rebase (or git am) is in progress. Only these: git runs post-merge with
# MERGE_HEAD and a cherry-pick's post-commit with CHERRY_PICK_HEAD still present, and each
# of those steps is a real commit state — the reflog rule below handles them.
lf_busy() {
    local p
    while IFS= read -r p; do [[ -n "$p" && -e "$p" ]] && return 0; done < <(git rev-parse \
        --git-path rebase-merge --git-path rebase-apply 2>/dev/null)
    return 1
}
# The snapshot mark (<store>/mark): when the last snapshot ran (epoch) and the newest line of
# HEAD's reflog at that time. Every reflog entry after it is a git operation since then.
lf_reflog() { git rev-parse --git-path logs/HEAD 2>/dev/null; }
lf_mark() {
    local log; log="$(lf_reflog)"
    { date +%s; [[ -n "$log" && -f "$log" ]] && tail -n 1 "$log"; } > "$STORE/mark.kit-tmp" 2>/dev/null \
        && mv -f "$STORE/mark.kit-tmp" "$STORE/mark" 2>/dev/null
}
# lf_touched: the commits a git operation since the last snapshot went through — LF_EXTRA
# (the hook's previous HEAD / rebased range) + both sides of every HEAD reflog entry after the
# mark (when the mark's line is gone — reflog expired — every entry since its time). A plain
# commit / amend entry changes no work tree and is skipped. No mark (older kit): LF_EXTRA only.
lf_touched() {
    [[ ${#LF_EXTRA[@]} -gt 0 ]] && printf '%s\n' "${LF_EXTRA[@]}"
    local log t="" line=""
    log="$(lf_reflog)"
    [[ -f "$STORE/mark" && -n "$log" && -f "$log" ]] || return 0
    { IFS= read -r t; IFS= read -r line; } < "$STORE/mark"
    [[ "$t" =~ ^[0-9]+$ ]] || return 0
    awk -v L="$line" -v T="$t" '
        { all[NR] = $0; if (L != "" && $0 == L) at = NR }
        END {
            for (i = (at ? at + 1 : 1); i <= NR; i++) {
                tab = index(all[i], "\t"); head = tab ? substr(all[i], 1, tab - 1) : all[i]; msg = tab ? substr(all[i], tab + 1) : ""
                n = split(head, f, " "); if (n < 4) continue
                if (!at && f[n - 1] + 0 < T) continue
                if (msg ~ /^commit( \((amend|initial)\))?: /) continue
                print f[1]; print f[2]
            }
        }' "$log" 2>/dev/null
}
# lf_git_removed <path>…: the given paths that some commit in lf_touched tracks
lf_git_removed() {
    local -a cs=()
    mapfile -t cs < <(lf_touched | awk '/^[0-9a-f]+$/ && $0 !~ /^0+$/ && !seen[$0]++' | head -n 500)
    [[ ${#cs[@]} -gt 0 && $# -gt 0 ]] || return 0
    local p c
    for p in "$@"; do for c in "${cs[@]}"; do printf '%s\t%s:%s\n' "$p" "$c" "$p"; done; done > "$STORE/touched.kit-tmp" 2>/dev/null || return 0
    cut -f2- "$STORE/touched.kit-tmp" | GIT_NO_LAZY_FETCH=1 git cat-file --batch-check='%(objecttype)' 2>/dev/null \
        | paste "$STORE/touched.kit-tmp" - | awk -F'\t' '$NF == "blob" && !seen[$1]++ { print $1 }'
    rm -f "$STORE/touched.kit-tmp"
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
    [[ -d "$FILES" ]] && { printf '%s\n' "$TOP" > "$STORE/repo" 2>/dev/null; lf_mark; }
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

prune() {  # store entries gone from the work tree while HEAD does not track them:
           # removed by a git operation → back from the store; else (owner) → trash/
    [[ -d "$FILES" ]] || return 0
    local p now
    local -a gone=() moved=() back=() when=()
    local -A bygit=()
    now="$(lf_tracked_in HEAD)"
    while IFS= read -r -d '' p; do
        p="${p#"$FILES"/}"
        lf_here "$p" && continue
        printf '%s\n' "$now" | grep -qxF -- "$p" && continue
        gone+=("$p")
    done < <(lf_store_list)
    [[ ${#gone[@]} -gt 0 ]] || return 0
    while IFS= read -r p; do [[ -n "$p" ]] && bygit[$p]=1; done < <(lf_git_removed "${gone[@]}")
    for p in "${gone[@]}"; do
        if [[ -n "${bygit[$p]:-}" ]]; then
            lf_link "$FILES/$p" "$p" && { back+=("$p"); when+=("$p as of $(lf_when "$FILES/$p")"); }
        else
            lf_to_trash "$p" && moved+=("$p")
        fi
    done
    if [[ ${#back[@]} -gt 0 ]]; then
        echo "kit: restored ${#back[@]} local-only file(s) a git operation removed (${back[*]:0:4}${back[4]:+ …}) — from $STORE" >&2
        # review N4: the store copy is as recent as the last in-place edit or snapshot — an
        # edit saved by rename (sed -i, atomic-save editors) after that time is not in it
        echo "kit: store copies: $(printf '%s; ' "${when[@]:0:4}")(an edit saved by rename after that time is not in them — see $STORE/prev)" >&2
    fi
    # one line from every snapshot caller (hooks, kit migrate, kit guard status, session start)
    [[ ${#moved[@]} -gt 0 ]] && echo "kit: ${#moved[@]} local-only file(s) gone from the work tree moved to $STORE/trash (${moved[*]:0:4}${moved[4]:+ …}; last $LF_TRASH_KEEP copies per file kept) — copy back what you still want; a checkout never restores them" >&2
    return 0
}

restore() {  # $1 = previous HEAD (may be empty), $2… = more commits the operation went through
    local prev="$1" p kept=() blob=(); shift
    LF_EXTRA=("$@")
    [[ -n "$prev" && ! "$prev" =~ ^0+$ ]] || { snapshot; return 0; }
    LF_EXTRA+=("$prev")
    local -A now=() before=()
    while IFS= read -r p; do now[$p]=1; done < <(lf_tracked_in HEAD)
    while IFS= read -r p; do before[$p]=1; done < <(lf_tracked_in "$prev")
    # 1) store copies of paths the new HEAD tracks wait (the owner is looking at that commit);
    # the ones git removed come back from the store in snapshot → prune
    if [[ -d "$FILES" ]]; then
        while IFS= read -r -d '' p; do
            p="${p#"$FILES"/}"
            [[ -n "${now[$p]:-}" ]] || continue
            lf_here "$p" && ! lf_same "$p" "$FILES/$p" && lf_differs "$p" "$FILES/$p" && kept+=("$p")
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
    if [[ ${#blob[@]} -gt 0 ]]; then
        echo "kit: restored ${#blob[@]} local-only file(s) this checkout removed (${blob[*]:0:4}${blob[4]:+ …}) — from the previous commit (no store copy)" >&2
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

LF_EXTRA=()
# mid-rebase: the tree is intermediate — wait for the rebase's own end (post-rewrite; after
# an abort or a hook-less finish, the next snapshot point via the reflog)
if [[ "$MODE" != post-rewrite ]] && lf_busy; then
    [[ "${2:-}" == --report ]] && echo "kit: a rebase is in progress — local-only snapshot deferred until it finishes" >&2
    exit 0
fi
case "$MODE" in
    snapshot) snapshot "${2:-}"; [[ "${2:-}" == --report ]] && trash_note ;;
    post-commit|pre-rebase) snapshot ;;
    post-checkout) [[ "${4:-1}" == 1 ]] && restore "${2:-}" ;;
    post-merge) restore "$(git rev-parse -q --verify ORIG_HEAD 2>/dev/null)" ;;
    post-rewrite)
        if [[ "${2:-}" == rebase ]]; then
            # the commits the rebase checked out: its base and every replayed commit
            # (ORIG_HEAD..HEAD with the boundary; capped) — also without a reflog
            O="$(git rev-parse -q --verify ORIG_HEAD 2>/dev/null)"
            mapfile -t RANGE < <([[ -n "$O" ]] && git rev-list --boundary "$O..HEAD" 2>/dev/null | sed 's/^-//' | head -n 200)
            restore "$O" "${RANGE[@]}"
        else
            snapshot
        fi ;;
esac
exit 0
