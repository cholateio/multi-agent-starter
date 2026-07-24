# 如何有效駕馭 AI Coding Agent：Claude Code 與 Codex 實戰操作手冊

> 內部技術文件 · 2026 年 7 月版 · 聚焦 Claude Code 與 OpenAI Codex 生態

## TL;DR

- **駕馭 agent 的能力階梯是 Prompt → Context → Harness**：把指令講清楚只是入場券；真正拉開 10x 與 2x 差距的是「上下文工程」（決定模型每次推論看到哪些 token）與「工程鷹架」（讓 agent 能安全、可驗證、可重複執行的環境）。Anthropic 研究論文《How Claude Code is used in practice》（2026-06-16 發表，分析 2025-10 至 2026-04 約 235,000 名使用者的約 400,000 個 session）指出「people make about 70% of the planning decisions but only 20% of the execution decisions...people decide what to build, and the agent decides how to build it」——你的槓桿在規劃與環境設計，不在打字。
- **Claude Code 與 Codex 各有主場，建議兩者並用**：Claude Code 走本機終端、以 CLAUDE.md + hooks + MCP 提供細粒度應用層治理，程式碼品質與長 session 記憶較強；Codex 走沙箱（cloud + 本機 OS 級 sandbox）、以 AGENTS.md + execpolicy 提供粗粒度但強邊界的安全模型，token 效率與非同步平行執行較強。常見分工是 Claude Code 做架構/複雜重構、Codex 做審查/除錯/大量平行任務。
- **Harness 才是團隊真正要投資的護城河**：把使用者提出的三大維度落地——(1) 隔離模擬環境（Mock/Stub + Record & Replay 讓測試不打真 API、Bug 可無限重播）、(2) LLM 評估框架（LLM-as-Judge + Golden Dataset 進 CI 防退化）、(3) 資料飛輪（結構化日誌 → 自動萃取最佳執行 → 回灌成新 benchmark）。這三者把「有時神、有時廢」的 agent 變成可持續改進的工程系統。

## Key Findings

1. **上下文是有限資源，不是越多越好。** Anthropic《Effective context engineering for AI agents》（2025-09-29）定義：「LLMs, like humans, have an 'attention budget'...good context engineering means finding the smallest possible set of high-signal tokens that maximize the likelihood of some desired outcome」，並解釋 context rot：「as the number of tokens in the context window increases, the model's ability to accurately recall information from that context decreases...this characteristic emerges across all models」。實務界的共識（Dexter Horthy / HumanLayer）是把上下文使用率壓在約 40%，超過就進入「dumb zone」。
2. **CLAUDE.md / AGENTS.md 要短。** 官方與社群共識是 CLAUDE.md 控制在 200 行以內，某些團隊低到 60 行。過長會讓 Claude「忽略一半」，重要規則淹沒在雜訊裡。能被 linter/hook 處理的事，就不要寫進 markdown。
3. **subagent 的本質是「context 隔離」而非「角色扮演」。** subagent 在獨立 context window 執行、只回傳摘要，讓主線對話保持乾淨——這是對抗 context pollution 最有力的工具。
4. **Harness 是官方級別的研究主題。** Anthropic 的《Effective harnesses for long-running agents》提出 initializer agent + coding agent 雙層架構、feature list（JSON 格式、200+ 條、初始全標記 failing）、progress 檔 + git commit 作為跨 session 記憶橋樑。
5. **驗證迴圈（tests/lint/type check）是 agent 最強的自我修正訊號。** TDD 是與 agentic 工具協作最強的單一模式：先寫測試、確認失敗、commit 測試、再讓 agent 實作到綠燈。
6. **兩者都已 GA 平行多 agent。** Codex 於 2026-03-14 GA subagents（manager 分解任務後在各自 cloud sandbox 生成 explorer/worker/default 三種角色，「You can now spawn up to 8 parallel agents from a single task, each with its own dedicated context window and cloud sandbox」）；Claude Code 有 Agent Teams 與原生 git worktree 隔離（`--worktree` / `isolation: worktree`）。

