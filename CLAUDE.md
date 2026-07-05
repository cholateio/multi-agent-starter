# [PROJECT NAME]

> CLAUDE.md（kit v4.2）。本檔只放「這個專案是什麼」——工作流、派工、
> review 規則由 `.claude/rules/` 自動載入（kit-owned，別在專案裡改）。
> 首次使用：跑 `claude`，貼上 `init.sh` 結尾印出的 bootstrap prompt，
> 讓 AI 幫你把 [佔位符] 填掉。

## Project goal

[一句話：這個專案是什麼、給誰用、核心目的。
 例：「給小型團隊用的 expense tracking SaaS，優先 self-host。」]

## Stack

- Language: [例：Python 3.12 / TypeScript 5.4 / Go 1.22]
- Framework: [例：FastAPI / Next.js 14 / none]
- Datastore: [例：PostgreSQL 16 / SQLite / none]
- Build/run: [完整指令，例：`pnpm dev` / `make run`]
- Test: [完整指令，例：`pytest -q` / `pnpm vitest run`——弱模型會照抄
  這一行來跑驗證，寫到可以直接複製執行的程度]

## File layout

[新專案：首次架構決策後填入。既有專案：貼 `tree -L 2` 並在關鍵目錄後
 加一句用途註記。例：
 - `src/api/` — HTTP handlers，薄層，不放業務邏輯
 - `src/core/` — 業務邏輯，所有 DB writes 走 repository]

## Project-specific constraints（禁區與硬規則）

[本專案的不可違反規則。格式：每條一行，「路徑或範圍：規則 + 原因 +
 替代作法」。越具體越好。例：
 - `src/legacy/payment/`：不可修改——會破壞舊金流；新需求走 `src/payment_v2/`
 - 所有 DB writes 必須走 repository pattern，不准裸 SQL
 新專案可留空，踩到坑再累積。]

**同步執法**：上面每一條「路徑型」禁區，都要把路徑同步加進
`.claude/protected-paths`（一行一個 glob，`*` 會跨目錄層級，
`src/legacy/` 結尾斜線代表整棵子樹）——PreToolUse hook 會物理擋下
對這些路徑的編輯，不再只靠模型自律。放寬或刪除任何一條需要 user
明確同意（見 kit-evolution 規則）。

## 檔案路由（需要時才讀，不用背）

| 情境 | 讀這裡 |
|------|--------|
| 卡關了 / 想宣告完成 / 猶豫要不要問 user | `.claude/docs/judgment-matrix.md` |
| 要派工給 subagent | `/kit-dispatch` skill（五種模板） |
| 要記教訓 / 想改 harness 檔案 | `docs/LESSONS.md`（append）/ kit-evolution 規則（自動已載入） |
| 有 spec 的功能 | `docs/specs/`（spec 是需求的唯一權威來源） |
| 專案歷史教訓 | `docs/LESSONS.md`（存在的話，動大手術前先掃一眼） |
| 要做 UI / 設計 schema / 同一 bug 連續卡 / 引入外部服務 / 定架構 | `.claude/docs/verification-signals.md`（命中哪節讀哪節） |

（review / isolation / 任務 sizing / 派工升降級 / 判斷層的規則不在
本檔——`.claude/rules/` 的 kit-workflow、kit-delegation、kit-evolution、
kit-judgment 已自動載入每個 session，直接遵守即可。）
