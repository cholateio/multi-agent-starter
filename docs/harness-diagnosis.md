# Harness 漏水診斷書（v4.0 基礎文件）

> 撰寫背景：2026-07-05，由 Fable 5 在本 kit 的唯一一次高階模型 session 中完成。
> 此後的長期運營假設：**指揮官 = Opus 4.8+**（複雜架構規劃用當代最強模型）、
> **Sonnet/Haiku 只做輕量執行（寫測試、機械批次），永不碰 review**、
> **長任務以無人值守為常態**、**KIT_PROFILE=full**。
> 本文件是 v4.0 所有防線的設計依據——後續每個產出（規則、hook、skill、模板）
> 都應能回指到這裡的某個痛點。這是 kit 自己的文件，留在 kit repo，不進專案。

---

## 一、三大失敗場景 → 三個物理痛點

弱模型長任務的三個極限失敗場景（工具調用崩潰、語意迷航、假性完成）不是三個
獨立的病，而是同一條惡化鏈的三段：**context 膨脹 → 記憶解體 → 逃生門造假**。
診斷的重點是找出鏈上「物理上可以剪斷」的三個點。

### 痛點 1（最浪費 Token）：指揮官親自下場 + 回報噴代碼

**物理機制**：主對話的 context 是整個系統唯一不可再生的資源。指揮官每親自
Read 一個大檔、每親自掃一次 repo，罰款是雙重的——當下的 token，加上此後
**每一輪** API 呼叫都要重複攜帶這些內容。subagent 回報時貼大段代碼同理。
context 越肥 → compact 來得越早 → 越早進入痛點 2（迷航）。**痛點 1 是
痛點 2 的上游**，這也是為什麼它排第一。

**v3.5 現況**：kit 對「誰該讀檔」完全沒有規範。superpowers 管流程節奏、
kit-workflow 管 review 紀律，但「主對話模型可不可以自己掃 20 個檔案」無人
管轄——強模型有品味自己會派工，弱模型（乃至疲勞的 Opus）會親自下場。

**阻斷方案**：
- `.claude/rules/kit-delegation.md`（自動載入）：「指揮官不下場」合約——
  硬規則是回報格式（禁 >20 行代碼，只准「路徑:行號 + 結論」，這才是
  context 污染的實際來源）；強制派工僅限全 repo 掃描、>10 檔、位置未知
  的搜索，其餘交給指揮官的成本判斷（派工實際成本 10-30k tokens，直讀
  400 行約 5k——門檻經自由度校正後定案）。
- `/kit-dispatch` skill：四種任務型態的派工模板，把「派工三件套」（目標
  與背景 / 驗收條件 / 回報格式）做成填空，讓弱指揮官照抄也能派出合格的工。
- 誠實標註：這一層是 **prompt-level 阻斷**（規則 + 模板），不是物理擋。
  物理層只能事後審計：tool-breaker hook 的埋點日誌記下每次調用的工具名，
  事後可以看出「指揮官親自 Read 了幾次」。

### 痛點 2（最容易導致失焦）：compact 後零重錨定 + 禁區純 prose

**物理機制**：compact 把 plan 細節、constraints、「哪些檔案已經完成」壓縮
成摘要；模型醒來時手上只剩大意。v3.5 的 SessionStart hook 在 compact/resume
後**只重播 profile 和 marker 路徑**，不重播「你在哪、什麼不能碰」——記憶
解體風險最高的時刻，harness 給的錨點反而最少。同時，專案禁區
（CLAUDE.md「Project-specific constraints」）只存在於 prose，執法者是
**正在迷航的模型本人**——場景 2 的定義就是這個執法者已經失能。

**阻斷方案**：
- `session-start.sh` 增加 RE-ANCHOR：偵測 `source=compact|resume`，注入
  強制指令——動任何檔案前先重讀 constraints 與進行中的 plan/progress，
  並用一句話自報目前所在 phase。（物理：hook 注入，不靠模型記得。）
- `protect-paths.sh`（PreToolUse，新增）：兩檔防護——`.claude/protected-paths`
  清單（專案自填，glob 一行一條）命中即 **hard-deny**；kit-owned 檔案
  命中轉 **ask**（user 在場可一鍵放行明確要求過的修改，無人值守時等同
  封鎖——避免與 update-config 等內建正當流程打架，安全性零損失）。
  迷航的模型碰不到禁區——deterministic 執法，完全不依賴模型記憶。
- CLAUDE.md 範本改版：constraints 段落明文要求「每條禁區同步寫進
  `.claude/protected-paths`」，讓 prose 和物理執法保持同一份清單的兩面。