## Details

### 第一層：Prompt Engineering — 如何對 coding agent 下指令

Prompt engineering 是基礎，但在 agentic 時代它只是 context engineering 的一個子集。核心原則：

**1. 講清楚「什麼是完成」，而且要可驗證。** 多個獨立實務報告都指出：帶有可檢查成功標準（如「`npm test` 通過」「`curl` 回 200」）的指令，比可解讀標準（如「寫乾淨的程式碼」）產生更可靠的結果。「每個函式都要有 docstring、函式最長 50 行」比「寫出結構良好的程式碼」被遵守得好得多。

**2. Plan Mode 先行。** Claude Code 的 plan mode（Shift+Tab 兩次進入）限制 agent 為唯讀，讓它先探索程式碼、產出計畫再動手。Opus 4.5 起 plan mode 會先問澄清問題、再產出可編輯的 plan.md。Anthropic 自家團隊發現無引導的嘗試成功率約 33%，工具創造者本人會放棄 10-20% 的 session——差距來自你放在工具周圍的模式，不是你打的字。

**3. Spec-driven development（規格驅動）。** 對於觸及 4 個檔案以上的變更，先寫 spec 再寫 code。標準流程是 Specify → Plan → Implement → Validate，每個階段間放人類審查閘門（review gate）。關鍵洞見：人類 review 閘門應該放在 Plan 與 Execute 之間，而不是 Explore 與 Plan 之間——探索很便宜，讓 agent 自由讀；但動檔案前要先看過計畫。有工程師花兩小時寫 12 步 spec，省下估計 6-10 小時的實作時間。開源框架如 GitHub Spec Kit、Superpowers（已成 Anthropic 官方 plugin）、BMAD-METHOD 把這套流程包好可直接用。

**4. 給參考範例。** 貼上可運作的開源程式碼配合 plan 請求，比抽象描述明顯改善產出——「對 LLM 而言，範例是值一千字的圖片」（Anthropic）。

### 第二層：Context Engineering — 管理上下文、記憶、檔案結構

這是 2026 年最關鍵的技能。Anthropic 在《Effective context engineering for AI agents》定義它為「策劃並維護 LLM 推論時最佳 token 集合的策略集」，並解釋 context rot 的成因：transformer 每個 token 都要 attend 到其他所有 token，n 個 token 產生 n² 對關係，context 越長注意力越稀釋；模型也有「注意力預算」，每個新 token 都在消耗它。所以好的 context engineering 是「找到最小的高訊號 token 集」，不是塞最多 token。

**CLAUDE.md / AGENTS.md 撰寫最佳實踐：**

- **保持精簡（<200 行，越短越好）。** 每一行都要自問：「刪掉這行 Claude 會不會犯錯？」不會就刪。
- **內容選「名詞」不選「動詞」。** CLAUDE.md 放「東西在哪、是什麼」（架構、慣例、技術棧與版本、專案結構、常用指令、要避免的模式）；具體任務流程用 slash commands 或 skills。
- **善用階層。** Claude Code 記憶階層是 managed → user (`~/.claude/CLAUDE.md`) → project (`./CLAUDE.md`) → local，越具體的越後載入、有效勝出。大型專案用 `.claude/rules/` 目錄拆成單一主題檔（各自維護、避免 merge 衝突），或用 `@path/to/file.md` import（最深 5 層）。子目錄的 CLAUDE.md 只在 Claude 於該子樹工作時才載入。
- **Codex 的 AGENTS.md 機制類似但更開放。** Codex 在啟動時建立指令鏈：全域 `~/.codex/AGENTS.md`（或 `AGENTS.override.md`）→ 從 git root 往下走到工作目錄，每層找 `AGENTS.override.md` → `AGENTS.md` → fallback 檔名。AGENTS.md 是開放格式標準，Cursor、Aider 等工具也讀，跨工具可共用一份。若已有 AGENTS.md，可讓 CLAUDE.md 只寫 `@AGENTS.md` 加 Claude 專屬補充，維持單一真相來源。
- **讓它自我進化。** Claude 犯錯時，叫它把修正寫回 CLAUDE.md。Claude Code v2.1.59 起有 auto memory，Claude 會自己記下 build 指令、除錯心得、你糾正過的偏好。
- **重要規則用 hooks/permissions 強制，不要只寫 markdown。** CLAUDE.md 是「指引」，會被忽略；絕不能發生的事要放 hooks 或 permission 規則。

