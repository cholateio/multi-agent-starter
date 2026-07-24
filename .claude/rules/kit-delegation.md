# Model Dispatch & Escalation Rules

> **Kit-owned.** Don't edit here — change in the kit repo, then `init.sh --update`.
> 前提假設：主對話（指揮官）= 當前可用的最強模型；Sonnet/Haiku = 輕量
> 執行員。review 與 isolation 規則在 kit-workflow.md，本檔不重複。

## 指揮官不下場（context 經濟）

主對話 context 是唯一不可再生資源。指揮官只做五件事：**決策、架構、派工、
驗收、跟 user 對話**。

- 硬規則只有一條：**subagent 回報禁貼超過 20 行代碼**——用「路徑:行號 +
  一句結論」，要細節自己讀那幾行。收到噴代碼的回報要求重報，不照收進 context。
- 必須派工：**全 repo 掃描、預估碰 >10 檔、或位置未知的搜索**（不知在哪
  別自己翻）。
- 其餘算成本：一個 subagent 約 10-30k tokens，直讀 400 行約 5k——中型
  閱讀直接讀更便宜。**別為了儀式感派工**，也別把 context 當免費資源。
- **每 phase 派工前重過 sizing 閘**（kit-workflow）：trivial／~≤10 行的
  phase 指揮官 inline 做或併進相鄰實質 task，不為它開 implementer＋reviewer
  ——fresh subagent 光重載稅 15-20k，3 行直改約 5k（收據 2026-07-23：3 個
  10 行 phase 各走完整派工+獨立 review＝205k）。

## 派工三件套（缺一不派）

每個 subagent prompt 必須包含，一件都不能省：

1. **目標與背景**：達成什麼、為什麼、從哪些檔案入手（給路徑）。
2. **驗收條件（AC）**：可機械檢查的完成定義（測試通過、檔案存在、輸出格式
   吻合），不是「做好做滿」空話。
3. **回報格式**：成果路徑與關鍵行號、驗證證據（測試輸出原文）、摘要行數
   上限、禁大段代碼。

五種任務型態的填空模板（研究/實作/重構/審查/驗收 read-back）：
invoke `/kit-dispatch` skill。

## 模型檔位與升降級

| 檔位 | 用途 |
|------|------|
| haiku | 機械性批次：套用已定案的 pattern、重命名、跑既有腳本 |
| sonnet | 輕量實作：寫測試（TDD 測項）、單檔小修、文件、格式化 |
| 主對話模型（opus 級+） | 架構、多檔改動、除錯根因；review／驗收的**派發與把關**（執行者見 kit-workflow 與下方隔離驗收） |

**升級路徑（自動執行，不必問 user）：**

- haiku 出現 **1 次**工具或語法錯誤 → 同任務直接改派 sonnet 重做。
- sonnet 同一子任務**連續 2 次**卡關 → 停止重試，把錯誤軌跡（做了什麼／
  錯誤原文／已排除什麼）升級給主對話模型。
- 兩輪升級後只有**帶著新診斷**（新線索/假設，非同一診斷換寫法）才准再試；
  提不出 → STOP，帶完整軌跡問 user。限制的是「無新資訊的重複」，非嘗試
  次數（judgment-matrix R1）。

**降級路徑（省 token）：**

- 主對話模型解出固定模式後，把模式寫成一次性 script 或逐步指令，交回
  sonnet/haiku 批次套用——別讓貴的模型做重複勞動。

**硬規則：sonnet/haiku 永不指派 review、驗收、或 auth/payment/security
判斷。**

## 隔離驗收（implementer ≠ verifier）

- 寫 code 的 agent **不得自我宣告完成**——完成與否由驗收方認定。
- 驗收方式（指揮官擇一）：(1) **fresh-context read-back**：重讀檔案實體、
  實跑測試、對照 AC 逐條打勾（常規）；(2) **多樣本評審**：高 stakes 時多個
  獨立 subagent 各評再選優。
- 收到「已寫入 X」的回報，接受前**必做最低驗證** `ls`／Read 確認檔案存在
  且非空——幻覺回報「已寫入」實際沒落檔是已知失敗模式。
- 卡關判斷、完成判準、何時問 user：讀 `.claude/docs/judgment-matrix.md`。
