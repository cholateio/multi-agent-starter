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

# review O9: the inline marker covers WARN-level rules only (R3b/R6/R7); block-level
# exceptions go through kit.toml (allow_literals by name / allow_paths)
eng public "" "uid: 11111111-2222-3333-4444-555555555555 $HP/testuser/ # kit-privacy: allow"
has  "A9: marker does not exempt an always literal (R4)" "$EO" $'BLOCK\tR4 personal-literal'
has  "A9: marker does not exempt a configured user path (R3)" "$EO" $'BLOCK\tR3 local-path'
has  "A9: …and the block says why" "$EO" "warn-level rules only"
eng public "" "name proj-a-secret-name # kit-privacy: allow"
has  "A9: marker does not exempt a public-only literal (R5)" "$EO" $'BLOCK\tR5 public-only-literal'
eng public "" "mail a.person@corp-mail.dev # kit-privacy: allow"
lacks "A9: marker suppresses the R6 email warning" "$EO" $'WARN\tR6 email'
has  "A9: …but the consumed marker is reported" "$EO" $'WARN\tR6 allow-marker\tf.txt:1'
eq   "A9: …exit 0" "$EC" "0"
eng public "" "WORKDIR $HP/node/app # kit-privacy: allow"
has  "A9: R3b consumed marker reported" "$EO" $'WARN\tR3b allow-marker'
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
# the pinned osv-scanner next to it, so kit setup in section E records it instead of downloading
[ -n "${KIT_TOOLS:-}" ] && [ -x "${KIT_TOOLS}/osv-scanner" ] && ln -sf "$KIT_TOOLS/osv-scanner" "$W/glbin/osv-scanner"
if [ -n "$GITLEAKS" ]; then ln -sf "$GITLEAKS" "$W/glbin/gitleaks"
else printf '#!/bin/sh\nexit 0\n' > "$W/glbin/gitleaks"; chmod +x "$W/glbin/gitleaks"; fi   # no real gitleaks: a clean stand-in (R1 assertions SKIP)
GL_PATH="$W/glbin:$NOGL_PATH"
AUDIT="$KIT_STATE_HOME/guard/audit.jsonl"
# glsel <PATH>: the guard never resolves gitleaks from PATH (review R3-1), only from
# config.toml tools_dir / gitleaks_path — so the test's "which gitleaks" choice is made
# there: GL_PATH → glbin, NOGL_PATH → an empty dir, crashgl → crashgl; any other PATH
# → no tools_dir line (the default ~/.local/bin)
mkdir -p "$W/nogl"
glsel() {
  local cfg="${KIT_GUARD_CONFIG_DIR:-$KIT_CONFIG_HOME}/config.toml" sel=""
  case "$1" in
    "$GL_PATH") sel="$W/glbin" ;; "$NOGL_PATH") sel="$W/nogl" ;; "$W/crashgl:$NOGL_PATH") sel="$W/crashgl" ;;
  esac
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"
  # …and, like kit setup / doctor --install, the binary's sha256 (review R4-1: the guard runs
  # only a gitleaks whose sha256 equals config.toml gitleaks_sha256): the selected one, else glbin's
  local shaf="$W/glbin/gitleaks"; [ -n "$sel" ] && [ -x "$sel/gitleaks" ] && shaf="$sel/gitleaks"
  local sha; sha="$(sha256sum < "$shaf" | cut -d' ' -f1)"
  { [ -n "$sel" ] && printf 'tools_dir = "%s"\n' "$sel"; printf 'gitleaks_sha256 = "%s"\n' "$sha"
    grep -v -e '^tools_dir' -e '^gitleaks_sha256' "$cfg"; } > "$cfg.new"; mv "$cfg.new" "$cfg"
}

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
  glsel "${2:-$GL_PATH}"
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
  glsel "$p"
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
gcm() { local r="$1"; shift; glsel "$GL_PATH"; GO="$(cd "$r" && PATH="$GL_PATH" timeout 30 git commit -q -m t "$@" 2>&1)"; GC=$?; }
gpu() { local r="$1"; shift; glsel "$GL_PATH"; GO="$(cd "$r" && PATH="$GL_PATH" timeout 30 git push -q "$@" 2>&1)"; GC=$?; }
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
e2e() { env https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
          HOME="$EM/home" KIT_CONFIG_HOME="$EM/home/.config/kit" KIT_STATE_HOME="$EM/home/.local/state/kit" \
          GIT_CONFIG_GLOBAL="$EM/gitconfig" XDG_CONFIG_HOME="$EM/home/.config" PATH="$EM/fakebin:$GL_PATH" "$@"; }
