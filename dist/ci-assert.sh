#!/usr/bin/env bash
# Assertion helpers for CI checks.
#
# Why these exist rather than inline `[[ ]]` tests:
#
# POSIX exempts a pipeline preceded by `!` from errexit, so the obvious way to
# write a negative assertion --
#
#     set -e
#     ! grep -q "forbidden" file      # passes whether or not it matches
#
# -- silently succeeds no matter what grep found. A check written that way is
# not a check. Every assertion below ends in an explicit `fail` call that runs
# `exit 1` itself, so errexit never has to be trusted to notice.
#
# Each helper is exercised by dist/ci-assert-test.sh, which deliberately feeds
# it a failing case and confirms it goes red. An assertion that has never been
# seen to fail is not evidence.

set -o pipefail

ASSERT_FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
  return 1
}

pass() {
  printf 'ok: %s\n' "$*"
}

# assert_file_exists <path> <description>
assert_file_exists() {
  local path=$1 desc=${2:-"$1 exists"}
  if [[ -f $path ]]; then
    pass "$desc"
  else
    fail "$desc -- no such file: $path"
  fi
}

# assert_contains <file> <fixed-string> <description>
assert_contains() {
  local file=$1 needle=$2 desc=${3:-"$1 contains '$2'"}
  if [[ ! -f $file ]]; then
    fail "$desc -- no such file: $file"
    return 1
  fi
  if grep -qF -- "$needle" "$file"; then
    pass "$desc"
  else
    fail "$desc -- '$needle' not found in $file"
  fi
}

# assert_not_contains <file> <fixed-string> <description>
#
# Written with an if/else on grep's status rather than `! grep -q`, for the
# errexit reason in the header comment.
assert_not_contains() {
  local file=$1 needle=$2 desc=${3:-"$1 does not contain '$2'"}
  if [[ ! -f $file ]]; then
    fail "$desc -- no such file: $file"
    return 1
  fi
  if grep -qF -- "$needle" "$file"; then
    fail "$desc -- '$needle' is present in $file"
  else
    pass "$desc"
  fi
}

# assert_cmd_succeeds <description> -- <command...>
assert_cmd_succeeds() {
  local desc=$1
  shift
  [[ ${1:-} == -- ]] && shift
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if (( rc == 0 )); then
    pass "$desc"
  else
    fail "$desc -- exited $rc: ${out:-(no output)}"
  fi
}

# assert_cmd_fails <description> -- <command...>
#
# For proving a gate actually rejects bad input.
assert_cmd_fails() {
  local desc=$1
  shift
  [[ ${1:-} == -- ]] && shift
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if (( rc == 0 )); then
    fail "$desc -- expected a nonzero exit, got 0: ${out:-(no output)}"
  else
    pass "$desc"
  fi
}

# assert_summary -- call once at the end; exits nonzero if anything failed.
assert_summary() {
  if (( ASSERT_FAILURES > 0 )); then
    printf '\n%d assertion(s) failed\n' "$ASSERT_FAILURES" >&2
    exit 1
  fi
  printf '\nall assertions passed\n'
  exit 0
}
