# Multi-Agent Starter Kit (v4.0)

讓 **Claude Code + Superpowers + Codex Plugin** 乾淨分工地一起工作的起手包。
你只負責描述任務、approve plan；AI 之間自己協作——你不再當人肉訊息路由器。

---

## 這是什麼（30 秒）

```
你 ─── prompt ───▶ Main Claude (orchestrator)
                       │
       ┌───────────────┼───────────────┐
       ▼               ▼               ▼
 research-scout    Superpowers      Codex Plugin
 (Claude 子代理研究)  (規劃 + 實作)     (跨模型審查)
```

三個角色各做最擅長的事，Main Claude 居中編排：

- **research-scout** — 研究：Claude 原生子代理（WebSearch/WebFetch），蒐集網路資料、整合外部資訊。不寫 code、不 review。
- **Superpowers** — 規劃 + 實作：brainstorm / 寫 plan / 執行 plan。
- **Codex Plugin** — 審查：用「不同的模型」來挑錯。

核心信念只有一句：**審查的人必須跟寫的人是不同模型。** 這條 isolation 原則是整個 kit 的承重牆。設計脈絡見 `ARCHITECTURE.md`。

---

## 先建立一個心智模型：kit 是「工具」，不是「專案模板」

> **你 clone 這個 kit 一次，它就留在原地當工具。**
> 每開一個專案，你用 kit 的 `init.sh` 把「安裝層」吐進去——不是把整個 kit 複製過去。

「安裝層」現在長這樣，也是你專案裡會出現的 kit 產物：

| 檔案 | 是什麼 | 你要做的事 |
|------|--------|-----------|
| `CLAUDE.md` | 給 AI 的專案規則 | **要填**（goal / stack / constraints） |
| `README.md` | 給人看的專案速查 | AI 幫你填好佔位符（30 秒重啟、環境變數、部署…） |
| `.gitignore` | 標準忽略規則 | 不用管 |
| `docs/specs/` | 放功能藍圖 / spec 的地方 | 有 spec-driven 開發時放進去，沒有就留空 |
| `.claude/` | 跑這套流程的基礎建設（rules / hooks / scripts / agents / skills / docs、`kit-version`） | **別碰**（要客製改 kit repo，再 `--update` 鋪回；v4.0 起 hook 會物理擋下對這些檔的編輯） |
| `.claude/protected-paths` | 專案禁區清單（一行一個 glob），PreToolUse hook 據此硬擋編輯 | **要填**——CLAUDE.md constraints 裡每條「路徑型」禁區同步加進來 |
| `mise.toml` | 工具版本鎖定 | 只有這台機器裝了 mise 才會出現；沒裝的機器不會生成、也不會提它 |

kit 自己的文件（這份 README、`ARCHITECTURE.md`）**永遠留在 kit repo**，不會被複製進你的專案——就像你的 app 不需要 React 的 `CONTRIBUTING.md`。這就是為什麼你以後打開專案不會再被一堆文件搞混「哪些能改」。

---

## 兩種 profile：full 與 solo

| Profile | 研究 | 規劃 + 實作 | 審查（isolation 保證） |
|---------|------|------------|----------------------|
| `full`（預設） | research-scout | Superpowers | **Codex Plugin** — 不同模型，真正的隔離 |
| `solo` | research-scout（同 full） | Superpowers | **fresh-context Claude 自審** — 只有狀態/時間隔離，非模型隔離 |

用環境變數 `KIT_PROFILE` 切換，每台機器設一次：

- 日常在家：`full`。
- 公司不能用 codex、或 token 用完了：`export KIT_PROFILE=solo`。

solo 不是「壞掉的 full」，是個誠實的降級檔位：保留 superpowers 的完整節奏，只是審查改由一個乾淨 context 的 Claude 子代理做，AI 會主動告訴你「跨模型隔離已關閉」。

---

## 安裝（每台機器一次）

```bash
# 1. 裝工具
#    Claude Code（唯一硬需求）— https://docs.claude.com/en/docs/claude-code/getting-started
#    以下只有 full profile 需要：
npm i -g @openai/codex && codex login

# 2. clone kit（從此留著，日後 git pull 就能更新）
git clone <kit-repo-url> ~/.multi-agent-kit

# 3. 設環境變數，加進 ~/.bashrc 或 ~/.zshrc 讓它持久
export KIT_PROFILE=full
```

第一次進 claude 時，再裝一次 codex plugin（**整台機器只做這一次**，之後所有專案共用）：

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

---

## 開一個專案

### 新專案

```bash
~/.multi-agent-kit/init.sh ~/projects/my-thing
cd ~/projects/my-thing && claude
```