**subagent 分工：**

subagent 是有獨立 system prompt、獨立工具權限、獨立 context window 的專門助手。Claude 遇到符合其 description 的任務就委派出去，subagent 在分離的 context 執行、只回傳摘要——搜尋結果、log、檔案傾印都不會污染主線。實務關鍵：

- **description 是路由器，不是標籤。** Claude 用它決定是否自動委派，要寫成「什麼情境該叫我」，需要主動觸發就加「use proactively」。
- **三階段管線：Explore → Plan → Execute。** Explore 唯讀讀碼、Plan 設計方案、Execute 才動檔案；Explore/Plan 刻意跳過 CLAUDE.md 與 git status 以保持快又便宜。
- **用便宜模型跑 subagent 省成本。** 設 `CLAUDE_CODE_SUBAGENT_MODEL`，主線跑 Opus、subagent 跑 Sonnet/Haiku。
- **檔案位置決定範圍。** `.claude/agents/`（專案級、進版控、團隊共用）與 `~/.claude/agents/`（個人跨專案）。注意 subagent 在 session 開始時載入，改檔要重啟；透過 `/agents` 建立的即時生效。（Codex 端對應的自訂 agent 存於 `~/.codex/agents/` 的 TOML 檔。）

**Compaction（壓縮）與 intentional compaction：**

Claude Code 有自動 compaction，但 Anthropic 自己承認「compaction 不足夠」——它不總是把清楚的指示傳給下一個 session。Dexter Horthy（HumanLayer，YC 演講《Advanced Context Engineering for Agents》，本報告參考影片 `b_9D7T0n4RA`）主張「頻繁刻意壓縮」：手動把進度摘要成一份「經審查的 markdown 檔」，再用它 seed 一個全新的 context，把探索變成一次性成本。他明言「when more than approximately 40% of the context window is used, diminishing returns kick in...The more you use the context window, the worse the outcomes you'll get」，超過此點稱為進入「dumb zone」。他的實務數據記錄於 HumanLayer 部落格：「We've gotten claude code to handle 300k LOC Rust codebases, ship a week's worth of work in a day, and maintain code quality that passes expert review」——具體案例是 BoundaryML 的 BAML（30 萬行 Rust）codebase，PR 由維護者隔日早上批准合併。他強調 subagent 的用途是「context 控制」——開一個新 context 去搜/讀/摘要一大片程式碼，只回傳精簡的事實指標（例如「邏輯在 foo/bar.ts:120-340」），讓父 agent 不用弄髒自己的視窗。（採用 RPI 心法時可參考此工作流：Research 壓縮系統實際運作、Plan 是最高槓桿步驟、Implement 只做機械執行。）

**避免 context rot / pollution 的操作清單：**

- 用 subagent 做探索，別讓主線讀幾百個檔案。
- MCP 工具用 tool search（Claude Code 2.1.7、2026-01-14 推出，預設開啟）延遲載入 tool 定義：50 個 MCP 工具的 context 從約 77K token 降到約 8.7K token，Anthropic 官方稱「85% reduction in token usage」，且 Opus 4.5 的 MCP 評估準確率由 79.5% 升至 88.1%；當 MCP 工具超過 context 10% 時自動啟用。
- 快速問題用 `/btw`，答案出現在可關閉的 overlay，不進對話歷史。
- 自訂 compaction 行為：在 CLAUDE.md 寫「壓縮時務必保留完整的已修改檔案清單與測試指令」。

