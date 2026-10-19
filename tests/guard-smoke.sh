#!/usr/bin/env bash
# tests/guard-smoke.sh - the v5 local git guard (plugin/guard/, design §7).
#
# Everything runs in throwaway repos under mktemp with an isolated HOME,
# KIT_CONFIG_HOME, KIT_STATE_HOME and GIT_CONFIG_GLOBAL — the real machine is
# never touched. Fixture literals are fake (testuser, 11111111-…, proj-a-…).
# gitleaks-dependent assertions use $KIT_TOOLS/gitleaks (or gitleaks on PATH)
# and print SKIP when neither exists.
#
# Sections: A engine (lib-privacy.sh) · B pre-commit · C pre-push ·
#           D shim / chaining / bypass · E end-to-end (kit setup + bare remote)
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$KIT_ROOT/plugin/guard"
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf 'SKIP %s (%s)\n' "$1" "$2"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 400)"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected [$3] in: $(printf '%s' "$2" | head -c 400)"; else pass "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }

for t in git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "SKIP guard-smoke: $t not installed"; exit 0; }
done
GITLEAKS=""
if [ -n "${KIT_TOOLS:-}" ] && [ -x "${KIT_TOOLS}/gitleaks" ]; then GITLEAKS="$KIT_TOOLS/gitleaks"
elif command -v gitleaks >/dev/null 2>&1; then GITLEAKS="$(command -v gitleaks)"; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard-smoke.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" KIT_CONFIG_HOME="$W/home/.config/kit" KIT_STATE_HOME="$W/home/.local/state/kit"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$W/home/.config"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@users.noreply.github.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@users.noreply.github.com
unset KIT_GUARD_CONFIG_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$KIT_CONFIG_HOME" "$KIT_STATE_HOME"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false

# fake-but-detectable secrets are assembled at run time so this file never
# carries one (gitleaks allowlists the documented AKIA…EXAMPLE key anyway)
FAKE_AWS="AKIA""QX7RZ2K4M6N3P5T2"
FAKE_JWT_SEG="eyJ""hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
FAKE_JWT="${FAKE_JWT_SEG}.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UifQ.Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0"

PRIV="$KIT_CONFIG_HOME/privacy.local.toml"
cat > "$PRIV" <<'EOF'
usernames = ["testuser"]
emails = ["owner@personal-mail.test"]

[[literal]]
name = "t-uid"
value = "11111111-2222-3333-4444-555555555555"
tier = "always"

[[literal]]
name = "t-proj"
value = "proj-a-secret-name"
tier = "public-only"

[[literal]]
name = "t-regex"
value = "a.b*c+"
tier = "always"

[[literal]]
name = "t-short"
value = "ab"
tier = "always"
EOF
chmod 600 "$PRIV"

# ============================================================ A. engine
# eng <visibility> <allow_literals_csv> <content> [allow_paths_csv] [display]
#   → sets EO (stdout), EE (stderr), EC (exit code)
eng() {
  local out err
  out="$W/eng.out"; err="$W/eng.err"
  printf '%s' "$3" | bash -c 'source "$1/lib-privacy.sh"; privacy_load_local "$2" || exit 9
    privacy_scan_file commit "$3" "$4" "${6:-f.txt}" "$5"' _ "$GUARD" "$PRIV" "$1" "$2" "${4:-}" "${5:-}" >"$out" 2>"$err"
  EC=$?; EO="$(cat "$out")"; EE="$(cat "$err")"
}
echo "--- A. engine"
if [ ! -f "$GUARD/lib-privacy.sh" ]; then fail "A0: plugin/guard/lib-privacy.sh exists" "missing"; fi

eng public "" "x = '/home/testuser/proj/x'"
has  "A1: /home/<configured user>/ BLOCK R3" "$EO" $'BLOCK\tR3 local-path\tf.txt:1'
eq   "A1: exit 1 on a block" "$EC" "1"
lacks "A1: user name redacted" "$EO$EE" "testuser"
eng public "" "WORKDIR /home/node/app"
has  "A2: /home/node/ WARN R3b" "$EO" $'WARN\tR3b other-home-path'
lacks "A2: /home/node/ not a block" "$EO" "BLOCK"
eq   "A2: warn only → exit 0" "$EC" "0"
eng public "" "see /mnt/c/Users/testuser/Desktop"
has  "A3: /mnt/c/Users/<user>/ BLOCK R3" "$EO" $'BLOCK\tR3 local-path'
eng public "" 'path = "C:\Users\TestUser\Documents"'
has  "A3: C:\\Users\\<User> (any case) BLOCK R3" "$EO" $'BLOCK\tR3 local-path'
eng public "" "home=/home/testuser"
has  "A3: /home/<user> at end of line BLOCK" "$EO" $'BLOCK\tR3 local-path'
eng public "" "home=/home/testuser2/x"
lacks "A3: /home/<user>2/ is a different user (not R3)" "$EO" "R3 local-path"
eng public "" "osuser /home/$(id -un)/x"
has  "A3b: the OS user's home is R3 even if not listed" "$EO" $'BLOCK\tR3 local-path'

