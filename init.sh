#!/usr/bin/env bash
# init.sh - bootstrap a project with the multi-agent kit (install-tier only)
#
# Usage:
#   init.sh <target-dir> [--existing] [--profile full|solo]
#
# Copies ONLY the install-tier (.claude/, CLAUDE.md, PROMPTING.md) out of the
# kit repo into <target-dir>. The kit's own docs (README / ARCHITECTURE /
# ADOPTION / USAGE / LICENSE) stay in the kit repo on purpose - they don't
# belong inside your project, and shipping them is what makes "which files can
# I touch?" confusing. After this runs, your project contains exactly two kinds
# of files: the CLAUDE.md you fill in, and the .claude/ infra you leave alone.

set -euo pipefail

# --- locate the kit (this script lives at the kit root) ---
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- parse args ---
TARGET=""
EXISTING=0
PROFILE="${KIT_PROFILE:-full}"

while [ $# -gt 0 ]; do
  case "$1" in
    --existing)  EXISTING=1; shift ;;
    --profile)   PROFILE="${2:-full}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           TARGET="$1"; shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "usage: init.sh <target-dir> [--existing] [--profile full|solo]" >&2
  exit 2
fi
if [ "$PROFILE" != "full" ] && [ "$PROFILE" != "solo" ]; then
  echo "profile must be 'full' or 'solo' (got: $PROFILE)" >&2
  exit 2
fi

# --- resolve target ---
if [ "$EXISTING" -eq 1 ]; then
  [ -d "$TARGET" ] || { echo "--existing given but '$TARGET' is not a directory" >&2; exit 1; }
else
  mkdir -p "$TARGET"
fi
TARGET="$(cd "$TARGET" && pwd)"

MODE="$([ "$EXISTING" -eq 1 ] && echo existing || echo new)"
echo "kit:     $KIT_ROOT"
echo "target:  $TARGET"
echo "profile: $PROFILE   mode: $MODE"
echo

# --- copy install-tier (never the kit's own docs) ---
copied=()
skipped=()

copy_no_clobber() {  # $1 = path relative to kit root
  local rel="$1"
  local src="$KIT_ROOT/$rel"
  local dst="$TARGET/$rel"
  [ -e "$src" ] || return 0
  if [ -e "$dst" ]; then skipped+=("$rel"); return 0; fi
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  copied+=("$rel")
}

# .claude/ : copy file-by-file so existing files are never overwritten
if [ -d "$KIT_ROOT/.claude" ]; then
  while IFS= read -r -d '' f; do
    copy_no_clobber "${f#"$KIT_ROOT/"}"
  done < <(find "$KIT_ROOT/.claude" -type f -print0)
fi

# CLAUDE.md : never overwrite (existing projects often have their own)
if [ -e "$TARGET/CLAUDE.md" ]; then
  cp "$KIT_ROOT/CLAUDE.md" "$TARGET/CLAUDE.md.from-kit"
  skipped+=("CLAUDE.md  (kept yours; template -> CLAUDE.md.from-kit, merge the Workflow Rules half)")
else
  copy_no_clobber "CLAUDE.md"
fi

# PROMPTING.md : the cheat sheet
copy_no_clobber "PROMPTING.md"

echo "copied:"
for c in "${copied[@]:-}"; do [ -n "$c" ] && echo "  + $c"; done
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "skipped (already present, left untouched):"
  for s in "${skipped[@]}"; do echo "  ~ $s"; done
fi
echo

# --- git init (handles the Windows/Git-Bash 'claude exits in non-git dir' gotcha) ---
if [ -d "$TARGET/.git" ]; then
  echo "git:     already a repo, left as-is"
else
  if ( cd "$TARGET" && git init -q && git add -A && git commit -q -m "chore: add multi-agent kit (install-tier)" ); then
    echo "git:     initialised + initial commit"
  else
    echo "git:     init failed (not fatal) - run 'git init' yourself"
  fi
fi
echo

# --- environment check (informational; never blocks) ---
chk() {  # $1 label  $2 test-expr  $3 fix
  if eval "$2" >/dev/null 2>&1; then
    printf '  [ ok ] %s\n' "$1"
  else
    printf '  [FIX] %s\n         -> %s\n' "$1" "$3"
  fi
}

echo "environment check ($PROFILE profile):"
chk "claude CLI installed" "command -v claude" \
    "install Claude Code: https://docs.claude.com/en/docs/claude-code/getting-started"
if [ "$PROFILE" = "full" ]; then
  chk "codex CLI installed"  "command -v codex" \
      "npm i -g @openai/codex && codex login"
  chk "gemini CLI installed" "command -v gemini" \
      "npm i -g @google/gemini-cli"
  chk "GEMINI_API_KEY set"   '[ -n "${GEMINI_API_KEY:-}" ]' \
      "export GEMINI_API_KEY=AIza...  (persist it; Windows: setx GEMINI_API_KEY ...)"
fi
chk "KIT_PROFILE set"        '[ -n "${KIT_PROFILE:-}" ]' \
    "export KIT_PROFILE=$PROFILE   (add to your shell profile so it sticks per-machine)"
echo

# --- next step ---
echo "next:"
echo "  cd $TARGET && claude"
echo
echo "  then paste the section-0 bootstrap from PROMPTING.md:"
if [ "$EXISTING" -eq 1 ]; then
  echo "    請先探索整個 repo，把你看到的架構、慣例、以及不該碰的區域"
  echo "    寫進 CLAUDE.md 的對應段落。先不要改任何其他檔案。"
else
  echo "    這個專案是 [一句話]，stack 用 [語言/框架]。"
  echo "    請把 CLAUDE.md 的 goal / stack / file layout 填好，constraints 先留空。"
fi
if [ "$PROFILE" = "full" ]; then
  echo
  echo "  (first time on THIS machine only) inside claude, install the codex plugin:"
  echo "    /plugin marketplace add openai/codex-plugin-cc"
  echo "    /plugin install codex@openai-codex"
  echo "    /reload-plugins  &&  /codex:setup"
fi
