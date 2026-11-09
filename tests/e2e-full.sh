#!/bin/bash
# Comprehensive regression for opencode-worker (deterministic, fake OpenCode runner).
# Covers roles/AGENTS.md, chat budgets, limits, coordination channels, inbox,
# deferred close, semaphore, alerts, server lifecycle, and HTTP API permissions.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
T=${T:-${TMPDIR:-/tmp}/opencode-worker-e2e-full}
S=${OW_MANAGER:-$HERE/../scripts/opencode-worker}
FAKE=$HERE/fake-opencode
export OPENCODE_BIN=$FAKE
export FAKE_OPENCODE_HOME="$T/fakehome"
R="$T/root"

pass=0
fail=0
check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
  fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }
jqp() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "ERR"; }
start_chat() {  # worker max_turns [priority] -> chat id
  "$S" --root "$R" chat start --worker "$1" --approved-by user --max-turns "$2" ${3:+--priority "$3"} \
    | sed -n 's/^chat: //p' | head -1
}

rm -rf "$T"; mkdir -p "$R" "$T/src"
cd "$T/src" && git init -q && echo "# demo" > README.md && git add -A \
  && git -c user.email=a@b -c user.name=t commit -qm init

echo "== A. roles and AGENTS.md =="
"$S" --root "$R" new lead --source "$T/src" --mode copy --role supervisor --task "coordinate" --quiet
"$S" --root "$R" new w1 --source "$T/src" --mode copy --role worker --task "build" --quiet
"$S" --root "$R" new w2 --source "$T/src" --mode copy --role worker --quiet
check "A1 supervisor role" "supervisor" "$("$S" --root "$R" status lead --json | jqp "d['role']")"
check "A2 worker role" "worker" "$("$S" --root "$R" status w1 --json | jqp "d['role']")"
check "A3 worker linked to supervisor" "lead" "$("$S" --root "$R" status w1 --json | jqp "d['supervisor']")"
check "A4 second supervisor refused" "4" "$(rc "$S" --root "$R" new lead2 --source "$T/src" --mode copy --role supervisor --quiet)"
check "A5 canonical AGENTS.md (worker)" "yes" "$([ -f "$R/w1/AGENTS.md" ] && echo yes || echo no)"
check "A6 canonical AGENTS.md (supervisor)" "yes" "$([ -f "$R/lead/AGENTS.md" ] && echo yes || echo no)"
check "A7 workspace managed block" "yes" "$(grep -q 'dsh-opencode-worker:start' "$R/w1/workspace/AGENTS.md" && echo yes || echo no)"
check "A8 worker brief mentions user equipment" "yes" "$(grep -q 'user equipment' "$R/w1/AGENTS.md" && echo yes || echo no)"
check "A9 supervisor brief mentions base station" "yes" "$(grep -q 'base station' "$R/lead/AGENTS.md" && echo yes || echo no)"
check "A10 supervisor brief mentions loop engineer" "yes" "$(grep -qi 'engineer' "$R/lead/AGENTS.md" && echo yes || echo no)"
"$S" --root "$R" agents w1 --task "new assignment" --write >/dev/null
check "A11 agents --write updates task" "yes" "$(grep -q 'new assignment' "$R/w1/AGENTS.md" && echo yes || echo no)"
"$S" --root "$R" room set --supervisor w2 --force >/dev/null
check "A12 new supervisor promoted" "supervisor" "$("$S" --root "$R" status w2 --json | jqp "d['role']")"
check "A13 old supervisor demoted to worker" "worker" "$("$S" --root "$R" status lead --json | jqp "d['role']")"
"$S" --root "$R" room set --supervisor lead --force >/dev/null
"$S" --root "$R" room set --clear-supervisor >/dev/null
check "A14 clear supervisor" "None" "$("$S" --root "$R" status w1 --json | jqp "d.get('supervisor')")"
"$S" --root "$R" agents w1 --write >/dev/null
check "A15 worker brief without supervisor" "yes" "$(grep -q 'No supervisor is set' "$R/w1/AGENTS.md" && echo yes || echo no)"
"$S" --root "$R" room set --supervisor lead >/dev/null

