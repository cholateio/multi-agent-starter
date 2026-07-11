---
name: kit-dispatch
description: Fill-in dispatch templates for delegating work to subagents.
  Use whenever you are about to spawn a subagent (Agent tool) for research,
  implementation, refactoring, or verification/review — copy the matching
  template, fill every blank, then dispatch. Enforces the kit-delegation
  "派工三件套" (goal+context / acceptance criteria / report format).
---

# /kit-dispatch — 標準化派工模板

派工三件套（目標背景 / 驗收條件 / 回報格式）缺一不派——規則在
kit-delegation.md，本 skill 提供直接可抄的模板。**用法：選對模板 →
填掉所有【】→ 作為 Agent tool 的 prompt 送出。** 不准送出還留著【】的
prompt。模型檔位選擇與升降級規則見 kit-delegation.md（review 類任務
永不派給 sonnet/haiku）。

> **為什麼判斷句寫死在模板裡（snapshot caveat，實測 2026-07-03）**：
> subagent 只繼承 session **啟動時**的指令快照——session 中途更新的
> rules / CLAUDE.md 到不了 subagent。對弱執行員，模板 prompt 是判斷
> 規則唯一保證送達的載體。填模板時不要刪下面的判斷句與措辭紀律。

---

## 模板 1：深度搜尋與研究（Search & Research）

```text
【任務】研究【主題】，回答下列問題，供【接下來要做的決策】使用。
【背景】本專案是【一句話】，stack：【語言/框架】。先讀 CLAUDE.md 與
【相關檔案路徑，如 docs/specs/xxx.md】了解脈絡。
【問題清單】（2-5 條，每條要能被明確回答）
1. 【問題一】
2. 【問題二】
【約束】必須尊重：【如「須離線可用」「不能加新依賴」】。
【驗收條件】
- 每個問題都有明確答案或明確標註「查不到」。
- 區分「fetch 原文驗證過」與「僅來自搜尋摘要（標 unverified）」。
- 附日期與來源連結，primary source 優先。
【回報格式】≤40 行。結構：每問題一段（結論 → 證據來源 → 信心度
low/medium/high）。禁止貼長篇引文，給連結與一句摘要即可。
```

## 模板 2：新功能實作（Implementation）

```text
【任務】實作【功能一句話】。
【背景】先讀：CLAUDE.md（含 Project-specific constraints）、
【plan/spec 路徑】、【入手檔案路徑:行號】。既有慣例參考【同類功能的
現存檔案路徑】——照它的模式寫，不要發明新風格。
【範圍】只改【目錄/檔案清單】。禁止動：【明確排除清單，至少把
constraints 禁區抄進來】。
【驗收條件】（可機械檢查，逐條）
1. 【行為一：給輸入 X 得輸出 Y】
2. 測試【指令，如 pytest tests/test_x.py -q】全數通過。
3. 不新增依賴（或：僅可新增【白名單】）。
【註解紀律】註解只寫代碼顯示不了的：不變量、跨檔耦合、非顯然 why
——其餘零註解。不敘述代碼在做什麼；改動理由寫進回報，不進註解。
【回報格式】≤25 行。必含：
- 改動清單：路徑:行號範圍 + 每檔一句「改了什麼」。
- 測試輸出原文（最後 5 行）。
- AC 逐條「達成/未達成 + 證據位置」。
- 未解決事項與 TASTE-DECISION 標記（若有）。
【措辭紀律】只有實跑過的才可寫「通過/完成」；沒跑過的一律寫
「changed but not yet verified」。可驗證的主張禁用「應該/大概」
修飾——能跑就跑。測試綠燈後又改過任何相關檔案 = 該綠燈作廢，
重跑之後才准回報。
禁止貼超過 20 行代碼。你的回報不算完成宣告——驗收由另一個
fresh-context agent 執行（模板 5）。
```

## 模板 3：架構重構（Refactoring）

