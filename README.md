# Multi-Agent Starter Kit (v3.1)

讓 **Claude Code + Superpowers + Codex Plugin + Gemini CLI** 乾淨分工地一起工作的起手包。
你只負責描述任務、approve plan；AI 之間自己協作——你不再當人肉訊息路由器。

---

## 這是什麼（30 秒）

```
你 ─── prompt ───▶ Main Claude (orchestrator)
                       │
       ┌───────────────┼───────────────┐
       ▼               ▼               ▼
   Gemini          Superpowers      Codex Plugin
  (研究)           (規劃 + 實作)     (跨模型審查)
```

三個外部 AI 各做最擅長的事，Main Claude 居中編排：

- **Gemini** — 研究：蒐集網路資料、整合外部資訊。不寫 code、不 review。
- **Superpowers** — 規劃 + 實作：brainstorm / 寫 plan / 執行 plan。
- **Codex Plugin** — 審查：用「不同的模型」來挑錯。

核心信念只有一句：**審查的人必須跟寫的人是不同模型。** 這條 isolation 原則是整個 kit 的承重牆。設計脈絡見 `ARCHITECTURE.md`。

---

## 先建立一個心智模型：kit 是「工具」，不是「專案模板」

> **你 clone 這個 kit 一次，它就留在原地當工具。**
> 每開一個專案，你用 kit 的 `init.sh` 把「安裝層」吐進去——不是把整個 kit 複製過去。

「安裝層」只有三樣東西，也是你專案裡唯一會出現的 kit 檔案：

| 檔案 | 是什麼 | 你要做的事 |
|------|--------|-----------|
| `CLAUDE.md` | 給 AI 的專案規則 | **要填**（goal / stack / constraints） |
| `PROMPTING.md` | 給你的一頁速查 | 隨用隨補 |
| `.claude/` | 跑這套流程的基礎建設 | **別碰**（hooks / scripts / 設定） |

kit 自己的文件（這份 README、`ARCHITECTURE.md`）**永遠留在 kit repo**，不會被複製進你的專案——就像你的 app 不需要 React 的 `CONTRIBUTING.md`。這就是為什麼你以後打開專案不會再被一堆文件搞混「哪些能改」。

---

## 兩種 profile：full 與 solo

| Profile | 研究 | 規劃 + 實作 | 審查（isolation 保證） |
|---------|------|------------|----------------------|
| `full`（預設） | Gemini | Superpowers | **Codex Plugin** — 不同模型，真正的隔離 |
| `solo` | 無（自己 search） | Superpowers | **fresh-context Claude 自審** — 只有狀態/時間隔離，非模型隔離 |

用環境變數 `KIT_PROFILE` 切換，每台機器設一次：

- 日常在家：`full`。
- 公司不能用 codex、或 token 用完了：`export KIT_PROFILE=solo`。

solo 不是「壞掉的 full」，是個誠實的降級檔位：保留 superpowers 的完整節奏，只是審查改由一個乾淨 context 的 Claude 子代理做，AI 會主動告訴你「跨模型隔離已關閉」。

---

## 安裝（每台機器一次）