echo "== B. chat budget, approval and limits =="
check "B1 chat start requires approval" "2" "$(rc "$S" --root "$R" chat start --worker w1)"
CHAT=$(start_chat w1 3)
check "B2 chat created" "open" "$("$S" --root "$R" chat status --chat "$CHAT" --json | jqp "d['status']")"
check "B3 approval recorded" "user" "$("$S" --root "$R" chat status --chat "$CHAT" --json | jqp "d['approved_by']")"
check "B4 max-turns out of range" "2" "$(rc "$S" --root "$R" chat start --worker w1 --approved-by user --max-turns 999)"
USED_BEFORE=$("$S" --root "$R" room status --json | jqp "d['room']['messages_used']")
"$S" --root "$R" chat send --chat "$CHAT" --expect "reply" --expect-within 60 --prompt "hello" >/dev/null
check "B5 turn consumed" "1" "$("$S" --root "$R" chat status --chat "$CHAT" --json | jqp "d['turns_used']")"
check "B6 turn cost 2 messages" "$((USED_BEFORE+2))" "$("$S" --root "$R" room status --json | jqp "d['room']['messages_used']")"
check "B7 session stored after first turn" "yes" "$("$S" --root "$R" chat status --chat "$CHAT" --json | jqp "'yes' if d['session_id'] else 'no'")"
check "B8 is_new_session only on first turn" "2" "$(rc "$S" --root "$R" chat send --chat "$CHAT" --is-new-session true --expect x --expect-within 60 --prompt again)"
check "B9 turn not consumed by rejected send" "1" "$("$S" --root "$R" chat status --chat "$CHAT" --json | jqp "d['turns_used']")"
check "B10 chat list shows chat" "$CHAT" "$("$S" --root "$R" chat list --json | jqp "[c['chat'] for c in d if c['worker']=='w1'][0]")"

echo "== C. coordination channels =="
check "C1 supervisor broadcast cost 2" "2" "$(DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" room broadcast --kind note --text "standup" >/dev/null; "$S" --root "$R" room status --json | jqp "d['room']['coordination_sent']")"
check "C2 worker broadcast denied" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room broadcast --text nope)"
check "C3 worker note to supervisor denied" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room dm --to lead --kind note --text fyi)"
check "C4 worker question to supervisor allowed" "0" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room dm --to lead --kind question --text 'which branch?')"
check "C5 worker report denied with open chat" "4" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room dm --to lead --kind report --text done)"
check "C6 worker task to peer denied" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room dm --to w2 --kind task --text do)"
check "C7 worker note to peer allowed" "0" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room dm --to w2 --kind note --text heads)"
check "C8 supervisor dm to self denied" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" room dm --to lead --kind note --text self)"
check "C9 impersonation denied" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room broadcast --from lead --text nope)"
check "C10 worker cannot send chat turn" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" chat send --chat "$CHAT" --prompt self)"
check "C11 worker cannot close peer chat" "2" "$(rc env DSH_OPENCODE_WORKER_NAME=w2 "$S" --root "$R" chat close --chat "$CHAT")"
check "C12 message log records coordination" "yes" "$("$S" --root "$R" room log --scope dm --to w2 --json | jqp "'yes' if len(d)>=1 else 'no'")"

echo "== D. inbox injection =="
check "D1 unread inbox before turn" "yes" "$(DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room inbox --json | jqp "'yes' if d['unread']>0 else 'no'")"
OUT=$("$S" --root "$R" chat send --chat "$CHAT" --expect "reply" --expect-within 60 --prompt "continue")
check "D2 inbox injected into prompt" "yes" "$(printf '%s' "$OUT" | grep -q 'Chatroom inbox' && echo yes || echo no)"
check "D3 inbox drained after turn" "0" "$(DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room inbox --json | jqp "d['unread']")"
DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" room dm --to w1 --kind note --text "second wave" >/dev/null
CHAT2=$(start_chat w1 2)
"$S" --root "$R" chat send --chat "$CHAT2" --no-inbox --expect x --expect-within 60 --prompt "no inbox" >/dev/null
check "D4 --no-inbox keeps message queued" "yes" "$(DSH_OPENCODE_WORKER_NAME=w1 "$S" --root "$R" room inbox --json | jqp "'yes' if d['unread']>0 else 'no'")"
check "D5 --no-inbox records zero inbox count" "0" "$("$S" --root "$R" chat status --chat "$CHAT2" --json | jqp "d['turns'][0].get('inbox_count',0)")"