### 第三層：Harness Engineering — 打造安全、可驗證、可重複的工程環境

Harness（鷹架/挽具）是把「模型」變成「可靠 agent」的那一層。這是官方級別的研究主題，也是團隊最該投資的地方。

**官方定義與基礎架構。** Anthropic《Effective harnesses for long-running agents》（2025-11-26）指出長時 agent 的核心難題是「每個新 session 從零記憶開始」，如同輪班工程師每班都失憶。他們的雙層解法：
- **Initializer agent**（第一個 session）：建立 `init.sh`（可啟動 dev server）、`claude-progress.txt`（進度日誌）、初始 git commit，並寫一份完整的 feature list（claude.ai clone 例子中 200+ 條，用 JSON 格式因為模型較不會亂改 JSON，初始全標 `passes: false`）。
- **Coding agent**（後續每個 session）：讀 progress 檔與 git log 上手 → 選一個未完成 feature → 只做一個 feature → 用 browser 自動化（Puppeteer MCP）端到端驗證 → commit + 寫進度。四大失敗模式（過早宣告完工、留下 bug、未測就標完成、浪費時間搞清楚怎麼跑）各有對應解法。

**沙箱與權限模式：**

- **Codex 沙箱（OS 級強邊界）。** 三種模式：`read-only`、`workspace-write`（預設，可讀可在工作區改可跑本地指令）、`danger-full-access`（無限制）。實作：macOS 用 Seatbelt（`sandbox-exec`）、Linux 用 Landlock + seccomp（或 bubblewrap）、Windows 原生 sandbox 或 WSL2。預設**網路關閉**、寫入限工作區。approval policy 與 sandbox 是兩個獨立控制：sandbox 定義「技術上能做什麼」，approval 定義「何時要停下來問你」。可用 `codex debug seatbelt` / `codex debug landlock` 測試指令在沙箱下的行為。企業可用 `requirements.toml`（MDM 部署、限制開發者不能放寬政策）+ managed proxy（domain allowlist）做多層防禦。
- **Claude Code 權限（應用層細粒度）。** 以 hooks 與 permission 規則在應用層治理，粒度細但邊界較弱。原則性差異：Codex 是「強邊界、粗控制」，Claude Code 是「弱邊界、細控制」。審查不信任的外部程式碼 → 用 Codex kernel sandbox；在信任的程式碼上強制團隊規範 → 用 Claude Code 可程式化 hooks。
- **git worktree 隔離。** 兩者都支援讓平行 agent 各有獨立工作目錄、共用同一 git 歷史。Claude Code 原生 `claude -w feature-x` 或 subagent frontmatter 加 `isolation: worktree`；桌面 app 每個新 session 自動建 worktree。`.worktreeinclude` 檔可自動複製 `.env` 等 gitignored 檔進新 worktree。實務天花板：每位開發者穩定跑 4-8 個並行 worktree，再多就卡在 review 而非 Claude。GitHub 共同創辦人 Scott Chacon 的 Grit 專案（用 agent 以 Rust 重寫 Git）是目前最公開的大規模平行 agent 案例：GitButler 部落格記載「let's say roughly 45B tokens in total」（成本約 $10-15k），產出 36 萬+ 行 Rust、500+ PR、7,000+ commits，通過 Git 42,001 項測試中的 41,715 項（約 99.3%）；教訓是「協調與 merge 衛生要工程化、不能假設」。

**Hooks 自動化（Claude Code 的殺手鐧）：**

Hooks 在 session 生命週期的特定點執行 shell 指令/prompt/agent，把 CLAUDE.md 的「建議」變成「強制閘門」。四種 handler：command（shell）、prompt（單輪 LLM）、agent（可用工具多步驟驗證）、http（POST 到端點）。關鍵事件：
- **PreToolUse**：工具執行前，可 allow/deny/ask，exit code 2 直接擋掉——這是安全團隊的頭號 hook（擋 `rm -rf`、保護 secrets、擋改 production 檔）。v2.0.10 起還能改寫 tool input。
- **PostToolUse**：工具成功後，自動 lint/format（例如 `Write|Edit` 後跑 prettier + eslint）。
- **Stop**：Claude 收尾前，exit code 2 可強迫它繼續（例如「測試沒過，先修好」）；記得檢查 `stop_hook_active` 避免無限迴圈。
- **SubagentStop / SessionStart / SessionEnd**：路由、注入 branch 資訊、清理。

