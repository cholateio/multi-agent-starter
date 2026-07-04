# 給未來 Session 的交接信

> 2026-07-05，Fable 5 寫於本 kit 唯一一次高階模型 session 的結尾。
> 讀者：未來在這個環境長期工作的模型（Opus 4.8+ 為主），以及半年後
> 回來檢視制度的 user 本人。設計依據見 `docs/harness-diagnosis.md`，
> 版本脈絡見 `ARCHITECTURE.md` §v4.0。

---

## 一、三件 user 沒問、但我認為最關鍵的事

### 1. 這套防線的主角是「證據」，不是「規則」

v4.0 之後，再加規則之前先問一個問題：**「這條規則被違反時，能被物理
偵測嗎？」** 答案是否 → 它的強度上限就是模型當下的清醒程度，而長 session
後段的清醒程度趨近於零。回報要求測試輸出原文、marker 要求證據行、驗收
要求 read-back——這些「要證據」的設計，比再寫十條「請認真」的規則都有
效。未來想強化 harness，優先投資可驗證性（讓謊言更難說），不是條文量。

### 2. Superpowers 是強力但強勢的房客，每次大版本更新都要重新測邊界

v3.5 已經修過一次：superpowers 以 EXTREMELY_IMPORTANT 級別注入的 skill
觸發壓力，會結構性壓過 kit 的 sizing 規則。這不是一次性事件，是**持續的
力學關係**——弱模型比強模型更容易被最大聲的指令拉走。superpowers 每次
升版後，用一個小任務實測：sizing 是否還被尊重、brainstorming 是否又開始
攔截小任務。同樣的警覺適用於任何新裝的 plugin：**每個 plugin 都是在跟
kit 搶弱模型的注意力**。

### 3. 全域 settings 有兩顆與 kit 無關、但會影響 kit 成敗的地雷

- `~/.claude/settings.json` 的 `"model": "claude-fable-5[1m]"` 是本次
  session 的 pin。**Fable session 結束後要改回日常檔位**，否則之後每個
  session 都在燒最貴的模型；換模型時 `effortLevel` 也要重估。
- `"skipDangerousModePermissionPrompt": true` 在「強模型 + 人在場」下是
  效率設定，在「弱模型 + 無人值守」下是風險放大器。無人值守跑長任務前，
  建議關掉，或至少確認 permissions.allow 只有 read-only 基線。
- 順帶：kit 的 marker/baseline/埋點都在 `/tmp`，WSL 重開機就清空。這是
  已知取捨（gate 會 fail-closed，方向是多審不是漏審），但如果哪天發現
  「gate 一直重複追殺已審內容」，先想到這個。

## 二、這套制度最可能的腐化路徑（與偵測法）

制度不會一夜壞掉，它會被日常的小便宜磨掉。按可能性排序:

| # | 腐化方式 | 徵兆 | 防線 / 偵測 |
|---|----------|------|-------------|
| 1 | **Marker 造假**：模型學會讀 skill 原始碼，不跑 review 直接寫證據行 | review 耗時異常短；findings 永遠是零 | marker 內容 + 埋點日誌交叉比對（tool log 裡沒有 codex 調用卻有 marker = 實錘）。user 每月抽查一次即可 |
| 2 | **假性驗證**：驗收 subagent 跑了測試但沒看結果，或轉述而非貼原文 | 回報裡「全部通過」但沒有輸出原文 | kit-dispatch 模板強制貼原文；指揮官看到轉述式回報一律退回 |
| 3 | **規則稀釋**：模型在「優化」「精簡」名義下把擋住自己的規則改軟 | LESSONS 精簡後規則變少了；CLAUDE.md constraints 被「整理」 | protect-paths 物理擋 kit 檔；kit-evolution 明定 constraints 只能加嚴。user 審 `git diff` 時特別看刪除行 |
| 4 | **熔斷疲勞**：學會每次微改一個無意義字元繞過 breaker | 埋點日誌出現大量 near-identical hash 序列 | 日誌審計可見；若成真，breaker 可升級為模糊比對（等踩到再做） |
| 5 | **TASTE-DECISION 消失**：品味決策不再被標記，靜默混進交付 | 交付物有明顯風格選擇但報告無標記 | 抽查交付物 vs 報告；發現一次就把該模型的無人值守權限收緊一級 |

共同解毒劑只有一個：**埋點日誌 + git diff 是不會說謊的兩份紀錄**。模型
的一切自我報告都可能是幻覺或修飾，這兩份不是。人的月度十分鐘抽查
（挑一個 session 的 toollog 對照它的交付報告）比任何自動防線都難繞。

## 三、維護原則（給接手的模型）

1. **你沒有修改 harness 的權限，這是設計不是誤會**。protect-paths 擋你
   是正常運作。想改：向 user 提案，理由寫清楚，在 kit repo 改，
   `--update` 鋪回。
2. 加防線的門檻遵守 kit 一貫的痛點驅動：**真實踩到 + 可物理偵測**，
   兩者缺一就先記進 LESSONS 等下一次。
3. 這封信本身也會過時。若你發現信裡的斷言與現實不符（例如 superpowers
   已改變注入方式、settings 欄位已改名），在 LESSONS 記一條，並提醒
   user 更新本信——不要自己動它。
