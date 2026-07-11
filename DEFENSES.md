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

四份 `.claude/rules/` 每個 session 自動載入,是固定的 context 稅,總量由
smoke test 把關(≤20KB)。

- **判斷八條 + 藉口對照表 + Red Flags**(`kit-judgment.md`,採自 fable-soul
  MIT 蒸餾)——補**認知性失敗**:目標≠指定修法、一句話機制先於動手、
  verified/changed-but-unverified 二分、stale-green reset(改動後先前的綠燈
  作廢)、證據勝過記憶、量測代替 hedge、給判斷不給菜單、先確認再舉報。
  每條在 Haiku 級模型上做過 RED-GREEN 行為測試(收據 `tests/evals.md`)。
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
- **判斷檢核表**(`.claude/docs/judgment-matrix.md`,需要時才讀)——換路徑
  信號(R1)、完成判準(R2)、熔斷提問時機(R3)、品味不拍板(R4),
  每條附正例反例。R3/R4 觸發條件明文**優先於** kit-judgment 的「直接做」傾向。
- **驗證信號注入**(`.claude/docs/verification-signals.md`,需要時才讀,v4.2)——
  五個「迴圈裡缺便宜驗證信號」的高風險領域:UI 沒截圖=視覺上未驗證(S1)、
  schema 每欄要有現存讀取路徑(S2)、bug 連環卡後交接去假設化(S3)、
  SaaS 引入必附實查成本卡且 user 拍板(S4)、業務邏輯不得只能透過 UI 觸達
  (S5,痛點驅動不預建)。kit-judgment 通用證據紀律在領域層的實例化。

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
- **rules/ 20KB 總量預算**——四份規則是每 session 的固定 context 稅,
  超標先精簡再新增(kit repo smoke test 把關)。防的是規則本身膨脹。

## 三、Harness engineering 防護(物理層:hooks / gate / 所有權,deterministic)

核心防線全在這層——因為只有這層在模型迷航後**仍然有效**。五支 hook 預設
開啟(v3.5 起),user-only 逃生口 `KIT_PROTECT=off` / `KIT_BREAKER=off`
(啟動前 export;模型自己 export 沒用,hook 吃的是 claude 啟動時的環境)。

- **protect-paths.sh**(PreToolUse,Edit/Write/NotebookEdit)——兩檔防護:
  `.claude/protected-paths` 清單命中即 **hard-deny**(你宣告的專案禁區,
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
- **verify-final-review.sh**(Stop gate)——結束前若有未審的業務邏輯就 block。
  修好三個洞:看得到 commit(baseline = session 起點 HEAD sha + working-tree
  hash,gate 聯集「未 commit + baseline 以來的 commits」)、審過用 content
  hash 記住不重複煩你、baseline 損毀則 **fail-closed**(退化方向是「多審」
  不是「漏審」)。v4.3 加**小改自動放行**:距上次認證的**累積** diff
  (git numstat 實測,模型話術無效)≤50 行、≤4 個業務檔(v4.5:測試檔兩個
  計數皆不計,敏感命名的測試檔除外)、未碰敏感 stem
  (auth/payment/migrat/…)或 protected-paths → 放行但**不推進 baseline**
  ——小改持續累積,破檻那次 review 批次涵蓋全部(防切香腸);無 baseline
  或 binary 一律 fail-closed 回到 size-blind block。
- **Marker 證據化 = 逃生門加價**——v3.5 的 block 訊息**親手把 `touch <marker>`
  遞給模型**,假性完成的最短路徑是 harness 自己鋪的。v4.0 起 marker 第一行
  必須是 `reviewed-by=` 證據行(由 `/kit-review` 真跑完 review 後寫入)、
  bypass flag 第一行必須是 `user-approved`(由 `/kit-skip-review` 在 user
  明確要求後寫入),block 訊息不再印任何捷徑指令。**誠實路徑從此比造假省力**。
- **檔案級所有權二分 + 回流**——`.claude/` 全套 kit-owned(每 session 自動
  載入)、CLAUDE.md 純專案內容。客製改 kit repo 再 `init.sh --update` 覆蓋
  回流,不靠人肉同步(drift 陷阱)。所有權從「檔案內的段落約定」升格成
  「檔案本身 + hook 執法」。
- **constraints ↔ protected-paths 同步執法**——CLAUDE.md 每條「路徑型」禁區
  要同步寫進 `.claude/protected-paths`,讓 prose(給人看)和物理執法(給 hook)
  是同一份清單的兩面。模型只能加嚴、不能放寬(放寬需 user 明確同意)。
- **Reviewer isolation(KIT_PROFILE)**——full=`/codex:review` 跨模型真隔離;
  solo=fresh-context Claude 自審(只剩狀態/時間隔離),且**明文宣告降級、
  不靜默**。硬規則:sonnet/haiku 永不指派 review、驗收、auth/payment/security
  判斷——這是 harness 的信任邊界,不是能力歧視。四維隔離(時間/觀點/規格/
  狀態)同時是判準也是檢查清單。

---

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
6. **/tmp 揮發性**——重開機(尤其 WSL)清空 /tmp → baseline/marker/埋點日誌
   消失,gate 退化為 porcelain-only 視野。已知且接受——fail-closed 設計保證
   退化方向是「多審」。

> 評估任何未來防線,先問那句工程判準:**被違反時能被物理偵測嗎?** 這決定
> 它該做成 hook 還是進 rules,也決定它的強度上限。
