# Design History（歷史紀錄，非活文件）

> 2026-07-24 文件瘦身時，由 `docs/superpowers/{plans,specs}/` 扁平化搬來，
> 並收入外部研究文件。**這裡的東西不是現行規範**——現行規範看
> `.claude/rules/`（自動載入）、`.claude/docs/`（路由載入）、
> `docs/harness-diagnosis.md`（防線設計依據）。

## 這裡有什麼

- **`YYYY-MM-DD-kit-vX.Y-*.md`** — 各版本當時的 plan / spec（v3.2–v4.5）。
  記錄「當時為什麼這樣決定」，價值在考古，不在照著做。
- **`AI Coding Agent.md`** — 外部研究文件（Prompt → Context → Harness 框架），
  v3.5 的 gap 分析依據。

## 讀這裡要注意

1. **內文的路徑引用是歷史的，刻意不回改。** 檔案裡提到的
   `docs/superpowers/specs/...` 就是現在的 `docs/design-history/...`——
   kit 的既有慣例是「歷史紀錄不回頭改寫」（見 v3.4 spec 自述），改寫會讓
   紀錄失去它作為當時快照的價值。
2. **內容會過時。** 這些文件寫於各自的版本當下，後續版本可能已推翻其中的
   決定。版本演進的權威摘要在 `ARCHITECTURE.md §二`。
