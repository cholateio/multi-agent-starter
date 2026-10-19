# Kit v5 設計：機器級安裝（Claude Code plugin）＋ 機隊安全流程

> 2026-10-19。設計者 = 本輪最強模型 session；實作交 Opus/Sonnet 子代理；重要決策
> 另送 Codex 跨模型審。owner 已把全部決策授權給設計者，每個關鍵取捨以
> 【設計者決定 Dn】標記並附一行理由，彙整於 §14。
>
> 本檔是 v5 的設計權威。它寫在公開 repo 裡，所以**本身遵守 v5 的陌生人安全規則**：
> 不出現私人專案名（以 proj-a… 代稱）、不出現本機絕對路徑、不出現金額與事故細節。
>
> 事實基礎（本 session 實測，2026-10-19）：Claude Code 2.1.303；codex plugin 1.0.6 以
> `${CLAUDE_PLUGIN_ROOT}` 掛 hooks（`hooks/hooks.json`）；superpowers 7.0.0 以
> SessionStart hook 把整份 skill 注入 context；本機 `~/.claude/rules/` 不存在；
> 全域 `core.hooksPath` 未設；機隊 ~29 個 GitHub repo（13 公開），本機 12 個 v4
> 專案 + kit 自身都把 `.claude/`（19–21 檔）**tracked 在 git 並已 push**；
> gitleaks 8.30.1 / osv-scanner 2.7.0 **目前只存在於一個暫存目錄，不在 PATH**。

> **修訂 2026-10-19**（plan 撰寫前，依 orchestrator 指示；Codex 審查尚未完成，後續
> 發現另行追加）：
> 1. 統一 `.gitignore` kit 區塊、guard R2 禁推路徑、audit A4、migrate 的 untrack／備份
>    清單一律加入 **`docs/superpowers/plans/`**（superpowers plugin 把 plan 寫在那裡；
>    本機 10 個專案已有該目錄）。`docs/plans/` 保留。
> 2. R4 `always` 層字面值的**合法例外**：公開 repo 可能刻意在 app code 與 SQL migration
>    硬編 owner 的雲端 uid（owner-only RLS）。新增 per-repo、diff 可見的例外機制
>    `kit.toml [privacy] allow_literals = ["<literal name>"]`——**以名稱引用**
>    `privacy.local.toml` 的 `[[literal]]`（每條新增必填 `name`），**永不以值引用**；預設維持
>    嚴格；guard R4/R5 與 audit A2/A3（含歷史掃描）同一套例外；詳 §7.2／§7.3／§8。
> 3. 實作順序：plugin 載入 + SessionStart 注入、全域 `core.hooksPath` guard shim 兩件最不
>    確定的事放在 plan 的 Phase 0 作 spike，各附 go/no-go；§12 同步調整。

---

## 1. 意圖：為什麼要 v5

v4 的三件承重牆（Stop gate、breaker、re-anchor）運作良好；出問題的是**安裝形態**與
**洩漏面**，兩者同源——kit 把自己「複製進每個專案並 tracked」：

1. **隱私洩漏來自開發產物，不是代碼。** 審計證實：沒有任何活憑證進過歷史，但
   PROJECT.toml（成本、雲端專案名）、LESSONS（事故、過往弱點）、AI plans（個人
   資料）、本機路徑、kit 自己的 `templates/README.example.md`（一個私人 repo 的
   README 原文）與 design-history 都在公開 repo 裡。v4 的「每專案一份 `.claude/`
   + 筆記型 README」把這些東西放在 push 的路徑上。
2. **沒有任何一道閘攔手動 commit。** v4 的 hooks 只看 Claude 的工具調用；`git push`
   本身無人把關。
3. **15 份副本 = 15 個 drift 源。** 12 個專案中 10 個的 `settings.json` 已與 kit
   模板不同；`init.sh --update` 的「印 diff 讓你合併」沒人做。
4. **`Bash(timeout *)` 放行任何指令。** 審計抓到；Claude Code 文件證實 `timeout`
   是內建會被剝掉的 wrapper，這條 allow 既危險又多餘。

v5 的一句話：**kit 從「專案的一部分」變成「機器的一部分」；專案只留 tracked、
工具中立、陌生人安全的最小真相（AGENTS.md + kit.toml），其餘要嘛在 plugin，
要嘛只在本機；再加一道所有 commit 都過的 guard 與一個機隊 audit。**

## 2. 目標 / 非目標 / 反目標 / 約束

**目標**
- G1 kit 裝一次（user-scope plugin），所有 kit 專案自動啟用，非 kit 目錄（含 `$HOME`）
  完全靜默。
- G2 專案不再 track `.claude/`；per-project 真相搬到 tracked、工具中立的位置。
- G3 保留 v4 全部物理防線（Stop gate / breaker / protect-paths / re-anchor / rules
  預算棘輪 / smoke tests），行為等價，除非搬家本身迫使改變（§3 逐項列出）。
- G4 本機 guard：**每一個** commit / push（人或 AI）都過 gitleaks + kit 隱私規則 +
  禁推路徑檢查。
- G5 機隊 audit：一條指令掃全機隊，終端表 + HTML，CRITICAL/HIGH 非零退出。
- G6 `kit migrate` 把 ~15 個 v4 專案無損遷到 v5，可 dry-run、可重跑。
- G7 kit repo 自身的 HEAD 對陌生人乾淨（history rewrite 在 v5 落地後另做）。

**非目標**
- 不做 history rewrite 本身（只保證 v5 之後的 HEAD 乾淨，並在 §12 排進順序）。
- 不修各專案的應用層安全缺口（RLS、上傳檢查、WebSocket Origin）——audit 只負責
  **指出**，修法走各專案 session。
- 不支援 Windows / Git Bash 作為 guard 與 `kit` CLI 的一級平台（v4 的可攜性顧慮只
  保留在 Claude hooks：bash + jq + git）。
- 不做密碼學防偽——威脅模型沿用 v4.9（持 Bash 的模型可偽造任何本機狀態；
  防線價值 = 摩擦 + 審計痕跡）。

**反目標（主動避免）**
- 不讓專案 tracked 檔案指向任何機器路徑（`@~/.../rules.md` 這種 import 不採用）。
- 不把個人字面值（uid、bucket、私人專案名）寫進任何會被 commit 的檔，**包括 kit
  repo 的 tests 與本檔**。
- 不為了「plugin 很酷」重寫能動的 hook 邏輯——hook 主體 diff 應只有路徑解析與
  啟用閘。
- 不讓 guard 慢到人想繞：pre-commit 典型 <1s，pre-push 典型 <3s。

**約束**
- Owner 決定 1–7（brief §2）固定。
- Claude Code plugin 的已文件化能力（研究結論，2026-10-19）：plugin **不能**攜帶
  `rules/`、根目錄 CLAUDE.md 不載入、`settings.json` 只認 `agent`/`subagentStatusLine`
  （**permissions 無法由 plugin 出貨**）、hooks 隨 plugin 啟用範圍在**每個目錄**
  都觸發、plugin 子代理忽略 `hooks`/`permissionMode`。
- Claude hooks 的工具鏈維持 bash + jq + git（Windows 機隊曾是 v4 的設計約束，不
  在 v5 擴大）；`kit` CLI 與 audit 用 Python 3.11+ 純標準庫（與 `bin/proj` 同底線）。

## 3. 架構：元件地圖 v4 → v5

```
v4：每個專案                        v5：機器一次                      v5：每個專案（tracked）
┌──────────────────────┐           ┌────────────────────────────┐    ┌──────────────────────┐
│ .claude/rules (5)    │──move──▶  │ plugin/rules → SessionStart│    │ AGENTS.md            │
│ .claude/hooks (5)    │──move──▶  │ plugin/hooks + hooks.json  │    │ CLAUDE.md (@AGENTS)  │
│ .claude/skills (4)   │──move──▶  │ plugin/skills (6, /kit:*)  │    │ kit.toml  ← 啟用標記 │
│ .claude/agents (2)   │──move──▶  │ plugin/agents              │    │   + protected paths  │
│ .claude/docs (2)     │──→skill─▶ │ plugin/skills/{judgment,   │    │ README / LICENSE     │
│ .claude/settings.json│           │   verify-signals}          │    │ docs/DEVELOPMENT.md  │
│   hooks ─────────────│──move──▶  │ plugin/hooks/hooks.json    │    │ docs/specs/          │
│   permissions ───────│──move──▶  │ ~/.claude/settings.json    │    │ .gitignore（統一）   │
│ .claude/protected-   │──move──▶  │   (kit setup 合併)         │    └──────────────────────┘
│   paths              │───────────┼──────────────────────────────▶ kit.toml [protected]
│ .claude/kit-version  │──drop     │ ~/.config/kit/             │    v5：每個專案（local only）
│ CLAUDE.md 範本       │──split──▶ │   config.toml              │    ┌──────────────────────┐
│ init.sh              │──replace▶ │   privacy.local.toml (600) │    │ .claude/ (untracked) │
│ (無)                 │──new────▶ │   git-hooks/{pre-commit,   │    │ PROJECT.toml         │
│                      │           │     pre-push} ← hooksPath  │    │ docs/LESSONS.md      │
│ /tmp/claude-kit-*    │──keep     │ ~/.local/state/kit/        │    │ docs/plans/          │
└──────────────────────┘           └────────────────────────────┘    └──────────────────────┘
```

