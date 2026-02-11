#!/usr/bin/env bash
# Tests for scripts/validate.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/validate.sh"
FIXTURES="$(cd "$(dirname "$0")" && pwd)/fixtures"
PASS=0; FAIL=0

assert_exit() {
  local desc="$1" expected="$2" file="$3"
  output=$("$SCRIPT" "$file" 2>&1) || true
  "$SCRIPT" "$file" >/dev/null 2>&1
  actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  ✅ $desc"
    ((PASS++))
  else
    echo "  ❌ $desc (expected exit $expected, got $actual)"
    echo "     output: $output"
    ((FAIL++))
  fi
}

assert_output_contains() {
  local desc="$1" pattern="$2" file="$3"
  output=$("$SCRIPT" "$file" 2>&1) || true
  if echo "$output" | grep -qF "$pattern"; then
    echo "  ✅ $desc"
    ((PASS++))
  else
    echo "  ❌ $desc (pattern '$pattern' not found)"
    echo "     output: $output"
    ((FAIL++))
  fi
}

echo "=== validate.sh tests ==="

echo "-- Valid packets --"
assert_exit "v1.0 valid packet" 0 "$FIXTURES/valid-v1.0.json"
assert_exit "v1.1 valid packet" 0 "$FIXTURES/valid-v1.1.json"

echo "-- Invalid packets --"
assert_exit "missing fields → exit 1" 1 "$FIXTURES/invalid-missing-fields.json"
assert_exit "bad ID format → exit 1" 1 "$FIXTURES/invalid-id-format.json"
assert_exit "no version → exit 1" 1 "$FIXTURES/invalid-no-version.json"
assert_exit "file not found → exit 1" 1 "$FIXTURES/nonexistent.json"

echo "-- Error messages --"
assert_output_contains "reports missing title on epic" "$.epics[0].title" "$FIXTURES/invalid-missing-fields.json"
assert_output_contains "reports missing title on issue" "$.issues[0].title" "$FIXTURES/invalid-missing-fields.json"
assert_output_contains "reports bad epic ID" "Invalid ID format" "$FIXTURES/invalid-id-format.json"
assert_output_contains "reports bad issue ID" "Invalid ID format" "$FIXTURES/invalid-id-format.json"
assert_output_contains "reports missing version" "version" "$FIXTURES/invalid-no-version.json"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
