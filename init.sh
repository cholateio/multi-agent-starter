#!/usr/bin/env bash
# init.sh - bootstrap or update a project with the multi-agent kit
#
# Usage:
#   init.sh <target-dir> [--update] [--profile full|solo]
#
# Install mode (default): init.sh <target-dir>
#   Mode (new/existing) is auto-detected from whether <target-dir> is empty.
#   Copies ONLY the install-tier out of the kit repo - .claude/, CLAUDE.md,
#   README.md, .gitignore, docs/specs/, and mise.toml (only if this machine
#   has mise) - no-clobber: existing files in the target are never
#   overwritten. The kit's own docs (README / ARCHITECTURE / tests /
#   VERSION) stay in the kit repo on purpose - they don't belong inside your
#   project, and shipping them is what makes "which files can I touch?"
#   confusing.
#
# Update mode: init.sh <target-dir> --update
#   Re-deploys the kit-owned files under
#   .claude/{rules,hooks,scripts,agents,skills,docs}/ into an existing kit
#   project, add-or-overwrite. Deploys .claude/settings.json only when the
#   project has none; never overwrites an existing settings.json or your
#   CLAUDE.md. Flags orphaned kit-owned files and legacy monolithic
#   CLAUDE.md for you to handle by hand. No backups are made - use
#   `git diff` / `git checkout -- <path>` to review or revert.
#
# --existing has been removed as of v3.2: mode is auto-detected now, just
# run init.sh <dir>.

set -euo pipefail

# --- locate the kit (this script lives at the kit root) ---
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_VERSION="$(cat "$KIT_ROOT/VERSION" 2>/dev/null || echo "0.0.0")"
KIT_SHA="$(git -C "$KIT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- parse args ---
TARGET=""
UPDATE=0
PROFILE="${KIT_PROFILE:-full}"

while [ $# -gt 0 ]; do
  case "$1" in
    --update)    UPDATE=1; shift ;;
    --existing)  echo "--existing 已移除:v3.2 起自動偵測,直接執行 init.sh <dir>" >&2; exit 2 ;;
    --profile)   [ $# -ge 2 ] || { echo "--profile needs a value" >&2; exit 2; }
                 PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -h|--help)   sed -n '1d; /^#/ { s/^# \{0,1\}//; p; b; }; q' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           TARGET="$1"; shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "usage: init.sh <target-dir> [--update] [--profile full|solo]" >&2
  exit 2
fi
if [ "$PROFILE" != "full" ] && [ "$PROFILE" != "solo" ]; then
  echo "profile must be 'full' or 'solo' (got: $PROFILE)" >&2
  exit 2
fi

# --- shared helpers ---
chk() {  # $1 label  $2 test-expr  $3 fix
  if eval "$2" >/dev/null 2>&1; then
    printf '  [ ok ] %s\n' "$1"
  else
    printf '  [FIX] %s\n         -> %s\n' "$1" "$3"
  fi
}

write_kit_version() {  # writes .claude/kit-version - kit-owned, overwritten every run
  mkdir -p "$TARGET/.claude"
  printf 'v%s %s %s\n' "$KIT_VERSION" "$KIT_SHA" "$(date +%F)" > "$TARGET/.claude/kit-version"
}