echo "== E. deferred close and report =="
CHAT3=$(start_chat w2 3)
"$S" --root "$R" chat send --chat "$CHAT3" --expect "slow" --expect-within 60 --timeout 20 --prompt "SLOW finish" > "$T/slow.out" 2>&1 &
BG=$!
sleep 1
check "E1 defer requested" "0" "$(rc env DSH_OPENCODE_WORKER_NAME=w2 "$S" --root "$R" chat close --chat "$CHAT3" --defer)"
check "E2 report allowed while deferred" "0" "$(rc env DSH_OPENCODE_WORKER_NAME=w2 "$S" --root "$R" room dm --to lead --kind report --text 'work complete')"
wait $BG
check "E3 deferred close applied" "closed" "$("$S" --root "$R" chat status --chat "$CHAT3" --json | jqp "d['status']")"
check "E4 report recorded in log" "yes" "$("$S" --root "$R" room log --kind report --json | jqp "'yes' if len(d)>=1 else 'no'")"
CHAT4=$(start_chat w2 3)
"$S" --root "$R" chat send --chat "$CHAT4" --expect "fail" --expect-within 60 --timeout 30 --prompt "SLOW FAIL turn" > "$T/fail.out" 2>&1 &
BG=$!
sleep 1
DSH_OPENCODE_WORKER_NAME=w2 "$S" --root "$R" chat close --chat "$CHAT4" --defer >/dev/null 2>&1
wait $BG
check "E5 failed turn drops deferred close" "open" "$("$S" --root "$R" chat status --chat "$CHAT4" --json | jqp "d['status']")"
check "E6 defer outside a turn closes now" "closed" "$(DSH_OPENCODE_WORKER_NAME=w2 "$S" --root "$R" chat close --chat "$CHAT4" --defer >/dev/null 2>&1; "$S" --root "$R" chat status --chat "$CHAT4" --json | jqp "d['status']")"

echo "== F. supervisor delegation =="
"$S" --root "$R" semaphore set --max-concurrent 1 >/dev/null
check "F1 delegation needs concurrency 2" "4" "$(rc env DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" chat send --chat "$CHAT2" --expect x --expect-within 60 --prompt delegate)"
"$S" --root "$R" semaphore set --max-concurrent 2 >/dev/null
DSH_OPENCODE_WORKER_NAME=lead "$S" --root "$R" chat send --chat "$CHAT2" --expect x --expect-within 60 --prompt delegate > "$T/f2.out" 2>&1
F2RC=$?
check "F2 supervisor delegation works" "0" "$F2RC"
[ "$F2RC" -eq 0 ] || { echo "   F2 output:"; sed 's/^/   /' "$T/f2.out"; }
echo "   F2 chat=$CHAT2 status: $("$S" --root "$R" chat status --chat "$CHAT2" --json | jqp "d['status']") turns=$("$S" --root "$R" chat status --chat "$CHAT2" --json | jqp "d['turns_used']")"
"$S" --root "$R" semaphore set --max-concurrent 3 >/dev/null

