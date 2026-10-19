#!/usr/bin/env bash
# tests/run-all.sh - run every tests/*.sh (except itself) plus python unit tests.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
self="$(basename "${BASH_SOURCE[0]}")"
failed=()
for t in tests/*.sh; do
  [ "$(basename "$t")" = "$self" ] && continue
  echo "=== $t"
  bash "$t" || failed+=("$(basename "$t")")
done
if [ -d tests/unit ]; then
  echo "=== tests/unit"
  python3 -m unittest discover -s tests/unit -q || failed+=("unit")
fi
if [ "${#failed[@]}" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILED: ${failed[*]}"; exit 1; fi