| v4 元件 | v5 去處 | 動作 | 備註 |
|---|---|---|---|
| `.claude/rules/*.md`（5 檔，19,615 B / 13,019 chars） | `plugin/rules/*.md`，由 SessionStart hook 注入 | **move（載體變）** | plugin 無法出貨 rules；見 §4.3 |
| 5 支 hooks | `plugin/hooks/*.sh` + `hooks/hooks.json`（`${CLAUDE_PLUGIN_ROOT}`） | move | 每支開頭加啟用閘 `kit_project_root`；主體不動 |
| `kit-review` / `kit-skip-review` / `kit-dispatch` / `research-before-planning` | `plugin/skills/{review,skip-review,dispatch,research-first}` → `/kit:review` 等 | move + **rename** | plugin 命名空間使 `/kit:kit-review` 疊字【D3】 |
| `research-scout` / `solo-reviewer` | `plugin/agents/` | move | 只用 plugin 支援的 frontmatter 欄位 |
| `.claude/docs/judgment-matrix.md`、`verification-signals.md` | `plugin/skills/judgment/SKILL.md`、`plugin/skills/verify-signals/SKILL.md` | **move → skill** | 原本靠 CLAUDE.md 路由表「需要時才讀」；skill description 原生承載觸發條件【D4】 |
| CLAUDE.md 的「檔案路由」表 | drop | **drop** | 被 skills 自描述取代 |
| `settings.json` hooks 區 | `hooks/hooks.json` | move | |
| `settings.json` permissions | `~/.claude/settings.json`（`kit setup` 合併） | move | 刪 `Bash(timeout *)`；見 §4.6 |
| `.claude/protected-paths` | `kit.toml` 的 `protected = [...]` | move | hook 用 sed 取行；格式受 `kit doctor` 驗證 |
| `.claude/kit-version` | drop | **drop** | plugin 版本由 Claude Code 管；`kit.toml` 的 `kit = 5` 是 schema 版 |
| protect-paths 的「kit repo 自我豁免」偵測 | 改為保護 `$CLAUDE_PLUGIN_ROOT`、`~/.config/kit/` 之下的檔案（在專案目錄外時） | **change** | 專案裡不再有 kit-owned 檔；kit-owned 的位置變了 |
| CLAUDE.md 範本（goal/stack/layout/constraints） | `AGENTS.md` 範本 + 兩行 CLAUDE.md stub | split | Codex 讀 AGENTS.md |
| `templates/README.md`（筆記型） | `README.public.md`（RepoBox 食譜）+ `README.private.md` + `docs/DEVELOPMENT.md` | rewrite | AI 接手 prompt 段 drop（AGENTS.md 承擔） |
| `templates/README.example.md`（私人 repo 原文） | 虛構專案範例 | rewrite | 衛生 |
| `templates/gitignore` | 統一版（公私同一份） | rewrite | |
| `templates/PROJECT.toml`、`mise.toml` | keep | keep | PROJECT.toml 改為 gitignored |
| `init.sh` | `bin/kit {setup,init,migrate,doctor,audit,guard,update}`；`init.sh` 留一版 stub 轉向 | replace | |
| `bin/proj` | keep | keep | 讀本機 PROJECT.toml 的行為不變 |
| `tests/{smoke,hooks-smoke,proj-smoke}.sh` | 改路徑 + 新 `guard-smoke` / `audit-smoke` / `migrate-smoke` / `plugin-validate` | extend | §11 |
| `/tmp/claude-kit-*` 狀態檔 | keep | keep | /tmp 揮發性仍是已接受限制【D9】 |
| `KIT_PROFILE` / `KIT_PROTECT` / `KIT_BREAKER` / `KIT_REVIEW_GATE` | keep；新增 `KIT=off` 總開關；profile 可在 `config.toml` 設機器預設 | keep/extend | |
| kit 自己的 `docs/LESSONS.md`、`PROJECT.toml`、`.claude/` | untrack | move | owner 決定 3 |
| `LICENSE`（0 bytes） | MIT 全文 | fix | |
| （新）guard、audit、kit.toml、privacy 規則、CI workflow 範本 | new | new | §7–§8 |

**明確 drop 的東西與理由**：`kit-version`（plugin 自帶版本）；`init.sh --update` 流程
（in-place plugin 或 `claude plugin update` 取代，再無 15 份副本）；CLAUDE.md 路由表
（skills 自描述）；settings.json 的 diff 合併提示（專案層不再有 settings.json）；
README 範本的「叫 AI 接手」段（AGENTS.md 就是給 AI 的）；protect-paths 的 kit repo
三檔偵測（`init.sh`+`VERSION`+`templates/`，前提消失）。

## 4. 機器級安裝（A）

### 4.1 kit repo 佈局（解「`.claude/` 不 track」vs「kit 的 `.claude/` 是產品」）

產品搬到中性目錄 `plugin/`；kit repo 自己的 `.claude/` 跟所有專案一樣 **untracked**
（開發 kit 時用 `claude --plugin-dir ./plugin` 載入開發中版本）。

```
multi-agent-starter/                 （public）
├── .claude-plugin/marketplace.json  # name: "multi-agent-kit"; plugins: [{name:"kit", source:"./plugin"}]
├── plugin/                          # ← 產品。所有 Claude 載入的東西只在這裡
│   ├── .claude-plugin/plugin.json   #   name "kit", version = VERSION（smoke 斷言相等）
│   ├── hooks/hooks.json
│   ├── hooks/{lib.sh,inject-rules.sh,session-start.sh,classify-task.sh,
│   │          protect-paths.sh,tool-breaker.sh,verify-final-review.sh}
│   ├── rules/{kit-workflow,kit-delegation,kit-judgment,kit-evolution,project-manifest}.md
│   ├── skills/{review,skip-review,dispatch,research-first,judgment,verify-signals}/SKILL.md
│   ├── agents/{research-scout,solo-reviewer}.md
│   ├── guard/{pre-commit.sh,pre-push.sh,lib-privacy.sh,privacy-rules.toml,gitleaks.toml}
│   └── templates/{AGENTS.md,CLAUDE.md,README.public.md,README.private.md,DEVELOPMENT.md,
│                  LICENSE.MIT,LICENSE.CC-BY-4.0,gitignore,kit.toml,PROJECT.toml,mise.toml,
│                  github/workflows/kit-guard.yml}
├── bin/kit  bin/proj                # kit = Python 3.11+ 入口（cli/ 套件）；proj 不動
├── cli/                             # kit CLI 的 Python 套件（setup/init/migrate/doctor/audit/guard）
├── tests/                           # §11
├── docs/                            # ARCHITECTURE / DEFENSES / design-history（已匿名化）
├── AGENTS.md  CLAUDE.md(@AGENTS.md)  kit.toml  README.md  LICENSE  VERSION
└── .gitignore                       # 與 templates/gitignore 同一份（kit 吃自己的狗糧）
```

【D1】plugin 命名 `kit`、marketplace 命名 `multi-agent-kit`：skill 叫法最短（`/kit:review`），
marketplace 名不與 plugin 名撞。
【D2】owner 本機用**本地路徑 marketplace**（`claude plugin marketplace add ./multi-agent-starter`
從 `$HOME` 執行）：文件明載「相對路徑 plugin 來自本地 marketplace 時**就地載入、不複製**，
改原始碼下個 session 即生效、不必升版」——這給 owner 零摩擦的開發／部署迴圈，且
`${CLAUDE_PLUGIN_ROOT}` 成為穩定路徑（= 原始碼 `plugin/`）。陌生人走 GitHub marketplace
（複製進 `~/.claude/plugins/cache/`，`claude plugin update` 更新）。兩條路的 hook 程式碼
相同，差別只在 `${CLAUDE_PLUGIN_ROOT}` 的值。

### 4.2 啟用：plugin 在每個目錄都會 fire，靠標記檔自我閘控

Claude Code **沒有** per-directory 啟用 hooks 的機制（研究結論）。所以每支 hook 的第一
件事是讀 `plugin/hooks/lib.sh`：

```bash
# lib.sh — every kit hook sources this and calls kit_project_root || exit 0
kit_project_root() {
    [[ "${KIT:-on}" == "off" ]] && return 1                       # user-only master switch
    local root="${CLAUDE_PROJECT_DIR:-$CWD}"                       # CWD parsed from stdin by caller
    [[ -f "$root/kit.toml" ]] || return 1                          # marker: not a kit project → silent
    if [[ -f "$root/.claude/kit-version" ]]; then                  # half-migrated v4 project
        echo "KIT: v4 layout detected, plugin hooks yield; run: kit migrate ." >&2; return 1
    fi
    printf '%s' "$root"
}
```

