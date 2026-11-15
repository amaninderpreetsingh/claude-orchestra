# How it works

The skills are the source of truth; this page is a map. Where they differ, the skill wins.

## Roles

- **Manager** — your chat, running `new-task` / `orchestrate` in the repo's main checkout inside a cmux workspace. It plans, dispatches, answers workers, merges their tasks, runs the final check, ships and reports. It never writes feature code.
- **Worker** — a separate `claude -w` session per task, opened by `orch spawn` as its own cmux workspace in the manager's sidebar group, in its own git worktree (`<repo>/.claude/worktrees/<run>-<task>`) with its own 10-port block (`$ORCH_PORT..$ORCH_PORT_END`). Workers start in auto permission mode with only the MCP servers in `orchestra/worker-mcp.json` (`--all-mcp`: all of yours). They never push and only talk to the manager.
- **Subagents** — `reviewer`, `verifier`, `oracle`, `ci-monitor`, plus Claude Code's `/code-review`. Each gets only the brief items, never the worker's reasoning.

## Two paths (`skills/new-task/SKILL.md`)

`/new-task` prints `Path: tiny | plan — <reason>` first.
- **Tiny** — ≤~30 changed lines, ≤3 files, not risky. One confirmation; `git switch -c t/<slug>` in the main checkout; edit + the test that proves it; commit; the gates the change touches plus gitleaks; one fresh `reviewer` (one re-review round if it blocks); push to main (or a PR if the repo wants PRs). No run, worker, worktree or dashboard. Bigger or riskier than it looked → it drops the branch and switches to a plan.
- **Plan** — everything else, including any risky change (auth, security rules, payments/money, data writes/migrations, CI/test infra). `/new-task` hands it to `orchestrate`; a one-task plan is fine.

## A plan, phase by phase (`skills/orchestrate/SKILL.md`, `SUPERVISE.md`)

0. **Orient.** Find the gate, setup and dev-server commands, and what a push to main deploys. Setup checks: cmux must identify the manager's workspace; for a web repo, the Playwright MCP server and Google Chrome must be there. `orch new-run` creates the run (and holds `caffeinate`); `orch baseline` runs every gate twice on the default branch in the background (flags flaky tests) while a sonnet subagent reads the code the task touches and writes `notes.md`. A new app first gets a GitHub repo and a scaffold task.
1. **Interview.** Ranked questions in rounds, each with a recommended answer; every answer is logged under `## Decisions` in `spec.md`.
2. **Plan.** EARS acceptance criteria with how each is checked, assumptions, no-gos, deploy impact, and small tasks: vertical, file-owned (no two tasks touch the same file), in dependency waves, each flagged `risky` or not, plus the **merge policy** (`auto` by default, or `manual`). Written to `plan.json` and shown to you. Approval lets the manager merge tasks into the feature branch under that policy, push it, and ship it to main after the final check. Then `orch run-branch` creates `orch/<run>` from `origin/<default>`, the feature worktree `runs/<run>/feature`, and pushes the branch.
3. **Dispatch.** Up to 3 workers at once, a task as soon as its dependencies are merged. Each gets a brief (`runs/<run>/slices/<id>.md`) and file locks on its Touches.
4. **Supervise.** The manager sleeps until a worker message (`QUESTION:`, `BLOCKED:`, `READY:`), an `orch-watch` event (`DEAD`, `STALLED` ≥15 min, `USAGE_LIMIT`, `RESUMED`) or the 30-minute heartbeat cron. Every wake runs `orch reap`, `orch report` and `orch doctor`. It answers with `ANSWER:`, `FIX:`, `REBASE:` or `STOP:`. After a usage-limit reset `orch-watch` types `continue` into paused workers; the heartbeat wakes the manager after its own limit. A `READY:` → the manager merges the task (see *Merging a READY task* below).
5. **Final check and ship** (see below), then the report: what shipped (task → sha, final main sha), what the push deploys, evidence, accepted findings and unfixed advisories, CI lines, and a separate *not exercised* list. Workers' `## Learned` notes are folded into the repo's project memory and checked with `memory-lint`.
6. **Retro**, only if something was learned: each miss → the lint rule, test, hook or reviewer rule that prevents it.

## Inside a worker (`skills/worker/SKILL.md`)

