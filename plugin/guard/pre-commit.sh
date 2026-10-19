#!/usr/bin/env bash
# plugin/guard/pre-commit.sh — kit v5 local guard, commit side (design §7.2).
# Run by the global git-hooks shim for EVERY repo on the machine.
#
#   R1 gitleaks on the staged diff                       block (missing/crashed → R8 warn)
#   R2 forbidden paths staged as A/C/M/R/T               block (no kit.toml: .env* only)
#   R3–R7 privacy rules on the ADDED lines of the staged diff (lib-privacy.sh)
#
# Deletions always pass (`git rm --cached PROJECT.toml` is the fix, not a leak).
# kit.toml is read from the index (what is being committed), else the work tree.
# Binary files (NUL bytes) skip the content rules; in-tree .gitattributes cannot
# mark text as binary to hide it (attributes come from the empty tree).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-guard.sh"
guard_init pre-commit

HAS_KIT=0; KT=""
if KT="$(git show :kit.toml 2>/dev/null)"; then HAS_KIT=1
elif [[ -n "$TOP" && -f "$TOP/kit.toml" ]]; then KT="$(cat "$TOP/kit.toml")"; HAS_KIT=1; fi
VIS=""; ALLOW_LITS=""; ALLOW_PATHS=""
if [[ $HAS_KIT -eq 1 ]]; then
    VIS="$(printf '%s\n' "$KT" | privacy_kt_visibility)"
    ALLOW_LITS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_literals)"
    ALLOW_PATHS="$(printf '%s\n' "$KT" | privacy_kt_privacy_array allow_paths)"
fi

# --- R2: staged paths (renames split into add+delete so the new name is seen)
while IFS= read -r -d '' p; do
    if g="$(guard_r2_match "$HAS_KIT" "$p")"; then
        guard_add BLOCK "R2 forbidden-path" "$p" "never pushed: $g is local-only (design §7.2)"
    fi
done < <(git -c core.quotePath=false diff --cached --name-only --no-renames --diff-filter=ACMRT -z 2>/dev/null)

# --- R3–R7: added lines of the staged diff
guard_load_privacy
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard-pc.XXXXXX")"; trap 'rm -rf "$TMPD"' EXIT
if GIT_ATTR_SOURCE="$GUARD_EMPTY_TREE" git -c core.quotePath=false diff --cached -U0 -M --no-color \
        --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ > "$TMPD/diff" 2>"$TMPD/err"; then
    guard_diff_stream < "$TMPD/diff" | privacy_scan_stream commit "$VIS" "$ALLOW_LITS" "$ALLOW_PATHS" > "$TMPD/scan"
    guard_add_scan < "$TMPD/scan"
else
    guard_add BLOCK "R0 guard-error" "(staged diff)" "could not read the staged diff: $(head -c 200 "$TMPD/err")"
fi

# --- R1: gitleaks on the staged diff (R8: missing / crashed → warn at commit time)
if ! guard_run_gitleaks git --staged "${TOP:-.}"; then
    guard_add WARN "R8 gitleaks-missing" "(all files)" "${GL_STATUS} — secrets (R1) NOT scanned; push will be blocked until it is installed — run: kit doctor --install"
fi

guard_finish
exit $?
