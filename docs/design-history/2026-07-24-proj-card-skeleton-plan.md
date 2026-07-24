# proj dashboard 卡片骨架重寫 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 存放位置說明：skill 預設是 `docs/superpowers/plans/`，本 repo 既有慣例是
> `docs/design-history/YYYY-MM-DD-*.md`（3 個同類範例），照慣例走，不新開子樹。

**Goal:** 讓 `proj html` 的卡片有一副固定骨架（左側標籤欄），並讓版面不再被單一超長欄位值炸掉。

**Architecture:** 三層獨立生效，由上而下：(1) 卡片改成「標籤欄 + 值欄」的 CSS grid，四條 band（現況／下一步／指令／花費）順序固定、空的整條不出現；(2) 渲染端對 `monthly_est` 與指令字串夾擊（截斷顯示、完整值進 `title`，複製 payload 不動）；(3) `proj` 對 manifest 新增兩條 warning（指令長度、`monthly_est` 成分），並同步 `.claude/rules/project-manifest.md`。三層都做完，dashboard 的整齊度不再依賴 16 個專案的資料紀律。

**Tech Stack:** Python 3.11+ 標準庫（`tomllib`/`html`/`unicodedata`/`re`），零第三方依賴；測試是 `tests/proj-smoke.sh`（bash 斷言腳本，非 pytest）。

## Global Constraints

- `bin/proj` 維持**零第三方依賴**、Python 3.11+。
- 產出的 HTML 必須**自包含**：零外部 http(s)、`<link>`、`src=`（既有斷言在守）。
- 代碼內註解一律**英文以外的規則例外**：本 repo 既有 `bin/proj` 全檔中文註解，照既有慣例續用中文（kit-workflow 註解紀律要求的是「不放進 config/secret 值行」，非禁止註解語言於一般原始碼；沿用檔案現況）。註解只寫不變量／耦合／why／收據四類。
- 不得引入 `white-space:nowrap` 字串到 CSS——既有斷言 `html: cmd code has no nowrap scroll` 以全檔字串比對在守（要防的是指令碼區不換行）。
- 複製按鈕的 `data-cmd` 永遠是**完整指令**，截斷只影響顯示。
- 每個 task 結束前跑 `bash tests/proj-smoke.sh`，必須 0 failed。
- Task 1／2 結束前必須**截圖**（headless Chrome，1440px）親眼比對；沒截圖 = visually unverified（`.claude/docs/verification-signals.md` S1）。

## 派工檔位建議（kit-workflow 要求）

| Task | 建議 MAIN 模型 / effort | 理由 | 升級觸發 |
|------|------------------------|------|----------|
| 1 卡片骨架 | Opus 4.8 / medium | 版面結構決策 + CSS grid 對齊，改錯了整張卡歪掉 | 截圖後標籤欄仍不對齊 → high effort |
| 2 渲染端夾擊 | Sonnet 5 / low-medium | 介面已凍結（`_clamp` 簽章寫死在本檔），機械性套用 | CJK 寬度截斷出現半形錯位 → 升 Opus 4.8 |
| 3 schema 執法 | Opus 4.8 / medium | 動 `.claude/rules/`，措辭要過 kit-evolution 的 RED-GREEN 紀律 | 無 |

---

## File Structure

- `bin/proj`（修改，唯一的實作檔）
  - `_CSS`：`.c-body` 改 grid、新增 `.band-k`/`.band-v`、`.cmds`/`.costs` 改 grid、刪 `.note`/`.note-list`/`.cost-row`
  - `_render_cards()`：改成 band 組裝
  - `_render_note()`：刪除，語意由 `_render_bands()` 承接
  - `_clamp()`：新增
  - `load_manifest()`：新增兩條 warning
- `tests/proj-smoke.sh`（修改）：新增／改寫斷言 + 兩個新 fixture
- `.claude/rules/project-manifest.md`（修改）：補指令長度上限與 `monthly_est` 成分規則

---

## Task 1: 卡片骨架（左側標籤欄）

**Files:**
- Modify: `bin/proj`（`_CSS` 約 283-330、`_render_note()` 418-425、`_render_cards()` 428-470）
- Test: `tests/proj-smoke.sh`