1. **Set up.** `orch register --sync` registers the worker (the owner record `orchestra-owner.json` in its worktree's git dir — the guard reads it) and points the fresh worktree at `origin/orch/<run>`.
2. **Do the task, tests first.** One failing test, then the minimal code, repeat. Every user-visible criterion gets a committed Playwright e2e spec, watched failing first. Bugs start by running the repro. Squash to one commit.
3. **Gates.** Every gate command from the brief plus gitleaks, logs under the task's artifacts dir, pass/fail counts and the sha noted. Failures also in `baseline.json` are pre-existing.
4. **Review loop, cap 4.** Each round reviews one gated commit with fresh agents launched together: a `reviewer` (`full` in round 1, `re-review` with the previous open findings after), `/code-review medium`, and on a risky task an `adversarial` reviewer in round 1 and the final round. Findings carry stable ids (`<file>:<line> <short title>`) and are classed **blocking** (a wrong result, crash, hang, fail-open or data loss on lines the diff changes), **advisory** or **rejected** (a `/code-review` finding disproved by quoting the code). Clean → step 5. The same blocking id open two rounds running, or blocking after the 4th round → `BLOCKED:` to the manager, which fixes differently (`FIX:`), accepts the finding (`ANSWER: accept <id>`), or asks you. Otherwise fix every blocking finding at the root cause, re-gate, next round.
5. **Re-check the feature branch.** Fetch; if `orch/<run>` moved, rebase onto it and re-run the gates; a conflict resolution or a gate fix that changes the patch gets one more review round.
6. **Prove the criteria.** The `verifier` runs the task's criteria: committed tests must fail on the old code and pass on the new, Playwright on the worker's own ports at 390px and desktop, real tests and emulator/API calls for backends. A criterion it can't exercise → `QUESTION:` to agree how it is checked.
7. **Evidence, then READY.** Writes `runs/<run>/slices/<id>.ready.md` (first line `sha: <full sha>`; then Gates, Review, Tests/Playwright, Not exercised) and sends `READY: <id> <sha> evidence=<path>`. A `REBASE:` after that → back to step 5, a new READY with the new sha.

## Merging a READY task

The manager reads the evidence file and trusts it (no gate re-run). A gap (no review rounds, a criterion with no result, a red gate outside the baseline) → `FIX:`. Otherwise `orch merge --run <run> --slice <id> --sha <sha>`, which works in the clean feature worktree. On any non-zero exit no branch, lock or merge record changes (exit 3 only adds its NEEDS YOU item) — with one exception: a push that errors when origin then can't be read leaves the feature worktree put back and the task unmerged, though origin may hold it; the message says so: `orch run-branch` catches the feature worktree up, then run the same `orch merge` again. `merge`, `ship`, `run-branch` and `end-run`'s feature teardown take turns on one per-run lock (`~/.claude/orchestra/state/feature-<run>.flock`); a second one waits up to `ORCH_FEATURE_LOCK_SECS` (default 300 s), then exits 1 with nothing done. A worker's checkout can't run `merge` or `ship`.

| Exit | Meaning | Manager's next step |
|---|---|---|
| 0 | merged: `orch/<run>` fast-forwarded to the worker's commit and pushed, the task's files unlocked, the task marked merged | `orch close` the worker, `REBASE:` the others (`orch broadcast`), background `ci-monitor` on the branch head (non-blocking), dispatch newly-ready tasks |
| 2 | not a fast-forward: the branch moved | `REBASE:` to that worker, wait for a new READY |
| 3 | needs your OK (a risky task, `merge_policy: manual`, a task not in `plan.json` or no `plan.json`); it added the NEEDS YOU item for that sha itself, sent one notification and printed the item number | ask you; OK → `orch merge … --sha <same sha> --user-ok`, which merges only while that sha's item is open and clears it itself (so never `note --done` it first: that would re-ask) |
| 4 | evidence missing or stale: the evidence sha, `--sha` and the worker's branch head don't all match | `FIX:` to redo the evidence, or handle the newer READY |
| 1 | anything else (feature worktree dirty or behind `origin/orch/<run>`, the lock busy, a malformed `plan.json`, the push refused) | read the message, fix that, run it again |

## Final check and ship

When every task is merged, in the feature worktree; the dashboard shows the five finish steps:
1. **Final review** — a fresh `reviewer` in mode `final` on `origin/<default>..orch/<run>` with the whole spec (plus an `adversarial` reviewer if any task was risky).
2. **Final tests** — a fresh `verifier` over every criterion end to end, then every gate against `baseline.json`. Real findings → a fix task (through dispatch and merge as usual), then from step 1 — except after a ship exit 4 (step 4).
3. **CI on the branch head** — `ci-monitor` must report `CI: PASS` (n/a without `.github/workflows`).
4. **Ship** — `orch ship --run <run>`: exit 0 fast-forwards `<default>` to `orch/<run>`, deletes the remote feature branch and prints the sha; 2 = a task isn't merged yet (or the plan has none); 1 = `origin/orch/<run>` holds commits the head doesn't carry (nothing pushed), or another failure the message names; 3 = `<default>` conflicts with the branch, nothing pushed (→ a fix task that merges `<default>` in); 4 = `<default>` moved and the feature worktree was rebased onto it (→ re-run step 2 on the new sha; green → ship again, skipping step 3: that sha can't reach `origin/orch/<run>` without a forced update, so step 5's CI on main covers it; red → a decision for you, never a fix task, since a fix worker would sync to the stale `origin/orch/<run>` and `orch merge` refuses after a ship rebase).
5. **CI on main** — `ci-monitor` on the shipped sha.

Then `orch end-run` closes every workspace, stops the run's processes, removes its worktrees (the feature worktree too), deletes the remote `orch/<run>` once the local branch or `<default>` carries everything it has (unshipped work stays in the local `orch/<run>`; the local branch goes only once it is on `<default>`), frees ports and locks, and releases `caffeinate` if no other run is active.

## Notifications

Only the NEEDS YOU items the manager raises notify you, once each: an open question, approval or owner-only step (`orch note --wait`), or a merge waiting for your OK (`orch merge` exit 3 adds it). Nothing else sends a notification — `orch spawn`'s "trust this folder" item only shows on the dashboard, so check NEEDS YOU when a worker doesn't start.

## What push-guard enforces (`orchestra/hooks/push-guard.py`)

A `PreToolUse` hook on every Bash command, about 250 lines, no shell parser: it splits the command text into simple commands best effort and checks three rules.
1. **No force pushes**, anywhere: `--force`, `-f` (also clustered), `--force-with-lease`, `--force-if-includes`, `--mirror` or an abbreviation git accepts, a `+` refspec, or `-c remote.<r>.mirror` / `.push=+…`. A delete push isn't one: outside workers it is allowed.
2. **A registered worker runs no `git … push`** at all.
3. **A worker's cmux** is only `agent message <its coordinator>` (short ref or stable id), `agent message --reply-to <id>`, `identify`, and `read-screen --surface <its own>`; no `CMUX_*` variables, no `orch broadcast`.

A denial exits 2 with one line naming the rule; anything else gets no decision, so your permission rules decide — the guard never approves or asks. Text a program only reads (an `echo`, a commit message, a `grep` pattern, a heredoc fed to `cat`/`git`/`gh`) is data; text a shell or interpreter runs is checked too. It is a guard-rail against accidents, **not a sandbox**: it knows a worker by the command's working directory (a checkout whose git dir holds `orchestra-owner.json`), so a worker that `cd`s out of its worktree isn't one to it; a script written then run, a verb built in a variable or an alias gets past it too. It loads on Python 3.9, runs no subprocess and fails closed: a crash, SIGTERM/SIGHUP or its own 20 s alarm (hook timeout 60 s) denies any command naming push, cmux or broadcast.

## State

`~/.claude/orchestra/runs/<run>/`:
- `run.json` (repo, title, default branch, `target` = the feature branch once `run-branch` ran, the manager's surface ref + stable id, status, workers), `spec.md`, `plan.json` (`{"merge_policy":"auto"|"manual","tasks":[{"id","title","wave","depends","criteria","goal","risky"}]}`), `criteria.json`, `baseline.json`, `notes.md`, `HANDOFF.md`, `cron.txt` (the heartbeat job id).
- `slices/<id>.md` (briefs), `<id>.progress.md` (the worker's step log and `## Learned`), `<id>.ready.md` (its evidence file).
- `waiting.json` (NEEDS YOU items), `ticks.json` and `finish.json` (dashboard state: next heartbeat, current finish step), `artifacts/<id>/` (gate logs, screenshots).
- `feature/` — the feature worktree on `orch/<run>`, where `orch merge` and `orch ship` work.

Worker registration lives in each worker worktree's git dir (`orchestra-owner.json`); file locks and port blocks under `~/.claude/orchestra/locks/`, `caffeinate` and watch state under `~/.claude/orchestra/state/`.
