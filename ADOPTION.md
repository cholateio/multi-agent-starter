# Adoption Guide for Existing Projects

把 v3 multi-agent kit 加入既有專案。新專案請看 README.md「Quick start」。

## 為什麼既有專案要特別小心

新專案沒包袱，AI 怎麼判斷都行。既有專案 AI 不懂你的慣例和歷史，
亂改會出事。**核心策略：先讓 AI 學會這個專案，再讓它動手。**

## Pre-flight checklist

開始之前確認：

- [ ] `claude`、`codex`、`gemini` CLI 都裝好且能跑（用 setup.sh 驗證）
- [ ] 專案有 git 控制（你能 revert 任何 AI 改動）
- [ ] 你心裡知道哪些區域是「沙盒」、哪些是「production-critical」
- [ ] 至少 30 分鐘做 onboarding，不要趕

## Step 1：複製基礎建設（不動既有 code）

```bash
cd ~/path/to/existing-project

# 複製 .claude 目錄、setup.sh、USAGE.md
cp -r /path/to/multi-agent-starter-v3/.claude .
cp /path/to/multi-agent-starter-v3/setup.sh .
cp /path/to/multi-agent-starter-v3/USAGE.md .

# 建立 docs 目錄
mkdir -p docs/decisions docs/plans
```

如果你已經有 CLAUDE.md：
- 不要直接 `cp` 覆寫
- 手動 merge：把 `multi-agent-starter-v3/CLAUDE.md` 後半段的
  `# Multi-Agent Workflow Rules` 整段加到你的 CLAUDE.md

如果沒有 CLAUDE.md：
```bash
cp /path/to/multi-agent-starter-v3/CLAUDE.md .
# 然後填 placeholders
```

## Step 2：環境檢查

```bash
./setup.sh
```

確認所有元件 OK。Codex Plugin 安裝指令在輸出最後會列出。

## Step 3：初步 CLAUDE.md（先不寫 constraints）

編輯 CLAUDE.md，填上：
- Project name
- 一段話描述目標
- Stack
- 初步 file layout（`tree -L 2` 結果就夠）

**先不要填 "Project-specific constraints"**——這段我們在 Step 5 才動，
因為要先讓 AI 探索後我們才知道要寫什麼。

暫時寫：

```markdown
## Project-specific constraints

(待 AI onboarding 後補上。在補上前，AI 應該避免任何不確定影響的修改。)
```

## Step 4：AI Onboarding（**不要跳過**）

進到 claude code：

```bash
claude
```

第一個 prompt：

```
Read CLAUDE.md to understand what this project is. Then explore the
codebase to build an understanding of:

1. 高層架構（modules、職責、互相連接）
2. Entry points 和主要 data flow
3. 你觀察到的 coding conventions
4. 看起來「歷史遺留」的地方（只標記，不批評）
5. Test setup 和覆蓋策略

把上述內容寫進 docs/AI_ONBOARDING.md。**不要修改任何 production 檔案**。
只是讀取和探索。

對於需要跨多檔案的探索，可以考慮 spawn gemini-research-scout subagent 
（如果適合的話）——但這個專案的 onboarding 主要是看內部 code，外部研究通常不需要。
```

讓它跑完，可能 10-30 分鐘。

## Step 5：你親自 review AI_ONBOARDING.md

**這步絕對不能跳過。** AI 的理解一定有錯。

打開 `docs/AI_ONBOARDING.md`，預期會看到：

- AI 對的地方（baseline）
- AI 對架構的誤解（你修正）
- AI 不知道的歷史脈絡（你補充）
- AI 標記為「奇怪」但其實是故意的東西（你解釋）

**直接編輯 AI_ONBOARDING.md**——它變成下一步的素材。

## Step 6：把 constraints 寫進 CLAUDE.md

回到 CLAUDE.md 的 "Project-specific constraints"，認真寫：

- **絕對不能改的區域**（含原因）
- **必須遵守的慣例**（特別是非顯而易見的）
- **有怪癖的外部依賴**（vendor API、legacy integration）
- **Migration / deployment / DB 約束**

