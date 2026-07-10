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
status_note = "單影片可用"
updated = 2020-01-01

[commands]
summary = "uv run good-proj <url>"

[[paid]]
service = "OpenAI API"
billing = "按用量"
monthly_est = "~$3"
cancel = "拿掉 .env 的 key"

[[paid]]
service = "Supabase"
billing = "free-tier"
monthly_est = "$0"
EOF

printf 'name = "broken\n' > "$ROOT/broken-proj/PROJECT.toml"

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
assert_not_contains "list: hidden dir excluded" "$OUT" ".hidden"

# --- stale 偵測: good-proj 給一個今天的 commit,updated=2020 → ⚠ ---
GIT_ID="$WORK/gitcfg"
printf '[user]\n\tname = T\n\temail = t@t.test\n' > "$GIT_ID"
gitq() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_ID" git -C "$ROOT/good-proj" "$@" >/dev/null 2>&1; }
rmdir "$ROOT/good-proj/.git" 2>/dev/null || true
if gitq init -q -b main && gitq add -A && gitq commit -q -m x; then
  run
  assert_contains "list: stale manifest marked" "$OUT" "⚠"
else
  fail "list: stale manifest marked" "git fixture setup failed"
fi

# --- proj <name> ---
run good-proj
assert_eq "detail: exit 0" "$CODE" "0"
assert_contains "detail: command copyable verbatim" "$OUT" "uv run good-proj <url>"
assert_contains "detail: cancel instruction shown" "$OUT" "拿掉 .env 的 key"

run no-such-proj
assert_eq "detail: unknown project exits 1" "$CODE" "1"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
