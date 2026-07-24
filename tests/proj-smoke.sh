#!/usr/bin/env bash
# tests/proj-smoke.sh - acceptance tests for bin/proj (kit v4.4, spec §6-7)
#
# 隔離手法比照 smoke.sh:mktemp fixture、絕不碰 kit repo、PASS/FAIL 計數。
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$KIT_ROOT/bin/proj"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/proj-smoke.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi }
assert_contains() { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing text: [$3]"; fi }
assert_not_contains() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "unexpectedly contains: [$3]"; else pass "$1"; fi }
assert_file_exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi }

if [ ! -x "$PROJ" ]; then
  echo "FAIL setup (bin/proj not found/executable at $PROJ)"
  echo "passed 0, failed 1"; exit 1
fi

# --- fixtures: 正常 manifest / 無 manifest 純 git / 壞 TOML / 隱藏目錄 ---
ROOT="$WORK/root"
mkdir -p "$ROOT/good-proj" "$ROOT/bare-proj/.git" "$ROOT/broken-proj" "$ROOT/.hidden"

cat > "$ROOT/good-proj/PROJECT.toml" <<'EOF'
name = "good-proj"
status = "mvp"
status_note = "單影片可用;批次待做"
updated = 2020-01-01

[commands]
dev = "pnpm dev"
summary = "uv run good-proj <url>"

[[paid]]
service = "OpenAI API"
billing = "按用量"
monthly_est = "NT$150/月"
cancel = "拿掉 .env 的 key"

[[paid]]
service = "Supabase"
billing = "free-tier"
monthly_est = "$0"
EOF

printf 'name = "broken\n' > "$ROOT/broken-proj/PROJECT.toml"

# 合法 TOML 但 status 不是字串(codex review P2:不可 hash 的型別不能炸掉整個列表)
mkdir -p "$ROOT/weird-proj"
printf 'name = "weird-proj"\nstatus = ["active"]\n' > "$ROOT/weird-proj/PROJECT.toml"

# HTML 轉義測試用:status_note 含 < > & (proj html 必須跳脫,不得原樣注入)
mkdir -p "$ROOT/xss-proj"
cat > "$ROOT/xss-proj/PROJECT.toml" <<'EOF'
name = "xss-proj"
status = "active"
status_note = "note with <script>alert(1)</script> & ampersand"
EOF

# 合法 TOML 但 commands 不是 table(codex review P2):新的長度檢查會對它呼叫 .items(),
# 讓整個 proj 列表掛掉——壞掉一個專案的欄位不該炸掉其他 15 個專案的總覽
mkdir -p "$ROOT/badcmd-proj"
printf 'name = "badcmd-proj"\nstatus = "done"\ncommands = ["echo hi"]\n' > "$ROOT/badcmd-proj/PROJECT.toml"

# status_note 首段為空(codex review P2):過濾空段會把第 2 段推到 index 0,
# 於是「下一步」被標成「現況」——語意反轉
mkdir -p "$ROOT/note-proj"
printf 'name = "note-proj"\nstatus = "done"\nstatus_note = ";deploy next"\n' > "$ROOT/note-proj/PROJECT.toml"

# 花費總和測試用:同幣別相加、不同幣別分列、range 取中點、? 標未估、free 不計入
mkdir -p "$ROOT/cost-proj"
cat > "$ROOT/cost-proj/PROJECT.toml" <<'EOF'
name = "cost-proj"
status = "done"
[[paid]]
service = "Fixed NT"
billing = "月費"
monthly_est = "NT$100/月"
[[paid]]
service = "Usage US"
billing = "按用量"
monthly_est = "US$2-3/月"
[[paid]]
service = "Unknown"
billing = "按用量"
monthly_est = "?"
[[paid]]
service = "FreeSvc"
billing = "free-tier"
monthly_est = "$0"
EOF