Hooks 設定在 `.claude/settings.json`（進版控、團隊共用）或 `settings.local.json`（個人）。到 2026 年 4 月已有 26 個生命週期事件（v2.1.116）。

**MCP 整合：**

MCP（Model Context Protocol，Anthropic 2024 開放標準）讓 agent 連外部工具/資料庫/API。Claude Code 用 `claude mcp add`，設定分全域（`~/.claude/settings.json`，放 Gmail/Slack 等通用工具）與專案（`.mcp.json`，放 Context7/Sentry/DB 等專案工具）。Codex 用 `config.toml` 的 `[mcp_servers.*]` 或 `codex mcp add`，也能反過來 `codex mcp` 把自己當 MCP server 讓別的 agent 呼叫。最高槓桿的服務型 MCP：GitHub（PR/issue）、Context7（消除 API 幻覺，公認最高影響力）、Playwright/Chrome DevTools（瀏覽器驗證）、Sentry（生產錯誤上下文）、Postgres/Supabase（DB）。注意工具清單越短越好——每個 server 的 tool 定義都吃 context，agent 每輪都要考慮每個工具，太多會變慢又選錯。2026 的趨勢是「code mode / 程式化工具呼叫」部分取代 MCP：模型直接寫程式呼叫 CLI（如 `gh`）在沙箱裡鏈接複雜動作，MCP 保留給沒有好 CLI 的服務。

**Headless / CI 整合：**

- **Claude Code**：`claude -p "prompt"`（print/headless 模式）是所有自動化的基礎，配 `--output-format json`、`--max-turns`、`--model`、`--allowedTools` 控制。官方 `anthropics/claude-code-action@v1` 包好 GitHub plumbing，`@claude` 提及觸發互動、prompt 參數觸發自動化。安全鐵律：唯讀 review 只給 `Read,Grep,Glob`；改檔限隔離 branch 且人審後才 merge；把 PR 內容當不信任輸入（防 prompt injection）；設 max-tokens 上限（review 20K、fix 60K、排程維護 100K）。
- **Codex**：`codex exec`（非互動），progress 到 stderr、最終訊息到 stdout，`--json` 出 JSONL 給 jq 解析，`--ephemeral` 不留 session 檔。官方 `openai/codex-action@v1` 會起安全 proxy、drop sudo 讓 Codex 讀不到自己的 API key（公開 repo 防洩漏）。CI 認證用 API key 而非 ChatGPT 登入（後者會吃你的互動額度）。**OpenAI 內部 Codex review 100% 的 PR**。

### 使用者三大 Harness 維度的深化落地

**維度一：隔離與模擬環境（Mocking & Stubbing + Record & Replay）**

目標是讓本機/CI 測試不需真打 API 或走 SSO。做法：
- **高擬真 Mock 服務層。** 學術界的 ClawsBench 做法值得借鏡：為每個外部服務（如 Graph API、OBO 驗證流程）建獨立 REST mock，用 SQLite 存狀態，實作與生產 API 相同的 endpoint、參數、schema、error code；並用「從真帳號擷取的黃金 request-response 對」驗證 mock 保真度（比對 key set、value type、mutation 副作用）。這讓複雜的 OBO 驗證或 SSO 流程可在本機/CI 完全離線重現。
- **Record & Replay（狀態重現）。** 核心洞見：程式執行大多是確定性的，只有非確定性事件（外部輸入、LLM 輸出、工具回應、時鐘、隨機數、WebSocket 封包）需要在錄製時記下。重播時用「確定性 stub」取代每個非確定來源——model stub 回傳錄下的確切 token、tool stub 回傳錄下的確切 API 回應；若 agent 試圖呼叫沒錄過的東西，replay engine 要「大聲失敗」而非偷偷打真系統。要記錄的關鍵：tool identifier（告訴 replay harness 哪個 stub 處理該事件）、時間戳、payload。把 Bug 當下的完整 context（含 WebSocket 封包）錄下來就能無限重播直到修復。開源生態已有多個 record-replay 函式庫（TypeScript/Python/pytest 皆有），可捕捉 model 輸出、tool、MCP、clock、randomness 並精確重播，附 fork、diff、redaction。PII 處理用確定性轉換（format-preserving encryption、keyed hashing）以保留 join 與 group-by 行為。

