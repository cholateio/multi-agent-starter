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

### v3.1（已被擴充）：profile 切換 + 一鍵 init + 文件精簡

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

### v3.2（已被擴充）：所有權二分 + 更新回流 + 文件模板

v3.1 讓開專案跟日常溝通變輕，但 kit 鋪進多個專案之後，暴露出下一層痛點：
**kit repo 更新了，已經跑過 `init.sh` 的專案卻拿不到**——workflow rules
埋在 CLAUDE.md 的段落裡，沒有回流機制，只能人工比對貼過去（drift 陷阱的
另一種形式）；同時各專案的 README 形狀不一，讓「隔幾個月回來」的重啟成本
又悄悄爬回來；而 PROMPTING.md 這份 v3.1 才推出的一頁速查，實戰下來也沒人
回去翻——控制文法就那幾條，內化一次之後就記住了，速查卡反而是多餘的一層。

三個關鍵決策：

1. **檔案級所有權二分取代段落級約定。** v3.1 的 CLAUDE.md 是「上半使用者
   填、下半 kit 塞」的單一檔案，靠人自律不去動下半段——但沒有工具強制，
   `init.sh` 也無從得知使用者是否手滑改了下半段，該不該覆蓋。v3.2 把
   workflow rules 整段搬進 kit-owned 的 `.claude/rules/kit-workflow.md`
   （`.claude/rules/` 由 Claude Code 自動載入，不需額外接線），CLAUDE.md
   歸零成純專案內容。**所有權從「檔案內的段落」升格成「檔案本身」**：
   `init.sh --update` 因此可以對 kit-owned 檔案直接 add-or-overwrite，不用
   再猜哪段能動、哪段不能動——這正是回流機制原本缺的那塊拼圖。

2. **PROMPTING.md 光榮退役。** 它的存在理由是教使用者一套控制文法；這個
   教學任務跑了幾輪專案之後已經完成——文法內化了，速查卡就沒人翻。與其
   放著佔一個檔案位置，不如把僅存的殘值（回來複習的那句 prompt、
   `--update` 指令）併進 `templates/README.md` 的「叫 AI 接手」段，讓它
   跟其他「回來 30 秒重啟」的資訊待在同一個地方。這是教訓 3（使用者文件
   要符合使用時的形態）的下一步：連「一頁速查」都可能太重，真正常駐的
   落點是使用者本來就會回去看的專案 README。

3. **`--existing` 移除，改自動偵測。** `init.sh` 原本要求使用者自己判斷
   「這是不是既有專案」再選對 flag，但這個判斷 `init.sh` 自己看一眼目標
   目錄是不是空的就能做——多一個 flag 只是多一次使用者會選錯的機會。冗餘
   的決策不該留在介面上。

> 這條路走下來，「少即是多」換了第三種樣貌：v3 簡化的是**實作**（自製
> wrapper 退役），v3.1 簡化的是**介面**（啟動與溝通），v3.2 簡化的是
> **所有權**（誰能改哪個檔案，從一條靠自律遵守的約定變成一條工具能執行
> 的規則）。

### v3.3（已被擴充）：harness 閉環——review gate 修復 + session onboarding + 權限基線

v3.2 解決了「檔案怎麼進專案、怎麼更新」；實戰下一個痛點在 harness 層：kit
最重要的紀律機制（Stop review gate）其實有三個洞，而且 hooks/skills/agents
之間沒有形成閉環。v3.3 全部針對這一層：

1. **Review gate 修成真的閉環。** 三個洞：(a) marker 無人寫——hook 檢查
   `/tmp/claude-codex-reviewed-<id>` 但沒有任何流程會寫它，審完照樣過不了；
   (b) commit 盲區——只看 `git status`，頻繁 commit 的 workflow 下 gate 全盲；
   (c) rename/空白檔名解析錯誤。修法：SessionStart hook 記 session 起點
   baseline（HEAD + working-tree content hash），Stop hook 聯集「未 commit
   （`-uall`）+ baseline 以來的 commits」，gate 滿足時推進 baseline。審過的
   狀態用 content hash 記住——「審完才 commit」不會被重複追殺（tree hash
   不因 commit 而變），baseline 損毀則 fail closed（全部列管，一次 review
   自癒）。cross-model review 在 plan 階段就抓到「審過的未 commit 變更會
   永遠重複 block」與「新目錄內檔案逃逸」兩個 P1——隔離的實證價值再 +1。

