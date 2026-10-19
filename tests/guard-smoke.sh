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
HP=/home   # fixtures build "/home/<user>" strings at runtime so the kit guard does not flag this file
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

eng public "" "x = '$HP/testuser/proj/x'"
has  "A1: /home/<configured user>/ BLOCK R3" "$EO" $'BLOCK\tR3 local-path\tf.txt:1'
eq   "A1: exit 1 on a block" "$EC" "1"
lacks "A1: user name redacted" "$EO$EE" "testuser"
eng public "" "WORKDIR $HP/node/app"
has  "A2: $HP/node/ WARN R3b" "$EO" $'WARN\tR3b other-home-path'
lacks "A2: $HP/node/ not a block" "$EO" "BLOCK"
eq   "A2: warn only → exit 0" "$EC" "0"
eng public "" "see /mnt/c/Users/testuser/Desktop"
has  "A3: /mnt/c/Users/<user>/ BLOCK R3" "$EO" $'BLOCK\tR3 local-path'
eng public "" 'path = "C:\Users\TestUser\Documents"'
has  "A3: C:\\Users\\<User> (any case) BLOCK R3" "$EO" $'BLOCK\tR3 local-path'
eng public "" "home=$HP/testuser"
has  "A3: /home/<user> at end of line BLOCK" "$EO" $'BLOCK\tR3 local-path'
eng public "" "home=$HP/testuser2/x"
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

eng public "" "uid: 11111111-2222-3333-4444-555555555555 $HP/testuser/ # kit-privacy: allow"
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
eng public "" "scratch /tmp/claude""-1000/x/y"
has  "A12: /tmp/claude-<uid>/ WARN R7" "$EO" $'WARN\tR7 claude-tmp-path'
eng public "" "ab abc"
eq   "A13: literal < 4 chars ignored" "$EO" ""
eng public "" "aXbbc aXbbbcc"
eq   "A14: literal is a fixed string (regex chars inert)" "$EO" ""
eng public "" "lit a.b*c+ here"
has  "A14: fixed-string literal matches itself" "$EO" $'BLOCK\tR4 personal-literal'
eng public "" "$HP/testuser/x 11111111-2222-3333-4444-555555555555" "docs/media/*" "docs/media/a.txt"
eq   "A15: allow_paths glob skips R3–R7" "$EO" ""
eng public "" "$HP/testuser/x" "docs/media/*" "src/a.txt"
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


# ============================================================ B. pre-commit
echo "--- B. pre-commit"
TH="$W/th"; mkdir -p "$TH"   # test hooks dir: straight to plugin/guard (the real shim is section D)
for h in pre-commit pre-push; do printf '#!/usr/bin/env bash\nexec bash "%s/%s.sh" "$@"\n' "$GUARD" "$h" > "$TH/$h"; chmod +x "$TH/$h"; done
# PATH without gitleaks (drop any PATH dir that has one) / with the pinned one first
NOGL_PATH=""; IFS=: read -ra _pp <<< "$PATH"
for d in "${_pp[@]}"; do [ -x "$d/gitleaks" ] || NOGL_PATH="${NOGL_PATH:+$NOGL_PATH:}$d"; done
mkdir -p "$W/glbin"
if [ -n "$GITLEAKS" ]; then ln -sf "$GITLEAKS" "$W/glbin/gitleaks"
else printf '#!/bin/sh\nexit 0\n' > "$W/glbin/gitleaks"; chmod +x "$W/glbin/gitleaks"; fi   # no real gitleaks: a clean stand-in (R1 assertions SKIP)
GL_PATH="$W/glbin:$NOGL_PATH"
AUDIT="$KIT_STATE_HOME/guard/audit.jsonl"

# newrepo <dir> [visibility|none]: repo with an initial commit made WITHOUT hooks
# (PROJECT.toml tracked from the start, like a v4 repo); kit.toml unless "none"
newrepo() {
  rm -rf "$1"; git init -q "$1"
  [ "${3:-}" = noproj ] || printf 'status = "active"\n' > "$1/PROJECT.toml"; echo "# r" > "$1/README.md"
  if [ "${2:-public}" != none ]; then printf 'kit = 5\nvisibility = "%s"\nprotected = [\n]\n' "${2:-public}" > "$1/kit.toml"; fi
  git -C "$1" add -A && git -C "$1" -c core.hooksPath=/dev/null commit -q -m init
}
# cmt <repo> [PATH] → CO (combined output), CC (exit code); commits staged changes through the guard
cmt() {
  CO="$(cd "$1" && PATH="${2:-$GL_PATH}" git -c core.hooksPath="$TH" commit -q -m t 2>&1)"; CC=$?
}
R="$W/rb"
newrepo "$R"
mkdir -p "$R/.claude"; echo x > "$R/.claude/x"; git -C "$R" add -f .claude/x
cmt "$R"
eq   "B1: staged .claude/x → exit 1" "$CC" "1"
has  "B1: [R2 forbidden-path]" "$CO" "KIT GUARD BLOCKED [R2 forbidden-path] .claude/x"
has  "B1: fix line" "$CO" "fix:"
has  "B1: user-only bypass line" "$CO" 'bypass (user only): kit guard bypass "<reason>"'
has  "B8: audit.jsonl logs the block" "$(cat "$AUDIT" 2>/dev/null)" '"rule":"R2"'
has  "B8: audit.jsonl names the hook" "$(cat "$AUDIT" 2>/dev/null)" '"hook":"pre-commit"'
has  "B8: audit.jsonl action block" "$(cat "$AUDIT" 2>/dev/null)" '"action":"block"'
jq -e . "$AUDIT" >/dev/null 2>&1 && pass "B8: audit.jsonl is valid JSON lines" || fail "B8: audit.jsonl is valid JSON lines" "$(head -c 300 "$AUDIT" 2>/dev/null)"
git -C "$R" rm -q --cached .claude/x
for f in docs/plans/p.md docs/superpowers/plans/p.md docs/decisions/d.md docs/LESSONS.md a/b.local.toml CLAUDE.local.md .superpowers/s sub/.env.local sub/PROJECT.toml; do
  mkdir -p "$R/$(dirname "$f")"; echo x > "$R/$f"; git -C "$R" add -f "$f"; cmt "$R"
  has "B1: $f blocked [R2]" "$CO" "[R2 forbidden-path] $f"; git -C "$R" rm -q --cached "$f"
done
echo x > "$R/.env.example"; git -C "$R" add -f .env.example; cmt "$R"
eq   "B1: .env.example passes" "$CC" "0"

git -C "$R" rm -q --cached PROJECT.toml; cmt "$R"
eq   "B2: git rm --cached PROJECT.toml (deletion) passes" "$CC" "0"

printf 'ok\npath = "'"$HP"'/testuser/x"\n' > "$R/c.txt"; git -C "$R" add c.txt; cmt "$R"
eq   "B3: $HP/testuser/ → exit 1" "$CC" "1"
has  "B3: [R3 local-path] with path:line" "$CO" "KIT GUARD BLOCKED [R3 local-path] c.txt:2 —"
lacks "B3: block output never prints the user name" "$CO" "testuser"
git -C "$R" reset -q c.txt; rm -f "$R/c.txt"

printf 'name: proj-a-secret-name\n' > "$R/d.txt"; git -C "$R" add d.txt; cmt "$R"
has  "B12: public-only literal blocked in a public repo" "$CO" "[R5 public-only-literal]"
git -C "$R" reset -q d.txt; rm -f "$R/d.txt"