- 標記 = 專案根目錄的 **`kit.toml`**（tracked、工具中立，§5.2）。`$HOME`、外來 fork、
  非 kit repo 沒有它 → 五支 hook 全部 `exit 0`，零輸出、零 context。
- 只看專案根（`CLAUDE_PROJECT_DIR` = session 啟動目錄），不往上找：與 v4「`.claude/`
  只在專案根」語意一致；monorepo 子目錄啟動不支援（記入 §13）。
- `.claude/kit-version` 仍在 = v4 的 settings.json hooks 也還在跑 → plugin 讓位，避免
  Stop gate 與 breaker 雙重觸發（過渡期保護；migrate 會刪掉它）。
- skills 與 agents 沒有閘：它們是 on-demand 的，在非 kit 目錄只多幾行 skill 清單，
  可接受【D5】（替代方案是 `paths:` frontmatter，但它是「碰到符合檔案才載入」的語意，
  不適合）。

### 4.3 常駐 rules：SessionStart 注入，兩段，預算雙軌

plugin 不能出貨 `rules/`，根目錄 CLAUDE.md 不載入，`~/.claude/rules/` 會在**每個**目錄
生效（違反 G1）。剩下唯一既文件化、又能被 `kit.toml` 閘控的載體是 SessionStart hook 的
`additionalContext`（superpowers 7.0 就是這樣注入整份 skill）。

【D6】`plugin/hooks/inject-rules.sh <group>` 以兩個 hook entry 註冊，matcher
`startup|resume|clear|compact|fork`：
- group `core` = kit-workflow + kit-delegation（8,111 chars）
- group `judgment` = kit-judgment + kit-evolution + project-manifest（4,908 chars）

理由：文件寫「注入文字上限 10,000 字元」。本 session 以 2.1.303 實測一個 13.9K 字元的
SessionStart 注入**完整送達**（上限未被執行），但設計不押注在未執行的上限上——拆成兩段
各 <10K 字元，對兩種實況都安全。每段加一行標頭
`KIT_RULES[<group>] (always-on; was .claude/rules in v4)`。

預算：smoke test 保留 **20,480 B 位元組棘輪**（v4.9 公式不變，現值 19,615 B），**新增每段
≤9,500 chars 的硬上限**。兩個單位同時執法，因為 Claude Code 的上限以 chars 計，kit 的
歷史預算以 bytes 計。

**已知退化（記入 §13）**：hook 注入的 context 不會像 memory 檔一樣自動進 subagent。
緩解三層：(a) `/kit:dispatch` 模板本來就把判斷句 inline（v4.1 為 snapshot caveat 設計的）；
(b) 專案 AGENTS.md 仍是 memory，subagent 看得到；(c) 若 `SubagentStart` 事件支援
`additionalContext`（研究未讀到細節），加第三個 entry 注入 ≤2K chars 的 judgment 摘要
——實作時驗證，不支援就只做 (a)(b)。

rules 內文需同步改寫的句子：`Kit-owned. Don't edit here — change in the kit repo, then
init.sh --update` → `change plugin/rules in the kit repo, then /reload-plugins`；
`.claude/docs/judgment-matrix.md` → `/kit:judgment` skill；`/kit-review` → `/kit:review`；
`.claude/protected-paths` → `kit.toml [protected]`。

### 4.4 hooks.json 與路徑／狀態解析

```json
{ "hooks": {
  "SessionStart": [ { "matcher": "startup|resume|clear|compact|fork", "hooks": [
      { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/inject-rules.sh\" core",     "timeout": 5 },
      { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/inject-rules.sh\" judgment", "timeout": 5 },
      { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\"",         "timeout": 5 } ] } ],
  "UserPromptSubmit":   [ { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/classify-task.sh\"", "timeout": 5 } ] } ],
  "PreToolUse": [
      { "matcher": "Edit|MultiEdit|Write|NotebookEdit", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/protect-paths.sh\"", "timeout": 5 } ] },
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/tool-breaker.sh\"", "timeout": 5 } ] } ],
  "PostToolUseFailure": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/tool-breaker.sh\"", "timeout": 5 } ] } ],
  "Stop": [ { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/verify-final-review.sh\"", "timeout": 10 } ] } ]
} }
```

- 路徑：一律 `${CLAUDE_PLUGIN_ROOT}`（hooks 命令列可用，且匯出為環境變數給 hook 行程）。
  `${CLAUDE_PROJECT_DIR}` 當專案根，stdin `cwd` 為後備——與 v4 相同。
- 狀態：`/tmp/claude-kit-*-<session_id>` 全部**不動**【D9】（搬去 `~/.local/state` 修得了
  WSL 重開機清 /tmp，但會動到 hooks-smoke 的 1,259 行斷言；/tmp 揮發是 v4 已接受的
  限制，fail-closed 方向是「多審」。列為 v5.1 候選）。
- `KIT_PROFILE`：env 優先，其次 `~/.config/kit/config.toml` 的 `profile`，預設 `full`。
  逃生口 `KIT_PROTECT` / `KIT_BREAKER` / `KIT_REVIEW_GATE` 不變，新增 `KIT=off`（整組
  靜默）。全部 user-only：hook 吃的是 Claude 啟動時的環境。
- KIT_CONTEXT 新增三行：plugin root 絕對路徑（模型讀 on-demand 檔用）、`kit.toml` 的
  `visibility` 與 protected 條數、guard 狀態（hooksPath 已設？gitleaks 在 PATH？）。
- 順手用 `CLAUDE_ENV_FILE`（SessionStart 可寫）匯出 `KIT_SESSION_ID`，讓 `/kit:review`
  不必從 KIT_CONTEXT 文字抄 session_id（文字廣播保留作後備）。

### 4.5 各 hook 的 v5 差異（主體不動）

| hook | 變更 |
|---|---|
| `inject-rules.sh`（新） | 讀 `${CLAUDE_PLUGIN_ROOT}/rules/<group 檔案>` → `additionalContext`；閘控 |
| `session-start.sh` | 閘控；KIT_CONTEXT 三行；kit 版本改讀 `plugin.json`；RE-ANCHOR 第 2 點加 `AGENTS.md` |
| `classify-task.sh` | 閘控；其餘零改 |
| `protect-paths.sh` | 禁區清單改讀 `kit.toml [protected]`（sed 取 `protected = [` 到 `]` 之間、去引號逗號、跳 `#` 行）；「kit-owned → ask」改成：目標在 `$CLAUDE_PLUGIN_ROOT` 或 `~/.config/kit/` 之下**且不在專案目錄內** → ask。在 kit repo 開發時 plugin 就在專案內，自然豁免 |
| `tool-breaker.sh` | 閘控；**新增 guard 保全**：Bash 命令含 `git (commit|push) … (--no-verify|-n)`、`KIT_GUARD=`、`core.hooksPath` 設定 → deny，訊息指向 `kit guard bypass`【D13】 |
| `verify-final-review.sh` | 閘控；`matches_protected` 改讀 kit.toml；`SENSITIVE_PATH_REGEX` 加 `kit\.toml`（放寬 protected / allow_literals 必過 review）；block 訊息的 skill 名改 `/kit:*`；其餘零改 |

【D13】理由：global git hooks 的天然繞道是 `--no-verify`；hook 層擋不了 git，但 Claude 的
Bash 調用在 PreToolUse 看得到。模型要繞只能走 `kit guard bypass`（留名留理由），人要繞
照常 `--no-verify`——「誠實免費、謊言留痕」原則的直接延伸。

### 4.6 權限基線（permissions）

plugin 無法出貨 permissions，所以 `kit setup` 把基線合併進 `~/.claude/settings.json`
（jq 聯集、印 diff、可重跑）。基線縮成：

```
Bash(git status*)  Bash(git diff*)  Bash(git log*)  Bash(git show*)  Bash(ls*)
```

- **刪 `Bash(timeout *)`**：Claude Code 本就剝 `timeout`/`time`/`nice`/`nohup` 等 wrapper
  再比對，這條只剩「放行任何以 timeout 起頭的字串」的壞處。
- 其餘五條沿用 v4 的 read-only 意圖。已知殘餘：`git log --output=<file>`/`git diff
  --output` 能寫檔——接受（寫出的是文字、protect-paths 本就不管 Bash），記入 §13。
- 複合命令（`ls && rm`）不會被 `Bash(ls*)` 整句放行——文件明載每個子命令獨立比對。

### 4.7 `kit` CLI（Python 3.11+，純標準庫，`bin/kit` → `cli/`）

