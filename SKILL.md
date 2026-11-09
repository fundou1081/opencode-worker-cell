---
name: opencode-worker-cell
description: Run a multi-worker cell with a local chatroom server: one supervisor (base station) schedules several workers (user equipment), each with a role-specific AGENTS.md, a budgeted chat, an inbox, and cost-accounted broadcast/DM channels. The chatroom records every message and enforces global chat and message limits, a global concurrency semaphore keeps the cell stable, and programmatic budget alerts notify the user when capacity runs low. Use when the user wants a team of OpenCode workers coordinated by a base station, several workers talking to each other, or a shared budget across many delegations. For a single standalone worker without a chatroom, use the opencode-worker skill instead.
whenToUse: The user asks to coordinate several OpenCode workers as a cell: a supervisor that assigns work packages, broadcasts or DMs its workers, tracks deadlines, collects reports, and escalates; or the user wants shared chat/message budgets, an inbox, and budget alerts across many delegations. For a single independent task with one worker, use the opencode-worker skill instead.
---

# OpenCode Worker Cell

Coordinate several persistent OpenCode workers as a small mobile network: one **supervisor** (base station) and many **workers** (user equipment) that chat over a local chatroom server with budgeted turns, cost-accounted broadcast/DM channels, and an inbox. Only a worker's final answer is printed; intermediate tool output stays in its logs. The same skill works under dsh and OpenCode: the manager only needs Python 3.9+, git, and the `opencode` CLI.

This is the **cell** skill. For a single standalone worker with no chatroom, no supervisor, and no coordination channels, use the **opencode-worker** skill instead.

The manager is `scripts/opencode-worker` beside this `SKILL.md` (run with `--profile full`). Resolve the absolute path from the skill base directory (dsh exposes it as `<skill_resources>`; OpenCode passes it with the loaded skill) and repeat it in every bash call:

```sh
W=/absolute/path/to/opencode-worker-cell/scripts/opencode-worker
```

`chat` and `room` commands talk to a small local **chatroom server** that owns chat creation, turn execution, room-wide limits, and the message log. It auto-starts on `127.0.0.1` with a random token when needed. `run` remains a local one-off and shares the same execution semaphore. The full component and turn-flow diagram is in `README.md` under *How it works → Architecture*.

## Using from OpenCode

OpenCode discovers skills under `~/.config/opencode/skills/<id>/SKILL.md` (or `.opencode/skills` in a project). Install this directory there, for example:

```sh
mkdir -p ~/.config/opencode/skills
ln -s ~/.dsh/skills/opencode-worker-cell ~/.config/opencode/skills/opencode-worker-cell
```

Then mention `@opencode-worker-cell` in a prompt or let the model load it by description. The manager is a standalone Python script: it invokes the `opencode` CLI directly and does not depend on dsh. The worker root defaults to `~/.dsh/opencode-workers`; override it with `--root` or `DSH_OPENCODE_WORKERS`. If OpenCode is already running, restart it or run with `--standalone` to pick up a newly installed skill.

## Mobile-network model

Model the project as a small mobile network. The **supervisor is the base station**; every **worker is user equipment** attached to one root. The calling agent (dsh or OpenCode) is the operator outside the network. One root has exactly one supervisor; every other worker has `supervisor: <name>` in `meta.json`.

| Channel | Direction | Rule | Cost |
|---|---|---|---|
| Broadcast | supervisor → all workers | Paging channel; supervisor only. | 1 message **per recipient**. |
| DM | supervisor ↔ worker, worker ↔ worker | Dedicated channel; supervisor may send `note`, `task`, `question`; workers may DM the supervisor with `question` or `report`, and each other with `note` or `question`. | 1 message per recipient. |
| Inbox | server → worker | Downlink queue; unread messages are injected into the worker's next `chat send` prompt, then the cursor advances. | Already counted at send time. |
| Report | worker → supervisor | Uplink control message, allowed only when the worker has no open chat, or has requested `chat close --defer` on its current chat. | 1 message. |
| Question | worker → supervisor | Uplink control message, allowed at any time. | 1 message. |

