#!/usr/bin/env bash
#
# setup.sh — verify multi-agent-starter v3 environment
#
# Run from project root. Checks that:
#   1. Required CLIs are present (claude, codex, gemini)
#   2. codex-plugin-cc plugin is installed in claude
#   3. gemini wrapper is executable and responds
#   4. Multi-agent kit files are in place

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Verifying CLIs"
echo

MISSING=0
check() {
    local name="$1"
    local cmd="$2"
    local install_hint="$3"
    if command -v "$cmd" >/dev/null 2>&1; then
        local version=$("$cmd" --version 2>&1 | head -1 || echo "?")
        printf "  ✓ %-12s  %s\n" "$name" "$version"
    else
        printf "  ✗ %-12s  MISSING — %s\n" "$name" "$install_hint"
        MISSING=$((MISSING + 1))
    fi
}

check "claude"  "claude"  "https://docs.claude.com/en/docs/claude-code/getting-started"
check "codex"   "codex"   "auto-installed via /codex:setup, or: npm install -g @openai/codex"
check "gemini"  "gemini"  "npm install -g @google/gemini-cli"
check "jq"      "jq"      "needed by hooks. Windows: included in Git Bash. Linux: apt install jq. macOS: brew install jq"

echo
if [[ $MISSING -gt 0 ]]; then
    echo "  $MISSING required CLI(s) missing. Install them, then re-run setup.sh"
    echo "  (You can still proceed — only the affected features will fail.)"
    echo
fi

echo "==> Checking codex-plugin-cc"
echo
echo "  Once you have claude installed and authenticated, run these commands"
echo "  inside Claude Code to install the codex plugin:"
echo
echo "    /plugin marketplace add openai/codex-plugin-cc"
echo "    /plugin install codex@openai-codex"
echo "    /reload-plugins"
echo "    /codex:setup"
echo
echo "  This is a one-time setup per machine. The plugin replaces the"
echo "  custom codex wrappers from earlier kit versions."
echo

echo "==> Verifying kit files"
for f in CLAUDE.md \
         README.md \
         USAGE.md \
         .claude/agents/gemini-research-scout.md \
         .claude/skills/research-before-planning/SKILL.md \
         .claude/scripts/gemini_exec.sh \
         .claude/hooks/classify-task.sh \
         .claude/hooks/verify-final-review.sh \
         .claude/settings.json; do
    if [[ -f "$f" ]]; then
        echo "  ✓ $f"
    else
        echo "  ✗ $f MISSING"
    fi
done

echo
echo "==> Verifying executables"
for s in .claude/scripts/gemini_exec.sh \
         .claude/hooks/classify-task.sh \
         .claude/hooks/verify-final-review.sh; do
    if [[ -x "$s" ]]; then
        echo "  ✓ $s"
    else
        echo "  ! $s (fixing)"
        chmod +x "$s"
    fi
done

echo
echo "==> Checking GEMINI_API_KEY"
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    echo "  ✓ GEMINI_API_KEY is set"
else
    echo "  ! GEMINI_API_KEY not set — research-scout will fail until you set it."
    echo "    Get a key at https://aistudio.google.com/apikey"
    echo "    Then: export GEMINI_API_KEY='AIza...' (add to ~/.bashrc to persist)"
fi

echo
echo "==> Smoke-testing gemini wrapper (skip with: SKIP_SMOKE=1 ./setup.sh)"
echo
if [[ "${SKIP_SMOKE:-0}" != "1" ]] && command -v gemini >/dev/null 2>&1; then
    gemini_out=$(timeout 30 .claude/scripts/gemini_exec.sh "say 'gemini ok' and stop" 2>&1)
    gemini_exit=$?
    if [[ $gemini_exit -eq 0 ]] && [[ -n "$gemini_out" ]]; then
        echo "  ✓ gemini wrapper responds"
    else
        echo "  ✗ gemini wrapper failed (exit $gemini_exit). Full output:"
        echo "$gemini_out" | sed 's/^/      /'
        echo "      → check GEMINI_API_KEY env var, trust settings, or quota"
    fi
else
    echo "  (skipped)"
fi

echo
echo "==> Setup check complete."
echo
echo "Next steps:"
echo
echo "  1. Edit CLAUDE.md — fill in [PROJECT NAME], goal, stack, layout,"
echo "     and (especially for legacy projects) Project-specific constraints"
echo
echo "  2. Optionally enable hooks: edit .claude/settings.json to uncomment"
echo "     the hooks block. See USAGE.md section 5 for what each hook does."
echo
echo "  3. (If new project) Initialize git: git init && git add -A && git commit -m 'init'"
echo
echo "  4. Start Claude Code: claude"
echo
echo "  5. Inside Claude Code, install the codex plugin (one-time):"
echo "       /plugin marketplace add openai/codex-plugin-cc"
echo "       /plugin install codex@openai-codex"
echo "       /reload-plugins"
echo "       /codex:setup"
echo
echo "  6. See USAGE.md for prompt templates for the 6 task scenarios."
