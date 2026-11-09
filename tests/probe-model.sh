#!/bin/bash
# Probe whether a model can be used right now.
#
# exit 0   the model answered -> it can be used
# exit 77  the model is unavailable (free quota exhausted, rate limit, auth
#          error, provider outage) -> callers should skip, not fail
#
# A quota problem is a property of the account, not of the worker tooling, so
# the regression suites must not report it as a product failure.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MODEL=${MODEL:-opencode/deepseek-v4.1-flash-free}
BIN=${OPENCODE_BIN:-opencode}
T=${T:-${TMPDIR:-/tmp}/opencode-worker-model-probe}

rm -rf "$T"
mkdir -p "$T"
OUT="$T/probe.json"
ERR="$T/probe.err"

"$BIN" run --standalone --format json --auto --model "$MODEL" -- \
  "Reply with exactly: PROBE_OK" >"$OUT" 2>"$ERR"
RC=$?

if grep -qiE "free-limit|free usage limit|rate.limit|quota|usage limit|Token Plan|用量上限|429" "$OUT" "$ERR"; then
  echo "model $MODEL is not usable right now (quota or rate limit)"
  exit 77
fi

if [ "$RC" -ne 0 ]; then
  echo "model $MODEL probe failed (exit $RC)"
  tail -n 3 "$ERR" 2>/dev/null
  exit 77
fi

if ! grep -q "PROBE_OK" "$OUT"; then
  echo "model $MODEL probe produced no answer"
  exit 77
fi

echo "model $MODEL is available"
exit 0