**維度二：LLM 專屬自動化評估（Evaluation Harness）**

Eval harness 是 AI agent 的「驗證層」——迴圈跑過一個 golden 資料集、對每筆呼叫你的 agent、收集回應與執行 trace、用一套指標評分；它活在離線/開發時路徑，不在即時請求路徑。落地要點：
- **評估方法要多元。** 單一技術涵蓋不了所有失敗模式：LLM-as-Judge（開放式品質如相關性、忠實度、正確性）、確定性斷言（exact match）、embedding similarity（模糊等價）、自訂 scoring（比對 golden dataset）。評估層級分四種：單一 span（一次 LLM/tool 呼叫）、完整 trace（一個端到端請求）、agent trajectory（走過的路徑）、session（多輪）。
- **Golden Dataset 量化。** 改 prompt 或 RAG 檢索邏輯後，自動跑過幾百筆黃金資料，給出相關性、精確度、幻覺評分。開源框架如 DeepEval（GEval 自訂標準、DAGMetric 多步嚴格評分、內建 RAG/agentic 指標）、LangSmith、Arize、Comet Opik 都可用。
- **進 CI 防退化。** 把 harness 寫進 `.gitlab-ci.yml` 或 GitHub Actions，PR 時對 regression dataset 跑同一套評估器，失敗就擋 merge——這是防止「AI 表現靜默退化」最有效的單一模式。注意 LLM judge 本身會幻覺（有工程師形容「每十次評估有一次是垃圾」），低分要自動重跑確認；staging 用已知輸入輸出對測試，production 用小樣本真實 trace 加人工 in-the-loop。

**維度三：資料驅動的持續回饋（Data Flywheel）**

- **結構化日誌（Structured Logging）。** 埋點記錄執行時間、token 消耗、記憶體狀態等 context 寫進資料庫（Supabase / PostgreSQL）。Claude Code 的 hooks 是天然埋點處：PostToolUse 的 `tool_response` 對已完成的 Agent 呼叫帶有 subagent 最終文字與 usage telemetry，可從 hook 記錄每個 subagent 的成本；PostToolUse input 也含 `duration_ms`（v2.1.119）。Codex 用 `--json` JSONL 串流每個事件（指令執行、檔案變更、agent 訊息）。
- **自動化黃金資料集。** 自動分析日誌、篩選最佳執行結果，轉成下次 harness 測試的 benchmark 基準。學術界稱這是「silver → gold」的升級：先用合成/生產 trace 當 silver，再經 SME 審查、評估器一致性檢查、bias 稽核升級成 gold。LangSmith 的實作是「從生產 trace 標記一筆觸發壞回應的真實查詢 → 加進 golden dataset → 下次 CI eval 自動跑」。這條迴圈把生產失敗接回結構化人類回饋，是維持品質隨規模擴張的關鍵。

### 兩工具比較與適用場景（2026 年中）

