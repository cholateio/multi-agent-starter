# Architecture: Why This Kit Works The Way It Does

> 設計脈絡與決策紀錄。
> Purpose: 解釋每個元件存在的理由，紀錄走過的取捨，避免未來偏離。

## 一、起點痛點：人類路由器困境

開發者使用多個 AI 服務（Claude、Codex、Gemini）時，很容易退化成人類訊息路由器——把 plan 從 Claude 複製貼到 Codex review、整理回饋再貼回 Claude。

**目標**：讓 AI 之間直接協作，使用者只負責決策和提供 feedback。

## 二、版本演進

### v1（已淘汰）：PAL MCP 路線

最初考慮使用社群熱門的 PAL MCP server，提供 `consensus`、`codereview`、`clink` 等多模型協作工具。

**淘汰原因**：
- 維護者回應疑慮
- 隔了一層黑盒子難以 debug
- 5000+ 行 Python 對「跨模型 review」這個簡單需求過重

### v2（已被取代）：自寫 wrapper + subagent

寫 ~150 行 Python 的 MCP server 跟兩個 bash wrapper，搭配自訂 subagent
（codex-coder、codex-reviewer、gemini-reviewer）和 skill
（plan-with-review、cross-model-review、handoff-context-format）。

**問題**：
- 三個環境問題（trusted-directory、stdin handling、權限提示）需要 debug
- 同模型 self-review 陷阱（codex-coder + codex-reviewer 看似 multi-agent
  但本質是同模型分兩次呼叫，沒有真正的 isolation）
- 維護成本：1600+ 行的 kit

### v3（已被精簡）：基於官方整合的精簡版

OpenAI 在 2026/3/30 發布 `codex-plugin-cc`——直接整合 Codex 進 Claude
Code 的官方 plugin。提供 `/codex:review`、`/codex:adversarial-review`、
`/codex:rescue` 等 slash commands。

這讓 v2 大部分自製元件**完成歷史任務、可以光榮退役**：

| v2 元件 | v3 取代 |
|---------|---------|
| `.claude/scripts/codex_exec.sh` | Codex Plugin 內建 |
| `codex-reviewer` subagent | `/codex:review` |
| `codex-coder` subagent | `/codex:rescue` |
| `gemini-reviewer` subagent | 不再需要（codex 取而代之） |
| `handoff-context-format` skill | Plugin 自己處理 context 傳遞 |
| `cross-model-review` skill | `/codex:review` 直接 invoke |
| `plan-with-review` skill | superpowers writing-plans + auto `/codex:review` |

v3 從 1600+ 行縮到 ~900 行。**少即是多**——之前我們設計的東西被官方做掉了，這是好消息。

### v3.1（當前）：profile 切換 + 一鍵 init + 文件精簡

v3 證明「基於官方整合的精簡版」方向正確，但實戰暴露出兩個**不在執行階段、
而在邊界**的痛點：啟動成本（每開專案要手動搬檔、填 CLAUDE.md）與人機溝通
（USAGE.md 太繁雜，沒人真的照著用）。v3.1 專打這兩端，不動執行核心。

三個關鍵決策：

1. **Profile 切換取代 fork。** full（gemini+codex+claude）是日常預設；但公司
   環境不能用 codex、或 token 用完時需要降級成只有 claude 的 solo。直覺是
   「維護兩份 `.claude`/`CLAUDE.md`」，但那會讓使用者退化成兩份檔案的人肉
   同步器（drift 陷阱）。改用單一 per-machine 環境變數 `KIT_PROFILE=full|solo`：
   **同一份 committed repo**，靠環境變數決定行為。reviewer 角色因此被抽象化——
   CLAUDE.md 不再寫死 `/codex:review`，而是「依 active profile 解讀 review」。
   solo 的 review 降級成 fresh-context subagent 自審（保留狀態/時間隔離、失去
   模型隔離），且**明文宣告降級、不靜默**。

2. **選擇性 init 取代 `cp -r`。** v3 把整個 kit `cp -r` 進專案，連
   README/ARCHITECTURE/USAGE 這些「kit 自己的文件」都被拖進去，造成使用者
   分不清哪些能改。v3.1 把 kit 定位成「留在原地的工具」，用 `init.sh` 只吐出
   **安裝層**（`.claude/` + `CLAUDE.md` + `PROMPTING.md`），kit 文件永遠留在
   kit repo。這同時根除「哪些檔案能改」的困惑——專案裡只剩「該填的」跟
   「別碰的」。