| 指令 | 做什麼 | 冪等 |
|---|---|---|
| `kit setup` | 一機一次：marketplace add（本地路徑 or GitHub）→ `claude plugin install kit@multi-agent-kit --scope user` → 合併權限基線 → 寫 `~/.config/kit/config.toml` → 安裝 git-hooks shims + `git config --global core.hooksPath` → `kit doctor --install` → 建 `privacy.local.toml` 骨架（chmod 600）→ symlink `~/.local/bin/{kit,proj}` | 是 |
| `kit doctor [--install]` | 檢查 claude ≥ 2.1.277、plugin enabled、hooksPath、gitleaks/osv-scanner/gh/jq、privacy.local.toml、rules chars/bytes 預算、`kit.toml` 格式；`--install` 以**釘版本 + sha256** 下載 gitleaks/osv-scanner 到 `~/.local/bin` | 是 |
| `kit init <dir> [--private] [--license MIT\|CC-BY-4.0\|none] [--lang en\|zh-TW]` | 鋪模板（no-clobber）、kit.toml、`git init` + 首 commit、印 bootstrap prompt | 是 |
| `kit migrate <dir> [--apply] [--commit]` | §9；預設 dry-run | 是 |
| `kit guard status\|bypass "<reason>"` | 看 guard 狀態；開 10 分鐘單次 bypass（§7.4） | — |
| `kit audit [name…] [--html] [--json] [--fetch-remote] [--offline <fixture>]` | §8 | — |
| `kit update` | 本地 marketplace：`git -C <kit_root> pull` + 提示 `/reload-plugins`；GitHub：`claude plugin update kit@multi-agent-kit` | 是 |

`~/.config/kit/config.toml`（本機、不 track）：

```toml
kit_root = "<absolute path to the multi-agent-starter checkout>"   # git shims resolve plugin/guard from here
profile  = "full"                   # KIT_PROFILE default; env var wins
github_owner = "<owner>"
[audit]
root    = "~"                       # same scan root as proj
exclude = ["<glob>", "<glob>"]      # fleet exclusions live HERE, never in the repo
```

## 5. v5 專案佈局

### 5.1 檔案樹

```
my-project/
├── AGENTS.md            # tracked：goal / stack / layout / constraints / conventions（工具中立）
├── CLAUDE.md            # tracked：`@AGENTS.md` + 可選 Claude 專屬段
├── kit.toml             # tracked：啟用標記 + visibility/license + protected globs
├── README.md            # tracked：public = RepoBox 食譜（英文）；private = 短版
├── LICENSE              # tracked：MIT 預設（public 必備）
├── .gitignore           # tracked：統一版（公私同一份）
├── .github/workflows/kit-guard.yml   # public 選配（§7.6）
├── docs/
│   ├── DEVELOPMENT.md   # tracked：重啟、env vars、部署、地雷（舊 README 範本內容搬家）
│   ├── specs/           # tracked：需求權威；必須陌生人安全
│   ├── LESSONS.md       # LOCAL ONLY（gitignored）
│   └── plans/           # LOCAL ONLY（gitignored；做完即刪）
├── PROJECT.toml         # LOCAL ONLY（gitignored；proj 照讀）
└── .claude/             # LOCAL ONLY（gitignored）：settings.local.json 等累積權限；無 kit 檔
```

### 5.2 `kit.toml`（tracked，工具中立）

```toml
# kit.toml — multi-agent-kit project marker. Kit hooks and git guards activate only when this file exists.
kit = 5                    # schema major; `kit doctor` validates
visibility = "public"      # public | private — selects the guard tier; `kit audit` verifies against GitHub
license = "MIT"            # MIT | CC-BY-4.0 | none
readme_lang = "en"         # en (default) | zh-TW — audit language check; owner names exceptions here
protected = [              # no-touch globs (repo-relative, `*` crosses `/`). PreToolUse hook hard-denies Edit/Write.
  # one entry per line, no inline comments on entry lines — a bash hook parses this block
  "supabase/migrations/*",
]
```

【D7】protected paths 放 `kit.toml` 而非獨立 `.kit/protected-paths`：一個檔同時是標記與
真相，不會各自漂移；Codex 讀得到；AGENTS.md 的 constraints 文字指向它。代價是 hook
要 sed 解析 TOML 陣列——以「一行一項、不准行內註解」的限制換可靠度，`kit doctor` 用
tomllib 驗證並拒絕違規格式。

### 5.3 `AGENTS.md` / `CLAUDE.md`

AGENTS.md 章節 = v4 CLAUDE.md 範本去掉 kit 樣板：`## Project goal` / `## Stack`（含可
直接複製的 test 指令）/ `## File layout` / `## Constraints`（prose；路徑型禁區要同步進
`kit.toml [protected]`，一句話說明）/ `## Conventions` / `## Where to look`（只列專案內
檔案：`docs/specs/`、`docs/DEVELOPMENT.md`）。**不得**出現本機路徑、成本、個資。

CLAUDE.md stub（整檔）：

```markdown
@AGENTS.md

<!-- Claude-specific notes only (optional). Workflow / review / dispatch rules come from the kit plugin — do not paste them here. -->
```

`@import` 是文件化語法（相對路徑、最多四層）；Claude Code ≥ 2.1.277 也會在沒有 CLAUDE.md
時原生讀 AGENTS.md，但 owner 決定 4 要求 stub 存在，且 stub 讓「Claude 專屬段」有地方放。

## 6. 模板清單（B）

| 模板 | 內容要點 |
|---|---|
| `AGENTS.md` | §5.3；佔位符附範例（沿用 v4 範本的範例句） |
| `CLAUDE.md` | §5.3 stub |
| `kit.toml` | §5.2 |
| `README.public.md` | **RepoBox 食譜**（brief §4）：H1 只放名字 → 兩句對「你」說的 lede（在哪遇到它、唯一動作、會得到什麼）→ hero GIF/圖（完整句 alt）→ 4 條 `**Label**: 一句具體話` → 桌機 72% + 手機 24% 截圖（raw HTML `<p><img width>`）→ 一行 caveat → `## How it works`（5 行 ASCII 資料流 + 一行「no server / no DB」類陳述）→ `## Install`（前置一句、編號步驟、UI 標籤粗體加 →、最少終端）→ `## Privacy & security`（信任模型條列）→ `## License`（一行 + credits）。**刻意不放**：stack 清單、badges、dev 指令、env 表、檔案佈局、roadmap、TOC、emoji 標題、AI prompt。語氣：對陌生人、短直述句、無第一人稱。**無 UI 的 library/CLI 後備**：hero 換終端錄影（asciinema → GIF）或一個 fenced「example output」區塊；截圖對換成「輸入 → 輸出」兩個 code block；其餘章節不變 |
| `README.private.md` | H1 → 一段「這是什麼、給誰」→ `Development: see docs/DEVELOPMENT.md` → 可選 License 行。≤15 行 |
| `DEVELOPMENT.md` | 吸收舊 README 範本：30 秒重啟、指令表、env vars 表（只列變數名與用途，**不列值**）、部署、「半年後最容易忘的事」、文件地圖。**去掉** AI 接手 prompt 與 kit 更新段。英文預設 |
| `LICENSE.MIT` / `LICENSE.CC-BY-4.0` | 全文；`kit init` 填年份與 GitHub handle。內容型 repo 選 CC-BY-4.0 |
| `gitignore` | 統一版，見下 |
| `PROJECT.toml` | v4 同款（local-only） |
| `mise.toml` | v4 同款 |
| `github/workflows/kit-guard.yml` | §7.6 |
| GitHub Actions 慣例（寫進 AGENTS.md 範本 Conventions 段） | 頂層 `permissions: contents: read`，job 層按需升權；`uses:` 一律 40 字元 SHA 加 `# vX.Y.Z` 尾註；`kit audit` 執法 |

統一 `.gitignore` 的 kit 區塊（標記包住，`kit migrate` 可冪等替換；標記外是專案自己的）：

```gitignore
# >>> kit v5 (managed block — edit outside the markers) >>>
.claude/
.codex/
.superpowers/
CLAUDE.local.md
PROJECT.toml
docs/LESSONS.md
docs/plans/
docs/superpowers/plans/
docs/decisions/
*.local.toml
.env
.env.*
!.env.example
.DS_Store
Thumbs.db
.idea/
*.swp
# <<< kit v5 <<<
```

【D8】公私同一份（owner 決定 2），且 `docs/specs/` 維持 tracked 但由 audit 的隱私掃描
覆蓋——翻公開前不需要清理動作，只需要 audit 綠燈。

## 7. 安全流程（C）：本機 guard

### 7.1 架構

