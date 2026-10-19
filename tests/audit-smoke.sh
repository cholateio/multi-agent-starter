#!/usr/bin/env bash
# tests/audit-smoke.sh - `kit audit` end to end on a generated fixture fleet with
# recorded gh api fixtures (fake owner acme). Isolated HOME / config / data dirs.
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s (%s)\n' "$1" "$2"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3]"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected [$3]"; else pass "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FIX="$KIT_ROOT/tests/fixtures/audit/gh"
UID_FAKE="11111111-2222-3333-4444-555555555555"
mkdir -p "$W/home" "$W/cfg" "$W/fleet" "$W/fakebin"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' > "$W/gitconfig"
printf '#!/bin/sh\necho "gh: not logged in" >&2\nexit 1\n' > "$W/fakebin/gh"; chmod +x "$W/fakebin/gh"
export HOME="$W/home" KIT_CONFIG_HOME="$W/cfg" KIT_DATA_HOME="$W/data" KIT_CACHE_HOME="$W/cache" \
       GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1 KIT_NO_OPEN=1
write_cfg() { printf 'kit_root = "%s"\ngithub_owner = "acme"\n[audit]\nroot = "%s"\nexclude = [%s]\n' "$KIT_ROOT" "$W/fleet" "${1:-}" > "$W/cfg/config.toml"; }
write_cfg
printf 'usernames = ["testuser"]\nemails = []\n[[literal]]\nname = "t-uid"\nvalue = "%s"\ntier = "always"\n' "$UID_FAKE" > "$W/cfg/privacy.local.toml"
chmod 600 "$W/cfg/privacy.local.toml"
mk() {  # mk <name> then files via heredoc-less helpers
  R="$W/fleet/$1"; mkdir -p "$R"; git -C "$R" init -q -b main; git -C "$R" remote add origin "git@github.com:acme/$1.git"
}
commit() { git -C "$R" add -A; git -C "$R" commit -qm fixture; }
# proj-a: everything wrong
mk proj-a
mkdir -p "$R/.claude" "$R/src" "$R/.github/workflows"
echo x > "$R/.claude/x"; printf '# proj-a — my private tool\n\n這是私人 repo。\n' > "$R/README.md"
echo "see /home/testuser/x" > "$R/notes.txt"; : > "$R/LICENSE"; echo node_modules/ > "$R/.gitignore"
printf "const OWNER = '%s';\n" "$UID_FAKE" > "$R/src/a.js"
printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n' > "$R/.github/workflows/w.yml"
commit
# proj-b: clean kit v5 repo
mk proj-b
mkdir -p "$R/.github/workflows"
cp "$KIT_ROOT/plugin/templates/gitignore" "$R/.gitignore"
printf '# proj-b\n\nA small tool.\n\n## Install\n\nRun it.\n\n## License\n\nMIT\n' > "$R/README.md"
printf 'MIT License\n\nCopyright (c) 2026 Test\n' > "$R/LICENSE"
(cd "$KIT_ROOT" && python3 -c "from cli.kittoml import render_kit_toml as r; print(r('public','MIT','en',[]), end='')") > "$R/kit.toml"
printf 'on: push\npermissions:\n  contents: read\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v4.1.0\n' > "$R/.github/workflows/w.yml"
commit

ka() { python3 "$KIT_ROOT/bin/kit" audit "$@" 2>&1; }

OUT="$(ka --offline "$FIX" --json "$W/a.json" --html "$W/a.html")"; CODE=$?
eq "a1: HIGH findings → exit 2" "$CODE" "2"
has "a1: table header" "$OUT" "repo"
has "a1: table lists proj-a" "$OUT" "proj-a"
has "a1: table lists remote-only proj-remote" "$OUT" "proj-remote"
lacks "a1: archived repo skipped" "$OUT" "proj-old"
has "a1: json has A4" "$(cat "$W/a.json")" '"check": "A4"'
has "a1: json has A15" "$(cat "$W/a.json")" '"check": "A15"'
has "a1: json has GitHub A9" "$(cat "$W/a.json")" '"check": "A9"'
has "a1: json has kit version" "$(cat "$W/a.json")" '"kit": "5.'
has "a1: html has data-check A4" "$(cat "$W/a.html")" 'data-check="A4"'
lacks "a1: literal value never in json" "$(cat "$W/a.json")" "$UID_FAKE"
lacks "a1: literal value never in html" "$(cat "$W/a.html")" "$UID_FAKE"
lacks "a1: literal value never on stdout" "$OUT" "$UID_FAKE"
lacks "a1: html loads nothing external" "$(cat "$W/a.html")" "src=\"http"
eq "a1: proj-b row has no findings" "$(printf '%s\n' "$OUT" | grep -E '^proj-b ' | grep -c ' ok ')" "1"

