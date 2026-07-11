# Harness Self-Update Rules

> **Kit-owned.** Do not edit this copy — customize in the kit repo, then
> `init.sh --update`.

## 誰可以改什麼

| 目標 | 模型可否自行修改 |
|------|------------------|
| `.claude/rules/`、`hooks/`、`scripts/`、`agents/`、`skills/`、`docs/`、`settings.json`、`kit-version` | **不可自行修改**。kit-owned，PreToolUse hook 會攔下並轉為向 user 請示（user 在場可一鍵放行明確要求過的修改；無人值守時等同封鎖）。常規改法仍是：向 user 說明理由，在 kit repo 修改後 `--update` 鋪回。 |
| CLAUDE.md 的事實區（stack、file layout） | 可，但必須在回報中明列改了什麼。 |
| CLAUDE.md 的 constraints 區、`.claude/protected-paths` | 只能**加嚴**（新增禁區）；放寬或刪除任何一條需要 user 明確同意。 |
| `docs/LESSONS.md` | 可自由 append（格式見下）。 |
| 任何工作流 / 架構層級的調整 | 必須先徵得 user 同意，無例外。 |

規則背後的威脅模型：長期運作的模型會在「優化」名義下把擋住自己的規則
改軟——這是 harness 腐化的頭號路徑。所以規則檔的修改權不在執行規則的
模型手上。

## 規則變更紀律（kit repo 側，源自 fable-soul 的 capture loop）

向 user 提案修改 kit 規則、或在 kit repo 動手改規則時：

1. **先查覆蓋**：新失敗模式先搜現有 rules / kit-judgment 條目。已有
   條目覆蓋 = 規則被無視，不是規則缺席——加強措辭或補藉口表列，
   不新增重複條目。
2. **RED-GREEN 收據**：prompt-level 規則（rules/、dispatch 模板判斷句）
   的新增或改寫，需先確立失敗證據（RED：合成壓力場景重現，**或**
   真實 session 的失敗紀錄——LESSONS / toollog / 外部已發表收據，
   註明日期與模型），再驗證新措辭翻轉行為（GREEN）——場景與格式見
   kit repo 的 `tests/evals.md`。兩種失敗證據都拿不出 = 不知道自己
   在修什麼，不加。「這個措辭顯然沒問題」本身就是一句藉口。
3. **逐字記錄**：捕捉到模型的失敗藉口時，LESSONS 的 Error 欄記逐字
   原話——paraphrase 會丟失觸發詞。
4. **總量預算**：`.claude/rules/` 是每個 session 的固定 context 稅，
   總量上限由 kit repo 的 smoke test 把關；超標先精簡再新增。

## 教訓紀錄格式（docs/LESSONS.md，沒有就建立）

每條教訓一律四行結構：

```markdown
### YYYY-MM-DD <一句話標題>
- Context: 什麼任務、什麼環境下發生
- Error: 實際發生什麼（關鍵錯誤原文 ≤5 行）
- Solution: 最後怎麼解的
- Rule: 一句可執行的祈使句預防規則
```

寫入時機：同一個坑踩第二次之前。修完一個非顯然的 bug、繞過一個環境
陷阱、發現文件與現實不符——都值得一條。顯然的錯（typo、忘 import）
不記。

## 精簡協議（防記憶膨脹）

- `docs/LESSONS.md` 超過 **300 行或 8KB**（`wc -l` / `wc -c` 自查）：
  **先精簡再新增**。
- 精簡 = 抽象化，不是刪光：把重複出現的教訓合併成一條通用 Rule，收進
  檔頭的「Rules 清單」段；被合併的舊條目才可刪除。每條被刪的教訓必須
  能對應到一條存活的 Rule，否則不准刪。
- 精簡後在 LESSONS.md 檔頭記一行：`<!-- compacted YYYY-MM-DD: N 條 -> M 條 -->`。
