# Defenses: 這套 kit 在 Prompt / Context / Harness 三層做了哪些防護

> 條列式清單。回答一個問題:**當驅動這套 kit 的是一個較弱、或長 session
> 後已經疲勞/迷航的模型時,哪些機制在物理上、程序上、措辭上擋著它不出事?**
> 設計依據見 `docs/harness-diagnosis.md`(三大失敗場景 → 三個物理痛點),
> 演進脈絡見 `ARCHITECTURE.md`。本檔是清單,那兩份是「為什麼」。

## 分層原則(先讀這段,清單才有座標)

防線分三層,強度**由弱到強**——這也是本檔的排列順序:

| 層 | 載體 | 強度 | 失效條件 |
|----|------|------|---------|
| **Prompt** | rules / 模板 / 每輪注入的措辭 | 靠模型當下讀得進、記得住 | 模型迷航後效力遞減 |
| **Context** | 誰讀什麼、context 怎麼不膨脹、compact 後怎麼重錨定 | 節流 + 重錨,延緩迷航 | 仍靠模型配合派工 |
| **Harness** | hooks / Stop gate / 檔案所有權 | **deterministic,完全不靠模型記憶** | 只有 Bash 邊門與 /tmp 揮發 |

**核心工程判準**(v4.0 起明文化):*能用 hook 擋的不靠 rules,能用 rules
說清楚的不寫進 CLAUDE.md。* 評估任何防線先問一句:「這條被違反時,能被
物理偵測嗎?」不能的話,它的強度上限就是模型當下的清醒程度——所以核心
防線全部做成 hook,rules 只承載 hook 做不到的判斷。

---

## 一、Prompt engineering 防護(措辭層:寫進 model context 的規則與模板)

六份 `plugin/rules/`(v5 起由 SessionStart hook 注入;v4 為 `.claude/rules/`)每個 session 自動載入,是固定的 context 稅,總量由
smoke test 把關(cap 20480B,v4.9 起附棘輪公式:瘦身後下修至實際值 +5%、
不高於舊 cap)。

- **判斷八條**(`kit-judgment.md`,採自 fable-soul MIT 蒸餾)——補**認知性
  失敗**:目標≠指定修法、一句話機制先於動手、verified/changed-but-unverified
  二分、stale-green reset(改動後先前的綠燈作廢)、證據勝過記憶、量測代替
  hedge、給判斷不給菜單、先確認再舉報。每條在 Haiku 級模型上做過 RED-GREEN
  行為測試(收據 `tests/evals.md`)。**藉口對照表 + Red Flags 於 v4.9 降級**
  至 judgment-matrix R5(隔離成對 A/B 證明八條 + 每輪 digest 足以承載,
  B≥A;回升觸發 = 真實 session 再犯入 LESSONS)。
- **每輪 KIT_JUDGMENT digest**(`classify-task.sh`,UserPromptSubmit)——
  每個非空 prompt 注入一行判斷提醒(done-claim 要證據、可驗證主張不 hedge、
  未確認的問題不是 finding、綠燈後的改動作廢驗證)。**確定性 re-fire,
  不依賴模型記得自查**。原案掛 Stop hook 進不了 model context,移到
  UserPromptSubmit 才真的送達。
- **派工三件套模板**(`/kit-dispatch` skill)——把「目標與背景 / 驗收條件 /
  回報格式」做成填空,弱指揮官照抄也能派出合格的工。模板 inline 判斷句
  (subagent 只繼承 session 啟動時的指令快照,是弱執行員規則唯一保證送達
  的載體);新增驗收 read-back 模板,附**四種造假模式清單**(無證據宣稱、
  跳過的檢查、發明的路徑/數據、被弱化的斷言)。
- **classify-task 只認明確修飾語**——移除關鍵字啟發式(button→small、
  refactor→large 判斷力不如模型本身)。只認祈使句 `直接做`/`完整流程`,
  其餘一律交給模型自判。**harness 不搶模型比它強的判斷**。v4.3 加
  **描述語境濾網**:先遮罩「頻率/進行式標記 + 觸發詞」(一直在走完整
  流程、keeps running the full review)再比對——描述工作流的句子不是
  指令(2026-07-10 實際誤觸收據見 tests/evals.md)。
- **Workflow sizing 反偏壓**(`kit-workflow.md`)——給小任務可操作判準
  (≤4 檔不計測試檔、無新依賴、不碰 schema/auth/payment/constraints → 直接做),
  並依 superpowers 自己承認的優先權(專案指示 > skills)明文解除小任務的
  brainstorming/TDD 強制觸發。防的是強觸發規則把瑣事拉進全套流程。
- **主導模型/effort 配置提案**(`kit-workflow.md`,v4.3)——feature 級
  以上計畫送簽核時必附各 phase「主導模型 + effort + 一句理由 + 卡關
  升級條件」,phase 交界一行提醒「要切請 /model」。純建議、user 執行
  ——讓成本可見,把「哪段可以用便宜檔」的決策交回 user 手上。
- **re-review 範圍收斂**(`kit-workflow.md`,v4.5)——round 1 審全集,之後
  只審 fix delta +「fix 改動的下游」(呼叫端=stale-green 的正門)+ findings
  碰過的碼;**不要每輪把 reviewer 指向整條分支**——重掃已審舊碼會挖出新
  角度,輪數自我繁殖(收據:3 個小 UI 需求走成 6 輪 review/87 分鐘,
  2026-07-11)。敏感路徑每輪維持全集。
- **註解紀律**(`kit-workflow.md` + dispatch 模板 2/3,v4.5)——代碼的讀者
  是**未來的 AI session**,不是人:它讀 code 比讀散文快,敘述性註解是純
  噪音。只寫代碼顯示不了的四類(不變量/外部約束、跨檔耦合、非顯然 why、
  附日期收據),辯護性註解歸 commit message/LESSONS。防的是「每次寫 code
  都產生大量沒人讀的註解」(user 2026-07-12 逐字回報)。
