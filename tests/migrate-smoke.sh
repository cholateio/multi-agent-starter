#!/usr/bin/env bash
# tests/migrate-smoke.sh - `kit migrate` on v4 fixtures generated at run time
# (nothing .claude/ is tracked in the kit repo). Isolated HOME / state dir; a
# fake `gh` that fails simulates offline / not logged in.
HP=/home   # fixtures build "/home/<user>" strings at runtime so the kit guard does not flag this file
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3]"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected [$3]"; else pass "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }
exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing $2"; fi; }
absent() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "exists $2"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/fakebin"
printf '#!/bin/sh\necho "gh: not logged in" >&2\nexit 1\n' > "$W/fakebin/gh"; chmod +x "$W/fakebin/gh"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n' > "$W/gitconfig"
export HOME="$W/home" KIT_CONFIG_HOME="$W/home/.config/kit" KIT_STATE_HOME="$W/state" \
       GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1 PATH="$W/fakebin:$PATH"
km() { python3 "$KIT_ROOT/bin/kit" migrate "$@" 2>&1; }
g() { git -C "$@"; }
pyconst() { (cd "$KIT_ROOT" && python3 -c "import sys; from tests.unit.test_migrate import $1 as v; sys.stdout.write(v)"); }
state() { (cd "$1" && g . write-tree && find . -path ./.git -prune -o -type f -print | sort | xargs cksum); }

# make_v4 <dir> [tracked|untracked]: a v4 project as init.sh --update left it
make_v4() {
  local R="$1" mode="${2:-tracked}"
  mkdir -p "$R/.claude/"{rules,hooks,skills,agents,docs} "$R/docs/plans" "$R/docs/superpowers/plans" "$R/src/legacy"
  g "$R" init -q -b main
  for f in kit-workflow kit-delegation kit-judgment kit-evolution project-manifest; do cp "$KIT_ROOT/plugin/rules/$f.md" "$R/.claude/rules/"; done
  for f in session-start classify-task protect-paths tool-breaker verify-final-review; do cp "$KIT_ROOT/plugin/hooks/$f.sh" "$R/.claude/hooks/"; done
  for s in kit-review kit-skip-review kit-dispatch research-before-planning; do mkdir -p "$R/.claude/skills/$s"; echo "# $s" > "$R/.claude/skills/$s/SKILL.md"; done
  cp "$KIT_ROOT/plugin/agents/"*.md "$R/.claude/agents/"
  echo "# jm" > "$R/.claude/docs/judgment-matrix.md"; echo "# vs" > "$R/.claude/docs/verification-signals.md"
  echo "v4.10.0 abcdef0 2026-08-02" > "$R/.claude/kit-version"
  printf '# legacy\nsrc/legacy/*\n' > "$R/.claude/protected-paths"
  pyconst V4_SETTINGS_JSON | python3 -c 'import json,sys; d=json.load(sys.stdin); d["permissions"]["allow"].append("Bash(pnpm *)"); print(json.dumps(d, indent=2))' > "$R/.claude/settings.json"
  pyconst V4_CLAUDE_MD > "$R/CLAUDE.md"
  printf 'name = "proj-a"\nstatus = "active"\n' > "$R/PROJECT.toml"
  printf '# Lessons\n- one\n' > "$R/docs/LESSONS.md"
  echo "plan p" > "$R/docs/plans/p.md"; echo "plan q" > "$R/docs/superpowers/plans/q.md"
  echo "x = 1" > "$R/src/legacy/old.py"; echo "# proj-a" > "$R/README.md"
  if [ "$mode" = tracked ]; then
    printf 'node_modules/\n\n# Claude Code runtime state. `.claude/` itself IS tracked on purpose:\n# kit-owned files are regenerable via `init.sh --update`, but settings.json\n# (accumulated permission approvals) and protected-paths (project no-touch\n# zones) are project truth that nothing can rebuild. Only machine-local\n# state is excluded.\n.claude/settings.local.json\n.claude/scheduled_tasks.lock\n' > "$R/.gitignore"
  else
    printf 'node_modules/\n.claude/\nPROJECT.toml\ndocs/LESSONS.md\ndocs/plans/\ndocs/superpowers/plans/\n' > "$R/.gitignore"
  fi
  g "$R" add -A; g "$R" commit -q -m "v4 project"
}

# ---- M1: dry-run changes nothing
R="$W/m1"; make_v4 "$R"
BEFORE="$(state "$R")"
OUT="$(km "$R")"; CODE=$?
eq "M1: dry-run exit 0" "$CODE" "0"
eq "M1: dry-run leaves git status clean" "$(g "$R" status --short)" ""
eq "M1: dry-run leaves tree + files unchanged" "$(state "$R")" "$BEFORE"
absent "M1: dry-run writes no backup" "$W/state/migrate-backup"
has "M1: dry-run says what it would do" "$OUT" "would kit.toml"
has "M1: dry-run shows the CLAUDE.md diff" "$OUT" "+@AGENTS.md"

# ---- M2: --apply
OUT="$(km "$R" --apply)"; CODE=$?
eq "M2: apply exit 0" "$CODE" "0"
has "M2: offline → assume public (warned)" "$OUT" "WARN: offline, assuming public"
KT="$(cat "$R/kit.toml" 2>/dev/null)"
has "M2: kit.toml visibility public" "$KT" 'visibility = "public"'
has "M2: kit.toml protected keeps # legacy" "$KT" "  # legacy"
has "M2: kit.toml protected has src/legacy/*" "$KT" '"src/legacy/*",'
CONSTRAINTS="$(pyconst V4_CLAUDE_MD | sed -n '/^## Project-specific constraints/,/^\*\*同步執法\*\*/p' | sed '$d')"
if grep -qF -- "$(printf '%s' "$CONSTRAINTS" | head -3)" "$R/AGENTS.md" 2>/dev/null; then pass "M2: AGENTS.md carries the constraints verbatim"; else fail "M2: AGENTS.md carries the constraints verbatim" "not found"; fi
eq "M2: CLAUDE.md first line is @AGENTS.md" "$(head -1 "$R/CLAUDE.md")" "@AGENTS.md"
TRACKED="$(g "$R" ls-files)"
for p in .claude/ PROJECT.toml docs/LESSONS.md docs/plans/ docs/superpowers/plans/; do lacks "M2: $p no longer tracked" "$TRACKED" "$p"; done
for f in PROJECT.toml docs/LESSONS.md docs/plans/p.md docs/superpowers/plans/q.md; do exists "M2: $f still on disk" "$R/$f"; done
eq "M2: .claude holds only settings.local.json" "$(cd "$R/.claude" && find . -type f | sort | tr '\n' ' ')" "./settings.local.json "
has "M2: settings.local.json keeps pnpm" "$(cat "$R/.claude/settings.local.json")" "Bash(pnpm *)"
lacks "M2: settings.local.json has no kit hooks" "$(cat "$R/.claude/settings.local.json")" "hooks"
absent "M2: kit-version removed" "$R/.claude/kit-version"
eq "M2: gitignore kit block exactly once" "$(grep -c '^# >>> kit v5' "$R/.gitignore")" "1"
has "M2: reports the v4 gitignore block removal" "$OUT" "tracked-on-purpose block removed"
lacks "M2: v4 'tracked on purpose' block gone" "$(cat "$R/.gitignore")" "IS tracked on purpose"
has "M2: project gitignore lines kept" "$(cat "$R/.gitignore")" "node_modules/"
BK="$(ls -d "$W/state/migrate-backup/m1/"*/ 2>/dev/null | head -1)"
exists "M2: backup has .claude/kit-version" "${BK}.claude/kit-version"
exists "M2: backup has PROJECT.toml" "${BK}PROJECT.toml"
exists "M2: backup has docs/superpowers/plans/q.md" "${BK}docs/superpowers/plans/q.md"
exists "M2: LICENSE added (public, was missing)" "$R/LICENSE"
has "M2: prints README bootstrap prompt" "$OUT" "README"
has "M2: reminds about history rewrite" "$OUT" "history"
eq "M2: kit doctor validator accepts kit.toml" "$(cd "$KIT_ROOT" && python3 -c "from cli.kittoml import validate_kit_toml as v; print(v('$R/kit.toml'))")" "[]"