3. **PROMPTING.md 取代 USAGE 的 prompt cookbook。** USAGE.md 把一個小小的
   「控制文法」攤平成六個情境範本（A–F），又是 illustrative 而非 parametric，
   導致沒人照用。v3.1 抽出底層文法——「一句話描述任務 + 可選修飾語覆寫 +
   介入指令」——收成一頁參數化 cheat sheet。

文件結構連帶精簡：`ADOPTION.md` 砍掉（精華併入 README 既有專案段），
`USAGE.md` 砍掉（prompt cookbook 由 PROMPTING.md 取代、operations/debug 併入
README）。從 v3「一堆會被複製進專案的文件」收斂成「kit repo 留文件、專案只
進安裝層」。

> v3.1 的核心仍是同一條心法：**少即是多**。差別在 v3 簡化的是「實作」
> （自製 wrapper 退役），v3.1 簡化的是「介面」（啟動與溝通）。

## 三、角色設計

### 三方分工

```
┌──────────────────────────────────────────────────────────┐
│  Main Claude (orchestrator)                              │
│  讀 CLAUDE.md，按情境協調三方                              │
└──┬─────────────────┬─────────────────┬──────────────────┘
   │                 │                 │
   ▼                 ▼                 ▼
┌────────────┐  ┌────────────┐  ┌─────────────────────────┐
│ Gemini     │  │ Superpowers│  │ Reviewer（依 profile）   │
│ Research   │  │ Plan +     │  │ full: /codex:review      │
│ Scout      │  │ Execute    │  │ solo: fresh-context 自審 │
└────────────┘  └────────────┘  └─────────────────────────┘
   研究員           架構師+工人      審查員
```

> v3.1 起，審查員不再寫死成 Codex。它是一個**角色**，由 `KIT_PROFILE` 決定誰
> 來扮演：full 用 Codex（真正的跨模型隔離），solo 用 fresh-context 的 Claude
> 子代理（只剩狀態/時間隔離）。solo 不是「壞掉的 full」，是個誠實標註過降級
> 程度的檔位。

### 為什麼 Gemini 變成研究員

v2 把 gemini 當 reviewer。v3 改成研究員。理由：

- 前沿模型在 code review 任務上越來越同質——「不同 model」的差異變小
- 但 gemini 在**網路搜尋整合**上有真實差異化優勢（內建 Google Search 能力）
- Research 是 nice-to-have（失敗可降級），review 是 must-have（失敗不可降級）
- 把 review 集中在 codex（有官方 plugin）、研究分給 gemini（發揮搜尋優勢）

這個分工讓**每個 model 做自己最強的事**，而不是強迫它們都能做 review。

### 為什麼信任 superpowers 主導 plan

Superpowers 的 brainstorming + writing-plans + executing-plans 是個成熟的規劃流程。v2 自己寫的 `plan-with-review` skill 在這方面遠不如 superpowers。

v3 直接讓 superpowers 主導，**我們只在 plan 寫完和實作完成時介入跑 `/codex:review`**。這是 Generator-Evaluator 模式：superpowers 是 Generator、Codex Plugin 是 Evaluator。

## 四、四個核心 isolation 維度

從整段討論累積出的設計心法：

1. **時間隔離**（防同質化）：fresh-context subagent 防止從前面 code 抄風格
2. **觀點隔離**（防 confirmation bias）：跨模型 review 防止邏輯盲點
3. **規格隔離**（防錯誤前提）：adversarial review 質疑前提（v3 透過 `/codex:adversarial-review` 兌現）
4. **狀態隔離**（防 context 污染）：subagent verbose 留在子對話

四個維度同時是判準也是檢查清單。遇到 AI 出錯的場景，先問：是哪一種隔離不足？

> v3.1 的 solo profile 是這個框架的好範例：拿掉 codex 後失去的是**觀點隔離**
> （維度 2），但 fresh-context 自審仍保留**時間隔離**（維度 1）與**狀態隔離**
> （維度 4）。所以 solo 不是「零隔離」，是「四缺一」——這也是為什麼它是個
> 可接受的降級，而不是放棄。

## 五、Hooks 為什麼是「最少必要」

v3 引入兩個 hooks：

- `classify-task.sh`（UserPromptSubmit）：自動分類任務大小
- `verify-final-review.sh`（Stop）：強制最終 review（v3.1 起 profile-aware——
  讀 `KIT_PROFILE` 決定強制 codex review 還是 fresh-context 自審）

但**預設關閉**，使用者主動 opt-in。理由：