SETUP_OUT="$(e2e python3 "$KIT_ROOT/bin/kit" setup --bin-dir "$EM/home/.local/bin" 2>&1)"
eq   "E0: kit setup sets the global hooksPath" "$(GIT_CONFIG_GLOBAL="$EM/gitconfig" git config --global core.hooksPath)" "$EM/home/.config/kit/git-hooks"
if [ -z "$GITLEAKS" ]; then   # no real gitleaks: record the clean stand-in the way setup records the pin (tests never download)
  mkdir -p "$EM/home/.local/bin"; cp "$W/glbin/gitleaks" "$EM/home/.local/bin/gitleaks"
  { printf 'gitleaks_sha256 = "%s"\n' "$(sha256sum < "$W/glbin/gitleaks" | cut -d' ' -f1)"; cat "$EM/home/.config/kit/config.toml"; } > "$EM/c.new"
  mv "$EM/c.new" "$EM/home/.config/kit/config.toml"
fi
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
for f in .env.example .env.sample .env.template .env.dist .env.defaults .env.local.example .env.local.dist .env.test.defaults .envrc; do
  git -C "$GI" check-ignore -q "$f" && fail "G-F4: template .gitignore keeps $f addable" "ignored" || pass "G-F4: template .gitignore keeps $f addable"
done

# O9: consumed allow markers are never silent (WARN + audit.jsonl)
G7="$W/g7"; newrepo "$G7" public noproj
echo 'contact a.person@corp-mail.dev # kit-privacy: allow' > "$G7/m.txt"; git -C "$G7" add m.txt; cmt "$G7"
eq   "G-O9: warn-level hit with a marker commits" "$CC" "0"
has  "G-O9: …and prints the consumed marker" "$CO" "KIT GUARD WARN [R6 allow-marker] m.txt:1"
has  "G-O9: …and logs it to audit.jsonl" "$(cat "$AUDIT")" '"action":"allow-marker"'
printf 'p '"$HP"'/testuser/x # kit-privacy: allow\n' > "$G7/b.txt"; git -C "$G7" add b.txt; cmt "$G7"
eq   "G-O9: block-level hit with a marker is still blocked" "$CC" "1"
has  "G-O9: …R3" "$CO" "[R3 local-path] b.txt:1"
printf 'kit = 5\nvisibility = "public"\n\n[privacy]\nallow_paths = ["b.txt"]\n' > "$G7/kit.toml"; git -C "$G7" add kit.toml b.txt; cmt "$G7"
eq   "G-O9: the kit.toml allow_paths route still works for block-level rules" "$CC" "0"

# F8: per-rule cap keeps a pathological warn-only file fast; ls-remote cannot stall a push
G8="$W/g8"; newrepo "$G8" none noproj
seq 1 200000 | sed 's/.*/user&@corp-mail.test,row &/' > "$G8/big.csv"; git -C "$G8" add big.csv
T0=$(date +%s%N); cmt "$G8"; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
eq   "G-F8: 200k-line email CSV commits (warn only)" "$CC" "0"
[ "$MS" -lt 6000 ] && pass "G-F8: …in < 6s (${MS}ms)" || fail "G-F8: 200k R6 hits < 6s" "${MS}ms"
has  "G-F8: …the rest is counted, not listed" "$CO" "more line(s)"
printf 'p '"$HP"'/testuser/a\n%.0s' $(seq 1 120) > "$G8/many.txt"; git -C "$G8" add many.txt; cmt "$G8"
eq   "G-F8: capped block-level rule still blocks" "$CC" "1"
git -C "$G8" reset -q many.txt; git -C "$G8" reset -q big.csv
mkdir -p "$W/slowssh"; printf '#!/bin/sh\nsleep 30\n' > "$W/slowssh/ssh"; chmod +x "$W/slowssh/ssh"
G9="$W/g9"; newrepo "$G9" none noproj
SHA="$(git -C "$G9" rev-parse HEAD)"
T0=$(date +%s%N)
PO="$(cd "$G9" && printf 'refs/heads/main %s refs/heads/main %s\n' "$SHA" 0000000000000000000000000000000000000000 \
      | PATH="$GL_PATH" GIT_SSH_COMMAND="$W/slowssh/ssh" bash "$GUARD/pre-push.sh" origin ssh://kit.invalid/x.git 2>&1)"; PC=$?
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[ "$MS" -lt 9000 ] && pass "G-F8: unreachable push URL gives up quickly (${MS}ms)" || fail "G-F8: ls-remote timeout" "${MS}ms"
has  "G-F8: …and says it falls back to a full-history scan" "$PO" "scanning the full history"
eq   "G-F8: …clean history still passes" "$PC" "0"