**Interfaces:**
- Produces: `_render_bands(r) -> str`——吃一列 `_collect()` 的 dict，回傳 `<div class="c-body">…</div>` 完整字串。Task 2 會在它內部套 `_clamp()`。
- Consumes: `_collect()` 既有的 row dict（keys: `name/status/skey/note/commands/paid/commit/stale`），不改其形狀。

- [ ] **Step 1: 寫失敗的斷言**

在 `tests/proj-smoke.sh` 的 `assert_contains "html: card body column present" "$HTML" "c-body"` 那行**之後**插入：

```bash
# 卡片骨架:四條 band 標籤固定,值欄共用同一條左邊界(CSS grid 的第二欄)
assert_contains "html: body is a label/value grid" "$HTML" ".c-body{display:grid;grid-template-columns:max-content minmax(0,1fr)"
assert_contains "html: 現況 band labelled" "$HTML" '<span class="band-k">現況</span>'
assert_contains "html: 下一步 band labelled" "$HTML" '<span class="band-k">下一步</span>'
assert_contains "html: 指令 band labelled" "$HTML" '<span class="band-k">指令</span>'
assert_contains "html: 花費 band labelled" "$HTML" '<span class="band-k">花費</span>'
# status_note 兩段拆進兩條 band,不再是無標籤 bullet
assert_contains "html: note seg1 goes to 現況" "$HTML" '<div class="band-v now">單影片可用</div>'
assert_contains "html: note seg2 goes to 下一步" "$HTML" '<div class="band-v next">批次待做</div>'
assert_not_contains "html: old bullet note list gone" "$HTML" "note-list"
# 空的 band 整條不出現。**注意兩個實作時才發現的坑**:(a) longtext-proj 是 Task 2 才
# 建立的 fixture,Task 1 階段預期值是 1,Task 2 再改成 2;(b) grep -c 數的是「行數」,
# 整份 HTML 只有一行 → 恆為 1,要數出現次數必須 grep -o | wc -l
CMD_BANDS="$(printf '%s\n' "$HTML" | grep -o '<span class="band-k">指令</span>' | wc -l)"
assert_eq "html: 指令 band only for projects with commands" "$CMD_BANDS" "1"
```

同時**刪除**既有這兩行（它們斷言的是被取代的舊結構）：

```bash
assert_contains "html: status_note split into list items" "$HTML" "<li>批次待做"
assert_contains "html: free-tier sorts last, no amount" "$HTML" '</span></div><div class="cost-row"><span class="paid paid-free">Supabase</span></div>'
```

並把 free-tier 那條改寫成 grid 版（free-tier 顯 `—` 佔住第二欄，維持格線）：