| 維度 | Claude Code | OpenAI Codex |
|---|---|---|
| 執行位置 | 本機終端（碼留在你機器上） | 沙箱（cloud 容器 + 本機 OS sandbox） |
| 設定檔 | CLAUDE.md（階層/policy/hooks/MCP，僅 Anthropic 工具讀） | AGENTS.md（開放標準，Cursor/Aider 也讀） |
| 安全模型 | 應用層 26 個 hook 事件，細粒度 | OS kernel（Seatbelt/Landlock/seccomp）+ execpolicy，強邊界 |
| 平行 agent | Agent Teams + git worktree 隔離 | subagents GA（manager-worker，最多 8 個） |
| 相對強項 | 程式碼品質、長 session 記憶、電腦使用/瀏覽器自動化、複雜協調 | token 效率、非同步平行、除錯/審查、零設定沙箱 |
| 相對弱項 | 用量額度消耗快（Opus 比 Sonnet 快 5-10x） | 焦點紀律鬆（會改它認為該改的鄰近檔，diff 龐大） |

盲測資料點：一次社群盲測中 Claude Code 的輸出在 36 次對決裡被評為較乾淨的比例高於 Codex；同一個 Express.js 重構任務，Codex 花費遠低於 Claude Code。決策原則：**任務涉及大量連續工具呼叫、且你能用驗證（測試/type check/review）包住迴圈 → 用 Codex；第一次就要對的高風險編輯 → 用 Claude Code。** 多數團隊的務實答案是「兩者都用，各在不同 surface」。也有人跑雙工具互為 MCP（Claude 統籌、Codex 編碼，或 Codex 審查 Claude 的產出）。

### 2025 下半年到 2026 年重要更新

- **模型迭代快速。** Anthropic：Opus 4.5（effort 參數、plan mode 升級）→ 4.6 → 4.7（Rakuten-SWE-Bench 解決 3x 於 4.6 的生產任務）→ 4.8（dynamic workflows 處理超大規模問題、fast mode 2.5x 速度且便宜 3 倍）；Sonnet 5、Fable 5（2026-06-09 GA）。OpenAI：GPT-5.2-Codex（Dec 2025，引入 context compaction）→ GPT-5.3-Codex（2026-02-05，SWE-Bench Pro 與 Terminal-Bench 新高、25% 更快、首個被列為 Preparedness「High」cyber 能力的模型）→ GPT-5.4 → GPT-5.5（2026-04-23，agentic-first 重訓）。注意 GPT-5.3-Codex 與 GPT-5.2 在 ChatGPT 登入下已被標記 deprecated。
- **Codex app（桌面）** 2026-02 macOS、2026-03-04 Windows 上市，主打平行管理多 agent、worktree、cloud 環境；GPT-5.2-Codex 上市後 Codex 用量翻倍、單月逾百萬開發者使用（GPT-5.5 launch 時約 400 萬週活）。Codex Remote 2026-06 GA（手機控本機）。
- **Claude Code 使用實況（Anthropic 400K session 研究，2025-10 至 2026-04）。** 除錯 session 佔比從 33% 降到 19%，用途轉向端到端 agentic（部署、跑碼、資料分析、寫非程式文件）；典型任務價值 7 個月上升約 27%。專家 session 每個 prompt 觸發 12 個動作、3,200 字輸出（新手僅 5 動作、600 字）；嚴格標準下成功率新手約 15%、中階以上 28-33%。結論：**駕馭 agent 的能力來自「領域掌握度」而非「會不會寫程式」。** Claude Code 使用者平均每週用 20 小時；有 agent 活動的 GitHub 專案自 2025 年底翻倍。
- **一個警示案例。** Anthropic 2026-04-23 postmortem：3/26 上線的「清除閒置 session 舊 thinking」變更有 bug，導致每輪都清而非只清一次，讓 Claude「健忘、重複、亂選工具」、用量額度異常消耗快，4/10 才修復。教訓：連 Anthropic 自己的 context 管理都會出微妙 bug——你的 harness 要有能重現與回歸測試的能力。

## Recommendations

**第 0 階段（第 1 週，個人）：建立 Prompt/Context 基礎。**
1. 每個 repo 寫一份 <150 行的 CLAUDE.md / AGENTS.md（技術棧+版本、專案結構、常用指令、要避免的模式、驗證指令）；能被 linter 處理的別寫。
2. 養成 plan mode 先行、觸及 4+ 檔案先寫 spec 的習慣；每個任務結尾要求可驗證標準。
3. 裝 1-2 個高價值 MCP（Context7 + GitHub），開 tool search。

