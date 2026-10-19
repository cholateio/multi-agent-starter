# Instruction Audit — 例行規則審計（kit repo 維護文件）

> 不部署進專案。Prompt 模板採自 fable-soul（MIT）的 Instruction Audit
> prompt。**時機：每次 minor 版本發佈前跑一次**；或任何時候懷疑規則
> 層之間開始互相矛盾。
>
> 為什麼需要：kit 的 prose 分四層（CLAUDE.md 範本、`.claude/rules/`、
> `judgment-matrix`、dispatch 模板判斷句），外加 superpowers 等 plugin
> 的注入。層與層之間的重複、矛盾、過時補丁是可預期的腐化路徑
> （harness-diagnosis §五·3「規則稀釋」的近親）——而目前沒有任何
> 物理防線能偵測「兩條規則打架」，只能靠例行審計。

## 怎麼跑

開一個 fresh session（或派 fresh-context subagent，read-only），貼上
下面的 prompt。審計是**唯讀**的：先報告，不修。修正走正常流程
（kit repo 修改 + RED-GREEN 收據 + /reload-plugins）。

```text
把這個 kit 會載入 session 的指令檔從頭到尾讀完：AGENTS.md／CLAUDE.md
範本、plugin/rules/*.md（含 subagent-digest.md）、plugin/skills/*/SKILL.md、
plugin/agents/*.md、hooks 注入的訊息字串（inject-rules.sh 的 KIT_RULES、
session-start.sh 的 KIT_CONTEXT/RE-ANCHOR、classify-task.sh 的 digest、
verify-final-review.sh 的 block message、protect-paths／tool-breaker 的
deny/ask 理由）。

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
| 2026-08-02 | CLAUDE.md 範本、rules×5、judgment-matrix、verification-signals、skills×4、agents×2、hooks 注入字串、superpowers/codex plugin 交叉 | Q1 矛盾×4、Q2 補償性×5（2 keep 已驗證仍需）、Q3 以身違例×2、Q4 跨層重複×6 組、Q5 留/刪/降 15 條 | v4.9 Task 3-6 執行；明細與逐條 verdict 見 design-history/2026-08-02-audit-findings.md |
| 2026-10-19 | v5 改寫：rules×5 + subagent-digest、skills×6、agents×2、hooks 注入字串（作者自審，非 fresh session） | 過期路徑 3（已修）、矛盾 0、跨層重複 1（接受） | 見下節 |

## 2026-10-19 v5 改寫審計

範圍：Task 2.7 的逐字替換之後，對五個 rules 檔逐條確認（矛盾、過期路徑、重複），
並掃 skills/agents/hook 訊息字串。執行者 = 改寫者本人（同 session，非 fresh
context；隔離度低於上一輪，限制已揭露）。

- 殘留檢查：`grep -rnE 'init\.sh --update|\.claude/docs/|/kit-(review|skip-review|dispatch)|research-before-planning|\.claude/protected-paths' plugin/` → 0。
- 過期路徑（已修）：kit-workflow「`KIT_PROFILE` env var selects the profile」漏了
  v5 的 `config.toml` 後備；kit-workflow 兩處 size-blind 敏感路徑清單未含
  `kit.toml`（Stop gate 已把它列入）；kit-evolution 減法紀律 #2「無 .claude 的
  headless」→「不載 kit plugin 的 headless」。
- 矛盾：未發現。kit-evolution 誰可以改什麼表與 protect-paths v5 行為一致（plugin
  root／`~/.config/kit`／git config → ask；`kit.toml` 可加嚴、放寬由 Stop gate
  的敏感路徑地板攔）。
- 跨層重複（接受）：subagent-digest.md 重述 kit-judgment 1/3/4/8 與 kit-delegation
  「回報禁貼 >20 行」——刻意：SessionStart 注入不進 subagent，digest 是唯一常駐
  載體；canonical 仍是 kit-judgment / kit-delegation。
- 未改：kit-judgment / kit-delegation 內的「judgment-matrix R1/R3/R4」裸稱呼保留
  （同檔已指向 `/kit:judgment` skill，R 編號沿用）。
- 預算：rules 19,684 B ≤ 20,480 B；core 8,118 / judgment 4,950 chars ≤ 9,500；
  digest 607 chars ≤ 2,000。
