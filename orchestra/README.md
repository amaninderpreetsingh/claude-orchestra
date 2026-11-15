# Orchestra — how to use it

## Everyday use
In any repo, open a cmux chat (`claude` in the repo) and type `/new-task <task>`. A tiny change (≤~30 lines, ≤3 files, not risky) takes the fast path: one confirmation, an edit on a branch in the main checkout, gates, one fresh reviewer, push. Everything else becomes a plan run by the manager (`orchestrate`). `/orchestrate <task>` goes straight to a plan; `/orchestrate --resume <run>` continues a run from its `runs/<run>/HANDOFF.md`.

1. **Interview** — a subagent reads the code first; then ranked questions with a recommended answer each ("yes" accepts), better ideas suggested, every decision logged.
2. **Plan** — EARS acceptance criteria, small file-owned tasks in waves, risky marks, the merge policy (`auto` by default, or `manual`), deploy impact. You approve or change. Then `orch run-branch` creates the feature branch `orch/<run>`.
3. **Workers** — up to 3 at once, each its own cmux workspace in the manager's sidebar group (next to a live dashboard workspace), each a `claude -w` worktree with its own 10-port block (`$ORCH_PORT..$ORCH_PORT_END`). Each one rebases onto the feature branch, does its task tests first, runs the gates, then **review rounds** (`skills/worker/SKILL.md` §4): a fresh `reviewer` + `/code-review medium` each round (+ an adversarial reviewer on risky tasks), fixing every blocking finding until a round is clean; the same finding twice in a row or 4 rounds still blocking → `BLOCKED` to the manager. Then it re-checks the feature branch, proves its criteria with the `verifier` (tests, Playwright), writes its evidence file and reports `READY`. Workers never push.
4. **Merges** — the manager checks the evidence and runs `orch merge`: auto, unless the task is risky or the policy is manual, which wait for your OK. It pushes the feature branch after every merge (CI runs on it, non-blocking) and tells the other workers to rebase. A merged worker's workspace is closed (`orch close`).
5. **Updates when something happens** — worker messages, `orch-watch` events (dead, stalled ≥15 min, usage limit hit/resumed), or a 30-min heartbeat (also on demand: ask "status"). After a usage-limit reset `orch-watch` types `continue` into paused workers; the heartbeat wakes the manager. `caffeinate` keeps the Mac awake while a run is active. You get a notification only for a NEEDS YOU item.
6. **Final check and ship** — once every task is merged: a fresh reviewer on the whole feature diff, a verifier over every criterion, the gates vs the baseline, green CI on the branch head; then `orch ship` fast-forwards main. Final report: what shipped, what deployed, evidence, what wasn't exercised. Workers' `## Learned` notes are folded into the repo's project memory and checked with `memory-lint`.

## New app
Make an empty folder for the app and `cd` into it (e.g. `mkdir -p ~/code && mkdir ~/code/<name> && cd ~/code/<name>`; the second `mkdir` fails if the folder already exists), run `claude` (accept the trust prompt), describe the app. It asks name, private/public and stack, creates the GitHub repo, builds a scaffold task first (typecheck, lint, tests, build, Playwright, repo `CLAUDE.md`), then the features on top.

## End-to-end test on a throwaway repo (nothing leaves your Mac)
```
~/.claude/orchestra/bin/make-demo-repo          # creates ~/orchestra-demo/app + opens it in cmux
~/.claude/orchestra/bin/make-demo-repo --no-launch [dir]   # only creates the repo (tests, verifiers)
```
Accept the folder-trust prompt once, then paste the suggested `/orchestrate …` task. Delete `~/orchestra-demo` afterwards.

## Commands
You might type:

| Command | What |
|---|---|
| `orch status` | all active runs + workers |
| `orch report --run <run>` | the status table, now |
| `orch dash --run <run> [--open]` | the live dashboard (`--open` reopens its workspace) |
| `orch-watch --run <run> [--once] [--timeout S]` | wait for the next `EVENT <kind> <slice> <detail>` (exit 3 = none) |
| `orch doctor --run <run> [--fix]` | dead workers, orphan locks (+ respawn command) |
| `orch locks --repo <path>` | who owns which files |
| `orch criteria-check --run <run>` | acceptance criteria status |
| `orch reap [--run <run>] [--dry-run]` | kill/clean anything finished or dead still using memory (runs on every manager wake) |
| `orch gc [--ended-older-than 14d] [--dry-run]` | runs that ended long ago keep only spec, HANDOFF, criteria, plan, run.json and the `feature` dir; the rest (artifacts, logs, watch state) is deleted |
| `memory-lint <memory dir>` | check a project memory dir (frontmatter, index, dups) |
| `orch end-run --run <run> --status aborted` | abandon a run — tears down all its workspaces, processes, worktrees |

The manager runs:

| Command | What |
|---|---|
| `orch new-run --repo <root> --title "<short>"` | create a run (records the manager's cmux surface, holds `caffeinate`) |
| `orch baseline --run <run> --setup "<setup>" --cmd "<gate>" …` | every gate twice on the default branch; flags FLAKY |
| `orch note --run <run> --plan <file>` | set `plan.json` (`{"merge_policy":"auto"\|"manual","tasks":[…]}`; a bare task list = auto, risky only where a task says so) |
| `orch note --run <run> --wait "<line>"` / `--done <n\|all>` | add / clear a NEEDS YOU item (adding one sends one notification) |
| `orch note --run <run> --finish <n>` / `--next-tick <HH:MM>` | the dashboard's finish step / next heartbeat |
| `orch criteria-init` / `criteria-add --run <run> --file <f>` | record the acceptance criteria |
| `orch run-branch --run <run>` | create `orch/<run>` from `origin/<default>`, the feature worktree `runs/<run>/feature`, push the branch |
| `orch lock --repo <root> --owner <o> <files…>` / `unlock` | file locks for a task's Touches |
| `orch spawn --run <run> --slice <id> [--resume] [--all-mcp] [--dry-run]` | open a worker workspace; `--all-mcp` gives it every MCP server instead of only `worker-mcp.json`'s, `--dry-run` prints what it would run |
| `orch merge --run <run> --slice <id> --sha <sha> [--user-ok]` | merge a READY task into `orch/<run>` (exit 0 merged + pushed; 2 not a fast-forward; 3 needs your OK — a risky task, a manual plan, or a task not in `plan.json` — adds the NEEDS YOU item for that sha; 4 evidence missing or stale; 1 anything else, e.g. a dirty feature worktree). `--user-ok` merges only while that sha's item is open, and clears it. On a non-zero exit no branch, lock or merge record changes (exit 3 only adds its item; one rare push-error case says what to check — see docs/how-it-works.md) |
| `orch broadcast --run <run> "<text>"` | message every active worker (e.g. `REBASE:`) |
| `orch close --run <run> --slice <id> [--status <s>]` | close a worker workspace + worktree, free its locks/ports |
| `orch ship --run <run>` | fast-forward `<default>` to `orch/<run>` and delete the remote feature branch (exit 2 a task unmerged; 3 conflict, nothing pushed; 4 rebased onto a moved `<default>` — re-run the final tests on that sha, green → ship again (no branch CI for it; CI on main covers it), red → your decision, never a fix task; 1 `origin/orch/<run>` holds commits the head lacks, or another failure, nothing pushed) |
| `orch ports --run <run> --name <n>` | a port block for a final-check agent |

Workers run one: `orch register --run <run> --slice <id> --sync` (registers the worktree and points it at `origin/orch/<run>`).

State: `~/.claude/orchestra/runs/<run>/` (spec, plan, criteria, briefs, progress and evidence files, artifacts/screenshots, the feature worktree).

## Guarantees (enforced by `hooks/push-guard.py`, not by prompts)
A guard-rail against accidents, not a sandbox: it scans the command text (no shell parser), it knows a worker by the directory a command runs in (a worker that `cd`s out of its worktree isn't one to it), and a script written then run, a verb in a variable or an alias gets past it. Three rules:
- **Nobody force-pushes**: `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, `--mirror`, a `+` refspec — inside workers and out. Delete pushes are allowed outside workers.
- **A registered worker runs no `git push`** at all; the manager merges and pushes.
- **A worker's cmux** is only `agent message` to its own manager (or `--reply-to <id>`), `identify` and `read-screen` of its own surface; it can't message other workers or drive other terminals.

It never approves anything: what it doesn't deny gets no decision, so your own permission rules decide a normal `git commit` / `git push` (under conservative settings they prompt). It loads on `/usr/bin/python3` (3.9) and fails closed (a crash, signal or timeout denies any command naming push, cmux or broadcast).

`orch merge` adds the merge-side checks: the evidence file's sha, `--sha` and the worker's branch head must match, the merge must be a fast-forward, and risky tasks or a manual plan need `--user-ok` for the sha you were shown. `orch ship` only fast-forwards. Both refuse to run from a worker's checkout, and `merge`, `ship`, `run-branch` and `end-run`'s feature teardown take turns on a per-run lock (`state/feature-<run>.flock`; a second one waits up to `ORCH_FEATURE_LOCK_SECS`, default 300 s, then exits 1 with nothing done).

## Manual chores (not code)
Console/web chores (store products, console settings, uploads) are not part of this repo: the manager does them itself at the right point in the run (with your own console-chores skill, if you have one), and owner-only steps (signatures, payments, final submit/publish) come back to you. Native/device-only behaviour is checked by hand and listed as not exercised.

## Files
`~/.claude/skills/new-task/` (front door) · `skills/orchestrate/` (manager) · `skills/worker/` · `skills/{diagnosing-bugs,retro,writing-for-agents}/` · `agents/{reviewer,verifier,oracle,ci-monitor}.md` · `orchestra/bin/{orch,orch-watch,memory-lint,make-demo-repo}` · `orchestra/hooks/push-guard.py` · `orchestra/worker-mcp.json` · `statusline/statusline.py`