echo "== G. exhaustion, session precedence, limits =="
CHAT5=$(start_chat w2 1)
"$S" --root "$R" chat send --chat "$CHAT5" --expect x --expect-within 60 --prompt one >/dev/null
check "G1 exhausted chat rejects turn" "4" "$(rc "$S" --root "$R" chat send --chat "$CHAT5" --expect x --expect-within 60 --prompt two)"
check "G2 exhausted status" "exhausted" "$("$S" --root "$R" chat status --chat "$CHAT5" --json | jqp "d['status']")"
SES=$("$S" --root "$R" chat status --chat "$CHAT5" --json | jqp "d['session_id']")
CHAT6=$("$S" --root "$R" chat start --worker w2 --approved-by user --max-turns 2 --session "$SES" | sed -n 's/^chat: //p' | head -1)
"$S" --root "$R" chat send --chat "$CHAT6" --expect x --expect-within 60 --prompt resume >/dev/null
check "G3 linked session reused" "$SES" "$("$S" --root "$R" chat status --chat "$CHAT6" --json | jqp "d['session_id']")"
USED=$("$S" --root "$R" room status --json | jqp "d['room']['messages_used']")
"$S" --root "$R" room set --max-messages $((USED+1)) >/dev/null
TURNS_BEFORE=$("$S" --root "$R" chat status --chat "$CHAT6" --json | jqp "d['turns_used']")
check "G4 message budget blocks turn" "4" "$(rc "$S" --root "$R" chat send --chat "$CHAT6" --expect x --expect-within 60 --prompt blocked)"
check "G5 blocked turn not consumed" "$TURNS_BEFORE" "$("$S" --root "$R" chat status --chat "$CHAT6" --json | jqp "d['turns_used']")"
"$S" --root "$R" room set --max-messages 500 >/dev/null
OPEN=$("$S" --root "$R" room status --json | jqp "d['room']['open_chats']")
"$S" --root "$R" room set --max-open-chats "$OPEN" >/dev/null
check "G6 open chat limit blocks start" "4" "$(rc "$S" --root "$R" chat start --worker w2 --approved-by user)"
"$S" --root "$R" room set --max-open-chats 50 >/dev/null

echo "== H. semaphore =="
CHAT7=$(start_chat w1 3)
"$S" --root "$R" chat send --chat "$CHAT7" --expect x --expect-within 60 --timeout 20 --prompt "SLOW occupy" > "$T/occupy.out" 2>&1 &
BG=$!
sleep 1
check "H1 focus-fire blocked for same worker" "4" "$(rc "$S" --root "$R" chat send --chat "$CHAT2" --expect x --expect-within 60 --queue-timeout 0 --prompt again)"
check "H2 one active slot per worker" "1" "$("$S" --root "$R" semaphore status --json | jqp "[h['worker'] for h in d['holders']].count('w1')")"
wait $BG
"$S" --root "$R" semaphore set --max-concurrent 1 >/dev/null
"$S" --root "$R" run w1 --timeout 12 "HANG hold" > "$T/hold.out" 2>&1 &
BG=$!
sleep 1
CN=$(start_chat w2 2 normal)
CH=$(start_chat w2 2 high)
"$S" --root "$R" chat send --chat "$CN" --expect x --expect-within 60 --queue-timeout 30 --prompt normal >/dev/null 2>&1 &
Q1=$!
"$S" --root "$R" chat send --chat "$CH" --expect x --expect-within 60 --queue-timeout 30 --prompt high >/dev/null 2>&1 &
Q2=$!
sleep 2
check "H3 priority queue order" "high" "$("$S" --root "$R" semaphore status --json | jqp "d['waiters'][0]['priority']")"
kill $BG $Q1 $Q2 2>/dev/null
wait 2>/dev/null
"$S" --root "$R" semaphore set --max-concurrent 3 >/dev/null
python3 - "$R" <<'PY'
import json, os, sys
path = os.path.join(sys.argv[1], ".semaphore", "state.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"version": 1, "max_concurrent": 3, "seq": 9,
           "holders": [{"worker": "w1", "chat": "chat-old", "pid": 999999, "token": "stale", "priority": "normal"}],
           "waiters": []}, open(path, "w"))
PY
check "H4 stale holder cleaned" "0" "$("$S" --root "$R" semaphore status --json | jqp "d['active']")"