**第 1 階段（第 2-4 週，團隊）：把規則變成強制閘門。**
4. 在 `.claude/settings.json` 加 hooks：PreToolUse 擋危險指令/保護 secrets、PostToolUse 自動 lint/format、Stop 跑測試不過就擋。Codex 端用 `execpolicy` rules + `workspace-write` sandbox。
5. 導入 Explore→Plan→Execute 三階段 subagent 管線；用便宜模型跑 subagent。
6. 平行開發統一用 git worktree（每人先控 2-3 個，穩定後到 4-8 個）。

**第 2 階段（第 2-3 月）：建 Harness 三支柱。**
7. **隔離環境**：為最痛的外部依賴（OBO/Graph API/SSO）建高擬真 mock 服務層；對最常見的生產 bug 類型導入 Record & Replay。
8. **Eval harness**：先建 20-50 筆 golden dataset（從真實生產 trace 標記而來），寫 `run_evals.py`，接進 CI，PR 時對 regression dataset 跑 LLM-as-Judge + 確定性斷言，失敗擋 merge。
9. **資料飛輪**：用 hooks/`--json` 把每次執行的時間、token、成敗、trace 寫進 Supabase/PostgreSQL；每週自動萃取最佳執行升級成新 benchmark。

**改變建議的門檻（benchmarks / thresholds）：**
- 若 context 使用率常態 >40% 或出現「健忘/重複」→ 立即導入 intentional compaction 與 subagent 隔離。
- 若 CI 的 eval 通過率在改 prompt/RAG 後掉超過某基準（例如相關性 <0.8、幻覺率 >5%）→ 擋 merge 並回滾。
- 若單一開發者穩定跑 >8 個並行 worktree 卻卡在 review → 瓶頸是人不是工具，該加審查人力或提高自動 review（用另一 agent 當 reviewer）。
- 若某任務類型「第一次就要對」的成本很高 → 從 Codex 切到 Claude Code（或反之，若是大量可驗證的平行 grind）。

## Caveats

- **模型與功能迭代極快，具體數字會過時。** 本報告採 2026 年 7 月可得的最新資料；模型版本（Opus 4.8 / GPT-5.5 等）、context window、價格、hook 事件數幾乎每季變動，採用前請對照官方文件當下值。
- **部分數據為廠商自報或社群測試。** SWE-bench 等 benchmark 有污染疑慮（OpenAI 自己在 2026 初建議改用 SWE-bench Pro），廠商 launch 貼文屬行銷語境；盲測 win-rate、成本對比等社群數字受 scaffold 差異影響，小差距視為平手。
- **參考影片的整合程度不一。** 使用者提供的 7 支影片中，僅 `b_9D7T0n4RA`（Dexter Horthy《Advanced Context Engineering for Agents》，YC）能高信心確認並詳細摘要，其內容已整合進 Context Engineering 章節。其餘幾支經查為 vizplainer 頻道的中文 AI agent 系列影片（標題可確認但缺可驗證的技術級摘要），另有數支因 YouTube rate-limit 無法識別；因此本報告以研究搜集到的最新一手/二手資料為主，影片僅作概念參考，避免過度宣稱其內容。
- **Harness 三支柱是投資，不是免費。** Record & Replay 的 PII redaction、mock 保真度維護、eval dataset 的人工升級都需要持續投入；建議先在「最痛的一個」依賴或 bug 類型上驗證 ROI，再擴大。
- **安全邊界不等於安全。** OpenAI 自己說 sandbox + approval 是縱深防禦、不是完整邊界；一旦開 full-access 或網路，防護即按設計移除。仍需最小權限、依賴掃描、人類 review 與獨立驗證（曾有仿冒 Codex 的惡意 npm 套件竊取 `~/.codex/auth.json`）。