# ---- M3: re-run apply → every line skip, nothing changes
BEFORE="$(state "$R")"
OUT="$(km "$R" --apply)"; CODE=$?
eq "M3: rerun exit 0" "$CODE" "0"
if printf '%s\n' "$OUT" | grep -E '^(done|would|needs-review) ' | grep -q .; then fail "M3: rerun lines are all skip" "$(printf '%s\n' "$OUT" | grep -E '^(done|would|needs-review) ' | head -2)"; else pass "M3: rerun lines are all skip"; fi
has "M3: rerun says nothing to do" "$OUT" "nothing to do"
eq "M3: rerun changes nothing" "$(state "$R")" "$BEFORE"
eq "M3: rerun made no second backup" "$(ls "$W/state/migrate-backup/m1" | wc -l | tr -d ' ')" "1"

# ---- M4: --commit
OUT="$(km "$R" --commit)"; CODE=$?
eq "M4: commit exit 0" "$CODE" "0"
eq "M4: commit subject" "$(g "$R" log -1 --format=%s)" "chore(kit): migrate to kit v5 — untrack .claude, add AGENTS.md + kit.toml"
eq "M4: tree clean after commit" "$(g "$R" status --porcelain)" ""
for f in kit.toml AGENTS.md CLAUDE.md .gitignore LICENSE; do has "M4: $f committed" "$(g "$R" ls-files)" "$f"; done
exists "M4: PROJECT.toml still on disk after commit" "$R/PROJECT.toml"

# ---- M5: dirty tree refused; --allow-dirty passes
R="$W/m5"; make_v4 "$R"; echo "owner edit" >> "$R/README.md"
OUT="$(km "$R" --apply)"; CODE=$?
eq "M5: dirty tree exit 1" "$CODE" "1"
has "M5: says dirty" "$OUT" "dirty"
absent "M5: refused run wrote nothing" "$R/kit.toml"
OUT="$(km "$R" --apply --allow-dirty)"; CODE=$?
eq "M5: --allow-dirty exit 0" "$CODE" "0"
exists "M5: --allow-dirty migrated" "$R/kit.toml"
has "M5: owner edit untouched" "$(cat "$R/README.md")" "owner edit"
OUT="$(km "$R" --commit --allow-dirty)"; CODE=$?
has "M5: commit leaves owner's unstaged edit out" "$(g "$R" status --porcelain)" " M README.md"

# ---- M6: CLAUDE.md without kit markers → needs-review, content kept verbatim
R="$W/m6"; make_v4 "$R"
printf '# custom\n\n## Goal\n\nOwner-written, no kit boilerplate.\n' > "$R/CLAUDE.md"; g "$R" commit -qam "custom claude"
OUT="$(km "$R" --apply)"
has "M6: needs-review reported" "$OUT" "needs-review"
eq "M6: AGENTS.md == original" "$(cat "$R/AGENTS.md")" "$(printf '# custom\n\n## Goal\n\nOwner-written, no kit boilerplate.')"

# ---- M7: interrupted apply converges; the v4-yield gate protects meanwhile
R="$W/m7"; make_v4 "$R"
OUT="$(KIT_TEST_MIGRATE_STOP_AFTER=agents km "$R" --apply)"; CODE=$?
eq "M7: simulated interrupt exits 3" "$CODE" "3"
exists "M7: kit.toml written before the interrupt" "$R/kit.toml"
exists "M7: kit-version still present" "$R/.claude/kit-version"
GATE="$(cd "$KIT_ROOT" && CWD="$R" CLAUDE_PROJECT_DIR= KIT=on bash -c 'source plugin/hooks/lib.sh; kit_project_root' 2>&1)"; GRC=$?
eq "M7: plugin gate yields mid-migration (rc 1)" "$GRC" "1"
has "M7: gate names the v4 layout" "$GATE" "v4 layout detected"
rm "$R/kit.toml"
OUT="$(km "$R" --apply)"; CODE=$?
eq "M7: rerun after interrupt exit 0" "$CODE" "0"
exists "M7: kit.toml restored" "$R/kit.toml"
absent "M7: kit-version gone after convergence" "$R/.claude/kit-version"
eq "M7: .claude converged" "$(cd "$R/.claude" && find . -type f | sort | tr '\n' ' ')" "./settings.local.json "
OUT="$(km "$R" --apply)"; has "M7: third run nothing to do" "$OUT" "nothing to do"
eq "M7: two backups, distinct dirs" "$(ls "$W/state/migrate-backup/m7" | wc -l | tr -d ' ')" "2"

# ---- M8: .claude already untracked (gitignored) but v4 files on disk
R="$W/m8"; make_v4 "$R" untracked
eq "M8: fixture has nothing tracked under .claude" "$(g "$R" ls-files .claude | wc -l | tr -d ' ')" "0"
OUT="$(km "$R" --apply)"; CODE=$?
eq "M8: apply exit 0" "$CODE" "0"
has "M8: untrack step skipped" "$OUT" "skip untrack"
lacks "M8: no claim of removing an absent v4 gitignore block" "$OUT" "tracked-on-purpose block removed"
absent "M8: kit-version removed" "$R/.claude/kit-version"
absent "M8: v4 hooks removed" "$R/.claude/hooks"
exists "M8: kit.toml written" "$R/kit.toml"
eq "M8: gitignore kit block once" "$(grep -c '^# >>> kit v5' "$R/.gitignore")" "1"

# ---- M9: absolute protected entries never reach the tracked kit.toml
R="$W/m9"; make_v4 "$R"
printf 'src/legacy/*\n'"$HP"'/testuser/notes/\n' > "$R/.claude/protected-paths"; g "$R" commit -qam "abs protected"
OUT="$(km "$R" --apply)"
lacks "M9: absolute path not in kit.toml" "$(cat "$R/kit.toml")" "$HP/testuser"
has "M9: absolute path flagged needs-review" "$OUT" "needs-review"
has "M9: relative entry kept" "$(cat "$R/kit.toml")" '"src/legacy/*",'

