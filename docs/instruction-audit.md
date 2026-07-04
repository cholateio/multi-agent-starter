# Instruction Audit — 例行規則審計（kit repo 維護文件）

> 不部署進專案。Prompt 模板採自 fable-soul（MIT）的 Instruction Audit
> prompt。**時機：每次 minor 版本發佈前跑一次**；或任何時候懷疑規則
> 層之間開始互相矛盾。
>
> 為什麼需要：kit 的 prose 分四層（CLAUDE.md 範本、`.claude/rules/`、
> `judgment-matrix`、dispatch 模板判斷句），外加 superpowers 等 plugin
> 的注入。層與層之間的重複、矛盾、過時補丁是可預期的腐化路徑
> （handover-from-fable §二·3「規則稀釋」的近親）——而目前沒有任何
> 物理防線能偵測「兩條規則打架」，只能靠例行審計。

## 怎麼跑

開一個 fresh session（或派 fresh-context subagent，read-only），貼上
下面的 prompt。審計是**唯讀**的：先報告，不修。修正走正常流程
（kit repo 修改 + RED-GREEN 收據 + `--update`）。

```text
把這個 kit 會載入 session 的指令檔從頭到尾讀完：CLAUDE.md 範本、
.claude/rules/*.md、.claude/docs/judgment-matrix.md、
.claude/skills/*/SKILL.md、.claude/agents/*.md、hooks 注入的訊息字串
（session-start.sh 的 KIT_CONTEXT/RE-ANCHOR、classify-task.sh 的
digest、verify-final-review.sh 的 block message）。

只報告，不要修。

1. 哪裡規則互相矛盾？引用兩邊原文與檔案路徑。
2. 哪些規則只是在補償某個弱模型或舊工具的限制？該失敗模式如今
   還存在嗎（給證據或標 unverified）？
3. 哪些文件以身違例——自己違反了自己開的規則？
4. 哪些規則跨層重複？指出 canonical 位置與該刪/壓縮的副本。
   特別檢查：kit 規則 vs superpowers skills 的重疊。
5. 留/刪/改的建議清單。每項附：防的失敗模式、觸發條件、proof
   surface、退場條件（strip condition）。
```

## 產出的處理

- 每個 finding 對照代碼實體驗證過才算數（kit-judgment 8：沒驗證的
  警告製造假工作）。
- 修正屬 kit-owned prose 變更 → 走 kit-evolution「規則變更紀律」
  （先查覆蓋、RED-GREEN 收據、總量預算）。
- 審計本身跑完記一行在下表，含日期與結論摘要——沒有 finding 也記
  （「未發現」是合法結果）。

## Audit log

| Date | Scope | Findings | 處理 |
|------|-------|----------|------|
| (尚未跑過) | | | |
