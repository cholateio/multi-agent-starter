# LESSONS

> 踩坑記錄（格式見 kit-evolution 規則）。同一個坑踩第二次之前寫入。

### 2026-07-25 Python round() 是銀行家捨入，在 money 顯示上會低估
- Context: `proj` 卡片把各服務月費解析成數字加總,`_fmt_amount` 對 ≥10 的值用 `int(round(v))`
- Error: `int(round(10.5)) == 10`(不是 11)——Python3 的 `round` 是 ties-to-even(銀行家捨入),不是四捨五入。range US$10-11 的中點 10.5 被顯示成 US$10,「取中點」悄悄變成「取下界」,money 總和被低估。codex review P2 抓到;真實機隊沒踩到(唯一的 range US$2-3 中點 2.5 <10 走保留小數的分支)
- Solution: 非整數一律保留 1 位小數(`round(v,1)` 後判斷是否整數),不做 int 捨入
- Rule: 對金額/計量做四捨五入別用裸 `round()`/`int(round())`——那是銀行家捨入,.5 會往偶數靠而非往上,在錢的顯示上是系統性低估。要真四捨五入用 `Decimal(ROUND_HALF_UP)` 或保留小數不捨。

### 2026-07-25 在共用路徑上新增驗證，把一個專案的壞欄位變成全機隊當機
- Context: 給 `proj` 的 manifest 加指令長度上限,檢查寫在 `load_manifest()`——那是 `proj`／`proj money`／`proj html` 全都會走的共用路徑
- Error: `for k, v in (data.get("commands") or {}).items()` 遇到合法 TOML 但非 table 的 `commands = ["echo hi"]` 直接 `AttributeError`。改動前那個專案只是「沒指令」照樣列出;改動後**整份跨專案總覽**連同其他 15 個健康專案一起掛掉(smoke 52 條連帶失敗)。codex review P2 抓到,我先在 main 版跑同一份 fixture 確認是回歸才修
- Solution: 型別守門 + 降級忽略(`isinstance(c, dict)`,非 table 就 warn 後當成沒有),三個消費點(`load_manifest`／`cmd_detail`／`_collect`)一起封
- Rule: 在「彙總多個來源」的共用路徑上新增驗證前,先問**壞資料會炸掉誰**——彙總工具的爆炸半徑是全體來源,不是那一筆。對外部/user-owned 資料一律先驗型別再迭代,壞的那筆降級忽略並 warn,不讓它中止整批。

### 2026-07-24 綁實作字串的否定斷言＝永遠綠的空斷言
- Context: 把 `proj html` 的卡片列從單欄改成三欄網格，改完跑 proj-smoke
- Error: `assert_not_contains "html: no three-column grid" "$HTML" "repeat(auto-fill"` 照樣 PASS——它比對的是**舊實作用過的字串**，新寫法 `repeat(3,minmax(0,1fr))` 不含它，所以不管版面變成幾欄都會通過。這是 proj-smoke 第二次出現過期斷言（前次 ea0f8f2/4ed2254：按用量組藏月費估計的斷言活過設計反轉）
- Solution: 翻成正面斷言，鎖住意圖而非殘骸——`assert_contains ... "grid-template-columns:repeat(3,minmax(0,1fr))"` 再加一條窄視窗降級斷言；1440/900/600 三個寬度各 headless 截圖確認 3/2/1 欄
- Rule: 否定斷言（assert_not_contains）只有在比對「唯一可能的違規寫法」時才成立——否則寫成正面斷言鎖住想要的狀態。設計反轉時先 grep 測試檔裡描述舊設計的斷言，全綠不代表沒有空斷言。

### 2026-07-24 中文行內註解的非 ASCII 位元組滲進 secret，爆 gateway 認證
- Context: connector 從 `.env` 抓 HERMES_KEY 傳給 Hermes gateway 做 Bearer 認證
- Error: `.env` 的 key 行尾跟了中文 `#` 註解，`cut -d= -f2` 沒剝行內註解，把中文的 byte `0xA7`（§）一起塞進 token → gateway `token.encode()` 對第 74 位字元爆 500；七輪 curl 全帶著壞 key（中途還踩 MSYS `/d/` 路徑把 KEY 抓成空 → 401，反向印證 500 是壞 key 字元）
- Solution: 改 connector 的 .env 讀法 `partition('=')→split('#')→strip`（剝引號與行內註解）；真 key 118→64 字元，認證通過。並立語言規則（見 kit-workflow 註解紀律）
- Rule: 代碼內註解一律英文；config/secret 檔案的值行絕不放非 ASCII（含中文行內註解）——會滲進 token／編碼等 byte 敏感語境。抓 .env 值用 partition/split/strip，不要裸 `cut`

