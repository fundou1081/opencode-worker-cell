#!/bin/bash
# End-to-end test of the opencode-worker cell with the REAL OpenCode CLI.
#
# Lifecycle under test (matches the designed cell behaviour):
#   1. dsh creates a supervisor + workers, sets the supervisor.
#   2. dsh starts a budgeted chat for a worker and sends a turn.
#   3. The worker works, then follows its AGENTS.md brief: it closes the chat
#      (chat close --defer) and reports to the supervisor (room dm --kind report).
#   4. The supervisor broadcasts and DMs; the next turn of that worker injects
#      the unread coordination into the prompt.
#   5. Continuing the same session uses a new approved chat with --session.
#   6. The supervisor drives a worker itself (chat send from inside its turn).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-quota.sh"
T=${T:-${TMPDIR:-/tmp}/opencode-worker-e2e-real}
S=${OW_MANAGER:-$HERE/../scripts/opencode-worker}
R="$T/root"
export OPENCODE_BIN=${OPENCODE_BIN:-$(command -v opencode)}
MODEL=${MODEL:-opencode/deepseek-v4.1-flash-free}

pass=0

if [ "${OW_SKIP_PROBE:-0}" != "1" ] && ! MODEL="$MODEL" T="$T/probe" "$HERE/probe-model.sh" >/dev/null 2>&1; then
  echo "SKIPPED: model $MODEL is unavailable (quota exhausted or provider down)"
  echo "Re-run later, or pick another model: MODEL=minimax-cn-coding-plan/MiniMax-M3.1-Flash $0"
  exit 77
fi
fail=0
check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
  fi
}
jqp() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "ERR"; }
start_chat() { "$S" --root "$R" chat start --worker "$1" --approved-by user --max-turns "$2" | sed -n 's/^chat: //p' | head -1; }

rm -rf "$T"; mkdir -p "$R" "$T/src"
cd "$T/src" && git init -q && printf '# demo\n' > README.md && git add -A \
  && git -c user.email=a@b -c user.name=t commit -qm init

echo "== setup =="
"$S" --root "$R" new lead --source "$T/src" --mode copy --role supervisor --task "coordinate the release" --model "$MODEL" --quiet
"$S" --root "$R" new w1 --source "$T/src" --mode copy --role worker --task "produce the artifact" --model "$MODEL" --quiet
"$S" --root "$R" new w2 --source "$T/src" --mode copy --role worker --task "produce the delegated artifact" --model "$MODEL" --quiet
"$S" --root "$R" room set --supervisor lead >/dev/null
"$S" --root "$R" semaphore set --max-concurrent 3 >/dev/null
check "setup supervisor" "supervisor" "$("$S" --root "$R" status lead --json | jqp "d['role']")"
check "setup worker linked" "lead" "$("$S" --root "$R" status w1 --json | jqp "d['supervisor']")"

echo "== real worker turn 1: task, self-close, report =="
CHAT1=$(start_chat w1 4)
"$S" --root "$R" chat send --chat "$CHAT1" --expect "hello from w1" --expect-within 300 --timeout 300 \
  --prompt "Objective: create a file named artifact.txt in the current workspace whose only line is: hello from w1
Verification: run 'cat artifact.txt' and include the output.
Report back: the file path and the cat output." > "$T/turn1.out" 2>&1
check "turn1 exit" "0" "$?"
check "turn1 artifact created" "yes" "$([ -f "$R/w1/workspace/artifact.txt" ] && echo yes || echo no)"
check "turn1 artifact content" "hello from w1" "$(cat "$R/w1/workspace/artifact.txt" 2>/dev/null | head -1)"
check "turn1 reported" "yes" "$(grep -q 'hello from w1' "$T/turn1.out" && echo yes || echo no)"
check "turn1 chat closed by worker" "closed" "$("$S" --root "$R" chat status --chat "$CHAT1" --json | jqp "d['status']")"
check "turn1 report logged" "yes" "$("$S" --root "$R" room log --kind report --json | jqp "'yes' if any(m.get('from')=='w1' for m in d) else 'no'")"
check "turn1 report in supervisor inbox" "yes" "$(DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" room inbox --json | jqp "'yes' if any(m.get('from')=='w1' for m in d['messages']) else 'no'")"
SES=$("$S" --root "$R" chat status --chat "$CHAT1" --json | jqp "d['session_id']")

echo "== coordination (broadcast + dm) =="
COORD_BEFORE=$("$S" --root "$R" room status --json | jqp "d['room']['coordination_sent']")
DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" room broadcast --kind note --text "standup note" >/dev/null
DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" room dm --to w1 --kind task --text "second instruction" >/dev/null
COORD_AFTER=$("$S" --root "$R" room status --json | jqp "d['room']['coordination_sent']")
check "coordination cost 3 (broadcast to 2 + dm)" "3" "$((COORD_AFTER - COORD_BEFORE))"
check "w1 inbox has 2 unread" "2" "$(DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room inbox --json | jqp "d['unread']")"

