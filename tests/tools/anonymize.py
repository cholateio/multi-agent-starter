#!/usr/bin/env python3
"""One-off anonymizer: replace private project names with aliases.

Reads a privacy.local.toml-format file (default: $KIT_ALIASES, else
$KIT_CONFIG_HOME/privacy.local.toml) and, for every [[literal]] with tier
"public-only" and an alias (key `alias`, or `alias=<x>` inside `note`), replaces
the value with the alias: case-insensitive, whole-word (a name is delimited by
anything other than [A-Za-z0-9_-]). This script holds no names; the table is
local-only. --check reports hits without writing (exit 1 when any).
Output never prints the matched names, only counts and alias targets.
"""
import argparse
import os
import re
import sys
import tomllib
from pathlib import Path


def load_table(path):
    with open(path, "rb") as f:
        d = tomllib.load(f)
    pairs = []
    for b in d.get("literal", []):
        if b.get("tier") != "public-only":
            continue
        alias = b.get("alias") or (re.search(r"alias=([A-Za-z0-9_-]+)", b.get("note", "")) or [None, ""])[1]
        v = b.get("value", "")
        if alias and len(v) >= 4:
            pairs.append((v, alias))
    pairs.sort(key=lambda p: -len(p[0]))  # longest first: a name before its own prefix
    return pairs


def compile_rules(pairs):
    # a trailing '-' in the value (prefix literal such as "foo-") matches as a prefix
    rules = []
    for v, a in pairs:
        tail = "" if v.endswith("-") else r"(?![A-Za-z0-9_-])"
        rules.append((re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(v) + tail, re.I), a))
    return rules


def process(text, rules):
    n = 0
    for rx, a in rules:
        text, k = rx.subn(a, text)
        n += k
    return text, n


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--check", action="store_true", help="report only, do not write")
    ap.add_argument("--table", default=os.environ.get("KIT_ALIASES") or
                    os.path.join(os.environ.get("KIT_CONFIG_HOME", os.path.expanduser("~/.config/kit")),
                                 "privacy.local.toml"))
    a = ap.parse_args(argv)
    rules = compile_rules(load_table(a.table))
    total = 0
    for f in a.files:
        p = Path(f)
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        new, n = process(text, rules)
        if n:
            total += n
            print(f"{f}: {n}")
            if not a.check:
                p.write_text(new, encoding="utf-8")
    print(f"total: {total}")
    return 1 if (a.check and total) else 0


if __name__ == "__main__":
    sys.exit(main())