2. **SessionStart hook 兌現。** v3 時代它在「為什麼不做更多」清單裡（沒踩到
   痛點）；v3.3 踩到了——Claude 無法知道自己的 session_id，所以 marker 檔
   永遠只有 hook 單方面知道路徑。SessionStart 廣播 KIT_CONTEXT（profile、
   codex/gemini 可用性、marker 路徑）+ 記 baseline，一支 hook 同時解掉
   「onboarding」跟「gate 盲區」兩個問題。

3. **修飾語 skills 化。** `/kit-review`（依 profile 跑對的 review + touch
   marker）、`/kit-skip-review`（user 授權的 gate 跳過）。marker 的讀寫從此
   有唯一的家；classify-task.sh 同步瘦成 explicit-override only——關鍵字
   啟發式（button→small、refactor→large）判斷力不如模型本身，刪；連
   `quick fix`/`small change` 這類描述詞也不再觸發，只認祈使句。

4. **solo-reviewer 從敘述變正式 agent 檔。** solo profile 的自審之前只存在
   於規則文字裡；現在是 `.claude/agents/solo-reviewer.md`（read-only 工具、
   輸出格式、「不因為 writer 是自己就手軟」的明文協議）。

5. **權限基線 + autoMode 評估。** settings 模板直接內建 read-only
   `permissions.allow`（git status/diff/log/show、ls、timeout、gemini_exec）。
   `defaultMode: "auto"`（background 分類器自動核可，research preview）評估後
   **不採用**：(a) preview 語義可能變動，kit 承諾的是可預期性；(b)
   settings.json 裝機後歸使用者，kit 不該替使用者選權限哲學；(c) kit 的信任
   邊界在 review gate，不在權限放寬——顯式 read-only allowlist 用零驚訝換掉
   八成摩擦。等 auto 轉 GA 再回頭評。

kit-workflow.md 同步瘦身成 landmines-only（~60 行）：留下的是模型自己推不出
的高風險規則（isolation 地雷、gate 機制、STOP 條件），刪掉的是模型本來就會
的（任務大小判斷表、能力清單）。

### v3.4（已被擴充）：gemini 退役——研究回歸 Claude 原生

使用者決定將 gemini 自工具鏈移除。**這是使用者環境的個人因素決策，不是
模型能力問題**——研究員角色本身留任，由 Claude 原生的 `research-scout`
子代理（WebSearch + WebFetch）接手執行。

介面刻意不動（「換心臟不換介面」）：觸發條件、輸入（Topic / Context /
2-5 個問題 / Constraints）、輸出格式、「研究是 nice-to-have 不是 gate」
的失敗語義全數保留，只換掉執行者。連帶的結構紅利：

1. **Profile 從此只決定一件事：誰當 reviewer。** 研究不再是 full 限定
   （不依賴外部 CLI 之後，solo 也能用），full/solo 的差異收斂成單一開關。
2. **少一個外部依賴面**：GEMINI_API_KEY、gemini CLI 安裝、quota debug
   全部消失；init.sh 環境檢查與 session-start 廣播同步瘦身。
3. 同輪收掉 v3.3 的三個 fix-later（`--help` 噪音、`--update` 補缺失
   settings.json、smoke env 隔離），並為已鋪 kit 的專案加 `--update`
   遷移提示（孤兒 gemini 檔不代刪、只講明去向）。

### v3.5（已被擴充）：sizing 防偏壓 + hooks 預設開啟

對照《AI Coding Agent》的 Harness Engineering 框架做了一輪 gap 分析，
修的是兩個「機制正常、效果打折」的點：