```
git commit / git push（人或 AI，任何 repo）
   │  core.hooksPath = ~/.config/kit/git-hooks   （全域；kit setup 設定）
   ▼
~/.config/kit/git-hooks/pre-commit | pre-push      （shim，kit setup 生成）
   │  KIT_ROOT ← ~/.config/kit/config.toml
   ├─▶ $KIT_ROOT/plugin/guard/pre-commit.sh | pre-push.sh   （bash + git + grep；gitleaks 可選）
   │       ├─ 讀 kit.toml（visibility / allow）—— 沒有 kit.toml 的 repo 也跑「通用層」
   │       ├─ 讀 plugin/guard/privacy-rules.toml（通用規則，shipped）
   │       └─ 讀 ~/.config/kit/privacy.local.toml（個人字面值，local-only）
   └─▶ 鏈到 $(git rev-parse --git-common-dir)/hooks/<name>（repo 自己的 hook，若存在且可執行）
```

shim 要點（實作者注意）：解析 repo 本地 hook 時用 `--git-common-dir`，**不能**用
`--git-path hooks`——後者尊重 `core.hooksPath`，會指回 shim 自己。repo 本地若設了
`core.hooksPath`（husky 類）會**蓋掉**全域設定、guard 靜默失效——這是 audit 的一條
HIGH 檢查（§8），guard 自己無法補救。
（spike 2026-10-19: GO — 隔離 `GIT_CONFIG_GLOBAL` 下 7/7 PASS：commit/push 皆觸發 shim、
`--git-common-dir` 鏈到 repo 本地 hook、linked worktree 內 `--git-common-dir` 回傳主 repo 的
`.git` 絕對路徑且鏈接正確、pre-push stdin 為 `<lref> <lsha> <rref> <rsha>`、shim 開銷中位數 3ms；
反向對照：shim 若改用 `--git-path hooks` 會 exec 自己形成**無限迴圈（commit 卡死）**，不只是靜默略過）

【D10】用全域 `core.hooksPath` 而非每 repo 安裝 hook：它涵蓋「所有 commit，含手動、含
未來 clone 的新 repo」，正是 owner 決定 6 的要求；每 repo 安裝會漏掉新 clone。

### 7.2 規則與 block / warn 表

| # | 規則 | pre-commit（staged diff） | pre-push（pushed range / 推送樹） | 適用範圍 |
|---|---|---|---|---|
| R1 | gitleaks 命中（含 `plugin/guard/gitleaks.toml` 的 kit 補充規則） | **block** | **block** | 所有 repo |
| R2 | 禁推路徑：`.claude/**`、`PROJECT.toml`、`docs/LESSONS.md`、`docs/plans/**`、`docs/superpowers/plans/**`、`docs/decisions/**`、`*.local.toml`、`CLAUDE.local.md`、`.superpowers/**`、`.env*`（除 `.env.example`） | **block**（staged A/C/M/R；刪除放行） | **block**（`git ls-tree -r <local sha>` 整棵樹都查——抓的是**長期 tracked** 的，不只這批新增的） | 有 kit.toml 的 repo（`.env*` 全 repo） |
| R3 | 本機路徑：`/home/<os user>/`、`/mnt/c/Users/<name>/`、`C:\Users\<name>`（user 名來自 `privacy.local.toml` 的 `usernames`） | **block** | **block** | 所有 repo |
| R3b | 其他 `/home/<x>/`（Dockerfile 的 `/home/node` 類） | warn | warn | 所有 repo |
| R4 | 個人字面值 `tier="always"`（uid、bucket、雲端專案名、PAT 描述、個人 email） | **block** | **block** | 所有 repo |
| R5 | 個人字面值 `tier="public-only"`（私人專案名、內部代號） | **block** if `visibility=public` **或 kit.toml 缺／無 visibility**（fail-closed 當公開）；private → 放行 | 同左 | 所有 repo |
| R6 | 非 noreply/example 的 email（通用 regex） | warn | warn | 所有 repo |
| R7 | `/tmp/claude-<uid>/…` 類暫存路徑 | warn | warn | 所有 repo |
| R8 | gitleaks 二進位不在 PATH | **warn**（大字橫幅 + `kit doctor --install`；R2–R7 照跑，它們只需 grep） | **block**（push 是洩漏邊界；修法是一條指令） | 所有 repo |

【D11】pre-commit 對缺 gitleaks 只 warn、pre-push 才 block：commit 是本地可改寫的，
push 不是；把硬閘放在真正的邊界，避免「裝機沒裝好就什麼都不能 commit」。
【D12】R3/R4 公私一律 block：owner 決定 2 的精神（翻公開不需清理）；私人 repo 裡真的
要引用本機路徑時用 `$HOME`/環境變數，或走 bypass。R5 是唯一分公私的規則，因為私人
專案互相引用是正常需求。

False-positive 出口（全部留痕在 diff 裡）：同一行尾 `kit-privacy: allow`；gitleaks 原生
`gitleaks:allow` 與 `.gitleaksignore`；`kit.toml` 的 `[privacy] allow_paths = ["docs/media/*"]`
（整路徑跳過 R3–R7，不跳 R1/R2）。

**字面值例外（修訂 2026-10-19）**：`kit.toml`
```toml
[privacy]
allow_literals = ["owner-cloud-uid"]   # names from privacy.local.toml [[literal]].name — never values
```
- `privacy.local.toml` 每條 `[[literal]]` 必填 `name`（`^[a-z0-9-]{3,40}$`，kit doctor 驗證唯一）。
- 命中 R4/R5 時，若該 repo 的 `kit.toml [privacy].allow_literals` 含該字面值的 `name` → 放行，
  **不分 tier、不分路徑**（owner 已在 tracked 檔明示接受此 repo 暴露該值）；guard 印一行
  `KIT GUARD: literal <name> allowed by kit.toml` 到 stderr（不印值）。
- 名稱出現在 `allow_literals` 但 `privacy.local.toml` 無此名 → guard 忽略並 warn（陌生人機器
  沒有本機清單，不能 fail）；`kit doctor` 在 owner 機器上把未知名稱列為 warn。
- `kit.toml` 列入 Stop gate 的 size-blind 敏感路徑（`SENSITIVE_PATH_REGEX` 加 `kit\.toml`）：
  放寬 `allow_literals` / `protected` 的 diff 必過 review 或 user 之口（kit-evolution「只能加嚴」）。
- audit A2（目前樹）與 A3（歷史）對同一 repo 套同一例外：被豁免的字面值不產生 A2/A3 finding，
  改產生一條 **INFO `A2x literal-exception-in-effect <name>`**，讓報表看得見例外存在。
- CI 層（§7.6）本就不含個人字面值，不受影響。

### 7.3 設定位置

| 檔 | 位置 | 性質 |
|---|---|---|
| 通用規則 | `plugin/guard/privacy-rules.toml`（`[[rule]] id/pattern/action/exclude`） | shipped、public |
| gitleaks 補充 | `plugin/guard/gitleaks.toml`（`[extend] useDefault = true` + kit 自訂） | shipped |
| 個人字面值 | `~/.config/kit/privacy.local.toml`（`usernames = [...]`、`[[literal]] name/value/tier/note`、`emails = [...]`），chmod 600，protect-paths 視為 kit-owned（模型要改 → ask） | **local-only，永不 commit**；`kit setup` 建骨架，初次 `kit audit` 從發現中提議條目 |
| 每 repo 覆寫 | `kit.toml [privacy]`：`allow_paths`（路徑跳過 R3–R7）、`allow_literals`（以 name 豁免 R4/R5 + A2/A3） | tracked、diff 可見 |
| 審計日誌 | `~/.local/state/kit/guard/audit.jsonl`（每次 block / bypass 一行：ts、repo、rule、path、reason） | local |

### 7.4 Bypass（user-only）

`kit guard bypass "<reason>"` → 在 `~/.local/state/kit/guard/bypass-<repo-id>` 寫入
`{expires: now+10min, reason}`；下一次該 repo 的 guard 命中時**單次**消費並寫 audit.jsonl。
`KIT_GUARD=off` 環境變數**不被承認**（模型能在 Bash 前綴它）。`git --no-verify` 是
git 原生繞道，guard 擋不了：對模型由 tool-breaker 擋（§4.5），對人由 audit 事後抓。

### 7.5 速度預算與失效模式

- 實測：gitleaks staged 掃描 0.22s、52-commit 全史 0.27s、667-commit 全史 0.40s；
  grep 層 <0.1s。預算：pre-commit 典型 <1s、pre-push 典型 <3s；pre-push 超過 10s 印
  一行提示但不中止（正確性優先）。
- 失效模式：`config.toml` 缺／`kit_root` 不存在 → shim 印 `KIT GUARD: not configured`
  後 **exit 1（block）**（guard 不存在時不能靜默成功——S6「降級必 fail-loud」）；
  `privacy.local.toml` 缺 → R4/R5 跳過 + warn（通用層照跑）；`git` 非 kit repo 且無
  kit.toml → 只跑通用層；二進位檔一律跳過內容規則；gitleaks 本身崩潰（非 0/1 退出）
  → 視同缺二進位（pre-commit warn / pre-push block）。
- block 訊息固定格式：`KIT GUARD BLOCKED [R4 personal-literal] <path>:<line> — <why>` +
  `fix:` 一行 + `bypass (user only): kit guard bypass "<reason>"`。**不印**被攔到的
  字面值本身（redact）。

