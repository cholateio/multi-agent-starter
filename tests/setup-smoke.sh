#!/usr/bin/env bash
# tests/setup-smoke.sh - `kit setup` in an isolated HOME / KIT_CONFIG_HOME /
# GIT_CONFIG_GLOBAL with a fake `claude` on PATH. Never touches the real machine.
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3]"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected [$3]"; else pass "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fakebin" "$W/state"
cat > "$W/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CLAUDE_LOG"
case "$*" in
  "--version") echo "2.1.303 (Claude Code)" ;;
  "plugin list --json") if [ -f "$FAKE_STATE/disabled" ]; then echo '[{"id":"kit@multi-agent-kit","enabled":false}]'
                        elif [ -f "$FAKE_STATE/installed" ]; then echo '[{"id":"kit@multi-agent-kit","enabled":true}]'; else echo '[]'; fi ;;
  "plugin enable "*) rm -f "$FAKE_STATE/disabled" ;;
  "plugin marketplace list --json") if [ -f "$FAKE_STATE/mkt" ]; then echo '[{"name":"multi-agent-kit","source":"directory"}]'; else echo '[]'; fi ;;
  "plugin marketplace add "*) touch "$FAKE_STATE/mkt" ;;
  "plugin install "*) touch "$FAKE_STATE/installed" ;;
  "plugin uninstall "*) rm -f "$FAKE_STATE/installed" ;;
  "plugin marketplace remove "*) rm -f "$FAKE_STATE/mkt" ;;
esac
exit 0
FAKE
printf '#!/bin/sh\necho 8.30.1\n' > "$W/fakebin/gitleaks"
printf '#!/bin/sh\necho "osv-scanner version: 2.7.0"\n' > "$W/fakebin/osv-scanner"
chmod +x "$W/fakebin/"*

fresh() {  # new isolated machine under $W/m<n>
  M="$W/m$1"; mkdir -p "$M/home"; : > "$M/gitconfig"; rm -f "$W/state/"*; : > "$W/claude.log"
}
ks() {
  env HOME="$M/home" KIT_CONFIG_HOME="$M/home/.config/kit" KIT_CACHE_HOME="$M/home/.cache/kit" \
      GIT_CONFIG_GLOBAL="$M/gitconfig" GIT_CONFIG_NOSYSTEM=1 CLAUDE_CONFIG_DIR= XDG_CONFIG_HOME= \
      FAKE_CLAUDE_LOG="$W/claude.log" FAKE_STATE="$W/state" PATH="$W/fakebin:$PATH" \
      python3 "$KIT_ROOT/bin/kit" setup "$@" 2>&1
}
hp() { GIT_CONFIG_GLOBAL="$M/gitconfig" GIT_CONFIG_NOSYSTEM=1 git config --global --get core.hooksPath; }
CFG() { printf '%s' "$M/home/.config/kit"; }

# (1) fresh local setup
fresh 1
OUT="$(ks --marketplace local)"; CODE=$?
eq "s1: exit 0" "$CODE" "0"
has "s1: marketplace add <kit_root>" "$(cat "$W/claude.log")" "plugin marketplace add $KIT_ROOT"
has "s1: plugin install --scope user" "$(cat "$W/claude.log")" "plugin install kit@multi-agent-kit --scope user"
S="$M/home/.claude/settings.json"
for p in 'Bash(git status)' 'Bash(git status *)' 'Bash(git diff)' 'Bash(git diff *)' 'Bash(git log)' 'Bash(git log *)' \
         'Bash(git show)' 'Bash(git show *)' 'Bash(ls)' 'Bash(ls *)'; do
  eq "s1: settings has exactly $p" "$(jq -r --arg p "$p" '[.permissions.allow[] | select(. == $p)] | length' "$S" 2>/dev/null)" "1"
done
# review fix F2: no space before * = prefix match (`git diff*` covers `git difftool --extcmd=…`, `ls*` covers lsof)
eq "s1: no space-less wildcard in the baseline" "$(jq -r '[.permissions.allow[] | select(test("[^ ]\\*\\)$"))] | length' "$S" 2>/dev/null)" "0"
lacks "s1: settings has no timeout" "$(cat "$S")" "timeout"
has "s1: config.toml kit_root" "$(cat "$(CFG)/config.toml")" "kit_root = \"$KIT_ROOT\""
has "s1: config.toml [audit] exclude" "$(cat "$(CFG)/config.toml")" "exclude = []"
for h in pre-commit pre-push; do
  [ -x "$(CFG)/git-hooks/$h" ] && pass "s1: shim $h executable" || fail "s1: shim $h executable" "missing"
