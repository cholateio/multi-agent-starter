# multi-agent-starter

## Project goal

kit v5 本身的 repo:Claude Code plugin + `kit` CLI + 本機 git guard,給「一個人 + 多個 AI agent」的專案用。

## Stack

- Language / framework: Bash(hooks、guard)、Python 3.11 純標準庫(`kit` CLI)
- Services: none(gitleaks / osv-scanner 由 `kit doctor --install` 以 sha256 釘版安裝)
- Test: `bash tests/run-all.sh`   <!-- 全部 smoke + unit;gitleaks 相關斷言需要 $KIT_TOOLS/gitleaks 或 PATH 上的 gitleaks -->

## File layout

- `plugin/` — 出貨給使用者的 plugin:`hooks/`、`rules/`、`skills/`、`agents/`、`guard/`、`templates/`
- `cli/` + `bin/kit` — `kit` CLI;`bin/proj` — 專案總覽
- `tests/` — smoke(`tests/*.sh`)+ unit(`tests/unit/`);`tests/tools/anonymize.py` 是一次性匿名化腳本
- `docs/design-history/` — 歷史設計與 plan(非活文件);`ARCHITECTURE.md` / `DEFENSES.md` 為活文件

## Constraints

- 這個 repo 是 **public**——任何 commit 都要陌生人安全:不寫私人專案名(用 `proj-a…` 代稱)、金額、本機絕對路徑、使用者名、cloud id。
- 測試 fixture 的 `/home/<user>` 字串在執行期組出(`HP=/home`、`"/ho" "me"`),不用 `kit-privacy: allow` 標記。
- 版本號只在 `VERSION`;`plugin/.claude-plugin/plugin.json` 與 marketplace.json 由 `tests/plugin-validate.sh` 對齊。
- Path-type constraints are mirrored in `kit.toml [protected]`; keep the two in sync (one glob per line).

## Conventions

- 改 hook / rule / guard 後:`bash tests/run-all.sh` 必須全綠;`claude plugin validate ./plugin --strict`。
- `README.md` 英文;長文件(ARCHITECTURE / DEFENSES / design-history)zh-TW。
- `claude --plugin-dir ./plugin` 用工作樹的 plugin 跑 session。
- GitHub Actions: top-level `permissions: contents: read`, raised per job only when needed; pin every `uses:` to a 40-character commit SHA with a trailing `# vX.Y.Z` comment.

## Where to look

- `ARCHITECTURE.md` — 元件與資料流
- `DEFENSES.md` — 每道防線擋什麼、不擋什麼(誠實條款)
- `docs/design-history/2026-10-19-kit-v5-design.md` — v5 設計與決策
