# Architecture: Why This Kit Works The Way It Does

> 設計脈絡與決策紀錄。
> Purpose: 解釋每個元件存在的理由，紀錄走過的取捨，避免未來偏離。

## 一、起點痛點：人類路由器困境

開發者使用多個 AI 服務（Claude、Codex、Gemini）時，很容易退化成人類訊息路由器——把 plan 從 Claude 複製貼到 Codex review、整理回饋再貼回 Claude。

**目標**：讓 AI 之間直接協作，使用者只負責決策和提供 feedback。

## 二、版本演進

### 前史：v1–v3.5（已被取代，壓縮存查）

| 版本 | 做了什麼 | 結局 / 留下什麼 |
|------|----------|-----------------|
| **v1** | 社群 PAL MCP server（consensus / codereview / clink） | 淘汰:維護者回應疑慮、隔一層黑盒難 debug、5000+ 行對「跨模型 review」這個簡單需求過重 |
| **v2** | 自寫 ~150 行 MCP + bash wrapper + 自訂 subagent/skill | 淘汰:三個環境 bug、1600+ 行維護成本,以及**同模型 self-review 陷阱**（codex-coder + codex-reviewer 看似多代理,本質是同模型分兩次呼叫,沒有真 isolation）——**這條教訓長成了 kit 的承重牆:審查的人必須跟寫的人是不同模型** |
| **v3** | OpenAI 2026-03-30 發布官方 `codex-plugin-cc`,自製元件光榮退役,1600+ → ~900 行 | 確立心法**少即是多**——此處簡化的是「實作」 |
| **v3.1** | `KIT_PROFILE` 環境變數取代「維護兩份 `.claude`」（人肉同步=drift 陷阱）;`init.sh` 只吐安裝層,kit 自己的文件永遠留在 kit repo | 少即是多的第二面:簡化「介面」(啟動與溝通) |
| **v3.2** | workflow rules 整段搬進 kit-owned `.claude/rules/`,CLAUDE.md 歸零成純專案內容;`--existing` 改自動偵測 | **所有權從「檔案內的段落」升格成「檔案本身」**——`--update` 才能安全 add-or-overwrite。少即是多的第三面:簡化「所有權」 |
| **v3.3** | 修 review gate 三個洞（marker 無人寫 / commit 盲區 / rename 解析錯誤）;SessionStart 廣播 KIT_CONTEXT + 記 baseline;`/kit-review`、`/kit-skip-review`;solo-reviewer 正式化;read-only 權限基線 | **現行 Stop gate 的骨架在此成形**（baseline + content hash + fail-closed）。`defaultMode:"auto"` 評估後不採用——kit 的信任邊界在 review gate,不在權限放寬 |
| **v3.4** | gemini 退役（**user 環境的個人因素,非模型能力問題**）,研究改 Claude 原生 `research-scout`,「換心臟不換介面」 | **profile 從此只決定一件事:誰當 reviewer** |
| **v3.5** | 給小任務可操作的 sizing 判準,並引用 superpowers 自己承認的優先權（專案指示 > skills）解除強制觸發;hooks 從 opt-in 改**預設開啟** | 首次記錄**superpowers 的 EXTREMELY_IMPORTANT 注入會結構性壓過 kit sizing**——這是持續的力學關係而非一次性事件,見 `docs/harness-diagnosis.md §六` |

### v4.0：弱模型防線——判斷力外化 + 物理熔斷

**不是踩到痛點後的修補，而是一次預防性立法**——由 Fable 5（一次性高階模型
session）在制度層面外化判斷力，供此後長期運營的較弱模型使用。完整診斷見
`docs/harness-diagnosis.md`（三大失敗場景 → 三個物理痛點；腐化偵測與長期維護
見同檔 §五、§六）。

- **防線分層：hook 管物理，rules 管判斷。** 評估標準明文化——「這條規則被違反
  時能否被物理偵測？」能 → 做成 hook；不能 → 進 rules 並接受其強度上限。新增
  `protect-paths.sh`（專案禁區 hard-deny／kit-owned 轉 ask 請示；user-only 逃生口
  `KIT_PROTECT=off`）與 `tool-breaker.sh`（連續相同調用熔斷 + 失敗密度警示 +
  全調用埋點日誌）。
