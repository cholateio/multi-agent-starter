# multi-agent-starter

kit v5 本身的 repo(Claude Code plugin + `kit` CLI + 本機 git guard)。
這個 repo 是 **public**——任何 commit 都要陌生人安全:不寫私人專案名(用 `proj-a…` 代稱)、
金額、本機絕對路徑、使用者名、cloud id。測試 fixture 的 `/home/<user>` 字串要在執行期組出。

## 結構

- `plugin/` — 出貨給使用者的 plugin:`hooks/`、`rules/`、`skills/`、`agents/`、`guard/`、`templates/`
- `cli/` + `bin/kit` — `kit` CLI(Python 3.11,純標準庫);`bin/proj` — 專案總覽
- `tests/` — `bash tests/run-all.sh` 跑全部 smoke + unit;`tests/tools/anonymize.py` 是一次性匿名化腳本
- `docs/design-history/` — 歷史設計與 plan(非活文件);`ARCHITECTURE.md` / `DEFENSES.md` 為 zh-TW 長文

## 開發

- `claude --plugin-dir ./plugin` 用工作樹的 plugin 跑 session
- 改 hook / rule / guard 後:`bash tests/run-all.sh` 必須全綠;`claude plugin validate ./plugin --strict`
- 版本號只在 `VERSION`;`plugin/.claude-plugin/plugin.json` 與 marketplace.json 由 `tests/plugin-validate.sh` 對齊
- `README.md` 英文;長文件(ARCHITECTURE / DEFENSES / design-history)zh-TW
