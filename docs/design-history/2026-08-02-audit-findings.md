# Instruction Audit findings — 2026-08-02 首跑（v4.9 減法版 Phase 0）

> 執行：fresh read-only subagent（主對話模型檔），prompt = instruction-audit.md
> 現成 prompt + v4.9 附加判準（Anthropic 2026 scaffolding 四類）。
> 指揮官抽驗：Q1 四條矛盾逐一對照原文屬實（其中 KIT_CONTEXT 漏列
> project-manifest 由本 session 自己的 KIT_CONTEXT 直接證實）；Q3.1/Q3.2
> 對照 verify-final-review.sh 實體屬實。Rejected：無。
> 本檔是 Task 5（無爭議刀）與 Task 6（判斷刀）的輸入；各條 verdict 執行後
> 回填於文末。

## Q1 — 規則互相矛盾（4 項，全數屬實）

1. **>30 行 STOP 條件不一致**：kit-workflow「delete/rewrite > 30 existing
   lines」（無條件）vs judgment-matrix R3.2「>30 行**且 plan 沒有明文預告**」。
   處置 → Task 5：kit-workflow 採 R3.2 豁免句（canonical = R3.2）。
2. **「指揮官只做五件事」被同檔推翻**：kit-delegation 同檔另有「trivial
   phase 指揮官 inline 做」與檔位表「多檔改動、除錯根因」。
   處置 → Task 5：改為「預設只做」。
3. **kit-workflow profiles 表寫 `/codex:review`**，但該 slash command 帶
   `disable-model-invocation: true`（已驗證 plugin 1.0.6 仍帶），照表操作
   即重演 2026-07-20 繞路收據。處置 → Task 5：表格改指向 `/kit-review`。
4. **KIT_CONTEXT auto-loaded 清單漏列 project-manifest.md**（session-start.sh
   only lists 4 of 5 rules）。處置 → Task 4 Step 3 順手修（事實錯漏）。

## Q2 — 補償性規則（失敗模式現況）

1. kit-review「node not python3」：保護 Windows/Git Bash 機隊可攜性——
   unverified 但無反證，**keep**。
2. kit-review 的 disable-model-invocation 繞路警告：**已驗證仍需要**；
   strip condition = plugin 拿掉該 flag。**keep**。
3. kit-dispatch snapshot caveat（subagent 只繼承啟動快照，實測 2026-07-03）：
   模板判斷句層的地基，今日是否仍如此 unverified。**keep**，標定期重測；
   若 harness 已修復，整個模板判斷句層可瘦身（記入 strip condition）。
4. classify-task 已自行退場的關鍵詞啟發式：良性先例，無動作。
5. judgment-matrix R4 標題「弱模型注定失敗的區域」：品味限制對強模型同樣
   成立（S1「模型發明品味很爛」），框架措辭過時。處置 → Task 6 順手改
   標題（on-demand 層，非行為變更）。

## Q3 — 以身違例（2 項）

1. verify-final-review.sh:38-59 檔頭 changelog 式敘事違反註解紀律（歸
   commit message/LESSONS）；classify-task.sh:4-23 輕度同病。
   處置 → Task 3 改 hook 時順手縮（保留日期收據行，砍敘事）。
2. block message「markers are audited against the session tool log」在
   KIT_BREAKER=off 時為假（toollog 不存在）。處置 → Task 3 Step 6 改
   措辭（改指 skiplog——v4.9 起 gate 自己寫，不依賴 tool-breaker）。

## Q4 — 跨層重複

1. 「bare touch 不過關」×4 prose + hook 執法：canonical = hook +
   KIT_CONTEXT 廣播；kit-workflow 那句 → **cut**（criterion d）；兩個
   skill 內為執行點 → keep。
2. solo 隔離揭露 ×5：canonical = kit-workflow + solo-reviewer 輸出行 +
   hook block message；kit-review SKILL 與 session-start 兩處 →
   **cut-mechanical**（改引用）。