# O3/F13: the guard finds gitleaks in config.toml tools_dir (kit setup --bin-dir), off PATH
G10="$W/g10"; newrepo "$G10" none noproj; mkdir -p "$W/customtools"; cp -P "$W/glbin/gitleaks" "$W/customtools/gitleaks"
glsel default; cp "$KIT_CONFIG_HOME/config.toml" "$W/cfg.bak" 2>/dev/null || : > "$W/cfg.bak"
printf 'tools_dir = "%s"\n' "$W/customtools" >> "$KIT_CONFIG_HOME/config.toml"
echo ok > "$G10/ok.txt"; git -C "$G10" add ok.txt
CO="$(cd "$G10" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" commit -q -m t 2>&1)"; CC=$?
eq   "G-F13: gitleaks in tools_dir (not on PATH) → commit passes" "$CC" "0"
lacks "G-F13: …and no R8 gitleaks-missing" "$CO" "R8 gitleaks-missing"
cp "$W/cfg.bak" "$KIT_CONFIG_HOME/config.toml"

# ============================================================ H. round-3 review fixes
echo "--- H. round-3 review fixes"
# R3-1: a fake gitleaks on the caller's PATH is never run — the guard resolves it ONLY from
# config.toml tools_dir / an absolute gitleaks_path recorded by kit setup / doctor --install
mkdir -p "$W/fakepath"; printf '#!/bin/sh\ntouch "%s/fake-gl-ran"\nexit 0\n' "$W" > "$W/fakepath/gitleaks"; chmod +x "$W/fakepath/gitleaks"
H1="$W/h1"; pushrepo "$H1" none noproj
printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$H1/k.txt"; git -C "$H1" add k.txt; nc "$H1"
h1fresh() { rm -rf "$H1.git"; git init -q --bare "$H1.git"; git -C "$H1" -c core.hooksPath=/dev/null push -q origin main~1:refs/heads/main 2>/dev/null; }
h1fresh; glsel "$NOGL_PATH"; rm -f "$W/fake-gl-ran"
PO="$(cd "$H1" && PATH="$W/fakepath:$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
eq   "H-R3-1: fake gitleaks on PATH + nothing in tools_dir → push blocked" "$PC" "1"
has  "H-R3-1: …as R8 (the PATH binary is not the guard's)" "$PO" "[R8 gitleaks-missing]"
absent_f() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "exists $2"; fi; }
absent_f "H-R3-1: …and the fake was never executed" "$W/fake-gl-ran"
if [ -n "$GITLEAKS" ]; then
  h1fresh; glsel "$GL_PATH"; rm -f "$W/fake-gl-ran"
  PO="$(cd "$H1" && PATH="$W/fakepath:$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
  eq  "H-R3-1: fake gitleaks first on PATH + real one in tools_dir → push blocked" "$PC" "1"
  has "H-R3-1: …by R1 (the real scan ran)" "$PO" "[R1 secret] k.txt:1"
  absent_f "H-R3-1: …fake never executed" "$W/fake-gl-ran"
  h1fresh; glsel "$NOGL_PATH"; printf 'gitleaks_path = "%s"\n' "$GITLEAKS" >> "$KIT_CONFIG_HOME/config.toml"
  PO="$(cd "$H1" && PATH="$W/fakepath:$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
  eq  "H-R3-1: a recorded absolute gitleaks_path is used (tools_dir empty)" "$PC" "1"
  has "H-R3-1: …R1 found the key" "$PO" "[R1 secret] k.txt:1"
