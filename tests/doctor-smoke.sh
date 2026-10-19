#!/usr/bin/env bash
# tests/doctor-smoke.sh - `kit doctor` in an isolated HOME: every check decidable,
# FAIL → exit 1; with all pieces faked in place → only OK/WARN, exit 0.
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3]"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected [$3]"; else pass "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/cfg" "$W/shimbin" "$W/proj"
for t in python3 git jq; do ln -s "$(command -v $t)" "$W/shimbin/$t"; done
: > "$W/gitconfig"
d() {  # run doctor isolated; cwd = $W/proj
  (cd "$W/proj" && env -i PATH="$W/shimbin" HOME="$W/home" KIT_CONFIG_HOME="$W/cfg" \
     GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1 KIT_CACHE_HOME="$W/cache" \
     https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
     "$W/shimbin/python3" "$KIT_ROOT/bin/kit" doctor "$@" 2>&1)
}

OUT="$(d)"; CODE=$?
[ "$CODE" -eq 1 ] && pass "d1: bare machine exits 1" || fail "d1: bare machine exits 1" "got $CODE"
has "d1: FAIL hooksPath" "$OUT" "FAIL hooksPath"
has "d1: WARN gitleaks" "$OUT" "WARN gitleaks"
has "d1: FAIL privacy.local.toml" "$OUT" "FAIL privacy.local.toml"
has "d1: FAIL claude (not on PATH)" "$OUT" "FAIL claude"
has "d1: FAIL plugin" "$OUT" "FAIL plugin"
has "d1: FAIL config.toml" "$OUT" "FAIL config.toml"
has "d1: rules budget OK" "$OUT" "OK rules budget"
if printf '%s\n' "$OUT" | grep -vE '^(OK|WARN|FAIL) [^ ].* — |^$|^kit doctor|^[0-9]+ (FAIL|WARN)' | grep -q .; then
  fail "d1: every line is OK|WARN|FAIL <label> — <detail>" "$(printf '%s\n' "$OUT" | grep -vE '^(OK|WARN|FAIL) ' | head -2)"
else pass "d1: every line is OK|WARN|FAIL <label> — <detail>"; fi

# fill everything in
printf '#!/bin/sh\necho "2.1.303 (Claude Code)"\n' > "$W/shimbin/claude"; chmod +x "$W/shimbin/claude"
mkdir -p "$W/home/.claude" "$W/cfg/git-hooks"
printf '{"enabledPlugins":{"kit@multi-agent-kit":true}}\n' > "$W/home/.claude/settings.json"
for h in pre-commit pre-push; do printf '#!/bin/sh\nexit 0\n' > "$W/cfg/git-hooks/$h"; chmod 755 "$W/cfg/git-hooks/$h"; done
git config --file "$W/gitconfig" core.hooksPath "$W/cfg/git-hooks"
printf 'kit_root = "%s"\nprofile = "full"\n' "$KIT_ROOT" > "$W/cfg/config.toml"
printf 'usernames = []\nemails = []\n' > "$W/cfg/privacy.local.toml"; chmod 600 "$W/cfg/privacy.local.toml"
OUT="$(d)"; CODE=$?
[ "$CODE" -eq 0 ] && pass "d2: complete machine exits 0" || fail "d2: complete machine exits 0" "got $CODE: $(printf '%s' "$OUT" | grep FAIL)"
lacks "d2: no FAIL lines" "$OUT" "FAIL "
has "d2: OK hooksPath" "$OUT" "OK hooksPath"
has "d2: OK plugin" "$OUT" "OK plugin"
has "d2: OK claude" "$OUT" "OK claude"

# privacy mode must be 600
chmod 644 "$W/cfg/privacy.local.toml"
OUT="$(d)"; CODE=$?
[ "$CODE" -eq 1 ] && pass "d3: privacy mode 644 fails" || fail "d3: privacy mode 644 fails" "got $CODE"
has "d3: names mode 600" "$OUT" "600"
chmod 600 "$W/cfg/privacy.local.toml"

# kit.toml in cwd: malformed → FAIL; unknown allow_literals name → WARN
printf 'kit = 5\nprotected = [\n  "a/", # x\n]\n' > "$W/proj/kit.toml"
OUT="$(d)"; CODE=$?
[ "$CODE" -eq 1 ] && pass "d4: malformed kit.toml fails" || fail "d4: malformed kit.toml fails" "got $CODE"
has "d4: names inline comment" "$OUT" "inline comment"
printf 'kit = 5\n[privacy]\nallow_literals = ["no-such-name"]\n' > "$W/proj/kit.toml"
OUT="$(d)"; CODE=$?
[ "$CODE" -eq 0 ] && pass "d5: unknown literal name is only a warning" || fail "d5: unknown literal name is only a warning" "got $CODE"
has "d5: WARN unknown literal name" "$OUT" "unknown literal name"
# old claude
printf '#!/bin/sh\necho "2.1.200 (Claude Code)"\n' > "$W/shimbin/claude"
OUT="$(d)"; CODE=$?
has "d6: old claude fails" "$OUT" "FAIL claude"

printf '#!/bin/sh\necho "2.1.303 (Claude Code)"\n' > "$W/shimbin/claude"

# review R4-1: trust = sha256, never the version output
printf '#!/bin/sh\ntouch "%s/stub-ran"\necho 8.30.1\n' "$W" > "$W/shimbin/gitleaks"; chmod +x "$W/shimbin/gitleaks"
OUT="$(d --install)"
lacks "d7: doctor --install never records a version-spoofing PATH gitleaks" "$(cat "$W/cfg/config.toml")" "$W/shimbin/gitleaks"
lacks "d7: …nor a gitleaks_sha256 for it" "$(cat "$W/cfg/config.toml")" "gitleaks_sha256"
has "d7: …and names it" "$OUT" "$W/shimbin/gitleaks is not the pinned gitleaks build"
rm -f "$W/shimbin/gitleaks" "$W/stub-ran"
mkdir -p "$W/home/.local/bin"; printf '#!/bin/sh\necho 8.30.1\n' > "$W/home/.local/bin/gitleaks"; chmod +x "$W/home/.local/bin/gitleaks"
OUT="$(d)"
has "d8: a tools_dir gitleaks with no sha256 recorded is a WARN (the guard will not run it)" "$OUT" "no gitleaks_sha256 recorded"
printf 'gitleaks_sha256 = "%s"\n' "$(printf x | sha256sum | cut -d' ' -f1)" >> "$W/cfg/config.toml"
OUT="$(d)"; CODE=$?
has "d8: a tools_dir gitleaks whose sha256 differs from the recorded one → FAIL replaced" "$OUT" "FAIL gitleaks"
has "d8: …says replaced" "$OUT" "the binary was replaced"
[ "$CODE" -eq 1 ] && pass "d8: …exit 1" || fail "d8: …exit 1" "got $CODE"
grep -v '^gitleaks_sha256' "$W/cfg/config.toml" > "$W/c.new"; mv "$W/c.new" "$W/cfg/config.toml"
printf 'gitleaks_sha256 = "%s"\n' "$(sha256sum < "$W/home/.local/bin/gitleaks" | cut -d' ' -f1)" >> "$W/cfg/config.toml"
OUT="$(d)"
has "d8: hash-equal but hand-recorded (not the pin) → WARN" "$OUT" "sha256 recorded by hand"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