### 2026-07-12 小改門檻把測試檔算進業務檔，越補測試越容易破檻
- Context: 部署專案裡一次 margin 調整（真正的 CSS 改動 19 行）觸發跨模型 review——共用元件連動 3 個測試檔，合計 6 檔 55 行，SMALL_MAX_FILES=2 先爆
- Error: small_change_allow 的 business file 判定只看副檔名，測試檔照算；「元件 + 其測試」= 2 檔即頂格，誘因反向（越認真補測試越容易被罰跑 review）
- Solution: v4.5 測試檔（test_*/_test./.test./.spec./tests?/ 等）從檔案數與行數兩個計數排除、SMALL_MAX_FILES 2→4；敏感命名測試檔（test_auth.py）不享排除；行數上限 50 與敏感路徑 size-blind 不動。smoke RED-GREEN：兩條新斷言在舊 hook 下失敗、新 hook 下通過，並以事故原 numstat 形狀重放驗證放行
- Rule: gate 門檻的計數單位要對齊它想擋的東西（未審業務邏輯），別讓驗證產物（測試）成為破檻主力；照字面只排除檔案數會修不到行數那半（55>50 照樣擋）。

### 2026-07-10 `git add .claude` 會一併收進執行期狀態檔
- Context: 機隊決定把 `.claude/` 從 gitignore 翻成 track（settings.json 的核可清單與 protected-paths 不可重建，不該只存在一顆硬碟上）
- Error: `git add .claude` 在 kaf-observatory 收進 `.claude/scheduled_tasks.lock`——內容是 `{"sessionId":...,"pid":16304,"acquiredAt":...}`，5 月殘留的執行期鎖檔，pid 與 sessionId 對別台機器毫無意義
- Solution: `git rm --cached` + gitignore 該檔；kit 的 `templates/gitignore` 補上 `.claude/settings.local.json` 與 `.claude/scheduled_tasks.lock` 兩行，讓新專案不再重踩
- Rule: 把一個目錄整包納入版控前，先列出它的實際內容（`find <dir> -type f`）並逐檔問「這在另一台機器上還有意義嗎」——工具目錄裡混著設定、產物與執行期狀態，`git add <dir>` 不會替你分辨。

### 2026-07-10 review marker 只在 gate 走到 marker 檢查時才被消耗
- Context: v4.3 hooks-smoke 加小改放行測項，cleanup 步驟順手寫了顆 marker 再跑 gate
- Error: 該次 stop 的 porcelain 是乾淨的 → gate 走「無變更 → advance+exit」路徑，根本沒碰 marker 檢查；marker 殘留，被**下一個場景**吃掉，把 5 行的 auth.py 變更放行（h2r 假失敗，實為測試自己污染狀態）
- Solution: cleanup 不寫 marker（無變更路徑自己會 advance baseline）＋加 `assert_file_absent` 鎖住「無 marker 殘留」
- Rule: 寫 marker 前先確認該次 stop 真的有待審變更——乾淨樹的 stop 不消耗 marker，殘留的 marker 會替未來的變更背書。debug 測試 suite 時，先驗證 fixture 狀態序列，再懷疑被測程式。

### 2026-07-05 rebase 會摧毀剛 untrack 的 gitignored 檔案
- Context: 給 6 個專案部署 kit 並 untrack `.claude/`（`git rm --cached` + gitignore），life-tracker 的 push 被 crawler bot commit 擋下，改走 `pull --rebase`
- Error: rebase checkout origin/main 時，gitignored 的 untracked `.claude` 檔被舊 tracked 版本**靜默覆蓋**（gitignored 路徑不受 checkout 的 untracked-file 保護）；replay untrack commit 後 `settings.json` 與三個 hook/skill 檔從磁碟消失
- Solution: 重跑 `init.sh --update`（deploy-if-absent 補回 settings.json，kit-owned 集合強制同步）；再逐檔對 kit 的 `git ls-files .claude/` 比對完整性
- Rule: 「untrack + gitignore 某目錄」的 commit 若經歷 rebase / checkout / branch 切換，完成後必須重跑 `--update` 並驗證該目錄完整性——不要假設 untracked 檔在 git 操作中安全。
