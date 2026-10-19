#!/usr/bin/env bash
# plugin/guard/lib-privacy.sh — the guard's privacy rule engine (design §7.2, R3–R7).
# Sourced by pre-commit.sh / pre-push.sh (and tests). bash + awk + grep only (D15).
# Independent of plugin/hooks/lib.sh on purpose: the guard runs for every repo
# on the machine, from a different entry point (the global git-hooks shim).
#
#   privacy_load_local <path>          privacy.local.toml → PRIV_USERS PRIV_EMAILS
#                                      PRIV_LIT_NAME[i] PRIV_LIT_VALUE[i] PRIV_LIT_TIER[i]
#                                      (missing / unreadable → return 1, arrays empty)
#   privacy_scan_stream <mode> <visibility> <allow_literals_csv> <allow_paths_csv>
#       stdin: one line per ADDED line: path<TAB>lineno<TAB>tag<TAB>content
#       stdout: BLOCK|WARN<TAB><rule> <tag><TAB><path>:<lineno>[ @tag]<TAB><why>
#       return 0 = no block, 1 = at least one BLOCK
#   privacy_scan_file <mode> <visibility> <allow_literals_csv> <display_path> [allow_paths_csv]
#       stdin: a file's content → same output (wraps privacy_scan_stream)
#   privacy_kit_toml_visibility|allow_literals|allow_paths <root>   ($root/kit.toml)
#   privacy_kt_visibility / privacy_kt_privacy_array <key>          (kit.toml text on stdin)
#
# Contract: literals match as FIXED strings, case-insensitively, and only when
# >= 4 characters; output never carries a matched value (literals are named
# <name>, user names are <user>); a line containing `kit-privacy: allow` is
# skipped; allow_paths globs (bash [[ == ]], `*` crosses `/`) skip R3–R7.
# kit.toml [privacy] allow_literals exempts a literal by NAME only — a value
# written there is not a name and exempts nothing (design 修訂 #2). Emails
# from privacy.local.toml are always-tier literals named `email`, exactly as
# kit audit A2/A3 treats them.

PRIV_MIN_LEN=4
_PRIV_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- local literals
_priv_awk_strings='
function strings(s,   out, i, c, q, buf, n) {   # every quoted string on the line → SEP-joined
    out = ""; q = ""; buf = ""; n = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "") {
            if (c == "#") break
            if (c == "\"" || c == "\047") { q = c; buf = "" }
            continue
        }
        if (q == "\"" && c == "\\") {
            i++; c = substr(s, i, 1)
            if (c == "t") c = "\t"; else if (c == "n") c = " "
            buf = buf c; continue
        }
        if (c == q) { out = out (n++ ? SEP : "") buf; q = ""; continue }
        buf = buf c
    }
    return out
}'