echo "== real worker turn 2 (new chat, same session): inbox injection =="
CHAT2=$(start_chat w1 2)
"$S" --root "$R" chat send --chat "$CHAT2" --expect "second instruction" --expect-within 300 --timeout 300 \
  --prompt "Objective: write the chatroom inbox block you were given into a file named inbox.txt in the current workspace.
Verification: run 'cat inbox.txt' and include the output.
Report back: the cat output." > "$T/turn2.out" 2>&1
check "turn2 exit" "0" "$?"
check "turn2 inbox injected" "2" "$("$S" --root "$R" chat status --chat "$CHAT2" --json | jqp "d['turns'][0].get('inbox_count',0)")"
check "turn2 inbox file has dm" "yes" "$(grep -q 'second instruction' "$R/w1/workspace/inbox.txt" 2>/dev/null && echo yes || echo no)"
check "turn2 inbox file has broadcast" "yes" "$(grep -q 'standup note' "$R/w1/workspace/inbox.txt" 2>/dev/null && echo yes || echo no)"
check "inbox drained" "0" "$(DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room inbox --json | jqp "d['unread']")"

echo "== session continuation with a real turn =="
CHAT3=$("$S" --root "$R" chat start --worker w1 --approved-by user --max-turns 2 --session "$SES" | sed -n 's/^chat: //p' | head -1)
"$S" --root "$R" chat send --chat "$CHAT3" --expect "artifact.txt" --expect-within 300 --timeout 300 \
  --prompt "Which file did you create in the earlier task in this session? Answer with only the file name." > "$T/turn3.out" 2>&1
check "turn3 exit" "0" "$?"
check "turn3 session reused" "$SES" "$("$S" --root "$R" chat status --chat "$CHAT3" --json | jqp "d['session_id']")"
check "turn3 remembered context" "yes" "$(grep -q 'artifact.txt' "$T/turn3.out" && echo yes || echo no)"

echo "== real supervisor delegates to a worker =="
CHAT_W2=$(start_chat w2 3)
CHAT_SUP=$(start_chat lead 3)
"$S" --root "$R" chat send --chat "$CHAT_SUP" --expect "delegated" --expect-within 900 --timeout 900 \
  --prompt "You are the base station for this worker cell. Drive worker w2 by sending exactly one turn to its chat.
Use the manager CLI, for example:
  \"\$DSH_OPENCODE_WORKER_CLI\" chat send --chat \"$CHAT_W2\" --expect delegated --expect-within 300 --prompt 'Create a file named delegated.txt in the current workspace whose only line is: delegated, then run cat delegated.txt and report it.'
Then reply with the worker's answer." > "$T/turn4.out" 2>&1
check "supervisor delegation exit" "0" "$?"
check "delegated file created" "yes" "$([ -f "$R/w2/workspace/delegated.txt" ] && echo yes || echo no)"
check "delegated file content" "delegated" "$(cat "$R/w2/workspace/delegated.txt" 2>/dev/null | head -1)"
check "worker chat consumed a turn" "1" "$("$S" --root "$R" chat status --chat "$CHAT_W2" --json | jqp "d['turns_used']")"

echo "== accounting, alerts and monitor =="
USED=$("$S" --root "$R" room status --json | jqp "d['room']['messages_used']")
"$S" --root "$R" room set --max-messages $((USED+1)) >/dev/null
check "messages_low alert" "messages_low" "$("$S" --root "$R" room alerts --json | jqp "[a['code'] for a in d['alerts'] if a['code']=='messages_low'][0]")"
"$S" --root "$R" room set --max-messages 500 >/dev/null
check "message log rows" "yes" "$("$S" --root "$R" room log --json | jqp "'yes' if len(d)>0 else 'no'")"
check "monitor page" "yes" "$(python3 - "$R" <<'PY'
import json, sys, urllib.request
info = json.load(open(sys.argv[1] + "/.chatroom/server.json"))
with urllib.request.urlopen(f"http://{info['host']}:{info['port']}/?token=" + info["token"], timeout=10) as resp:
    html = resp.read().decode()
print("yes" if 'id="alerts"' in html else "no")
PY
)"

"$S" --root "$R" server stop --force >/dev/null 2>&1

# A provider-side quota refusal is not a product failure.
if [ "$fail" -ne 0 ] && quota_failure_detected "$T"; then
  printf '\nSKIPPED: the model provider refused the run (quota or rate limit)\n'
  exit 77
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