if [ -n "$GITLEAKS" ]; then
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$R/k.txt"; git -C "$R" add k.txt; cmt "$R"
  eq  "B4: fake AWS key → exit 1" "$CC" "1"
  has "B4: [R1 secret]" "$CO" "KIT GUARD BLOCKED [R1 secret] k.txt:1"
  lacks "B4: secret not printed" "$CO" "$FAKE_AWS"
else skip "B4: R1 gitleaks" "no gitleaks"; printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$R/k.txt"; git -C "$R" add k.txt; fi
cmt "$R" "$NOGL_PATH"
eq   "B5: no gitleaks → pre-commit still passes (R8 warn)" "$CC" "0"
has  "B5: banner says kit doctor --install" "$CO" "kit doctor --install"
has  "B5: banner is R8" "$CO" "[R8 gitleaks-missing]"
mkdir -p "$W/crashgl"; printf '#!/bin/sh\nexit 2\n' > "$W/crashgl/gitleaks"; chmod +x "$W/crashgl/gitleaks"
printf 'more\n' >> "$R/k.txt"; git -C "$R" add k.txt; cmt "$R" "$W/crashgl:$NOGL_PATH"
eq   "B14: gitleaks crash (exit 2) → treated as missing: pre-commit passes" "$CC" "0"
has  "B14: crash reported" "$CO" "[R8 gitleaks-missing]"

printf 'hello\n' > "$R/clean.txt"; git -C "$R" add clean.txt
T0=$(date +%s%N); cmt "$R"; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
eq   "B6: clean commit passes" "$CC" "0"
[ "$MS" -lt 1000 ] && pass "B6: clean commit < 1s incl. gitleaks (${MS}ms)" || fail "B6: clean commit < 1s" "${MS}ms"

printf 'bin\0ary 11111111-2222-3333-4444-555555555555\n' > "$R/blob.bin"; git -C "$R" add blob.bin; cmt "$R"
eq   "B7: binary file (NUL) content not scanned" "$CC" "0"
printf '*.txt binary\n' > "$R/.gitattributes"; printf 'x '"$HP"'/testuser/y\n' > "$R/hid.txt"; git -C "$R" add .gitattributes hid.txt; cmt "$R"
has  "B10: .gitattributes 'binary' cannot hide text from the guard" "$CO" "[R3 local-path] hid.txt:1"
git -C "$R" reset -q hid.txt; rm -f "$R/hid.txt"; git -C "$R" add .gitattributes; cmt "$R"

printf 'WORKDIR '"$HP"'/node/app\n' > "$R/Dockerfile"; git -C "$R" add Dockerfile; cmt "$R"
eq   "B16: $HP/node warns but passes" "$CC" "0"
has  "B16: warn line format" "$CO" "KIT GUARD WARN [R3b other-home-path] Dockerfile:1"

printf 'echo '"$HP"'/testuser/old\n' > "$R/old.sh"; git -C "$R" add old.sh; git -C "$R" -c core.hooksPath=/dev/null commit -q -m "pre-guard"
git -C "$R" mv old.sh renamed.sh; cmt "$R"
eq   "B17: pure rename of pre-existing content is not re-flagged (only added lines)" "$CC" "0"
printf 'echo '"$HP"'/testuser/new\n' >> "$R/renamed.sh"; cmt "$R"
cmt "$R"; (cd "$R" && PATH="$GL_PATH" git -c core.hooksPath="$TH" commit -q -a -m t >"$W/o" 2>&1); CC=$?; CO="$(cat "$W/o")"
eq   "B15: git commit -a (temporary index) still guarded" "$CC" "1"
has  "B15: the added line is reported" "$CO" "[R3 local-path] renamed.sh:2"
git -C "$R" checkout -q -- renamed.sh

printf 'kit = 5\nvisibility = "public"\n\n[privacy]\nallow_literals = ["t-uid"]\n' > "$R/kit.toml"
printf 'uid 11111111-2222-3333-4444-555555555555\n' > "$R/u.txt"; git -C "$R" add kit.toml u.txt; cmt "$R"
eq   "B13: allow_literals by name (staged kit.toml) → passes" "$CC" "0"
has  "B13: stderr notes the exception" "$CO" "literal t-uid allowed by kit.toml"
printf 'kit = 5\nvisibility = "public"\n\n[privacy]\nallow_literals = ["11111111-2222-3333-4444-555555555555"]\n' > "$R/kit.toml"
printf 'uid2 11111111-2222-3333-4444-555555555555\n' >> "$R/u.txt"; git -C "$R" add kit.toml u.txt; cmt "$R"
eq   "B13: allow_literals by value → blocked" "$CC" "1"
lacks "B13: value never echoed" "$CO" "11111111"
git -C "$R" reset -q --hard

N="$W/nokit"; newrepo "$N" none
printf 'x\n' > "$N/PROJECT.toml.new"; mv "$N/PROJECT.toml.new" "$N/PROJECT.toml"; mkdir -p "$N/docs/plans"; echo p > "$N/docs/plans/p.md"
git -C "$N" add PROJECT.toml docs/plans/p.md; cmt "$N"
eq   "B9: no kit.toml → PROJECT.toml / docs/plans pass (R2 is .env* only)" "$CC" "0"
echo "K=v" > "$N/.env"; git -C "$N" add -f .env; cmt "$N"
eq   "B9: no kit.toml → .env still blocked" "$CC" "1"
has  "B9: .env is R2" "$CO" "[R2 forbidden-path] .env"
git -C "$N" rm -q --cached .env
printf 'p '"$HP"'/testuser/x\n' > "$N/n.txt"; git -C "$N" add n.txt; cmt "$N"
has  "B9: no kit.toml → R3 still runs" "$CO" "[R3 local-path]"
git -C "$N" reset -q n.txt
printf 'name proj-a-secret-name\n' > "$N/n.txt"; git -C "$N" add n.txt; cmt "$N"
has  "B9: no kit.toml → R5 fail-closed (treated as public)" "$CO" "[R5 public-only-literal]"
git -C "$N" reset -q n.txt
printf 'uid 11111111-2222-3333-4444-555555555555\n' > "$N/n.txt"; git -C "$N" add n.txt; cmt "$N"
has  "B9: no kit.toml → R4 still runs" "$CO" "[R4 personal-literal]"
git -C "$N" reset -q n.txt
if [ -n "$GITLEAKS" ]; then
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$N/k.txt"; git -C "$N" add k.txt; cmt "$N"
  has "B9: no kit.toml → R1 still runs" "$CO" "[R1 secret]"; git -C "$N" reset -q k.txt
fi
P="$W/priv"; newrepo "$P" private
printf 'name proj-a-secret-name\n' > "$P/n.txt"; git -C "$P" add n.txt; cmt "$P"
eq   "B12: public-only literal passes in a private repo" "$CC" "0"
printf 'uid 11111111-2222-3333-4444-555555555555\n' > "$P/m.txt"; git -C "$P" add m.txt; cmt "$P"
has  "B12: always literal blocked in a private repo" "$CO" "[R4 personal-literal]"
git -C "$P" reset -q m.txt
mv "$PRIV" "$PRIV.off"; printf 'uid 11111111-2222-3333-4444-555555555555\n' > "$P/m.txt"; git -C "$P" add m.txt; cmt "$P"
eq   "B18: privacy.local.toml missing → R4/R5 skipped (passes)" "$CC" "0"
has  "B18: …with a warning" "$CO" "privacy.local.toml"
mv "$PRIV.off" "$PRIV"; git -C "$P" reset -q m.txt