- **逃生門加價：marker 證據化。** block 訊息原本親手印出 `touch <marker>`——
  假性完成的最短路徑是 harness 自己鋪的。改為必須含 `reviewed-by=` 證據行，
  訊息不再印任何 incantation。**誠實路徑從此比造假省力**（是摩擦 + 審計痕跡，
  不是密碼學防偽——模型持 Bash 可偽造一切，最後一層是人的抽查）。
- **compact 重錨定**（SessionStart 偵測 `compact|resume` 注入 RE-ANCHOR：重讀
  constraints 與 plan、自報 phase）、**判斷力外化成檢核表**（kit-delegation／
  kit-evolution／judgment-matrix／`/kit-dispatch`）、**CLAUDE.md 範本改版**
  （佔位符附範例、constraints 與 protected-paths 同步執法、加檔案路由表）。

### v4.1：判斷層採納——fable-soul 蒸餾

v4.0 防的是**結構性失敗**；v4.1 補**認知性失敗**（假完成措辭、過期驗證、湊數
findings、hedge 話術）。素材採自 fable-soul（MIT），只收 kit 未覆蓋的機制。

- **`.claude/rules/kit-judgment.md`**（auto-loaded 第四檔）：八條機制 + 藉口對照
  表 + Red Flags；與 judgment-matrix 的分工寫死（R3 熔斷提問／R4 品味不拍板的
  觸發優先於本檔的「直接做」傾向）。
- **per-turn digest**（classify-task）：每個非空 prompt 注入一行 KIT_JUDGMENT，
  確定性 re-fire 不依賴模型記得自查。**踩到的坑**：fable-soul 原案掛在 Stop
  hook 無效——Stop 的 exit-0 stdout 是 transcript-only、進不了 model context，
  移到 UserPromptSubmit 才真的送達。
- **派工模板判斷句 inline**：subagent 只繼承 session 啟動時的指令快照（實測
  2026-07-03），模板因此是弱執行員判斷規則**唯一保證送達**的載體。
- **prose 層有了 proof surface**：`tests/evals.md` + kit-evolution「規則變更紀律」
  （先查覆蓋、RED-GREEN 收據、逐字記藉口、rules/ 20KB 預算由 smoke 把關）。
  **誠實條款**：2026-07-05 實測 RED 全數未重現——目標條件是長 session 退化後的
  模型，fresh-context 合成 eval 模擬不了（詳見 evals.md 採納註記）。

### v4.2–v4.5：領域層、成本感知、manifest 體系

- **v4.2 verification-signals**（read-on-demand，經 CLAUDE.md 路由觸達）：五個
  「迴圈裡缺便宜驗證信號」的高風險領域——kit-judgment 通用證據紀律的領域實例化。
- **v4.3 成本感知**：Stop gate **小改自動放行**（累積 numstat ≤50 行／≤2 業務檔、
  無敏感或 protected 路徑 → 放行但**不推進 baseline**，小改累積、破檻那次批次
  涵蓋全部＝防切香腸；門檻由 git 實測，模型話術無效）；feature 級以上計畫須附
  各 phase 主導模型 + effort + 升級條件；classify-task 描述語境濾網（「一直在走
  完整流程」是描述不是指令——2026-07-10 實際誤觸）。
- **v4.4 manifest 體系**：`PROJECT.toml`（user-owned，`--update` deploy-if-absent
  比照 settings.json 先例，kit 永不覆蓋）+ `bin/proj` 跨專案彙總 +
  `rules/project-manifest.md`——**狀態要機器可讀，維護不靠記性**。
- **v4.5 proj html dashboard**：自包含 HTML（WSL 自動開瀏覽器）；同版把 manifest
  收錄規範從渲染端啟發式**上移到 schema**，渲染層有什麼顯什麼、不再猜。

### v4.6：review 經濟學——輪數、門檻、註解噪音

三個痛點都指向同一件事：**流程的成本要和它擋下的風險成比例**。

1. **re-review 範圍收斂**（kit-workflow）：收據是 anatomy-rag 真實 session
   （2026-07-11，Opus 4.8）——3 個小 UI 需求走成 6 輪 codex review／87
   分鐘，每輪 `--scope branch` 重掃全分支，已審舊碼被反覆再挖新角度，
   輪數自我繁殖。修法：round 1 審全集，之後只審 fix delta +「fix 改動的
   下游」（呼叫端＝stale-green 的正門）+ findings 碰過的碼；敏感路徑
   每輪維持全集。同輪在 kit-judgment 藉口表加「同根因第 2 個變體」列
   （反覆拿螢幕寬度當輸入能力的代理 → 停下列完整取值一次覆蓋）。
