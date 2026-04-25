# Multi-Agent Starter Kit v3

Reusable starter kit for using **Claude Code + Superpowers + Codex Plugin + Gemini CLI**
together in a clean separation-of-concerns architecture.

## What this is

A standardized starting point for any new project (or to drop into existing
projects) that gives you:

- **Cross-model code review** that's hard to forget (via Codex Plugin's official integration)
- **External research** before planning when needed (via Gemini)
- **Battle-tested workflow rules** for what triggers when
- **Optional discipline hooks** so the rules don't rely on AI memory

## What's new in v3 (vs v2)

v2 implemented cross-model review by writing custom MCP-style wrappers
around codex/gemini CLIs. **v3 deletes most of that** because OpenAI
released `codex-plugin-cc` — an official plugin that does the same job
better and with first-party support.

What v3 keeps:
- Gemini CLI for **research only** (its real strength)
- Custom workflow rules in CLAUDE.md
- Optional hooks for stronger discipline
- The full A-F prompt cookbook in USAGE.md

What v3 removes:
- All `codex_*` wrappers and subagents (replaced by Codex Plugin)
- The `handoff-context-format` skill (plugin handles context internally)
- The `cross-model-review` skill (plugin's `/codex:review` slash command)
- The `plan-with-review` skill (replaced by superpowers + plugin)

## Documents in this kit

| File | Purpose |
|------|---------|
| `README.md` | This file — navigation and overview |
| `CLAUDE.md` | **Read by Claude every session.** Multi-agent workflow rules. |
| `USAGE.md` | **Read by you.** Operations manual: prompt templates, hooks, debug |
| `ADOPTION.md` | Guide for adding the kit to existing projects |
| `ARCHITECTURE.md` | Why the kit works the way it does (design rationale) |
| `setup.sh` | Environment verification |

## Quick start

### New project

```bash
cp -r multi-agent-starter-v3 my-new-project
cd my-new-project
git init && git add -A && git commit -m "init"
export GEMINI_API_KEY="AIza..."
./setup.sh
# Edit CLAUDE.md placeholders
claude
# Inside Claude Code:
#   /plugin marketplace add openai/codex-plugin-cc
#   /plugin install codex@openai-codex
#   /reload-plugins
#   /codex:setup
```

Then see USAGE.md for what to type next.

### Existing project

See `ADOPTION.md` for the safe onboarding flow. Don't skip it — AI not
knowing your codebase conventions is the biggest source of legacy-project
mishaps.

## Prerequisites

```bash
# Claude Code — https://docs.claude.com/en/docs/claude-code/getting-started

# Codex CLI (auto-installed when you run /codex:setup, or:)
npm install -g @openai/codex
codex login

# Gemini CLI
npm install -g @google/gemini-cli
# Get API key from https://aistudio.google.com/apikey
export GEMINI_API_KEY="AIza..."
# (Persistent on Windows: setx GEMINI_API_KEY "AIza...")
```

The kit will partially work even if codex or gemini isn't installed —
specific features just won't be available. Claude Code itself is the only
hard requirement.

## Architecture in 30 seconds

```
You ─── prompt ───▶ Main Claude (orchestrator)
                       │
       ┌───────────────┼───────────────┐
       ▼               ▼               ▼
   Gemini          Superpowers      Codex Plugin
  (research)       (plan+execute)    (review)
```

Three external AI capabilities, each doing what they're best at. Main
Claude orchestrates. You approve plans and that's mostly it.

For full design rationale see `ARCHITECTURE.md`.

## Customization

The kit is designed to be edited:

- **Change workflow rules**: edit `CLAUDE.md`
- **Change task classification**: edit `.claude/hooks/classify-task.sh`
- **Add a domain skill**: drop a `SKILL.md` into `.claude/skills/`
- **Disable hooks**: edit `.claude/settings.json`

All edits take effect on next Claude Code session start. No infrastructure
to restart, no rebuild step.

## Environment gotchas

**Windows + Git Bash**: `claude` may exit immediately in non-git directories.
Run `git init` first, or launch from PowerShell.

**Codex 0.123+**: requires git repo or `--skip-git-repo-check`. Plugin handles
this for you.

**Gemini 0.39+**: stricter trusted-directory checks. Wrapper handles this.

**Permission prompts**: `tail -f` paths include changing UUIDs. Just accept,
or add allow patterns to `.claude/settings.json`.

See USAGE.md section 7 for full debug guide.

## Versioning notes

- **v1 (deprecated)**: PAL MCP-based — abandoned due to maintainer concerns
- **v2 (legacy)**: Custom codex/gemini wrappers — superseded by codex-plugin-cc
- **v3 (current)**: Codex Plugin + Gemini for research + minimal custom code

If you're starting today, use v3. v2 is preserved for projects that already
adopted it.