done
for h in commit-msg post-checkout post-receive; do
  [ -x "$(CFG)/git-hooks/$h" ] && pass "s1: chain-only shim $h executable" || fail "s1: chain-only shim $h executable" "missing"
done
lacks "s1: shim placeholder replaced" "$(cat "$(CFG)/git-hooks/pre-push")" "__HOOK__"
has "s1: shim chains via --git-common-dir" "$(cat "$(CFG)/git-hooks/commit-msg")" "--git-common-dir"
has "s1: shim runs its own hook" "$(cat "$(CFG)/git-hooks/pre-push")" "pre-push"
eq "s1: global core.hooksPath" "$(hp)" "$(CFG)/git-hooks"
eq "s1: privacy mode 600" "$(stat -c %a "$(CFG)/privacy.local.toml")" "600"
eq "s1: ~/.local/bin/kit symlink" "$(readlink "$M/home/.local/bin/kit")" "$KIT_ROOT/bin/kit"
eq "s1: ~/.local/bin/proj symlink" "$(readlink "$M/home/.local/bin/proj")" "$KIT_ROOT/bin/proj"
has "s1: steps report [done]" "$OUT" "[done]"

# (2) merge into an existing settings.json
fresh 2
mkdir -p "$M/home/.claude"
printf '{"permissions":{"allow":["Bash(timeout *)","Bash(pnpm *)"]},"model":"x"}\n' | jq . > "$M/home/.claude/settings.json"
OUT="$(ks)"
S="$M/home/.claude/settings.json"
has "s2: keeps custom allow" "$(jq -r '.permissions.allow[]' "$S")" "Bash(pnpm *)"
lacks "s2: drops Bash(timeout *)" "$(cat "$S")" "timeout"
eq "s2: keeps other keys" "$(jq -r .model "$S")" "x"
ls "$M/home/.claude/" | grep -q '^settings.json.bak-' && pass "s2: .bak- backup written" || fail "s2: .bak- backup written" "none"
has "s2: prints a unified diff" "$OUT" '-      "Bash(timeout *)"'
# a machine that ran the pre-fix v5 setup: the space-less wildcards are narrowed away
fresh 2b
mkdir -p "$M/home/.claude"
printf '{"permissions":{"allow":["Bash(git diff*)","Bash(ls*)","Bash(git status*)","Bash(git log*)","Bash(git show*)","Bash(pnpm *)"]}}\n' | jq . > "$M/home/.claude/settings.json"
OUT="$(ks)"
S="$M/home/.claude/settings.json"
eq "s2b: pre-fix wide wildcards removed" "$(jq -r '[.permissions.allow[] | select(test("[^ ]\\*\\)$"))] | length' "$S")" "0"
has "s2b: narrowed form present" "$(jq -r '.permissions.allow[]' "$S")" "Bash(git diff *)"
has "s2b: custom allow kept" "$(jq -r '.permissions.allow[]' "$S")" "Bash(pnpm *)"

# (3) re-run → every step skip
: > "$W/claude.log"
OUT="$(ks)"; CODE=$?
eq "s3: rerun exit 0" "$CODE" "0"
lacks "s3: rerun has no [done]" "$OUT" "[done]"
has "s3: rerun reports [skip]" "$OUT" "[skip]"
lacks "s3: rerun does not reinstall plugin" "$(cat "$W/claude.log")" "plugin install"

# (4) dry-run on a clean HOME writes nothing
fresh 4
OUT="$(ks --dry-run)"; CODE=$?
eq "s4: dry-run exit 0" "$CODE" "0"
eq "s4: dry-run created no files" "$(find "$M/home" -mindepth 1 | wc -l | tr -d ' ')" "0"
eq "s4: dry-run left gitconfig empty" "$(wc -c < "$M/gitconfig" | tr -d ' ')" "0"
eq "s4: dry-run ran no claude command" "$(wc -c < "$W/claude.log" | tr -d ' ')" "0"
has "s4: WOULD RUN hooksPath" "$OUT" "WOULD RUN: git config --global core.hooksPath $(CFG)/git-hooks"
has "s4: WOULD RUN plugin install" "$OUT" "WOULD RUN: claude plugin install kit@multi-agent-kit --scope user"
has "s4: WOULD WRITE settings" "$OUT" "WOULD WRITE: $M/home/.claude/settings.json"
has "s4: WOULD WRITE privacy" "$OUT" "WOULD WRITE: $(CFG)/privacy.local.toml"