echo "== I. alerts and notifications =="
USED=$("$S" --root "$R" room status --json | jqp "d['room']['messages_used']")
"$S" --root "$R" room set --max-messages $((USED+1)) >/dev/null
check "I1 messages_low alert" "messages_low" "$("$S" --root "$R" room alerts --json | jqp "[a['code'] for a in d['alerts'] if a['code']=='messages_low'][0]")"
check "I2 fail-on-alert exit code" "4" "$(rc "$S" --root "$R" room alerts --fail-on-alert)"
check "I3 notification persisted" "yes" "$(grep -q 'messages_low' "$R/.chatroom/notifications.jsonl" && echo yes || echo no)"
check "I4 alert dedupe cooldown" "0" "$("$S" --root "$R" room alerts --json | jqp "len(d['new'])")"
check "I5 watch --once exit code" "4" "$(rc "$S" --root "$R" watch --once --fail-on-alert)"
check "I6 room status shows alerts" "yes" "$("$S" --root "$R" room status | grep -q 'alerts:' && echo yes || echo no)"
"$S" --root "$R" server stop --force >/dev/null 2>&1
check "I7 server_down alert" "server_down" "$("$S" --root "$R" room alerts --json | jqp "[a['code'] for a in d['alerts'] if a['code']=='server_down'][0]")"
"$S" --root "$R" server start >/dev/null
"$S" --root "$R" room set --max-messages 500 >/dev/null

echo "== I2. provider limit alert =="
PLCHAT=$(start_chat w2 2)
PLOUT=$("$S" --root "$R" chat send --chat "$PLCHAT" --expect x --expect-within 60 --timeout 30 --prompt "PROVIDERLIMIT nope" 2>&1)
check "I8 provider limit detected" "model_quota_exhausted" "$("$S" --root "$R" room alerts --json | jqp "[a['code'] for a in d['alerts'] if a['code']=='model_quota_exhausted'][0]")"
check "I9 provider limit explained in the turn output" "yes" "$(printf '%s' "$PLOUT" | grep -q '\[provider limit\]' && echo yes || echo no)"

echo "== J. server, API and monitor =="
check "J1 unauthenticated API rejected" "401" "$(python3 - "$R" <<'PY'
import json, sys, urllib.error, urllib.request
info = json.load(open(sys.argv[1] + "/.chatroom/server.json"))
url = f"http://{info['host']}:{info['port']}/api/status"
try:
    urllib.request.urlopen(url, timeout=5)
    print("200")
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
)"
check "J2 authenticated status works" "200" "$(python3 - "$R" <<'PY'
import json, sys, urllib.request
info = json.load(open(sys.argv[1] + "/.chatroom/server.json"))
req = urllib.request.Request(f"http://{info['host']}:{info['port']}/api/status")
req.add_header("Authorization", "Bearer " + info["token"])
with urllib.request.urlopen(req, timeout=5) as resp:
    print(resp.status)
PY
)"
check "J3 monitor page renders alerts banner" "yes" "$(python3 - "$R" <<'PY'
import json, sys, urllib.request
info = json.load(open(sys.argv[1] + "/.chatroom/server.json"))
with urllib.request.urlopen(f"http://{info['host']}:{info['port']}/?token=" + info["token"], timeout=5) as resp:
    html = resp.read().decode()
print("yes" if 'id="alerts"' in html and "renderAlerts" in html else "no")
PY
)"
check "J4 worker cannot create chat via API" "403" "$(python3 - "$R" <<'PY'
import json, sys, urllib.error, urllib.request
info = json.load(open(sys.argv[1] + "/.chatroom/server.json"))
req = urllib.request.Request(
    f"http://{info['host']}:{info['port']}/api/chats",
    data=json.dumps({"worker": "w2", "max_turns": 2, "approved_by": "user"}).encode(),
    method="POST")
req.add_header("Authorization", "Bearer " + info["token"])
req.add_header("Content-Type", "application/json")
req.add_header("X-Worker-Name", "w1")
try:
    urllib.request.urlopen(req, timeout=5)
    print("200")
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
)"
check "J5 worker cannot change limits via API" "403" "$(python3 - "$R" <<'PY'
import json, sys, urllib.error, urllib.request
info = json.load(open(sys.argv[1] + "/.chatroom/server.json"))
req = urllib.request.Request(
    f"http://{info['host']}:{info['port']}/api/limits",
    data=json.dumps({"max_messages": 99999}).encode(), method="POST")