### 7.6 CI 層（public repo 選配）

【D14】值得，但只做最薄的一層：GitHub 原生 secret scanning + push protection 已在公開
repo 開啟（API 實查），秘密這塊伺服器端已有；CI 補的是本機 guard 的盲區——其他機器、
網頁編輯、bot commit（機隊有 crawler bot 直接 commit 的 repo）。
`templates/github/workflows/kit-guard.yml`：`permissions: contents: read`；`actions/checkout`
SHA 釘、`fetch-depth: 0`；步驟一 gitleaks（gitleaks-action SHA 釘；若個人帳號授權條款
不合，退回以 sha256 驗證的釘版二進位）；步驟二 ~15 行 bash：禁推路徑存在於樹 + 通用
隱私 regex（**不含**個人字面值——那份清單不出本機）。私人 repo 不裝（Actions 分鐘、
價值低）。

## 8. 機隊 audit（`kit audit`）

一條指令、每 repo 一列、每條檢查一個 finding。掃描集合 = `[audit].root` 第一層含 `.git`
的目錄 ∪ `gh repo list <owner>`（遠端存在但未 clone 的只跑 GitHub 層；`--fetch-remote`
會 clone 到 `~/.cache/kit/audit-clones/` 補跑歷史層），再套 `exclude` globs。

| ID | 檢查 | 資料來源 | 嚴重度 |
|---|---|---|---|
| A1 | gitleaks 全史命中 | `gitleaks git --redact -f json` | public **CRITICAL**；private **HIGH** |
| A2 | 個人字面值在**目前樹**（tracked 檔）；`kit.toml [privacy].allow_literals` 列名者不計，改報 INFO `A2x` | `git grep -F -i -f <literals>` | public **HIGH**；private（always 層）**MEDIUM** |
| A3 | 個人字面值只在**歷史**；同 A2 例外 | `git log -p --all` 流式比對 | public **MEDIUM**（待 history rewrite）；private LOW |
| A4 | 禁推路徑被 tracked（§7.2 R2 清單） | `git ls-files` | public **HIGH**；private MEDIUM |
| A5 | 通用隱私 regex 命中目前樹（本機路徑、email） | grep | public MEDIUM；private LOW |
| A6 | `kit.toml` visibility ≠ GitHub 實況，或 kit 專案缺 kit.toml | `gh api repos/{o}/{r}` | **HIGH** |
| A7 | secret scanning / push protection 關閉 | `security_and_analysis` | public **HIGH** |
| A8 | Dependabot alerts 關閉 | `GET vulnerability-alerts`（204/404） | MEDIUM |
| A9 | Actions 預設 workflow 權限 = write | `actions/permissions/workflow` | **HIGH** |
| A10 | workflow `uses:` 非 40 字元 SHA | 解析 `.github/workflows/*.yml` | 該 workflow 有 write 權限 → **HIGH**；否則 MEDIUM |
| A11 | workflow 缺頂層 `permissions:` | 同上 | MEDIUM |
| A12 | osv-scanner：lockfile 有 CRITICAL/HIGH 漏洞 | `osv-scanner scan source --format json`（機隊 lockfile：pnpm-lock / package-lock / uv.lock） | **HIGH**（有部署的專案）；MEDIUM（status ≠ active/idle，讀本機 PROJECT.toml） |
| A13 | LICENSE 缺或 0 bytes，或與 GitHub 偵測不符 | 檔案 + `licenseInfo` | public MEDIUM |
| A14 | GitHub description / topics 缺 | `gh api` | public LOW |
| A15 | README 陌生人安全：H1 不只名字、含「私人 repo／written for future me」類標記、CJK 比例 >10% 且 `readme_lang=en`、含本機路徑、emoji 標題、缺 `## Install`/`## License` | 啟發式 | public MEDIUM（標記類）／LOW（格式類） |
| A16 | repo 本地 `core.hooksPath` 蓋掉全域 guard | `git config --local core.hooksPath` | **HIGH** |
| A17 | `.gitignore` 缺 kit 區塊 / `.claude` 未忽略 | 檔案 | MEDIUM |
| A18 | 分支保護／ruleset 缺（預設分支） | `gh api rulesets` | LOW（單人機隊；只提示） |

輸出：終端表（repo × 最高嚴重度 × 計數，`--verbose` 展開每條 finding：ID、路徑:行、
redacted 片段、修法一行）；`--json`（給下次比對 diff）；`--html`（自包含，沿用 `proj html`
的開瀏覽器行為，**不**合併進 `bin/proj`——彙總工具的爆炸半徑是全體來源，kit 的
LESSONS 已記過一次）。退出碼：任一 CRITICAL/HIGH → **2**；執行錯誤 → 1；否則 0。
Baseline：`--baseline <json>` 只報新增 finding（給 rollout 期間逐步清零用）。
速度：以 13 個 clone、每個 ≤1s gitleaks + ≤2s osv 估，全機隊 <1 分鐘（osv 需網路）。

## 9. 遷移（D）：`kit migrate <dir>`

前提：`kit setup` 已跑（plugin 啟用、guard 就位）。預設 **dry-run**（印出會做的每一步與
diff），`--apply` 才動手，`--commit` 才 commit。全程冪等：每步先檢查狀態，重跑得到
「nothing to do」。

1. **前置檢查**：工作樹乾淨（否則停，`--allow-dirty` 覆寫）；偵測 v4（`.claude/kit-version`
   存在）或已 v5（`kit.toml` 存在 → 只補缺項）。
2. **安全副本**：把 `.claude/`、`PROJECT.toml`、`docs/LESSONS.md`、`docs/plans/`、`docs/superpowers/plans/` 複製到
   `~/.local/state/kit/migrate-backup/<repo>/<ts>/`。理由：kit 自己的 LESSONS 記過
   「untrack + gitignore 後經 rebase/checkout，被忽略的檔會被舊 tracked 版本靜默覆蓋」。
   這是本機一次性保險，不違反「LESSONS 不備份」的意圖（不進 git、不上雲）。
3. **kit.toml**：由 `gh api` 取 visibility（離線 → `public`，fail-closed）；license 由
   LICENSE 檔推斷；`protected` ← `.claude/protected-paths`（`#` 註解行原樣搬進陣列、
   glob 一行一項）。
4. **AGENTS.md ← CLAUDE.md**：剝離三段 kit 樣板（開頭 `> CLAUDE.md（kit v4.x）` 引言、
   `**同步執法**` 段、`## 檔案路由` 表及其後括號段），其餘內容原樣成為 AGENTS.md；
   `**同步執法**` 以一句「路徑型禁區同步進 `kit.toml [protected]`」取代。結構辨識
   失敗（找不到任何樣板標記）→ 整份搬進 AGENTS.md 並標 `needs-review`，**絕不丟內容**。
   CLAUDE.md 改寫成 stub；若原檔有非範本章節（偵測：不在 goal/stack/layout/constraints/
   路由之列的 `##`），保留在 stub 的 Claude 專屬段。
5. **`.gitignore`**：以標記區塊冪等寫入 §6 的 kit 區塊；移除 v4 的「`.claude/` 刻意
   track」註解塊。
6. **untrack**：`git rm -r --cached .claude PROJECT.toml docs/LESSONS.md docs/plans docs/superpowers/plans docs/decisions`
   （存在者）；磁碟檔保留。
7. **清 `.claude/` 的 kit 檔**：刪 `rules/ hooks/ agents/ skills/ docs/ kit-version protected-paths`
   （plugin 接管；留著會雙重載入）；`settings.json` → 剝掉 kit 的 hooks 區與 kit 權限
   基線，殘餘（使用者累積的 allow）合併進 `settings.local.json`，空了就刪。**雙重觸發
   防呆**：步驟 7 與 3 同一次 apply 完成，中途失敗時 §4.2 的 `kit-version` 讓位閘保護。
8. **補檔**：LICENSE（public 且缺 → MIT 全文）、`docs/DEVELOPMENT.md` 骨架（private）、
   `docs/specs/` 不動。
9. **README 不自動改寫**（內容工作）：印出 bootstrap prompt——「依 AGENTS.md 與
   docs/，用 kit 的 README 食譜（public/private）重寫 README.md，dev 內容搬 docs/DEVELOPMENT.md，
   不得含本機路徑／成本／個資；先給我看 diff」。
10. **commit**（`--commit`）：`chore(kit): migrate to kit v5 — untrack .claude, add AGENTS.md + kit.toml`。
    這個 commit 會過 guard：R2 只擋新增/修改，刪除放行。
11. **報告**：每步 done/skip/needs-review；提醒「歷史裡仍有 PROJECT.toml/LESSONS/plans，
    history rewrite 見 §12 步驟 6」。

`init.sh --update` 使用者的過渡：v5 的 `init.sh` 變成 stub——印「v5: run `kit setup` once,
then `kit migrate <dir>`」並 `exit 2`；v5.1 刪除。