# range 中點 ≥10 不得被 int 捨入吃掉小數(US$10-11 → 10.5,不是 10——低估半塊)
mkdir -p "$ROOT/round-proj"
printf 'name = "round-proj"\nstatus = "done"\n[[paid]]\nservice = "R"\nbilling = "按用量"\nmonthly_est = "US$10-11/月"\n' > "$ROOT/round-proj/PROJECT.toml"

# 全 free-tier → 花費顯示「免費」
mkdir -p "$ROOT/freeonly-proj"
printf 'name = "freeonly-proj"\nstatus = "done"\n[[paid]]\nservice = "OnlyFree"\nbilling = "free-tier"\nmonthly_est = "$0"\n' > "$ROOT/freeonly-proj/PROJECT.toml"

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

# 排序測試用:與 xss-proj 同為 active,但有 git commit(xss-proj 無 → "-" 沉組底)
mkdir -p "$ROOT/recent-proj"
cat > "$ROOT/recent-proj/PROJECT.toml" <<'EOF'
name = "recent-proj"
status = "active"
updated = 2026-07-24
EOF

# run: $@ = proj args; sets OUT / ERR / CODE
run() {
  OUT="$(env PROJ_ROOT="$ROOT" "$PROJ" "$@" 2>"$WORK/stderr")"; CODE=$?
  ERR="$(cat "$WORK/stderr")"
}

# --- proj (list) ---
run
assert_eq "list: exit 0" "$CODE" "0"
assert_contains "list: good-proj status shown" "$OUT" "mvp"
assert_contains "list: non-free service \$-marked" "$OUT" "\$OpenAI API"
assert_not_contains "list: free-tier not \$-marked" "$OUT" "\$Supabase"
assert_contains "list: bare-proj is 未登記" "$OUT" "未登記"
assert_contains "list: broken manifest flagged in table" "$OUT" "manifest 損壞"
assert_contains "list: parse warning on stderr" "$ERR" "解析失敗"
assert_contains "list: non-string status warns but stays listed" "$ERR" "weird-proj"
# schema 執法:指令長度上限、monthly_est 不得夾帶確認日期/算法依據(2026-07-24 量測)
assert_contains "list: over-long command warns" "$ERR" "上限 80"
# 壞掉的 commands 欄位不得炸掉整份列表(其餘 fixture 仍要列出來)
assert_contains "list: non-table commands warns" "$ERR" "commands 不是 table"
assert_contains "list: non-table commands does not abort listing" "$OUT" "badcmd-proj"
assert_not_contains "list: no traceback leaks" "$ERR" "Traceback"
assert_contains "list: monthly_est with a receipt date warns" "$ERR" "收據歸 TOML 註解"
assert_contains "list: non-string status row present" "$OUT" "weird-proj"
assert_not_contains "list: hidden dir excluded" "$OUT" ".hidden"

# --- stale 偵測: good-proj 給一個今天的 commit,updated=2020 → ⚠ ---
GIT_ID="$WORK/gitcfg"
printf '[user]\n\tname = T\n\temail = t@t.test\n' > "$GIT_ID"
gitq() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID" git -C "$ROOT/$1" "${@:2}" >/dev/null 2>&1; }
rmdir "$ROOT/good-proj/.git" 2>/dev/null || true
if gitq good-proj init -q -b main && gitq good-proj add -A && gitq good-proj commit -q -m x; then
  run
  assert_contains "list: stale manifest marked" "$OUT" "⚠"
else
  fail "list: stale manifest marked" "git fixture setup failed"
fi
gitq recent-proj init -q -b main && gitq recent-proj add -A && gitq recent-proj commit -q -m x

# --- proj <name> ---
run good-proj
assert_eq "detail: exit 0" "$CODE" "0"
assert_contains "detail: command copyable verbatim" "$OUT" "uv run good-proj <url>"
assert_contains "detail: cancel instruction shown" "$OUT" "拿掉 .env 的 key"

run no-such-proj
assert_eq "detail: unknown project exits 1" "$CODE" "1"