2. **Stop gate 小改門檻修形**（verify-final-review.sh）：收據是 margin
   調整（實改 19 行）因共用元件連動 3 個測試檔成 6 檔 55 行而被罰跑跨
   模型 review。**測試檔是驗證產物，不是業務邏輯**，卻是破檻主力——
   誘因反向（越認真補測試越容易被罰）。修法：測試檔從**檔案數與行數
   兩個計數**排除（只排檔案數會漏掉行數那半邊：55 > 50 照樣擋）、
   `SMALL_MAX_FILES` 2→4；敏感命名的測試檔（`test_auth.py`）不享排除
   ——敏感檢查先於測試排除。
3. **註解紀律**（kit-workflow + dispatch 模板 2/3）：user 逐字收據
   「vibe coding 的模式下…實在沒必要每次撰寫 code 都產生大量註解」。
   關鍵洞察：**「對 AI 友善」與「減量」是同一刀**——代碼的實際讀者是
   未來的 AI session，它讀 code 比讀散文快，敘述性註解是純噪音；它需要
   的是代碼顯示不了的四類（不變量/外部約束、跨檔耦合、非顯然 why、
   附日期收據）。辯護性註解歸 commit message／LESSONS。

### v4.7：manifest 的欄位有牙齒了

兩個小改，同一個道理：**只靠模型自律的規則不會被遵守**。

1. **`idle` 狀態**：原本五個狀態撐不起一個常見情境——專案上線自走、cron 還在
   跑、還在花錢，但沒有人在開發它，也還沒到結案（case-pick 2026-07-13 進觀察期
   時發現）。`active` 謊稱有人在動它，`paused` 暗示它連跑都不跑，`done` 宣告
   不再有下一步。`idle` 補上這一格。
2. **`status_note` / `service` 的形狀檢查**（`bin/proj`）：收據是 2026-07-13
   實測——`status_note` 的「固定兩段、細節歸 LESSONS」**寫在 rules 裡卻有 11/12
   個專案違反**（最糟 362 字，把整個成本調查塞進 dashboard）；`service` 則有
   8 個專案把說明寫進 badge。每次違反的藉口都是「這個細節很重要」——它重要，
   但 dashboard 是拿來掃一眼的，不是筆記本。修法：`proj` 對超標發警告（不擋、
   只吵），規則文字補上那個數字——**沒有數字的規範不可檢查**。

### v4.8（當前）：gate 從「工作樹範圍」改成「turn 範圍」+ 成本三槓桿

收據有兩份：一個 4 檔基本功能（api router + DB + 來源分流）跑掉 1.5 小時／
~2M token；以及 user 回報「brainstorming 階段常被 Stop gate 卡」。

1. **Stop gate turn-scoped**（classify-task + verify-final-review）：gate 原本是
   「工作樹範圍」——只要樹裡躺著未審業務碼就**每輪都攔**，brainstorming／純對話
   輪一起被卡。改成 classify-task 於每輪開頭快照**工作樹 hash + HEAD sha**，
   只有這一輪真的動過（改檔**或** commit）才攔；內容定址故 subagent 的改動也算，
   HEAD 一起比對堵掉「只 commit 不改內容」的盲點。義務不消失（不推進 baseline）。
   **已知缺口**（codex P1，user 接受並明文記錄）：no-edit 的「宣告完成」輪也會
   放行——hook 靠樹狀態分不出「完成」與「brainstorming」，要在 hook 層堵得靠
   脆弱的完成語彙偵測，反而重造誤擋。
2. **user-only 逃生口 `KIT_REVIEW_GATE=off`**：與 `KIT_PROTECT`／`KIT_BREAKER`
   對齊——先前唯獨最會卡人的 Stop gate 沒有 env 開關。
3. **review／派工成本三槓桿**：per-task review **不是預設**（只在敏感路徑 +
   依賴邊界審，其餘攢進 final review——收據：9 次 per-task review 553k 幾乎與
   final 完全重疊）；複審一律**開新 fresh reviewer 只餵 scoped delta**，禁止
   resume 重放（收據：285 行 transcript 重放去審一個 9KB delta ＝ 148k）；
   **每 phase 派工前重過 sizing 閘**，trivial／~≤10 行由指揮官 inline 做或併進
   相鄰 task（收據：3 個 10 行 phase 各走完整派工 + 獨立 review ＝ 205k）。
