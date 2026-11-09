#!/bin/bash
# Run the deterministic regression suite (no model cost) and, if a model is
# available, the real-model suite. A model that is unavailable is reported as
# SKIPPED, not as a failure.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODEL=${MODEL:-opencode/deepseek-v4.1-flash-free}
total_fail=0
total_skip=0
run() {
  local label=$1; shift
  local rc=0
  printf '\n######## %s ########\n' "$label"
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '>>>> %s: PASS\n' "$label"
  elif [ "$rc" -eq 77 ]; then
    printf '>>>> %s: SKIPPED (model unavailable)\n' "$label"
    total_skip=$((total_skip+1))
  else
    printf '>>>> %s: FAIL\n' "$label"
    total_fail=$((total_fail+1))
  fi
}
run "deterministic: chatroom cell" "$HERE/e2e-full.sh"
run "real model: chatroom cell" env MODEL="$MODEL" "$HERE/e2e-real.sh"
printf '\n=========================================\n'
if [ "$total_fail" -eq 0 ] && [ "$total_skip" -eq 0 ]; then
  printf 'ALL SUITES PASSED\n'
elif [ "$total_fail" -eq 0 ]; then
  printf 'ALL SUITES PASSED (%d SKIPPED: model unavailable)\n' "$total_skip"
else
  printf '%d SUITE(S) FAILED, %d SKIPPED\n' "$total_fail" "$total_skip"
fi
exit "$total_fail"