**具體比抽象有用**：
- 沒用的：「不要破壞東西」
- 有用的：「`src/legacy/payment/` 整合 PaymentVendor v1（無文件、極脆弱）—
  任何改動需手動確認」

## Step 7：調低觸發閾值

對既有專案，CLAUDE.md 的 line threshold 調低：

```markdown
- Change exceeds 30 lines (lower than default 100 for legacy code)
- About to delete or rewrite >10 existing lines
- Modifying any file under <list your high-risk paths>
```

可以信任建立後再放寬。

## Step 8：沙盒 feature 跑第一次

**第一個任務不要在 production-critical 區域。** 挑低風險的：

✓ 好的第一任務：
- 加新 internal admin endpoint
- 補既有 utility 的測試
- 改善 error messages
- 加文件

✗ 不好的第一任務：
- 重構 auth flow
- 優化 payment pipeline
- 任何 data migration

跑一次完整 plan-review-implement loop，**仔細看每個 phase 的輸出**。

觀察點：
- Reviewer 有抓到 project-specific 的 concerns 嗎？還是只給通用建議？
- AI 寫的 code 跟既有風格一致嗎？
- 它有遵守 constraints 嗎？

## Step 9：迭代 CLAUDE.md

第一次跑會冒出問題。每次 AI 做了你不想要的事，**就立刻補一條 CLAUDE.md
規則**。例如：

```
觀察：AI 一直建議用 exception，但我們專案用 Result type
→ 加進 CLAUDE.md "Coding standards"：
  "We use Result types, not exceptions, across module boundaries"
```

```
觀察：reviewer 一直挑 style nits，valuable concern 反而被淹
→ 加進 CLAUDE.md：
  "When reviewing: prioritize correctness and security; defer style 
   matters to linter"
```

## Step 10：建立 trust tiers

5-10 個任務後，把信任分級寫進 CLAUDE.md：

```markdown
## Trust tiers

Tier 1（auto-execute，最後總結）：
- UI / styling
- Documentation
- Tests for stable code
- Internal admin tools

Tier 2（plan-review-implement，PR 你 review）：
- 非 critical paths 的 business logic
- 新 API endpoints
- Performance improvements

Tier 3（只 propose plan，你實作或明確 approve）：
- Auth / payment / deployment
- Schema migrations
- 任何在「Project-specific constraints」列出的區域
```

## 既有專案的常見坑

### 坑 1：跳過 onboarding

症狀：AI 建議違反不成文慣例。
修法：**不要跳過 Step 4**。30 分鐘 onboarding 換取後續上百次正確判斷。

### 坑 2：constraints 寫得太抽象

症狀：AI 一再做你不想要的事。
修法：Constraints 越具體越好。每次踩坑就補一條規則。

### 坑 3：盲信 reviewer

症狀：codex/gemini 建議的改動跟專案慣例衝突。
修法：Reviewer 看不到 CLAUDE.md（只看 plugin 傳的 context）。
**永遠用你對專案的知識過濾 review 建議**。

### 坑 4：太早讓 AI 動高風險區

症狀：一個錯誤改動引發 production incident。
修法：信任分級存在是有理由的。先沙盒、再核心、最後高風險。

## 何時 re-onboard

每 6 個月、或經歷大改架構後，重跑 Step 4。AI 的理解會 drift，
codebase 也會演進。30 分鐘 re-onboarding 比基於過時假設行動便宜得多。

## 對照表：新專案 vs 既有專案

| 面向 | 新專案 | 既有專案 |
|------|--------|---------|
| 第一個 AI 任務 | 規劃首個 feature | Onboard，寫 AI_ONBOARDING.md |
| CLAUDE.md 重點 | 願景、約定 | 警告、約束、不要碰 |
| 信任起點 | 高（沒歷史可破壞） | 低（先做沙盒） |
| Line threshold | 100 | 30，建立信任後放寬 |
| Gemini scout 使用 | 偶爾（新技術選型） | Onboarding 階段重度，之後少用 |
| 主要風險 | over-engineering | 破壞既有功能 |