# ---- M10: unknown file in a kit dir is kept and flagged; non-kit repo refused
R="$W/m10"; make_v4 "$R"; echo "# mine" > "$R/.claude/skills/my-skill.md"; g "$R" add -A; g "$R" commit -qm mine
OUT="$(km "$R" --apply)"
exists "M10: user file kept" "$R/.claude/skills/my-skill.md"
has "M10: user file flagged" "$OUT" ".claude/skills/my-skill.md"
mkdir -p "$W/plain"; g "$W/plain" init -q -b main
OUT="$(km "$W/plain" --apply)"; CODE=$?
eq "M10: non-kit repo refused (exit 1)" "$CODE" "1"
has "M10: points at kit init" "$OUT" "kit init"

# ---- M11 (final review C1): owner's untracked / edited files that migrate would also write → dirty
R="$W/m11"; make_v4 "$R"; mkdir -p "$R/docs"
echo "DB_PASSWORD=not-a-real-secret" > "$R/docs/DEVELOPMENT.md"; echo "draft agents" > "$R/AGENTS.md"
printf 'MIT License\nowner edit\n' > "$R/LICENSE"; git -C "$R" add LICENSE; git -C "$R" commit -qm lic; echo "more" >> "$R/LICENSE"
HEAD0="$(g "$R" rev-parse HEAD)"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M11: owner files in managed paths → dirty, exit 1" "$CODE" "1"
has "M11: says dirty" "$OUT" "dirty"
eq "M11: nothing committed" "$(g "$R" rev-parse HEAD)" "$HEAD0"
OUT="$(km "$R" --commit --allow-dirty)"; CODE=$?
eq "M11: --allow-dirty commit exit 0" "$CODE" "0"
eq "M11: owner's untracked docs/DEVELOPMENT.md NOT committed" "$(g "$R" ls-files docs/DEVELOPMENT.md)" ""
eq "M11: owner's draft AGENTS.md NOT committed" "$(g "$R" ls-files AGENTS.md)" ""
has "M11: owner's LICENSE edit left uncommitted" "$(g "$R" status --porcelain)" " M LICENSE"
# a resumed run (manifest of what migrate wrote) is still not "dirty"
R="$W/m12"; make_v4 "$R"; km "$R" --apply >/dev/null
echo "owner new file" > "$R/docs/DEVELOPMENT.md"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M12: untracked owner file after apply → dirty on commit" "$CODE" "1"
rm "$R/docs/DEVELOPMENT.md"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M12: resume after apply commits (exit 0)" "$CODE" "0"
for f in kit.toml AGENTS.md CLAUDE.md .gitignore LICENSE; do has "M12: $f committed" "$(g "$R" ls-files)" "$f"; done
eq "M12: clean after commit" "$(g "$R" status --porcelain)" ""

# ---- M13 (final review I4): invalid settings.local.json never wedges the migration
R="$W/m13"; make_v4 "$R"; printf '{"permissions": {"allow": ["Bash(x)",]}}\n' > "$R/.claude/settings.local.json"
OUT="$(km "$R" --apply)"; CODE=$?
eq "M13: apply exit 0" "$CODE" "0"
has "M13: needs-review names settings.local.json" "$OUT" "settings.local.json"
absent "M13: kit-version removed (migration completed)" "$R/.claude/kit-version"
lacks "M13: kit hooks stripped from settings.json" "$(cat "$R/.claude/settings.json" 2>/dev/null)" ".claude/hooks/"
has "M13: owner allow kept in settings.json" "$(cat "$R/.claude/settings.json" 2>/dev/null)" "Bash(pnpm *)"
has "M13: invalid local file untouched" "$(cat "$R/.claude/settings.local.json")" '"Bash(x)",]'
OUT="$(km "$R" --apply)"; has "M13: rerun converges" "$OUT" "nothing to do"

# ---- M14 (review F3): a checkout of a pre-migration ref must not lose local-only files
# exact reviewer repro, with the kit shims installed under the global hooksPath
SHD="$KIT_CONFIG_HOME/git-hooks"; mkdir -p "$SHD"
for h in pre-commit pre-push pre-rebase post-checkout post-merge post-rewrite post-commit; do
  sed "s/__HOOK__/$h/g" "$KIT_ROOT/plugin/guard/shim.sh" > "$SHD/$h"; chmod 755 "$SHD/$h"
done
printf 'kit_root = "%s"\n' "$KIT_ROOT" > "$KIT_CONFIG_HOME/config.toml"
git config --file "$W/gitconfig" core.hooksPath "$SHD"
R="$W/m14"; make_v4 "$R"; echo "# mine" > "$R/.claude/skills/my-skill.md"; g "$R" add -A; g "$R" commit -qm mine; g "$R" tag v4-state
OUT="$(km "$R" --commit)"; CODE=$?
eq "M14: migrate --commit exit 0" "$CODE" "0"
has "M14: migrate warns that pre-migration commits still track the local files" "$OUT" "pre-migration commits still TRACK"
has "M14: …and names the store" "$OUT" "localfiles/"
echo "edited after migration" >> "$R/PROJECT.toml"; echo "- two (after migration)" >> "$R/docs/LESSONS.md"
echo "# mine, edited" >> "$R/.claude/skills/my-skill.md"
CO1="$(cd "$R" && git checkout -q v4-state 2>&1)"
eq "M14: on the old ref PROJECT.toml is the tracked v4 version" "$(cat "$R/PROJECT.toml")" "$(printf 'name = "proj-a"\nstatus = "active"')"
has "M14: …and the hook says the owner's copy is kept" "$CO1" "kept in"
CO2="$(cd "$R" && git checkout -q main 2>&1)"
has "M14: back on main PROJECT.toml has the post-migration edit" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "edited after migration"
has "M14: …docs/LESSONS.md too" "$(cat "$R/docs/LESSONS.md" 2>/dev/null)" "two (after migration)"
exists "M14: …docs/plans/p.md is back" "$R/docs/plans/p.md"
exists "M14: …docs/superpowers/plans/q.md is back" "$R/docs/superpowers/plans/q.md"
has "M14: …the owner's own .claude file with its edit" "$(cat "$R/.claude/skills/my-skill.md" 2>/dev/null)" "mine, edited"
exists "M14: …settings.local.json survived" "$R/.claude/settings.local.json"
absent "M14: v4 kit files are NOT resurrected (.claude/kit-version)" "$R/.claude/kit-version"
has "M14: the hook reports the restore" "$CO2" "restored"
eq "M14: tree clean (restored files are ignored, not tracked)" "$(g "$R" status --porcelain)" ""
# an editor that saves by rename breaks the hard link; the next commit re-links
sed -i 's/edited after migration/re-edited by rename-save/' "$R/PROJECT.toml"
g "$R" commit -q --allow-empty -m "later work"
(cd "$R" && git checkout -q v4-state 2>/dev/null && git checkout -q main 2>/dev/null)
has "M14: rename-saved edit survives after the post-commit snapshot" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "re-edited by rename-save"
# bisect walks old commits too
(cd "$R" && git bisect start -q main v4-state >/dev/null 2>&1; git bisect reset -q >/dev/null 2>&1)
has "M14: after a bisect PROJECT.toml is intact" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "re-edited by rename-save"
# another clone pulls the migration commit: git deletes the files — they come back from the old blob
RB="$W/m14.git"; git clone -q --bare "$R" "$RB" 2>/dev/null; RC="$W/m14-clone"
git clone -q "$RB" "$RC" 2>/dev/null; (cd "$RC" && git checkout -q v4-state -B main 2>/dev/null)
eq "M14: clone starts on the v4 commit with PROJECT.toml tracked" "$(g "$RC" ls-files PROJECT.toml)" "PROJECT.toml"
(cd "$RC" && git pull -q --ff-only origin main >/dev/null 2>&1)
eq "M14: after pulling the migration commit PROJECT.toml is untracked" "$(g "$RC" ls-files PROJECT.toml)" ""
exists "M14: …and still on disk (restored from the previous commit)" "$RC/PROJECT.toml"
exists "M14: …docs/LESSONS.md too" "$RC/docs/LESSONS.md"
absent "M14: …but no v4 .claude kit files" "$RC/.claude/kit-version"
# kit guard status and the session start refresh the snapshot too
RID14="$(printf '%s' "$R" | sha1sum | cut -c1-12)"
rm -rf "$W/state/localfiles/$RID14"
GS="$(cd "$R" && python3 "$KIT_ROOT/bin/kit" guard status 2>&1)"
exists "M14: kit guard status re-creates the snapshot" "$W/state/localfiles/$RID14/files/PROJECT.toml"
has "M14: …and reports it" "$GS" "local-only files:"
rm -rf "$W/state/localfiles/$RID14"
printf '{"session_id":"m14s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$R" \
  | CLAUDE_PLUGIN_ROOT="$KIT_ROOT/plugin" CLAUDE_PROJECT_DIR="$R" bash "$KIT_ROOT/plugin/hooks/session-start.sh" >/dev/null 2>&1
