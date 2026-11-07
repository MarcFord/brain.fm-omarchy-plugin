#!/usr/bin/env bash
# Proves dist/ci-assert.sh actually fails when it should.
#
# Every helper is run twice: once on input it must accept, once on input it must
# reject. A helper that passes both is broken, and this script says so. The
# `! grep -q` bug this guards against was invisible precisely because nobody
# ever watched the assertion go red.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf 'present\n' > "$TMP/haystack"

errors=0
note_bad() { printf 'BROKEN HELPER: %s\n' "$*" >&2; errors=$((errors + 1)); }

# Run one helper invocation in a subshell with a fresh counter and report
# whether it registered a failure. Sourcing per-case keeps ASSERT_FAILURES from
# leaking between cases.
helper_failed() {
  local output
  output=$(
    # shellcheck source=ci-assert.sh
    source "$HERE/ci-assert.sh"
    "$@" >/dev/null 2>&1
    printf '%s' "$ASSERT_FAILURES"
  )
  [[ $output != 0 ]]
}

expect_green() {
  local label=$1; shift
  if helper_failed "$@"; then
    note_bad "$label -- helper rejected input it should accept"
  else
    printf 'ok: %s accepts good input\n' "$label"
  fi
}

expect_red() {
  local label=$1; shift
  if helper_failed "$@"; then
    printf 'ok: %s rejects bad input\n' "$label"
  else
    note_bad "$label -- helper ACCEPTED input it should reject"
  fi
}

expect_green "assert_file_exists"   assert_file_exists "$TMP/haystack" "d"
expect_red   "assert_file_exists"   assert_file_exists "$TMP/absent"   "d"

expect_green "assert_contains"      assert_contains "$TMP/haystack" "present" "d"
expect_red   "assert_contains"      assert_contains "$TMP/haystack" "absent"  "d"
expect_red   "assert_contains"      assert_contains "$TMP/absent"   "present" "d"

expect_green "assert_not_contains"  assert_not_contains "$TMP/haystack" "absent"  "d"
expect_red   "assert_not_contains"  assert_not_contains "$TMP/haystack" "present" "d"

expect_green "assert_cmd_succeeds"  assert_cmd_succeeds "d" -- true
expect_red   "assert_cmd_succeeds"  assert_cmd_succeeds "d" -- false

expect_green "assert_cmd_fails"     assert_cmd_fails "d" -- false
expect_red   "assert_cmd_fails"     assert_cmd_fails "d" -- true

if (( errors > 0 )); then
  printf '\n%d helper(s) do not behave as documented\n' "$errors" >&2
  exit 1
fi
printf '\nassertion helpers verified in both directions\n'