`init.sh` 看目錄是不是空的來自動判斷新/既有專案（**`--existing` flag 已移除**，不用也不能再指定），一次做完：只複製安裝層、`git init` + 初始 commit、跑環境檢查（每個缺項附修法）、在結尾印出對應的 bootstrap prompt。

進到 claude 後，把 `init.sh` 結尾印出的那句貼上去，讓 AI 幫你把 `CLAUDE.md` 和 `README.md` 的佔位符填好（新專案印出的長這樣）：

```
這個專案是 [一句話],stack 用 [語言/框架]。
請填好 CLAUDE.md 的 goal / stack / file layout(constraints 留空)和 README.md 的佔位符。
```

### 既有專案

```bash
~/.multi-agent-kit/init.sh ~/code/legacy-app
cd ~/code/legacy-app && claude
```

同一個指令、同一份安裝層——`init.sh` 偵測到目錄非空就自動切成既有專案模式，行為**非破壞性**：絕不覆蓋你既有的 `CLAUDE.md` 或 `.claude/` 檔（已有 CLAUDE.md 時，範本另存成 `CLAUDE.md.from-kit` 讓你手動挑要併入的專案內容；workflow rules 已經是獨立的 `.claude/rules/kit-workflow.md`，no-clobber 複製時會直接鋪進你的專案，不用再從 `CLAUDE.md.from-kit` 裡手動搬）。

既有專案有一條黃金法則：**先讓 AI 學會這個專案，再讓它動手。** AI 不懂你的歷史與不成文慣例，貿然亂改會出事。所以第一句不是叫它寫 code，是叫它做 onboarding——這正是 `init.sh` 在既有專案模式下結尾印出的那句：

```
請先探索整個 repo,把架構、慣例、以及「不該碰的區域」寫進 CLAUDE.md,並填 README.md 的佔位符;
若架構值得記錄,建 docs/ARCHITECTURE.md(大綱:分層、data flow、要改 X 先看 Y、歷史遺留)。
先不要改任何其他檔案。
```

接著三個動作別省：

1. **自己 review 它寫的 constraints。** AI 的理解一定有錯——對的留著、誤解的修正、它不知道的歷史你補上。`Project-specific constraints` 越具體越好（「`src/legacy/payment/` 無文件、極脆弱，任何改動需手動確認」遠勝「不要弄壞東西」）。
2. **頭幾個任務挑低風險的**：補測試、改 error message、加 internal endpoint。**不要**第一棒就丟 auth / payment / schema migration。
3. **信任建立後再放寬。** 對 legacy code 可先把 `CLAUDE.md` 的 STOP 閾值調低（例如改動超過 30 行就停下問你），跑順了再放鬆。

---

## 更新既有專案的 kit

kit repo 更新後（`git -C ~/.multi-agent-kit pull`），已經跑過 `init.sh` 的專案不會自動跟上——要手動拉一次：

```bash
~/.multi-agent-kit/init.sh <dir> --update   # 覆蓋 kit-owned 檔、印遷移/孤兒提示
~/.multi-agent-kit/init.sh <dir>            # （選擇性）no-clobber 補鋪新模板
```

所有權規則一句話：**`.claude/` 的 kit 檔不可在專案內改，要客製改 kit repo 再 `--update` 鋪回。**

---

## 日常使用

開工後你幾乎只做一件事：**approve plan**，其餘坐著看。

要更精準地駕馭 AI，其實就是下面這個小文法——這就是全部，沒有更多要背的：

- **一句話描述任務**（大小由系統自己判，多數時候不用你指定）。
- 想覆寫判斷時，**接一個修飾語**：`直接做` / `走完整流程` / `這會動到 X，請 review` / `請質疑這個設計`。
- 中途想插話：`暫停` / `rollback 剛才的改動` / `/btw 小問題`。

---

## 操作參考

### Codex 指令（full profile）

```
/codex:review [--base main] [--background]   審查改動（--base 從某 branch 起算；--background 大改動）
/codex:adversarial-review                    不只挑 bug，挑戰設計前提（高 stakes 用）
/codex:rescue [任務]                         整件事丟給 codex（A/B 比較、卡住時）
/codex:status | /codex:result <id> | /codex:cancel <id>   背景任務管理
```

`/codex:rescue` 出來的 code **不要再用 codex review**——同模型寫 + 審 = 零 isolation；交給 main Claude 或人工。

### Hooks（`.claude/settings.json`，v3.5 起預設開啟）

