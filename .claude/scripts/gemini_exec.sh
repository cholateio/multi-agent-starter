#!/usr/bin/env bash
#
# gemini_exec.sh — non-interactive gemini CLI wrapper
#
# Used exclusively by gemini-research-scout subagent for web research.
# We do NOT use gemini for code review in v3 — that's codex-plugin's job.
#
# Usage:
#   echo "your prompt" | ./gemini_exec.sh
#   ./gemini_exec.sh "your prompt"

set -euo pipefail

if [[ $# -ge 1 ]]; then
    PROMPT="$1"
else
    PROMPT="$(cat)"
fi

if [[ -z "${PROMPT// }" ]]; then
    echo "ERROR: empty prompt" >&2
    exit 2
fi

if ! command -v gemini >/dev/null 2>&1; then
    echo "ERROR: gemini CLI not found in PATH. Install: npm install -g @google/gemini-cli" >&2
    exit 3
fi

# Run gemini in non-interactive headless mode.
# --skip-trust: gemini 0.39+ refuses non-trusted dirs without this
# -p: single-prompt headless
# < /dev/null: explicitly close stdin so gemini doesn't hang for 3s
gemini --skip-trust -p "$PROMPT" < /dev/null 2>&1