**殘餘漏洞（誠實標註）**：Bash 是邊門——`sed -i`、`echo >`、`rm` 不經過
Edit/Write 工具，protect-paths 攔不到。Bash 命令字串解析不可靠（`git diff
src/legacy/` 是唯讀、合法），硬攔的誤擋成本高於收益，v4.0 不做。緩解：
judgment-matrix 明文「禁區檔案連 Bash 都不許碰」+ 埋點日誌留痕供事後審計。

### 痛點 3（最常引發工具調用錯誤）：重試螺旋 + 逃生門太便宜

**物理機制**有兩half：

(a) **重試螺旋**：弱模型 context 變大後的典型崩潰是「同一個調用、同樣的
參數、連續失敗、連續重試」——每一圈都燒 token、推進 compact、加深迷航。
v3.5 對此**零偵測**：模型可以原地轉五十圈，harness 毫無知覺。

(b) **逃生門太便宜**：v3.5 的 Stop gate 被 block 時，block 訊息**親手把
`touch /tmp/claude-codex-reviewed-...` 這條指令遞給模型**。對一個急著結束
turn 的弱模型，「直接 touch」比「真的跑 review」便宜一百倍——假性完成的
最短路徑是 harness 自己鋪的。

**阻斷方案**：
- `tool-breaker.sh`（新增，雙事件）：
  - **PreToolUse（硬擋）**：連續第 3 次**完全相同**的工具調用（工具名 +
    參數 hash 一致、中間無其他調用）→ 物理 deny，訊息要求「先用一句話
    診斷前兩次為何不滿足，換方法或走升降級路徑」。輪詢類工具（TaskOutput
    等合法重複者）豁免。
  - **PostToolUseFailure（軟警示）**：工具失敗時記錄失敗事件；近期調用中
    失敗密度過高（最近 12 條遙測事件中 ≥3 次失敗）→ 以 stderr 向模型注入警示
    （此時工具已執行完畢，物理上不可 block，只能警示——官方文件已驗證）。
  - 兩個事件都寫一行埋點日誌（工具名 + 參數 hash，不記參數內容以免洩密）
    到 `/tmp/claude-kit-toollog-<session_id>.jsonl`，供事後審計。
- **Marker 證據化**（改 `verify-final-review.sh` + `/kit-review` skill）：
  空的 touch 不再過關——marker 第一行必須是 `reviewed-by=...` 證據行
  （由 /kit-review 在真的跑完 review 後寫入）；bypass flag 同規則，
  第一行必須是 `user-approved`（由 /kit-skip-review 在 user 明確要求後
  寫入），否則丟棄並點名——不能讓 skip flag 變成 marker 加固後的新
  最短造假路徑。Stop gate 的 block 訊息**不再印出任何 touch 指令**，
  只指向 `/kit-review` 與 `/kit-skip-review`。誠實路徑從此比造假路徑
  省力——這才是防線的真正目標。

**殘餘漏洞（誠實標註）**：模型讀 skill/hook 原始碼之後仍可偽造證據行。
這道防線的目標是「摩擦 + 審計痕跡」，不是密碼學防偽——持有 Bash 的模型
理論上可以偽造一切。防偽的最後一層是人：埋點日誌 + marker 內容留痕讓
造假**可被事後發現**，配合交接信裡的定期抽查建議。

---

## 二、阻斷方案 ↔ 產出對照表

| 痛點 | 物理阻斷（hook，deterministic） | 程序阻斷（rules/skill，prompt-level） |
|------|-------------------------------|--------------------------------------|
| 1 Token 洩漏 | 埋點日誌（僅審計） | kit-delegation 派工合約、/kit-dispatch 模板 |
| 2 迷航亂改 | protect-paths hard-deny、RE-ANCHOR 注入 | CLAUDE.md constraints ↔ protected-paths 同步、judgment-matrix R1 |
| 3 螺旋+造假 | tool-breaker deny、marker 證據化 | kit-delegation 升降級路徑、judgment-matrix R2/R3 |

原則：**能用 hook 擋的不靠 rules，能用 rules 說清楚的不寫進 CLAUDE.md**。
rules 只承載 hook 做不到的部分（判斷、派工、格式），CLAUDE.md 只承載
專案事實。

---

## 三、誠實條款：這套 Harness 的能力極限

1. **Bash 邊門**：protect-paths 只攔 Edit/Write/NotebookEdit。模型經 Bash
   改禁區檔案物理上攔不住（見痛點 2 殘餘漏洞）。
