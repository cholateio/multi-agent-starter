# USAGE.md — 操作手冊

> 這份文件是給你（使用者）看的，不是給 AI 看的。AI 看的是 CLAUDE.md。
> 兩者形成鏡像：CLAUDE.md 規範 AI 如何做事，USAGE.md 規範你如何跟 AI 溝通。

## 目錄

- [零、心智模型](#零心智模型)
- [一、首次使用](#一首次使用)
- [二、六種日常情境的 prompt 範本](#二六種日常情境的-prompt-範本)
- [三、過程中的介入手段](#三過程中的介入手段)
- [四、跟 superpowers / 第三方 skill 共存](#四跟-superpowers--第三方-skill-共存)
- [五、Hooks 啟用與管理](#五hooks-啟用與管理)
- [六、Anti-patterns（不該這樣下指令）](#六anti-patterns不該這樣下指令)
- [七、Debug 與環境問題速查](#七debug-與環境問題速查)

---

## 零、心智模型

整個 multi-agent 系統一張圖：

```
你 ─── prompt ───▶ Main Claude (orchestrator)
                       │
       ┌───────────────┼───────────────┐
       ▼               ▼               ▼
   Gemini          Superpowers      Codex Plugin
  (research)       (plan+execute)    (review)
       │               │               │
   蒐集資源         規劃+實作         跨模型審查
```

三個外部 AI 各司其職：

- **Gemini** 只做研究（不寫 code、不 review）
- **Superpowers** 規劃和實作的主力（有自己的 brainstorm/plan/execute 流程）
- **Codex Plugin** 只做 review（不寫 code、不規劃）

**你只在一個地方介入：approve plan**。其他時候坐著看就好。

---

## 一、首次使用

### 1.1 你是新專案還是既有專案？

兩條路線分流：

- **新專案**：跳到 1.2 「新專案路線」
- **既有專案**：先看 `ADOPTION.md`，做完 onboarding 後回到這裡 1.3

### 1.2 新專案路線

```bash
# Step 1：clone starter kit
cp -r /path/to/multi-agent-starter-v3 ~/Desktop/my-new-project
cd ~/Desktop/my-new-project

# Step 2：初始化 git（codex 0.123+ 需要）
git init
git add -A
git commit -m "Initial: multi-agent kit"

# Step 3：設環境變數（一次性）
export GEMINI_API_KEY="AIza..."           # 從 https://aistudio.google.com/apikey 取得
# Windows PowerShell 同時跑：setx GEMINI_API_KEY "AIza..."

# Step 4：跑 setup 檢查
./setup.sh

# Step 5：編輯 CLAUDE.md
# 填上 [PROJECT NAME]、goal、stack、layout
# constraints 段可以先空著（新專案沒包袱）

# Step 6：啟動 claude code
claude
```

進到 claude code 後，**第一次**還要做 codex plugin 安裝（每台機器只要做一次）：

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

`/codex:setup` 會檢查並引導你登入 codex（如果還沒登入）。

### 1.3 既有專案路線

簡述（完整流程在 ADOPTION.md）：

```bash
cd ~/path/to/existing-project

# Step 1：複製基礎建設（不動既有 code）
cp -r /path/to/multi-agent-starter-v3/.claude .
cp /path/to/multi-agent-starter-v3/setup.sh .
cp /path/to/multi-agent-starter-v3/USAGE.md .
mkdir -p docs/decisions docs/plans

# Step 2：合併或新增 CLAUDE.md
# 如果你已有 CLAUDE.md：手動 merge multi-agent-starter-v3/CLAUDE.md 的後半段（# Multi-Agent Workflow Rules）
# 如果沒有：直接 cp，然後填上 placeholders

# Step 3：環境檢查
./setup.sh

# Step 4：先 onboarding，再開發（重要！）
claude
# 第一個 prompt：讓 AI 探索並寫 AI_ONBOARDING.md，不准修改任何檔案
# 詳見 ADOPTION.md
```

### 1.4 第一次測試

確認環境 OK 後，下個小 prompt 測試：

```
列出我這個專案的檔案結構，並說一下你看到的架構。
```

預期行為：
- Claude 讀 CLAUDE.md
- Claude 用 ls / Read 工具
- Claude 給你一段架構描述

如果這步走得通，就可以進入第二章開始正式工作。

---

## 二、六種日常情境的 prompt 範本

### A. 加小新功能（< 30 行）

**適用判準**：單一檔案、無新依賴、UI/cosmetic、glue code。

**Prompt 範本**：

```
加一個 P 鍵暫停遊戲。
```

或更明確：

```
加 P 鍵暫停遊戲。直接做，不需要 plan。
```

**預期 Claude 行為**：
- task classifier hook 識別為 `small_task`（如果你啟用 hook）
- Claude 跳過 superpowers 流程
- 直接修檔
- 給你一行摘要：「P 鍵暫停功能加在 index.html 的 keydown handler，總共 8 行」

**你的介入點**：通常 0 次（除非權限提示）。

**約耗時**：1-2 分鐘。

---

### B. 加中型新功能（30-150 行）

**適用判準**：1-2 個檔案、有業務邏輯、可能要重構小段現有 code。

**Prompt 範本**：

```
我想加 difficulty levels（easy/medium/hard），影響 pipe gap 和 speed。
```

**預期 Claude 行為**：
- task classifier 識別為 `medium_task` 或 feature
- Claude 啟動 superpowers writing-plans（可能跳過 brainstorming，因為需求清晰）
- Plan 落地到 `plans/` 或 `docs/plans/`
- Claude 自動跑 `/codex:review` 檢查 plan
- 整合 review feedback，改 plan
- 給你最終 plan，等你 approve
- 你 approve 後實作
- 完成後跑 `/codex:review` 對 final code

**你的介入點**：1-2 次（approve plan、可能權限提示）。

**約耗時**：5-15 分鐘。

---

### C. 加大功能 / 多檔案改動

**適用判準**：跨多個檔案、可能引入新依賴、業務影響大。

**Prompt 範本**：

```
我想加 leaderboard 功能。需要：
- 用 localStorage 持久化分數
- UI 上有 top 10 列表
- 玩家可輸入自己的名字
- 跨 session 維持

請走完整流程。
```

**預期 Claude 行為**：
- task classifier 識別為 `large_task`
- Claude 評估是否觸發 `research-before-planning`
  - 例：localStorage 是常見技術 → 不觸發
  - 例：「我想加 OAuth login 功能」→ 觸發 research scout 蒐集 OAuth 最佳實踐
- 啟動 superpowers brainstorming → writing-plans
- 自動 `/codex:review` plan
- 高 stakes 時自動加 `/codex:adversarial-review`
- 給你最終 plan
- 你 approve
- superpowers executing-plans 開始實作（可能 spawn Claude subagent 並行）
- 重要 phase 完成時自動 `/codex:review`
- 全部完成後最終 `/codex:review`
- 給你三段總結：what was built / what to test manually / known limitations

**你的介入點**：1-3 次（approve plan、研究結果若需要重新方向、權限提示）。

**約耗時**：15-30 分鐘。

---

### D. 修小 bug

**適用判準**：已知症狀、希望快速修。

**Prompt 範本（多數情況）**：

```
按 space 鍵後 bird 不會跳了。請修。
```

**Prompt 範本（你預期 fix 影響核心邏輯）**：

```
按 space 鍵後 bird 不會跳了。請修。這個 fix 可能影響 input handling，請 codex review。
```

**Prompt 範本（你已經知道根因）**：

```
按 space 鍵後 bird 不會跳了。我懷疑是 phase transition 後 event listener 沒重新綁定。請修。
```

**預期 Claude 行為**：
- task classifier 識別為 `bug_fix`
- 跳過所有規劃流程
- 調查 root cause
- 提出修法 + 實作
- 自動檢查 nearby code 有沒有相關 bug
- 如果 fix 動到業務邏輯 → 自動 `/codex:review`
- 如果 fix 是 local（單一函式）→ 直接給總結

**你的介入點**：通常 0-1 次。

**約耗時**：2-5 分鐘。

---

### E. 重構

**適用判準**：要動既有 code 的結構，目標是提升可維護性而非加功能。

**Prompt 範本**：

```
我想重構 game state 管理。目前散在多個變數裡，我想集中成一個 state object。
重構不能破壞現有功能。請走完整流程，包含 adversarial review。
```

**預期 Claude 行為**：
- task classifier 識別為 `large_task_refactor`
- Claude 先檢查現有測試覆蓋
  - 如果沒有測試 → 主動建議「先補測試再重構」
  - 你同意後先寫測試
- superpowers brainstorming（探索重構策略）→ writing-plans
- 自動 `/codex:review` 和 `/codex:adversarial-review`（重構是高風險，雙審查）
- 給你最終 plan
- 你 approve
- 分 phase 重構，每個 phase 完成跑測試 + `/codex:review`
- 全部完成後最終 review

**你的介入點**：2-4 次（approve 補測試、approve plan、可能中途決策）。

**約耗時**：20-40 分鐘。

---

### F. 中途暫停 / 改方向

**情境**：Claude 已經開始實作，但你發現方向不對、或想再思考一下。

**Prompt 範本**：

```
等等，剛剛你提到要用 X 演算法。我想重新討論這個決定，請先停下實作。
```

或更精確：

```
暫停。我發現 [問題]，這會影響 [Y]。我們需要：
（a）回到 plan 階段重新討論這部分
（b）繼續但跳過 [Z]
（c）整個取消
你建議哪個？
```

或者你只是想確認某件事：

```
/btw 我們剛剛為什麼選 [X]？
```

`/btw` 不會中斷實作，是 side question。詳見第三章。

**預期 Claude 行為**：
- 立刻停止實作
- 整理當前進度（已完成什麼、未完成什麼）
- 回應你的問題或選項
- 等你決定下一步

**重要**：Claude 在實作中途收到「暫停」指令時，**不會自動 rollback 已寫的 code**。如果你想 rollback，明確說：「請 rollback 剛才的改動」或用 git。

---

## 三、過程中的介入手段

### 3.1 `/btw` — 不污染主對話的 side question

**何時用**：你想問個小問題，但不想讓問題進入 conversation history、也不想中斷 Claude 正在做的事。

**範例**：

```
/btw 我們的 game state 物件目前有哪幾個 key？
/btw collision detection 用的是什麼演算法？
/btw 為什麼 plan 選 setInterval 而不是 requestAnimationFrame？
```

**限制**：`/btw` **沒有工具存取**，只能從目前的對話 context 回答。如果問題需要讀新檔案、跑命令、search code，要在主對話問。

**特性**：
- 答案以 overlay 形式跳出，按 Esc 關掉
- 主任務繼續跑、不被打斷
- 不進入 conversation history

詳細用法見 Anthropic 官方文件或 USAGE.md 第七章 FAQ。

### 3.2 `/codex:review` — 手動觸發 codex 審查

雖然 CLAUDE.md 規則會讓 Claude 在重要 phase 完成時自動跑，但你也可以**手動**指定要 review 什麼：

```
/codex:review                       # review 當前未 commit 的改動
/codex:review --base main           # review 從 main branch 分支以來的所有改動
/codex:review --background          # 背景跑（大改動時用）
```

什麼時候手動下：
- 你寫了 code 但 Claude 沒主動 review → 你想確認
- 你想對特定 PR 做 review（用 `--base`）
- 改動很大、不想阻塞 → 加 `--background`

### 3.3 `/codex:adversarial-review` — 質疑前提的 review

這跟 `/codex:review` 不同。它不只挑 bug，還會**挑戰你的設計選擇**。

**何時用**：
- auth / payment / data migration 等高 stakes 區域
- 你自己對某個設計選擇有疑慮
- 想壓力測試一個方案

**範例**：

```
/codex:adversarial-review --base main
/codex:adversarial-review challenge whether this caching strategy is right
/codex:adversarial-review look for race conditions in the new queue logic
```

**警告**：adversarial review 會質疑「你真的需要這個功能嗎？」之類的根本問題。心理上要準備好被打臉。

### 3.4 `/codex:rescue` — 委派完整任務給 codex

當你想讓 codex 從頭做一件事（不只是 review）：

```
/codex:rescue 重寫 collision detection 用 SAT 演算法
/codex:rescue --background 把 src/auth.ts 改用 jose library
```

**何時用**：
- 想 A/B 比較兩個模型的實作方式
- Claude 卡住或 loop
- 任務太大、想丟給 codex 在背景跑（用 `--background`）

**注意**：rescue 出來的結果**不該再用 codex review**——同一個模型寫 + review 沒有 isolation 價值。

### 3.5 `/codex:status` / `/codex:result` / `/codex:cancel`

背景任務管理：

```
/codex:status               # 看背景中的 codex 任務狀態
/codex:result <task-id>     # 取得完成任務的結果
/codex:cancel <task-id>     # 取消還在跑的任務
```

### 3.6 權限提示處理

實作中你會看到類似的提示：

```
Bash command
   timeout 60 tail -f "C:\...\tasks\xxx.output"
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again
   3. No
```

**永遠選 1 (Yes)**。

理由：
- 這類路徑包含 session UUID，每次都不同 → 「Don't ask again」對下次無效
- 主 Claude 想監看 subagent output，是無害的讀取操作

如果你受不了一直被問，可以在 `.claude/settings.json` 加 allow patterns：

```json
"permissions": {
  "allow": [
    "Bash(timeout *)",
    "Bash(./.claude/scripts/gemini_exec.sh *)",
    "Bash(git status *)",
    "Bash(git diff *)"
  ]
}
```

---

## 四、跟 superpowers / 第三方 skill 共存

### 4.1 為什麼選擇 superpowers 主導 plan

Superpowers 的 brainstorming + writing-plans + executing-plans 是個成熟的規劃流程，比 v2 自己寫的 `plan-with-review` skill 更完整。所以 v3 直接讓 superpowers 做這件事。

我們的角色是**驗證層**：在 superpowers 寫完 plan 之後 → 跑 `/codex:review`；在實作完成後 → 跑 `/codex:review`。

### 4.2 觸發優先順序

| 任務類型 | 觸發順序 |
|---------|---------|
| 大 feature 含新技術 | research-before-planning → superpowers:brainstorming → superpowers:writing-plans → /codex:review on plan → user approve → superpowers:executing-plans → /codex:review on phases → /codex:review final |
| 大 feature 已知技術 | superpowers:brainstorming → superpowers:writing-plans → /codex:review on plan → user approve → superpowers:executing-plans → ... |
| 中 feature | superpowers:writing-plans → /codex:review → user approve → 實作 → /codex:review final |
| 小任務 / bug fix | 直接做，可能跑 /codex:review final |
| 純 UI tweak | 直接做，不 review |

CLAUDE.md 的「Task-size classification」段落定義了 Claude 怎麼自動判斷。如果判斷錯了，你可以用 prompt 中的關鍵字（「直接做」、「完整流程」）override。

### 4.3 frontend-design 等領域 skill

如果你裝了 `frontend-design` 之類的領域 skill，它們**跟我們的流程不衝突**：

- frontend-design 教 Claude 「怎麼寫好前端」（design tokens、component patterns）
- 我們的流程教 Claude 「什麼時候 review、找誰 review」

兩者在不同層次：領域 skill 影響**內容**，我們的流程影響**節奏**。

實際運作：
1. 你說「做一個 dashboard 的 button component」
2. classifier 識別為 small_task（單一 component）
3. frontend-design skill 觸發 → Claude 用它的 design tokens 寫 component
4. 因為是 small_task，不跑 /codex:review
5. 完成

如果是 medium_task（整個 dashboard 的多個 components）：
1. classifier 識別為 feature
2. superpowers writing-plans 觸發
3. plan 內容裡會引用 frontend-design 的 patterns
4. /codex:review 檢查 plan
5. ...

---

## 五、Hooks 啟用與管理

### 5.1 預設狀態

`.claude/settings.json` 裡 hooks 是**預設關閉**的（block 名稱叫 `_hooksDisabledByDefault_uncomment_to_enable`）。

理由：先讓你熟悉純 CLAUDE.md 模式跑幾次，再考慮加 hooks。Hooks 是強紀律工具，不該預設啟用。

### 5.2 兩個可選 hooks

#### Hook A：classify-task.sh（UserPromptSubmit）

**做什麼**：每次你下 prompt 時，自動分類這個任務的大小（small / medium / large / bug_fix / refactor），並把分類結果 inject 進 context 給 Claude。

**啟用後的差異**：
- Claude 較少誤判任務大小（小任務不會走完整流程）
- 你少打「請直接做」這類覆寫指令
- prompt 處理多 100ms 左右（hook 執行時間）

**何時不要啟用**：
- 你的 prompt 風格獨特、hook 的 regex 認不得
- 你喜歡每次明確指示 Claude 要走什麼流程

#### Hook B：verify-final-review.sh（Stop）

**做什麼**：Claude 準備結束 turn 時，檢查這次 session 有沒有改業務邏輯檔案。如果改了但還沒跑過 `/codex:review`，**block 結束**並要求 Claude 先跑 review。

**啟用後的差異**：
- 強保證業務邏輯一定有跨模型 review
- 偶爾會「假警報」（你只是改了註解、hook 沒分辨出來）

**何時不要啟用**：
- 你想完全靠 CLAUDE.md 規則（信任 Claude 自覺）
- 你有時候想在 review 前先 commit 半成品到 feature branch

### 5.3 啟用方法

編輯 `.claude/settings.json`：

```json
// 把這個區塊：
"_hooksDisabledByDefault_uncomment_to_enable": {
  "hooks": { ... }
}

// 改名成：
"hooks": { ... }
```

然後重啟 claude code session。

### 5.4 旁路 final review hook

有時你真的想跳過 final review（例如改了業務邏輯但你已經知道是對的）：

```bash
# 在新的 terminal：
touch /tmp/claude-skip-review-<session_id>
```

session_id 可以從 hook 的 block message 裡看到。或者更簡單：

```
跟 Claude 說：「這次跳過 codex review，我已經 review 過了。」
```

Claude 會把這個訊息傳達給 hook（理論上 — 實際上 hook 還是會 block，需要你手動 touch flag file）。

---

## 六、Anti-patterns（不該這樣下指令）

### 6.1 「一句話想做大功能」

❌ 不好：
```
做一個完整的 e-commerce 後台。
```

✅ 好：
```
我想做一個 e-commerce 後台。先 brainstorm 跟我討論主要功能模組，
不要直接開始 plan。
```

理由：太大的需求需要先共同收斂 scope。直接讓 Claude 開幹會走偏。

### 6.2 「不信任 superpowers 的 plan，每個都想自己審」

❌ 不好：每次 plan 出來你都從頭挑戰它。

✅ 好：信任 superpowers 寫的 plan，加上 `/codex:review` 已經幫你過一次。你只需要看 review notes、決定要不要 approve。

理由：你自己再審一次違背了「人類路由器解放」的目標。如果不信任 superpowers，那就 disable 它。

### 6.3 「對小任務強制走完整流程」

❌ 不好：
```
加一個 dark mode 切換按鈕。請走完整流程，包括 brainstorming 和 plan review。
```

✅ 好：
```
加一個 dark mode 切換按鈕。
```

理由：小任務的完整流程開銷比實作本身還大。讓 Claude 自己判斷，或加「直接做」明確 opt-out。

### 6.4 「啟用 codex review gate」

❌ 不好：

```
/codex:setup --enable-review-gate
```

✅ 好：不要啟用這個 flag。

理由：review-gate 會在每次 Claude stop 時自動跑 review，造成 Claude/Codex loop，**快速消耗 quota**。除非你有專門的監控人員，否則不要開。

我們用 `Stop` hook 做類似但更可控的事。

### 6.5 「同一份 code 讓 codex 寫 + codex review」

❌ 不好：
```
用 /codex:rescue 寫 X 演算法，再用 /codex:review 檢查。
```

✅ 好：
```
用 /codex:rescue 寫 X 演算法。等 main Claude 整合後跑 /codex:review。
```

或者：
```
用 /codex:rescue 寫 X 演算法。等回來後我們手動 review。
```

理由：同一個模型寫 + review 沒有 isolation 價值。如果用 codex 寫，review 應該由 main Claude 自己做（或人工）。

---

## 七、Debug 與環境問題速查

### 7.1 Codex plugin 沒裝好

**症狀**：你下指令說「請 codex review」但 Claude 說「我沒有這個 tool」。

**修法**：

```
進到 claude code 後，依序：
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

`/codex:setup` 會檢查 codex CLI 是否裝好、是否登入。

### 7.2 Codex quota 用光

**症狀**：`/codex:review` 回 "usage limit exceeded" 或 "rate limit"。

**修法**：

- 等冷卻期過（通常幾小時）
- 或升級 ChatGPT 訂閱
- 暫時可以告訴 Claude「跳過 codex review，自己 review」（接受降級）

CLAUDE.md 的規則會讓 Claude 不靜默降級——它會問你怎麼辦。

### 7.3 Gemini scout 沒回應

**症狀**：研究階段卡住或回 "Input must be provided"。

**修法**：

```bash
# 檢查 API key
echo "$GEMINI_API_KEY"   # 應該印出 AIza...

# 沒設？
export GEMINI_API_KEY="AIza..."

# Windows 也設一份系統級
setx GEMINI_API_KEY "AIza..."
# 然後完全關閉所有 terminal，重開

# 手動測試
./.claude/scripts/gemini_exec.sh "say hello"
```

### 7.4 Claude code 在 Git Bash 啟動失敗

**症狀**：執行 `claude` 出現 "Input must be provided" 立即退出。

**原因**：Windows + Git Bash + 非 git 目錄會誤判進 print 模式。

**修法**：

```bash
git init       # 初始化 git
# 或從 PowerShell 啟動 claude code
```

### 7.5 權限提示一直跳

**症狀**：每幾分鐘就跳 Bash 命令權限。

**修法**：在 `.claude/settings.json` 加 allow patterns（見 3.6 節）。

### 7.6 Superpowers 寫的 plan 找不到

**症狀**：Claude 說 plan 寫好了，但你不知道在哪個檔案。

**修法**：

```
/btw plan 寫在哪個檔案？
```

或在主對話：

```
plan 存在哪？
```

Superpowers 不同版本可能寫到 `plans/`、`docs/plans/`、`.claude/plans/`。

### 7.7 Hook 行為怪異

**症狀**：感覺 hook 沒生效或誤觸發。

**修法**：

```bash
# 檢查 hook 是否啟用
cat .claude/settings.json | grep -A 20 '"hooks"'

# 手動測試 classify-task hook
echo '{"prompt":"add a button"}' | .claude/hooks/classify-task.sh

# 應該看到 JSON 輸出包含 "TASK_CLASSIFICATION"

# 看 verify-final-review hook 邏輯
cat .claude/hooks/verify-final-review.sh
```

如果 hook 邏輯不適合你的工作流，**直接編輯 .sh 檔案**——這就是 hooks 的好處，是純 bash。

---

## 結語

這份操作手冊跟 CLAUDE.md 是配對的：CLAUDE.md 寫給 AI、USAGE.md 寫給你。

當你發現某個情境下 AI 行為不如預期：
- 如果是 AI 的問題 → 改 CLAUDE.md
- 如果是你的 prompt 不夠精準 → 改 USAGE.md，補一個範本
- 如果是流程結構需要強化 → 加 hook

每跑 5-10 個專案，回來看一次 USAGE.md，補一些新發現的 anti-pattern 或 prompt 範本。**痛點驅動文件**，這是這份 kit 從一開始就守的原則。