eng public "" $'ok\nuid: 11111111-2222-3333-4444-555555555555'
has  "A4: always literal BLOCK R4 (public), line 2" "$EO" $'BLOCK\tR4 personal-literal\tf.txt:2'
has  "A4: why names the literal" "$EO" "<t-uid>"
lacks "A4: value never printed" "$EO$EE" "11111111"
eng private "" "uid: 11111111-2222-3333-4444-555555555555"
has  "A4: always literal BLOCK R4 (private)" "$EO" $'BLOCK\tR4 personal-literal'
eng public "" "name: PROJ-A-SECRET-NAME"
has  "A5: public-only literal BLOCK R5 when public (case-insensitive)" "$EO" $'BLOCK\tR5 public-only-literal'
lacks "A5: value never printed" "$EO$EE" "secret-name"
eng private "" "name: proj-a-secret-name"
eq   "A5: public-only literal passes when private" "$EO" ""
eq   "A5: private → exit 0" "$EC" "0"
eng "" "" "name: proj-a-secret-name"
has  "A5: visibility unset → treated as public (fail-closed)" "$EO" $'BLOCK\tR5 public-only-literal'
eng garbage "" "name: proj-a-secret-name"
has  "A5: visibility garbage → treated as public" "$EO" $'BLOCK\tR5 public-only-literal'

eng public "t-uid" "uid: 11111111-2222-3333-4444-555555555555"
lacks "A6: allow_literals by NAME → no block" "$EO" "BLOCK"
has  "A6: stderr says allowed by kit.toml" "$EE" "KIT GUARD: literal t-uid allowed by kit.toml"
eng public "t-uid,t-proj" "uid 11111111-2222-3333-4444-555555555555 proj-a-secret-name"
eq   "A6: two names allowed → exit 0" "$EC" "0"
eng public "11111111-2222-3333-4444-555555555555" "uid: 11111111-2222-3333-4444-555555555555"
has  "A7: allow_literals by VALUE → still BLOCK" "$EO" $'BLOCK\tR4 personal-literal'
lacks "A7: value never echoed (stdout/stderr)" "$EO$EE" "11111111"
has  "A7: stderr explains a value is not a name" "$EE" "VALUE"
eng public "nope" "uid: 11111111-2222-3333-4444-555555555555"
has  "A8: unknown name → stderr warn" "$EE" "unknown literal name"
has  "A8: unknown name → others still block" "$EO" $'BLOCK\tR4 personal-literal'

eng public "" "uid: 11111111-2222-3333-4444-555555555555 /home/testuser/ # kit-privacy: allow"
eq   "A9: 'kit-privacy: allow' line skipped" "$EO" ""
eng public "" $'mail a@b.co\nbot x@users.noreply.github.com\nnoreply@example.com\nsee git@github.com:o/r'
has  "A10: generic email WARN R6" "$EO" $'WARN\tR6 email\tf.txt:1'
lacks "A10: noreply / example / git@ not flagged" "$EO" "f.txt:2"
lacks "A10: example.com not flagged" "$EO" "f.txt:3"
lacks "A10: git@host not flagged" "$EO" "f.txt:4"
eng public "" "owner@personal-mail.test wrote this"
has  "A11: personal email (privacy emails) BLOCK R4 as <email>" "$EO" "<email>"
lacks "A11: personal email never printed" "$EO$EE" "personal-mail"
eng public "email" "owner@personal-mail.test wrote this"
lacks "A11: allow_literals=email exempts it (same as audit A2)" "$EO" "BLOCK"
eng public "" "scratch /tmp/claude-1000/x/y"
has  "A12: /tmp/claude-<uid>/ WARN R7" "$EO" $'WARN\tR7 claude-tmp-path'
eng public "" "ab abc"
eq   "A13: literal < 4 chars ignored" "$EO" ""
eng public "" "aXbbc aXbbbcc"
eq   "A14: literal is a fixed string (regex chars inert)" "$EO" ""
eng public "" "lit a.b*c+ here"
has  "A14: fixed-string literal matches itself" "$EO" $'BLOCK\tR4 personal-literal'
eng public "" "/home/testuser/x 11111111-2222-3333-4444-555555555555" "docs/media/*" "docs/media/a.txt"
eq   "A15: allow_paths glob skips R3–R7" "$EO" ""
eng public "" "/home/testuser/x" "docs/media/*" "src/a.txt"
has  "A15: allow_paths does not cover other paths" "$EO" $'BLOCK\tR3'

