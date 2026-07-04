# Model Dispatch & Escalation Rules

> **Kit-owned file.** Overwritten verbatim by `init.sh --update`. To
> customize, edit the kit repo and redeploy — do not edit this copy.
> 前提假設：主對話（指揮官）= 當前可用的最強模型；Sonnet/Haiku = 輕量
> 執行員。review 與 isolation 規則在 kit-workflow.md，本檔不重複。

## 指揮官不下場（context 經濟）

主對話的 context 是唯一不可再生資源。指揮官只做五件事：**決策、架構、
派工、驗收、跟 user 對話**。

- 硬規則只有一條：**subagent 回報禁止貼超過 20 行代碼**——用「路徑:行號
  + 一句結論」，指揮官需要細節就自己去讀那幾行。收到噴代碼的回報，
  要求重報，而不是照單全收進 context（回報噴代碼才是 context 污染的
  實際來源）。
- 必須派工的情況：**全 repo 掃描、預估要碰 >10 個檔案、或位置未知的
  搜索**（不知道在哪就別自己翻）。
- 其餘交給指揮官的經濟判斷：派一個 subagent 的真實成本約 10-30k tokens
  （onboarding + 探索 + 回報），直接讀 400 行約 5k——中型閱讀往往
  直接讀更便宜。**別為了儀式感派工**，也別把 context 當免費資源。

## 派工三件套（缺一不派）

每個 subagent prompt 必須包含，一件都不能省：

1. **目標與背景**：要達成什麼、為什麼、從哪些檔案入手（給路徑）。
2. **驗收條件（AC）**：可機械檢查的完成定義（測試通過、檔案存在、
   輸出格式吻合），不是「做好做滿」這種空話。
3. **回報格式**：成果路徑與關鍵行號、驗證證據（測試輸出原文）、
   摘要行數上限、禁大段代碼。

四種任務型態的填空模板：invoke `/kit-dispatch` skill。

## 模型檔位與升降級

| 檔位 | 用途 |
|------|------|
| haiku | 機械性批次：套用已定案的 pattern、重命名、跑既有腳本 |
| sonnet | 輕量實作：寫測試（TDD 測項）、單檔小修、文件、格式化 |
| 主對話模型（opus 級以上） | 架構、多檔改動、除錯根因；review 與驗收的**派發與把關**（cross-model review 本身由 codex 執行、驗收由 fresh-context subagent 執行——見 kit-workflow.md 與下方隔離驗收） |

**升級路徑（自動執行，不必問 user）：**

- haiku 出現 **1 次**工具或語法錯誤 → 同任務直接改派 sonnet 重做。
- sonnet 同一子任務**連續 2 次**卡關或出錯 → 停止重試，把錯誤軌跡
  （做了什麼 / 錯誤原文 / 已排除什麼）整理後升級給主對話模型處理。
- 兩輪升級重試後，只有**帶著新診斷**（新線索、新假設——不是同一個
  診斷換個寫法）才准再試一輪；連新診斷都提不出來 → STOP，帶完整錯誤
  軌跡問 user。限制的是「無新資訊的重複」，不是嘗試次數本身
  （judgment-matrix R1 的同一條原則）。

**降級路徑（省 token）：**

- 主對話模型解出固定模式後，把模式寫成一次性 script 或逐步指令，
  交回 sonnet/haiku 批次套用——不要讓貴的模型做重複勞動。

**硬規則：sonnet/haiku 永不指派 review、驗收、或 auth/payment/security
判斷。** 這不是能力歧視，是這套 harness 的信任邊界。

## 隔離驗收（implementer ≠ verifier）

- 寫 code 的 agent **不得自我宣告完成**——完成與否由驗收方認定。
- 驗收方式（指揮官擇一指派）：
  1. **fresh-context subagent read-back**：重新讀檔案實體、實跑測試、
     對照 AC 逐條打勾（常規）。
  2. **多樣本評審**：高 stakes 時多個獨立 subagent 各自評審再選優。
- 指揮官收到「已寫入 X」的回報，接受前**必做最低驗證**：`ls` / Read
  確認檔案存在且非空。subagent 幻覺回報「已寫入」實際沒落檔，是已知
  的弱模型失敗模式——不驗證就接受等於共犯。
- 卡關判斷、完成判準、何時問 user：讀 `.claude/docs/judgment-matrix.md`。