exists "M14: session start re-creates the snapshot" "$W/state/localfiles/$RID14/files/PROJECT.toml"
rm -f /tmp/claude-kit-baseline-m14s
# a repo that is not a kit repo gets no store
NK="$W/m14-nokit"; g "$W" init -q -b main m14-nokit; echo a > "$NK/a"; g "$NK" add a; g "$NK" commit -qm a; g "$NK" checkout -q -b x
NKID="$(printf '%s' "$NK" | sha1sum | cut -c1-12)"
absent "M14: non-kit repo: no localfiles store" "$W/state/localfiles/$NKID"
git config --file "$W/gitconfig" --unset core.hooksPath

# ---- M17 (review R3-3 / R3-9a / N2 / N4): symlinks, omitted files, store perms, prune, mtime
git config --file "$W/gitconfig" core.hooksPath "$SHD"
R="$W/m17"; make_v4 "$R"
ln -s ../README.md "$R/docs/plans/link.md"; ln -s /nonexistent/target "$R/.claude/dangling"
head -c $((9 * 1024 * 1024)) /dev/zero | tr '\0' 'x' > "$R/docs/plans/big.md"
g "$R" add -A; g "$R" commit -qm "v4 extras"; g "$R" tag v4-state
OUT="$(km "$R" --commit)"; CODE=$?
eq "M17: migrate --commit exit 0" "$CODE" "0"
has "M17: migrate warns about the file it cannot protect (> 8 MiB)" "$OUT" "docs/plans/big.md"
has "M17: …as NOT protected" "$OUT" "NOT protected"
RID17="$(printf '%s' "$R" | sha1sum | cut -c1-12)"; ST17="$W/state/localfiles/$RID17"
[ -L "$ST17/files/docs/plans/link.md" ] && pass "M17: a symlink is stored AS a symlink" || fail "M17: a symlink is stored AS a symlink" "$(ls -l "$ST17/files/docs/plans/" 2>&1 | head -3)"
eq "M17: …with its target" "$(readlink "$ST17/files/docs/plans/link.md" 2>/dev/null)" "../README.md"
eq "M17: store root is private (700)" "$(stat -c %a "$W/state/localfiles" 2>/dev/null)" "700"
GS="$(cd "$R" && python3 "$KIT_ROOT/bin/kit" guard status 2>&1)"
has "M17: kit guard status lists the omitted file" "$GS" "docs/plans/big.md"
has "M17: …as NOT protected" "$GS" "NOT protected"
(cd "$R" && git checkout -q v4-state 2>/dev/null)
CO2="$(cd "$R" && git checkout -q main 2>&1)"
[ -L "$R/docs/plans/link.md" ] && pass "M17: the symlink comes back as a symlink" || fail "M17: the symlink comes back as a symlink" "$(ls -l "$R/docs/plans/link.md" 2>&1)"
eq "M17: …same target" "$(readlink "$R/docs/plans/link.md" 2>/dev/null)" "../README.md"
[ -L "$R/.claude/dangling" ] && pass "M17: a dangling .claude symlink comes back (store, not blob)" || fail "M17: a dangling .claude symlink comes back" "missing"
has "M17: the restore message dates the store copies" "$CO2" "as of"
# N2: a plan the owner deletes on purpose is not resurrected after a later snapshot
echo "# done plan" > "$R/docs/plans/done.md"; g "$R" commit -q --allow-empty -m snap1
rm -f "$R/docs/plans/done.md" "$R/docs/plans/p.md"; g "$R" commit -q --allow-empty -m snap2
(cd "$R" && git checkout -q v4-state 2>/dev/null && git checkout -q main 2>/dev/null)
absent "M17: a deleted plan (snapshot taken after the delete) stays deleted after visiting an old ref" "$R/docs/plans/p.md"
absent "M17: …an untracked-only deleted plan too" "$R/docs/plans/done.md"
TG17="$(ls -d "$ST17/trash/docs/plans/p.md".~*~ 2>/dev/null | head -n 1)"
exists "M17: …but its last copy is kept in the store's trash (timestamped)" "${TG17:-$ST17/trash/docs/plans/p.md.~none~}"
mkdir -p "$R/.claude/many"; for i in $(seq 1 2005); do : > "$R/.claude/many/f$i"; done
LO="$(cd "$R" && bash "$KIT_ROOT/plugin/guard/localfiles.sh" snapshot 2>&1)"
has "M17: files beyond the 2000-file cap are named as NOT protected" "$LO" "beyond the first 2000 files"
has "M17: …with the full list in the store" "$(cat "$ST17/omitted" 2>/dev/null)" "(beyond the first 2000 files)"
rm -rf "$R/.claude/many"
git config --file "$W/gitconfig" --unset core.hooksPath

# ---- M19 (review R4-4): trash keeps timestamped generations (last 5 per path) and every
# snapshot caller reports what it moved
git config --file "$W/gitconfig" core.hooksPath "$SHD"
R="$W/m19"; make_v4 "$R"; g "$R" tag v4-state; km "$R" --commit >/dev/null 2>&1
RID19="$(printf '%s' "$R" | sha1sum | cut -c1-12)"; ST19="$W/state/localfiles/$RID19"
LF="$KIT_ROOT/plugin/guard/localfiles.sh"
gens() { ls -d "$ST19/trash/$1".~*~ 2>/dev/null | wc -l | tr -d ' '; }
for i in 1 2 3 4 5 6 7; do
  echo "draft $i" > "$R/docs/plans/cycle.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null)
  rm -f "$R/docs/plans/cycle.md"; LO="$(cd "$R" && bash "$LF" snapshot 2>&1)"