4. **註解語言政策**：代碼內註解一律英文——收據是 `.env` 行尾中文 `#` 註解的
   `0xA7` 被 `cut` 連進 Bearer token、gateway 爆 500；文件／prose／commit 維持中文。
5. **rules/ 精簡**（20864B→20410B）：加法用等量精簡騰出，順帶修好先前**既有
   超標**的紅燈（v4.6 那輪之後又漲回線外）。

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
│ research-  │  │ Superpowers│  │ Reviewer（依 profile）   │
│ scout      │  │ Plan +     │  │ full: /codex:review      │
│ (Claude 原生│  │ Execute    │  │ solo: fresh-context 自審 │
│  subagent) │  │            │  │                          │
└────────────┘  └────────────┘  └─────────────────────────┘
   研究員           架構師+工人      審查員
```

> v3.1 起，審查員不再寫死成 Codex。它是一個**角色**，由 `KIT_PROFILE` 決定誰
> 來扮演：full 用 Codex（真正的跨模型隔離），solo 用 fresh-context 的 Claude
> 子代理（只剩狀態/時間隔離）。solo 不是「壞掉的 full」，是個誠實標註過降級
> 程度的檔位。

### 研究員角色：為什麼它可以降級，reviewer 不行

執行者換過三輪（v2 gemini 當 reviewer → v3 改當研究員 → v3.4 退役、Claude
原生 `research-scout` 接手，見前史表），但判準沒變：

- **Research 是 nice-to-have（失敗可降級），review 是 must-have（失敗不可
  降級）**——這條決定了誰能被替換、誰不能。
- 「每個 model 做自己最強的事」不等於「每個 model 都要能 review」：review 集中
  在有官方 plugin 的 codex；研究跟著當代最好的搜尋能力走，現在那是 Claude 原生
  的 WebSearch/WebFetch，不必再跨出 Claude 生態。

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

v3 引入兩個 hooks，v3.3 補上第三個，v4.0 加到五個：

- `session-start.sh`（SessionStart）：廣播 kit context（profile、marker 路徑）
  + 記 review gate 的 git baseline（v3.3）+ compact/resume 重錨定（v4.0）
- `classify-task.sh`（UserPromptSubmit）：只認明確修飾語（v3.3 起移除啟發式）
- `verify-final-review.sh`（Stop）：強制最終 review（profile-aware；v3.3 起
  含 commit 盲區修復與 content-hash 認證；v4.0 起只認含證據行的 marker）
- `protect-paths.sh`（PreToolUse，v4.0）：專案禁區 deterministic hard-deny；
  kit-owned 檔案轉 ask 請示（無人值守等同封鎖）
- `tool-breaker.sh`（PreToolUse + PostToolUseFailure，v4.0）：重試螺旋
  熔斷 + 失敗密度警示 + 埋點日誌

「沒它就會出錯」的判準在 v4.0 有了操作化版本：**違反時能被物理偵測的
紀律才做成 hook**；其餘進 rules 檔，並誠實接受 prompt-level 的強度上限。

v3.5 起**預設開啟**（v3 至 v3.4 為 opt-in）。當年 default-off 的理由：

**Hooks 的好處**：
- 確定性執行，不靠 LLM 記憶
- 紀律強，不會在長 session 後段被忘記

**Hooks 的代價**：
- 增加 debug 複雜度（背景跑、看不到）
- 安全敏感（用使用者權限執行 shell）
- 可能跟 superpowers 的 hooks 衝突

「最少必要」原則：只用 hooks 實現「沒它就會出錯」的紀律。其他保持彈性。

v3.5 翻轉預設的推理見 §二 v3.5：代價清單裡真正致命的（gate 的洞）已在
v3.3 修復且有行為測試保護，而 default-off 的隱性代價——大多數部署根本
沒有 gate 在跑——比殘餘代價更高。

## 六、為什麼不做更多

開發過程中冒出許多「也可以加」的想法：

- SubagentStop hook 自動 review 每個 phase
- PostToolUse hook 監控 quota
- SessionStart hook 環境檢查（v3.3 兌現——痛點終於出現：gate 的 commit 盲區
  與 marker 路徑廣播都需要它。「等踩到痛點再做」在這條上驗證有效）
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
