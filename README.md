# opencode-worker-cell

A dsh/OpenCode skill that runs a **cell** of persistent [OpenCode](https://opencode.ai) workers: one supervisor (base station) and many workers (user equipment) coordinated over a local chatroom server with budgeted turns, cost-accounted broadcast/DM channels, an inbox, and programmatic budget alerts. Each worker has its own workspace, full file and shell permissions, and a resumable session. Only the worker's final answer is printed, so intermediate tool output does not consume the caller's context. A small local chatroom server records every chat message and enforces room-wide chat and message limits. Workers form a mobile-network-style cell: one supervisor (base station) schedules the work, and every worker (user equipment) has a role-specific `AGENTS.md`, a budgeted chat, an inbox, and cost-accounted coordination channels.

## Requirements

- macOS or Linux
- Python 3.9+
- git
- OpenCode CLI on `PATH` (or set `OPENCODE_BIN`); no paid provider is required — OpenCode's free models work without authentication. Tested with v2.2.6, which provides `run --format json`, `--session`, and `--auto`

## Installation

This repository is self-contained: `scripts/opencode-worker` is the whole manager, vendored with
the **cell** profile as its default (chatroom server, roles, broadcast/DM, alerts).

**OpenCode** - clone it into the global skill directory:

```sh
git clone https://github.com/fundou1081/opencode-worker-cell.git \
    ~/.config/opencode/skills/opencode-worker-cell
```

**dsh** - clone it into the skill directory:

```sh
git clone https://github.com/fundou1081/opencode-worker-cell.git \
    ~/.dsh/skills/opencode-worker-cell
```

Either way the skill is discovered through its `SKILL.md`. The manager only needs
`scripts/opencode-worker` to be executable.

```text
opencode-worker-cell/
├── SKILL.md                 # model-facing instructions
├── README.md                # this file
├── scripts/
│   └── opencode-worker      # the manager (cell profile by default)
└── tests/                   # regression suite
```

Verify the environment:

```sh
./scripts/opencode-worker doctor
```

### OpenCode discovery

OpenCode discovers `SKILL.md` under `~/.config/opencode/skills/<id>/` and `.opencode/skills/` in
a project. Mention `@opencode-worker-cell` in a prompt, or let OpenCode load it from the
description in `SKILL.md`. The manager is standalone: it only needs Python 3.9+, git, and the
`opencode` CLI. If OpenCode is already running, restart it or use `--standalone` to pick up a new
skill. Use `--root` (or `DSH_OPENCODE_WORKERS`) to isolate test roots from the default worker
root.
## How it works

A worker is a name plus:

- **Role**: `supervisor` (base station) or `worker` (user equipment), recorded in `meta.json`.
- **Workspace**: an isolated directory the worker edits and runs commands in.
- **Session**: an OpenCode session id. Every run resumes it, so the worker keeps its conversation.
- **State**: `~/.dsh/opencode-workers/<name>/` containing `meta.json`, `AGENTS.md`, `result.md`, `logs/`, `chats/`, and usually `workspace/`. Shared chatroom state lives at `~/.dsh/opencode-workers/.chatroom/`.

Each `run` or `chat send` invokes:

```sh
opencode run --format json --auto [--session <id>] -- <prompt>
```

The JSONL event stream is parsed after the run. The last assistant text is written to `result.md` and printed; the raw stream and stderr stay in `logs/`. Token usage and run metadata are recorded in `meta.json` and shown by `status`.

Three control layers bound delegation:

- **Chat budget**: multi-turn work runs in a chat with a hard turn limit and a local ledger of recipients, expected results, deadlines, and turn outcomes. Creating a chat requires user/admin approval; exhausted chats stop. `run` remains a one-off, unbudgeted escape hatch.
- **Chatroom limits**: a local server owns chat creation and turn execution, records every prompt and assistant result, and enforces a global open-chat count and total message count. Each turn consumes 2 messages; queue timeouts and failures still count. The server auto-starts on demand.
- **Global semaphore**: every `run` and `chat send` acquires a slot from a central queue under `<root>/.semaphore`, which limits total concurrency (default 3) and allows at most one active slot per worker. Priority (`high`, `normal`, `low`) orders the queue, so one worker cannot be focus-fired by concurrent chats.

`chat` and `room` commands are HTTP clients for the chatroom server; `run` stays local and shares the same file-based semaphore. A per-worker file lock is the last line of defence against two runs on the same worker. Logs accumulate under `logs/`; remove old files or destroy the worker when done.

The chatroom server binds only `127.0.0.1` on an ephemeral port. Every API request and the monitor page require a random bearer token stored in `<root>/.chatroom/server.json` with mode `0600`.

The server is started on demand: whoever calls `chat` or `room` first starts it. Before starting, the manager checks the process table and `<root>/.chatroom/server.pid` for a chatroom server that already belongs to this root; if one is running, the command fails with exit 4 and names the pid instead of starting a second server. `server status` lists every server process for the root (including ones that are no longer managed), and `server stop` refuses to kill a pid it cannot prove belongs to this root, so a stale `server.json` can never take down an unrelated process.

The port and the token are created per server run: after a restart, `server url --monitor` prints a new URL. A monitor tab that was left open from an earlier run gets `403` until it is reloaded with the current URL.

### Mobile-network model

The project is modeled as a small mobile network:

| Component | Network role | Responsibility |
|---|---|---|
| Caller (dsh or OpenCode) / user | Operator | Owns the root, approves chats, sets hard budgets, receives escalations. |
| Supervisor | Base station | Loop engineer: decomposes goals, assigns packages, tracks deadlines, re-plans, broadcasts, reports the final result. |
| Worker | User equipment | Owns one concrete assignment in its workspace; asks questions, reports completion, may DM peers. |
| Chat | Traffic channel | One worker, one session, a hard turn budget. |
| Broadcast | Paging channel | Supervisor → all workers; cost = one message per recipient. |
| DM | Dedicated channel | Supervisor ↔ worker or worker ↔ worker; cost = one message. |
| Inbox | Downlink queue | Unread coordination is injected into the worker's next turn. |
| Report / question | Uplink control | Report only when work is complete; question at any time. |

One root has exactly one supervisor. The supervisor may drive workers with `chat send` from inside its own turn; workers may only DM. Every turn and coordination message is charged to the room's `max_messages` budget.

### Roles and AGENTS.md

```sh
W=/path/to/opencode-worker-cell/scripts/opencode-worker

# One supervisor per root.
"$W" new lead --role supervisor --task "ship the release" --source ~/code/project

# Workers own concrete assignments.
"$W" new fix-auth --role worker --task "fix the auth tests" --source ~/code/project
"$W" new fix-ui   --role worker --task "repair the settings page" --source ~/code/project

# Preview or regenerate a role brief.
"$W" agents fix-auth
"$W" agents fix-auth --task "new assignment" --write
"$W" room set --supervisor lead --force   # promote/replace
```

Each worker gets a canonical `<root>/<worker>/AGENTS.md`:

- **Supervisor**: loop-engineer brief. Turn the goal into work packages, assign one owner per package, record expected result/deadline/progress checks, track the ledger, re-plan on reports or misses, escalate budget/scope/concurrency needs, and produce the final report.
- **Worker**: responsibility brief. Stay inside the assignment and workspace, verify the work, report only when completely finished or when blocked, and use `question` at any time.

The manager also maintains a marked block in `<workspace>/AGENTS.md` so OpenCode sees the role instructions in its working directory. Custom instructions can be supplied with `--agents-file FILE` and are stored as `<worker>/AGENTS.custom.md`.

#### Task-aware working loop

The brief template is fixed, the **working method** is not: it follows the kind of work, so a
worker fixing a bug is told to reproduce first and a worker writing tests is told to write the
failing test first. The profile is detected from `--task` and can be pinned with `--loop`.

| Profile | Picked for | The loop adds |
|---|---|---|
| `bugfix` | fix, bug, crash, failing, regression | reproduce first, name the root cause, add a test that fails before the fix |
| `feature` | implement, support, endpoint | acceptance criteria first, follow existing patterns, test the new path |
| `test` | test, spec, coverage, assertion | failing test first, cover the boundaries, keep the suite deterministic |
| `refactor` | refactor, extract, simplify, rename | behaviour baseline first, small steps, no drive-by changes |
| `perf` | performance, slow, optimize, latency | measure before and after, one change at a time, behaviour unchanged |
| `research` | investigate, analyze, compare, audit | turn it into questions, evidence first, separate fact from inference |
| `docs` | document, readme, changelog | the code wins over the docs, examples must run |
| `infra` | deploy, CI, pipeline, docker, release | reversible steps, reproduce first, rollback written down |
| `generic` | anything else | restate criteria, smallest change, run the checks |

```sh
"$W" new fix-auth --role worker --task "fix the auth tests"     # -> loop: bugfix
"$W" status fix-auth                                             # shows: loop: bugfix
"$W" new probe   --role worker --task "..." --loop research      # pin it
```

Each profile also carries its own **Definition of done**, so the worker knows when it may
report completion. The supervisor brief keeps the planning loop and gets a cell-level
definition of done (one owner per package, evidence checked by the supervisor, a final report
that lists what shipped and what is still open).

### Coordination channels

```sh
# Supervisor paging all workers (cost = number of active workers).
"$W" room broadcast --kind note --text "Standup: report blockers before 14:00."

# Dedicated message (cost 1).
"$W" room dm --to fix-auth --kind task --text "Also update the changelog."

# Worker uplink (inside a worker turn; sender comes from the environment).
"$W" room dm --to lead --kind question --text "Should I touch the migration?"
"$W" room dm --to lead --kind report   --text "Done: tests pass, diff committed."

# Read the downlink queue; chat send injects it automatically.
"$W" room inbox [--worker NAME] [--mark]

# Inspect the feed, including cost.
"$W" room log --scope dm --limit 50
```

Rules enforced by the server:

- Broadcast is supervisor-only. Workers that try it get exit 2.
- A worker may DM the supervisor only with `question` or `report`; it may DM another worker only with `note` or `question`.
- A supervisor may send `note`, `task`, or `question` to a worker, but not to itself.
- `report` is rejected with exit 4 while the worker has an open chat unless it has requested `chat close --defer`. The deferred close takes effect after the current turn succeeds; a failed turn drops it.
- Worker reports and questions land in the supervisor's own inbox. The supervisor reads them with `room inbox`, or a supervisor chat turn injects them automatically.
- Unread DMs/broadcasts are injected into the next `chat send` prompt as a `[Chatroom inbox: ...]` block, then the cursor advances. `--no-inbox` skips injection for one turn.
- Every coordination message costs its recipient count (broadcast to N = N; DM = 1). If the budget cannot cover the cost, the send exits 4 before recording anything.
- Supervisor delegation (`chat send` from inside the supervisor's turn) requires `max_concurrent >= 2`; with 1 it exits 4 to avoid deadlock.

### Architecture

```text
┌─────────────────────────────────────────────────────────────────────────┐
│           caller conversation (dsh or OpenCode)                         │
│   Loads this skill; delegates through bash calls to the manager script  │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ CLI (explicit NAME / CHAT)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                 opencode-worker manager (single Python CLI)             │
│                                                                         │
│  Local commands                    HTTP clients (Bearer token)          │
│  ├─ create/new, agents, run/send   ├─ chat start/send/status/list/close │
│  ├─ status/list/result/logs        ├─ room status/set/log               │
│  ├─ diff/commit/close/destroy      ├─ room broadcast/dm/inbox/alerts    │
│  ├─ semaphore status/set           └─ watch (out-of-band, no model)     │
│  ├─ server start/stop/restart/status/url/logs/serve                     │
│  └─ doctor                                                              │
└──────────────┬────────────────────────────────┬─────────────────────────┘
               │ direct execution               │ HTTP
               │ (one-off run)                  ▼
               │             ┌────────────────────────────────────────────┐
               │             │  Chatroom Server (one per worker root)     │
               │             │  127.0.0.1:<ephemeral>, token auth         │
               │             │                                            │
               │             │  API: health/status/limits/chats/turns/    │
               │             │       messages/inbox/supervisor/alerts/    │
               │             │       shutdown                             │
               │             │  Monitor: /?token=... (chatroom UI)        │
               │             │                                            │
               │             │  Responsibilities:                         │
               │             │  • create/close chats, approval + budget   │
               │             │  • reserve and record 2 messages per turn  │
               │             │  • broadcast/DM, inbox cursors, roles      │
               │             │  • global open-chat / message limits       │
               │             │  • budget/health alerts + notifications    │
               │             │  • restart recovery: interrupted + pairs   │
               │             └──────────────────┬─────────────────────────┘
               │                                │ child run (holder token)
               ▼                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│             Global semaphore (file lock, shared by all runs)            │
│   <root>/.semaphore/state.json                                          │
│   • max_concurrent default 3 (1–16)                                     │
│   • at most one active slot per worker                                  │
│   • queue: priority (high>normal>low) → worker queue length → arrival   │
│   • the chat server hands its holder token to the child run, so the     │
│     child does not re-acquire a slot                                    │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ slot granted
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                  Worker execution layer (isolated per worker)           │
│                                                                         │
│   <root>/<worker>/                                                      │
│   ├─ meta.json            role, task, supervisor, model, status         │
│   ├─ AGENTS.md            canonical role brief (supervisor/worker)      │
│   ├─ AGENTS.custom.md     optional custom instructions                  │
│   ├─ workspace/           isolated workspace (worktree/copy/empty)      │
│   ├─ logs/*.jsonl         OpenCode event stream                         │
│   ├─ result.md            last result                                   │
│   └─ chats/<chat-id>.json turn ledger: deadline, result, approval       │
│                                                                         │
│   Command: opencode run --format json --auto [--session SES] -- PROMPT  │
│   Model:   opencode/deepseek-v4.1-flash-free (free, no API key)         │
└─────────────────────────────────────────────────────────────────────────┘

Shared state (per root):
<root>/.chatroom/
├─ state.json         limits, usage, supervisor, inbox cursors, alert state
├─ messages.jsonl     every chat + coordination message (JSONL)
├─ notifications.jsonl new budget/health alerts (JSONL)
├─ server.json        pid / host / port / token (0600)
├─ server.pid         pid + start time of the running server (0600)
├─ server.log         request and server log (0600)
└─ *.lock             room / startup locks

Isolation rules:
• Chat lock: one turn per chat at a time; a concurrent send exits 4 without
  consuming a turn.
• Worker lock: OpenCode processes for one worker run serially.
• Nesting guard: inside a worker (DSH_OPENCODE_WORKER_DEPTH > 0),
  create/run/chat start/close/destroy/semaphore set/room set/broadcast/
  server lifecycle commands refuse to run. A supervisor may call chat send
  and coordinate; workers may only DM. DSH_OPENCODE_ALLOW_NESTED=1 is a
  deliberate override.
```

One `chat send` turn:

```text
dsh, OpenCode, or supervisor ──▶ chat send ──HTTP──▶ Server
                              ├─ validate chat state, turn budget, caller role
                              │  (approval was recorded at creation)
                              ├─ require at least 2 messages remaining
                              ├─ reserve 2 messages, record the user prompt
                              ├─ acquire a semaphore slot (may queue;
                              │  queue timeout still consumes the turn)
                              ├─ inject unread inbox messages, advance cursor
                              ├─ spawn child run with the holder token
                              │    ├─ skip duplicate acquisition
                              │    ├─ take the worker lock
                              │    └─ opencode run ... → JSON
                              ├─ record the assistant result
                              ├─ apply a pending deferred close on success
                              └─ return result / remaining turns / messages
caller ◀── final answer plus ledger summary only ──┘
```

Boundaries: `run` stays local but uses the same global semaphore; `chat` and `room` go through the server, so chat content, turns, and messages are accounted centrally. The OpenCode child only receives its workspace and prompt; it does not participate in orchestration.

## Models and cost

Workers invoke `opencode run` directly and never read the caller's model or credentials. The default model is `opencode/deepseek-v4.1-flash-free`, a free OpenCode Zen model with cost 0 and no API key.

List available models and pin one per worker or per run:

```sh
opencode-worker doctor --models
opencode-worker new demo --mode empty --model opencode/deepseek-v4.1-flash-free
opencode-worker run demo --model opencode/glm-5.3-flash-free "..."
```

Any `opencode/*-free` model uses the free quota. If the default changes or a paid provider is added later, pin a free model explicitly to avoid spend.

## Quick start

```sh
W=/path/to/opencode-worker-cell/scripts/opencode-worker

# 1. Create a supervisor (base station) and workers (user equipment) from a git repository.
"$W" new lead --role supervisor --task "ship the release" --source ~/code/my-project
"$W" new fix-auth --role worker --task "fix the auth tests" --source ~/code/my-project

# 2. Query the worker and its session.
"$W" status fix-auth --json
"$W" session fix-auth

# 3. Create an approved chat with a hard turn budget.
"$W" chat start --worker fix-auth --max-turns 6 --priority high \
  --approved-by user --note "fix auth tests"
# prints: chat: chat-20261108T...

# The chatroom server auto-starts. Inspect room limits and open the monitor.
"$W" room status
"$W" server url --monitor

# 4. Send one turn; record the expected result and deadline.
"$W" chat send --chat chat-20261108T... \
  --expect "auth tests pass" --expect-within 600 \
  --prompt-file - <<'EOF'
Objective: fix the failing auth tests.
Context: the failures are in tests/auth; the token expiry logic is in src/auth/token.ts.
Verification: run `pytest tests/auth -q` and report the result.
Report back: changed files, test output summary, and remaining risks.
EOF

# Follow-up in the same chat and session.
"$W" chat send --chat chat-20261108T... --prompt "Add a regression test for the expired-token path."

# Inspect the local ledger, including deadlines and remaining turns.
"$W" chat status --chat chat-20261108T...
"$W" chat list --open

# One-off shorthand: run NAME TASK... auto-creates and resumes.
"$W" run fix-auth "Also update the changelog."

# Optionally tune the room-wide limits (0 = unlimited).
"$W" room set --max-open-chats 20 --max-messages 2000

# Close the chat when the work is done; this frees its open-chat slot.
"$W" chat close --chat chat-20261108T...

# Supervisor coordination is cost-accounted and recorded in the same room budget.
"$W" room broadcast --from lead --kind note --text "Report blockers before 14:00."
"$W" room dm --from lead --to fix-auth --kind task --text "Also update the changelog."
"$W" room alerts

# Review and merge.
"$W" diff fix-auth --stat
"$W" diff fix-auth --patch
"$W" commit fix-auth -m "fix auth token expiry"
git -C ~/code/my-project merge opencode/fix-auth

# Clean up. The branch is kept.
"$W" destroy fix-auth
```

## Workspace modes

| Mode | Behavior |
|---|---|
| `auto` (default) | Uses `worktree` when the source is a git repository with a commit; otherwise `copy`. |
| `worktree` | `git worktree add -b opencode/<name> <workspace> <base>`. Starts from `HEAD` or `--base`; uncommitted source changes are excluded. |
| `copy` | Copies the source, skipping `.git`, `node_modules`, virtualenvs, caches, and build output. Initializes a git baseline so `diff` and `commit` work. `--copy-all` disables filtering. |
| `empty` | Empty workspace for research or scratch work. |

The source defaults to the current directory. For a git worktree, the worker's changes live on a real branch in the source repository. For a copy, the workspace has its own baseline commit.

## Commands

### `doctor`

```sh
opencode-worker doctor [--models] [--json]
```

Checks the OpenCode binary and version, Python, git, the worker root, the default model, the global semaphore, and whether the current directory is a git repository. `--models` also lists available OpenCode models. Exits non-zero if OpenCode, git, or the root is unavailable. It does not call a model; the default model is free, so no API key is required.

### `session`

```sh
opencode-worker session NAME [--json]
```

Prints the worker's OpenCode session id, or `-` if it has none yet. `--json` returns `{worker, session, status, workspace}`.

### `chat` (budgeted conversations)

A chat is the unit of cost control for multi-turn delegation. It belongs to one worker, has a hard turn budget, and keeps a local ledger of every turn, including the expected result and deadline. Chat creation, turn execution, and the ledger are owned by the local chatroom server; these commands start it automatically when needed.

```sh
opencode-worker chat start --worker NAME --approved-by user|admin [options]
opencode-worker chat send --chat ID [options]
opencode-worker chat status --chat ID [--json]
opencode-worker chat list [--worker NAME] [--open] [--overdue] [--json]
opencode-worker chat close --chat ID [--defer]
```

#### `chat start`

| Option | Description |
|---|---|
| `--worker NAME` | Worker that will receive the chat (required; must already exist). |
| `--approved-by user\|admin` | Who approved this chat (required). Stored with `approved_at`. |
| `--max-turns N` | Turn budget, 1–50 (default 10). |
| `--priority high\|normal\|low` | Queue priority (default `normal`). |
| `--session ID` | Link the chat to an existing OpenCode session. |
| `--note TEXT` | Approval note stored in the ledger. |
| `--json` | Print the full chat record. |

New chats are stored at `<worker>/chats/<chat-id>.json`; the id is only created by this approved command. Creation is refused when the room's `max_open_chats` is reached. There is no implicit current chat or current worker: pass `--worker` and `--chat` explicitly.

#### `chat send`

| Option | Description |
|---|---|
| `--chat ID` | Chat to use (required). |
| `--prompt TEXT` | Task text. |
| `--prompt-file FILE\|-` | Read the task from a file or stdin; cannot be combined with `--prompt`. |
| `--is-new-session true\|false` | `true` starts a fresh session; only valid on the first turn and not with a linked session. |
| `--expect TEXT` | What result you expect; recorded in the ledger. |
| `--expect-within SEC` | Deadline for the expected result; overdue work is flagged. |
| `--priority high\|normal\|low` | Override the chat priority for this turn. |
| `--queue-timeout SEC` | Wait for a global semaphore slot (default 300; `0` fails fast). |
| `--timeout SEC` | Hard kill the OpenCode process after N seconds. |
| `--wait` | Wait for the worker lock instead of failing when busy. |
| `--no-inbox` | Do not inject unread coordination messages into this turn. |
| `--max-chars N` | Truncate the printed result; the full text stays in `result.md`. |
| `--json` | Include chat id, turn number, remaining budget, session, result, tokens, inbox count, and errors. |

A chat runs one turn at a time; a concurrent send to the same chat exits 4 without consuming a turn. Each `chat send` consumes one turn **before** execution. Failed, timed-out, and queue-timed-out turns still count. When the budget is exhausted the chat is marked `exhausted` and further sends exit 4. To continue the same OpenCode session, ask the user/admin to approve a new chat with `--session <id>`; do not bypass the budget.

**Who may send**: the calling agent/admin may send to any chat. The supervisor may send to a worker's chat from inside its own turn (this is how the base station drives user equipment) and must have `max_concurrent >= 2`. A worker cannot send chat turns; it communicates through `room dm`.

Each accepted turn also reserves and records **2 messages** in the room log: the user prompt and the assistant result. Queue-timeout, failed, and interrupted turns still consume those 2 messages. If fewer than 2 messages remain under `max_messages`, the send exits 4 before consuming a turn. See [`room`](#room) for the room-wide limits.

Before the turn runs, the server injects unread DMs/broadcasts for the worker as a `[Chatroom inbox: ...]` block, advances the worker's inbox cursor, and records `inbox_count`/`inbox_seqs` in the turn. The original prompt remains in the log.

Session precedence:

- `--is-new-session true` starts fresh and is only valid on the first turn of a chat with no linked session.
- `false` (default) resumes the chat's linked session.
- A chat without a session starts fresh on its first turn; the resulting session id is stored in the chat.
- A new chat with `--session SES` resumes that session from its first turn.

`chat status` shows the budget, priority, semaphore position, approval, and per-turn deadlines. `chat list` is the cross-worker ledger and flags `OVERDUE` work; `--overdue` narrows it to work whose deadline has passed. Use them instead of repeatedly polling the worker.

`chat close --defer` requests completion from inside a running turn. The server closes the chat after that turn succeeds, which lets the worker send its `report` immediately. A failed turn drops the deferred close and leaves the chat open. `chat close` without `--defer` refuses while the chat is busy (exit 4). Because a finished worker closes its own chat, follow-up work needs a new approved chat that links the same session: `chat start --worker NAME --session <session-id>`.

### `room`

```sh
opencode-worker room status [--json]
opencode-worker room set [--max-open-chats N] [--max-messages N] \
  [--supervisor NAME] [--clear-supervisor] [--force] [--json]
opencode-worker room broadcast [--from NAME] --kind K --text T
opencode-worker room dm --to NAME [--from NAME] --kind K --text T
opencode-worker room inbox [--worker NAME] [--mark] [--limit N] [--json]
opencode-worker room alerts [--fail-on-alert] [--limit N] [--json]
opencode-worker room log [--chat ID] [--worker NAME] [--scope SCOPE] \
  [--from NAME] [--to NAME] [--kind K] [--since SEQ] [--limit N] [--max-chars N] [--json]
```

The room is shared by every worker under the same root. Limits live in `<root>/.chatroom/state.json`:

| Limit | Default | Meaning |
|---|---|---|
| `max_open_chats` | 10 | Chats whose status is `open`; `0` = unlimited. Exhausted and closed chats free slots. |
| `max_messages` | 500 | Total chat + coordination messages; `0` = unlimited. |

Each accepted turn records 2 messages. A broadcast to N workers records N messages; a DM records 1. Queue-timeout, failed, and interrupted turns still consume their 2 messages and one turn. A send is rejected **before** consuming a turn when fewer than 2 messages remain; coordination is rejected if its cost cannot be covered. Lowering a limit below current usage is allowed; it blocks new chats/turns until usage drops or the limit is raised.

`room set --supervisor NAME` promotes a worker to supervisor and demotes the previous one; `--clear-supervisor` removes the role. Exactly one supervisor per root is the intended topology. The monitor page shows roles, supervisor, channels, and alerts, and provides send/close/limit/supervisor/broadcast/DM controls.

`room log` reads `messages.jsonl`; use `--since SEQ` for incremental reads, `--scope broadcast|dm|chat` to filter the channel, and `--max-chars 0` for full text.

### Alerts and watchdog

Budget and health alerts are computed by the manager, not by a model, so they still work when the model quota is exhausted:

| Code | Level | Trigger |
|---|---|---|
| `messages_low` | warning | 80% of `max_messages` used. |
| `messages_exhausted` | critical | 0 messages left. |
| `open_chats_high` | warning | 80% of `max_open_chats` used. |
| `open_chats_exhausted` | critical | Open-chat limit reached. |
| `turns_overdue` | warning | Any turn past its `--expect-within` deadline. |
| `queue_backlog` | warning | Waiters ≥ `max(3, 2 × max_concurrent)`. |
| `no_supervisor` / `multiple_supervisors` | warning | Role topology is wrong. |
| `model_quota_exhausted` | critical | The model provider refused a recent turn (free-tier, quota, or rate limit). |
| `server_down` | critical | Chatroom server unreachable while open chats, active turns, or server metadata exist. |

```sh
opencode-worker room alerts
opencode-worker room alerts --fail-on-alert   # exit 4 if anything is active
opencode-worker watch --once --verbose
opencode-worker watch --interval 30 --notify-command 'notify-send "chatroom" "$(cat)"'
```

New alerts are appended to `<root>/.chatroom/notifications.jsonl` with a 5-minute dedupe window, exposed at `GET /api/alerts`, included in `/api/status`, and shown as a banner on the monitor page. `watch` is an optional out-of-band process: it only observes the base station/chatroom (budget, queue, overdue turns, server health) and never schedules work. The supervisor may run `room alerts` inside its own turn; workers may not. The supervisor handles semantic escalation only when budget remains; the hard stop is always enforced by the server.

### `server`

```sh
opencode-worker server status [--json]
opencode-worker server start [--port N] [--json]
opencode-worker server stop [--force] [--json]
opencode-worker server restart [--port N] [--force] [--json]
opencode-worker server url [--monitor]
opencode-worker server logs [--tail N]
opencode-worker server serve [--port N]   # foreground, mainly for debugging
```

The server binds `127.0.0.1` on an ephemeral port (or `--port`) and authenticates every API request with a bearer token. `chat` and `room` auto-start it, so no manual step is needed. `server url --monitor` prints a tokenized URL for the browser monitor.

State under `<root>/.chatroom/`:

- `state.json` — room limits, message usage, supervisor, inbox cursors, alert dedupe state, and sequence counter.
- `messages.jsonl` — all recorded chat and coordination messages, one JSON object per line.
- `notifications.jsonl` — budget/health alerts, one JSON object per line.
- `server.json` — pid, host, port, and token for the running server.
- `server.log` — request log and server errors.

`server stop` and `server restart` refuse while a turn is queued or running unless `--force`. On restart, turns left `queued` or `running` are marked `interrupted`, and missing message pairs are completed in the log. The server is loopback-only; do not expose its port or token.

### `semaphore`

```sh
opencode-worker semaphore status [--json]
opencode-worker semaphore set --max-concurrent N [--json]
```

All `run` and `chat send` executions acquire a slot from the central semaphore at `<root>/.semaphore/state.json`. Every process using the same worker root shares this queue, so multiple caller sessions (dsh or OpenCode) coordinate automatically.

- Global concurrency default **3**; `set --max-concurrent` accepts 1–16. Lowering the limit does not preempt active holders.
- At most **one active slot per worker**, so concurrent chats cannot focus-fire the same worker.
- Queue order: priority (`high` > `normal` > `low`), then the worker with fewer queued chats, then arrival order.
- `status` lists active holders and the waiting queue with worker, chat id, priority, pid, and timestamps.

Slots held by dead processes are cleaned up automatically on the next acquire or status check.

### Nesting and supervisor delegation

Workers are started with `DSH_OPENCODE_WORKER_DEPTH=<parent+1>`. `create`/`new`, `run`/`send`, `chat start`, `chat close`, `destroy`, `semaphore set`, `room set`, `room broadcast`, and `server start|stop|restart` refuse to run at depth > 0, so a worker cannot create or drive other workers. The chatroom server's child `run` also executes at depth+1, so even a manually started server cannot delegate from inside a worker.

The one deliberate exception is the **supervisor** role. A supervisor may call `chat send` to drive its workers from inside its own turn (the server checks the `X-Worker-Name` header and role), and it may broadcast. This needs `max_concurrent >= 2`; with 1 the send exits 4 to avoid a semaphore deadlock. Regular workers may only DM. The calling agent remains the outer orchestrator. Setting `DSH_OPENCODE_ALLOW_NESTED=1` disables the guard for a deliberate lead-worker setup; use it only with explicit user approval and tight limits.

### `create` / `new`

```sh
opencode-worker create NAME [options]
opencode-worker new NAME [options]
```

`new` is an alias for `create`. The worker name is required and must be lowercase kebab-case.

| Option | Description |
|---|---|
| `--source DIR` | Source directory (default: cwd). |
| `--mode auto\|worktree\|copy\|empty` | Workspace mode. |
| `--base REF` | Git base ref for worktree mode (default: `HEAD`). |
| `--branch NAME` | Explicit branch name for worktree mode. |
| `--workspace PATH` | Explicit workspace path instead of the default. |
| `--role supervisor\|worker` | Network role (default `worker`). One supervisor per root. |
| `--task TEXT` | Short assignment recorded in `meta.json` and `AGENTS.md`. |
| `--loop PROFILE` | Working loop written into `AGENTS.md` (default: `auto`, detected from the task text). |
| `--agents-file FILE` | Role-specific instructions copied to `<worker>/AGENTS.custom.md`. |
| `--model PROVIDER/MODEL` | OpenCode model stored on the worker. Default: `opencode/deepseek-v4.1-flash-free`. |
| `--agent NAME` | OpenCode agent (default: `build`). |
| `--copy-all` | Copy mode: do not skip caches or build output. |
| `--force` | Allow copying the home directory or reusing a non-empty empty-mode workspace. |
| `--json`, `--quiet` | Machine-readable or silent output. |

Worker names are lowercase kebab-case.

### `agents`

```sh
opencode-worker agents NAME [--task TEXT] [--agents-file FILE] [--write] [--json]
```

Prints the role-specific `AGENTS.md` for a worker. With `--write`, regenerates `<worker>/AGENTS.md` and the managed block in `<workspace>/AGENTS.md`; `--task` updates the assignment first, `--loop` pins the working loop, and `--agents-file` replaces `<worker>/AGENTS.custom.md`. `new` and `room set --supervisor` call the same renderer automatically, so role changes keep every brief consistent.

### `run` / `send`

```sh
opencode-worker run NAME [TASK...] [options]
```

| Option | Description |
|---|---|
| `TASK...` | Task text. `-` reads stdin. |
| `--prompt-file FILE\|-` | Read the task from a file or stdin; cannot be combined with `TASK`. |
| `--timeout SECONDS` | Kill the OpenCode process group after N seconds (default: no timeout). |
| `--max-chars N` | Truncate the printed result; the full text stays in `result.md`. |
| `--session ID` | Resume this exact OpenCode session. |
| `--new-session` | Start a fresh session in the same workspace. |
| `--wait` | Wait for the worker lock instead of failing when busy. |
| `--priority high\|normal\|low` | Semaphore queue priority (default `normal`). |
| `--queue-timeout SEC` | Wait for a semaphore slot (default 300; `0` fails fast). |
| `--source DIR`, `--mode MODE` | Settings used when auto-creating a missing worker. |
| `--model`, `--agent` | Per-run overrides. `--model` falls back to the worker's stored model, then the default. |
| `--standalone` | Use a private OpenCode server for this run. |
| `--no-create` | Fail if the worker does not exist. |
| `--json` | Include worker, session, is_new_session, result, status, tokens, errors, and log path in JSON output. |
| `--include-stderr` | Include the stderr tail in `--json` output. |

If the worker does not exist and `--no-create` is absent, it is created from the current directory (or `--source`) with `--mode auto` (or the given `--mode`).

Exit codes: `0` success, `1` unexpected failure, `2` invalid request or failed precondition, `3` missing worker/workspace, `4` busy or unsafe state, `124` timeout, `127` OpenCode executable not found, otherwise OpenCode's exit code.

### `status`, `list`, `result`

```sh
opencode-worker status NAME [--json]
opencode-worker list [--all] [--json]
opencode-worker result NAME [--json]
```

`status` is the worker query command: it shows state, session id, workspace, run count, last run duration and token counts, and the result path. `status --json` includes both the stored `name`/`session_id` fields and the fixed `worker`/`session` aliases. `list` hides closed workers unless `--all` is passed. `result` prints the last full result.

### `logs`

```sh
opencode-worker logs NAME [--tail N] [--stderr]
```

Reads the newest raw OpenCode JSONL stream, or its stderr with `--stderr`. Use only for debugging; normal operation does not need it.

### `diff`

```sh
opencode-worker diff NAME [--stat|--name-only|--patch]
```

Compares the workspace against its baseline commit. Untracked files are included. Without flags it prints `git status --short`, a diffstat, and untracked paths. Diff and commit follow git's ignore rules, so files ignored by `.gitignore` are not shown or committed.

### `commit`

```sh
opencode-worker commit NAME -m "message"
```

Stages and commits everything in the workspace. Commits use the identity `OpenCode Worker <opencode-worker@localhost>` and do not change global git config.

### `close` and `destroy`

```sh
opencode-worker close NAME
opencode-worker destroy NAME [--force] [--delete-session]
```

`close` marks a worker closed but keeps its workspace, session, and logs; a closed worker can still be resumed with `run` and reappears in `list` after the next run. `destroy` removes the state directory and, in worktree mode, removes the worktree. It refuses a live run, refuses a dirty worktree without `--force`, and refuses to remove a workspace containing the current directory. The branch is always kept. `--delete-session` also deletes the OpenCode session. A workspace explicitly placed outside the worker directory with `--workspace` is kept for copy and empty modes; remove it manually.

## Merging changes

**Worktree mode** produces a normal branch in the source repository:

```sh
opencode-worker commit NAME -m "message"
git -C /path/to/repo merge opencode/NAME
```

The branch survives `destroy`, so you can merge later. If the base branch moved, merge or rebase as usual.

**Copy mode** produces a patch:

```sh
opencode-worker diff NAME --patch > /tmp/NAME.patch
git -C /path/to/project apply /tmp/NAME.patch
```

Review the patch first; paths are relative to the workspace root.

**Empty mode** has no source to merge into. Copy files out of the workspace path shown by `status`.

## Token and context discipline

- The command prints only the last assistant text. JSONL events, stderr, and token usage stay on disk.
- `--max-chars` bounds what enters the caller's context; `result.md` keeps the full text.
- `status --json` exposes token counts for the last run.
- Ask workers for summaries and file paths, not pasted files or full logs.

## Long-running tasks

The dsh bash tool defaults to a 120-second timeout and caps foreground calls at 600 seconds; OpenCode's shell tool has its own timeout. Run long delegations as background jobs and collect them with the caller's job tool (dsh: `run_in_background: true` + `job_output`).

The script's `--timeout` is a separate safety kill for the OpenCode process. Prefer background jobs and leave `--timeout` unset for long tasks. A timeout kills the client, not necessarily the OpenCode server's in-flight turn, so the next resume can include output from that turn; treat a timed-out run as uncertain and inspect the workspace before trusting the result.

## Safety

Workers run with `opencode run --auto`, so file edits and shell commands execute without approval prompts. The workspace isolates the worker's default context, not the machine: absolute paths, the network, and user-level credentials remain reachable. Delegate only trusted tasks, avoid unnecessary secrets in briefs, and review `diff --patch` before merging. Copy mode copies the source tree, including files ignored by git such as `.env`; worktree mode starts from committed content only.

The chatroom server is loopback-only and token-protected; `server.json` contains the token with mode `0600`. Do not expose the port or token. `server stop --force` and `server restart --force` interrupt active turns and may orphan an OpenCode child if the process is killed abruptly; use them only with explicit approval.

## Environment variables

| Variable | Effect |
|---|---|
| `DSH_OPENCODE_WORKERS` | Worker root. |
| `OPENCODE_BIN` | OpenCode executable. |
| `DSH_HOME` | Base for the default root `$DSH_HOME/opencode-workers`. |
| `--root PATH` | Per-command root override, useful for tests. |
| `DSH_OPENCODE_WORKER_DEPTH` | Nesting depth set by the manager for each worker; normally not set by hand. |
| `DSH_OPENCODE_WORKER_NAME` | Worker name injected into a worker's OpenCode environment. |
| `DSH_OPENCODE_WORKER_ROLE` | `supervisor` or `worker`, injected by the manager. |
| `DSH_OPENCODE_WORKER_ROOT` | Worker root, injected for `room` calls from inside a worker. |
| `DSH_OPENCODE_SUPERVISOR` | Supervisor name for the current worker, if any. |
| `DSH_OPENCODE_CHAT_ID` | Chat id for the current server-driven turn. |
| `DSH_OPENCODE_ALLOW_NESTED` | `1` disables the worker-to-worker delegation guard; use only for a deliberate lead-worker setup. |

Default root: `~/.dsh/opencode-workers`. Shared chatroom state is stored under `<root>/.chatroom/`; it is per root, not per worker.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `opencode executable not found` | Install OpenCode or set `OPENCODE_BIN`; run `doctor`. |
| `worker ... already exists` | Use another name or `destroy` the old worker. |
| `worker ... is busy` | Wait, pass `--wait`, or use another worker. |
| `chat ... quota exhausted` | Ask the user/admin to approve a new chat with `--session <id>`; do not bypass the budget. |
| `chatroom open-chat limit reached` | Close finished chats or raise `room set --max-open-chats`; do not bypass. |
| `chatroom message limit reached` | Raise `room set --max-messages`, or stop and report; do not delete the log to bypass. |
| `report requires no open chat` | Finish the work, run `chat close --chat ID --defer`, then send the report. |
| `workers cannot broadcast` | Use `room dm --to NAME`; only the supervisor broadcasts. |
| `supervisor delegation needs max_concurrent >= 2` | Ask the user/admin to run `semaphore set --max-concurrent 2`. |
| `chatroom message budget low/exhausted` | Run `room alerts`; ask the user/admin to raise `--max-messages` or approve a new chat; do not bypass. |
| `disabled inside an OpenCode worker` | Worker-to-worker delegation is off. Only the supervisor may `chat send`; workers use `room dm`. The calling agent remains the outer orchestrator. |
| `chatroom server unreachable` | Run `server status` and `server logs`; `server restart --force` interrupts active turns, so ask first. |
| `server has N active turn(s)` | Wait for the turn, or use `--force` with explicit approval. |
| Monitor returns 401 | Use the tokenized URL from `server url --monitor`; the token changes when the server restarts. |
| `timed out ... semaphore slot` | Check `semaphore status`; wait, raise `--queue-timeout`, or use another worker. |
| Status `interrupted` | The runner died or was killed. Run again to resume the session and workspace. |
| `session id not found` | The next run starts a new session in the same workspace. |
| OpenCode auth or provider error | Retry with a free model via `--model opencode/<name>-free`; otherwise fix OpenCode configuration. |
| Dirty worktree on destroy | Commit inside the worker or pass `--force`. |
| Worker is running on destroy | Stop the run first; `--force` does not destroy a live worker. |
| Worker appears hung | Stop the background job, or kill the runner pid from `status --json`; use `--timeout` as a safety net. |

## Testing

```sh
cd tests
./run.sh                              # deterministic suite + real-model suite
./e2e-full.sh                        # 110 checks, no model cost
MODEL=opencode/deepseek-v4.1-flash-free ./e2e-real.sh   # 26 checks
```

The deterministic suite uses a fake OpenCode CLI (`tests/fake-opencode`) and an isolated root,
so it needs no model and never touches the default worker root. When the model provider
refuses a request (free quota exhausted), the real-model suite reports `SKIPPED` (exit 77)
instead of failing.
## Uninstall

```sh
rm -rf ~/.config/opencode/skills/opencode-worker-cell   # OpenCode
rm -rf ~/.dsh/skills/opencode-worker-cell                # dsh
rm -rf ~/.dsh/opencode-workers                           # all worker state (default worktrees are removed; branches remain)
```
