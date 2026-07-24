# Project Manifest 規則

> **Kit-owned.** Don't edit here — change in the kit repo, then `init.sh --update`.

`PROJECT.toml`（專案根目錄）是專案狀態的機器可讀 manifest，user-owned，`proj`
靠它做跨專案彙總。Session 結束前若本次工作觸發以下任一事件，更新它並把
`updated` 改成今天：

- 專案狀態跨越階段（如 MVP 完成、決定擱置）→ `status` / `status_note`
- 起始指令新增或改變 → `[commands]`
- 新增或移除付費外部服務（SaaS / LLM API）→ `[[paid]]`

`status_note`：固定兩段以分號隔開——「目前進度;下一步」，**每段一句話、上限
60 字**（`proj` 對超標與段數不符發警告）。細節（bug 經過、數據、待辦、金額、
commit hash）不寫這裡，歸 LESSONS／commit message。

2026-07-13 實測 11/12 專案違反，藉口都是「這個細節很重要」——重要不代表放
這裡（dashboard 不是筆記本）。寫前問：**半年後掃這行要知道的是「現在在哪、
下一步」，不是「發生過什麼」。**

`[commands]`（寧缺勿濫）：只收「**用它**」的指令——專案自己提供的工具/服務
啟動與操作（例 `uv run yt-summary "<url>"`），不收「**開發它**」的
（dev/build/test/lint/deploy——查得到的不抄）。
判準：半年後回來「用」它需要的才收。單條上限 **80 字**（`proj` warn），更長的
包成腳本再收。

`[[paid]]` 每個欄位都是卡片上的**一格**，不是註腳。`proj` 對超標發警告：

- `service`：只放服務名（`Supabase`、`GitHub Pro`），不放說明（那是 badge，
  一眼認出服務用）。
- `billing`：**封閉枚舉** `按用量 | 月費 | 年費 | free-tier`。填別的值會被
  當成「按用量」，固定月費就從 KPI 的固定月費項**靜默消失**。
- `monthly_est`：金額與用量,以幣別（NT$/US$）+ 週期（/月|/年）起頭，dashboard 才
  加得進月總和;上限 40 字，**不夾確認日期或算法依據**（`proj` warn `YYYY-MM-DD`／確認）。
- `cancel`：怎麼停止付錢。dashboard 不渲染，只在 `proj money` 與 TOML 看得到。

只更新事實，不改 schema。不確定某服務是否付費：照列，加 `# 待確認`。