else skip "H-R3-1: real gitleaks via tools_dir / gitleaks_path" "no gitleaks"; fi
glsel "$NOGL_PATH"; grep -v '^gitleaks_path' "$KIT_CONFIG_HOME/config.toml" > "$W/c.new"; mv "$W/c.new" "$KIT_CONFIG_HOME/config.toml"
printf 'gitleaks_path = "fakepath/gitleaks"\n' >> "$KIT_CONFIG_HOME/config.toml"; h1fresh
PO="$(cd "$W" && cd "$H1" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
has  "H-R3-1: a RELATIVE gitleaks_path is ignored (R8)" "$PO" "[R8 gitleaks-missing]"
grep -v '^gitleaks_path' "$KIT_CONFIG_HOME/config.toml" > "$W/c.new"; mv "$W/c.new" "$KIT_CONFIG_HOME/config.toml"

# R3-2: removing kit.toml by NOT having it — (a) an orphan branch whose history never had it
# (Fable N1), (b) a force-push of unrelated kit-less history over a remote tip that is not
# present locally (Codex) — must not switch R2 off
H2="$W/h2"; pushrepo "$H2" public; git -C "$H2" rm -q --cached PROJECT.toml; rm -f "$H2/PROJECT.toml"; nc "$H2"
git -C "$H2" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
git -C "$H2" checkout -q --orphan dump; git -C "$H2" rm -r -q --cached .; rm -f "$H2/kit.toml"
mkdir -p "$H2/.claude"; echo '{}' > "$H2/.claude/settings.local.json"; printf 'status = "x"\n' > "$H2/PROJECT.toml"
git -C "$H2" add -f .claude/settings.local.json PROJECT.toml; cmt "$H2"
eq   "H-R3-2a: orphan-branch commit of .claude/ + PROJECT.toml in a kit repo → blocked" "$CC" "1"
has  "H-R3-2a: …R2 (kit status from the local branch tips)" "$CO" "[R2 forbidden-path] .claude/settings.local.json"
nc "$H2" dump
psh "$H2" "" origin dump
eq   "H-R3-2a: orphan-branch dump push → blocked" "$PC" "1"
has  "H-R3-2a: …R2 on PROJECT.toml" "$PO" "[R2 forbidden-path] PROJECT.toml"
eq   "H-R3-2a: …remote has no dump branch" "$(git -C "$H2.git" rev-parse -q --verify refs/heads/dump)" ""
git -C "$H2" checkout -q -f main; git -C "$H2" branch -q -D dump
git -C "$H2" checkout -q --orphan gh-pages; git -C "$H2" rm -r -q --cached .; rm -f "$H2/kit.toml"
echo '<p>site</p>' > "$H2/index.html"; git -C "$H2" add index.html; cmt "$H2"
eq   "H-R3-2: legit orphan gh-pages commit in a kit repo passes" "$CC" "0"
psh "$H2" "" origin gh-pages
eq   "H-R3-2: …and pushes" "$PC" "0"
git -C "$H2" checkout -q -f main
# (b) a fresh clone-less repo force-pushes kit-less history over the remote's unfetched kit tip
H3="$W/h3"; rm -rf "$H3"; git init -q "$H3"; git -C "$H3" remote add origin "$H2.git"
mkdir -p "$H3/.claude"; echo '{}' > "$H3/.claude/settings.local.json"; printf 'status = "x"\n' > "$H3/PROJECT.toml"
git -C "$H3" add -f .claude PROJECT.toml; nc "$H3" unrelated
psh "$H3" "" -f origin main
eq   "H-R3-2b: force-push of kit-less history over an UNFETCHED kit remote tip → blocked" "$PC" "1"
has  "H-R3-2b: …as a kit.toml removal" "$PO" "BLOCKED [R2 kit.toml-removed]"
has  "H-R3-2b: …and R2 runs" "$PO" "[R2 forbidden-path] .claude/settings.local.json"
eq   "H-R3-2b: …remote main unchanged" "$(git -C "$H2.git" rev-parse main)" "$(git -C "$H2" rev-parse main)"
eq   "H-R3-2b: …no temporary refs left behind" "$(git -C "$H3" for-each-ref refs/kit-guard/)" ""
psh "$H3" "" origin main:refs/heads/side
eq   "H-R3-2b: new branch of kit-less history to a kit remote (unfetched HEAD) → blocked" "$PC" "1"
has  "H-R3-2b: …R2" "$PO" "[R2 forbidden-path] PROJECT.toml"
# fail closed: an advertised tip that cannot be fetched
H4="$W/h4"; rm -rf "$H4" "$H4.git"; git init -q --bare "$H4.git"; git init -q "$H4"; echo a > "$H4/a"; git -C "$H4" add a; nc "$H4"
git -C "$H4" -c core.hooksPath=/dev/null push -q "$H4.git" main 2>/dev/null
H5="$W/h5"; rm -rf "$H5"; git init -q "$H5"; git -C "$H5" remote add origin "$H4.git"; echo b > "$H5/b"; git -C "$H5" add b; nc "$H5"
# the remote lists its refs but serves no objects (upload-pack's pack step fails); push still works
git config --file "$GIT_CONFIG_GLOBAL" uploadpack.packObjectsHook false
psh "$H5" "" -f origin main
git config --file "$GIT_CONFIG_GLOBAL" --unset uploadpack.packObjectsHook
eq   "H-R3-2c: an advertised remote tip that cannot be inspected → blocked (fail closed)" "$PC" "1"
has  "H-R3-2c: …says why" "$PO" "[R2 kit-status-unknown]"
eq   "H-R3-2c: …remote unchanged" "$(git -C "$H4.git" rev-parse main)" "$(git -C "$H4" rev-parse main)"
# legit pushes that must still pass
H6="$W/h6"; pushrepo "$H6" none noproj; git -C "$H6" -c core.hooksPath=/dev/null push -q origin main:refs/heads/other 2>/dev/null
H7="$W/h7"; rm -rf "$H7"; git init -q "$H7"; git -C "$H7" remote add origin "$H6.git"; echo c > "$H7/c"; git -C "$H7" add c; nc "$H7"
psh "$H7" "" origin main:refs/heads/fresh
eq   "H-R3-2: a non-kit repo pushing next to unfetched NON-kit remote branches passes" "$PC" "0"
eq   "H-R3-2: …no temporary refs left behind" "$(git -C "$H7" for-each-ref refs/kit-guard/)" ""
psh "$H7" "" -f origin main
eq   "H-R3-2: force-push in a repo that never had kit.toml passes" "$PC" "0"
echo more >> "$H2/README.md"; git -C "$H2" add README.md; nc "$H2"; git -C "$H2" checkout -q -b feat2
psh "$H2" "" origin feat2
eq   "H-R3-2: new branch in a kit repo passes" "$PC" "0"
git -C "$H2" commit -q --amend -m amended --no-verify
psh "$H2" "" -f origin feat2
eq   "H-R3-2: force-push in a kit repo passes" "$PC" "0"
rm -rf "$W/h8"; git init -q "$W/h8"; echo n > "$W/h8/n"; git -C "$W/h8" add n; cmt "$W/h8"
eq   "H-R3-2: first commit in a brand-new non-kit repo passes" "$CC" "0"