1. **Workflow sizing 被 superpowers 的觸發規則結構性壓過。** v3.3 把
   關鍵字啟發式刪掉、交給模型自判是對的；但實戰發現 default 路徑上有
   一股不對等的力量——superpowers 的 using-superpowers 每個 session 以
   EXTREMELY_IMPORTANT 級別注入「1% 可能適用就必須 invoke」，而
   brainstorming 的 description（creating features / adding functionality
   / modifying behavior）幾乎 match 所有改 code 的任務。kit-workflow.md
   的 sizing 表只有四行、語氣弱，單檔小 feature 這種灰色地帶就被拉進
   brainstorm→spec→TDD 全套。修法是「把模型需要的授權文字放進它會讀、
   優先權最高的位置」：sizing 段給小任務可操作判準（≤2 檔、無新依賴、
   不碰 schema/auth/payment/constraints → 直接做 + 自行驗證），並引用
   superpowers 自己承認的優先權順序（專案指示 > skills）明文解除小任務
   的強制觸發；模糊地帶則「問一句」而非默默走全流程。同輪清掉
   research-before-planning 與 research-scout 裡引用已廢除分類器的
   `large_task`/`small_task` 標籤。

2. **Hooks 從 opt-in 改為預設開啟。** 「最少必要」在 v3 選擇 default-off
   的理由是 gate 有洞、debug 複雜；v3.3 把三個洞修完、hooks-smoke.sh
   380 行行為測試蓋住 edge case 之後，opt-in 的前提已不存在——而
   default-off 的實際代價是大多數部署根本沒有 gate 在跑，kit 最重要的
   紀律機制形同虛設。settings.json 歸使用者所有的原則不變：`--update`
   照舊不覆蓋既有 settings.json，只印 diff 讓使用者自己合併。

### v4.0：弱模型防線——判斷力外化 + 物理熔斷

背景與動機和前幾版不同：這一版**不是踩到痛點後的修補，而是一次預防性
立法**——由 Fable 5（一次性的高階模型 session）在制度層面外化判斷力，
供此後長期運營的較弱模型（Opus 4.8 指揮、Sonnet/Haiku 執行、無人值守
為常態）使用。完整診斷見 `docs/harness-diagnosis.md`（三大失敗場景 →
三個物理痛點），交接脈絡見 `docs/handover-from-fable.md`。核心決策：

1. **防線分層：hook 管物理，rules 管判斷。** 評估標準明文化——「這條
   規則被違反時能否被物理偵測？」能 → 做成 hook；不能 → 進 rules，
   並接受其強度上限。v4.0 新增兩支 hook：`protect-paths.sh`（PreToolUse：
   `.claude/protected-paths` 專案禁區 hard-deny；kit-owned 檔案轉 ask
   請示——user 在場一鍵放行、無人值守等同封鎖，避免與 update-config 等
   內建流程打架；user-only 逃生口 `KIT_PROTECT=off`）與 `tool-breaker.sh`（雙事件：
   PreToolUse 連續相同調用熔斷 + PostToolUseFailure 失敗密度警示 +
   全調用埋點日誌）。
2. **逃生門加價：marker 證據化。** Stop gate 的 block 訊息原本親手印出
   `touch <marker>`——假性完成的最短路徑是 harness 自己鋪的。v4.0 起
   marker 必須含 `reviewed-by=` 證據行（由 /kit-review 在 review 真跑完
   後寫入），block 訊息不再印任何 incantation。誠實路徑從此比造假省力。
   誠實標註：這是摩擦 + 審計，不是密碼學防偽（模型持 Bash 可偽造一切；
   最後一層是人對埋點日誌的抽查）。
3. **compact 重錨定。** SessionStart 偵測 `source=compact|resume` 時注入
   RE-ANCHOR 指令（重讀 constraints 與 plan、自報 phase）——記憶解體
   風險最高的時刻，給最強的錨。
4. **判斷力外化成可比對的檢核表。** `.claude/rules/kit-delegation.md`
   （指揮官不下場、派工三件套、Haiku→Sonnet→Opus 升降級、implementer≠
   verifier）、`.claude/rules/kit-evolution.md`（模型可自改什麼、LESSONS
   格式與精簡協議）、`.claude/docs/judgment-matrix.md`（換路徑信號/完成
   判準/熔斷提問/品味極限，每條附正例反例）、`/kit-dispatch` skill
   （四種派工模板）。`init.sh` 的 kit-owned 集合加入 `docs`。