## 10. Kit repo 衛生（E）

- 匿名化：本機 grep 證實私人專案名散佈於 `ARCHITECTURE.md`、`DEFENSES.md`、`README.md`、
  `docs/LESSONS.md`、六份 design-history、`tests/evals.md`、`tests/hooks-smoke.sh`、
  `tests/proj-smoke.sh`、`tool-breaker.sh` 註解、`project-manifest.md`。處置：建立
  **本機**對照表（`privacy.local.toml` 的 `[[literal]] value=<私人名> tier=public-only
  alias=proj-a`）；一次性腳本 `tests/tools/anonymize.py` 讀對照表做替換（腳本不含名字），
  替換後的 HEAD 由 `kit audit` A2 驗證為零命中。design-history「歷史不回改」慣例在此
  讓位於隱私——在 `design-history/README.md` 加一行說明「2026-10 匿名化」。
- 成本與事故：ARCHITECTURE/DEFENSES 中的「收據」保留**日期與模式**，刪專案名、金額、
  個資；kit 的 `docs/LESSONS.md` 整檔 untrack（owner 決定 3）。
- `templates/README.example.md` → 虛構專案（例：「Lanternfish — 把 RSS 變成每週一封信
  的小工具」），依 RepoBox 食譜寫滿，作為食譜的活範例。
- `LICENSE` 寫入 MIT 全文；`PROJECT.toml` untrack；`.claude/` untrack（kit 自己的開發
  settings 本地化）。
- kit repo 自己放一份 `kit.toml`（`visibility=public`），所以 guard 對它同樣執法——
  包括擋 `.claude/` 與 `tests/fixtures` 裡任何 `.claude/` 路徑（§11 的 fixture 因此
  改為執行期生成）。
- History rewrite 排在 v5 之後（§12），本設計只保證 HEAD 乾淨。

## 11. 測試策略

| 套件 | 範圍 | 關鍵場景 |
|---|---|---|
| `tests/plugin-validate.sh`（新） | `claude plugin validate ./plugin --strict`；`plugin.json.version == VERSION`；marketplace.json 指向 `./plugin`；`hooks.json` 每個 command 檔存在且可執行；rules 每段 ≤9,500 chars、總 bytes ≤ 棘輪 cap | 無 claude CLI 的 CI 跳過 validate、其餘照跑 |
| `tests/hooks-smoke.sh`（改） | 路徑改 `plugin/hooks/`；`run_hook` 多傳 `CLAUDE_PLUGIN_ROOT`；fixture repo 產生時寫 `kit.toml` | **新增啟用閘矩陣**：無 kit.toml → 五支 hook 全 exit 0 且 stdout 空；有 kit.toml + `.claude/kit-version` → 讓位且 stderr 含提示；`KIT=off` → 靜默。protected 改讀 kit.toml 的 RED-GREEN（含 `#` 行、行內註解違規時 `kit doctor` 失敗）。tool-breaker 新增 `--no-verify`/`KIT_GUARD=` deny 的正反例（`git commit -m "no --no-verify here"` 不擋——引號中和沿用 v4.10 契約）。既有 ~1,200 行斷言全數保留 |
| `tests/inject-rules-smoke.sh`（新） | 兩段輸出為合法 JSON、含標頭、合計等於 rules 檔內容；非 kit 目錄零輸出 | |
| `tests/guard-smoke.sh`（新） | mktemp 建 repo + bare remote；以 `GIT_CONFIG_GLOBAL` 指到假 config（`core.hooksPath` → 測試用 shim）；假 `HOME` 放 privacy.local.toml 測試清單 | R1 假 token（gitleaks 自帶規則可辨的格式）block；R2 staged `.claude/x` block、刪除放行、pre-push 抓長期 tracked 的 PROJECT.toml；R3 使用者路徑 block、`/home/node` 僅 warn；R5 public block / private 放行 / 無 kit.toml 當 public；`kit-privacy: allow` 放行；`[privacy] allow_literals` 以 name 放行 R4（以值寫入 kit.toml 不放行、未知 name 只 warn）；bypass 單次且寫 audit.jsonl；缺 gitleaks（PATH 清空）→ pre-commit exit 0 + warn、pre-push exit 1；鏈到 repo 本地 `.git/hooks/pre-commit`；`--git-path` 陷阱的回歸斷言 |
| `tests/migrate-smoke.sh`（新） | v4 fixture **執行期生成**（從 `plugin/` 複製成 v4 佈局 + v4 風格 CLAUDE.md + protected-paths + 改過的 settings.json），不 track 任何 `.claude/` | dry-run 零變更（tree hash 相等）；apply 後：kit.toml 內容、AGENTS.md 含原 constraints 逐字、CLAUDE.md stub、`git ls-files` 無禁推路徑、磁碟檔仍在、settings.local.json 含使用者 allow 而無 kit hooks；重跑 → nothing to do；無樣板標記的 CLAUDE.md → needs-review 且內容零遺失 |
| `tests/audit-smoke.sh`（新） | `--offline <fixture>`：錄好的 `gh api` JSON + 本機 fixture repo | 每個 A1–A17 至少一個命中與一個不命中；退出碼 2/0；`--baseline` 只報新增；exclude glob 生效；HTML 含每個 finding ID |
| `tests/smoke.sh`（改） | 改測 `kit init`：模板落檔、no-clobber、kit.toml、LICENSE 年份、bootstrap prompt；rules 預算改讀 `plugin/rules/` | |
| `tests/proj-smoke.sh` | 不動 | |
| 手動／eval（`tests/evals.md` 新增） | (a) 真實 session：非 kit 目錄啟動 → `/context` 無 KIT_RULES；kit 專案 → 有兩段；(b) subagent 可見性：派一個 Agent 問它是否看到 KIT_RULES，記錄結果決定 §4.3 (c)；(c) `claude plugin eval` 對 `/kit:judgment`、`/kit:verify-signals` 的觸發準確度（選配） |

發佈前清單：全部 smoke 綠 → `claude --plugin-dir ./plugin` 跑一輪真 session（Stop gate
擋一次、`/kit:review` 寫 marker 放行）→ `instruction-audit.md` 例行審計（rules 改寫句子後
必跑）→ Codex review 設計決策 D1–D14。

## 12. 機隊 rollout 順序

0. **Spikes（修訂 2026-10-19）**：動手前先用拋棄式 plugin 骨架驗證 (a) `--plugin-dir` /
   本地 marketplace 載入 + SessionStart `additionalContext` 注入完整送達、非 kit 目錄零輸出、
   `claude plugin validate --strict` 對 `rules/` 的態度、`SubagentStart` 是否吃
   `additionalContext`；(b) 以 `GIT_CONFIG_GLOBAL` 隔離驗證全域 `core.hooksPath` shim 對
   commit/push 皆觸發、以 `--git-common-dir` 鏈到 repo 本地 hook、worktree 下仍正確。
   每個 spike 有 go/no-go；no-go 走 §13 的後備設計並回寫本檔。Codex 審查意見在 spike 之後
   折入 plan。

   | spike | 結果 | 採用路徑 |
   |---|---|---|
   | 0.1 注入（SessionStart / SubagentStart / validate） | GO：9,401 chars 完整送達、非 kit 目錄零注入；SubagentStart 吃 `additionalContext`；`rules/` 過 `--strict`（需 `author`） | §4.3 兩段 + (c) 第三個 SubagentStart entry；保留 `plugin/rules/` |
   | 0.1 本地 marketplace | GO：執行期 `CLAUDE_PLUGIN_ROOT` = 來源目錄（`installPath` 雖指向 cache 複本） | D2 本地 marketplace 就地載入；不得以 `installPath` 推 kit_root；owner 在真實 user scope 複核一次 |
   | 0.2 全域 hooksPath shim | GO：7/7 PASS（含 worktree、pre-push stdin、<50ms） | §7.1 原設計；`--git-common-dir` 為必要（`--git-path` 會無限迴圈） |

1. **kit repo**：在分支完成 v5（plugin/、cli/、tests、模板、匿名化、LICENSE）；smoke 全綠；
   Codex 審；合併；tag v5.0.0。
2. **本機**：`kit setup`（本地 marketplace、權限基線、hooksPath、工具安裝、privacy.local.toml）
   → `kit doctor` 全綠 → 在 `$HOME` 開一個 claude session 確認零 kit 輸出。
3. **基線 audit**：`kit audit --json > baseline.json`（預期大量 finding）；把 A2/A3 發現的
   字面值整理進 `privacy.local.toml`（此時 guard 才真正「認得」要擋什麼）。
4. **kit repo 自己遷移**（dogfood：`kit migrate .`）→ 公開 pilot 一個小 repo（README 寫著
   「私人 repo」卻公開的那個是最佳樣本：遷移 + README 食譜重寫 + LICENSE 一次驗證）。