# (5) uninstall: hooksPath unset, shims gone, symlinks gone, settings untouched
fresh 5
ks >/dev/null
SUM_BEFORE="$(cksum < "$M/home/.claude/settings.json")"
OUT="$(ks --uninstall)"; CODE=$?
eq "s5: uninstall exit 0" "$CODE" "0"
eq "s5: hooksPath unset" "$(hp)" ""
[ ! -e "$(CFG)/git-hooks/pre-commit" ] && pass "s5: shims removed" || fail "s5: shims removed" "still there"
[ ! -e "$(CFG)/git-hooks/commit-msg" ] && pass "s5: chain-only shims removed" || fail "s5: chain-only shims removed" "still there"
[ ! -L "$M/home/.local/bin/kit" ] && pass "s5: kit symlink removed" || fail "s5: kit symlink removed" "still there"
eq "s5: settings.json unchanged" "$(cksum < "$M/home/.claude/settings.json")" "$SUM_BEFORE"
[ -f "$(CFG)/privacy.local.toml" ] && pass "s5: privacy kept" || fail "s5: privacy kept" "removed"
has "s5: plugin uninstalled" "$(cat "$W/claude.log")" "plugin uninstall kit@multi-agent-kit"

# (6) a foreign global hooksPath is never overwritten
fresh 6
GIT_CONFIG_GLOBAL="$M/gitconfig" git config --global core.hooksPath /opt/other-hooks
OUT="$(ks)"; CODE=$?
eq "s6: foreign hooksPath kept" "$(hp)" "/opt/other-hooks"
eq "s6: exit 1 (step not done)" "$CODE" "1"
has "s6: warns about the foreign hooksPath" "$OUT" "/opt/other-hooks"

# (7) github marketplace
fresh 7
OUT="$(ks --marketplace github --github-owner acme)"
has "s7: github marketplace add owner/repo" "$(cat "$W/claude.log")" "plugin marketplace add acme/multi-agent-starter"
has "s7: github_owner recorded" "$(cat "$(CFG)/config.toml")" 'github_owner = "acme"'

# (8) shim fails loud without config (design §7.5: guard missing must block)
mkdir -p "$W/lonely/git-hooks"; sed 's/__HOOK__/pre-commit/g' "$KIT_ROOT/plugin/guard/shim.sh" > "$W/lonely/git-hooks/pre-commit"
OUT="$(bash "$W/lonely/git-hooks/pre-commit" 2>&1)"; CODE=$?
eq "s8: unconfigured shim exits 1" "$CODE" "1"
has "s8: unconfigured shim says not configured" "$OUT" "KIT GUARD: not configured"

# (9) review O2: an installed-but-disabled plugin is re-enabled
fresh 9
touch "$W/state/installed" "$W/state/disabled" "$W/state/mkt"
OUT="$(ks)"
has "s9: setup enables a disabled plugin" "$(cat "$W/claude.log")" "plugin enable kit@multi-agent-kit"
lacks "s9: …without reinstalling it" "$(cat "$W/claude.log")" "plugin install"
has "s9: …and says so" "$OUT" "enabled"

# (10) review O3/F13: --bin-dir is persisted as tools_dir (the guard, doctor and session start read it)
fresh 10
OUT="$(ks --bin-dir "$M/tools")"
has "s10: config.toml records tools_dir" "$(cat "$(CFG)/config.toml")" "tools_dir = \"$M/tools\""
OUT="$(ks --bin-dir "$M/tools2")"
has "s10: a new --bin-dir updates tools_dir" "$(cat "$(CFG)/config.toml")" "tools_dir = \"$M/tools2\""
eq "s10: …exactly one tools_dir line" "$(grep -c '^tools_dir' "$(CFG)/config.toml")" "1"
# (11) review R3-5: a relative --bin-dir is persisted as an absolute path
mkdir -p "$M/cwd"; OUT="$(cd "$M/cwd" && ks --bin-dir reltools)"
has "s11: relative --bin-dir recorded absolute" "$(cat "$(CFG)/config.toml")" "tools_dir = \"$M/cwd/reltools\""

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
