#!/bin/bash
# Shared helper for the real-model suites.
#
# A provider-side quota or rate-limit refusal is a property of the account,
# not of the worker tooling. When that happens the suites must report
# SKIPPED (exit 77) instead of FAIL.
#
# The markers below only match *provider* refusals. The chat turn budget
# ("chat quota exhausted (1/2)") is a normal, expected message and is
# deliberately not part of the pattern.

QUOTA_PATTERN='free-limit|free usage limit|insufficient_quota|quota exceeded|rate.limit|token plan|用量上限|provider\.free'

# quota_failure_detected <path> [...]
# exit 0 when one of the paths contains a provider quota/rate-limit refusal.
quota_failure_detected() {
  local found=1
  local path
  for path in "$@"; do
    [ -e "$path" ] || continue
    if find "$path" -type f -not -path '*/.git/*' -not -path '*/probe/*' -size -4M -print0 2>/dev/null \
      | xargs -0 grep -qiE "$QUOTA_PATTERN" /dev/null 2>/dev/null; then
      found=0
      break
    fi
  done
  return "$found"
}
