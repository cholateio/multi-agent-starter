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

### v3（當前）：基於官方整合的精簡版

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

## 三、v3 的角色設計

### 三方分工

```
┌──────────────────────────────────────────────────────────┐
│  Main Claude (orchestrator)                              │
│  讀 CLAUDE.md，按情境協調三方                              │
└──┬─────────────────┬─────────────────┬──────────────────┘
   │                 │                 │
   ▼                 ▼                 ▼
┌────────────┐  ┌────────────┐  ┌─────────────────────────┐
│ Gemini     │  │ Superpowers│  │ Codex Plugin (官方)      │
│ Research   │  │ Plan +     │  │ /codex:review           │
│ Scout      │  │ Execute    │  │ /codex:adversarial-review│
└────────────┘  └────────────┘  └─────────────────────────┘
   研究員           架構師+工人      審查員
   蒐集網路         規劃+實作       Cross-model review
   資源整合
```

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

## 五、Hooks 為什麼是「最少必要」

v3 引入兩個 hooks：

- `classify-task.sh`（UserPromptSubmit）：自動分類任務大小
- `verify-final-review.sh`（Stop）：強制最終 review

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
   - 當官方解法出現，自製方案就該功成身退

2. **Markdown 是最好的配置語言**
   - CLAUDE.md / USAGE.md / SKILL.md 都是純文字
   - 改 prompt 比改 code 便宜十倍
   - Hooks 是少數需要 bash 的地方，但保持薄

3. **Isolation 比 Specialization 重要**
   - Subagent 不是專家，是乾淨的狀態隔離區
   - 模型多樣性主要來自不同訓練分布
   - 「用了多個 subagent」≠「實現了 isolation」（v2 教訓）

4. **每三個月重新檢視這份文件**
   - 那時候會發現自己踩過 v3 沒講到的坑
   - 或者新的官方工具出現，又該簡化了

## 八、v2 到 v3 的關鍵教訓

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

v3 補上 USAGE.md，跟 CLAUDE.md 形成鏡像：一個給 AI、一個給人。

---

*Living document. 每次有新洞察就回來修。*
