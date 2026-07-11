# Multi-Agent Starter Kit (v4.6)

讓 **Claude Code + Superpowers + Codex Plugin** 乾淨分工地一起工作的起手包。
你只描述任務、approve plan;AI 之間自己協作——你不再當人肉訊息路由器。

## 這是什麼(30 秒)

```
你 ─── prompt ───▶ Main Claude (orchestrator)
                       │
       ┌───────────────┼───────────────┐
       ▼               ▼               ▼
 research-scout    Superpowers      Codex Plugin
 (Claude 子代理研究)  (規劃 + 實作)     (跨模型審查)
```

- **research-scout** — 研究:Claude 原生子代理(WebSearch/WebFetch)。不寫 code、不 review。
- **Superpowers** — 規劃 + 實作:brainstorm / 寫 plan / 執行 plan。
- **Codex Plugin** — 審查:用「不同的模型」挑錯。

核心信念一句話:**審查的人必須跟寫的人是不同模型。** 這條 isolation 是整個
kit 的承重牆。這套 kit 在 prompt / context / harness 三層做了哪些防護,見
[`DEFENSES.md`](DEFENSES.md);設計脈絡見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## 兩種 profile

用環境變數 `KIT_PROFILE` 切換,每台機器設一次:

- **`full`(預設)** — 審查用 `/codex:review`,**不同模型、真正的隔離**。日常用這個。
- **`solo`** — 公司不能用 codex、或 token 用完:`export KIT_PROFILE=solo`。審查降級成
  fresh-context Claude 自審(只剩狀態/時間隔離),AI 會**主動宣告「跨模型隔離已
  關閉」**——誠實的降級,不是壞掉的 full。

## 安裝(每台機器一次)

kit 是**留在原地的工具**,不是專案模板:clone 一次,每開專案用 `init.sh` 把
「安裝層」(`.claude/` + `CLAUDE.md` + `README.md`)吐進去——kit 自己的文件永遠
留在 kit repo,所以你打開專案不會被搞混「哪些能改」。

```bash
# 1. 裝 Claude Code(唯一硬需求)— https://docs.claude.com/en/docs/claude-code/getting-started
#    full profile 另需:
npm i -g @openai/codex && codex login

# 2. clone kit(留著,日後 git pull 更新)
git clone <kit-repo-url> ~/.multi-agent-kit

# 3. 設環境變數(加進 ~/.bashrc / ~/.zshrc 讓它持久)
export KIT_PROFILE=full
```

第一次進 claude 再裝一次 codex plugin(**整台機器只做這一次**,所有專案共用):

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

## 開一個專案

```bash
~/.multi-agent-kit/init.sh ~/projects/my-thing   # 空目錄=新專案,非空=既有專案,自動判斷
cd ~/projects/my-thing && claude
```

`init.sh` 只複製安裝層、`git init` + 初始 commit、跑環境檢查,並在結尾印出一句
**bootstrap prompt**——進 claude 後把它貼上去,AI 就會填好 `CLAUDE.md` /
`README.md` / `PROJECT.toml` 的佔位符。

**既有專案多一條黃金法則:先讓 AI 學會這個專案,再讓它動手。** init.sh 在既有
模式下印出的第一句是叫 AI 做 onboarding(探索 repo、寫 constraints、**先不改任何
檔案**),不是叫它寫 code。接著三件事別省:

1. **自己 review 它寫的 constraints**——AI 的理解一定有錯:對的留、誤解的修、
   它不知道的歷史你補。越具體越好(「`src/legacy/payment/` 極脆弱,任何改動需
   手動確認」遠勝「不要弄壞東西」)。
2. **頭幾棒挑低風險**(補測試、改 error message、加 internal endpoint),
   **別**第一棒就丟 auth / payment / schema migration。
3. **信任建立後再放寬** STOP 閾值。

既有模式**非破壞性**:絕不覆蓋你既有的 `CLAUDE.md` / `.claude/`(已有 CLAUDE.md
時範本另存 `CLAUDE.md.from-kit` 讓你手動挑要併入的內容)。

**更新已鋪過的專案**(kit repo `git pull` 後):

```bash
~/.multi-agent-kit/init.sh <dir> --update   # 覆蓋 kit-owned 檔、印遷移提示;settings.json 只印 diff 讓你自己合併
```

## 專案總覽:proj(v4.4)