```bash
# 1. 裝工具
#    Claude Code（唯一硬需求）— https://docs.claude.com/en/docs/claude-code/getting-started
#    以下兩個只有 full profile 需要：
npm i -g @openai/codex && codex login
npm i -g @google/gemini-cli

# 2. clone kit（從此留著，日後 git pull 就能更新）
git clone <kit-repo-url> ~/.multi-agent-kit

# 3. 設環境變數，加進 ~/.bashrc 或 ~/.zshrc 讓它持久
export KIT_PROFILE=full
export GEMINI_API_KEY="AIza..."          # full 才需要；Windows 另跑 setx
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

`init.sh` 會一次做完：只複製安裝層、`git init` + 初始 commit、跑環境檢查（每個缺項附修法）、印出你的下一步。

進到 claude 後，貼 `PROMPTING.md` 第 0 段「新專案」那句，讓 AI 幫你把 `CLAUDE.md` 填好：

```
這個專案是 [一句話：要做什麼]，stack 用 [語言/框架]。
請把 CLAUDE.md 的 goal / stack / file layout 填好，constraints 先留空。
```

### 既有專案

```bash
~/.multi-agent-kit/init.sh ~/code/legacy-app --existing
cd ~/code/legacy-app && claude
```

`init.sh --existing` 是**非破壞性**的：絕不覆蓋你既有的 `CLAUDE.md` 或 `.claude/` 檔（已有 CLAUDE.md 時，範本另存成 `CLAUDE.md.from-kit` 讓你手動 merge 後半段的 Workflow Rules）。

既有專案有一條黃金法則：**先讓 AI 學會這個專案，再讓它動手。** AI 不懂你的歷史與不成文慣例，貿然亂改會出事。所以第一句不是叫它寫 code，是叫它做 onboarding（`PROMPTING.md` §0「既有專案」那句）：

```
請先探索整個 repo，把你看到的架構、慣例、以及「不該碰的區域」
寫進 CLAUDE.md 的對應段落。先不要改任何其他檔案。
```

接著三個動作別省：

1. **自己 review 它寫的 constraints。** AI 的理解一定有錯——對的留著、誤解的修正、它不知道的歷史你補上。`Project-specific constraints` 越具體越好（「`src/legacy/payment/` 無文件、極脆弱，任何改動需手動確認」遠勝「不要弄壞東西」）。
2. **頭幾個任務挑低風險的**：補測試、改 error message、加 internal endpoint。**不要**第一棒就丟 auth / payment / schema migration。
3. **信任建立後再放寬。** 對 legacy code 可先把 `CLAUDE.md` 的 STOP 閾值調低（例如改動超過 30 行就停下問你），跑順了再放鬆。

---

## 日常使用

開工後你幾乎只做一件事：**approve plan**，其餘坐著看。

要更精準地駕馭 AI，看 `PROMPTING.md` 那一頁就夠——它把「怎麼下指令」收斂成一個小文法：

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

### Hooks（`.claude/settings.json`，預設關閉，opt-in）

- `classify-task.sh`：自動分類任務大小，讓你少打「直接做」。
- `verify-final-review.sh`：結束前若有未審的業務邏輯就 block（v3.1 起 profile-aware）。
- **啟用**：把 settings.json 裡 `_hooksDisabledByDefault_uncomment_to_enable` 改名成 `hooks`，重啟 session。
- **單次旁路 final review**：`touch /tmp/claude-skip-review-<session_id>`（session_id 在 block 訊息裡），或跟 Claude 說「這次跳過 review，我已確認」。
- ⚠️ **不要**啟用 `/codex:setup --enable-review-gate`：它在每次 stop 自動 review，會造成 Claude/Codex loop 燒 quota。我們的 Stop hook 做同樣的事但更可控。

### 權限提示

路徑含每次變動的 session UUID，「Don't ask again」對下次無效，選 `Yes` 即可。受不了就在 settings.json 的 `permissions.allow` 加 patterns（`Bash(timeout *)`、`Bash(git status *)`、`Bash(./.claude/scripts/gemini_exec.sh *)` 等）。

---

## Debug 速查

- **「我沒有 codex 這個 tool」** → plugin 沒裝：重跑上面那四個 `/plugin … /codex:setup` 指令。
- **`/codex:review` 回 usage / rate limit** → quota 用光：等冷卻（通常幾小時）、升級訂閱，或暫切 `export KIT_PROFILE=solo`。
- **研究階段卡住 / 「Input must be provided」** → 檢查 `echo $GEMINI_API_KEY`；Windows 用 `setx` 後重開所有 terminal；手動測 `./.claude/scripts/gemini_exec.sh "say hello"`。
- **`claude` 在 Git Bash 立即退出** → 非 git 目錄誤入 print 模式：`git init`（`init.sh` 已代勞），或從 PowerShell 啟動。
- **找不到 superpowers 寫的 plan** → 問「plan 存在哪？」；不同版本可能在 `plans/`、`docs/plans/`、`.claude/plans/`。
- **Hook 沒生效 / 誤觸發** → `cat .claude/settings.json | grep -A20 '"hooks"'` 確認啟用；`echo '{"prompt":"add a button"}' | .claude/hooks/classify-task.sh` 測分類；不合用就直接編輯 `.sh`（純 bash 是 hooks 的好處）。

---

## 專案裡哪些能改、哪些別碰

| 路徑 | 角色 | 你要做的 |
|------|------|---------|
| `CLAUDE.md` | 專案設定 | 填 / 維護 |
| `PROMPTING.md` | 你的速查 | 隨手補 |
| `.claude/settings.json` | 設定 | 可調（hooks / 權限） |
| `.claude/hooks/`、`scripts/`、`agents/`、`skills/` | infra | 別碰（要改流程才動） |

---

## 文件地圖

| 檔案 | 給誰看 | 內容 |
|------|--------|------|
| `README.md` | 新人 / 你 | 你正在看的——裝機、開專案、操作、debug |
| `PROMPTING.md` | 你（每天） | 一頁速查：怎麼跟 AI 溝通（會進專案） |
| `CLAUDE.md` | AI（每個 session） | 協作工作流規則（會進專案） |
| `ARCHITECTURE.md` | 想深入的人 | 為什麼這樣設計、v1→v3.1 的取捨 |

（`ADOPTION.md` 已併入本檔「既有專案」段、`USAGE.md` 已併入本檔「操作參考 / Debug」段，皆不再單獨維護。）

---

## 版本

- **v3.1（現在）**：`KIT_PROFILE` profile 切換 + 一鍵 `init.sh` + 一頁 `PROMPTING.md` + 砍掉專案污染與冗長文件。
- **v3**：官方 codex-plugin-cc 取代自製 codex/gemini wrapper。
- **v2 / v1**：deprecated（自製 wrapper / PAL MCP）。

今天起手就用 v3.1。