# ============================================================ C. pre-push
echo "--- C. pre-push"
# pushrepo <dir> [visibility]: newrepo + bare origin with the initial history
# pushed WITHOUT hooks (= history that predates the guard)
pushrepo() {
  newrepo "$1" "${2:-public}"; rm -rf "$1.git"; git init -q --bare "$1.git"
  git -C "$1" remote add origin "$1.git"; git -C "$1" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
}
# psh <repo> <PATH|""> <push args…> → PO, PC
psh() {
  local r="$1" p="${2:-$GL_PATH}"; shift 2
  PO="$(cd "$r" && PATH="$p" git -c core.hooksPath="$TH" push -q "$@" 2>&1)"; PC=$?
}
nc() { git -C "$1" -c core.hooksPath=/dev/null commit -q -m "${2:-c}"; }   # commit without the guard
Q="$W/pq"; pushrepo "$Q"
echo more >> "$Q/README.md"; git -C "$Q" add README.md; nc "$Q"
T0=$(date +%s%N); psh "$Q" "" origin main; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
eq   "C1: long-tracked PROJECT.toml (not in the pushed range) → push exit 1" "$PC" "1"
has  "C1: [R2] from the whole pushed tree" "$PO" "KIT GUARD BLOCKED [R2 forbidden-path] PROJECT.toml"
has  "C14: audit.jsonl logs pre-push" "$(cat "$AUDIT")" '"hook":"pre-push"'
git -C "$Q" rm -q --cached PROJECT.toml; nc "$Q"
psh "$Q" "" origin main
eq   "C2: after git rm --cached the push passes" "$PC" "0"
[ "$MS" -lt 3000 ] && pass "C1: typical push scan < 3s (${MS}ms)" || fail "C1: typical push scan < 3s" "${MS}ms"
printf 'p = "'"$HP"'/testuser/x"\n' > "$Q/c3.txt"; git -C "$Q" add c3.txt; nc "$Q"
psh "$Q" "" origin main
eq   "C3: new commit with $HP/testuser/ → exit 1" "$PC" "1"
has  "C3: [R3] with path:line @commit" "$PO" "[R3 local-path] c3.txt:1 @"
lacks "C3: user name never printed" "$PO" "testuser"
psh "$Q" "$NOGL_PATH" origin main
eq   "C4: no gitleaks → push blocked" "$PC" "1"
has  "C4: says gitleaks required for push" "$PO" "gitleaks required for push"
has  "C4: [R8]" "$PO" "[R8 gitleaks-missing]"
git -C "$Q" reset -q --hard HEAD~1
git -C "$Q" -c core.hooksPath=/dev/null push -q origin main:br 2>/dev/null
psh "$Q" "$NOGL_PATH" origin :br
eq   "C5: deleting a remote branch passes (even without gitleaks)" "$PC" "0"
git -C "$Q" checkout -q -b feat
printf 'uid 11111111-2222-3333-4444-555555555555\n' > "$Q/f1.txt"; git -C "$Q" add f1.txt; nc "$Q"
echo clean > "$Q/f2.txt"; git -C "$Q" add f2.txt; nc "$Q"
psh "$Q" "" origin feat
eq   "C6: first push of a new branch scans every local-only commit" "$PC" "1"
has  "C6: the older commit's literal is found" "$PO" "[R4 personal-literal] f1.txt:1"
git -C "$Q" rm -q f1.txt; nc "$Q"
psh "$Q" "" origin feat
eq   "C8: a leak added then removed inside the range still blocks (history reaches the remote)" "$PC" "1"
has  "C8: …reported on the intermediate commit" "$PO" "[R4 personal-literal] f1.txt:1 @"
git -C "$Q" checkout -q main; git -C "$Q" branch -q -D feat
mkdir -p "$Q/docs/plans"; echo p > "$Q/docs/plans/x.md"; git -C "$Q" add docs/plans/x.md; nc "$Q"
git -C "$Q" rm -q docs/plans/x.md; nc "$Q"
psh "$Q" "" origin main
eq   "C9: a forbidden path added then deleted inside the range blocks" "$PC" "1"
has  "C9: [R2] for the intermediate path" "$PO" "[R2 forbidden-path] docs/plans/x.md"
git -C "$Q" reset -q --hard origin/main
printf 'p '"$HP"'/testuser/old\n' > "$Q/old.txt"; git -C "$Q" add old.txt; nc "$Q"
git -C "$Q" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
echo clean >> "$Q/README.md"; git -C "$Q" add README.md; nc "$Q"
psh "$Q" "" origin main
eq   "C10: content already on this remote is not rescanned" "$PC" "0"
rm -rf "$Q.other.git"; git init -q --bare "$Q.other.git"; git -C "$Q" remote add other "$Q.other.git"
printf 'p '"$HP"'/testuser/new\n' > "$Q/new.txt"; git -C "$Q" add new.txt; nc "$Q"
git -C "$Q" -c core.hooksPath=/dev/null push -q other main 2>/dev/null
psh "$Q" "" origin main
eq   "C11: commits already on ANOTHER remote are still scanned for this one" "$PC" "1"
git -C "$Q" reset -q --hard origin/main
git -C "$Q" checkout -q -b b1; echo one > "$Q/m.txt"; git -C "$Q" add m.txt; nc "$Q"
git -C "$Q" checkout -q main; echo two > "$Q/m.txt"; git -C "$Q" add m.txt; nc "$Q"
git -C "$Q" -c core.hooksPath=/dev/null merge -q b1 >/dev/null 2>&1
printf 'merged '"$HP"'/testuser/evil\n' > "$Q/m.txt"; git -C "$Q" add m.txt; git -C "$Q" -c core.hooksPath=/dev/null commit -q --no-edit
psh "$Q" "" origin main
eq   "C13: content introduced by a merge resolution is scanned" "$PC" "1"
has  "C13: …as an R3 hit" "$PO" "[R3 local-path] m.txt"
git -C "$Q" reset -q --hard origin/main; git -C "$Q" branch -q -D b1
printf 'p '"$HP"'/testuser/t\n' > "$Q/t.txt"; git -C "$Q" add t.txt; nc "$Q"; git -C "$Q" tag -a v1 -m v1; git -C "$Q" reset -q --hard origin/main
psh "$Q" "" origin v1
eq   "C15: pushing an annotated tag scans its commits" "$PC" "1"
git -C "$Q" tag -d v1 >/dev/null
if [ -n "$GITLEAKS" ]; then
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$Q/k.txt"; git -C "$Q" add k.txt; nc "$Q"
  psh "$Q" "" origin main
  eq  "C12: fake AWS key in the range → blocked" "$PC" "1"
  has "C12: [R1 secret]" "$PO" "[R1 secret] k.txt:1"
  lacks "C12: secret not printed" "$PO" "$FAKE_AWS"
  git -C "$Q" reset -q --hard origin/main