req.add_header("Authorization", "Bearer " + info["token"])
req.add_header("Content-Type", "application/json")
req.add_header("X-Worker-Name", "w1")
try:
    urllib.request.urlopen(req, timeout=5)
    print("200")
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
)"
check "J6 server restart keeps chats" "$CHAT" "$("$S" --root "$R" server restart --force >/dev/null; "$S" --root "$R" chat status --chat "$CHAT" --json | jqp "d['chat_id']")"
check "J7 interrupted turns normalized" "0" "$("$S" --root "$R" room status --json | jqp "d['room']['active_turns']")"

echo "== L. crash recovery =="
CRASHCHAT=$(start_chat w1 2)
"$S" --root "$R" chat send --chat "$CRASHCHAT" --expect x --expect-within 60 --timeout 60 --prompt "HANG crash" > "$T/crash.out" 2>&1 &
BG=$!
sleep 2
SRVPID=$("$S" --root "$R" server status --json | jqp "d['server']['pid']")
kill -9 "$SRVPID" 2>/dev/null
pkill -f "fake-opencode" 2>/dev/null
wait $BG 2>/dev/null
rm -f "$R/.chatroom/server.json"
check "L1 crash marks turn interrupted" "interrupted" "$("$S" --root "$R" chat status --chat "$CRASHCHAT" --json 2>/dev/null | jqp "d['turns'][-1]['status']")"
check "L2 no active turns after crash" "0" "$("$S" --root "$R" room status --json | jqp "d['room']['active_turns']")"
check "L3 message pair completed after crash" "2" "$("$S" --root "$R" room log --chat "$CRASHCHAT" --json | jqp "len([m for m in d if m.get('chat')=='$CRASHCHAT'])")"
check "L4 chat usable after crash" "0" "$(rc "$S" --root "$R" chat send --chat "$CRASHCHAT" --expect x --expect-within 60 --prompt 'after crash')"

echo "== K0. task-aware working loop =="
"$S" --root "$R" new loopbug --mode empty --task "fix the failing auth tests" --quiet >/dev/null 2>&1
check "K0a bug task picks the bugfix loop" "bugfix" "$("$S" --root "$R" status loopbug | sed -n 's/^loop: //p')"
check "K0b worker brief carries the loop" "yes" "$(grep -q 'Working method (bug fix)' "$R/loopbug/AGENTS.md" && echo yes || echo no)"
check "K0c cell protocol kept" "yes" "$(grep -q '## Cell protocol' "$R/loopbug/AGENTS.md" && echo yes || echo no)"
check "K0d supervisor has a cell definition of done" "yes" "$(grep -q '## Definition of done' "$R/lead/AGENTS.md" && echo yes || echo no)"

echo "== K. one-off run and cleanup =="
check "K1 one-off run works" "0" "$(rc "$S" --root "$R" run w2 'one-off task')"
check "K2 run auto-creates missing worker" "0" "$(rc "$S" --root "$R" run w3 'another task')"
check "K3 destroy removes worker" "0" "$(rc "$S" --root "$R" destroy w3 --force)"
check "K4 destroyed worker gone" "no" "$([ -d "$R/w3" ] && echo yes || echo no)"
"$S" --root "$R" doctor > "$T/doctor.txt" 2>&1
check "K5 doctor reports roles" "yes" "$(grep -q 'supervisor lead' "$T/doctor.txt" && echo yes || echo no)"
check "K6 doctor reports no warnings" "0" "$("$S" --root "$R" doctor | grep -c '^warning:')"