5. **CLAUDE.md 範本改版**：弱模型需要極度明確的範本——佔位符全部附
   格式與範例、constraints 要求與 protected-paths 同步執法、加檔案路由
   表（何時讀哪份文件）。

### v4.1：判斷層採納——fable-soul 蒸餾

v4.0 防的是**結構性失敗**（context 經濟、迷航、重試螺旋、marker 造假）；
v4.1 補**認知性失敗**（假完成措辭、過期驗證、湊數 findings、hedge 話術）。
素材採自 fable-soul（MIT）——一份在弱模型上做過 RED-GREEN 行為測試的
Fable 判斷蒸餾——但只收 kit 未覆蓋的機制，不照搬。核心產出：

1. **`.claude/rules/kit-judgment.md`**（auto-loaded 第四檔）：八條機制
   （目標≠指定修法、機制先於動手、verified/unverified 二分、stale-green
   reset、證據勝過記憶、量測代替 hedge、給判斷不給菜單、先確認再舉報）
   + 藉口對照表 + Red Flags。與 judgment-matrix 的分工寫死：R3（熔斷
   提問）/R4（品味不拍板）觸發條件優先於本檔的「直接做」傾向。
2. **per-turn digest**（classify-task.sh）：每個非空 prompt 注入一行
   KIT_JUDGMENT 提醒——確定性 re-fire，不依賴模型記得自查。fable-soul
   原案掛在 Stop hook，但 Stop 的 exit-0 stdout 進不了 model context
   （transcript-only），實作無效；移到 UserPromptSubmit 才真的送達。
3. **派工模板判斷句 inline**：snapshot caveat（subagent 只繼承 session
   啟動時的指令快照，實測 2026-07-03）使模板成為弱執行員判斷規則唯一
   保證送達的載體。模板 2/3 加措辭紀律（stale-green、hedge 禁令）、
   模板 4 加「沒驗證的警告=錯誤」、新增模板 5 驗收 read-back（四種
   造假模式清單：無證據宣稱、跳過的檢查、發明的路徑/數據、被弱化的
   斷言）。
4. **prose 層有了 proof surface**：`tests/evals.md`（行為 eval 套件，
   0–2 評分）+ kit-evolution「規則變更紀律」（先查覆蓋、RED-GREEN
   收據、逐字記藉口、rules/ 總量 20KB 預算由 smoke test 把關）。
   誠實條款：2026-07-05 實測 **RED 全數未重現**——fresh Haiku 4.5 +
   kit v4.0 快照已扛住這些場景；kit-judgment 的目標條件是長 session
   退化後的模型（合成 eval 無法模擬），失敗證據承接 fable-soul 的
   外部收據與本 kit 生產史（詳見 tests/evals.md 採納註記）。
5. **`docs/instruction-audit.md`**：例行規則審計（每 minor 版本前跑）。
   prose 有四層之後，「兩條規則打架」沒有物理偵測手段，只能例行審計。

### v4.2：verification-signals 領域層

`.claude/docs/verification-signals.md`（read-on-demand，經 CLAUDE.md
路由表觸達）：五個「迴圈裡缺便宜驗證信號」的高風險領域（UI 截圖、
schema 讀取路徑、bug 連環卡交接、SaaS 成本卡、業務邏輯可觸達性）——
kit-judgment 通用證據紀律在領域層的實例化。

### v4.3：成本感知層

痛點（2026-07-07 真實 session）：調適期小改也被 size-blind Stop gate
逼跑跨模型 review；模型/effort 配置只在 user 主動要求時出現。三個產出：

1. **Stop gate 小改自動放行**（verify-final-review.sh）：量測「距上次
   認證 tree 的累積 numstat」，≤50 行 / ≤2 業務檔 / 無敏感或 protected
   路徑 → 放行但**不推進 baseline**——小改累積，破檻那次 review 批次
   涵蓋全部（防切香腸）。無 baseline / binary 一律 fail-closed。門檻
   是 git 實測，模型話術無效——延續「能用 hook 擋的不靠 rules」判準。
