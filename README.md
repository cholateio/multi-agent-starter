# Multi-Agent Starter Kit

You use Claude Code with Superpowers and the Codex plugin, and you end up as the human message router between them. This kit installs once per machine and makes the three agents work in clean roles, with a different model reviewing every change and a git guard that keeps private material out of your commits.

![Layered diagram of the kit: install layer (kit CLI, tests, templates), harness layer (hooks, rules, skills), runtime roles (orchestrator, subagents, reviewer) and project state](docs/architecture/overview.svg)

- **One install**: a single Claude Code plugin per machine; projects carry only `AGENTS.md` and `kit.toml`.
- **Cross-model review**: a Stop gate holds the turn until a different model has reviewed the change set.
- **Physical guardrails**: hooks block risky edits, runaway retries and verifier pipes that hide a red test.
- **Leak guard**: every `git commit` and `git push` on the machine is scanned for secrets, local paths and personal literals.

Requires Claude Code, git, Python 3.11 or newer, and (for cross-model review) the Codex CLI.

## How it works

```
you ── task ──► Claude (orchestrator) ──► Superpowers  (plan + implement)
                       │            └───► research-scout (read-only research)
                       └── Stop gate ──► Codex review (a different model)
git commit / git push (any tool) ──► global hooksPath ──► kit guard
```

Hooks and rules activate only in directories that contain a `kit.toml`, so the plugin stays silent everywhere else, including your home directory. Details and trade-offs are in [`ARCHITECTURE.md`](ARCHITECTURE.md); the defense inventory is in [`DEFENSES.md`](DEFENSES.md).

## Install

You need Claude Code installed and signed in. For the `full` review profile also run `npm i -g @openai/codex && codex login`; without Codex set `export KIT_PROFILE=solo` and review falls back to a fresh-context Claude reviewer.

1. Clone the kit and keep it: `git clone https://github.com/cholateio/multi-agent-starter ~/.multi-agent-kit`
2. Run the one-time machine setup: `~/.multi-agent-kit/bin/kit setup` (add `--dry-run` first to see every step).
3. Check it: `kit doctor` should print only `OK` lines.

To install the plugin from GitHub instead of the local checkout, run `claude plugin marketplace add cholateio/multi-agent-starter` and `claude plugin install kit@multi-agent-kit`, or pass `--marketplace github` to `kit setup`.

`kit setup` installs the plugin at user scope, merges a minimal permission baseline into `~/.claude/settings.json`, points git's global `core.hooksPath` at the guard shims, and downloads pinned, checksum-verified `gitleaks` and `osv-scanner` (or records the absolute path of an already-installed copy of the pinned version — the guard never looks them up on `PATH`). `kit setup --uninstall` reverses it.

## Use it in a project

```bash
kit init ~/projects/my-thing              # new project: AGENTS.md, CLAUDE.md, kit.toml, README, LICENSE, .gitignore
kit init ~/projects/my-thing --private    # non-public repository: private README, no public-only checks
kit migrate ~/projects/old-v4-project     # dry-run; add --apply --commit to migrate a v4 project
cd ~/projects/my-thing && claude
```

`kit init` prints one bootstrap prompt; paste it into Claude to fill in the placeholders. `kit.toml` is the activation marker and holds the repo's visibility, license and protected paths (zones the AI may not edit without your confirmation). Existing files are never overwritten.

Day to day you describe a task and approve the plan. Add a modifier to override sizing: `直接做` (just do it), `走完整流程` (full flow), or `請質疑這個設計` (challenge the design). Run `/kit:review` to pass the Stop gate, or `/kit:skip-review` to skip it with an audit trail. Do not enable `/codex:setup --enable-review-gate`; the kit's own gate does the same job without looping.

## Guard and audit

The guard runs on every commit and push on the machine, whether a person or an AI makes it:

| Check | Result |
|---|---|
| Secrets (gitleaks plus kit rules) | block |
| Files that must never be pushed (`.claude/`, `PROJECT.toml`, `*.local.toml`, `.env*`, plans) | block |
| Local paths and your personal literals from `~/.config/kit/privacy.local.toml` | block |
| Other home paths, emails, scratch paths | warn |

Your personal literals (names of private projects, cloud ids, emails) live only in `~/.config/kit/privacy.local.toml` (mode 600) and are never printed back. A deliberate exception goes in `kit.toml` (`allow_literals` by name, or `allow_paths`); a `kit-privacy: allow` comment on the line only silences warning-level rules (other home paths, emails, scratch paths) and is itself reported and logged. `kit guard status` shows the install state; `kit guard bypass "<reason>"` is a single-use, audited override that only a person at a terminal can run.

`kit audit` scans every repo under your configured root and GitHub settings: leaked history, personal literals in the tree and in history, tracked forbidden paths, README hygiene, workflow pinning, vulnerable lockfiles. It prints a table and exits non-zero on CRITICAL or HIGH findings. Add `--html` for a report and `--baseline <file>` to see only new findings.

## Development

```bash
claude --plugin-dir ./plugin     # run Claude with the working-tree plugin
bash tests/run-all.sh            # every smoke suite plus the Python unit tests
claude plugin validate ./plugin --strict
```

`tests/guard-smoke.sh` and `tests/audit-smoke.sh` build their fixtures at runtime in temp directories with an isolated `HOME`, so they never touch your real configuration. Release checklist: all suites green, then the rule audit in [`docs/instruction-audit.md`](docs/instruction-audit.md).

## Documentation

| File | Content |
|---|---|
| [`DEFENSES.md`](DEFENSES.md) | Prompt, context and harness defenses, and the guard rules (zh-TW) |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Why the kit is shaped this way; version history v1 to v5 (zh-TW) |
| [`docs/harness-diagnosis.md`](docs/harness-diagnosis.md) | Failure scenarios behind the hook design (zh-TW) |
| [`docs/instruction-audit.md`](docs/instruction-audit.md) | Rule audit procedure (zh-TW) |
| [`docs/design-history/`](docs/design-history/) | Historical plans and specs; not living documents |

## License

[MIT](LICENSE). Built on Claude Code, the Superpowers plugin and the Codex plugin.