else skip "C12: R1 on push" "no gitleaks"; fi
QP="$W/pp"; pushrepo "$QP" private; git -C "$QP" rm -q --cached PROJECT.toml; nc "$QP"
printf 'name proj-a-secret-name\n' > "$QP/n.txt"; git -C "$QP" add n.txt; nc "$QP"
psh "$QP" "" origin main
eq   "C7: private repo → public-only literal passes" "$PC" "0"
printf 'kit = 5\nvisibility = "public"\n' > "$QP/kit.toml"; echo "again proj-a-secret-name" >> "$QP/n.txt"; git -C "$QP" add kit.toml n.txt; nc "$QP"
psh "$QP" "" origin main
eq   "C7: same repo flipped to public (pushed kit.toml) → blocked" "$PC" "1"
has  "C7: [R5]" "$PO" "[R5 public-only-literal]"
QN="$W/pn"; pushrepo "$QN" none
echo x >> "$QN/README.md"; git -C "$QN" add README.md; nc "$QN"
psh "$QN" "" origin main
eq   "C16: no kit.toml → long-tracked PROJECT.toml is not R2" "$PC" "0"
echo "K=v" > "$QN/.env"; git -C "$QN" add -f .env; nc "$QN"; git -C "$QN" rm -q --cached .env; nc "$QN"
git -C "$QN" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null   # .env reached history before the guard
printf 'x\n' > "$QN/.env.local"; git -C "$QN" add -f .env.local; nc "$QN"
psh "$QN" "" origin main
eq   "C16: no kit.toml → .env* added in the pushed range is R2" "$PC" "1"

# ============================================================ D. shim / chaining / bypass
echo "--- D. shim, chaining, bypass"
SHIMS="$KIT_CONFIG_HOME/git-hooks"; mkdir -p "$SHIMS"
mkshims() { for h in "$@"; do sed "s/__HOOK__/$h/g" "$KIT_ROOT/plugin/guard/shim.sh" > "$SHIMS/$h"; chmod 755 "$SHIMS/$h"; done; }
mkshims pre-commit pre-push commit-msg post-commit
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$SHIMS"
KIT="python3 $KIT_ROOT/bin/kit"
# gcm <repo> [extra git args…] → GO, GC : a plain `git commit` through the GLOBAL hooksPath, with a hang timeout
gcm() { local r="$1"; shift; GO="$(cd "$r" && PATH="$GL_PATH" timeout 30 git commit -q -m t "$@" 2>&1)"; GC=$?; }
gpu() { local r="$1"; shift; GO="$(cd "$r" && PATH="$GL_PATH" timeout 30 git push -q "$@" 2>&1)"; GC=$?; }
lacks "D4: shim never resolves hooks via --git-path (it would recurse into itself)" "$(grep -v '^#' "$KIT_ROOT/plugin/guard/shim.sh")" "--git-path"
has  "D4: shim chains via --git-common-dir" "$(cat "$KIT_ROOT/plugin/guard/shim.sh")" "--git-common-dir"

printf 'kit_root = "%s"\nprofile = "full"\n' "$KIT_ROOT" > "$KIT_CONFIG_HOME/config.toml"
S1="$W/sd"; newrepo "$S1" public noproj
eq   "D4: under a global hooksPath, --git-path hooks points at the shim dir (the trap)" "$(cd "$S1" && git rev-parse --git-path hooks)" "$SHIMS"
echo a > "$S1/a.txt"; git -C "$S1" add a.txt; gcm "$S1"
eq   "D1-: configured shim → clean commit passes" "$GC" "0"
mv "$KIT_CONFIG_HOME/config.toml" "$W/cfg.off" 2>/dev/null
echo b > "$S1/b.txt"; git -C "$S1" add b.txt; gcm "$S1"
eq   "D1: config.toml missing → commit blocked" "$GC" "1"
has  "D1: …KIT GUARD: not configured" "$GO" "KIT GUARD: not configured"
printf 'kit_root = "%s"\nprofile = "full"\n' "$KIT_ROOT" > "$KIT_CONFIG_HOME/config.toml"
printf 'kit_root = "%s"\n' "$W/no-such-kit" > "$KIT_CONFIG_HOME/config.toml"; gcm "$S1"
eq   "D1: kit_root without guard scripts → blocked" "$GC" "1"
printf 'kit_root = "%s"\nprofile = "full"\n' "$KIT_ROOT" > "$KIT_CONFIG_HOME/config.toml"
gcm "$S1"
eq   "D1: config restored → passes" "$GC" "0"

printf '#!/bin/sh\necho ran > "%s/local-pc"\nexit 0\n' "$W" > "$S1/.git/hooks/pre-commit"; chmod +x "$S1/.git/hooks/pre-commit"
echo c > "$S1/c.txt"; git -C "$S1" add c.txt; rm -f "$W/local-pc"; gcm "$S1"
eq   "D2: guard passes, then the repo-local pre-commit runs" "$(cat "$W/local-pc" 2>/dev/null)" "ran"
printf '#!/bin/sh\necho local-hook-says-no >&2\nexit 3\n' > "$S1/.git/hooks/pre-commit"
echo d > "$S1/d.txt"; git -C "$S1" add d.txt; gcm "$S1"
eq   "D2: repo-local hook failure blocks the commit" "$GC" "1"
has  "D2: …its output is shown" "$GO" "local-hook-says-no"
printf 'p '"$HP"'/testuser/x\n' > "$S1/e.txt"; git -C "$S1" add e.txt; rm -f "$W/local-pc"
printf '#!/bin/sh\necho ran > "%s/local-pc"\n' "$W" > "$S1/.git/hooks/pre-commit"; gcm "$S1"
eq   "D2: guard block stops before the local hook" "$(cat "$W/local-pc" 2>/dev/null)" ""
git -C "$S1" reset -q e.txt; rm -f "$S1/e.txt"; git -C "$S1" add d.txt; gcm "$S1"
printf '#!/bin/sh\ngrep -q JIRA "$1" || { echo "commit-msg: need JIRA" >&2; exit 1; }\n' > "$S1/.git/hooks/commit-msg"; chmod +x "$S1/.git/hooks/commit-msg"
echo f > "$S1/f.txt"; git -C "$S1" add f.txt; gcm "$S1"
eq   "D10: chain-only shim runs the repo-local commit-msg hook" "$GC" "1"
has  "D10: …with its message" "$GO" "commit-msg: need JIRA"
mv "$KIT_CONFIG_HOME/config.toml" "$W/cfg.off"
GO="$(cd "$S1" && PATH="$GL_PATH" timeout 30 bash "$SHIMS/commit-msg" /dev/null 2>&1)"; GC=$?
eq   "D10: chain-only hooks do not need kit config" "$GC" "1"
lacks "D10: …and never say not configured" "$GO" "not configured"
mv "$W/cfg.off" "$KIT_CONFIG_HOME/config.toml"
rm -f "$S1/.git/hooks/commit-msg"; gcm "$S1"

git -C "$S1" worktree add -q "$W/sd-wt" -b wt 2>/dev/null
rm -f "$W/local-pc"; echo w > "$W/sd-wt/w.txt"; git -C "$W/sd-wt" add w.txt; gcm "$W/sd-wt"
eq   "D3: commit in a linked worktree passes" "$GC" "0"
eq   "D3: …and chains to the MAIN repo's hook (--git-common-dir)" "$(cat "$W/local-pc" 2>/dev/null)" "ran"
printf 'p '"$HP"'/testuser/x\n' > "$W/sd-wt/x.txt"; git -C "$W/sd-wt" add x.txt; gcm "$W/sd-wt"
eq   "D3: the guard runs in a linked worktree too" "$GC" "1"
git -C "$W/sd-wt" reset -q x.txt