- **規則變更紀律**(`kit-evolution.md`)——改 kit 規則前先查覆蓋(已有條目
  = 規則被無視,不是缺席)、要 RED-GREEN 收據(拿不出失敗證據 = 不知道
  在修什麼,不加)、逐字記藉口(paraphrase 會丟觸發詞)、rules/ 20KB 總量
  預算。防的是「模型以優化名義把規則越改越軟」。
- **判斷檢核表**(`plugin/skills/judgment`,需要時才讀)——換路徑
  信號(R1)、完成判準(R2)、熔斷提問時機(R3)、品味不拍板(R4),
  每條附正例反例。R3/R4 觸發條件明文**優先於** kit-judgment 的「直接做」傾向。
- **驗證信號注入**(`plugin/skills/verify-signals`,需要時才讀,v4.2
  起,v4.10 擴至八節)——「迴圈裡缺便宜驗證信號」的高風險領域:UI 沒截圖
  =視覺上未驗證(S1)、schema 每欄要有現存讀取路徑(S2)、bug 連環卡後
  交接去假設化(S3)、SaaS 引入必附實查成本卡且 user 拍板(S4)、業務邏輯
  不得只能透過 UI 觸達(S5)、**驗證器先紅過才可信/零與死可分/降級必
  fail-loud**(S6)、**驗證終點=user 可見面+觀察層閉環+測試階梯**(S7)、
  **不可逆操作四要件前置閘**(S8)。S6-S8 收據=機隊 13 專案 85 條 LESSONS
  聚類(2026-08-02)。kit-judgment 通用證據紀律在領域層的實例化。

## 二、Context engineering 防護(不可再生資源:誰讀什麼、怎麼不膨脹、怎麼重錨)

主對話的 context 是整個系統**唯一不可再生的資源**;每肥一分,此後每一輪
API 呼叫都重複攜帶,越肥 → compact 越早 → 迷航越早。這層專打這條惡化鏈的
上游。

- **指揮官不下場**(`kit-delegation.md`)——主對話只做五件事:決策、架構、
  派工、驗收、跟 user 對話。硬規則只有一條:**回報禁貼 >20 行代碼**(用
  「路徑:行號 + 一句結論」)——回報噴代碼是 context 污染的實際來源,
  收到噴代碼要求重報,而不是照單全收。
- **強制派工的三種情況**——全 repo 掃描、預估 >10 檔、位置未知的搜索
  (不知道在哪就別自己翻)。其餘交給經濟判斷:派一個 subagent 約
  10–30k tokens,直讀 400 行約 5k——**別為儀式感派工,也別把 context
  當免費資源**。
- **隔離驗收 = 狀態隔離**(implementer≠verifier)——寫 code 的 agent 不得
  自我宣告完成;驗收由 fresh-context subagent read-back。subagent 的
  verbose 探索留在子對話,不污染指揮官 context(四維隔離之一)。
- **RE-ANCHOR 重錨定**(`session-start.sh`,偵測 `source=compact|resume`)——
  compact 把 plan/constraints/進度壓成大意,是記憶解體風險最高的時刻;
  此時注入強制指令:動任何檔案前先重讀 constraints 與進行中的 plan、
  用一句話自報所在 phase。**hook 注入,不靠模型記得**。
- **檔案路由表**(CLAUDE.md「需要時才讀」段)——把「何時讀哪份文件」做成
  查表,而不是把所有背景常駐在 context。減少每 session 的固定稅。
- **rules/ 總量預算 + 棘輪**——五份規則是每 session 的固定 context 稅,
  超標先精簡再新增(kit repo smoke test 把關);v4.9 起減法紀律
  (kit-evolution):降級是預設、真刪僅限 hook 接管、瘦身後 cap 下修。
  防的是規則本身膨脹與「刪了又靜默漲回」。

## 三、Harness engineering 防護(物理層:hooks / gate / 所有權,deterministic)

核心防線全在這層——因為只有這層在模型迷航後**仍然有效**。五支 hook 預設
開啟(v3.5 起),user-only 逃生口 `KIT_PROTECT=off` / `KIT_BREAKER=off` /
`KIT_REVIEW_GATE=off`(啟動前 export;模型自己 export 沒用,hook 吃的是
claude 啟動時的環境)。

- **protect-paths.sh**(PreToolUse,Edit/Write/NotebookEdit)——兩檔防護:
  專案 `kit.toml` 的 `protected` 清單(v4 為 `.claude/protected-paths`)命中即 **hard-deny**(你宣告的專案禁區,
  路徑經 dot-segment 正規化,防 `src/../.claude/x` 繞過);kit-owned 檔案
  (rules/hooks/scripts/agents/skills/docs、settings.json、kit-version)
  命中轉 **ask**——user 在場一鍵放行你確實要求過的修改,**無人值守時等同
  封鎖**。迷航的模型碰不到禁區,不靠它記得。(kit repo 本身自動豁免。)