- `session-start.sh`：session 開始時廣播 kit context（active profile、codex 可用性、這個 session 的 review marker 路徑），記下 review gate 用的 git baseline；v4.0 起在 compact/resume 後注入 RE-ANCHOR（強制重讀 constraints 與 plan，防記憶解體後亂改）。
- `classify-task.sh`：只認你的明確修飾語（`直接做`→跳過流程、`完整流程`→全套），其他一律交給模型自判（v3.3 起移除關鍵字啟發式）。
- `verify-final-review.sh`：結束前若有未審的業務邏輯就 block——v3.3 起連「已經 commit 的變更」也看得到（靠 session-start 記的 baseline），審過的內容則用 content hash 記住、不會重複煩你。v4.0 起 marker 必須含 `reviewed-by=` 證據行（由 `/kit-review` 寫入），空 touch 不再過關。
- `protect-paths.sh`（v4.0）：兩檔防護——`.claude/protected-paths` 清單路徑（你宣告的專案禁區）**硬擋**；kit-owned 檔案（rules/hooks/settings.json 等）**轉請示**（你在場時彈窗放行你確實要求過的修改，例如加權限；無人值守時等同封鎖）。整個 session 放行：啟動前 `export KIT_PROTECT=off`（模型自己 export 沒用——hook 吃的是 claude 啟動時的環境）。
- `tool-breaker.sh`（v4.0）：連續 3 次完全相同的工具調用會被物理擋下（重試螺旋熔斷）、工具連續失敗會收到警示；所有調用寫進 `/tmp/claude-kit-toollog-<session_id>.jsonl` 供事後審計。停用：啟動前 `export KIT_BREAKER=off`。
- **預設開啟**（v3.5 起）。要停用全部：把 settings.json 裡的 `hooks` 改名（例如 `_hooks_disabled`），重啟 session。**SessionStart 跟 Stop 要一起開/關**（Stop gate 靠 SessionStart 記的 baseline）。既有專案 `--update` 不會覆蓋你的 settings.json，想跟上就照它印出的 diff 手動合併。
- **審完怎麼過 gate**：用 `/kit-review`——它會依 profile 跑對的 review 並寫入證據 marker；要跳過就 `/kit-skip-review`。你本人的手動逃生口（路徑在 session 開頭的 KIT_CONTEXT 裡；空 touch 無效，gate 只認 `user-approved` 開頭的內容——這行格式故意只寫在這份 kit 文件裡，部署出去的專案看不到）：`echo "user-approved date=$(date +%F) quote=\"manual skip\"" > /tmp/claude-skip-review-<session_id>`。
- ⚠️ **不要**啟用 `/codex:setup --enable-review-gate`：它在每次 stop 自動 review，會造成 Claude/Codex loop 燒 quota。我們的 Stop hook 做同樣的事但更可控。

### 權限提示

v3.3 起 settings.json 模板直接內建一組 read-only 的 `permissions.allow` 基線（`git status/diff/log/show`、`ls`、`timeout`），裝完就少掉大部分權限彈窗；要收緊或放寬直接編輯專案裡的 settings.json（它是你的檔）。路徑含 session UUID 的提示照舊選 `Yes` 即可。

---

## Debug 速查

- **「我沒有 codex 這個 tool」** → plugin 沒裝：重跑上面那四個 `/plugin … /codex:setup` 指令。
- **`/codex:review` 回 usage / rate limit** → quota 用光：等冷卻（通常幾小時）、升級訂閱，或暫切 `export KIT_PROFILE=solo`。
- **`claude` 在 Git Bash 立即退出** → 非 git 目錄誤入 print 模式：`git init`（`init.sh` 已代勞），或從 PowerShell 啟動。
- **找不到 superpowers 寫的 plan** → 問「plan 存在哪？」；不同版本可能在 `plans/`、`docs/plans/`、`.claude/plans/`。
- **Hook 沒生效 / 誤觸發** → `cat .claude/settings.json | grep -A20 '"hooks"'` 確認啟用；`echo '{"prompt":"add a button"}' | .claude/hooks/classify-task.sh` 測分類；要客製 hook 改 kit repo 的檔，再 `--update` 鋪回專案。

---

## 專案裡哪些能改、哪些別碰

| 路徑 | 角色 | 你要做的 |
|------|------|---------|
| `CLAUDE.md` | 專案設定 | 填 / 維護 |
| `README.md` | 給人看的專案速查 | 填 / 維護 |
| `.claude/settings.json` | 設定 | 可調（hooks / 權限）——v4.0 起模型動它要先向你請示（protect-paths 彈窗），無人值守時動不了 |
| `.claude/protected-paths` | 專案禁區清單（給 protect-paths hook 執法） | 填 / 維護；模型只能加嚴、不能放寬 |
| `docs/LESSONS.md` | 踩坑教訓（Context/Error/Solution/Rule 四行格式） | 模型自行累積，超過 300 行會自我精簡（規則見 kit-evolution） |
| `.claude/rules/`（workflow / delegation / evolution） | kit-owned 規則，每 session 自動載入 | 別碰——`--update` 會直接覆蓋；要客製改 kit repo 再鋪回 |
| `.claude/hooks/`、`scripts/`、`agents/`、`skills/`、`docs/` | infra，同樣 kit-owned | 別碰（v4.0 起 hook 物理執法；要改流程就去改 kit repo，`--update` 鋪回） |
| `.claude/kit-version` | kit 版本標記 | kit 自動寫入，別手動編輯 |