3. kit-dispatch「派工後，指揮官的責任」段 ≈ kit-delegation 隔離驗收
   逐字複寫（同一讀者）→ **cut-mechanical**：壓一行引用（ls/Read 舉證句
   保留）。
4. no-speculative-findings ×3：kit-judgment 8 canonical；模板 4 與
   solo-reviewer 為 subagent 載體 → keep（豁免類）。
5. superpowers 重疊：verification-before-completion ≡ 第 3 條+R2、
   systematic-debugging ≡ 第 2 條+S3；kit 獨有增量 = stale-green、熔斷
   R1、confirm-before-flagging。plugin 外部不可刪；維持 precedence 句。
   註記：kit-judgment 日後再瘦時第 2、3 條優先（superpowers 觸發時補強）。
6. KIT_JUDGMENT digest 複寫 3/6/8/4 條：刻意的抗衰減重複 → keep。

## Q5 — 留/刪/降清單（Task 5/6 執行依據）

| 條款位置 | 判定 | 防的失敗模式 | strip condition | 執行後 verdict |
|---|---|---|---|---|
| kit-workflow「bare touch does not pass」句 | cut（hook 接管） | 偽造 marker | 已滿足 | done v4.9（Final review 段改寫時移除；KIT_CONTEXT 廣播仍在） |
| kit-workflow >30 行 STOP | 改採 R3.2 豁免句 | plan 外大刪改 | — | done v4.9 |
| kit-workflow profiles 表 `/codex:review` 字樣 | 改指 /kit-review | Skill-tool 繞路（2026-07-20） | plugin 除旗 | done v4.9 |
| kit-judgment 藉口對照表 | demote → judgment-matrix | 藉口式假完成 | A/B 證明 8 條+digest 足夠 | done v4.9：A/B（場景 1/2/5）B≥A，降級 R5；回升觸發=LESSONS 再犯 |
| kit-judgment Red Flags 段 | demote → judgment-matrix | turn 末假宣告 | 同上 | done v4.9：同上批降級 R5 |
| kit-judgment 第 1-8 條 | keep（常駐 canonical） | 假完成/假舉報 | 無 | keep（A/B 顯示八條獨立承載行為） |
| kit-delegation「只做五件事」 | 改「預設只做」 | 措辭矛盾 | — | done v4.9 |
| kit-dispatch 模板判斷句 + snapshot caveat | keep（弱執行員唯一載體） | 規則到不了 subagent | 重測證明快照已修 | keep |
| kit-dispatch「派工後指揮官責任」段 | cut-mechanical（引用 kit-delegation） | 幻覺「已寫入」 | 無 | done v4.9（最低驗證句保留） |
| kit-review node/timeout 細節 | keep | Windows 部署 | 機隊無 Windows | keep |
| classify-task digest | keep（~40 token 抗衰減） | 長 session 紀律衰減 | harness 原生重注入 | keep（v4.9 增 defer 提醒行） |
| kit-evolution PreToolUse 描述 + CLAUDE.md 同步執法段 hook 敘述 | cut-mechanical（行動指令保留） | harness 腐化 | 已滿足 | done v4.9（kit-evolution 側；CLAUDE.md 範本側細節在 init.sh，未動——影響僅新部署，留下版） |
| judgment-matrix / verification-signals 正反例 | keep（on-demand，降級目的地） | 卡關無檢核表 | 無 | keep（R5 接收本版降級） |
| solo 揭露 ×5 → 保 3 | cut-mechanical | 假隔離承諾 | 無 | partial v4.9：kit-review SKILL 縮引用；session-start 行**保留**——它是 profile 廣播功能行非重複 prose（偏離 audit 建議，理由記此） |
| gate block message toollog 句 | 改措辭（指 skiplog） | 威懾句失真 | 無 | done v4.9（skiplog + telemetry-when-enabled 事實句） |