A chat turn itself records **2 messages** (user prompt + assistant result). A broadcast to N workers costs N messages. If the message budget cannot cover the operation, it exits 4 before recording anything. The base station (supervisor) should watch the budget and proactively tell the user when it is insufficient; `room alerts` and `watch` do this programmatically.

## Roles and AGENTS.md

```sh
# One supervisor per root. It is the loop engineer: process, scheduling, coordination.
"$W" new lead --role supervisor --task "ship the release" --source ~/code/project

# Workers own concrete assignments.
"$W" new fix-auth --role worker --task "fix the auth tests" --source ~/code/project
"$W" new fix-ui   --role worker --task "repair the settings page" --source ~/code/project
```

- `--role supervisor|worker` (default `worker`). `new` refuses a second supervisor; use `room set --supervisor NAME --force` to replace one.
- `new` builds the whole worker: `<root>/<worker>/AGENTS.md`, `meta.json`, `logs/`, and the workspace (git worktree for a git `--source`, copy otherwise, empty without one). Do not `mkdir` and do not write `AGENTS.md` yourself.
- Each worker gets a canonical `<root>/<worker>/AGENTS.md`: supervisors get a loop-engineer brief (decompose, assign, track deadlines, escalate); workers get a responsibility brief (stay in the assignment, verify, report only when complete or blocked).
- The manager also maintains a marked block in `<workspace>/AGENTS.md` so OpenCode sees the role instructions in the workspace. `agents NAME [--task TEXT] [--agents-file FILE] [--loop PROFILE] [--write]` previews or regenerates it.
- The **working method** in the brief follows the task: `bugfix`, `feature`, `test`, `refactor`, `perf`, `research`, `docs`, `infra`, or `generic`. It is detected from `--task`; check it with `status NAME` and pin it with `--loop PROFILE`.
- `room set --supervisor NAME` promotes a worker and demotes the previous supervisor; `--clear-supervisor` removes the role. Roles are recorded in `meta.json` and shown by `status`, `list`, `chat list`, `room status`, and the monitor.

## Coordination channels

```sh
# Supervisor paging all workers (cost = number of active workers).
"$W" room broadcast --kind note --text "Standup: report blockers before 14:00."

# Dedicated message (cost 1).
"$W" room dm --to fix-auth --kind task --text "Also update the changelog."

# Worker uplink (inside a worker turn; the sender is taken from the environment).
"$W" room dm --to lead --kind question --text "Should I touch the migration?"
"$W" room dm --to lead --kind report   --text "Done: tests pass, diff committed."

# Read the downlink queue. A chat send injects it automatically.
"$W" room inbox [--worker NAME] [--mark]

# Inspect the recorded feed, including coordination cost.
"$W" room log --scope dm --limit 50
```