5. **其餘公開 repo**（洩漏面優先）→ 私人 repo。**等其他 agent 正在編輯的四個 repo 完工
   再動它們**。每個 repo：`kit migrate --apply --commit` → AI session 跑 README/DEVELOPMENT
   bootstrap → `kit audit <name>` 無 HIGH → push（guard 首戰）。
6. **History rewrite**（v5 後、另立 runbook）：公開 repo 中歷史含本機路徑／PROJECT.toml／
   LESSONS 的（基線 audit 的 A3/A4 清單），`git filter-repo` 移除路徑 + 字面值替換；
   **特別風險**：被他人以 commit SHA 釘住的 reusable workflow（repobox 的 analyze.yml
   由 library template 以 40 字元 SHA 引用）——rewrite 後 SHA 全變，須同步更新 template
   與自己的 library repo，並在 rewrite 前公告。rewrite 後跑 `kit audit` 驗 A3 歸零。
7. **CI 層**：公開 repo 加 `kit-guard.yml`（SHA 釘）；確認一次 push 觸發成功。
8. **v5.1 清理**：刪 `init.sh` stub；評估 /tmp → `~/.local/state` 的狀態搬家；若 subagent
   注入可行則加入。

## 13. 開放風險與未驗證項

| # | 風險／未驗證 | 影響 | 後備設計 |
|---|---|---|---|
| 1 | 注入上限 10,000 chars：文件說有，2.1.303 實測 13.9K 完整送達 | 未來版本若執法，單段 >10K 會被截 | 兩段各 <9.5K，smoke 執法（spike 2026-10-19: GO — headless `claude -p --plugin-dir` 下單段 9,401 chars 完整送達（transcript attachment 長度 9,401、結尾 sentinel 在 API request 內）；無 `kit.toml` 的空目錄與 `$HOME` 零注入、模型答 NONE） |
| 2 | hook 注入的 rules **不進 subagent**（未實測，依文件推斷） | 實作型 subagent 少了 kit-workflow/judgment 常駐文字 | dispatch 模板 inline（既有）+ AGENTS.md 為 memory + 驗證 SubagentStart 注入（spike 2026-10-19: GO — 實測 SessionStart 注入在 subagent transcript 0 命中（推斷成立）；`SubagentStart` 的 `additionalContext` 以 system-reminder 送進 subagent → 採 §4.3 (c)，Task 2.2 做第三個 entry） |
| 3 | 本地路徑 marketplace「就地載入」在本機未實測 | 若其實會複製，改原始碼不即時生效 | GitHub marketplace + `kit update`；shim 從 config 解析 kit_root，與 plugin 載入方式無關（spike 2026-10-19: GO — directory 型 marketplace：`installed_plugins.json` 的 `installPath` 指向 cache 複本，但執行期 `CLAUDE_PLUGIN_ROOT` = 來源目錄；改 rules、hook 腳本、`hooks.json` 皆於下個 session 生效、不需 update。注意 cache 複本會過期，任何程式不得以 `installPath` 當 kit_root。以隔離 `CLAUDE_CONFIG_DIR` 驗證，真實 user scope 待 owner 複核） |
| 4 | `claude plugin validate --strict` 對未知目錄 `plugin/rules/` 的態度未知 | 可能 warning | 改名 `context/` 不影響設計（spike 2026-10-19: GO — `--strict` 對 `rules/` 無 warning，保留 `rules/`；唯一 warning 是 plugin.json 缺 `author`，--strict 下即失敗 → plugin.json 必含 `author`） |
| 5 | gitleaks-action 對個人帳號的授權條款 | CI 層步驟一可能失敗 | 釘版二進位 + sha256 |
| 6 | repo 本地 `core.hooksPath`（husky）蓋掉 guard | 該 repo 零 guard | audit A16 HIGH；pre-push 的 CI 層兜底（public）（spike 2026-10-19: 風險成立 — repo 本地 `core.hooksPath=.husky` 時 shim 不執行、無任何訊息；A16 維持） |
| 7 | `git --no-verify` / 其他機器 / 網頁編輯 | 繞過本機 guard | tool-breaker 擋模型；CI 層；audit 事後 |
| 8 | 權限基線殘餘：`git log --output=`、`git diff --output=` 可寫檔 | 低（寫文字檔） | 接受；記入 DEFENSES 誠實條款 |
| 9 | monorepo 子目錄啟動（無 kit.toml 在 cwd） | hooks 靜默 | 不支援，文件化 |
| 10 | 匿名化後 design-history 的「歷史快照」價值下降 | 考古可讀性 | README 註記；對照表本機保存 |
| 11 | `kit.toml` 的 visibility 與 GitHub 漂移（翻公開忘了改） | R5 用錯層級（private 放行） | audit A6 HIGH；`gh` 可用時 pre-push 順手比對（有網路才做，不阻塞） |
| 12 | 兩個 SessionStart rules entry 在 compact 後重注入 ≈ v4 的固定稅，但 resume 也注入 | 多一次 ~13K chars | 與 v4 等價（rules 本就常駐），接受 |
| 13 | gitleaks/osv-scanner 目前只在暫存目錄、未入 PATH | 裝機前 guard 走 R8 路徑 | `kit doctor --install` 釘版安裝是 setup 的一部分 |

## 14. 設計者決定彙整

| ID | 決定 | 一行理由 |
|---|---|---|
| D1 | plugin 名 `kit`、marketplace 名 `multi-agent-kit`、產品目錄 `plugin/` | skill 叫法最短；名稱不互撞；`.claude/` 徹底退出產品位置 |
| D2 | owner 用本地路徑 marketplace（就地載入），陌生人用 GitHub marketplace | 文件化的零摩擦開發迴圈；`${CLAUDE_PLUGIN_ROOT}` 穩定 |
| D3 | skills 改名為 `review` / `skip-review` / `dispatch` / `research-first` | 命名空間下 `/kit:kit-review` 疊字；搬家本就要改所有引用 |
| D4 | judgment-matrix 與 verification-signals 轉成 skills | 用原生 progressive disclosure 取代 CLAUDE.md 路由表 |
| D5 | skills/agents 不做目錄閘控，只有 hooks 閘控 | on-demand 元件在非 kit 目錄的成本是幾行清單 |
| D6 | rules 以 SessionStart 注入，拆兩段，雙單位預算 | plugin 無法出貨 rules；`~/.claude/rules` 無法靜默；對 10K 上限兩種實況都安全 |
| D7 | 標記 + protected 合一在 `kit.toml` | 標記與真相不漂移；工具中立；格式受 doctor 驗證 |
| D8 | 公私同一份 .gitignore，specs tracked 但受 audit 掃描 | 翻公開零清理（owner 決定 2 的延伸） |
| D9 | `/tmp` 狀態檔不搬 | 不動 1,259 行測試；已接受的限制；列 v5.1 |
| D10 | 全域 `core.hooksPath` + shim 鏈 repo 本地 hook | 涵蓋所有 commit 含新 clone；不破壞既有 hook |
| D11 | 缺 gitleaks：pre-commit warn、pre-push block | 硬閘放在洩漏邊界，不卡本地工作 |
| D12 | 本機路徑與 always 層字面值公私一律 block；只有私人專案名分公私 | 翻公開零清理 vs 私人專案互引的正常需求 |
| D13 | tool-breaker 對模型 deny `--no-verify` / `KIT_GUARD=` / 改 hooksPath | 模型的繞道只能是留名的 `kit guard bypass` |
| D14 | CI 層只做公開 repo、只做最薄一層（gitleaks + 通用規則 + 禁推路徑） | 補本機 guard 盲區；個人字面值不出本機；秘密伺服器端已有 push protection |
| D15 | `kit` CLI 用 Python 3.11+ 純標準庫；guard 與 Claude hooks 維持 bash+jq+git | 與 proj 同底線；commit 路徑零 Python 啟動成本與依賴 |
| D16 | audit 獨立於 `bin/proj`，只共用 HTML 開啟行為 | 彙總工具的爆炸半徑是全體來源（kit LESSONS 收據） |
| D17 | migrate 預設 dry-run、拒絕髒樹、先做本機安全副本 | 「絕不遺失使用者內容」+ kit LESSONS 的 rebase 覆蓋收據 |
| D18 | README 重寫交給 AI session（migrate 只印 prompt） | 內容工作不該由腳本猜；食譜 + AGENTS.md 已給足約束 |
| D19 | 權限基線只保留 5 條 read-only git/ls，刪 `Bash(timeout *)` | wrapper 已由 Claude Code 剝除；殘餘風險已記 |
| D20 | rollout：kit 自身 → 一個公開 pilot → 其餘公開 → 私人；history rewrite 之後另做 | 洩漏面優先；SHA 釘住的 reusable workflow 需要協調 |

---

*本檔寫於 v5 實作前。實作偏離本檔的任何一條 D 決定，需在 PR 說明中引用 ID 並給理由；
Codex review 以本表為核對清單。*
