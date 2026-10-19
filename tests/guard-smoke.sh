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


# ============================================================ B. pre-commit
echo "--- B. pre-commit"
TH="$W/th"; mkdir -p "$TH"   # test hooks dir: straight to plugin/guard (the real shim is section D)
for h in pre-commit pre-push; do printf '#!/usr/bin/env bash\nexec bash "%s/%s.sh" "$@"\n' "$GUARD" "$h" > "$TH/$h"; chmod +x "$TH/$h"; done
# PATH without gitleaks (drop any PATH dir that has one) / with the pinned one first
NOGL_PATH=""; IFS=: read -ra _pp <<< "$PATH"
for d in "${_pp[@]}"; do [ -x "$d/gitleaks" ] || NOGL_PATH="${NOGL_PATH:+$NOGL_PATH:}$d"; done
mkdir -p "$W/glbin"; [ -n "$GITLEAKS" ] && ln -sf "$GITLEAKS" "$W/glbin/gitleaks"
GL_PATH="$W/glbin:$NOGL_PATH"
AUDIT="$KIT_STATE_HOME/guard/audit.jsonl"

# newrepo <dir> [visibility|none]: repo with an initial commit made WITHOUT hooks
# (PROJECT.toml tracked from the start, like a v4 repo); kit.toml unless "none"
newrepo() {
  rm -rf "$1"; git init -q "$1"
  printf 'status = "active"\n' > "$1/PROJECT.toml"; echo "# r" > "$1/README.md"
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

printf 'ok\npath = "/home/testuser/x"\n' > "$R/c.txt"; git -C "$R" add c.txt; cmt "$R"
eq   "B3: /home/testuser/ → exit 1" "$CC" "1"
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
printf '*.txt binary\n' > "$R/.gitattributes"; printf 'x /home/testuser/y\n' > "$R/hid.txt"; git -C "$R" add .gitattributes hid.txt; cmt "$R"
has  "B10: .gitattributes 'binary' cannot hide text from the guard" "$CO" "[R3 local-path] hid.txt:1"
git -C "$R" reset -q hid.txt; rm -f "$R/hid.txt"; git -C "$R" add .gitattributes; cmt "$R"

printf 'WORKDIR /home/node/app\n' > "$R/Dockerfile"; git -C "$R" add Dockerfile; cmt "$R"
eq   "B16: /home/node warns but passes" "$CC" "0"
has  "B16: warn line format" "$CO" "KIT GUARD WARN [R3b other-home-path] Dockerfile:1"

printf 'echo /home/testuser/old\n' > "$R/old.sh"; git -C "$R" add old.sh; git -C "$R" -c core.hooksPath=/dev/null commit -q -m "pre-guard"
git -C "$R" mv old.sh renamed.sh; cmt "$R"
eq   "B17: pure rename of pre-existing content is not re-flagged (only added lines)" "$CC" "0"
printf 'echo /home/testuser/new\n' >> "$R/renamed.sh"; cmt "$R"
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
printf 'p /home/testuser/x\n' > "$N/n.txt"; git -C "$N" add n.txt; cmt "$N"
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
echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT, skipped $SKIP_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