2. **主導模型/effort 配置提案**（kit-workflow.md）：feature 級以上
   計畫簽核必附各 phase 主導模型 + effort + 一句理由 + 卡關升級條件；
   phase 交界一行 /model 提醒。純建議、user 執行（scenario 9 RED-GREEN
   收據見 tests/evals.md）。
3. **classify-task 描述語境濾網**：遮罩「頻率/進行式標記 + 觸發詞」
   再比對——「一直在走完整流程」是描述不是指令（2026-07-10 實際誤觸）。

### v4.4：專案 manifest 體系

痛點：機隊擴到十個專案後，「哪個在跑、怎麼啟動、誰在燒錢」只存在人的
記憶裡。決策：**狀態要機器可讀，維護不靠記性**。

1. **`PROJECT.toml`**（專案根，**user-owned**，`--update` deploy-if-absent
   ——比照 settings.json 先例，kit 永不覆蓋）：status / status_note /
   `[commands]` / `[[paid]]`。
2. **`bin/proj`** 跨專案彙總：`proj`（狀態總覽 + 過時偵測）/ `proj money`
   （燒錢視圖）/ `proj remote`（gh 對照未 clone）。
3. **`rules/project-manifest.md`**（kit-owned，隨 --update 推平）：session
   結束前狀態/指令/付費服務有變就同步。維護慣例做成規則，而不是靠人記得。
   收錄判準：`[commands]` 只收「**用它**」的指令，不收「**開發它**」的
   （dev/build/test 查 package.json 就有）；`status_note` 固定兩段
   「目前進度;下一步」，細節歸 LESSONS/commit。

### v4.5：proj html dashboard

`bin/proj html` 產出自包含 HTML dashboard（WSL 自動開瀏覽器）——終端太窄
時看不下十個專案的橫排資訊。同版把 manifest 的收錄規範從渲染端啟發式
過濾**上移到 schema**（kit rule）：規則寫在 manifest 規範裡，渲染層有
什麼顯什麼，不再猜。

### v4.6（當前）：review 經濟學——輪數、門檻、註解噪音

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
   ——敏感檢查先於測試排除。判準延續 v4.3：門檻由 git numstat 實測，
   模型話術無效。
3. **註解紀律**（kit-workflow + dispatch 模板 2/3）：user 逐字收據
   「vibe coding 的模式下…實在沒必要每次撰寫 code 都產生大量註解」。
   關鍵洞察：**「對 AI 友善」與「減量」是同一刀**——代碼的實際讀者是
   未來的 AI session，它讀 code 比讀散文快，敘述性註解是純噪音；它需要
   的是代碼顯示不了的四類（不變量/外部約束、跨檔耦合、非顯然 why、
   附日期收據）。辯護性註解歸 commit message／LESSONS。
4. **rules/ 精簡**（20253B→18962B）：砍字不砍義務，把 20KB 預算的餘裕
   還回來——規則檔是每 session 的固定 context 稅，新增前先還債。

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

### 為什麼 Gemini 變成研究員

v2 把 gemini 當 reviewer。v3 改成研究員。理由：

- 前沿模型在 code review 任務上越來越同質——「不同 model」的差異變小
- 但 gemini 在**網路搜尋整合**上有真實差異化優勢（內建 Google Search 能力）
- Research 是 nice-to-have（失敗可降級），review 是 must-have（失敗不可降級）
- 把 review 集中在 codex（有官方 plugin）、研究分給 gemini（發揮搜尋優勢）

這個分工讓**每個 model 做自己最強的事**，而不是強迫它們都能做 review。

> **v3.4 後記**：gemini 已因使用者環境因素退役（非能力問題）。研究員角色
> 由 Claude 原生 research-scout 接手——「每個 model 做自己最強的事」的分工
> 邏輯不變，只是研究這件事不再需要跨出 Claude 生態才能做好：WebSearch/
> WebFetch 已是原生能力，而「研究失敗可降級、review 失敗不可降級」的
> 判準依然成立。

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