OUT="$(ka --offline "$FIX" --baseline "$W/a.json")"; CODE=$?
eq "a2: baseline rerun exit 0" "$CODE" "0"
has "a2: 0 new findings" "$OUT" "0 new findings"

echo "fresh" > "$W/fleet/proj-b/.env"; git -C "$W/fleet/proj-b" add -f .env; git -C "$W/fleet/proj-b" commit -qm env
OUT="$(ka --offline "$FIX" --baseline "$W/a.json")"; CODE=$?
eq "a3: new HIGH vs baseline → exit 2" "$CODE" "2"
has "a3: 1 new finding" "$OUT" "1 new finding"
git -C "$W/fleet/proj-b" rm -q --cached .env; rm "$W/fleet/proj-b/.env"; git -C "$W/fleet/proj-b" commit -qm unenv

OUT="$(ka --offline "$FIX" proj-b)"; CODE=$?
eq "a4: clean repo alone → exit 0" "$CODE" "0"

write_cfg '"proj-*"'
OUT="$(ka --offline "$FIX")"; CODE=$?
lacks "a5: exclude glob drops proj-a" "$OUT" "proj-a"
lacks "a5: exclude glob drops remote-only proj-remote" "$OUT" "proj-remote"
write_cfg

OUT="$(ka --offline "$FIX" --verbose proj-a)"
has "a6: verbose lists finding path:line" "$OUT" "src/a.js:1"
has "a6: verbose shows redacted literal name" "$OUT" "<t-uid>"
has "a6: verbose shows a fix line" "$OUT" "fix:"

# gh unavailable (fake gh fails) → GitHub checks UNKNOWN, exit code unaffected
OUT="$(PATH="$W/fakebin:$PATH" ka proj-b)"; CODE=$?
eq "a7: gh unavailable, clean repo → exit 0" "$CODE" "0"
has "a7: reports UNKNOWN checks" "$OUT" "UNKNOWN"

# default html path + exit 1 on a broken config
OUT="$(ka --offline "$FIX" proj-b --html)"
[ -f "$W/data/audit.html" ] && pass "a8: default html under KIT_DATA_HOME" || fail "a8: default html under KIT_DATA_HOME" "missing"
echo 'broken = [' > "$W/cfg/config.toml"
OUT="$(ka --offline "$FIX")"; CODE=$?
eq "a9: malformed config → exit 1" "$CODE" "1"

# a10 (final review C2): literal values in PATHS are redacted; invalid privacy still redacts + shows the gap
write_cfg
printf 'usernames = ["testuser"]\nemails = []\n[[literal]]\nname = "t-uid"\nvalue = "%s"\ntier = "always"\n[[literal]]\nname = "secret-proj"\nvalue = "zebracorn"\ntier = "always"\n' "$UID_FAKE" > "$W/cfg/privacy.local.toml"
R="$W/fleet/proj-a"; mkdir -p "$R/docs/plans"; echo "launch" > "$R/docs/plans/zebracorn-launch.md"; echo "/home/zebracorn/x" > "$R/p.txt"; commit
OUT="$(ka --offline "$FIX" -v --json "$W/z.json" --html "$W/z.html" proj-a)"
lacks "a10: literal not in verbose paths" "$OUT" "zebracorn"
lacks "a10: literal not in json paths" "$(cat "$W/z.json")" "zebracorn"
lacks "a10: literal not in html" "$(cat "$W/z.html")" "zebracorn"
printf '[[literal]]\nname = "bad-one"\nvalue = "abc"\ntier = "always"\n' >> "$W/cfg/privacy.local.toml"
OUT="$(ka --offline "$FIX" -v --json "$W/z2.json" proj-a)"
lacks "a10: invalid privacy still redacts" "$OUT" "zebracorn"
lacks "a10: invalid privacy still redacts json" "$(cat "$W/z2.json")" "zebracorn"
has "a10: invalid privacy → visible UNKNOWN A2" "$(python3 -c "import json;print([f['severity'] for f in json.load(open('$W/z2.json'))['findings'] if f['check']=='A2' and 'privacy' in f['snippet']])")" "UNKNOWN"
lacks "a10: literal not in invalid-privacy json either" "$(cat "$W/z2.json")" "$UID_FAKE"
chmod 600 "$W/cfg/privacy.local.toml"

echo
echo "passed $PASS_COUNT, failed $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