---

## 文件地圖

| 檔案 | 給誰看 | 內容 |
|------|--------|------|
| `README.md` | 新人 / 你 | 你正在看的——裝機、開專案、操作、debug（給專案用的範本在 `templates/README.md`，`init.sh` 複製時改名成專案的 `README.md`） |
| `CLAUDE.md` | AI（每個 session） | 專案內容範本：goal / stack / constraints（會進專案；workflow 規則另外放在 `.claude/rules/kit-workflow.md`，同樣會進專案、但 kit-owned） |
| `ARCHITECTURE.md` | 想深入的人 | 為什麼這樣設計、v1→v4.0 的取捨 |
| `docs/harness-diagnosis.md` | 想深入的人 | v4.0 防線的設計依據：三大弱模型失敗場景 → 三個物理痛點 → 阻斷方案，含誠實條款（這套 harness 的能力極限） |
| `docs/handover-from-fable.md` | 未來的模型與你 | 一次性高階模型 session 留下的交接信：三件關鍵事 + 制度腐化路徑與偵測法 |

（`ADOPTION.md` 已併入本檔「既有專案」段、`USAGE.md` 已併入本檔「操作參考 / Debug」段，皆不再單獨維護。）

---

## 版本

- **v4.0（現在）**：弱模型防線——判斷力外化 + 物理熔斷。兩支新 hook（`protect-paths` 禁區硬擋、`tool-breaker` 重試螺旋熔斷 + 埋點日誌）、Stop gate marker 證據化（空 touch 不過關、block 訊息不再印捷徑）、compact/resume RE-ANCHOR、三份新規則（kit-delegation 派工升降級、kit-evolution 自我更新邊界、judgment-matrix 判斷檢核表）、`/kit-dispatch` 派工模板 skill、CLAUDE.md 範本改版（constraints ↔ protected-paths 同步執法）。設計依據：`docs/harness-diagnosis.md`。
- **v3.5**：workflow sizing 防偏壓——kit-workflow.md 給小任務可操作判準（≤2 檔、無新依賴、不碰 auth/payment/schema/constraints → 直接做），並依 superpowers 自己的優先權規則（專案指示 > skills）明文解除小任務的 brainstorming/TDD 強制觸發、模糊時問一句而非默默走全套；hooks 預設開啟（v3.3 修完 gate 的洞後 opt-in 前提不存在）；清掉 research skill/agent 裡已廢除的 `large_task`/`small_task` 分類標籤。
- **v3.4**：gemini 退役（使用者環境因素，非能力問題）——研究改由 Claude 原生 `research-scout` 子代理（WebSearch/WebFetch）承接、不再限 full profile，profile 從此只決定 reviewer；init.sh 收尾三小項（`--help` 只印檔頭、`--update` 補缺失 settings.json、smoke env 隔離）+ `--update` gemini 遷移提示。
- **v3.3**：harness 閉環——Stop review gate 修好三個洞（marker 無人寫、commit 盲區、rename 解析），SessionStart hook 廣播 profile/marker context + 記 baseline，`/kit-review`、`/kit-skip-review` 修飾語 skills，`solo-reviewer` 正式 agent 檔，classify-task 只留明確覆寫，settings 模板內建 read-only 權限基線。
- **v3.2**：檔案級所有權二分——`CLAUDE.md` 純專案內容、workflow 規則移到 kit-owned 的 `.claude/rules/kit-workflow.md` + `init.sh --update` 讓已鋪過 kit 的專案能回流拿新版 + `templates/`（README / gitignore / mise 範本）+ 那份「怎麼下指令」的一頁速查文件光榮退役（教學任務已完成，殘值併入 `templates/README.md`）。
- **v3.1**：`KIT_PROFILE` profile 切換 + 一鍵 `init.sh` + 一頁「怎麼下指令」速查表 + 砍掉專案污染與冗長文件。
- **v3**：官方 codex-plugin-cc 取代自製 codex/gemini wrapper。
- **v2 / v1**：deprecated（自製 wrapper / PAL MCP）。

今天起手就用 v4.0。