privacy_load_local() {
    PRIV_USERS=(); PRIV_EMAILS=(); PRIV_LIT_NAME=(); PRIV_LIT_VALUE=(); PRIV_LIT_TIER=()
    [[ -f "$1" && -r "$1" ]] || return 1
    local kind a b c
    while IFS=$'\x1f' read -r kind a b c; do
        case "$kind" in
            U) [[ -n "$a" ]] && PRIV_USERS+=("$a") ;;
            E) [[ ${#a} -ge $PRIV_MIN_LEN ]] && PRIV_EMAILS+=("$a") ;;
            L) PRIV_LIT_NAME+=("$a"); PRIV_LIT_VALUE+=("$b"); PRIV_LIT_TIER+=("$c") ;;
        esac
    done < <(awk -v SEP=$'\x1e' -v MIN="$PRIV_MIN_LEN" "$_priv_awk_strings"'
        function flush() {
            if (inlit && val != "" && length(val) >= MIN) {
                if (tier != "public-only") tier = "always"
                if (name == "") name = "literal-" nlit      # nameless: still enforced (fail-closed)
                printf "L\037%s\037%s\037%s\n", name, val, tier
            }
            inlit = 0; name = ""; val = ""; tier = ""
        }
        { line = $0; sub(/^[ \t]+/, "", line) }
        line ~ /^\[\[literal\]\]/ { flush(); inlit = 1; nlit++; next }
        line ~ /^\[/              { flush(); next }
        match(line, /^[A-Za-z_]+[ \t]*=/) {
            key = substr(line, 1, RLENGTH - 1); sub(/[ \t]+$/, "", key)
            rest = substr(line, RLENGTH + 1)
            v = strings(rest)
            if (!inlit && (key == "usernames" || key == "emails")) {
                n = split(v, arr, SEP)
                for (i = 1; i <= n; i++) if (arr[i] != "") printf "%s\037%s\n", (key == "usernames" ? "U" : "E"), arr[i]
            } else if (inlit) {
                if (key == "name") name = v; else if (key == "value") val = v; else if (key == "tier") tier = v
            }
        }
        END { flush() }' "$1" 2>/dev/null)
    return 0
}

# ---------------------------------------------------------------- shipped rules
# RULE_* arrays, loaded once per process from privacy-rules.toml
_priv_rules_loaded=0
_priv_load_rules() {
    [[ $_priv_rules_loaded -eq 1 ]] && return 0
    RULE_ID=(); RULE_TAG=(); RULE_PAT=(); RULE_ACT=(); RULE_ICASE=(); RULE_EXCL=(); RULE_EXCEPT=(); RULE_WHY=()
    local f="$_PRIV_GUARD_DIR/privacy-rules.toml" id tag pat act ic ex exc why
    [[ -f "$f" ]] || { echo "KIT GUARD: $f missing — generic privacy rules (R3/R3b/R6/R7) not checked" >&2; _priv_rules_loaded=1; return 0; }
    while IFS=$'\x1f' read -r id tag pat act ic ex exc why; do
        RULE_ID+=("$id"); RULE_TAG+=("$tag"); RULE_PAT+=("$pat"); RULE_ACT+=("$act")
        RULE_ICASE+=("$ic"); RULE_EXCL+=("$ex"); RULE_EXCEPT+=("$exc"); RULE_WHY+=("$why")
    done < <(awk '
        function flush() { if (r["id"] != "" && r["pattern"] != "")
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", r["id"], r["tag"], r["pattern"], r["action"], r["icase"], r["exclude"], r["except"], r["why"]
            split("", r) }
        /^[ \t]*\[\[rule\]\]/ { flush(); next }
        /^[ \t]*[a-z]+[ \t]*=[ \t]*\047/ {
            k = $0; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
            v = $0; sub(/^[^=]*=[ \t]*\047/, "", v); sub(/\047[ \t]*(#.*)?$/, "", v)
            r[k] = v }
        END { flush() }' "$f")
    _priv_rules_loaded=1
}

_priv_users_alt() {  # → (u1|u2) of privacy usernames + OS user, regex-escaped; empty if none
    local -a us=() ; local u seen=" " os
    os="$(id -un 2>/dev/null)"
    for u in "${PRIV_USERS[@]}" "$os"; do
        [[ -z "$u" || "$seen" == *" $u "* ]] && continue
        seen+="$u "
        us+=("$(printf '%s' "$u" | sed 's/[][\.*^$+?(){}|/]/\\&/g')")
    done
    [[ ${#us[@]} -gt 0 ]] || return 0
    local IFS='|'; printf '(%s)' "${us[*]}"
}

_priv_path_allowed() {  # $1 = path, rest = globs
    local p="$1" g; shift
    for g in "$@"; do [[ -n "$g" && "$p" == $g ]] && return 0; done
    return 1
}

# ---------------------------------------------------------------- scanner
privacy_scan_stream() {
    local mode="$1" vis="$2" allow_csv="${3:-}" paths_csv="${4:-}"
    local LC_ALL=C
    local td; td="$(mktemp -d "${TMPDIR:-/tmp}/kit-guard.XXXXXX")" || { echo "KIT GUARD: mktemp failed" >&2; return 1; }
    awk -v M="$td/meta" -v C="$td/content" '{
        p1 = index($0, "\t"); r1 = substr($0, p1 + 1); p2 = index(r1, "\t"); r2 = substr(r1, p2 + 1); p3 = index(r2, "\t")
        if (!p1 || !p2 || !p3) next
        print substr($0, 1, p1 - 1) "\t" substr(r1, 1, p2 - 1) "\t" substr(r2, 1, p3 - 1) > M
        print substr(r2, p3 + 1) > C }'
    [[ -f "$td/content" ]] || { rm -rf "$td"; return 0; }

    local -a allow_names=() allow_paths=()
    IFS=',' read -ra allow_names <<< "$allow_csv"
    IFS=',' read -ra allow_paths <<< "$paths_csv"
    local blocked=0 i n

    # literals: privacy [[literal]] + emails (always, named `email`)
    local -a ln=() lv=() lt=()
    for i in "${!PRIV_LIT_NAME[@]}"; do
        [[ ${#PRIV_LIT_VALUE[$i]} -ge $PRIV_MIN_LEN ]] || continue
        ln+=("${PRIV_LIT_NAME[$i]}"); lv+=("${PRIV_LIT_VALUE[$i]}"); lt+=("${PRIV_LIT_TIER[$i]}")
    done
    for i in "${!PRIV_EMAILS[@]}"; do ln+=("email"); lv+=("${PRIV_EMAILS[$i]}"); lt+=("always"); done
    # allow_literals entries that are not names: warn, exempt nothing, never echo a value
    local a known v
    if [[ ${#ln[@]} -gt 0 ]]; then
        for a in "${allow_names[@]}"; do
            [[ -z "$a" ]] && continue
            known=0; for n in "${ln[@]}"; do [[ "$n" == "$a" ]] && known=1; done
            [[ $known -eq 1 ]] && continue
            local isval=0; for v in "${lv[@]}"; do [[ "${v,,}" == "${a,,}" ]] && isval=1; done
            if [[ $isval -eq 1 ]]; then
                echo "KIT GUARD: kit.toml allow_literals has a literal VALUE, not a name — ignored (list names from privacy.local.toml, never values)" >&2
            else
                echo "KIT GUARD: unknown literal name in kit.toml allow_literals: $a (not in privacy.local.toml — ignored)" >&2
            fi
        done
    fi
    local -a act=() # per literal: active | exempt | off
    : > "$td/pats"
    for i in "${!ln[@]}"; do
        if [[ "${lt[$i]}" == "public-only" && "$vis" == "private" ]]; then act+=("off"); continue; fi
        known=0; for a in "${allow_names[@]}"; do [[ "$a" == "${ln[$i]}" ]] && known=1; done
        [[ $known -eq 1 ]] && act+=("exempt") || act+=("active")
        printf '%s\n' "${lv[$i]}" >> "$td/pats"
    done

    _priv_join() {  # stdin: grep -n hits "N:text" → N US path US lineno US tag US text (US = \x1f)
        awk -v META="$td/meta" 'BEGIN { while ((getline l < META) > 0) m[++k] = l }
            { c = index($0, ":"); n = substr($0, 1, c - 1); x = m[n]; gsub(/\t/, "\037", x)
              print n "\037" x "\037" substr($0, c + 1) }'
    }
    local -A said_allowed=() hitlines=()
    local num path lno tag text low disp
    _priv_emit() {  # $1 action  $2 "Rn tag"  $3 why
        disp="$path:$lno"; [[ -n "$tag" ]] && disp+=" @$tag"
        printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$disp" "$3"
        [[ "$1" == "BLOCK" ]] && blocked=1
    }
    if [[ -s "$td/pats" ]]; then
        grep -n -a -i -F -f "$td/pats" "$td/content" 2>/dev/null | _priv_join > "$td/lhits"
        while IFS=$'\x1f' read -r num path lno tag text; do
            low="${text,,}"
            [[ "$low" == *"kit-privacy: allow"* ]] && continue
            _priv_path_allowed "$path" "${allow_paths[@]}" && continue
            for i in "${!ln[@]}"; do
                [[ "${act[$i]}" == "off" ]] && continue
                [[ "$low" == *"${lv[$i],,}"* ]] || continue
                if [[ "${act[$i]}" == "exempt" ]]; then
                    if [[ -z "${said_allowed[${ln[$i]}]:-}" ]]; then
                        echo "KIT GUARD: literal ${ln[$i]} allowed by kit.toml" >&2
                        said_allowed[${ln[$i]}]=1
                    fi
                elif [[ "${lt[$i]}" == "public-only" ]]; then
                    _priv_emit BLOCK "R5 public-only-literal" "public-only literal <${ln[$i]}> in a repo treated as public (kit.toml visibility=${vis:-unset})"
                else
                    _priv_emit BLOCK "R4 personal-literal" "personal literal <${ln[$i]}>"
                fi
            done
        done < "$td/lhits"
    fi

    # shipped regex rules
    _priv_load_rules
    local users; users="$(_priv_users_alt)"
    local pat flags ex skip last action
    for i in "${!RULE_ID[@]}"; do
        pat="${RULE_PAT[$i]}"
        if [[ "$pat" == *__USER__* ]]; then
            [[ -n "$users" ]] || continue
            pat="${pat//__USER__/$users}"
        fi
        flags="-n -a -E"
        [[ "${RULE_ICASE[$i]}" == "true" ]] && flags+=" -i"
        [[ -n "${RULE_EXCEPT[$i]}" ]] && flags+=" -o"
        action="WARN"; [[ "${RULE_ACT[$i]}" == "block" ]] && action="BLOCK"
        # shellcheck disable=SC2086
        grep $flags -e "$pat" "$td/content" 2>/dev/null | _priv_join > "$td/rhits"
        last=""
        while IFS=$'\x1f' read -r num path lno tag text; do
            [[ "$num" == "$last" ]] && continue
            if [[ -n "${RULE_EXCEPT[$i]}" ]]; then
                low="${text,,}"
                [[ "$low" =~ ${RULE_EXCEPT[$i]} ]] && continue
                text="$(sed -n "${num}p" "$td/content")"   # -o gave the match; need the line
            fi
            [[ "${text,,}" == *"kit-privacy: allow"* ]] && continue
            _priv_path_allowed "$path" "${allow_paths[@]}" && continue
            skip=0
            for ex in ${RULE_EXCL[$i]//,/ }; do [[ -n "${hitlines[$ex:$num]:-}" ]] && skip=1; done
            [[ $skip -eq 1 ]] && continue
            [[ -n "${hitlines[${RULE_ID[$i]}:$num]:-}" ]] && continue   # same id, another pattern
            hitlines[${RULE_ID[$i]}:$num]=1
            last="$num"
            _priv_emit "$action" "${RULE_ID[$i]} ${RULE_TAG[$i]}" "${RULE_WHY[$i]}"
        done < "$td/rhits"
    done
    rm -rf "$td"
    unset -f _priv_join _priv_emit
    [[ $blocked -eq 0 ]]
}

privacy_scan_file() {
    local d="$4"
    awk -v D="$d" '{ print D "\t" NR "\t\t" $0 }' | privacy_scan_stream "$1" "$2" "$3" "${5:-}"
}

# ---------------------------------------------------------------- kit.toml readers
privacy_kt_visibility() {  # stdin: kit.toml text → top-level visibility value (or empty)
    awk '/^[ \t]*\[/ { exit }
         /^[ \t]*visibility[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v)
             if (match(v, /^"[^"]*"/) || match(v, /^\047[^\047]*\047/)) print substr(v, 2, RLENGTH - 2)
             exit }'
}

privacy_kt_privacy_array() {  # $1 = key; stdin: kit.toml text → CSV of [privacy].<key> strings
    awk -v KEY="$1" "$_priv_awk_strings"'
        function bare(s,   i, c, q, o) {   # the line minus quoted strings and comment
            o = ""; q = ""
            for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
                if (q != "") { if (q == "\"" && c == "\\") i++; else if (c == q) q = ""; continue }
                if (c == "#") break
                if (c == "\"" || c == "\047") { q = c; continue }
                o = o c }
            return o }
        BEGIN { SEP = "," }
        { line = $0; sub(/^[ \t]+/, "", line) }
        !inarr && line ~ /^\[/ { intab = (line ~ /^\[privacy\][ \t]*(#.*)?$/); next }
        inarr { v = strings(line); if (v != "") out = out (out != "" ? "," : "") v
                if (index(bare(line), "]")) inarr = 0
                next }
        intab && match(line, "^" KEY "[ \t]*=[ \t]*\\[") {
            rest = substr(line, RLENGTH + 1); out = strings(rest)
            if (!index(bare(rest), "]")) inarr = 1
        }
        END { print out }'
}

privacy_kit_toml_visibility()     { [[ -f "$1/kit.toml" ]] && privacy_kt_visibility < "$1/kit.toml"; return 0; }
privacy_kit_toml_allow_literals() { [[ -f "$1/kit.toml" ]] && privacy_kt_privacy_array allow_literals < "$1/kit.toml"; return 0; }
privacy_kit_toml_allow_paths()    { [[ -f "$1/kit.toml" ]] && privacy_kt_privacy_array allow_paths < "$1/kit.toml"; return 0; }