# ============================================================ I. round-4 review fixes
echo "--- I. round-4 review fixes"
# R4-1: scanner trust = content hash. (a) kit setup with a version-spoofing stub FIRST on PATH
# never records it; (b) a stub copied / linked over the hash-recorded tools_dir binary is R8
# "binary replaced" (push blocked), and never runs
mkdir -p "$W/spoof"; printf '#!/bin/sh\ntouch "%s/spoof-ran"\necho 8.30.1\nexit 0\n' "$W" > "$W/spoof/gitleaks"; chmod +x "$W/spoof/gitleaks"
I1="$W/i1home"; rm -rf "$I1"; mkdir -p "$I1/home"; : > "$I1/gitconfig"; rm -f "$W/spoof-ran"
i1() { env https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HOME="$I1/home" KIT_CONFIG_HOME="$I1/home/.config/kit" \
         KIT_STATE_HOME="$I1/home/.local/state/kit" KIT_CACHE_HOME="$I1/home/.cache/kit" GIT_CONFIG_GLOBAL="$I1/gitconfig" \
         XDG_CONFIG_HOME="$I1/home/.config" PATH="$EM/fakebin:$W/spoof:$GL_PATH" "$@"; }
I1OUT="$(i1 python3 "$KIT_ROOT/bin/kit" setup 2>&1)"
I1CFG="$(cat "$I1/home/.config/kit/config.toml" 2>/dev/null)"
lacks "H-R4-1a: kit setup never records a version-spoofing PATH stub" "$I1CFG" "$W/spoof/gitleaks"
has   "H-R4-1a: …and says it is not the pinned build" "$I1OUT" "not the pinned gitleaks"
I1DOC="$(i1 python3 "$KIT_ROOT/bin/kit" doctor --install 2>&1)"
lacks "H-R4-1a: kit doctor --install does not record it either" "$(cat "$I1/home/.config/kit/config.toml")" "$W/spoof/gitleaks"
if [ -n "$GITLEAKS" ]; then
  has "H-R4-1a: …the real pinned gitleaks (same sha256) is recorded instead" "$(cat "$I1/home/.config/kit/config.toml")" "gitleaks_sha256 = \"$(sha256sum < "$GITLEAKS" | cut -d' ' -f1)\""
  I1R="$W/i1repo"; rm -rf "$I1R"; git init -q "$I1R"; printf 'kit = 5\nvisibility = "public"\n' > "$I1R/kit.toml"
  printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$I1R/k.txt"; git -C "$I1R" add -A
  CO="$(cd "$I1R" && i1 git commit -q -m t 2>&1)"; CC=$?
  eq  "H-R4-1a: commit with an AWS key after that setup → blocked by R1" "$CC" "1"
  has "H-R4-1a: …R1" "$CO" "[R1 secret] k.txt:1"