# stream form: path<TAB>lineno<TAB>tag<TAB>content (pre-push tags lines with a commit)
SO="$(printf 'a.txt\t7\tabc1234\tuid 11111111-2222-3333-4444-555555555555\n' | bash -c 'source "$1/lib-privacy.sh"; privacy_load_local "$2"; privacy_scan_stream push public "" ""' _ "$GUARD" "$PRIV" 2>&1)"
has  "A16: stream form reports path:line @commit" "$SO" $'BLOCK\tR4 personal-literal\ta.txt:7 @abc1234'

R="$(bash -c 'source "$1/lib-privacy.sh"; privacy_load_local "$2/nope.toml"; echo "rc=$?"' _ "$GUARD" "$W")"
eq   "A17: privacy_load_local on a missing file returns 1" "$R" "rc=1"
R="$(bash -c 'source "$1/lib-privacy.sh"; privacy_load_local "$2"; echo "${#PRIV_USERS[@]} ${#PRIV_EMAILS[@]} ${#PRIV_LIT_NAME[@]} ${PRIV_LIT_NAME[1]} ${PRIV_LIT_TIER[1]}"' _ "$GUARD" "$PRIV")"
eq   "A17: privacy_load_local parses users/emails/literals" "$R" "1 1 3 t-proj public-only"

mkdir -p "$W/kt"
cat > "$W/kt/kit.toml" <<'EOF'
kit = 5
visibility = "private"   # comment
protected = [
  "src/legacy/*",
]

[privacy]
allow_paths = ["docs/media/*", "assets/*"]
allow_literals = [
  "t-uid",
  "t-proj",
]
EOF
R="$(bash -c 'source "$1/lib-privacy.sh"; echo "$(privacy_kit_toml_visibility "$2")|$(privacy_kit_toml_allow_literals "$2")|$(privacy_kit_toml_allow_paths "$2")"' _ "$GUARD" "$W/kt")"
eq   "A18: kit.toml readers (visibility, multi-line allow_literals, one-line allow_paths)" "$R" "private|t-uid,t-proj|docs/media/*,assets/*"
R="$(bash -c 'source "$1/lib-privacy.sh"; echo "$(privacy_kit_toml_visibility "$2")|$(privacy_kit_toml_allow_literals "$2")|$(privacy_kit_toml_allow_paths "$2")"' _ "$GUARD" "$W/nokt")"
eq   "A18: no kit.toml → all empty" "$R" "||"
printf 'visibility = "private"\nallow_literals = ["t-uid"]\n' > "$W/kt/kit.toml"
R="$(bash -c 'source "$1/lib-privacy.sh"; privacy_kit_toml_allow_literals "$2"' _ "$GUARD" "$W/kt")"
eq   "A18: allow_literals outside [privacy] is ignored" "$R" ""

# rules file + gitleaks extension
has  "A19: privacy-rules.toml ships R3/R3b/R6/R7" "$(cat "$GUARD/privacy-rules.toml" 2>/dev/null)" "id = 'R3b'"
has  "A19: gitleaks.toml extends the default rules" "$(cat "$GUARD/gitleaks.toml" 2>/dev/null)" "useDefault = true"
has  "A19: gitleaks.toml has the kit supabase rule" "$(cat "$GUARD/gitleaks.toml" 2>/dev/null)" 'id = "kit-supabase-service-key"'
if [ -n "$GITLEAKS" ]; then
  mkdir -p "$W/gl"; printf 'SUPABASE_SERVICE_ROLE_KEY=%s\n' "$FAKE_JWT" > "$W/gl/env.txt"
  "$GITLEAKS" dir "$W/gl" --config "$GUARD/gitleaks.toml" --no-banner --redact --log-level error \
     --report-format json --report-path "$W/gl.json" --exit-code 7 >/dev/null 2>&1; C=$?
  eq  "A20: gitleaks.toml loads and flags a service-role JWT" "$C" "7"
  has "A20: kit rule id reported" "$(cat "$W/gl.json" 2>/dev/null)" "kit-supabase-service-key"
else skip "A20: gitleaks.toml kit rule" "no gitleaks"; fi

# speed: the engine over a few thousand lines stays fast
seq 1 4000 | sed 's/^/line of ordinary source code number /' > "$W/big.txt"
T0=$(date +%s%N); bash -c 'source "$1/lib-privacy.sh"; privacy_load_local "$2"; privacy_scan_file commit public "" big.txt < "$3"' _ "$GUARD" "$PRIV" "$W/big.txt" >/dev/null 2>&1
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[ "$MS" -lt 500 ] && pass "A21: 4000-line scan < 500ms (${MS}ms)" || fail "A21: 4000-line scan < 500ms" "${MS}ms"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT, skipped $SKIP_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
