# Project Manifest 規則

> **Kit-owned file.** Overwritten verbatim by `init.sh --update`. To
> customize, edit the kit repo and redeploy — do not edit this copy.

`PROJECT.toml`（專案根目錄）是專案狀態的機器可讀 manifest，user-owned，
`proj` 指令靠它做跨專案彙總。

Session 結束前，若本次工作觸發以下任一事件，同步更新 PROJECT.toml，
並把 `updated` 改成今天：

- 專案狀態跨越階段（如 MVP 完成、決定擱置）→ `status` / `status_note`
- 起始指令新增或改變 → `[commands]`
- 新增或移除付費外部服務（SaaS / LLM API）→ `[[paid]]`

只更新事實，不改 schema。不確定某服務是否付費：照列，加 `# 待確認`。