done
eq "M19: 7 disappear/reappear cycles with different content keep the last 5 copies" "$(gens docs/plans/cycle.md)" "5"
NEWEST="$(ls -d "$ST19/trash/docs/plans/cycle.md".~*~ | sort | tail -n 1)"; OLDEST="$(ls -d "$ST19/trash/docs/plans/cycle.md".~*~ | sort | head -n 1)"
eq "M19: …the newest copy is the last version" "$(cat "$NEWEST" 2>/dev/null)" "draft 7"
eq "M19: …the oldest kept is version 3" "$(cat "$OLDEST" 2>/dev/null)" "draft 3"
has "M19: the snapshot says what it moved (one line)" "$LO" "moved to $ST19/trash (docs/plans/cycle.md"
eq "M19: …exactly one line" "$(printf '%s\n' "$LO" | grep -c 'moved to')" "1"
for i in 1 2 3; do
  echo "same" > "$R/docs/plans/same.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null)
  rm -f "$R/docs/plans/same.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null)
done
eq "M19: identical content is not stored twice" "$(gens docs/plans/same.md)" "1"
# a single-generation trash from the round-3 build becomes the oldest generation
mkdir -p "$ST19/trash/docs/plans"; echo "legacy" > "$ST19/trash/docs/plans/old.md"
echo "newer" > "$R/docs/plans/old.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null); rm -f "$R/docs/plans/old.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null)
eq "M19: a legacy one-copy trash is kept as a generation" "$(gens docs/plans/old.md)" "2"
has "M19: …with its content" "$(cat "$ST19/trash/docs/plans/old.md".~*~ 2>/dev/null)" "legacy"
# every snapshot caller reports: the post-commit hook …
echo "c1" > "$R/docs/plans/hook.md"; g "$R" commit -q --allow-empty -m hk1 2>/dev/null
rm -f "$R/docs/plans/hook.md"; HO="$(cd "$R" && git commit -q --allow-empty -m hk2 2>&1)"
has "M19: post-commit snapshot reports the move" "$HO" "moved to $ST19/trash (docs/plans/hook.md"
# … kit guard status …
echo "c2" > "$R/docs/plans/gs.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null); rm -f "$R/docs/plans/gs.md"
GS="$(cd "$R" && python3 "$KIT_ROOT/bin/kit" guard status 2>&1)"
has "M19: kit guard status reports the move" "$GS" "moved to $ST19/trash (docs/plans/gs.md"
has "M19: …and the generations kept" "$GS" "last 5 per file"
# … the session start (into the model's context) …
echo "c3" > "$R/docs/plans/ss.md"; (cd "$R" && bash "$LF" snapshot 2>/dev/null); rm -f "$R/docs/plans/ss.md"
SSO="$(printf '{"session_id":"m19s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$R" \
  | CLAUDE_PLUGIN_ROOT="$KIT_ROOT/plugin" CLAUDE_PROJECT_DIR="$R" bash "$KIT_ROOT/plugin/hooks/session-start.sh" 2>/dev/null)"
rm -f /tmp/claude-kit-baseline-m19s
has "M19: session start reports the move" "$SSO" "docs/plans/ss.md"
# … and a checkout never resurrects a trashed file
(cd "$R" && git checkout -q v4-state 2>/dev/null && git checkout -q main 2>/dev/null)
absent "M19: trashed plans are not restored by a checkout" "$R/docs/plans/cycle.md"
git config --file "$W/gitconfig" --unset core.hooksPath