- **Supervisor delegation**: the supervisor may call `chat send` from inside its own OpenCode turn to drive a worker. This requires `semaphore set --max-concurrent 2` or more (the supervisor's turn and the worker turn must coexist); with 1 it exits 4. Workers cannot send chat turns.
- **Deferred close**: when a worker finishes, it runs `chat close --chat ID --defer`, then sends its `report`. The server closes the chat after the current turn succeeds; if the turn fails, the deferred close is dropped. A `report` while an open chat exists without a deferred close exits 4. A finished worker therefore frees its open-chat slot; follow-up work needs a **new** approved chat (`chat start --worker NAME --session <session-id>`) to keep the same OpenCode session.
- **Supervisor inbox**: worker reports and questions land in the supervisor's own inbox. Read it with `room inbox` (a supervisor chat turn injects it automatically).
- **No implicit recipient**: always pass `--to` for DMs. `room broadcast` rejects a single recipient.
- Coordination messages are counted in the same `max_messages` budget as chat turns. Keep them short and purposeful.

## Chat budget (use this for multi-turn work)

Every delegation that may need more than one message runs inside a **chat** with a hard turn budget, a room-wide message quota, and a local ledger. The chatroom server records the user prompt and assistant result for every turn.

```sh
# 1. Create a chat. Approval is mandatory.
"$W" chat start --worker fix-auth --max-turns 6 --priority high \
  --approved-by user --note "fix the auth tests"
# prints: chat: chat-20261108T...

# 2. Send one turn. Always record what you expect and when.
"$W" chat send --chat chat-20261108T... \
  --expect "auth tests pass" --expect-within 600 \
  --prompt-file - <<'EOF'
Objective: fix the failing auth tests.
Context: failures are in tests/auth; token expiry logic is in src/auth/token.ts.
Verification: run `pytest tests/auth -q` and report the result.
Report back: changed files, test summary, remaining risks.
EOF

# 3. Check the local ledger. Overdue work is marked OVERDUE.
"$W" chat status --chat chat-20261108T...
"$W" chat list --open

# 4. Close when done.
"$W" chat close --chat chat-20261108T...
```

Rules:

- **Budget**: default 10 turns, hard cap 50 (`--max-turns`). Each `chat send` consumes one turn before it runs; failed, timed-out, and queue-timed-out turns still count. One chat runs one turn at a time; a concurrent send to the same chat exits 4 without consuming a turn.
- **Exhaustion**: at the limit the chat stops with exit 4. To continue the same OpenCode session, ask the user or admin to approve a **new** chat with `--session <session-id>`. Never start a new chat silently.
- **Approval**: `chat start` requires `--approved-by user|admin` and stores `approved_at` plus an optional `--note`. Do not claim approval you did not receive.
- **Expectations**: always pass `--expect TEXT` and `--expect-within SEC`. `chat status`/`chat list` expose the deadline and `OVERDUE`; when due, check progress and report to the user. Do not busy-poll.
- **Priority**: `--priority high|normal|low` (default `normal`) orders the global execution queue. Set it at `chat start`, or override for one turn with `chat send --priority`.
- **Room limits**: the chatroom enforces a global open-chat count and total message count. Each turn records two messages (prompt + result). When either limit is reached, new chats/turns exit 4; raise the limit with `room set` or close chats. Do not bypass.

## Chatroom limits

The local chatroom enforces two room-wide limits stored in `<root>/.chatroom/state.json`:

- `max_open_chats` (default 10; `0` = unlimited): counts chats whose status is `open`. Exhausted and closed chats free slots. `chat start` exits 4 when full.
- `max_messages` (default 500; `0` = unlimited): total messages across all chats **and coordination channels**. Each turn reserves and records 2 messages (user prompt + assistant result), including failed, queue-timed-out, and interrupted turns. A broadcast to N workers costs N messages; a DM costs 1. If fewer than 2 remain, `chat send` exits 4 **before** consuming a turn; coordination exits 4 if its cost cannot be covered.

```sh
"$W" room status
"$W" room set --max-open-chats 20 --max-messages 2000
"$W" room log --chat chat-20261108T... --limit 50
"$W" room log --scope dm --from lead --limit 50
```

The monitor page (`server url --monitor`) shows room usage, roles, chats, alerts, and the message/coordination feed, and provides simple send/close/limit/supervisor/broadcast/DM controls.

## Local chatroom server

The server is per worker root. It binds only `127.0.0.1` on an ephemeral port and requires a bearer token stored in `<root>/.chatroom/server.json` (mode 0600). `chat` and `room` commands auto-start it; no manual step is needed.

**Pre-flight before starting**: the manager never assumes it is the only server. Before it starts one it checks the process table and `<root>/.chatroom/server.pid` for a chatroom server that already belongs to this root. If one exists, the command fails with exit 4 and names the pid instead of starting a second server (two servers on one root would race on the room state, the chat locks and the semaphore). `server status` lists every server process it finds, and `server stop` only kills a pid whose command line still points at this root; a stale or recycled pid is reported, never killed, even with `--force` (which only escalates a verified server that ignores SIGTERM).

```sh
"$W" server status
"$W" server url --monitor
"$W" server stop              # refuses while a turn is active
"$W" server restart --force   # explicit; active turns are interrupted
"$W" server logs --tail 50
```

Files under `<root>/.chatroom/`:

- `state.json` — limits, message/turn usage, supervisor, inbox cursors, and alert dedupe state.
- `messages.jsonl` — every recorded chat message and coordination message.
- `notifications.jsonl` — new budget/health alerts (JSONL).
- `server.json` — pid, host, port, and token for the running server.
- `server.pid` — pid and start time of the running server; survives a lost `server.json` so a second server is never started by accident.
- `server.log` — request log and errors.

On restart, turns left `queued` or `running` are marked `interrupted`, and any missing message pair is completed in the log. `server stop` and `server restart` refuse active or waiting turns unless `--force`.

## Alerts and watchdog

Budget and health alerts are computed **programmatically** by the manager, so they work even when the model quota is exhausted. Thresholds:

- `messages_low` / `messages_exhausted`: 80% of `max_messages` used, then 0 left.
- `open_chats_high` / `open_chats_exhausted`: 80% of `max_open_chats`, then the limit.
- `turns_overdue`: any turn past its `--expect-within` deadline.
- `queue_backlog`: semaphore waiters reach `max(3, 2 × max_concurrent)`.
- `no_supervisor` / `multiple_supervisors`: role topology is wrong.
- `model_quota_exhausted`: a recent turn was refused by the model provider (free-tier, quota, or rate limit). Switch the worker model with `--model` or ask the user for a paid provider; the failure text is kept in the alert.
- `server_down`: the chatroom server is not reachable while open chats, active turns, or server metadata exist.

```sh
"$W" room alerts                 # current alerts + recent notifications
"$W" room alerts --fail-on-alert # exit 4 when anything is active
"$W" watch --once --verbose      # one check, no model cost
"$W" watch --interval 30 \
  --notify-command 'terminal-notifier -title "chatroom" -message "$(cat)"'
```

New alerts are appended to `<root>/.chatroom/notifications.jsonl` (deduplicated with a 5-minute cooldown), exposed at `GET /api/alerts`, and rendered as a banner on the monitor page. `watch` is optional and out-of-band: it only observes the base station/chatroom and never schedules work. The supervisor may run `room alerts` inside its own turn; workers may not. The supervisor handles semantic escalation (re-plan, request a new budget) only when budget remains.

## Session precedence

- `--is-new-session true` starts a fresh session. It is valid only on the first turn of a chat and only if the chat has no linked session.
- `--is-new-session false` (default) resumes the chat's linked session.
- A chat created without `--session` starts fresh on its first turn; the resulting session id is stored in the chat.
- After exhaustion, continue the same session with a new approved chat: `chat start --worker NAME --session SES ...`.
- `chat start --session SES` links an existing session from the first turn.

## One-off runs

`run NAME TASK...` is the unbudgeted shorthand for a single self-contained task. It auto-creates a missing worker and resumes the worker's stored session. Prefer `chat` whenever the task may need follow-up messages; use `run` only when one turn is enough.

```sh
"$W" run fix-auth "Also update the changelog."
```

## Global semaphore

Every `run` and `chat send` acquires a slot from the central queue at `<root>/.semaphore`. Every process using the same worker root shares this queue:

- Global concurrency default **3**; change it with `semaphore set --max-concurrent N` (1–16). Lowering it does not preempt active holders.
- At most **one active slot per worker**, so concurrent chats cannot focus-fire the same worker. Extra turns wait in the queue.
- Queue order: priority first, then the worker with fewer queued chats, then arrival order.
- `--queue-timeout SEC` controls how long to wait (default 300; `0` fails fast). A queue timeout consumes the chat turn.
- Inspect active holders and waiters with `semaphore status [--json]`.

## Nesting and supervisor delegation

Workers are launched with `DSH_OPENCODE_WORKER_DEPTH`. `create`/`new`, `run`/`send`, `chat start`, `chat close`, `destroy`, `semaphore set`, `room set`, `room broadcast`, and `server start|stop|restart` refuse to run at depth > 0. A worker can never create or drive another worker. The one deliberate exception is the **supervisor** role: a supervisor may call `chat send` to drive its workers from inside its own turn (see *Coordination channels*), and it may broadcast. Workers may only DM. The chatroom server's child `run` also executes at depth+1, so a manually started server cannot delegate from inside a worker. Do not set `DSH_OPENCODE_ALLOW_NESTED=1` unless the user explicitly asks for a deliberate lead-worker setup; the calling agent remains the outer orchestrator.

## Model selection

Prefer the strongest available model for the task, not the default. In this
environment the observed capability order is:

1. `opencode/deepseek-v4.1-flash-free` — strongest of the free tier; use for
   independent implementation, debugging, refactors, multi-file changes, and
   test authoring. It may be rate-limited; switch rather than retrying blindly.
2. `minimax-cn-coding-plan/MiniMax-M3` (or newer MiniMax) — good for bounded
   implementation, test/review work, documentation, and verification runs.
   Keep architecture-critical or high-risk changes under caller review.
3. `ollama/*-cloud` (ultra is the strongest Ollama option) — use for simple,
   read-only, or short tasks: investigation, data collection, running an
   existing test, summarizing, or checking a diff. Do not assign large
   autonomous multi-file development without a stronger model.

Use `doctor --models` to confirm the current IDs and quotas. The ordering is a
task-allocation default, not a benchmark claim: a stronger model that is
quota-limited or misconfigured is not usable. Escalate to the strongest
available model for high-risk work; use cheaper/weaker models only when the
task is isolated and easy to verify.

In a cell, give the supervisor the strongest available model; assign each
worker according to its task (DeepSeek for independent development, MiniMax
for bounded tests/review, Ollama for simple investigation).

## Defaults

- **Workspace**: git worktree when the source is a git repo with a commit, otherwise a filtered copy. `--mode empty` for pure research.
- **Model**: `opencode/deepseek-v4.1-flash-free` — free, no API key. Override with `--model provider/model`.
- **Agent**: `build`.
- **Output**: only the final assistant text. Raw JSONL and stderr stay in `~/.dsh/opencode-workers/<name>/logs/`.

Workers call the `opencode` CLI directly and never use the calling agent's model or credentials. `doctor --models` lists available models; names ending in `-free` use the free quota.

## Commands

| Command | Purpose |
|---|---|
| `chat start --worker NAME --approved-by user\|admin [--max-turns N] [--priority P] [--session SES]` | Create a budgeted chat via the chatroom server. |
| `chat send --chat ID [--expect TEXT] [--expect-within SEC] [--priority P]` | Send one turn, consume the budget, and record both messages. |
| `chat status --chat ID [--json]` | Show budget, turns, deadlines, and semaphore position. |
| `chat list [--worker NAME] [--open] [--overdue] [--json]` | The local delegation ledger across workers. |
| `chat close --chat ID [--defer]` | Close a chat and free its open-chat slot; `--defer` closes after the current turn (worker completion). |
| `room status [--json]` | Show room limits, usage, roles, and active turns. |
| `room set [--max-open-chats N] [--max-messages N] [--supervisor NAME] [--clear-supervisor] [--force]` | Change room-wide limits or the supervisor role. |
| `room broadcast --kind K --text T` | Supervisor paging channel to all workers (cost = N). |
| `room dm --to NAME --kind K --text T` | Dedicated message (cost 1); worker uplink rules apply. |
| `room inbox [--worker NAME] [--mark]` | Read undelivered coordination messages. |
| `room alerts [--fail-on-alert] [--json]` | Compute budget/health alerts and show notifications. |
| `room log [--chat ID] [--worker NAME] [--scope SCOPE] [--from NAME] [--to NAME] [--kind K] [--since SEQ] [--json]` | Read the recorded message log. |
| `watch [--once] [--interval SEC] [--notify-command CMD]` | Out-of-band alert watchdog; no model cost. |
| `agents NAME [--task TEXT] [--agents-file FILE] [--write]` | Preview or regenerate a worker's `AGENTS.md`. |
| `server status\|start\|stop\|restart\|url\|logs` | Manage the local chatroom server. |
| `semaphore status [--json]` | Show active slots and the waiting queue. |
| `semaphore set --max-concurrent N` | Set the global concurrency limit (1–16). |
| `status NAME` | Query one worker's state. |
| `list [--all]` | List workers. |
| `session NAME [--json]` | Show a worker's session id. |
| `new NAME [--role supervisor\|worker] [--task TEXT] [--agents-file FILE]` | Create a worker and its `AGENTS.md`. |
| `run NAME [TASK...]` | One-off unbudgeted run; auto-creates and resumes. |
| `result NAME` | Print the last full result. |
| `diff NAME` | `--stat`, `--name-only`, or `--patch`. |
| `commit NAME -m MSG` | Commit workspace changes. |
| `destroy NAME` | Remove state/worktree; `--force` for dirty worktrees; `--delete-session` also deletes the session. |
| `doctor [--models] [--json]` | Check the environment and list models. |

`create` is the same as `new`. `close` and `logs` remain available for cleanup and debugging. Run any command with `--help` for its full flags.

## Writing the brief

The worker starts with a fresh context, so the brief must stand alone:

```text
Objective: one concrete outcome.
Context: repository layout, relevant files, constraints, versions, credentials already in the environment.
Deliverables: files to change or create; behavior required.
Verification: exact commands and expected results.
Report back: a short summary, verification evidence, and remaining risks.
Do not: unrelated refactors, dependency upgrades, branch changes, or changes outside the workspace.
```

Tell it to stay inside the workspace and verify its own work. Ask for a summary and file paths, not full logs or pasted files.

## Parallel and long tasks

Use one worker per independent task; different workers run in parallel subject to the global semaphore. The same worker never runs twice at once; a second turn waits in the semaphore queue. For tasks that may exceed the caller's shell timeout, run the call as a background job and collect it with the caller's job tool (dsh `job_output`; OpenCode background shell).

## Safety

- `opencode run --auto` grants full file and shell permissions. The workspace isolates context, not the machine.
- Review `diff --patch` before merging or applying changes.
- `destroy` refuses a live run and a dirty worktree without `--force`.
- Uncommitted source changes are not copied into a worktree; commit or stash first, or use copy mode.

## Troubleshooting

| Symptom | Action |
|---|---|
| `opencode executable not found` | Run `doctor`; install OpenCode or set `OPENCODE_BIN`. |
| `chat ... quota exhausted` | Ask the user/admin for a new approved chat with `--session <id>`; do not bypass. |
| `chatroom open-chat limit reached` | Close finished chats or raise `room set --max-open-chats`; do not bypass. |
| `chatroom message limit reached` | Raise `room set --max-messages`, or stop and report; do not delete the log to bypass. |
| `report requires no open chat` | Finish the work, run `chat close --chat ID --defer`, then send the report. |
| `workers cannot broadcast` | Use `room dm --to NAME`; only the supervisor broadcasts. |
| `supervisor delegation needs max_concurrent >= 2` | Ask the user/admin to run `semaphore set --max-concurrent 2`. |
| `chatroom message budget low/exhausted` | Run `room alerts`; ask the user/admin to raise `--max-messages` or approve a new chat; do not bypass. |
| `chatroom server unreachable` | Run `room alerts` and `server status`; the `watch` watchdog reports `server_down` without a model. |
| `server has N active turn(s)` | Wait for the turn, or use `--force` only with explicit approval. |
| Monitor returns 401 | Use the tokenized URL from `server url --monitor`; the token is per server run. |
| `timed out ... semaphore slot` | Check `semaphore status`; wait, raise `--queue-timeout`, or use another worker. |
| Worker busy (exit 4) | Wait, pass `--wait`, or use another worker. |
| Status `interrupted` | Run again; the session and workspace are reused. |
| Auth/provider error | Retry with a free model via `--model opencode/<name>-free`; otherwise fix OpenCode config. |
| Run timed out | Prefer background jobs; check `status`; use `--new-session` if the session looks confused. |

## Environment

`DSH_OPENCODE_WORKERS` overrides the worker root, `OPENCODE_BIN` the OpenCode binary, `DSH_HOME` the default root base. Default root: `~/.dsh/opencode-workers`.
