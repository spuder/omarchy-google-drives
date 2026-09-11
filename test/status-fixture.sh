#!/usr/bin/env bash
# Smoke test: googledrive-status --demo must always print valid JSON shaped
# the way Model.js's parseAccounts() expects, with no real rclone/account
# config required. Exits non-zero on the first failure.
set -uo pipefail

STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/googledrive-status"
fails=0

check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

echo "1. --demo prints valid JSON"
out="$(python3 "$STATUS" --demo)"
echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
check "valid JSON" "0" "$?"

echo "2. demo payload has the expected shape"
check "ok is true" "True" "$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
check "rcloneInstalled is true" "True" "$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rcloneInstalled"])')"
check "two demo accounts" "2" "$(echo "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["accounts"]))')"
check "first account id" "personal" "$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["accounts"][0]["id"])')"

echo "3. without --demo and without config, it still returns valid JSON"
empty_home="$(mktemp -d)"
trap 'rm -rf "$empty_home"' EXIT
out2="$(HOME="$empty_home" python3 "$STATUS")"
echo "$out2" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
check "valid JSON with no config" "0" "$?"
check "empty accounts with no config" "0" "$(echo "$out2" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["accounts"]))')"

if (( fails > 0 )); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