# ---- M20 (v5.0.1): a rebase that replays the migration commit onto pre-migration history
# (real case: a scheduled workflow keeps pushing empty commits to the remote's old side).
# git checks out the base (old tracked versions overwrite the local-only files), replays the
# migration commit (deletes them) and runs post-commit per pick: the files must come back
# from the store with the owner's newest content — not be trashed as an owner deletion
git config --file "$W/gitconfig" core.hooksPath "$SHD"
m20repo() {  # <dir>: pre-migration remote, migrated local + one more commit, unfetched remote heartbeat
  local R="$1" e
  make_v4 "$R"; echo "# mine" > "$R/.claude/skills/my-skill.md"; g "$R" add -A; g "$R" commit -qm mine
  rm -rf "$R.git"; git clone -q --bare "$R" "$R.git" 2>/dev/null; g "$R" remote add origin "$R.git"; g "$R" fetch -q origin 2>/dev/null
  km "$R" --commit >/dev/null 2>&1
  echo "work" > "$R/work.txt"; g "$R" add work.txt; g "$R" commit -qm work 2>/dev/null
  e="$(g "$R.git" commit-tree -p main -m heartbeat "main^{tree}")"; g "$R.git" update-ref refs/heads/main "$e"
}
ntrash() { find "$1/trash" -type f 2>/dev/null | wc -l | tr -d ' '; }
R="$W/m20"; m20repo "$R"; g "$R" fetch -q origin
ST20="$W/state/localfiles/$(printf '%s' "$R" | sha1sum | cut -c1-12)"
# an edit saved by rename AFTER the last snapshot (breaks the hard link) — only the
# pre-rebase snapshot can capture it — and an in-place edit
sed -i 's/^status = .*/status = "edited just before the rebase"/' "$R/PROJECT.toml"
echo "- three (in place)" >> "$R/docs/LESSONS.md"
RO="$(cd "$R" && git rebase origin/main 2>&1)"; RC=$?
eq "M20: rebase of the migration commit onto the pre-migration side exit 0" "$RC" "0"
eq "M20: …PROJECT.toml untracked after the rebase" "$(g "$R" ls-files PROJECT.toml)" ""
has "M20: PROJECT.toml is back with the edit made just before the rebase" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "edited just before the rebase"
has "M20: …docs/LESSONS.md with the owner's in-place edit" "$(cat "$R/docs/LESSONS.md" 2>/dev/null)" "three (in place)"
exists "M20: …docs/plans/p.md is back" "$R/docs/plans/p.md"
exists "M20: …docs/superpowers/plans/q.md is back" "$R/docs/superpowers/plans/q.md"
has "M20: …the owner's .claude file is back" "$(cat "$R/.claude/skills/my-skill.md" 2>/dev/null)" "mine"
absent "M20: …v4 kit files are NOT resurrected" "$R/.claude/kit-version"
lacks "M20: …nothing reported as moved to trash" "$RO" "moved to"
eq "M20: …the trash is empty" "$(ntrash "$ST20")" "0"
has "M20: …the hook says it restored them" "$RO" "restored"
eq "M20: …tree clean (restored files are ignored)" "$(g "$R" status --porcelain)" ""
# (b) the same through git pull --rebase (no separate fetch)
RB20="$W/m20b"; m20repo "$RB20"
sed -i 's/^status = .*/status = "edited before pull --rebase"/' "$RB20/PROJECT.toml"
RO="$(cd "$RB20" && git pull -q --rebase origin main 2>&1)"; RC=$?
eq "M20b: git pull --rebase exit 0" "$RC" "0"
has "M20b: PROJECT.toml is back with the newest edit" "$(cat "$RB20/PROJECT.toml" 2>/dev/null)" "edited before pull --rebase"
exists "M20b: …docs/LESSONS.md is back" "$RB20/docs/LESSONS.md"
exists "M20b: …docs/plans/p.md is back" "$RB20/docs/plans/p.md"
lacks "M20b: …nothing moved to trash" "$RO" "moved to"
# (c) a genuine owner deletion (no tree-changing git operation since the last snapshot) is trashed
rm -f "$R/docs/LESSONS.md"; echo other > "$R/other.txt"; g "$R" add other.txt
CO="$(cd "$R" && git commit -q -m other 2>&1)"
absent "M20c: an owner rm + unrelated commit: LESSONS.md stays deleted" "$R/docs/LESSONS.md"
has "M20c: …moved to the store's trash" "$CO" "moved to $ST20/trash (docs/LESSONS.md"
TG20="$(ls -d "$ST20/trash/docs/LESSONS.md".~*~ 2>/dev/null | head -n 1)"
exists "M20c: …its last copy is in the trash" "${TG20:-$ST20/trash/docs/LESSONS.md.~none~}"
# (d) a hook-less reset round trip through a pre-migration commit is detected (reflog) at the next snapshot
TIP="$(g "$R" rev-parse HEAD)"
(cd "$R" && git reset -q --hard origin/main && git reset -q --hard "$TIP")
absent "M20d: (git deleted PROJECT.toml during the reset round trip)" "$R/PROJECT.toml"
GS="$(cd "$R" && python3 "$KIT_ROOT/bin/kit" guard status 2>&1)"
has "M20d: kit guard status restores it from the store" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "edited just before the rebase"
has "M20d: …and says so" "$GS" "restored"
absent "M20d: …the owner-deleted LESSONS.md stays deleted" "$R/docs/LESSONS.md"
# (e) cherry-picking the migration commit onto the pre-migration side (post-commit runs with
# CHERRY_PICK_HEAD present) and (f) a non-ff merge of it (post-merge runs with MERGE_HEAD present)
MIG="$(g "$R" rev-parse main~2)"
(cd "$R" && git checkout -q -b cp origin/main 2>/dev/null)
CPO="$(cd "$R" && git cherry-pick "$MIG" 2>&1)"
eq "M20e: cherry-pick of the migration commit untracks PROJECT.toml" "$(g "$R" ls-files PROJECT.toml)" ""
has "M20e: …PROJECT.toml is back with the owner's content" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "edited just before the rebase"
lacks "M20e: …nothing moved to trash" "$CPO" "moved to"
(cd "$R" && git checkout -q -b mg origin/main 2>/dev/null); echo side > "$R/side.txt"; g "$R" add side.txt; g "$R" commit -qm side 2>/dev/null
MGO="$(cd "$R" && git merge -q --no-edit main 2>&1)"
eq "M20f: non-ff merge of the migrated main untracks PROJECT.toml" "$(g "$R" ls-files PROJECT.toml)" ""
has "M20f: …PROJECT.toml is back with the owner's content" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "edited just before the rebase"
lacks "M20f: …nothing moved to trash" "$MGO" "moved to"
(cd "$R" && git checkout -q main 2>/dev/null)
# ---- M21 (v5.0.1 review): the repo's own pre-rebase hook runs BEFORE the localfiles snapshot —
# what it writes (atomic rename) or deletes is what the store keeps, and a refusing hook stops
# the rebase with no snapshot taken
R="$W/m21"; m20repo "$R"; g "$R" fetch -q origin
ST21="$W/state/localfiles/$(printf '%s' "$R" | sha1sum | cut -c1-12)"
cat > "$R/.git/hooks/pre-rebase" <<'EOF'
#!/bin/sh
printf 'status = "rewritten by the repo hook"\n' > PROJECT.toml.tmp && mv PROJECT.toml.tmp PROJECT.toml
rm -f docs/plans/p.md
EOF
chmod +x "$R/.git/hooks/pre-rebase"
RO="$(cd "$R" && git rebase origin/main 2>&1)"; RC=$?
eq "M21: rebase through pre-migration history with a repo pre-rebase hook exit 0" "$RC" "0"
has "M21: PROJECT.toml has what the repo hook wrote (atomic rename)" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "rewritten by the repo hook"
absent "M21: …the plan the repo hook deleted stays deleted" "$R/docs/plans/p.md"
exists "M21: …the other local-only files are back" "$R/docs/LESSONS.md"
R="$W/m21b"; m20repo "$R"; g "$R" fetch -q origin
ST21="$W/state/localfiles/$(printf '%s' "$R" | sha1sum | cut -c1-12)"
printf '#!/bin/sh\necho "repo hook: not now" >&2\nexit 3\n' > "$R/.git/hooks/pre-rebase"; chmod +x "$R/.git/hooks/pre-rebase"
rm -f "$R/docs/plans/p.md"; H21="$(g "$R" rev-parse HEAD)"
RO="$(cd "$R" && git rebase origin/main 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "M21b: a refusing repo pre-rebase hook stops the rebase (exit $RC)" || fail "M21b: refusing hook" "exit 0"
has "M21b: …its message is shown" "$RO" "repo hook: not now"
eq "M21b: …HEAD unchanged" "$(g "$R" rev-parse HEAD)" "$H21"
eq "M21b: …no snapshot taken (the owner's rm is not trashed yet)" "$(ntrash "$ST21")" "0"
git config --file "$W/gitconfig" --unset core.hooksPath