- **tool-breaker.sh**(PreToolUse + PostToolUseFailure)——**重試螺旋熔斷**:
  連續第 3 次完全相同的工具調用(工具名 + 參數 hash 一致、中間無其他調用)
  → 物理 deny,訊息要求「先一句話診斷前兩次為何不滿足,換方法或走升降級」;
  輪詢類工具豁免。**失敗密度警示**:最近 12 條遙測事件中 ≥3 次失敗 → stderr
  注入警示(工具已執行完,物理上不能 block,只能警示)。所有調用寫一行
  埋點日誌到 `/tmp/claude-kit-toollog-<session_id>.jsonl` 供事後審計。
  **verifier-pipe guard**(v4.10):「測試執行器接管道過濾再鏈 git commit/push
  且無 pipefail」→ deny——管道回報的是過濾器的 exit code,測試可以紅著
  看起來綠(收據:local-b 同 session 三犯;機隊 10/13 專案踩驗證管道說謊)。
  四步契約(豁免→摺疊→四態引號中和器→單一有序 regex),寧漏勿誤擋;
  **防呆不防敵**——蓄意規避(拆字/跨調用/bash -c 巢狀)明文界外,同
  威脅模型邊界(#7)的超集論證。
- **verify-final-review.sh**(Stop gate,v4.9 決策點化)——「先算後判」:
  批次事實(changed set/業務/敏感/累積行數)先於一切裁決分支計算,地板依
  批次內容執法、永不信 flag 自述。基線機制不變:baseline = 上次認證的
  HEAD sha + working-tree content hash,gate 聯集「未 commit + baseline 以來
  的 commits」,審過用 content hash 記住,損毀 fail-closed(退化方向是
  「多審」不是「漏審」)。**小改自動放行**:累積 diff ≤150 行/≤8 業務檔
  (numstat 實測;測試檔不計,敏感命名測試檔除外)→ 放行但不推進 baseline
  (防切香腸)。**破檻 = 一次三選一決策**(收據 2026-08-02:舊行為破檻後
  每個動碼輪連攔,且會撞 Claude Code「Stop hook 8 連 block 強制放行」的
  天花板變成靜默失效):review(/kit-review)/ defer(mid-flight,寫一行
  理由,gate 靜默至批次再長 150 行)/ skip(v4.9 決策權移交模型,
  /kit-skip-review 雙模式)。**敏感地板**:敏感 stem、protected-paths、
  不可量測批次——不可 defer、不可 model-skip、small-allow 無效;僅
  review 或 user-approved 能結清。敏感掃描先於副檔名過濾(修 pre-existing
  migration-SQL 盲區)、業務過濾先於截斷(修 pre-existing head-50 藏檔洞)。
  **skiplog 審計 fail-closed**:model-skip 生效與 defer 蓋章以
  `/tmp/claude-kit-skiplog-<sid>.jsonl` 寫入成功為前提。v4.8 的 turn-scoped
  (只有本輪動過樹才攔)與 user-only 逃生口 `KIT_REVIEW_GATE=off` 照舊;
  已知缺口(no-edit 完成輪放行,user 接受 2026-07-24)照舊,但敏感批次
  因禁 defer 不受此缺口影響(codex 2026-08-02 P1 的修法)。
- **Marker 證據化 = 逃生門加價**——v3.5 的 block 訊息**親手把 `touch <marker>`
  遞給模型**,假性完成的最短路徑是 harness 自己鋪的。v4.0 起 marker 第一行
  必須是 `reviewed-by=` 證據行(由 `/kit-review` 真跑完 review 後寫入);
  bypass flag 兩種:`user-approved`(user 明確要求)或 v4.9 的
  `skipped-by=model reason= scope=`(模型自判,非敏感批次限定,審計
  fail-closed)。block 訊息仍不印 marker 捷徑;defer 的 echo 教學行例外
  ——它是有界的門(150 行後必再問),不是認證。**架構轉向:與其把 skip
  做難,不如讓誠實免費、讓謊言留痕**——正門開著,走正門留名留理由。
- **檔案級所有權二分 + 回流**——kit 全套(`plugin/`)由 kit-owned plugin 一次安裝、
  所有專案共用(v4 為每專案複製 `.claude/`),專案只留 `AGENTS.md` + `kit.toml`。
  客製改 kit repo 再 `kit update`,不靠人肉同步(drift 陷阱)。所有權從「檔案內的段落約定」升格成
  「檔案本身 + hook 執法」。
- **constraints ↔ protected-paths 同步執法**——CLAUDE.md 每條「路徑型」禁區
  要同步寫進 `kit.toml` 的 `protected`,讓 prose(給人看)和物理執法(給 hook)
  是同一份清單的兩面。模型只能加嚴、不能放寬(放寬需 user 明確同意)。
- **Reviewer isolation(KIT_PROFILE)**——full=`/codex:review` 跨模型真隔離;
  solo=fresh-context Claude 自審(只剩狀態/時間隔離),且**明文宣告降級、
  不靜默**。硬規則:sonnet/haiku 永不指派 review、驗收、auth/payment/security
  判斷——這是 harness 的信任邊界,不是能力歧視。四維隔離(時間/觀點/規格/
  狀態)同時是判準也是檢查清單。

---

## v5 guard(本機 git guard:commit / push 的洩漏邊界)

設計權威:`docs/design-history/2026-10-19-kit-v5-design.md §7`。全域
`core.hooksPath` 指向 `kit setup` 生成的 shim(`~/.config/kit/git-hooks/`),
所以**機器上每個 repo、人或 AI 的每次 commit/push** 都先過
`plugin/guard/pre-commit.sh` / `pre-push.sh`,再鏈到 repo 自己的 hook
(`git rev-parse --git-common-dir`,worktree 共用主 repo 的 hooks;**絕不**用
`--git-path hooks`——它尊重 hooksPath、指回 shim 自己、無限遞迴)。其他 hook 名
(commit-msg、post-checkout、post-receive…)裝的是只鏈接不檢查的 shim,repo
本地的 git-lfs / linter hook 照常跑。

| # | 規則 | pre-commit(staged diff 的**新增行** + staged 檔名) | pre-push(推送樹 + 推送範圍每個 commit 的新增行、commit / tag 訊息、檔名、ref 名) | 沒有 kit.toml 的 repo |
|---|---|---|---|---|
| R1 | gitleaks(內建規則 + `plugin/guard/gitleaks.toml`) | block | block | 照跑 |
| R2 | 禁推路徑 `.claude/` `.superpowers/` `PROJECT.toml` `docs/LESSONS.md` `docs/plans/` `docs/superpowers/plans/` `docs/decisions/` `*.local.toml` `CLAUDE.local.md` `.env` / `.env.<name>`(最後一段是 example/sample/template/dist/defaults 的範本放行;`.envrc` 只 warn;kit.toml `allow_paths` 可豁免單一 .env 檔) | block(A/C/M/R/T;刪除放行) | block:整棵推送樹(抓**長期 tracked**)+ 範圍內曾新增過(加了又刪也會留在遠端歷史);拿掉 kit.toml 的推送仍算 kit repo,且移除本身 block | 只查 `.env*`,且只查 commit / 推送範圍內新增的(不掃整棵樹) |
| R3 | 本機路徑 `/home/<u>`、`/mnt/c/Users/<u>`、`/Users/<u>`、`C:\Users\<u>`(`<u>` = privacy usernames ∪ 目前 OS user) | block | block | 照跑 |
| R3b | 其他 `/home/<x>/` | warn | warn | 照跑 |
| R4 | `tier="always"` 個人字面值 + privacy emails(名稱 `email`) | block | block | 照跑 |
| R5 | `tier="public-only"` 字面值 | block,除非 kit.toml `visibility="private"` | 同左(讀**推送樹**裡的 kit.toml) | 當公開處理(fail-closed)→ block |
| R6 / R7 | 一般 email / `/tmp/claude-<uid>/` | warn | warn | 照跑 |
| R8 | gitleaks 找不到(`config.toml` 的 `tools_dir` / `gitleaks_path`;**從不看 PATH**)、sha256 不等於記錄的 `gitleaks_sha256`(「binary replaced」/ 沒記錄)或崩潰 | warn(大字橫幅) | **block** | 照跑 |

- 推送範圍 = 本地 sha 減去**推送目標實際已有**的 commit(`git ls-remote <url>` +
  舊值);remote-tracking refs **不採信**(`remote set-url`、多個 pushurl 鏡像、
  直接推 URL 時它們描述的是別的 repo);ls-remote 失敗就掃推送 ref 的完整歷史。
  merge 的衝突解法用 remerge diff 掃。ref 刪除永遠放行。
  **遠端已前進、本地沒 fetch**(v5.0.1):push 傳進來的舊值(非零 rsha)本地沒有——別人或排程
  workflow 在上次 fetch 之後推過——那個 ref **不掃**,只出一行 `[R0 fetch-first]` block:
  `git fetch` 後 rebase / merge 再推;刻意覆蓋(force push)也先 fetch,guard 才算得出範圍。
  以前這裡會退回掃整段歷史,把遠端早就有的舊 `.claude/`、PROJECT.toml、本機路徑全部當成「這次
  新增」再報一次。這個 block **不吃 bypass**(已 arm 的 bypass 不消耗、留著):放行就等於送出沒掃過的內容。
- 每個 git 呼叫都明確釘住輸出格式(`--no-color`、前綴、`--root`、`--text`、
  `--format`…),呼叫端的 config(`-c color.ui=always`、`log.showRoot=false`、
  `diff.noprefix`…)改不了 guard 讀到的內容;R1 的 gitleaks 跑在 guard 自己產生的
  同一條新增行串流上(`gitleaks stdin`),不再另起一次 `git diff/log`。
- 內容規則一律 fixed-string、不分大小寫、字面值 <4 字元忽略;輸出**永不印出**
  被攔的值(字面值以 `<name>` 代稱、使用者名以 `<user>`)。diff 一律 `--text`,
  任何 attributes(repo 內、`.git/info/attributes`、`core.attributesFile`)都不能把
  文字檔標成 binary 來躲;真正含 NUL 的檔案段落才跳過內容規則(含一個 NUL 就整段跳過)。
- 誤報出口(都在 diff 裡留痕):行尾 `kit-privacy: allow` **只豁免 warn 級規則**
  (R3b/R6/R7),每個被用掉的標記都印 `WARN [<rule> allow-marker]` 並寫一行
  audit.jsonl(action `allow-marker`)——block 級(R3/R4/R5)寫了標記照擋,例外只走
  kit.toml(review O9);`gitleaks:allow` /
  **已 commit 的** `.gitleaksignore`(未追蹤的不算——指紋 `path:rule:line` 或
  `commit:path:rule:line`);`kit.toml [privacy] allow_paths`(跳 R3–R7 與單一 `.env`
  檔的 R2,不跳 R1 與其他 R2 路徑);
  `allow_literals = ["<name>"]` **以名稱**豁免 R4/R5,寫值不算數(guard 與
  `kit audit` A2/A3 同一套語意)。
- 失效模式 fail-loud:`config.toml` / `kit_root` / guard 腳本缺 → shim
  `KIT GUARD: not configured` 並 **exit 1**;讀不到 staged diff / 推送範圍 → block。
  `privacy.local.toml` 缺 → R4/R5 跳過 + warn(R3 仍認得 OS user)。
- 審計:每次 block / bypass / 被用掉的 `kit-privacy: allow` 寫 `~/.local/state/kit/guard/audit.jsonl`。
- 拿掉 kit.toml 不會關掉 R2:commit 時從 HEAD 讀 kit.toml(並 warn),push 時遠端舊 tip / 範圍邊界 /
  範圍內任何 commit 有 kit.toml 就仍算 kit repo,而且「移除 kit.toml」本身 block(只有 user bypass 放行)。
  推送 tip 沒有 kit.toml 時,先看**本地證據**(不連網):任何本地分支 tip、推送目標公告且本地已有的
  `HEAD` / `refs/heads/*` / `refs/tags/*`(review R3-2:orphan 分支、不相干歷史)。之後才連網,而且
  **只抓兩樣**(review R4-3):這個 ref 在遠端的舊 tip(本地沒有時)與遠端 `HEAD`(還沒有任何 kit
  訊號時)——`--depth=1`、伺服器允許就 `--filter=blob:none`(kit.toml 的 blob 需要時才補抓)、
  非互動、`KIT_GUARD_FETCH_TIMEOUT` 預設 30 秒,抓進 hook 暫存目錄裡的**一次性 bare repo**
  (alternates 借用本 repo 物件):本 repo 不留 ref、不留物件、不變 shallow;從不抓整個公告命名空間。
  「本地有」= 讀得到 commit 的根 tree(tree 列出 kit.toml 時連同它的 blob,不觸發 lazy fetch);
  partial clone 裡只有 commit 沒有 tree 的舊 tip / `HEAD` 照「本地沒有」走上述抓取,抓了仍讀不到
  tree → fail closed(review R5-2)。
  被覆蓋的遠端舊 tip 有 kit.toml = 移除 → block。**舊 tip(非零 rsha)本地沒有**一律先
  `[R0 fetch-first]`(v5.0.1,見上);舊 tip 在本地但**讀不到 tree**(partial clone)又抓不到——離線、
  或 hook 自己的連線認證不過(push 本身的連線過了,例如有密碼的 ssh key 沒 agent)——
  **fail closed** `[R2 kit-status-unknown]`(user bypass 放行;review R4-2 / R5-2);遠端 `HEAD` 列得出卻抓不到
  也一樣。新 ref(零 rsha)且 ls-remote 失敗 → 只用本地訊號。orphan / unborn 分支上的 commit 從本地分支 tip 讀 kit.toml。
- 速度(Phase 4 實測):小 diff pre-commit 中位數 52ms 不含 gitleaks、270ms 含(final-review 修正後重測);
  7-commit push 320ms 含 gitleaks;8,000 行 email CSV(8k 個 R6 warn)< 1s;每條規則只列前 50 筆、
  其餘計數成一行,20 萬行 email CSV 約 1.3s(review F8)。push 時 `git ls-remote` 上限 5 秒、
  ssh BatchMode、不跳密碼提示;失敗就說原因並改掃完整歷史。
- **本機專屬檔案(review F3)**:migrate 後 PROJECT.toml / LESSONS / plans / `.claude/` 已不追蹤,
  但遷移前的每個 commit 仍追蹤它們——`git checkout <舊 ref>` 會蓋掉、切回來會刪掉。git 沒有
  pre-checkout hook,所以 `plugin/guard/localfiles.sh` 把這些檔 **hard link** 進
  `~/.local/state/kit/localfiles/<repo-id>/files/`(git 換檔是 unlink + 新建,store 那份保留內容,
  包含上次快照後的就地修改);post-checkout / post-merge / post-rewrite shim 把被刪的放回(沒有
  store 時用前一個 commit 的 blob,只限 owner 內容、不含 `.claude/` 的 v4 kit 檔),post-commit /
  pre-rebase / `kit migrate` / `kit guard status` / session start 更新快照。
  **誰刪的**(v5.0.1):store 裡有、工作樹沒了、HEAD 不追蹤的檔,若上次快照之後的 git 操作經過
  追蹤它的 commit——HEAD reflog 在快照標記(`<store>/mark`)之後的每筆紀錄的兩端(單純的
  commit / amend 不算),加上 hook 自己的前一個 HEAD 與 rebase 的 `ORIG_HEAD..HEAD`——就是 git
  刪的 → 從 store 放回(owner 內容優先於 git 途中寫出的舊追蹤版);否則才算 owner 刪的 → trash。
  所以 rebase / `pull --rebase` 把遷移 commit 重放到遷移前的歷史上(git 先 checkout 舊 base 蓋掉、
  再套遷移 commit 刪掉)、cherry-pick / merge 遷移 commit、沒有 hook 的 `reset --hard` 來回,都會
  放回;rebase 進行中(`rebase-merge` / `rebase-apply` 存在)每個 pick 的 post-checkout / post-commit
  不動作,由結尾的 post-rewrite 收尾;pre-rebase 先快照,rebase 前最後一刻用 rename 存的修改也在。
  (pre-merge-commit / pre-applypatch 不用:git 跑它們時工作樹已經改完。)symlink 以 symlink 存、以 symlink 回;
  超過 8 MiB 或第 2000 個之後的檔**不進 store**,列在 `<store>/omitted`,清單變動時、每次
  `kit guard status` 與 `kit migrate` 都印 `NOT protected` 警告(review R3-3);store 根目錄 700。
  工作樹沒了、HEAD 也不追蹤的 store 檔 = owner 刪的(或 reset / stash / clean 拿掉的)→ 移到
  `<store>/trash/<path>.~<時間戳>~`,**每個路徑保留最近 5 代**、內容相同不重複存(review R4-4);
  checkout 不會再放回(review N2);每個快照呼叫端(post-* hook、`kit migrate`、`kit guard status`、
  session start 的 context)都用一行說搬了什麼;還原訊息附 store 那份的時間(review N4)。

**Bypass(user-only)**:`kit guard bypass "<reason>"` 只在有 TTY 的終端機執行
(agent 的非互動 shell 沒有 TTY → 拒絕);寫 `bypass-<repo-id>` 並記一筆
`bypass-armed`(guard 只接受有對應記錄、到期 ≤10 分鐘的 bypass 檔);10 分鐘內**下一次
會被擋的** commit 或 push 單次放行並記 audit(乾淨的 commit 不消耗;commit 與 push
各需一次)。`KIT_GUARD=off` 不被承認。模型這一側由 tool-breaker 的 guard-preserve
(所有目錄都跑)deny:`--no-verify`、`commit -n`、改 / 清空 `core.hooksPath`、
`HOME=` / `XDG_CONFIG_HOME=` / `GIT_CONFIG_*=` / `KIT_STATE_HOME=` 前綴的
commit/push、`env -i` / `env -` / `env -u HOME` / `--ignore-environment` / `--unset=HOME` /
先 `unset HOME` 再 commit/push、`-c` / `--config-env` 的 `include.path=` / `includeIf.*.path=`
(含 `GIT_CONFIG_KEY_n` 與 `git config include.path` 寫入)、`git send-pack`(不跑 pre-push)、
`kit guard bypass`(含 `script` / `unbuffer` / `pty.spawn` 包裝),以及**直接寫** guard 的輸入:
重導向目標、或寫入型指令(rm/mv/touch/truncate/chmod/tee:任一運算元;cp/ln/install/rsync:
目的地;sed/perl/ruby:僅 `-i`;dd `of=`;`--output=`)的運算元是 guard 狀態檔、git-hooks shim、
git config 檔、`privacy.local.toml`、kit `config.toml` 或 `plugin/guard/`——只讀(`sed -n`、
`cat … | sed`)與「同一行別處提到」不算(review F1/F6/F7),`plugin/hooks/` 也算 guard 輸入
(review R3-9);掃描器本身也算:`~/.local/bin/{gitleaks,osv-scanner}`、config.toml 的
`tools_dir/…` 與記錄的 `*_path`(cp/ln -sf/install/mv/chmod/重導向 → deny;review R4-1)。
`PATH=` 不攔:gitleaks / osv-scanner 的單一解析器(guard、session start、doctor、
`kit guard status` 共用)**只讀 config.toml**——`tools_dir/<name>`(預設 `~/.local/bin`),否則
記錄的絕對路徑 `gitleaks_path` / `osv_scanner_path`;**從不看呼叫端的 PATH**(review R3-1:
`PATH=/tmp/x:$PATH git push` 配一支回 0 的假 gitleaks 曾讓 R1 失效);相對路徑一律忽略。
**信任 = 內容雜湊,不是版本字串也不是位置**(review R4-1):`kit setup` / `kit doctor --install`
只在 `tools_dir/<name>` 的 sha256 等於釘版值、或 PATH 上某支的 sha256 等於釘版值時才採用
(印 `8.30.1` 的假 stub 會被點名忽略),否則安裝驗過 sha256 的下載;每條路都把
`gitleaks_sha256` / `osv_scanner_sha256` 寫進 config.toml。guard 每次執行前重算 sha256
(22 MB 的 gitleaks:解析 + 雜湊約多 11 ms,pre-commit 中位數 285→296 ms、pre-push 390→404 ms,本機 SHA-NI;不做快取——快取檔本身會變成可偽造的輸入),
候選裡第一支雜湊相符的才跑;都不符 → R8「binary replaced」,沒記錄 → R8「no gitleaks_sha256
recorded」。雜湊工具本身只用固定絕對路徑(`/usr/bin/sha256sum`、`/bin/sha256sum`、`/usr/bin/shasum`、
`/usr/bin/openssl`),不經 PATH、不經 shell 函式(review R5-1:匯出一個印出釘版值的 `sha256sum`
函式曾能替假 stub 背書);shim 以 `bash -p` 重跑自己、也以 `bash -p` 跑 guard / localfiles——環境裡
匯出的 shell 函式(`BASH_FUNC_*`,例如假的 `cat` / `bash` / `git`)與 `$BASH_ENV` 都不載入(舊機器
重跑 `kit setup` 換上新 shim)。非 linux/x86_64 的 owner 自己裝好後,在 config.toml 手寫 `<tool>_path` 與
`<tool>_sha256`(doctor 以 WARN 標「sha256 recorded by hand」)。protect-paths 對 Edit/Write 到
`~/.config/kit`、`<state>/guard`、git config 檔轉 ask。

**已知繞道與殘餘(誠實條款)**:
1. 人用 `git --no-verify` → guard 擋不了;事後由 `kit audit`(A1–A5)抓內容。
2. 其他機器、GitHub 網頁編輯、bot commit → 本機 guard 看不到;公開 repo 由
   CI 層(§7.6)與 GitHub push protection 兜底。
3. repo 本地 `core.hooksPath`(husky 類)蓋掉全域 shim → 該 repo **零 guard 且無訊息**;
   `kit doctor`(在該 repo 內跑)FAIL、`kit guard status` 標 OVERRIDDEN、`kit audit` A16 HIGH。
4. 推送目標**已有**的內容不會在 push 時重查:同一個 remote 從私人翻公開時,舊的
   public-only 字面值要靠 `kit audit` A2/A6。
5. **含 NUL 的檔案段落整段不掃內容**(review F5/O7):二進位裡的字面值,或刻意
   `printf '\0' >>` 一個 NUL 的文字檔,整個檔案就跳過 R1 與 R3–R7(gitleaks 的 git 模式
   本來也看不到 → R1 與上游同等;R3–R7 是 kit 自己的損失)。不擋 NUL 檔,因為那會擋掉
   每個真的二進位檔;
   `gitleaks stdin` 不套用 gitleaks 的路徑型 allowlist(lockfile 可能多出誤報);
   commit 訊息在 commit 時還不存在,只在 push 時掃;作者 / committer email 不掃;
   `reference-transaction` / `post-index-change` 沒有鏈接 shim。
6. 同一個 commit 可以順手放寬 `kit.toml`(`allow_literals`、`visibility`)——diff 可見,
   且 kit.toml 是 Stop gate 的敏感路徑,必過 review 或 user 之口。
7. 模型威脅邊界同 v4.9:持 Bash 的模型用變數、alias、腳本仍能拼出繞道
   (anti-footgun,不是 anti-evasion);bypass 檔與 audit log 只是摩擦 + 留痕。逐條明列:
   - **變數 / 間接的 `--no-verify`**(review O6):`f=--no-verify; git push "$f"`、
     `git push $(echo --no-verify)`、`NV=--no-verify; git commit $NV` 都不會被 deny;
     guard-preserve 只看命令字面。
   - **間接改寫 guard 的輸入**(review F6 殘餘):直接形式(重導向、sed -i、cp 到該路徑…)
     已 deny,但 `python3 -c 'open(...).write(...)'`、自己寫的腳本、變數拼出的路徑、
     `cd ~/.config/kit && sed -i … config.toml`(相對檔名)、編輯器等仍能改
     `privacy.local.toml`、`config.toml`、`plugin/guard/*.sh`、git config。
   - 行尾 `kit-privacy: allow` 模型可以自己寫,但只豁免 warn 級規則,且每次都 WARN + audit。
   - **PATH 上的冒牌 `git` / `bash` / coreutils**(review R3-1 殘餘):gitleaks 已不從 PATH 解析,
     但 `PATH=/tmp/x:$PATH git push` 裡的 `git` 本身、shim 的 `#!/usr/bin/env bash`、guard 用的
     awk/sed/grep 仍從 PATH 找——冒牌 `git` 可以自己呼叫真的 `git push --no-verify`,與「把
     `--no-verify` 寫進腳本檔再執行」同一類(要先寫一支可執行的冒牌檔),不另設防。
8. 權限基線殘餘(§13 #8):`git log --output=`、`git diff --output=` 可寫檔,
   被 `Bash(git log *)` / `Bash(git diff *)` 放行——低風險(只寫文字檔),接受。基線一律
   「空格 + `*`」:無空格的 `Bash(git diff*)` 是前綴比對,會連 `git difftool --extcmd=` 一起放行
   (任意執行),`Bash(ls*)` 會放行 lsof(review F2;kit setup 重跑時移除舊的無空格寫法)。
9. **R2 只錨在 repo 根目錄**(review F10):`sub/.claude/settings.local.json`、
   `fixtures/.superpowers/…` 這種巢狀路徑不擋;`kit audit` A4 會以 INFO 列出巢狀 `.claude/`。
10. **上線順序**(review F9):沒有 kit.toml 的 repo 一律當公開——public-only 字面值 block、
   `.env*` 照擋。`kit setup` 裝好全域 hook 後,私人 v4 repo 要**緊接著** `kit migrate`;在那之前,
   提到其他私人專案名的私人 repo 會推不上去(要嘛先 migrate、要嘛 user bypass)。
11. **本機專屬檔案保護的縫**(review F3 殘餘):hard link 只保住「就地」修改;用 rename 存檔的
   編輯器(`sed -i`、原子存檔)在上次快照後、下一次破壞性 checkout 前的修改會遺失(回來的是
   較舊的 store 版本);repo 與 `~/.local/state` 不在同一個檔案系統時只能複製,同一個縫。
   `git reset --hard <舊>` 不觸發 hook,但會留在 HEAD reflog:下一次快照時從 store 放回(v5.0.1);
   reflog 關掉(`core.logAllRefUpdates=false`)時退回舊行為。`git stash`、`git clean` 不留 reflog——內容在
   下一次快照時移進
   `<store>/trash/`(帶時間戳,每個路徑留最近 5 代;第 6 次以上「消失又出現、內容不同」會丟掉最舊那代),
   下一個快照點會用一行說明,`kit guard status` 也會列出來,要自己複製回來。
   **刪掉的 plan 復活**(review N2):快照時「工作樹沒了、HEAD 不追蹤」的檔移進 trash、不再放回;
   但刪掉後**沒有任何快照點**(commit、checkout、`kit guard status`、session start)就做了一次經過
   「仍追蹤它的 commit」的 git 操作(checkout 遷移前的 ref 再回來、rebase / reset 穿過遷移前的歷史),
   那份 plan 仍會從 store 回來(未追蹤、已 ignore,不會被推)——v5.0.1 起「git 刪的放回」優先。
   **rename 存檔的縫**(review N4):還原訊息會印 store 那份的時間(`as of …`),比那更晚、用 rename
   存的修改不在裡面(`<store>/prev/` 留前一版);沒有每個 prompt 都快照(成本)。
   超過 8 MiB / 第 2000 個之後的檔不受保護,只有警告(review R3-3)。根治是改寫歷史(design §12 步驟 6)。
12. guard-preserve 已知誤擋:`chmod` 算寫入(`chmod -x` 會讓 shim 靜默失效),所以模型照 doctor
   建議跑 `chmod 600 privacy.local.toml` 也會被 deny(交給 user);在 kit repo 自己的開發裡,
   `sed -i plugin/guard/*.sh`、`sed -i plugin/hooks/*.sh` 被 deny(那份就是線上的 guard / hook),改用 Edit(轉 ask)。
13. **合法移除 kit.toml 之後**(review N3):user bypass 放行的那次移除留在歷史裡;之後推到**新的**
   remote(或 ls-remote 失敗、改掃完整歷史時),範圍含那個移除 commit → 每次都 `[R2 kit.toml-removed]`
   block,要再 bypass 一次;還留著 kit.toml 的本地分支也讓這個 repo 繼續被當成 kit repo(R2 照套)。
   少見、有 bypass,不另設例外。
14. **kit 身分判斷的縫**(review R3-2 / R4-2 / R4-3 殘餘):**新 ref**(零 rsha)且 `git ls-remote` 失敗
   (離線、要密碼)時只剩本地訊號(本地分支 tip、範圍、工作樹 kit.toml)——全新 repo 離線推不相干
   歷史成為沒抓過的 kit remote 的**新分支**不會被認出(通常推送本身也會失敗);覆蓋既有 ref 的推送
   則 fail closed。只看遠端 `HEAD`:kit.toml 只存在遠端**非預設分支 / tag** 上、本地又沒有時,不算
   kit 訊號(review R4-3 的取捨:不再抓整個命名空間;R5 複審維持——有上限的公告 tip 掃描留待日後);`refs/pull/*` 等 review 命名空間與
   remote-tracking refs 不當 kit 訊號。反過來的成本:本地沒有遠端舊 tip 時,**任何**覆蓋它的推送
   (含 force push、orphan gh-pages、非 kit repo)一律 `[R0 fetch-first]`、不吃 bypass(v5.0.1)——
   先 `git fetch` 再推;舊 tip 在本地但讀不到 tree、又抓不到時是 `[R2 kit-status-unknown]`(user bypass 放行)。
15. **掃描器雜湊的縫**(review R4-1 殘餘):驗雜湊與執行之間有極短的 TOCTOU 窗(換檔要剛好卡在
   兩者之間);`kit doctor --install` 會把 `tools_dir` 裡被換掉的檔換回釘版(或改記 PATH 上雜湊相符的
   那支),所以模型跑它無害;間接寫法(`python3 -c` 改 config.toml 的 `gitleaks_sha256`)同第 7 條。
16. **刻意操弄 hook 環境不在範圍內**(review R5 殘餘;**防呆不防敵**):guard 擋手滑與模型的直覺路徑,
   不擋刻意改造自己 hook 環境的人。R5-1 之後雜湊工具走絕對路徑、shim 之後的一切不載入匯出函式與
   `$BASH_ENV`,但仍有:shim 第一行(`bash -p` 重跑)之前就生效的 `$BASH_ENV` 與名為 `exec` 的匯出
   函式;PATH 上的冒牌 `git` / awk / sed(第 7 條);`/usr/bin/shasum`(perl)、`openssl` 讀的
   `PERL5LIB` / `OPENSSL_CONF` 類變數;guard 的 git 讀的 `GIT_*` 變數。partial clone 的邊角:git < 2.44
   不認 `GIT_NO_LAZY_FETCH`,檢查 tree 時照 git 設定 lazy fetch(多一次連線、可能提示);本地分支 tip /
   已有的公告物件只有 commit 沒有 tree 時不算 kit 訊號(只有被覆蓋的舊 tip 與 `HEAD` 會補抓);
   以及第 14 條「kit.toml 只在沒抓過的非預設分支 / tag」。這些都要先在呼叫端環境或 clone 方式上
   動手腳,與「把 `--no-verify` 寫進腳本」同類,不另設防。

## 四、誠實條款:這套 harness 的能力極限

防線的價值是**摩擦 + 審計痕跡**,不是密碼學防偽。明列邊界(完整版見
`docs/harness-diagnosis.md §三`):

1. **Bash 是邊門**——protect-paths 只攔 Edit/Write/NotebookEdit;`sed -i`、
   `echo >`、`rm` 繞過工具層物理攔不住。命令字串解析誤報率太高不硬攔,
   靠埋點日誌留痕事後審計。
2. **防偽是摩擦不是密碼學**——marker 證據行、bypass 流程,讀過原始碼的模型
   都能偽造。持有 Bash 的模型理論上可偽造一切;最後一層防線是**人**對埋點
   日誌與 marker 內容的定期抽查。
3. **假性完成沒有可靠的物理 gate**——「宣稱完成但零落檔」需要語意理解(分析型
   任務本來就合法零落檔),bash 做 NLP 誤報不可接受。替代:程序性驗收——
   指揮官收到「已寫入 X」必須 ls/read 實證,驗收一律 fresh-context read-back。
4. **prompt-level 規則對迷航模型效力遞減**——rules 寫得再好,迷航的模型讀過
   也會忘。這正是分層邏輯的由來:核心防線做成 hook,rules 只做 hook 做不到的。
5. **品味決策是弱模型的天花板**——商業美感、取名、文案語氣、無硬規格的 UX:
   拆解與隔離驗證救不了。標準應對(judgment-matrix R4,具強制力):弱模型不得
   自行拍板,產出選項 + trade-offs 停下問 user;無人值守時選最保守選項並以
   `TASTE-DECISION` 標記待覆核,禁止讓品味選擇隱形。
6. **/tmp 揮發性**——重開機(尤其 WSL)清空 /tmp → baseline/marker/埋點/
   skiplog 消失,gate 退化為 porcelain-only 視野。已知且接受——fail-closed
   設計保證退化方向是「多審」。
7. **威脅模型邊界(v4.9 明文)**——持 Bash 的模型可改寫任何 /tmp 狀態檔:
   偽造 `user-approved`、改寫 defer stamp,乃至直接改寫 baseline line2 認證
   任意樹(既有**超集**攻擊,前兩者都不比它強)。敏感地板與 skip 審計的
   強度定位=「誠實路徑最省力 + 造假留下可交叉比對的不一致」,**非密碼學
   保證**。月度抽查升級為三方交叉:flag/stamp 內容 ↔ skiplog ↔ toollog
   ——skiplog 裡沒有對應條目的 stamp、toollog 裡沒有 review 調用的 marker,
   都是實錘。model-skip 的 reason 屬自我報告,抽查時對照實際 diff。

> 評估任何未來防線,先問那句工程判準:**被違反時能被物理偵測嗎?** 這決定
> 它該做成 hook 還是進 rules,也決定它的強度上限。