# --- proj money ---
run money
assert_eq "money: exit 0" "$CODE" "0"
assert_contains "money: service row shown" "$OUT" "OpenAI API"
assert_contains "money: monthly_est shown" "$OUT" "NT\$150/月"
assert_contains "money: cancel shown" "$OUT" "拿掉 .env 的 key"

# --- proj remote: gh 缺席的降級路徑(比照 smoke.sh 的受控 PATH 手法) ---
GHLESS="$WORK/ghless-bin"
mkdir -p "$GHLESS"
for t in python3 git sh; do
  p="$(type -P "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$GHLESS/$t"
done
OUT="$(env PATH="$GHLESS" PROJ_ROOT="$ROOT" "$PROJ" remote 2>&1)"; CODE=$?
assert_eq "remote: exit 1 without gh" "$CODE" "1"
assert_contains "remote: hint mentions gh CLI" "$OUT" "gh"

# --- proj html: 自包含 dashboard + 非 WSL 降級 (受控 PATH 無 explorer.exe,不觸發開啟) ---
HTMLBIN="$WORK/html-bin"
mkdir -p "$HTMLBIN"
for t in python3 git sh; do
  p="$(type -P "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$HTMLBIN/$t"
done
HTMLHOME="$WORK/html-home"
DASH="$HTMLHOME/.local/share/proj/dashboard.html"
OUT="$(env PATH="$HTMLBIN" HOME="$HTMLHOME" PROJ_ROOT="$ROOT" "$PROJ" html 2>&1)"; CODE=$?
assert_eq "html: exit 0 without explorer.exe" "$CODE" "0"
assert_file_exists "html: dashboard.html produced" "$DASH"
HTML="$(cat "$DASH" 2>/dev/null)"
assert_contains "html: project name present" "$HTML" "good-proj"
assert_contains "html: status value present" "$HTML" "mvp"
assert_contains "html: paid service present" "$HTML" "OpenAI API"
assert_contains "html: broken manifest flagged" "$HTML" "manifest 損壞"
# v4.5.2:收錄規範移到 manifest schema(kit rule),渲染層不再啟發式過濾——有什麼顯什麼
assert_contains "html: all manifest commands shown (no heuristic filter)" "$HTML" "pnpm dev"
assert_contains "html: special command shown" "$HTML" "uv run good-proj"
assert_contains "html: three-column card grid" "$HTML" "grid-template-columns:repeat(3,minmax(0,1fr))"
assert_contains "html: grid degrades on narrow viewports" "$HTML" "@media(max-width:760px){.cards{grid-template-columns:1fr}}"
assert_contains "html: cards stretch to equal height" "$HTML" ".cards{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;align-items:stretch}"
assert_contains "html: card body column present" "$HTML" "c-body"
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
# 空的 band 整條不出現:只有 good-proj(2 條指令)該長出「指令」band,
# recent/xss/weird/broken 四個 fixture 都沒有指令
# grep -c 數的是「行數」,整份 HTML 只有一行 → 恆為 1;要數出現次數必須 grep -o | wc -l
CMD_BANDS="$(printf '%s\n' "$HTML" | grep -o '<span class="band-k">指令</span>' | wc -l)"
assert_eq "html: 指令 band only for projects with commands" "$CMD_BANDS" "2"
# 超長值截斷顯示,完整值進 title;複製 payload 必須完整(截斷只影響顯示)。
# 斷言字串一律單引號:fixture 裡的 $(date …) 是字面值,雙引號會被 bash 展開成今天日期
assert_contains "html: long command clamped in display" "$HTML" "…</code>"
assert_contains "html: full command kept in title" "$HTML" 'title="uv run python -m quant.data.taifex_fetch --root data/raw --start'
assert_contains "html: copy payload stays complete" "$HTML" 'data-cmd="uv run python -m quant.data.taifex_fetch --root data/raw --start'
# dashboard 只收有 manifest 的專案:bare-proj(純 git,無 PROJECT.toml)不該出現在卡片區
assert_not_contains "html: unregistered project hidden" "$HTML" "bare-proj"
# 卡片排序:狀態活躍度 → commit 日期新舊 → 名稱。fixture 對應:
# broken-proj(損壞,排最前) / recent-proj(active,有 commit) / xss-proj(active,無 git)
# / good-proj(mvp) / weird-proj(status 認不得,排最後)
CARD_ORDER="$(printf '%s\n' "$HTML" | grep -o '<h3>[^<]*</h3>' | sed 's/<[^>]*>//g' | tr '\n' ' ')"
assert_contains "html: broken manifest surfaces first" "$CARD_ORDER" "broken-proj recent-proj"
assert_contains "html: active sorts above mvp" "$CARD_ORDER" "xss-proj good-proj"
# active 組內:recent-proj 有 commit 排前,其餘無 git("-")按名稱 longtext → xss
assert_contains "html: newer commit first within a status" "$CARD_ORDER" "recent-proj longtext-proj xss-proj"
CARD_LAST="$(printf '%s' "$CARD_ORDER" | awk '{print $NF}')"
assert_eq "html: unknown status sinks last" "$CARD_LAST" "weird-proj"
# 空的首段不得讓第 2 段被標成「現況」——band 位置照 status_note 的段序,不是壓縮後的序
assert_contains "html: empty first segment keeps 下一步 semantics" "$HTML" '<span class="band-k">下一步</span><div class="band-v next">deploy next</div>'
assert_not_contains "html: empty first segment does not become 現況" "$HTML" '<div class="band-v now">deploy next</div>'
assert_not_contains "html: cmd code has no nowrap scroll" "$HTML" "white-space:nowrap"
assert_contains "html: path printed on non-WSL" "$OUT" "dashboard.html"
# 自包含:零外部引用
assert_not_contains "html: no external http" "$HTML" "http://"
assert_not_contains "html: no external https" "$HTML" "https://"
assert_not_contains "html: no external src=" "$HTML" "src="
assert_not_contains "html: no external stylesheet" "$HTML" "<link"
# 花費長在卡片上,不再有底部總表
assert_not_contains "html: bottom money section removed" "$HTML" "花錢總覽"
assert_not_contains "html: no money tables left" "$HTML" "<table"
# 花費 = 一行按月總和 + 服務 tag 橫排下一列(不再逐項顯示金額)
assert_not_contains "html: no per-service amount on card" "$HTML" "cost-amt"
# 同幣別相加:good-proj 只有 OpenAI NT$150(Supabase free 不計) → NT$150/月
assert_contains "html: cost total sums same currency" "$HTML" '<div class="cost-sum">NT$150/月</div>'
# 服務 tag 橫排,按用量保留警示色,free 沉底
assert_contains "html: cost tags row present" "$HTML" '<div class="cost-tags"><span class="paid paid-usage">OpenAI API</span><span class="paid paid-free">Supabase</span></div>'
# 不同幣別分列 + range 取中點(US$2-3 → 2.5)
assert_contains "html: mixed currency kept separate" "$HTML" 'NT$100 + US$2.5/月'
# ? 項誠實標未估,不謊報 0(cost-proj 的 Unknown 按用量無月額)
assert_contains "html: unestimable flagged not zeroed" "$HTML" '<span class="cost-warn">+1未估</span>'
# 年費且附月額等值 → 用月額(longtext NT$260/年（≈NT$22/月）→ NT$22)
assert_contains "html: yearly uses monthly equiv" "$HTML" '<div class="cost-sum">NT$22/月</div>'
# 全 free-tier → 免費
assert_contains "html: all free shows 免費" "$HTML" '<div class="cost-sum">免費</div>'
# range 中點 ≥10 保留小數(codex P2:int(round(10.5))=10 銀行家捨入會低估)
assert_contains "html: fractional midpoint above ten kept" "$HTML" '<div class="cost-sum">US$10.5/月</div>'
# HTML 轉義:xss-proj 的 <script> 不得原樣注入
assert_not_contains "html: user script not raw" "$HTML" "<script>alert(1)"
assert_contains "html: user script escaped" "$HTML" "&lt;script&gt;alert(1)"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