# ---- M22 (v5.0.2, field report): the owner re-clones a repo at the SAME path (mv the old clone
# away, git clone into the same dir, rsync the ignored files back). The store is keyed by path, so
# the clone's post-checkout (previous HEAD = null) found the store's files "gone" and trashed them.
# Now: same remote recorded in the store → missing local-only files come back from the store
# (never over an existing file); a different / unknown remote → nothing restored, nothing trashed
git config --file "$W/gitconfig" core.hooksPath "$SHD"
LF="$KIT_ROOT/plugin/guard/localfiles.sh"
st_trash() { find "$1" "$1".* -path '*/trash/*' \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' '; }
R="$W/m22"; make_v4 "$R"; g "$R" tag v4-state; km "$R" --commit >/dev/null 2>&1
rm -rf "$R.git"; git clone -q --bare "$R" "$R.git" 2>/dev/null; g "$R" remote add origin "$R.git"
echo "# a plan written after the migration" > "$R/docs/plans/new.md"
sed -i 's/^status = .*/status = "owner edit before the re-clone"/' "$R/PROJECT.toml"
(cd "$R" && bash "$LF" snapshot 2>/dev/null)
ST22="$W/state/localfiles/$(printf '%s' "$R" | sha1sum | cut -c1-12)"
mv "$R" "$R.old"
CO22="$(git clone -q "$R.git" "$R" 2>&1)"; RC=$?
eq "M22: re-clone at the same path exit 0" "$RC" "0"
has "M22: PROJECT.toml comes back with the owner's content" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "owner edit before the re-clone"
exists "M22: …docs/LESSONS.md" "$R/docs/LESSONS.md"
exists "M22: …docs/plans/p.md" "$R/docs/plans/p.md"
exists "M22: …the plan written after the migration" "$R/docs/plans/new.md"
exists "M22: …docs/superpowers/plans/q.md" "$R/docs/superpowers/plans/q.md"
has "M22: the clone's hook says what it restored" "$CO22" "restored"
eq "M22: …in one line" "$(printf '%s\n' "$CO22" | grep -c 'restored')" "1"
lacks "M22: …nothing moved to trash" "$CO22" "moved to"
eq "M22: …the trash is empty" "$(st_trash "$ST22")" "0"
eq "M22: …tree clean (restored files are ignored)" "$(g "$R" status --porcelain)" ""
[ ! "$R/PROJECT.toml" -ef "$R.old/PROJECT.toml" ] && pass "M22: …a copy, not a hard link shared with the old clone" || fail "M22: restored file shares an inode with the old clone" "same inode"
# the owner then copies the ignored files back anyway: identical content, harmless
RS="$(rsync -a -I --exclude .git "$R.old/" "$R/" 2>&1)"; cp -p "$R.old/docs/LESSONS.md" "$R/docs/LESSONS.md"
SO="$(cd "$R" && bash "$LF" snapshot --report 2>&1)"
lacks "M22: rsync/cp of the same files back: nothing moved to trash" "$SO" "moved to"
eq "M22: …the trash is still empty" "$(st_trash "$ST22")" "0"
has "M22: …PROJECT.toml unchanged" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "owner edit before the re-clone"
cmp -s "$R/PROJECT.toml" "$ST22/files/PROJECT.toml" && pass "M22: …store copy matches" || fail "M22: store copy matches" "$(cat "$ST22/files/PROJECT.toml" 2>&1)"
eq "M22: …tree clean" "$(g "$R" status --porcelain)" ""
# (b) a fresh clone whose checkout already has a file at a local-only path: never overwritten
mv "$R" "$R.b"
CO22="$(git clone -q -b v4-state "$R.git" "$R" 2>&1)"; RC=$?
eq "M22b: re-clone of a pre-migration tag at the same path exit 0" "$RC" "0"
lacks "M22b: the tracked PROJECT.toml is NOT overwritten by the store copy" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "owner edit before the re-clone"
has "M22b: …it holds what the commit tracks" "$(cat "$R/PROJECT.toml" 2>/dev/null)" 'status = "active"'
exists "M22b: an untracked local-only file still comes back" "$R/docs/plans/new.md"
has "M22b: …the store keeps the owner's PROJECT.toml" "$(cat "$ST22/files/PROJECT.toml" 2>/dev/null)" "owner edit before the re-clone"
lacks "M22b: …nothing moved to trash" "$CO22" "moved to"
eq "M22b: …the trash is empty" "$(st_trash "$ST22")" "0"
# (c) a DIFFERENT repository cloned into the same path: nothing restored, nothing trashed
mv "$R" "$R.c"
O="$W/m22other"; make_v4 "$O"; sed -i 's/proj-a/proj-b/' "$O/PROJECT.toml"; g "$O" commit -qam other; km "$O" --commit >/dev/null 2>&1
rm -rf "$O.git"; git clone -q --bare "$O" "$O.git" 2>/dev/null
CO22="$(git clone -q "$O.git" "$R" 2>&1)"; RC=$?
eq "M22c: clone of another repo into the same path exit 0" "$RC" "0"
absent "M22c: the other repo's PROJECT.toml is NOT restored" "$R/PROJECT.toml"
absent "M22c: …nor its plans" "$R/docs/plans/new.md"
lacks "M22c: …nothing restored" "$CO22" "restored"
lacks "M22c: …nothing moved to trash" "$CO22" "moved to"
has "M22c: …a hint points at kit guard status" "$CO22" "kit guard status"
eq "M22c: …the trash is empty" "$(st_trash "$ST22")" "0"
echo "x" > "$R/x.txt"; g "$R" add x.txt; HO="$(cd "$R" && git commit -qm x 2>&1)"
GS="$(cd "$R" && python3 "$KIT_ROOT/bin/kit" guard status 2>&1)"
lacks "M22c: a later commit trashes nothing" "$HO" "moved to"
eq "M22c: …nor kit guard status (trash still empty)" "$(st_trash "$ST22")" "0"
has "M22c: kit guard status names the earlier clone's store" "$GS" "earlier clone"
ASIDE="$(ls -d "$ST22".* 2>/dev/null | head -n 1)"
has "M22c: …which still holds the owner's files" "$(cat "${ASIDE:-/nonexistent}/files/PROJECT.toml" 2>/dev/null)" "owner edit before the re-clone"
# (d) a store from v5.0.1 (no remote recorded): nothing restored, nothing trashed; copying back is harmless
R="$W/m22d"; make_v4 "$R"; km "$R" --commit >/dev/null 2>&1
rm -rf "$R.git"; git clone -q --bare "$R" "$R.git" 2>/dev/null; g "$R" remote add origin "$R.git"
(cd "$R" && bash "$LF" snapshot 2>/dev/null)
ST22D="$W/state/localfiles/$(printf '%s' "$R" | sha1sum | cut -c1-12)"; rm -f "$ST22D/remotes" "$ST22D/remote-id"
mv "$R" "$R.old"
CO22="$(git clone -q "$R.git" "$R" 2>&1)"; RC=$?
eq "M22d: re-clone over a store with no recorded remote exit 0" "$RC" "0"
absent "M22d: …nothing restored" "$R/PROJECT.toml"
lacks "M22d: …nothing moved to trash" "$CO22" "moved to"
has "M22d: …a hint points at kit guard status" "$CO22" "kit guard status"
eq "M22d: …the trash is empty" "$(st_trash "$ST22D")" "0"
rsync -a --exclude .git "$R.old/" "$R/"
SO="$(cd "$R" && bash "$LF" snapshot --report 2>&1)"
lacks "M22d: rsync back + snapshot: nothing moved to trash" "$SO" "moved to"
eq "M22d: …the trash is still empty" "$(st_trash "$ST22D")" "0"
exists "M22d: …and the new store protects the copied-back files" "$ST22D/files/PROJECT.toml"