2. **防偽是摩擦不是密碼學**：marker 證據行、bypass 流程都可以被「讀了
   原始碼的模型」偽造。防線價值 = 讓誠實路徑更省力 + 留下可審計的痕跡。
3. **假性完成沒有可靠的物理 gate**：「宣稱完成但零落檔」的偵測需要理解
   語意（分析型任務本來就合法地零落檔），bash 做 NLP 誤報率不可接受，
   v4.0 不做 transcript 掃描。替代：程序性驗收——kit-delegation 規定
   指揮官收到「已寫入 X」回報時必須 ls/read 實證，驗收一律由 fresh-context
   subagent read-back。
4. **jq 依賴**：所有 hooks 無 jq 時靜默失效（kit 既有立場：不因工具缺失
   卡死 session）。裝機檢查靠 init.sh。
5. **/tmp 揮發性**：重開機（尤其 WSL）清空 /tmp → baseline 消失 → gate
   退化為 porcelain-only 視野；marker/埋點日誌同理消失。已知且接受——
   gate 的 fail-closed 設計保證退化方向是「多審」不是「漏審」。
6. **品味決策是弱模型的天花板（本條為應對標準）**：模糊的商業美感、
   取名哲學、文案語氣、無硬規格的 UX 取捨——拆解與隔離驗證救不了這些。
   標準應對（寫入 judgment-matrix R4，具強制力）：
   - 弱模型**不得自行拍板**品味決策；產出 2-3 個選項 + trade-offs，停下問 user。
   - 無人值守時：選「最保守、與既有慣例最一致」的選項，在交付報告中以
     `TASTE-DECISION` 標記該決策待 user 覆核。禁止讓品味選擇隱形。
7. **Prompt-level 規則對迷航模型效力遞減**：rules 檔寫得再好，場景 2 的
   模型就是讀過也會忘。這正是 v4.0 的分層邏輯——核心防線全部做成 hook
   （deterministic），rules 只做 hook 做不到的部分。評估任何未來防線時
   先問：「這條規則被違反時，能被物理偵測嗎？」不能的話，它的強度上限
   就是模型當下的清醒程度。

---

## 四、為什麼不做更多（v4.0 邊界）

- **transcript 掃描偵測假性完成**：bash 做語意判斷誤報率高；分析型任務
  合法地零落檔。用程序性驗收替代（見極限 3）。
- **deliverable manifest gate**（plan 宣告預期產出、Stop hook 逐一驗證）：
  依賴 superpowers plan 格式穩定，複雜度高。等踩到「程序性驗收也擋不住」
  的實際痛點再做。
- **Bash 命令解析保護**：誤擋合法唯讀命令的成本 > 收益。埋點日誌先留痕
  觀測，若實戰出現 Bash 邊門事故再評估。
- **失敗後硬擋**：官方文件已驗證——PostToolUse 只在工具「成功完成」後
  觸發；失敗走 `PostToolUseFailure`，但該事件發生時工具已執行完，**物理上
  不可能 block**，只能軟警示。所以 v4.0 的硬熔斷只有一個掛在 PreToolUse
  的「連續相同調用」偵測（事前可擋），失敗密度偵測降格為 stderr 警示。
  「精準地在第 N 次失敗後硬擋下一次任意調用」做不到也不該做（會誤傷
  換了方法的正當嘗試）。
- **加密簽名 marker**：密碼學防偽對「模型持有 Bash」的威脅模型無意義
  （簽名工具本身就在模型手上）。

**觀測待辦（下一次調整的輸入，不是現在的工作）**：PostToolUseFailure
的失敗密度警示有誤傷 TDD 的嫌疑——Bash 指令非零退出（紅燈階段的測試
失敗）是否被計為「工具失敗」尚未實證。請在頭一兩個真實 session 後檢查
`/tmp/claude-kit-toollog-*.jsonl`：若正常紅綠循環中 `"e":"fail"` 大量
出現，把 tool-breaker.sh 的 exit 2 警告降級為純記錄（保留日誌），
PreToolUse 硬熔斷不受影響。

---

*引用關係：B（CLAUDE.md 範本）落實痛點 1/2 的路由與 constraints 同步；
C（kit-delegation.md）落實痛點 1 與痛點 3 的升降級；D（judgment-matrix.md）
落實極限 6 與痛點 2/3 的判斷外化；E（/kit-dispatch）落實痛點 1 的派工
三件套；F（kit-evolution.md）防的是本文件未列的第四種腐化——模型「優化」
規則時把規則改軟；G（handover-from-fable.md）承接極限 2 的人工審計建議。*
