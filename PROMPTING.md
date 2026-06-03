# PROMPTING.md — 跟 AI 溝通的 cheat sheet

> 給你（人）看的一頁速查。貼螢幕邊，隨用隨補。
> 它不教你怎麼描述任務（你會），只補你 freestyle 時想不起來的「控制詞」。
> AI 看的是 CLAUDE.md；這份是它的鏡像。

---

## 0. 開專案的第一句

**新專案（空的，沒得掃）**
```
這個專案是 [一句話：要做什麼]，stack 用 [語言/框架]。
請把 CLAUDE.md 的 goal / stack / file layout 填好，constraints 先留空。
```

**舊專案（`init.sh --existing` 之後）**
```
請先探索整個 repo，把你看到的架構、慣例、以及「不該碰的區域」
寫進 CLAUDE.md 的對應段落。先不要改任何其他檔案。
```

**照藍圖實作（你已有 spec）**
```
照 docs/specs/[檔名] 實作。先對 spec 跑一次 adversarial review，再進 plan。
```

---

## 1. 起手（base）— 多數時候只要這樣
```
[一句話描述任務]
```
大小由系統自己判斷，通常不用你指定。下面的修飾語只在你想覆寫判斷時才加。

---

## 2. 修飾語（接在任務後面，覆寫自動判斷）
```
…直接做，不用 plan             強制走小任務
…走完整流程                    強制 brainstorm + plan + review
…先 brainstorm，別急著 plan     scope 還模糊時先收斂
…這會動到 [X]，請 review        主動觸發審查
…請質疑這個設計（adversarial）   不只挑 bug，挑戰前提（高 stakes 用）
…這次跳過 review（我已確認）     接受降級、省 quota
```

---

## 3. 航行中（隨時插話）
```
暫停，先別動 code               停手（注意：不會自動 rollback）
rollback 剛才的改動             要復原得明講，或自己用 git
我們現在在哪？plan 存哪？        查狀態（很常忘記可以問）
/btw [小問題]                   側問：不中斷、不進歷史、無工具
/codex:review [--base main]     手動審查（full profile）
/codex:rescue [任務]            整件事丟給 codex（A/B 比較、卡住時）
```

---

## 4. 三條 don't（信任邊界 — 別把自己又變回路由器）
```
× 不要每個 plan 都自己從頭重審     superpowers + review 已幫你過一次
× 不要對小任務硬加完整流程         流程開銷 > 實作本身
× 不要 codex 寫的 code 再給 codex review   同模型 = 零 isolation
```

---

## 5. 切換 profile（公司環境 / quota 用完時）
```
切到 solo:   export KIT_PROFILE=solo     只用 Claude，無跨模型審查
切回 full:   export KIT_PROFILE=full
```
solo 模式下「review」= fresh-context 自審（拿到狀態/時間隔離，**不是**模型
隔離）。AI 會主動告訴你 isolation 已降級——這是設計，不是 bug。

---

*痛點驅動文件。每跑 5–10 個專案，回來補一個新的修飾語或 anti-pattern。*
