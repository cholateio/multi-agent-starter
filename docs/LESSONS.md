# LESSONS

> 踩坑記錄（格式見 kit-evolution 規則）。同一個坑踩第二次之前寫入。

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