# enumerate_kit_files: NUL-terminated absolute paths of kit-owned files under
# $1 (path relative to KIT_ROOT, e.g. ".claude" or ".claude/rules"). Prefers
# `git ls-files` so only what the maintainer actually committed ships into a
# project - not whatever else happens to be sitting on their disk (future
# settings.local.json, plugin state, ...). Falls back to plain `find` when
# KIT_ROOT isn't a git checkout (e.g. a tarball download).
enumerate_kit_files() {  # $1 = path relative to KIT_ROOT
  # Only trust ls-files when KIT_ROOT IS the git toplevel - if KIT_ROOT is a
  # non-git directory nested inside some unrelated parent repo, rev-parse
  # would otherwise succeed against that parent and `ls-files -- .claude`
  # would silently return nothing, deploying zero kit files.
  if [ "$(git -C "$KIT_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$KIT_ROOT" ]; then
    git -C "$KIT_ROOT" ls-files -z -- "$1" | while IFS= read -r -d '' rel; do
      printf '%s\0' "$KIT_ROOT/$rel"
    done
  else
    find "$KIT_ROOT/$1" -type f -print0 2>/dev/null
  fi
}

if [ "$UPDATE" -eq 1 ]; then
  # ============================ update mode ============================
  if [ ! -d "$TARGET" ] || [ ! -d "$TARGET/.claude" ]; then
    echo "error: 不是 kit 專案,先跑 init.sh $TARGET" >&2
    exit 1
  fi
  TARGET="$(cd "$TARGET" && pwd)"

  echo "kit:     $KIT_ROOT"
  echo "target:  $TARGET"
  echo "mode:    update"
  echo

  # dirty working tree: soft warning only, never blocks
  if [ -d "$TARGET/.git" ] && [ -n "$(git -C "$TARGET" status --porcelain 2>/dev/null)" ]; then
    echo "warning: 建議先 commit 再 update,方便 git diff 檢視變更"
    echo
  fi

  # version transition
  if [ -f "$TARGET/.claude/kit-version" ]; then
    FROM="$(cut -d' ' -f1 "$TARGET/.claude/kit-version" 2>/dev/null || echo pre-v3.2)"
    [ -n "$FROM" ] || FROM="pre-v3.2"
  else
    FROM="pre-v3.2"
  fi
  echo "update: $FROM → v$KIT_VERSION"
  echo

  # --- overwrite the kit-owned set: rules, hooks, scripts, agents, skills, docs ---
  # add-or-overwrite: this is how a v3.1 project picks up rules/kit-workflow.md.
  # "docs" (v4.0) carries on-demand references like judgment-matrix.md.
  # .claude/settings.json is deliberately NOT in this set.
  KIT_OWNED_DIRS="rules hooks scripts agents skills docs"
  updated=0
  unchanged=0
  warnings=0
  updated_list=()

  for d in $KIT_OWNED_DIRS; do
    [ -d "$KIT_ROOT/.claude/$d" ] || continue
    while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue  # tracked-but-deleted-on-disk kit file - nothing to copy
      rel="${f#"$KIT_ROOT/"}"
      dst="$TARGET/$rel"
      changed=0
      if [ -f "$dst" ] && cmp -s "$f" "$dst"; then
        : # content already matches
      else
        mkdir -p "$(dirname "$dst")"
        cp "$f" "$dst"
        changed=1
      fi
      # sync executability regardless of whether content changed - cp alone
      # doesn't do this: it leaves an existing dst's mode untouched, so a
      # kit-side chmod (e.g. a script going 644 -> 755) would otherwise never
      # reach already-installed projects. [ -x ] keeps this portable (no
      # `stat` flags, no GNU-only `chmod --reference`).
      if [ -x "$f" ] && [ ! -x "$dst" ]; then
        chmod +x "$dst"
        changed=1
      elif [ ! -x "$f" ] && [ -x "$dst" ]; then
        chmod a-x "$dst"
        changed=1
      fi
      if [ "$changed" -eq 1 ]; then
        updated=$((updated + 1))
        updated_list+=("$rel")
      else
        unchanged=$((unchanged + 1))
      fi
    done < <(enumerate_kit_files ".claude/$d")
  done

  # --- settings.json: deploy-if-absent (never overwrite an existing one) ---
  if [ -f "$KIT_ROOT/.claude/settings.json" ] && [ ! -f "$TARGET/.claude/settings.json" ]; then
    cp "$KIT_ROOT/.claude/settings.json" "$TARGET/.claude/settings.json"
    updated=$((updated + 1))
    updated_list+=(".claude/settings.json")
  fi

  echo "updated:"
  for u in "${updated_list[@]:-}"; do [ -n "$u" ] && echo "  + $u"; done
  echo

  # --- orphan detection (informational only; never deletes or modifies) ---
  orphans=()
  for d in $KIT_OWNED_DIRS; do
    [ -d "$TARGET/.claude/$d" ] || continue
    while IFS= read -r -d '' f; do
      rel="${f#"$TARGET/"}"
      [ -e "$KIT_ROOT/$rel" ] || orphans+=("$rel")
    done < <(find "$TARGET/.claude/$d" -type f -print0)
  done
  if [ "${#orphans[@]}" -gt 0 ]; then
    echo "非 kit 檔(你自己的,或 kit 已淘汰):"
    for o in "${orphans[@]}"; do echo "  - $o"; done
    warnings=$((warnings + 1))
    echo
  fi

  if [ -f "$TARGET/PROMPTING.md" ]; then
    echo "kit 已不再提供 PROMPTING.md,可自行刪除"
    warnings=$((warnings + 1))
    echo
  fi

  if [ -f "$TARGET/.claude/agents/gemini-research-scout.md" ] || [ -f "$TARGET/.claude/scripts/gemini_exec.sh" ]; then
    echo "kit 已不再整合 gemini(研究改由 Claude 原生 research-scout 子代理完成):"
    echo "  可刪除 .claude/agents/gemini-research-scout.md 與 .claude/scripts/gemini_exec.sh,"
    echo "  settings.json 裡的 gemini_exec allow 行也可一併移除"
    warnings=$((warnings + 1))
    echo
  fi

  # --- settings.json: never overwritten, just flagged ---
  if [ -f "$KIT_ROOT/.claude/settings.json" ] && [ -f "$TARGET/.claude/settings.json" ] \
     && ! cmp -s "$KIT_ROOT/.claude/settings.json" "$TARGET/.claude/settings.json"; then
    echo "settings.json 與 kit 模板不同(不會覆蓋,如需新設定請手動合併):"
    diff -u "$TARGET/.claude/settings.json" "$KIT_ROOT/.claude/settings.json" || true
    echo
    echo "最省事的合併法 - 在專案裡開 claude,貼上這句:"
    echo "「把 kit 模板($KIT_ROOT/.claude/settings.json)的 hooks 區塊和權限基線"
    echo "  合併進這個專案的 .claude/settings.json,保留我既有的條目;合併後用 jq 驗證,"
    echo "  完成後提醒我重啟 session 讓 hooks 生效。」"
    warnings=$((warnings + 1))
    echo
  fi

  # --- legacy monolithic CLAUDE.md detection ---
  if [ -f "$TARGET/CLAUDE.md" ] && grep -q "Multi-Agent Workflow Rules" "$TARGET/CLAUDE.md"; then
    cat <<'EOF'
偵測到舊版單體 CLAUDE.md。把下面這句貼給 claude 完成遷移:
「刪除 CLAUDE.md 裡『Multi-Agent Workflow Rules』標題起的整段(規則已移至
.claude/rules/kit-workflow.md),保留上半的專案內容。」
EOF
    warnings=$((warnings + 1))
    echo
  fi

  write_kit_version
  echo "updated $updated, unchanged $unchanged, warnings $warnings"
  echo "檢視或還原本次 update 的變更: git diff / git checkout -- <path>"
  exit 0
fi

# ============================== install mode ==============================
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"

if [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  MODE=new
else
  MODE=existing
fi

echo "kit:     $KIT_ROOT"
echo "target:  $TARGET"
echo "profile: $PROFILE   mode: $MODE"
echo

# --- copy install-tier, no-clobber (never the kit's own docs) ---
copied=()
skipped=()

copy_as_no_clobber() {  # $1 = src path rel to KIT_ROOT   $2 = dst path rel to TARGET
  local src="$KIT_ROOT/$1"
  local dst="$TARGET/$2"
  [ -e "$src" ] || return 0
  if [ -e "$dst" ]; then skipped+=("$2"); return 0; fi
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  copied+=("$2")
}

copy_no_clobber() {  # $1 = path relative to kit root (same path in target)
  copy_as_no_clobber "$1" "$1"
}

# .claude/ : copy file-by-file so existing files are never overwritten
if [ -d "$KIT_ROOT/.claude" ]; then
  while IFS= read -r -d '' f; do
    copy_no_clobber "${f#"$KIT_ROOT/"}"
  done < <(enumerate_kit_files ".claude")
fi

# CLAUDE.md : never overwrite (existing projects often have their own)
if [ -e "$TARGET/CLAUDE.md" ]; then
  cp "$KIT_ROOT/CLAUDE.md" "$TARGET/CLAUDE.md.from-kit"
  skipped+=("CLAUDE.md  (kept yours; template -> CLAUDE.md.from-kit, merge manually)")
else
  copy_no_clobber "CLAUDE.md"
fi

# project templates : README / gitignore, renamed on the way in
copy_as_no_clobber "templates/README.md" "README.md"
copy_as_no_clobber "templates/gitignore" ".gitignore"
copy_as_no_clobber "templates/PROJECT.toml" "PROJECT.toml"

# docs/specs/ : spec-driven entry point (kit-workflow.md looks here)
if [ -d "$TARGET/docs/specs" ]; then
  skipped+=("docs/specs/  (already exists)")
else
  mkdir -p "$TARGET/docs/specs"
  : > "$TARGET/docs/specs/.gitkeep"
  copied+=("docs/specs/.gitkeep")
fi

# mise.toml : only if this machine uses mise; silent (no message at all) otherwise
if command -v mise >/dev/null 2>&1; then
  copy_as_no_clobber "templates/mise.toml" "mise.toml"
fi

echo "copied:"
for c in "${copied[@]:-}"; do [ -n "$c" ] && echo "  + $c"; done
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "skipped (already present, left untouched):"
  for s in "${skipped[@]}"; do echo "  ~ $s"; done
fi
echo

# --- kit-version marker (kit-owned; written on both install and update) ---
# written BEFORE git init so a new project's initial commit includes it
# instead of leaving it untracked.
write_kit_version

# --- git init (handles the Windows/Git-Bash 'claude exits in non-git dir' gotcha) ---
# The whole section is soft under `set -e`: every git invocation that could
# fail (missing binary, init failing, commit failing) sits inside an if/else
# branch (exempt from errexit) rather than as a naked statement, so a git
# problem never aborts the rest of the install (env check + next-step prompt
# must still print, exit 0).
if [ -d "$TARGET/.git" ]; then
  echo "git:     already a repo, left as-is"
elif ! command -v git >/dev/null 2>&1; then
  echo "git:     not installed (not fatal) - install git, then run 'git init' yourself"
else
  git_init_ok=1
  if ! git -C "$TARGET" init -q -b main >/dev/null 2>&1; then
    # older git without `init -b` support
    if git -C "$TARGET" init -q && git -C "$TARGET" symbolic-ref HEAD refs/heads/main; then
      : # fallback succeeded
    else
      git_init_ok=0
      echo "git:     init failed (not fatal) - run 'git init' yourself"
    fi
  fi

  if [ "$git_init_ok" -eq 1 ]; then
    if git -C "$TARGET" config user.name >/dev/null 2>&1 && git -C "$TARGET" config user.email >/dev/null 2>&1; then
      if git -C "$TARGET" add -A && git -C "$TARGET" commit -q -m "chore: add multi-agent kit (install-tier)"; then
        echo "git:     initialised (branch main) + initial commit"
      else
        echo "git:     commit failed (not fatal) - commit manually"
      fi
    else
      echo "git:     initialised (branch main); commit skipped - git identity not set"
      chk "git user.name configured"  "git -C \"$TARGET\" config user.name"  'git config --global user.name "Your Name"'
      chk "git user.email configured" "git -C \"$TARGET\" config user.email" 'git config --global user.email "you@example.com"'
    fi
  fi
fi
echo

# --- environment check (informational; never blocks) ---
echo "environment check ($PROFILE profile):"
chk "claude CLI installed" "command -v claude" \
    "install Claude Code: https://docs.claude.com/en/docs/claude-code/getting-started"
if [ "$PROFILE" = "full" ]; then
  chk "codex CLI installed"  "command -v codex" \
      "npm i -g @openai/codex && codex login"
fi
chk "KIT_PROFILE set"        '[ -n "${KIT_PROFILE:-}" ]' \
    "export KIT_PROFILE=$PROFILE   (add to your shell profile so it sticks per-machine)"
echo

# --- next step ---
echo "next:"
echo "  cd $TARGET && claude"
echo
echo "  then paste this bootstrap prompt:"
if [ "$MODE" = "new" ]; then
  echo "    這個專案是 [一句話],stack 用 [語言/框架]。"
  echo "    請填好 CLAUDE.md 的 goal / stack / file layout(constraints 留空)和 README.md 的佔位符。"
  echo "    並依專案現況填 PROJECT.toml(狀態、起始指令、付費的外部服務)。"
else
  echo "    請先探索整個 repo,把架構、慣例、以及「不該碰的區域」寫進 CLAUDE.md,並填 README.md 的佔位符;"
  echo "    若架構值得記錄,建 docs/ARCHITECTURE.md(大綱:分層、data flow、要改 X 先看 Y、歷史遺留);"
  echo "    並依探索所得填 PROJECT.toml(狀態、起始指令、付費的外部服務)。"
  echo "    先不要改任何其他檔案。"
fi
if [ "$PROFILE" = "full" ]; then
  echo
  echo "  (first time on THIS machine only) inside claude, install the codex plugin:"
  echo "    /plugin marketplace add openai/codex-plugin-cc"
  echo "    /plugin install codex@openai-codex"
  echo "    /reload-plugins  &&  /codex:setup"
fi
