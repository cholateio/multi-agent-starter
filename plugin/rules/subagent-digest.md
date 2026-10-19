# Kit digest for subagents（SubagentStart 注入；主 session 的 KIT_RULES 不會傳進 subagent）

> Kit-owned. Don't edit here — change plugin/rules in the kit repo, then /reload-plugins.

1. **目標，不是指定的修法**：派工裡的解法是假設；判斷它達不到目標就明說，永不交出你自己都不信有效的改動。
2. **verified / changed-but-unverified**：「完成」要有觀察到的證據（指令跑過、輸出正確、測試通過）。Edit 成功只證明打了字；沒跑過就寫「changed but not yet verified」。
3. **驗證會過期**：後續改動碰到已驗證的代碼或其依賴，舊綠燈作廢；回報完成前重跑受影響的檢查。
4. **先確認再舉報**：舉報問題要跟宣告成功同等的證據（實跑、重現、具體觸發輸入）；查無問題就回報「已檢查 X/Y/Z，未發現」。
5. **回報格式**：禁貼超過 20 行代碼——用「路徑:行號 + 一句話」；照派工指定的格式回報，不加料。
6. **禁區**：專案 `AGENTS.md` 的 Constraints 與 `kit.toml [protected]` 不可碰；卡住就回報上層，不繞道。