else skip "H-R4-1a: real gitleaks recorded by setup" "no gitleaks"; fi
absent_f "H-R4-1a: the spoofing stub never ran (setup, doctor, commit)" "$W/spoof-ran"
# (b) replaced in place
mkdir -p "$W/trusted"; cp "$W/glbin/gitleaks" "$W/trusted/gitleaks"; chmod +x "$W/trusted/gitleaks"
I2="$W/i2"; pushrepo "$I2" none noproj
printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$I2/k.txt"; git -C "$I2" add k.txt
i2sel() { glsel default; grep -v '^tools_dir' "$KIT_CONFIG_HOME/config.toml" > "$W/c.new"
          { printf 'tools_dir = "%s"\n' "$W/trusted"; cat "$W/c.new"; } > "$KIT_CONFIG_HOME/config.toml"; }
i2sel
cp "$W/spoof/gitleaks" "$W/trusted/gitleaks"; rm -f "$W/spoof-ran"
CO="$(cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" commit -q -m t 2>&1)"; CC=$?
has  "H-R4-1b: stub copied over tools_dir/gitleaks → commit warns R8" "$CO" "[R8 gitleaks-missing]"
has  "H-R4-1b: …binary replaced" "$CO" "gitleaks binary replaced"
nc "$I2" 2>/dev/null
PO="$(cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
eq   "H-R4-1b: …push blocked" "$PC" "1"
has  "H-R4-1b: …as R8 binary replaced" "$PO" "gitleaks binary replaced"
absent_f "H-R4-1b: …the stub never ran" "$W/spoof-ran"
ln -sf /bin/true "$W/trusted/gitleaks"
PO="$(cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
eq   "H-R4-1b: ln -sf /bin/true over it → push blocked" "$PC" "1"
has  "H-R4-1b: …binary replaced" "$PO" "gitleaks binary replaced"
rm -f "$W/trusted/gitleaks"; cp "$W/glbin/gitleaks" "$W/trusted/gitleaks"; chmod +x "$W/trusted/gitleaks"
grep -v '^gitleaks_sha256' "$KIT_CONFIG_HOME/config.toml" > "$W/c.new"; mv "$W/c.new" "$KIT_CONFIG_HOME/config.toml"
PO="$(cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
eq   "H-R4-1b: no gitleaks_sha256 recorded → push blocked" "$PC" "1"
has  "H-R4-1b: …says so" "$PO" "no gitleaks_sha256 recorded"
i2sel
PO="$(cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
eq   "H-R4-1b: the hash-equal binary restored → push scans again (blocked by R1 or passes without real gitleaks)" "$PC" "$([ -n "$GITLEAKS" ] && echo 1 || echo 0)"
lacks "H-R4-1b: …no R8" "$PO" "R8 gitleaks-missing"