ln -sf "$SHIMS/pre-commit" "$S1/.git/hooks/pre-commit"
echo g > "$S1/g.txt"; git -C "$S1" add g.txt; gcm "$S1"
eq   "D11: a repo-local hook that IS the shim does not recurse (no hang)" "$GC" "0"
rm -f "$S1/.git/hooks/pre-commit"

# pre-push: guard and the local hook both see the full stdin
rm -rf "$S1.git"; git init -q --bare "$S1.git"; git -C "$S1" remote add origin "$S1.git"
printf '#!/bin/sh\ncat > "%s/local-pp-stdin"\necho "$1 $2" > "%s/local-pp-args"\n' "$W" "$W" > "$S1/.git/hooks/pre-push"; chmod +x "$S1/.git/hooks/pre-push"
gpu "$S1" origin main wt
eq   "D7: push through the global shim passes" "$GC" "0"
eq   "D7: local pre-push got one stdin line per ref" "$(wc -l < "$W/local-pp-stdin" | tr -d ' ')" "2"
has  "D7: …in <lref> <lsha> <rref> <rsha> form" "$(cat "$W/local-pp-stdin")" "refs/heads/main $(git -C "$S1" rev-parse main) refs/heads/main 0000000000000000000000000000000000000000"
eq   "D7: …and the remote name/url args" "$(cat "$W/local-pp-args")" "origin $S1.git"

# the shim pins its own config dir: KIT_CONFIG_HOME in the commit's env cannot hide privacy.local.toml
printf 'uid 11111111-2222-3333-4444-555555555555\n' > "$S1/u.txt"; git -C "$S1" add u.txt
GO="$(cd "$S1" && KIT_CONFIG_HOME="$W/empty" PATH="$GL_PATH" timeout 30 git commit -q -m t 2>&1)"; GC=$?
eq   "D14: KIT_CONFIG_HOME override does not switch off R4" "$GC" "1"
git -C "$S1" reset -q u.txt; rm -f "$S1/u.txt"

# bypass: user-only (needs a TTY), single-use, audited, 10 minutes
mkdir -p "$S1/.claude"; echo x > "$S1/.claude/x"; git -C "$S1" add -f .claude/x
BO="$(cd "$S1" && $KIT guard bypass "agent wants it" </dev/null 2>&1)"; BC=$?
eq   "D8: bypass without a TTY is refused" "$BC" "1"
has  "D8: …as user-only" "$BO" "USER-only"
BO="$(cd "$S1" && script -qec "$KIT guard bypass ''" /dev/null 2>&1)"; BC=$?
eq   "D9: empty reason → exit 2" "$BC" "2"
BO="$(cd "$S1" && script -qec "$KIT guard bypass 'vendor fixture, reviewed'" /dev/null 2>&1)"; BC=$?
eq   "D5: bypass from a terminal → exit 0" "$BC" "0"
has  "D5: …says it is armed" "$BO" "armed"
SO="$(cd "$S1" && $KIT guard status 2>&1)"
has  "D13: status shows the active bypass" "$SO" "bypass: active"
gcm "$S1"
eq   "D5: the blocked commit goes through once" "$GC" "0"
has  "D5: …saying the bypass was consumed" "$GO" "bypass consumed — vendor fixture, reviewed"
has  "D5: audit.jsonl records the bypass" "$(cat "$AUDIT")" '"action":"bypass"'
has  "D5: …with its reason" "$(cat "$AUDIT")" '"reason":"vendor fixture, reviewed"'
mkdir -p "$S1/.claude"; echo y > "$S1/.claude/y"; git -C "$S1" add -f .claude/y; gcm "$S1"
eq   "D5: single-use — the next block blocks again" "$GC" "1"
BO="$(cd "$S1" && script -qec "$KIT guard bypass 'late'" /dev/null 2>&1)"
BF="$(ls "$KIT_STATE_HOME"/guard/bypass-* 2>/dev/null | head -1)"
[ -n "$BF" ] && sed -i -E 's/"expires": *[0-9]+/"expires": 1000/' "$BF"
gcm "$S1"
eq   "D6: an expired bypass does not apply" "$GC" "1"
[ ! -e "$BF" ] && pass "D6: …and is removed" || fail "D6: …and is removed" "still there"
BO="$(cd "$S1" && script -qec "$KIT guard bypass 'clean run'" /dev/null 2>&1)"
git -C "$S1" rm -q --cached .claude/y; echo h > "$S1/h.txt"; git -C "$S1" add h.txt; gcm "$S1"
SO="$(cd "$S1" && $KIT guard status 2>&1)"
has  "D5: a clean commit does not burn the bypass" "$SO" "bypass: active"
rm -f "$KIT_STATE_HOME"/guard/bypass-*

SO="$(cd "$S1" && PATH="$GL_PATH" $KIT guard status 2>&1)"; SC=$?
eq   "D13: guard status exit 0" "$SC" "0"
has  "D13: status shows the global hooksPath" "$SO" "hooksPath: $SHIMS"
has  "D13: status shows the repo visibility" "$SO" "visibility: public"
has  "D13: status shows privacy counts (no values)" "$SO" "1 usernames, 1 emails, 3 literals"
lacks "D13: status never prints literal values" "$SO" "11111111"
has  "D13: status shows gitleaks" "$SO" "gitleaks:"
git -C "$S1" config core.hooksPath .husky
SO="$(cd "$S1" && $KIT guard status 2>&1)"
has  "D12: status flags a repo-local core.hooksPath override" "$SO" "OVERRIDDEN"
DO="$(cd "$S1" && $KIT doctor 2>&1)"
has  "D12: kit doctor FAILs the override in the current repo" "$DO" "FAIL repo hooksPath"
git -C "$S1" config --unset core.hooksPath

# submodule: the guard runs inside it and chains to its own hooks dir
SUB="$W/subsrc"; newrepo "$SUB" none
git -C "$S1" -c protocol.file.allow=always submodule -q add "$SUB" sub >/dev/null 2>&1
git -C "$S1" -c core.hooksPath=/dev/null commit -q -m sub
printf 'p '"$HP"'/testuser/s\n' > "$S1/sub/s.txt"; git -C "$S1/sub" add s.txt; gcm "$S1/sub"
eq   "D15: guard runs inside a submodule" "$GC" "1"
git -C "$S1/sub" reset -q s.txt; rm -f "$S1/sub/s.txt"

# ============================================================ E. end-to-end: kit setup + bare remote
echo "--- E. end-to-end (kit setup, global hooksPath, bare remote)"
EM="$W/e2e"; mkdir -p "$EM/home" "$EM/fakebin"
printf '#!/bin/sh\ncase "$*" in "--version") echo "2.1.303 (Claude Code)";; *"--json"*) echo "[]";; esac\nexit 0\n' > "$EM/fakebin/claude"; chmod +x "$EM/fakebin/claude"
: > "$EM/gitconfig"
e2e() { env HOME="$EM/home" KIT_CONFIG_HOME="$EM/home/.config/kit" KIT_STATE_HOME="$EM/home/.local/state/kit" \
          GIT_CONFIG_GLOBAL="$EM/gitconfig" XDG_CONFIG_HOME="$EM/home/.config" PATH="$EM/fakebin:$GL_PATH" "$@"; }