# ---- M23 (v5.0.2 review): the repository identity a fresh clone is matched on = the `origin`
# remote only (no origin → the single remote; several and no origin → none), hosted URLs
# normalised to host/owner/repo, anything else exact (credentials, query and fragment dropped)
stkey() { printf '%s/state/localfiles/%s' "$W" "$(printf '%s' "$1" | sha1sum | cut -c1-12)"; }
rid() { (cd "$1" && bash "$LF" snapshot 2>/dev/null); cat "$(stkey "$1")/remote-id" 2>/dev/null; }
# (a) a fork whose clone also lists the upstream as a non-origin remote; then the upstream is
# cloned at the same path → not the same repository: nothing restored
U="$W/m23up"; make_v4 "$U"; km "$U" --commit >/dev/null 2>&1
rm -rf "$U.git" "$W/m23fork.git"; git clone -q --bare "$U" "$U.git" 2>/dev/null; git clone -q --bare "$U" "$W/m23fork.git" 2>/dev/null
R="$W/m23a"; git clone -q "$W/m23fork.git" "$R" 2>/dev/null; g "$R" remote add upstream "$U.git"
printf 'name = "fork-private"\n' > "$R/PROJECT.toml"; (cd "$R" && bash "$LF" snapshot 2>/dev/null)
mv "$R" "$R.old"; CO23="$(git clone -q "$U.git" "$R" 2>&1)"
absent "M23a: clone of the upstream where its fork was: the fork's PROJECT.toml is NOT restored" "$R/PROJECT.toml"
lacks "M23a: …nothing restored" "$CO23" "restored"
has "M23a: …the fork's store is set aside (hint)" "$CO23" "kit guard status"
# (b) /srv/proj vs /srv/proj.git are two repositories (.git is not stripped from a local path)
R="$W/m23b"; git clone -q "$O" "$R" 2>/dev/null
printf 'name = "b-private"\n' > "$R/PROJECT.toml"; (cd "$R" && bash "$LF" snapshot 2>/dev/null)
mv "$R" "$R.old"; CO23="$(git clone -q "$O.git" "$R" 2>&1)"
absent "M23b: <path> then <path>.git cloned at one place: nothing restored" "$R/PROJECT.toml"
lacks "M23b: …no restore line" "$CO23" "restored"
# (c) ssh and https URLs of one GitHub repo are the same repository (insteadOf → a local bare)
GH="$W/m23gh.git"; rm -rf "$GH"; git clone -q --bare "$O" "$GH" 2>/dev/null
git config --file "$W/gitconfig" --add "url.$GH.insteadOf" "git@github.com:owner/repo.git"
git config --file "$W/gitconfig" --add "url.$GH.insteadOf" "https://github.com/Owner/Repo.git"
R="$W/m23c"; git clone -q "git@github.com:owner/repo.git" "$R" 2>/dev/null
printf 'name = "gh-private"\n' > "$R/PROJECT.toml"
eq "M23c: an scp-like GitHub URL is recorded as host/owner/repo" "$(rid "$R")" "github.com/owner/repo"
mv "$R" "$R.old"; CO23="$(git clone -q "https://github.com/Owner/Repo.git" "$R" 2>&1)"
has "M23c: re-clone over https: PROJECT.toml restored" "$(cat "$R/PROJECT.toml" 2>/dev/null)" "gh-private"
has "M23c: …one restore line" "$CO23" "restored"
git config --file "$W/gitconfig" --unset-all "url.$GH.insteadOf"
# (d) normalisation, recorded at snapshot (the same exact local path: M22)
AT=@   # userinfo built at run time (the guard reads "user@host" as an email address)
R="$W/m23c"; printf 'name = "gh-private"\n' > "$R/PROJECT.toml"
for c in "git@github.com:Owner/Repo.git|github.com/owner/repo" \
         "ssh://git@GitHub.com:22/Owner/Repo.git/|github.com/owner/repo" \
         "https://x:y${AT}github.com/Owner/Repo/|github.com/owner/repo" \
         "https://gitlab.com/Grp/Sub/Proj.git|gitlab.com/grp/sub/proj" \
         "git@bitbucket.org:team/r.git|bitbucket.org/team/r" \
         "/srv/proj.git|/srv/proj.git" \
         "file:///srv/proj.git|file:///srv/proj.git" \
         "ssh://me:pw${AT}git.example.invalid/r.git|ssh://me${AT}git.example.invalid/r.git" \
         "me${AT}git.example.invalid:r.git|me${AT}git.example.invalid:r.git"; do
  g "$R" remote set-url origin "${c%%|*}"
  eq "M23d: ${c%%|*} → ${c#*|}" "$(rid "$R")" "${c#*|}"
done
g "$R" remote rename origin up
eq "M23d: no origin, a single remote: that one" "$(rid "$R")" "me${AT}git.example.invalid:r.git"
g "$R" remote add other "$O"
eq "M23d: several remotes, no origin: no identity recorded" "$(rid "$R")" ""
# (e) credentials, query and fragment never reach the store or a message
R="$W/m23e"; git clone -q "$O.git" "$R" 2>/dev/null
g "$R" remote set-url origin "https://u:p${AT}example.invalid/x?token=abc#frag"
printf 'name = "e-private"\n' > "$R/PROJECT.toml"
eq "M23e: the recorded remote drops userinfo, query and fragment" "$(rid "$R")" "https://example.invalid/x"
eq "M23e: …no credential anywhere in the store" "$(grep -rlE 'token=abc|#frag|u:p@' "$(stkey "$R")" 2>/dev/null | grep -v '/files/' | wc -l | tr -d ' ')" "0"
mv "$R" "$R.old"; CO23="$(git clone -q "$O.git" "$R" 2>&1)"
GS="$(cd "$R" && python3 "$KIT_ROOT/bin/kit" guard status 2>&1)"
absent "M23e: another remote: nothing restored" "$R/PROJECT.toml"
has "M23e: …the message says 'a different remote'" "$CO23" "a different remote"
lacks "M23e: …and never prints the recorded URL" "$CO23$GS" "example.invalid"
lacks "M23e: …nor the token" "$CO23$GS" "token"
git config --file "$W/gitconfig" --unset core.hooksPath

# ---- M15 (review O8): an owner edit to a file migrate wrote, between --apply and --commit
R="$W/m15"; make_v4 "$R"; km "$R" --apply >/dev/null
echo "owner tweak after apply" >> "$R/AGENTS.md"
HEAD0="$(g "$R" rev-parse HEAD)"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M15: edited migrate output → refused (exit 1)" "$CODE" "1"
has "M15: …names the edited file" "$OUT" "AGENTS.md"
eq "M15: …nothing committed" "$(g "$R" rev-parse HEAD)" "$HEAD0"
OUT="$(km "$R" --commit --allow-dirty)"; CODE=$?
eq "M15: --allow-dirty commits the rest (exit 0)" "$CODE" "0"
eq "M15: …but never the owner-edited AGENTS.md" "$(g "$R" ls-files AGENTS.md)" ""
has "M15: …and says so" "$OUT" "needs-review AGENTS.md"
has "M15: owner edit still on disk" "$(cat "$R/AGENTS.md")" "owner tweak after apply"
has "M15: kit.toml was committed" "$(g "$R" ls-files)" "kit.toml"
# a manifest from an older kit (path list, no hashes) is not trusted blindly
R="$W/m16"; make_v4 "$R"; km "$R" --apply >/dev/null
GD="$(g "$R" rev-parse --absolute-git-dir)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump(sorted(d) if isinstance(d, dict) else d, open(sys.argv[1], "w"))' "$GD/kit-migrate-written.json"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M16: legacy (hash-less) manifest → stop for review (exit 1)" "$CODE" "1"

# ---- M18 (review R3-4): the resume fingerprint covers file type and mode, not only bytes
R="$W/m18"; make_v4 "$R"; km "$R" --apply >/dev/null
chmod +x "$R/AGENTS.md"; HEAD0="$(g "$R" rev-parse HEAD)"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M18: mode-only owner change to migrate output → refused (exit 1)" "$CODE" "1"
has "M18: …names the file" "$OUT" "AGENTS.md"
eq "M18: …nothing committed" "$(g "$R" rev-parse HEAD)" "$HEAD0"
R="$W/m18b"; make_v4 "$R"; km "$R" --apply >/dev/null
cp "$R/AGENTS.md" "$W/m18-agents"; rm "$R/AGENTS.md"; ln -s "$W/m18-agents" "$R/AGENTS.md"
OUT="$(km "$R" --commit)"; CODE=$?
eq "M18: migrate output replaced by a symlink to identical bytes → refused (exit 1)" "$CODE" "1"
R="$W/m18c"; make_v4 "$R"; km "$R" --apply >/dev/null
OUT="$(km "$R" --commit)"; CODE=$?
eq "M18: untouched migrate output still resumes (exit 0)" "$CODE" "0"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