# R5-1: the scanner's hash never goes through a caller-defined command: an exported fake
# sha256sum / shasum / openssl printing the recorded pin cannot vouch for a replaced stub,
# and exported cat / bash functions cannot blind the shim (empty stdin / no guard run)
i2sel; cp "$W/spoof/gitleaks" "$W/trusted/gitleaks"; rm -f "$W/spoof-ran"
echo r5 >> "$I2/r5.txt"; git -C "$I2" add r5.txt; nc "$I2"
PIN="$(sed -nE 's/^gitleaks_sha256 = "(.*)"$/\1/p' "$KIT_CONFIG_HOME/config.toml")"; export PIN
PO="$(sha256sum() { printf '%s  -\n' "$PIN"; }; shasum() { sha256sum; }; openssl() { printf '%s *stdin\n' "$PIN"; }
      export -f sha256sum shasum openssl; cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$TH" push -q origin main 2>&1)"; PC=$?
eq   "R5-1: replaced scanner + exported fake sha256sum printing the pin → push blocked" "$PC" "1"
has  "R5-1: …as R8 binary replaced" "$PO" "gitleaks binary replaced"
absent_f "R5-1: …the stub never ran" "$W/spoof-ran"
for fn in cat bash; do
  PO="$(eval "$fn() { :; }"; export -f "$fn"; cd "$I2" && PATH="$NOGL_PATH" git -c core.hooksPath="$SHIMS" push -q origin main 2>&1)"; PC=$?
  eq   "R5-1: exported '$fn' function cannot switch the guard off through the shim (push blocked)" "$PC" "1"
  has  "R5-1: …R8 binary replaced ($fn)" "$PO" "gitleaks binary replaced"
done
absent_f "R5-1: …the stub never ran (shim)" "$W/spoof-ran"
i2sel

# R4-2: the remote's old tip (non-zero rsha) is not here and the HOOK's own connection fails
# (passphrase key without agent, auth prompt…) while the push transport works: fail closed
mkdir -p "$W/faketo"; printf '#!/bin/sh\nexit 124\n' > "$W/faketo/timeout"; chmod +x "$W/faketo/timeout"
K="$W/k"; pushrepo "$K" public; git -C "$K" rm -q --cached PROJECT.toml; rm -f "$K/PROJECT.toml"; nc "$K"
git -C "$K" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
J="$W/j"; rm -rf "$J"; git init -q "$J"; git -C "$J" remote add origin "$K.git"
mkdir -p "$J/.claude"; echo '{}' > "$J/.claude/settings.local.json"; printf 'status = "x"\n' > "$J/PROJECT.toml"
git -C "$J" add -f .claude PROJECT.toml; nc "$J" unrelated
glsel "$GL_PATH"
PO="$(cd "$J" && PATH="$W/faketo:$GL_PATH" git -c core.hooksPath="$TH" push -q -f origin main 2>&1)"; PC=$?
eq   "H-R4-2: force-push over an unfetched remote tip while the hook cannot reach the remote → blocked" "$PC" "1"
has  "H-R4-2: …kit-status-unknown" "$PO" "[R2 kit-status-unknown]"
eq   "H-R4-2: …remote main unchanged" "$(git -C "$K.git" rev-parse main)" "$(git -C "$K" rev-parse main)"
J2="$W/j2"; rm -rf "$J2"; git init -q "$J2"; git -C "$J2" remote add origin "$K.git"; echo hi > "$J2/hi.txt"; git -C "$J2" add hi.txt; nc "$J2"
PO="$(cd "$J2" && PATH="$W/faketo:$GL_PATH" git -c core.hooksPath="$TH" push -q origin main:refs/heads/new-ref 2>&1)"; PC=$?
eq   "H-R4-2: a NEW ref (zero rsha) with the hook offline uses local signals only (clean non-kit push passes)" "$PC" "0"

# R4-3: classify from local branch tips first; then fetch ONLY the old tip of the pushed ref
# and the remote HEAD — shallow, blob-less where supported, into a throwaway repo (nothing
# lands in this repo); never the whole advertised namespace
M="$W/m"; pushrepo "$M" public; git -C "$M" rm -q --cached PROJECT.toml; rm -f "$M/PROJECT.toml"; nc "$M"
git -C "$M" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
for i in $(seq 1 40); do
  git -C "$M" checkout -q --orphan "b$i"; git -C "$M" rm -r -q --cached . >/dev/null; rm -f "$M/kit.toml" "$M/README.md"
  head -c 65536 /dev/urandom | od -An -tx1 > "$M/blob$i.txt"; git -C "$M" add "blob$i.txt"; nc "$M" "b$i"
  git -C "$M" -c core.hooksPath=/dev/null push -q origin "b$i" 2>/dev/null; rm -f "$M/blob$i.txt"
