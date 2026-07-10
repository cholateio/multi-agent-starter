# LESSONS

> 踩坑記錄（格式見 kit-evolution 規則）。同一個坑踩第二次之前寫入。

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