"$S" --root "$R" server stop --force >/dev/null 2>&1
echo "== M. remaining command surface =="
PRIOCHAT=$(start_chat w1 2)
"$S" --root "$R" chat send --chat "$PRIOCHAT" --priority low --expect x --expect-within 60 --prompt "low priority" >/dev/null 2>&1
check "M1 per-turn priority recorded" "low" "$("$S" --root "$R" chat status --chat "$PRIOCHAT" --json | jqp "d['turns'][0].get('priority')")"
SEQ=$("$S" --root "$R" room log --json | jqp "d[-1]['seq']")
check "M2 room log --since filter" "0" "$("$S" --root "$R" room log --since "$SEQ" --json | jqp "len(d)")"
check "M3 room log --scope filter" "yes" "$("$S" --root "$R" room log --scope dm --json | jqp "'yes' if all(m.get('scope')=='dm' for m in d) else 'no'")"
check "M4 room log --kind filter" "yes" "$("$S" --root "$R" room log --kind report --json | jqp "'yes' if all(m.get('kind')=='report' for m in d) else 'no'")"
"$S" --root "$R" room set --clear-supervisor >/dev/null
rm -f "$T/notify.out"
"$S" --root "$R" watch --once --notify-command "cat >> $T/notify.out" >/dev/null 2>&1
check "M5 watch --notify-command fires" "yes" "$(grep -q 'no_supervisor' "$T/notify.out" 2>/dev/null && echo yes || echo no)"
"$S" --root "$R" room set --supervisor lead >/dev/null
check "M6 doctor --models lists models" "yes" "$("$S" --root "$R" doctor --models | grep -q 'deepseek-v4.1-flash-free' && echo yes || echo no)"
"$S" --root "$R" agents lead --write >/dev/null
check "M7 supervisor brief regenerated" "yes" "$(grep -q 'base station' "$R/lead/AGENTS.md" && echo yes || echo no)"
"$S" --root "$R" room set --max-messages 0 >/dev/null
check "M8 unlimited message budget accepted" "0" "$("$S" --root "$R" room status --json | jqp "d['room']['max_messages']")"
"$S" --root "$R" room set --max-messages 500 >/dev/null

echo "== N. server pre-flight and safety =="
rm -f "$R/.chatroom/server.json"
OUT=$("$S" --root "$R" chat start --worker w1 --approved-by user 2>&1)
check "N1 refuses to start a second server" "yes" "$(printf '%s' "$OUT" | grep -q 'already running' && echo yes || echo no)"
check "N2 still exactly one server process" "1" "$("$S" --root "$R" server status --json 2>/dev/null | jqp "len(d.get('processes') or [])")"
"$S" --root "$R" server status --json > "$T/n3.json" 2>&1
"$S" --root "$R" server status > "$T/n3.txt" 2>&1
check "N3 status reports the unmanaged process" "yes" "$(grep -q 'is a chatroom server process' "$T/n3.txt" && echo yes || echo no)"
check "N3b pid file fallback detected it" "yes" "$([ -f "$R/.chatroom/server.pid" ] && echo yes || echo no)"
"$S" --root "$R" server stop --force >/dev/null 2>&1
check "N4 server stopped" "0" "$("$S" --root "$R" server status --json 2>/dev/null | jqp "len(d.get('processes') or [])")"
check "N5 auto start works again" "0" "$(rc "$S" --root "$R" chat start --worker w1 --approved-by user)"
sleep 300 &
VICTIM=$!
python3 - "$R" "$VICTIM" <<'PY2'
import json, os, sys
root, victim = sys.argv[1], int(sys.argv[2])
path = os.path.join(root, ".chatroom", "server.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"version": "1.6.0", "pid": victim, "host": "127.0.0.1", "port": 59999,
           "token": "stale", "url": "http://127.0.0.1:59999", "root": root,
           "started_at": "2020-01-01T00:00:00Z"}, open(path, "w"))
PY2
check "N6 stop refuses a foreign pid" "4" "$(rc "$S" --root "$R" server stop)"
check "N7 foreign process survived" "yes" "$(ps -p "$VICTIM" >/dev/null 2>&1 && echo yes || echo no)"
check "N8 force stop exits cleanly" "0" "$(rc "$S" --root "$R" server stop --force)"
check "N9 force did not kill the foreign pid" "yes" "$(ps -p "$VICTIM" >/dev/null 2>&1 && echo yes || echo no)"
check "N10 verified server stopped" "0" "$("$S" --root "$R" server status --json 2>/dev/null | jqp "len(d.get('processes') or [])")"
kill "$VICTIM" 2>/dev/null
check "N11 pid file removed on stop" "no" "$([ -f "$R/.chatroom/server.pid" ] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
