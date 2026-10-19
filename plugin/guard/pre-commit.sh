#!/usr/bin/env bash
# plugin/guard/pre-commit.sh — kit v5 local guard, commit side (design §7.2).
# Run by the global git-hooks shim for EVERY repo on the machine.
#
#   R1 gitleaks on the staged diff                       block (missing/crashed → R8 warn)
#   R2 forbidden paths staged as A/C/M/R/T               block (no kit.toml: .env* only)
#   R3–R7 privacy rules on the ADDED lines of the staged diff (lib-privacy.sh)
#
# Deletions always pass (`git rm --cached PROJECT.toml` is the fix, not a leak).
# kit.toml is read from the index (what is being committed), else HEAD (a commit that
# drops it is still a kit commit, with a warning), else the work tree, else any local
# branch tip (an orphan / unborn branch of a kit repo is still a kit repo; review R3-2).
# Binary files (NUL bytes) skip the content rules; no .gitattributes (in-tree,
# .git/info, core.attributesFile) can mark text as binary to hide it (--text).
# R1 runs gitleaks over the same hardened stream (lib-guard guard_scan).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-guard.sh"
guard_init pre-commit

HAS_KIT=0; KT=""
if KT="$(git show :kit.toml 2>/dev/null)"; then HAS_KIT=1
elif KT="$(git show HEAD:kit.toml 2>/dev/null)"; then
    # this commit drops kit.toml: it is still a kit repo for THIS commit (review O5)
    HAS_KIT=1
    guard_add WARN "R2 kit.toml-removed" "kit.toml" "this commit removes kit.toml — R2 still applies here, and the push will be BLOCKED unless the user runs kit guard bypass"
elif [[ -n "$TOP" && -f "$TOP/kit.toml" ]]; then KT="$(cat "$TOP/kit.toml")"; HAS_KIT=1
elif KT="$(guard_kit_toml_elsewhere)"; then HAS_KIT=1   # unborn / orphan branch of a kit repo (review R3-2)
fi
VIS=""; ALLOW_LITS=""; ALLOW_PATHS=""
if [[ $HAS_KIT -eq 1 ]]; then
    VIS="$(printf '%s\n' "$KT" | privacy_kt_visibility)"
    ALLOW_LITS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_literals)"
    ALLOW_PATHS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_paths)"
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard-pc.XXXXXX")" || { echo "KIT GUARD BLOCKED [R0 guard-error] mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

# --- R2: staged paths (renames split into add+delete so the new name is seen)
: > "$TMPD/names"
while IFS= read -r -d '' p; do
    printf '%s\n' "$p" >> "$TMPD/names"
    if g="$(guard_r2_match "$HAS_KIT" "$p" "$ALLOW_PATHS")"; then
        guard_add BLOCK "R2 forbidden-path" "$p" "never pushed: $g is local-only (design §7.2)"
    elif [[ "$(guard_env_class "${p##*/}")" == warn ]]; then
        guard_add WARN "R2 env-file" "$p" "direnv file tracked — fine for non-secret exports; secrets belong in an ignored .env / .envrc.local"
    fi
done < <(git -c core.quotePath=false diff --cached --name-only --no-renames --diff-filter=ACMRT -z --no-relative 2>/dev/null)

# --- R1 + R3–R7: the added lines of the staged diff, plus the staged file NAMES.
# Every output-shaping option is explicit, so the caller's config (-c / global:
# color, noprefix, relative, external diff, textconv) cannot reshape the diff;
# --text so attributes (in-tree, .git/info, core.attributesFile) cannot hide text.
guard_load_privacy
if GIT_ATTR_SOURCE="$GUARD_EMPTY_TREE" git -c core.quotePath=false diff --cached -U0 -M --text --no-color \
        --no-ext-diff --no-textconv --no-relative --src-prefix=a/ --dst-prefix=b/ > "$TMPD/diff" 2>"$TMPD/err"; then
    { guard_diff_stream < "$TMPD/diff"; guard_text_lines "(file name)" "" < "$TMPD/names"; } > "$TMPD/stream"
    git show :.gitleaksignore > "$TMPD/gitleaksignore" 2>/dev/null || : > "$TMPD/gitleaksignore"
    if ! guard_scan "$TMPD/stream" commit "$VIS" "$ALLOW_LITS" "$ALLOW_PATHS" "$TMPD/gitleaksignore"; then
        guard_add WARN "R8 gitleaks-missing" "(all files)" "${GL_STATUS} — secrets (R1) NOT scanned; push will be blocked until it is installed — run: kit doctor --install"
    fi
else
    guard_add BLOCK "R0 guard-error" "(staged diff)" "could not read the staged diff: $(head -c 200 "$TMPD/err")"
fi

guard_finish
exit $?