```text
【任務】重構【目標一句話，如「把 X 模組的 DB 存取收斂進 repository」】。
行為必須完全不變——這是重構，不是改功能。
【背景】先讀：CLAUDE.md constraints、【現況說明或 plan 路徑】、
重構範圍內的所有檔案：【清單】。
【安全網】動手前先跑【測試指令】記下基線結果（貼進回報）；重構後
必須得到完全相同的通過集合。無測試覆蓋的部分：先補「特性測試」
（characterization test）鎖住現行為，再動手。
【範圍】只改【清單】。任何 public API / 匯出符號的簽名變更 = 超出
範圍，立刻停下回報，不要「順便」。
【驗收條件】
1. 重構前後測試結果完全一致（貼兩次輸出原文對照）。
2. 【結構目標，如「X.py 不再 import sqlalchemy」——用可 grep 的形式寫】
3. diff 總量 ≤【N】行；超過就停下回報，可能方向錯了（judgment-matrix R1.4）。
【註解紀律】不新增敘述性註解；只有新結構需要一行不變量/耦合說明時才加。
【回報格式】≤25 行：改動清單（路徑:行號）、前後測試輸出對照、
結構目標逐條驗證（附 grep 指令與結果）。禁大段代碼。
【措辭紀律】貼進回報的「後」測試輸出必須晚於最後一次改動——改了
就重跑，改動前的綠燈證明不了改動後的代碼。沒跑過的主張標
unverified，不用「應該」。
```

## 模板 4：代碼與安全審查（Code Review）

> 派發對象限制：cross-model review 走 `/kit-review`（→ codex），
> fresh-context 自審用 solo-reviewer agent。**永不派給 sonnet/haiku。**
> 本模板用於：需要一個 read-only reviewer subagent 審特定範圍時
> （phase-level review、或 /codex:rescue 產出的代碼需 Claude 審查時）。

```text
【任務】審查【範圍：git diff A..B / 檔案清單 / working tree】。
你是 read-only 審查員：只報 findings，不寫任何修復。
【背景】這批改動的意圖：【一句話】。對照的 AC/spec：【路徑】。
專案禁區與慣例：CLAUDE.md 的 Project-specific constraints。
【審查優先序】正確性 bug → 安全/資料遺失風險 → constraints 違規 →
邊界條件與併發 → 對鄰近代碼的回歸影響 → 風格（僅限離譜者）。
【驗收條件】
- 每條 finding 先對照代碼實體驗證過才報（no speculative findings）。
- 「因為無法驗證正確性」而發的警告本身就是錯誤——它替指揮官製造
  假工作。驗證不了的疑慮標 unverified 另列，不計入 findings。
- 空手而回也要明說「已檢查 X/Y/Z 角度，未發現問題」——驗證後
  一無所獲時，「未發現」就是正確答案，不是湊一串 maybe。
【回報格式】
- 第一行 verdict：Approve / With fixes / Blocked + 一句理由。
- Findings 清單：`P1|P2|P3 — 路徑:行號 — 何時會壞 — 修法提示`
  （P1 = 現在就會壞；P2 = 真缺陷、影響面窄；P3 = 值得修、不擋路）。
- ≤30 行。禁止貼代碼區塊，行號足矣。
```

## 模板 5：驗收 Read-back（Acceptance Verification）

> implementer ≠ verifier（kit-delegation）：實作 / 重構任務回報後，
> 派一個 fresh-context agent 跑本模板。驗收 agent 與 implementer
> 不得是同一個 subagent 對話。

```text
【任務】驗收下列工作是否真的完成。你是 fresh-context 驗收員：
不信任 implementer 的回報，只信檔案實體與你親自實跑的結果。
【背景】原始 AC：【逐條抄進來】。implementer 宣稱的改動：
【路徑:行號清單】。測試指令：【指令】。
【驗收步驟】
1. Read 每個宣稱改過的檔案：存在、非空、內容與宣稱相符。
2. 親自實跑測試取得輸出——不得引用 implementer 貼的輸出。
3. AC 逐條對照：達成/未達成 + 證據位置。
【必須主動檢查的造假模式】
- 無證據的宣稱（說改了但檔案裡沒有）。
- 被跳過的檢查（AC 有列、回報沒提）。
- 發明的路徑 / 指令 / 數據（引用的東西實際不存在）。
- 被弱化的斷言或被偷改的 AC（測試改鬆、AC 被重新詮釋）。
【回報格式】≤20 行。第一行 verdict：PASS / FAIL + 一句理由。
AC 逐條「達成/未達成 + 證據」；你自己跑的測試輸出原文（最後
5 行）；命中的造假模式（若有）逐條點名。禁大段代碼。
```

---

## 派工後，指揮官的責任

1. 回報進來先跑最低驗證：宣稱寫過的檔案 `ls`/Read 確認存在非空。
2. 回報缺 AC 對照或缺測試原文 → **退回重報**，不腦補、不放行。
3. 實作類任務接著派驗收（模板 5），implementer 的「完成」不算數
   （kit-delegation：implementer ≠ verifier）。