SETUP_OUT="$(e2e python3 "$KIT_ROOT/bin/kit" setup --bin-dir "$EM/home/.local/bin" 2>&1)"
eq   "E0: kit setup sets the global hooksPath" "$(GIT_CONFIG_GLOBAL="$EM/gitconfig" git config --global core.hooksPath)" "$EM/home/.config/kit/git-hooks"
cp "$PRIV" "$EM/home/.config/kit/privacy.local.toml"; chmod 600 "$EM/home/.config/kit/privacy.local.toml"
ER="$W/e2e-repo"; rm -rf "$ER" "$ER.git"; git init -q --bare "$ER.git"; git init -q "$ER"; git -C "$ER" remote add origin "$ER.git"
printf 'kit = 5\nvisibility = "public"\n' > "$ER/kit.toml"; echo "# e2e" > "$ER/README.md"; git -C "$ER" add -A
ec() { EO2="$(cd "$ER" && e2e timeout 30 git commit -q -m "$1" 2>&1)"; EC2=$?; }
ec init
eq   "E1: a clean first commit passes (a real kit setup no longer blocks every commit)" "$EC2" "0"
if [ -n "$GITLEAKS" ]; then
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$ER/aws.txt"; git -C "$ER" add aws.txt; ec aws
  eq  "E2: fake AWS key → commit blocked" "$EC2" "1"; has "E2: [R1 secret]" "$EO2" "[R1 secret]"
  git -C "$ER" reset -q aws.txt; rm -f "$ER/aws.txt"
else skip "E2: fake AWS key" "no gitleaks"; fi
printf 'status = "active"\n' > "$ER/PROJECT.toml"; git -C "$ER" add -f PROJECT.toml; ec manifest
eq   "E3: PROJECT.toml → commit blocked" "$EC2" "1"; has "E3: [R2]" "$EO2" "[R2 forbidden-path] PROJECT.toml"
git -C "$ER" reset -q PROJECT.toml
printf 'data = "/home/%s/x"\n' "$(id -un)" > "$ER/p.txt"; git -C "$ER" add p.txt; ec path
eq   "E4: /home/<this user>/x → commit blocked" "$EC2" "1"; has "E4: [R3]" "$EO2" "[R3 local-path]"
git -C "$ER" reset -q p.txt; rm -f "$ER/p.txt"
echo "hello" > "$ER/clean.txt"; git -C "$ER" add clean.txt; ec clean
eq   "E5: clean commit passes" "$EC2" "0"
EP="$(cd "$ER" && e2e timeout 60 git push -q origin main 2>&1)"; EPC=$?
eq   "E5: clean push to the bare remote passes" "$EPC" "0"
git -C "$ER" add -f PROJECT.toml; git -C "$ER" -c core.hooksPath=/dev/null commit -q -m "long ago, before the guard"
echo "more" >> "$ER/clean.txt"; git -C "$ER" add clean.txt; ec later
git -C "$ER" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null   # PROJECT.toml reached the remote pre-guard
echo "again" >> "$ER/clean.txt"; git -C "$ER" add clean.txt; ec again
EP="$(cd "$ER" && e2e timeout 60 git push origin main 2>&1)"; EPC=$?
eq   "E6: push of a tree with a long-tracked PROJECT.toml → blocked" "$EPC" "1"
has  "E6: [R2] tree-wide" "$EP" "[R2 forbidden-path] PROJECT.toml"
eq   "E6: …and the remote did not move" "$(git -C "$ER.git" rev-parse main)" "$(git -C "$ER" rev-parse HEAD~1)"

# ============================================================ F. final-review fixes (adversarial review, Phase 4)
echo "--- F. final-review fixes"
git config --file "$GIT_CONFIG_GLOBAL" --unset core.hooksPath   # back to the explicit test hooks dir
# C1: remote-tracking refs are not what a (new / extra) push URL has
F1="$W/f1"; pushrepo "$F1" none; git -C "$F1" rm -q --cached PROJECT.toml; nc "$F1"
printf 'p '"$HP"'/testuser/x\nuid 11111111-2222-3333-4444-555555555555\n' > "$F1/old.txt"; git -C "$F1" add old.txt; nc "$F1"
git -C "$F1" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null; git -C "$F1" fetch -q origin
git -C "$F1" rm -q old.txt; nc "$F1"
rm -rf "$F1.pub.git"; git init -q --bare "$F1.pub.git"; git -C "$F1" remote set-url origin "$F1.pub.git"
psh "$F1" "" origin main
eq   "F-C1: after set-url to a new remote, history already on the OLD remote is scanned" "$PC" "1"
has  "F-C1: …finding the deleted leak" "$PO" "[R3 local-path] old.txt:1"
eq   "F-C1: …and the new remote stays empty" "$(git -C "$F1.pub.git" rev-parse -q --verify main)" ""
git -C "$F1" remote set-url origin "$F1.git"
rm -rf "$F1.pp.git"; git init -q --bare "$F1.pp.git"
git -C "$F1" remote set-url --add --push origin "$F1.git"; git -C "$F1" remote set-url --add --push origin "$F1.pp.git"
psh "$F1" "" origin main
eq   "F-C1: an extra push URL (mirror) gets the full scan" "$PC" "1"
eq   "F-C1: …and the mirror stays empty" "$(git -C "$F1.pp.git" rev-parse -q --verify main)" ""
# C2: the caller's config cannot blind the scans
F2="$W/f2"; newrepo "$F2" none
printf 'p '"$HP"'/testuser/x\n' > "$F2/a.txt"; git -C "$F2" add a.txt
CO="$(cd "$F2" && PATH="$GL_PATH" git -c core.hooksPath="$TH" -c color.ui=always -c color.diff=always -c diff.noprefix=true -c diff.mnemonicPrefix=true -c diff.relative=true commit -q -m t 2>&1)"; CC=$?
eq   "F-C2: -c color/noprefix/relative do not blind pre-commit" "$CC" "1"
git -C "$F2" reset -q a.txt
if [ -n "$GITLEAKS" ]; then
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$F2/k.txt"; git -C "$F2" add k.txt
  CO="$(cd "$F2" && PATH="$GL_PATH" git -c core.hooksPath="$TH" -c color.ui=always commit -q -m t 2>&1)"; CC=$?
  eq  "F-C2: color.ui=always does not blind R1 at commit" "$CC" "1"; has "F-C2: …R1" "$CO" "[R1 secret] k.txt:1"
  git -C "$F2" -c core.hooksPath=/dev/null commit -q -m leak
  rm -rf "$F2.git"; git init -q --bare "$F2.git"; git -C "$F2" remote add origin "$F2.git"
  PO="$(cd "$F2" && PATH="$GL_PATH" git -c core.hooksPath="$TH" -c color.ui=always -c log.showRoot=false push -q origin main 2>&1)"; PC=$?
  eq  "F-C2: color.ui=always + log.showRoot=false do not blind R1 at push" "$PC" "1"; has "F-C2: …R1 on push" "$PO" "[R1 secret] k.txt:1"