```bash
assert_contains "html: free-tier sorts last, shows dash" "$HTML" '<span class="paid paid-free">Supabase</span><span class="cost-amt">—</span>'
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `bash tests/proj-smoke.sh 2>&1 | grep -E "^FAIL|passed"`
Expected: 多條 FAIL（`missing text: [.c-body{display:grid...]` 等），`passed N, failed 8` 之類。

- [ ] **Step 3: 改 CSS**

`bin/proj` 的 `_CSS` 中，把這段：

```
.c-body{flex:1 1 auto;min-width:0;display:flex;flex-direction:column;gap:9px}
```

替換成：

```
.c-body{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 12px;align-items:baseline;min-width:0}
.band-k{font-size:11px;color:var(--mut)}
.band-v{min-width:0;font-size:13px}
.band-v.next{color:var(--mut)}
```

把這兩行刪掉（`.note` / `.note-list` 已無使用者）：

```
.note{margin:0;color:var(--mut);font-size:13px}
.note-list{margin:0;padding-left:18px;color:var(--mut);font-size:13px}
.note-list li{margin:2px 0}
```

把 `.cmds` 三行：

```
.cmds{list-style:none;padding:0;margin:0;display:flex;flex-wrap:wrap;gap:6px 14px}
.cmds li{display:flex;align-items:baseline;gap:6px;font-size:12px;min-width:0}
.cmd-k{color:var(--mut)}
```

替換成（三欄 grid：key / code / copy，key 與 code 各自對齊）：

```
.cmds{display:grid;grid-template-columns:max-content minmax(0,1fr) max-content;gap:5px 8px;align-items:baseline}
.cmds>*{min-width:0}
.cmd-k{color:var(--mut);font-size:11px}
```

把 `.costs` / `.cost-row` 兩行：

```
.costs{display:flex;flex-direction:column;gap:4px}
.cost-row{display:flex;align-items:baseline;gap:8px;min-width:0}
```

替換成（兩欄 grid：服務 badge / 金額）：

```
.costs{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:5px 8px;align-items:baseline}
```

- [ ] **Step 4: 改渲染**

刪除整個 `_render_note()` 函式（`bin/proj:418-425`），新增 `_render_bands()`，並改寫 `_render_cards()`。把 `_render_note` 與 `_render_cards` 兩個函式整段替換成：

```python
def _render_bands(r):
    """四條 band 順序固定、標籤固定、值欄共用同一條左邊界(CSS grid 第二欄);
    空的 band 整條不輸出。status_note 的契約是「目前進度;下一步」——schema 保證的
    這個結構原本在渲染時被丟掉(兩顆無標籤 bullet),現在標回去。"""
    cells = []

    def band(label, value_html):
        if value_html:
            cells.append(f'<span class="band-k">{label}</span>{value_html}')

    segs = [s.strip() for s in str(r["note"]).replace("；", ";").split(";") if s.strip()]
    band("現況", f'<div class="band-v now">{_e(segs[0])}</div>' if segs else '')
    # 3 段以上是違規資料(proj 已 warn),渲染端不吞——併進「下一步」照顯,別靜默丟資料
    band("下一步", f'<div class="band-v next">{_e("；".join(segs[1:]))}</div>' if len(segs) > 1 else '')

    # 收錄規範在 manifest schema 端執法(kit rule:只收「用它」的指令),
    # 渲染端不做啟發式過濾——manifest 有什麼顯什麼
    if r["commands"]:
        items = "".join(
            f'<span class="cmd-k">{_e(k)}</span><code>{_e(v)}</code>'
            f'<button class="copy" data-cmd="{_e(v)}" title="複製">C</button>'
            for k, v in r["commands"].items())
        band("指令", f'<div class="band-v"><div class="cmds">{items}</div></div>')

    # 花費就長在卡片上——原本卡片只掛服務名、金額另開一張表,要看「這個專案花多少」
    # 得在兩個區塊之間對照專案名。free-tier 沉底且以 — 佔住金額欄(恆為 $0,寫出來是雜訊,
    # 但空著會讓格線斷掉);按用量靠 .paid-usage 的警示色標示,不需要獨立的「計費」欄。
    if r["paid"]:
        ordered = sorted(r["paid"],
                         key=lambda p: _paid_bucket(str(p.get("billing", ""))) == "free")
        items = []
        for p in ordered:
            b = _paid_bucket(str(p.get("billing", "")))
            amt = "—" if b == "free" else str(p.get("monthly_est", "?"))
            items.append(f'<span class="paid paid-{b}">{_e(p.get("service", "?"))}</span>'
                         f'<span class="cost-amt">{_e(amt)}</span>')
        band("花費", f'<div class="band-v"><div class="costs">{"".join(items)}</div></div>')

    return f'<div class="c-body">{"".join(cells)}</div>' if cells else ''


def _render_cards(rows):
    cards = []
    for r in rows:
        badge = f'<span class="badge" data-status="{_e(r["skey"])}">{_e(r["status"])}</span>'
        stale = '<span class="stale" title="manifest 可能過時">⚠</span>' if r["stale"] else ''
        cards.append(
            f'<article class="card" data-status="{_e(r["skey"])}">'
            f'<div class="c-head"><div class="c-badge">{badge}{stale}'
            f'<span class="commit">{_e(r["commit"])}</span></div>'
            f'<h3>{_e(r["name"])}</h3></div>'
            f'{_render_bands(r)}</article>')
    return '<section class="cards">' + "".join(cards) + '</section>'
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/proj-smoke.sh 2>&1 | grep -E "^FAIL|passed"`
Expected: `passed N, failed 0`

- [ ] **Step 6: 截圖親眼驗（S1，不可省）**

```bash
cd /tmp && env PROJ_ROOT="$HOME" ~/multi-agent-starter/bin/proj html >/dev/null 2>&1
WIN=$(wslpath -w ~/.local/share/proj/dashboard.html)
"/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" --headless --disable-gpu \
  --window-size=1440,1500 --screenshot="$(wslpath -w /tmp/card-skeleton.png)" "$WIN"
```

親眼確認三件事：四條 band 的標籤欄等寬且左邊界一致；值欄全部對齊同一條垂直線；空 band 的卡片沒有留下空行。任一項不成立 → 回 Step 3 調 grid，不要繼續。

- [ ] **Step 7: Commit**

```bash
git add bin/proj tests/proj-smoke.sh
git commit -m "feat(proj): 卡片改固定骨架——四條 band 左側標籤欄,status_note 兩段標回現況/下一步"
```

---

## Task 2: 渲染端夾擊（超長值不再炸版）

**Files:**
- Modify: `bin/proj`（`disp_width()` 附近新增 `_clamp()`；`_render_bands()` 的指令與花費兩段）
- Test: `tests/proj-smoke.sh`

**Interfaces:**
- Consumes: Task 1 的 `_render_bands()`；既有 `disp_width(s) -> int`。
- Produces: `_clamp(s, width) -> (display: str, title: str)`——`title` 為空字串代表沒截斷。CJK 算 2 格，與 `disp_width` 同一把尺。

- [ ] **Step 1: 寫失敗的斷言**

在 `tests/proj-smoke.sh` 的 fixture 區（`# 排序測試用` 那段之前）新增一個超長值 fixture：

```bash
# 夾擊測試用:120 字指令與 37 字 monthly_est(真實機隊資料的形狀,見 2026-07-24 量測)
mkdir -p "$ROOT/longtext-proj"
cat > "$ROOT/longtext-proj/PROJECT.toml" <<'EOF'
name = "longtext-proj"
status = "active"
status_note = "長字串測試;維持現狀"

[commands]
fetch = "uv run python -m quant.data.taifex_fetch --root data/raw --start $(date -d '-14 days' +%F) --end $(date -d '-1 day' +%F)"

[[paid]]
service = "Longname Service"
billing = "月費"
monthly_est = "NT$260/年（≈NT$22/月，user 2026-07-11 確認）"
EOF
```

在 HTML 斷言區新增：

```bash
# 超長值截斷顯示,完整值進 title;複製 payload 必須完整(截斷只影響顯示)
assert_contains "html: long command clamped in display" "$HTML" "…</code>"
assert_contains "html: full command kept in title" "$HTML" 'title="uv run python -m quant.data.taifex_fetch --root data/raw --start'
# 注意:斷言字串一律用單引號,fixture 裡的 $(date …) 是**字面值**,雙引號會被 bash 展開成
# 今天的日期而永遠對不上。這條斷言本身就在證明 data-cmd 未被截斷(子字串已超過 56 格上限)
assert_contains "html: copy payload stays complete" "$HTML" 'data-cmd="uv run python -m quant.data.taifex_fetch --root data/raw --start'
assert_contains "html: long monthly_est clamped" "$HTML" '<span class="cost-amt" title="NT$260/年（≈NT$22/月，user 2026-07-11 確認）">'
# 短值不該被加上 title(沒截斷就沒 title,避免整片 hover 噪音)
assert_contains "html: short cost has no title" "$HTML" '<span class="cost-amt">~$3</span>'
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `bash tests/proj-smoke.sh 2>&1 | grep -E "^FAIL|passed"`
Expected: `FAIL html: long command clamped in display (missing text: […</code>])` 等 4 條。

- [ ] **Step 3: 實作 `_clamp()`**

在 `bin/proj` 的 `pad()` 函式**之後**（`print_table()` 之前）插入：

```python
# 卡片欄位的顯示上限(顯示格數,CJK 算 2)。manifest 端也有上限並會 warn,但渲染端
# 必須自保:dashboard 的整齊度不能綁在 15 個專案的資料紀律上(2026-07-24 量測:
# monthly_est 1-41 字、指令 14-120 字)。截斷只影響顯示,複製 payload 永遠完整。
CARD_CMD_MAX = 56   # 實作時量到 56 仍會折行,最終定 34(見 52e552d)
CARD_EST_MAX = 22


def _clamp(s, width):
    """回傳 (顯示字串, title)。未截斷時 title 為空字串——沒截斷就不掛 title,
    否則整片 hover 提示變成噪音。"""
    s = str(s)
    if disp_width(s) <= width:
        return s, ""
    out, used = [], 0
    for ch in s:
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if used + w > width - 1:
            break
        out.append(ch)
        used += w
    return "".join(out) + "…", s
```

- [ ] **Step 4: 在 `_render_bands()` 套用**

指令段的 `items = "".join(...)` 替換成：

```python
        cmd_cells = []
        for k, v in r["commands"].items():
            disp, full = _clamp(v, CARD_CMD_MAX)
            t = f' title="{_e(full)}"' if full else ''
            cmd_cells.append(
                f'<span class="cmd-k">{_e(k)}</span><code{t}>{_e(disp)}</code>'
                f'<button class="copy" data-cmd="{_e(v)}" title="複製">C</button>')
        items = "".join(cmd_cells)
```

花費段的 `items.append(...)` 那兩行替換成：

```python
            disp, full = _clamp(amt, CARD_EST_MAX)
            t = f' title="{_e(full)}"' if full else ''
            items.append(f'<span class="paid paid-{b}">{_e(p.get("service", "?"))}</span>'
                         f'<span class="cost-amt"{t}>{_e(disp)}</span>')
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/proj-smoke.sh 2>&1 | grep -E "^FAIL|passed"`
Expected: `passed N, failed 0`

- [ ] **Step 6: 截圖確認沒有任何一張卡被單一長字串撐開**

```bash
cd /tmp && env PROJ_ROOT="$HOME" ~/multi-agent-starter/bin/proj html >/dev/null 2>&1
WIN=$(wslpath -w ~/.local/share/proj/dashboard.html)
"/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" --headless --disable-gpu \
  --window-size=1440,1500 --screenshot="$(wslpath -w /tmp/card-clamp.png)" "$WIN"
```

親眼確認：quant 的 `taifex_fetch` 指令縮成一行、anatomy-rag 的 41 字 `monthly_est` 不再換行。

- [ ] **Step 7: Commit**

```bash
git add bin/proj tests/proj-smoke.sh
git commit -m "feat(proj): 卡片欄位渲染端夾擊——超長指令與月費估計截斷顯示,完整值進 title"
```

---

## Task 3: manifest schema 執法（指令長度 + monthly_est 成分）

**Files:**
- Modify: `bin/proj`（檔頭常數區、`load_manifest()`）
- Modify: `.claude/rules/project-manifest.md`
- Test: `tests/proj-smoke.sh`

**Interfaces:**
- Consumes: Task 2 的 `longtext-proj` fixture（120 字指令 + 含確認日期的 `monthly_est`），不需新增 fixture。
- Produces: 兩條新 stderr warning，格式沿用既有 `warn()`（`proj: <name>: …`）。

**RED 收據（kit-evolution 要求）：** 2026-07-24 對機隊 16 個 manifest 實測——`monthly_est` 最長 41 字（已違反現行 40 字上限，但成分規則無執法，`NT$260/年（≈NT$22/月，user 2026-07-11 確認）` 這種夾帶確認日期的值合乎長度卻違反「只放金額與用量」）；`commands` 值長 14-120 字，schema 對指令長度**完全沒有上限**。

- [ ] **Step 1: 寫失敗的斷言**

在 `tests/proj-smoke.sh` 的 list 斷言區（`assert_contains "list: non-string status warns but stays listed" "$ERR" "weird-proj"` 之後）新增：

```bash
# schema 執法:指令長度上限、monthly_est 不得夾帶確認日期/算法依據(2026-07-24 量測)
assert_contains "list: over-long command warns" "$ERR" "上限 80"
assert_contains "list: monthly_est with a receipt date warns" "$ERR" "收據歸 TOML 註解"
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `bash tests/proj-smoke.sh 2>&1 | grep -E "^FAIL|passed"`
Expected: `FAIL list: over-long command warns (missing text: [上限 80])` 與 `FAIL list: monthly_est with a receipt date warns`。

- [ ] **Step 3: 加常數與 import**

`bin/proj` 檔頭 `import` 區的 `import os` 之後插入一行：

```python
import re
```

`MONTHLY_EST_MAX = 40` 之後插入：

```python
# 指令長度上限。基準：2026-07-24 機隊量測中位數 24 字,超過 80 的只有一條(quant 的
# 120 字 taifex_fetch,含兩個 $(date) 展開)——那種長度該包成腳本再收錄,不是貼進 manifest。
COMMAND_MAX = 80
# monthly_est 只放金額與用量。確認日期（"user 2026-07-11 確認"）與算法依據是收據,
# 歸 TOML 註解——規則本來就這樣寫,但只有長度被執法,成分沒有,所以違規值長期存活。
_EST_RECEIPT = re.compile(r"\d{4}-\d{2}-\d{2}|確認")
```

- [ ] **Step 4: 在 `load_manifest()` 加兩條 warning**

在 `load_manifest()` 中 `for p in data.get("paid", []):` 迴圈**之前**插入：

```python
    for k, v in (data.get("commands") or {}).items():
        if isinstance(v, str) and len(v) > COMMAND_MAX:
            warn(f"{d.name}: 指令 {k} {len(v)} 字(上限 {COMMAND_MAX})"
                 f"——包成腳本再收錄,卡片一行放不下")
```

在同一函式中既有的 `monthly_est` 長度檢查（`if isinstance(m, str) and len(m) > MONTHLY_EST_MAX:` 那個 `warn` 之後）追加：

```python
        if isinstance(m, str) and _EST_RECEIPT.search(m):
            warn(f"{d.name}: {s} 的 monthly_est 夾了確認日期／算法依據"
                 f"——只放金額與用量,收據歸 TOML 註解")
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/proj-smoke.sh 2>&1 | grep -E "^FAIL|passed"`
Expected: `passed N, failed 0`

- [ ] **Step 6: 同步規則檔**

`.claude/rules/project-manifest.md` 的 `[commands]（寧缺勿濫）` 段落末尾追加一句：

```markdown
單條指令上限 **80 字**（`proj` 會 warn）——超過代表該包成腳本再收錄，卡片一行放不下。
```

同檔 `monthly_est` 那一項改成（加粗成分規則，長度規則不動）：

```markdown
- `monthly_est`：只放金額與用量（`NT$128/月;Actions 用量估 2000+ 分/月`），
  上限 40 字，且**不得夾帶確認日期或算法依據**（`proj` 對 `YYYY-MM-DD` 與
  「確認」二字會 warn）。怎麼算出來的、確認日期、月上限設定——全歸 TOML 註解。
```

- [ ] **Step 7: 確認機隊現況會被點名（GREEN 收據）**

Run: `env PROJ_ROOT="$HOME" bin/proj 2>&1 >/dev/null | sort | uniq -c | sort -rn | head -20`
Expected: 逐條列出違規的專案與欄位（預期至少命中 `portfolio-cholate` / `cholate-blog` 的 `NT$260/年（… user 2026-07-11 確認）` 與 `quant` 的 120 字指令）。把實際輸出貼進完成報告——這是規則生效的證據，不是猜測。

**注意**：這一步只是「點名」，**不要**代替 user 去改那 16 個 `PROJECT.toml`——manifest 是 user-owned，改哪些、怎麼改由 user 決定。

- [ ] **Step 8: Commit**

```bash
git add bin/proj tests/proj-smoke.sh .claude/rules/project-manifest.md
git commit -m "feat(proj): manifest 加嚴——指令 80 字上限、monthly_est 禁夾確認日期,兩條 warning 執法"
```

---

## 收尾（全部 task 完成後）

- [ ] 跑完整測試：`bash tests/proj-smoke.sh` 與 `bash tests/smoke.sh`，兩者都要 0 failed
- [ ] 三個寬度截圖複驗：1440 / 900 / 600 → 3 / 2 / 1 欄，卡片同列等高
- [ ] `/kit-review`（本輪累計變更已遠超 150 行門檻，final review 不可省；full profile = `/codex:review` 跨模型隔離）
- [ ] review 打回的問題修完後，**重跑**測試與截圖（stale-green reset：改動後先前的綠燈作廢）