每個專案根目錄有一份 `PROJECT.toml`(user-owned,init/--update 只鋪骨架、
永不覆蓋):狀態、起始指令、付費外部服務。`bin/proj` 掃描 `$PROJ_ROOT`
(預設 `$HOME`)彙總:

```bash
ln -s ~/.multi-agent-kit/bin/proj ~/.local/bin/proj   # 每台機器一次

proj              # 全專案:狀態/說明/燒錢服務/最後 commit(過時標 ⚠)
proj yt-summary   # 單一專案:起始指令直接可複製
proj money        # 只看誰在花錢:服務/計費/月費估計/取消方式
proj remote       # gh repo list 對照本機,列出還沒 clone 的
proj html         # 產出視覺化 HTML dashboard,WSL 自動開瀏覽器(終端太窄看不下時)
```

維護不靠記性:kit-owned rule(`project-manifest.md`)會讓每個專案的
AI session 在狀態/指令/付費服務變動時順手更新 manifest。

## 日常使用

開工後你幾乎只做一件事:**approve plan**,其餘坐著看。要更精準駕馭,就這個小
文法——這就是全部:

- **一句話描述任務**(大小系統自己判,多數不用你指定)。
- 想覆寫判斷,**接一個修飾語**:`直接做` / `走完整流程` / `這會動到 X,請 review`
  / `請質疑這個設計`。
- 中途插話:`暫停` / `rollback 剛才的改動` / `/btw 小問題`。

任務大小、review 時機、派工升降級由 `.claude/rules/` 自動執法,你不用背。審完用
`/kit-review` 過 Stop gate(它跑 profile 對應的 review 並寫入證據);要跳過用
`/kit-skip-review`。高 stakes 想挑戰設計前提用 `/codex:adversarial-review`,整件
事想丟給另一個模型用 `/codex:rescue`。

> ⚠️ **不要**啟用 `/codex:setup --enable-review-gate`——它每次 stop 自動 review,
> 會造成 Claude/Codex loop 燒 quota。kit 的 Stop hook 做同樣的事但更可控。

## 常見卡點

- **「我沒有 codex 這個 tool」** → plugin 沒裝:重跑上面四個 `/plugin … /codex:setup`。
- **`/codex:review` 回 usage / rate limit** → quota 用光:等冷卻、升級訂閱,或暫切
  `export KIT_PROFILE=solo`。
- **`claude` 在 Git Bash 立即退出** → 非 git 目錄誤入 print 模式:`git init`
  (`init.sh` 已代勞),或從 PowerShell 啟動。
- **Hook 沒生效** → `grep -A20 '"hooks"' .claude/settings.json` 確認啟用;要客製
  hook 改 kit repo 再 `--update`,別在專案裡改(v4.0 起 hook 會物理擋下)。

## 專案裡哪些能改、哪些別碰

| 你要填 / 維護 | 別碰(kit-owned) |
|---------------|------------------|
| `CLAUDE.md`(goal / stack / constraints)、`README.md`、`.claude/protected-paths`(專案禁區,**只能加嚴**)、`docs/LESSONS.md`(自行累積) | `.claude/`(rules / hooks / scripts / agents / skills / docs、settings.json、kit-version)——要客製改 kit repo 再 `--update` 鋪回;v4.0 起 hook 物理擋下對這些檔的編輯(kit repo 本身豁免) |

## 文件地圖

| 檔案 | 給誰 | 內容 |
|------|------|------|
| `README.md` | 你 | 你正在看的——裝機、開專案、日常操作、卡點 |
| [`DEFENSES.md`](DEFENSES.md) | 想看工程 | prompt / context / harness 三層防護清單 + 誠實條款 |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | 想深入 | 為什麼這樣設計、v1→v4.6 完整取捨、四維 isolation |
| `docs/harness-diagnosis.md` | 想深入 | v4.0 防線設計依據:三大弱模型失敗場景 → 物理痛點 → 阻斷方案 |
| `docs/handover-from-fable.md` | 未來的模型與你 | 高階模型交接信:三件關鍵事 + 制度腐化偵測法 |
| `CLAUDE.md` | AI(每 session) | 專案內容範本(goal / stack / constraints);workflow 規則另放 `.claude/rules/`(kit-owned) |

---

*版本:**v4.6**(review 經濟學:re-review 範圍收斂、Stop gate 測試檔不計數、
註解紀律)。完整版本演進見 [`ARCHITECTURE.md §二`](ARCHITECTURE.md)。*