else skip "F-C2: gitleaks under hostile config" "no gitleaks"; fi
F3="$W/f3"; newrepo "$F3" none noproj; printf 'p '"$HP"'/testuser/root\n' > "$F3/r.txt"; git -C "$F3" add r.txt; git -C "$F3" -c core.hooksPath=/dev/null commit -q --amend -m root
rm -rf "$F3.git"; git init -q --bare "$F3.git"; git -C "$F3" remote add origin "$F3.git"
PO="$(cd "$F3" && PATH="$GL_PATH" git -c core.hooksPath="$TH" -c log.showRoot=false push -q origin main 2>&1)"; PC=$?
eq   "F-C2: log.showRoot=false does not hide the root commit" "$PC" "1"
has  "F-C2: …root commit content found" "$PO" "[R3 local-path] r.txt:1"
# I1: attributes from outside the tree
F4="$W/f4"; newrepo "$F4" none
printf '* -diff\n' > "$F4/.git/info/attributes"
printf 'p '"$HP"'/testuser/x\n' > "$F4/a.txt"; git -C "$F4" add a.txt; cmt "$F4"
eq   "F-I1: .git/info/attributes '* -diff' cannot hide text (commit)" "$CC" "1"
git -C "$F4" -c core.hooksPath=/dev/null commit -q -m leak; rm -rf "$F4.git"; git init -q --bare "$F4.git"; git -C "$F4" remote add origin "$F4.git"
git -C "$F4" rm -q --cached PROJECT.toml 2>/dev/null; psh "$F4" "" origin main
eq   "F-I1: …nor on push" "$PC" "1"
if [ -n "$GITLEAKS" ]; then
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$F4/k.json"; git -C "$F4" add k.json; cmt "$F4"
  has "F-I1: …nor from gitleaks (R1)" "$CO" "[R1 secret] k.json:1"; git -C "$F4" reset -q k.json
fi
rm -f "$F4/.git/info/attributes"; printf '*.json -diff\n' > "$W/gattr"
git config --file "$GIT_CONFIG_GLOBAL" core.attributesFile "$W/gattr"
printf '{"p":"'"$HP"'/testuser/x"}\n' > "$F4/c.json"; git -C "$F4" add c.json; cmt "$F4"
eq   "F-I1: a global attributes file cannot hide text" "$CC" "1"
git config --file "$GIT_CONFIG_GLOBAL" --unset core.attributesFile; git -C "$F4" reset -q c.json
# I2: commit / tag messages, file names, ref names
F5="$W/f5"; pushrepo "$F5" public; git -C "$F5" rm -q --cached PROJECT.toml; nc "$F5"; git -C "$F5" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
echo ok >> "$F5/README.md"; git -C "$F5" add README.md; git -C "$F5" -c core.hooksPath=/dev/null commit -q -m "fix: see $HP/testuser/proj/log.txt"
psh "$F5" "" origin main
eq   "F-I2: a local path in a commit MESSAGE blocks the push" "$PC" "1"
has  "F-I2: …reported as the commit message" "$PO" "[R3 local-path] (commit message)"
git -C "$F5" reset -q --hard origin/main
echo n > "$F5/notes-proj-a-secret-name.md"; git -C "$F5" add notes-proj-a-secret-name.md; cmt "$F5"
eq   "F-I2: a literal in a FILE NAME blocks the commit" "$CC" "1"
has  "F-I2: …reported as a file name" "$CO" "[R5 public-only-literal] (file name)"
git -C "$F5" reset -q notes-proj-a-secret-name.md; rm -f "$F5/notes-proj-a-secret-name.md"
psh "$F5" "" origin main:proj-a-secret-name
eq   "F-I2: a literal in the pushed REF NAME blocks" "$PC" "1"
git -C "$F5" tag -a v2 -m "built on $HP/testuser/box"
psh "$F5" "" origin v2
eq   "F-I2: a local path in an annotated TAG message blocks" "$PC" "1"
git -C "$F5" tag -d v2 >/dev/null
# I3: .gitleaksignore must be committed to count
if [ -n "$GITLEAKS" ]; then
  F6="$W/f6"; newrepo "$F6" none
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$F6/k.txt"; git -C "$F6" add k.txt
  echo "k.txt:aws-access-token:1" > "$F6/.gitleaksignore"; echo .gitleaksignore >> "$F6/.git/info/exclude"; cmt "$F6"
  eq  "F-I3: an UNTRACKED .gitleaksignore does not suppress R1" "$CC" "1"
  git -C "$F6" add -f .gitleaksignore; cmt "$F6"
  eq  "F-I3: a committed (diff-visible) .gitleaksignore fingerprint is honoured" "$CC" "0"
else skip "F-I3: .gitleaksignore" "no gitleaks"; fi
# I4: bypass forgery and PATH-shadowed gitleaks
F7="$W/f7"; newrepo "$F7" public noproj; mkdir -p "$F7/.claude"; echo x > "$F7/.claude/x"; git -C "$F7" add -f .claude/x
RID="$(printf '%s' "$F7" | sha1sum | cut -c1-12)"; mkdir -p "$KIT_STATE_HOME/guard"
printf '{"expires": %s, "reason": "forged"}\n' "$(( $(date +%s) + 300 ))" > "$KIT_STATE_HOME/guard/bypass-$RID"; cmt "$F7"
eq   "F-I4: a hand-written bypass (no matching bypass-armed audit entry) is rejected" "$CC" "1"
printf '{"expires": 9999999999, "reason": "forged"}\n' > "$KIT_STATE_HOME/guard/bypass-$RID"; cmt "$F7"
eq   "F-I4: a bypass expiring beyond 10 minutes is rejected" "$CC" "1"
BO="$(cd "$F7" && script -qec "$KIT guard bypass 'real one'" /dev/null 2>&1)"; cmt "$F7"
eq   "F-I4: a bypass armed by kit guard bypass still works" "$CC" "0"
if [ -n "$GITLEAKS" ]; then
  mkdir -p "$HOME/.local/bin" "$W/fakegl"; ln -sf "$GITLEAKS" "$HOME/.local/bin/gitleaks"
  printf '#!/bin/sh\nexit 0\n' > "$W/fakegl/gitleaks"; chmod +x "$W/fakegl/gitleaks"
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$F7/k.txt"; git -C "$F7" add k.txt; cmt "$F7" "$W/fakegl:$NOGL_PATH"
  eq  "F-I4: the pinned ~/.local/bin/gitleaks wins over a PATH-shadowing fake" "$CC" "1"
  rm -f "$HOME/.local/bin/gitleaks"; git -C "$F7" reset -q k.txt