done
git -C "$M" checkout -q --orphan gh-pages; git -C "$M" rm -r -q --cached . >/dev/null 2>&1; echo '<p>old</p>' > "$M/index.html"; git -C "$M" add index.html; nc "$M" oldsite
git -C "$M" -c core.hooksPath=/dev/null push -q origin gh-pages 2>/dev/null; git -C "$M" checkout -q -f main
git -C "$M.git" config uploadpack.allowFilter true
MC="$W/mc"; rm -rf "$MC"; git clone -q --no-local --single-branch --branch main "$M.git" "$MC" 2>/dev/null
BSHAS="$(git -C "$M.git" for-each-ref --format='%(objectname)' 'refs/heads/b*')"
nolocal() { local x n=0; for x in $BSHAS; do git -C "$MC" cat-file -e "$x" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }
mpush() { glsel "$GL_PATH"; rm -f "$W/tr"; PO="$(cd "$1" && GIT_TRACE_PACKET="$W/tr" PATH="$GL_PATH" git -c core.hooksPath="$TH" push -q "${@:2}" 2>&1)"; PC=$?
          # distinct COMMITS the hook asked the remote for (a lazily fetched kit.toml blob is not one)
          WANTS="$(sed -n 's/.*fetch> want \([0-9a-f]*\).*/\1/p' "$W/tr" 2>/dev/null | sort -u \
                   | while read -r x; do [ "$(git -C "$M.git" cat-file -t "$x" 2>/dev/null)" = commit ] && echo "$x"; done | grep -c .)"; }
git -C "$MC" checkout -q --orphan site; git -C "$MC" rm -r -q --cached .; rm -f "$MC/kit.toml" "$MC/README.md"
echo '<p>new</p>' > "$MC/index.html"; git -C "$MC" add index.html; nc "$MC" site
mpush "$MC" origin site:refs/heads/preview
eq   "H-R4-3a: new orphan branch of a kit repo (remote has 41 unfetched branches) passes" "$PC" "0"
eq   "H-R4-3a: …kit status from the local main: nothing fetched" "${WANTS:-0}" "0"
eq   "H-R4-3a: …no remote branch objects landed here" "$(nolocal)" "0"
mpush "$MC" -f origin site:gh-pages
eq   "H-R4-3b: orphan force-push over the remote's unfetched gh-pages passes" "$PC" "0"
eq   "H-R4-3b: …only the old gh-pages tip was fetched" "$WANTS" "1"
has  "H-R4-3b: …shallow (depth 1)" "$(cat "$W/tr" 2>/dev/null)" "fetch> deepen 1"
has  "H-R4-3b: …blob-less where the server allows it" "$(cat "$W/tr" 2>/dev/null)" "fetch> filter blob:none"
eq   "H-R4-3b: …no remote branch objects landed here" "$(nolocal)" "0"
eq   "H-R4-3b: …and this repo did not become shallow" "$(git -C "$MC" rev-parse --is-shallow-repository)" "false"
eq   "H-R4-3b: …no temporary refs left" "$(git -C "$MC" for-each-ref refs/kit-guard/ refs/kit-probe/)" ""
MN="$W/mn"; rm -rf "$MN"; git init -q "$MN"; git -C "$MN" remote add origin "$M.git"; printf 'status = "x"\n' > "$MN/PROJECT.toml"; git -C "$MN" add PROJECT.toml; nc "$MN"
mpush "$MN" origin main:refs/heads/side
eq   "H-R4-3c: a non-kit repo pushing PROJECT.toml to a kit remote (unfetched HEAD) → blocked" "$PC" "1"
has  "H-R4-3c: …R2 (kit status from the remote HEAD)" "$PO" "[R2 forbidden-path] PROJECT.toml"
eq   "H-R4-3c: …only the remote HEAD was fetched" "$WANTS" "1"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT, skipped $SKIP_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
