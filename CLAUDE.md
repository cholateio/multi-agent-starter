# [PROJECT NAME]

> CLAUDE.md (kit v3.2, profile-aware). Fill the [PLACEHOLDERS] below on first
> use - or just run `claude` and paste the bootstrap prompt printed at the end
> of `init.sh` and let it fill them for you.
> Multi-agent workflow rules are auto-loaded from `.claude/rules/kit-workflow.md`
> (kit-owned - do not edit here; customize the kit repo and redeploy via
> `--update`).

## Project goal

[一句話描述這個專案是什麼、核心目的。
 例：「給小型團隊用的 expense tracking SaaS，優先 self-host。」]

## Stack

- Language: [e.g. Python 3.12 / TypeScript 5.4 / Go 1.22]
- Framework: [e.g. FastAPI / Next.js 14 / none]
- Datastore: [e.g. PostgreSQL 16 / SQLite / none]
- Build/run: [e.g. pnpm / make / cargo]
- Test: [e.g. pytest / vitest / cargo test]

## File layout

[新專案首次架構決策後填入；既有專案貼 `tree -L 2`。]

## Coding standards

[實際 standards。例：functions single-responsibility / no `any` / Result types。]

## Project-specific constraints

[此專案特殊規則 - 對既有專案這是最重要的段落。例：
 - `src/legacy/payment/` 不可修改，會破壞舊金流
 - 所有 DB writes 必須走 repository pattern
 新專案可留空，由使用累積。]