fi
# I5: many R6 hits stay fast
F8="$W/f8"; newrepo "$F8" none
seq 1 8000 | sed 's/.*/user&@corp-mail.test,row &/' > "$F8/emails.csv"; git -C "$F8" add emails.csv
T0=$(date +%s%N); cmt "$F8"; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
eq   "F-I5: 8000-line email CSV passes (warn only)" "$CC" "0"
[ "$MS" -lt 5000 ] && pass "F-I5: …in < 5s (${MS}ms)" || fail "F-I5: 8000 R6 hits < 5s" "${MS}ms"
# M2: a path with a space keeps the line format
printf 'p '"$HP"'/testuser/x\n' > "$F8/a b.txt"; git -C "$F8" add "a b.txt"; cmt "$F8"
has  "F-M2: path with a space reported as 'a b.txt:1'" "$CO" "[R3 local-path] a b.txt:1 —"
git -C "$F8" reset -q "a b.txt"
# M3: privacy.local.toml variants the bash loader must not drop
cp "$PRIV" "$PRIV.bak"
printf 'usernames = [\n  "otheruser",\n]\nemails = []\n\n[[ literal ]]\nname = "t-spaced"\nvalue = "zz-spaced-literal"\ntier = "always"\n' > "$PRIV"
printf 'p '"$HP"'/otheruser/x\nq zz-spaced-literal\n' > "$F8/m3.txt"; git -C "$F8" add m3.txt; cmt "$F8"
has  "F-M3: multi-line usernames array is enforced" "$CO" "[R3 local-path] m3.txt:1"
has  "F-M3: '[[ literal ]]' header is enforced" "$CO" "[R4 personal-literal] m3.txt:2"
mv "$PRIV.bak" "$PRIV"; git -C "$F8" reset -q m3.txt
# ============================================================ G. review round (Codex x Fable adjudication)
echo "--- G. review-round fixes"
# O5: removing kit.toml must not switch R2 off
G1="$W/g1"; pushrepo "$G1" public noproj
git -C "$G1" rm -q kit.toml; mkdir -p "$G1/docs/plans"; echo p > "$G1/docs/plans/p.md"; git -C "$G1" add -f docs/plans/p.md; cmt "$G1"
eq   "G-O5: commit that drops kit.toml + adds docs/plans → blocked (kit.toml read from HEAD)" "$CC" "1"
has  "G-O5: …R2 on the plan" "$CO" "[R2 forbidden-path] docs/plans/p.md"
has  "G-O5: …and a kit.toml-removed warning" "$CO" "[R2 kit.toml-removed]"
git -C "$G1" rm -q --cached docs/plans/p.md; cmt "$G1"
eq   "G-O5: dropping kit.toml alone commits (warned)" "$CC" "0"
has  "G-O5: …with the warning" "$CO" "WARN [R2 kit.toml-removed]"
git -C "$G1" add -f docs/plans/p.md; nc "$G1"
psh "$G1" "" origin main
eq   "G-O5: push of a tip without kit.toml (remote had it) → blocked" "$PC" "1"
has  "G-O5: …kit.toml removal is a BLOCK at push" "$PO" "BLOCKED [R2 kit.toml-removed] kit.toml"
has  "G-O5: …and R2 still runs tree-wide" "$PO" "[R2 forbidden-path] docs/plans/p.md"
eq   "G-O5: …remote unchanged" "$(git -C "$G1.git" rev-parse main)" "$(git -C "$G1" rev-parse HEAD~2)"
psh "$G1" "" origin main:newbr
eq   "G-O5: new branch (no remote old tip) whose range drops kit.toml → blocked" "$PC" "1"
has  "G-O5: …found via the range" "$PO" "[R2 kit.toml-removed]"
G2="$W/g2"; newrepo "$G2" public noproj; git -C "$G2" rm -q kit.toml; nc "$G2"; echo x >> "$G2/README.md"; git -C "$G2" add README.md; nc "$G2"
rm -rf "$G2.git"; git init -q --bare "$G2.git"; git -C "$G2" remote add origin "$G2.git"
psh "$G2" "" origin main
eq   "G-O5: first push of a history whose root had kit.toml → blocked" "$PC" "1"
G3="$W/g3"; pushrepo "$G3" none noproj; echo y >> "$G3/README.md"; git -C "$G3" add README.md; nc "$G3"
psh "$G3" "" origin main
eq   "G-O5: a repo that never had kit.toml pushes normally" "$PC" "0"
RID="$(printf '%s' "$G1" | sha1sum | cut -c1-12)"
BO="$(cd "$G1" && script -qec "$KIT guard bypass 'retire kit here'" /dev/null 2>&1)"
git -C "$G1" rm -q --cached docs/plans/p.md; nc "$G1"
psh "$G1" "" origin main
eq   "G-O5: a user bypass lets an intended kit.toml removal through" "$PC" "0"

# F4: .env* — .env and .env.<name> stay local; templates (last suffix example/sample/
# template/dist/defaults) are fine; .envrc is a warning; tree-wide only in kit repos
G4="$W/g4"; newrepo "$G4" public noproj
for f in .env.sample .env.template .env.dist .env.defaults .env.local.example sub/.env.example .environment; do
  mkdir -p "$G4/$(dirname "$f")"; echo "K=" > "$G4/$f"; git -C "$G4" add -f "$f"; cmt "$G4"
  eq "G-F4: $f commits" "$CC" "0"
done
for f in .env .env.test .env.development .env.production .env.local .env.sample.local sub/.env.test; do
  mkdir -p "$G4/$(dirname "$f")"; echo "K=v" > "$G4/$f"; git -C "$G4" add -f "$f"; cmt "$G4"
  has "G-F4: $f blocked [R2]" "$CO" "[R2 forbidden-path] $f"; git -C "$G4" rm -q --cached "$f"
done
echo 'export A=1' > "$G4/.envrc"; git -C "$G4" add -f .envrc; cmt "$G4"
eq   "G-F4: .envrc commits (direnv)" "$CC" "0"
has  "G-F4: …with a warning" "$CO" "WARN [R2 env-file] .envrc"
printf 'kit = 5\nvisibility = "public"\n\n[privacy]\nallow_paths = [".env.test"]\n' > "$G4/kit.toml"
echo "K=v" > "$G4/.env.test"; git -C "$G4" add -f kit.toml .env.test; cmt "$G4"
eq   "G-F4: kit.toml allow_paths lets .env.test through" "$CC" "0"
G5="$W/g5"; pushrepo "$G5" none noproj
echo "K=v" > "$G5/.env.test"; git -C "$G5" add -f .env.test; nc "$G5"; git -C "$G5" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
echo z >> "$G5/README.md"; git -C "$G5" add README.md; nc "$G5"
psh "$G5" "" origin main
eq   "G-F4: non-kit repo: a long-tracked .env.test is not re-blocked tree-wide" "$PC" "0"
echo "K=v" > "$G5/.env.production"; git -C "$G5" add -f .env.production; nc "$G5"
psh "$G5" "" origin main
eq   "G-F4: non-kit repo: a NEW .env.production in the range blocks" "$PC" "1"
has  "G-F4: …as R2" "$PO" "[R2 forbidden-path] .env.production"
git -C "$G5" reset -q --hard origin/main
G6="$W/g6"; pushrepo "$G6" public noproj
echo "K=v" > "$G6/.env.test"; git -C "$G6" add -f .env.test; nc "$G6"; git -C "$G6" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
echo z >> "$G6/README.md"; git -C "$G6" add README.md; nc "$G6"
psh "$G6" "" origin main
eq   "G-F4: kit repo: a long-tracked .env.test is still blocked tree-wide" "$PC" "1"
GI="$W/gi"; rm -rf "$GI"; git init -q "$GI"; cp "$KIT_ROOT/plugin/templates/gitignore" "$GI/.gitignore"
for f in .env .env.local .env.test .env.production; do
  git -C "$GI" check-ignore -q "$f" && pass "G-F4: template .gitignore ignores $f" || fail "G-F4: template .gitignore ignores $f" "not ignored"
done
for f in .env.example .env.sample .env.template .env.dist .env.defaults .env.local.example .envrc; do
  git -C "$GI" check-ignore -q "$f" && fail "G-F4: template .gitignore keeps $f addable" "ignored" || pass "G-F4: template .gitignore keeps $f addable"
done

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT, skipped $SKIP_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