**Hooks 的好處**：
- 確定性執行，不靠 LLM 記憶
- 紀律強，不會在長 session 後段被忘記

**Hooks 的代價**：
- 增加 debug 複雜度（背景跑、看不到）
- 安全敏感（用使用者權限執行 shell）
- 可能跟 superpowers 的 hooks 衝突

「最少必要」原則：只用 hooks 實現「沒它就會出錯」的紀律。其他保持彈性。

## 六、為什麼不做更多

開發過程中冒出許多「也可以加」的想法：

- SubagentStop hook 自動 review 每個 phase
- PostToolUse hook 監控 quota
- SessionStart hook 環境檢查
- 自訂 dashboard 追蹤 AI 工作量
- 跨 session 共享 task list

**這些都沒進 v3**，因為都還沒踩到實際痛點。痛點驅動架構，不是架構驅動痛點。等實際使用 5-10 個專案後，再決定哪些值得加。

## 七、長期心法（不變的核心）

> 「不要焦慮地追逐每天冒出來的新名詞或熱門框架。
> 真正重要的是去深究這些架構『為什麼存在』以及『解決了什麼底層問題』。」

具體展開：

1. **痛點驅動架構，不是架構驅動痛點**
   - v3 大幅簡化是因為 codex-plugin 出現了，不是因為「想簡化所以簡化」
   - v3.1 大幅簡化介面是因為實戰踩到啟動/溝通成本，不是因為「想加 profile 所以加」
   - 當官方解法出現，自製方案就該功成身退

2. **Markdown 是最好的配置語言**
   - CLAUDE.md / PROMPTING.md / SKILL.md 都是純文字
   - 改 prompt 比改 code 便宜十倍
   - Hooks 是少數需要 bash 的地方，但保持薄

3. **Isolation 比 Specialization 重要**
   - Subagent 不是專家，是乾淨的狀態隔離區
   - 模型多樣性主要來自不同訓練分布
   - 「用了多個 subagent」≠「實現了 isolation」（v2 教訓）

4. **每三個月重新檢視這份文件**
   - 那時候會發現自己踩過前一版沒講到的坑
   - 或者新的官方工具出現，又該簡化了

## 八、關鍵教訓

### 教訓 1：自製方案要警惕官方化的可能性

v2 投入大量精力解決「跨模型 review」，結果 4 個月後 OpenAI 推出 codex-plugin
直接做掉。如果一開始就等等看會省很多事。

但這不代表「總是等」是對的——v2 的存在讓我們**真實理解了問題**，當官方解法
出現時能快速判斷它好在哪。沒有 v2 的踩坑經驗，v3 也不會這麼乾淨。

### 教訓 2：「看起來 multi-agent」不等於「真的 isolation」

v2 的 codex-coder + codex-reviewer 組合是個典型陷阱。看起來很 multi-agent，
但本質是同一個模型分兩次呼叫，沒有真正的 isolation。

V3 透過架構強制（codex-plugin 不能對自己寫的 code review）+ CLAUDE.md
明文警告，避免這個 anti-pattern。

### 教訓 3：使用者文件跟 AI 文件同等重要

v2 大部分文件是寫給 AI 看的（CLAUDE.md、SKILL.md）。實戰中發現使用者也
需要對應的文件——「我該怎麼下指令？」「Hook 怎麼啟用？」「Debug 怎麼做？」

v3 補上 USAGE.md，跟 CLAUDE.md 形成鏡像。**但 v3.1 又發現 USAGE.md 過繁**：
六個 prompt 範本沒人照用，因為它把小小的控制文法攤平成情境清單。於是收成
一頁 PROMPTING.md（控制詞速查），長版 operations/debug 併進 README。教訓的
進階版：使用者文件不只要存在，還要**符合使用時的形態**——人在當下要的是
速查卡，不是手冊。

### 教訓 4：真正的痛點往往不在你以為的地方

設計 v3 時，預期的脆弱點是執行階段——任務分類誤判、codex quota、長 session
規則漂移。實戰發現執行階段反而最穩（isolation 承重牆站得住），真正磨人的是
**兩端**：進場（啟動成本）和介面（溝通）。兩者共通點是「人的認知負載」，不是
AI 的能力問題——所以解法不在 CLAUDE.md（給 AI 的），而在 init.sh 跟
PROMPTING.md（給人的）。

教訓：架構設計容易過度關注「AI 怎麼做事」，而低估「人怎麼啟動和驅動這套
系統」。v3.1 補的全是後者。

---

*Living document. 每次有新洞察就回來修。*
