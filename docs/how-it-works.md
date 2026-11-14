# How it works

The skills are the source of truth; this page is a map. Where they differ, the skill wins.

## Roles

- **Coordinator** — your chat, running `new-task` / `orchestrate` in the repo's main checkout inside a cmux workspace. It plans, dispatches, answers workers, integrates and reports. It never writes feature code.
- **Worker** — a separate `claude -w` session per slice, opened by `orch spawn` as its own cmux workspace in the coordinator's sidebar group, in its own git worktree (`<repo>/.claude/worktrees/<run>-<slice>`) with its own 10-port block (`$ORCH_PORT..$ORCH_PORT_END`). Workers start in auto permission mode with only the MCP servers in `orchestra/worker-mcp.json`; `orch spawn --native` (Simulator slices) skips that file so the worker keeps cmux Computer Use.
- **Subagents** — `reviewer`, `verifier`, `oracle`, `ci-monitor`, plus a general-purpose agent that runs `/code-review`. Each gets only the brief items, never the worker's reasoning.

## A run, phase by phase (`skills/orchestrate/SKILL.md`, `SUPERVISE.md`)

0. **Orient.** Find the gate, setup and dev-server commands, and what a push to main deploys. Setup checks: cmux must identify the coordinator's workspace; for a web repo, the Playwright MCP server and Google Chrome must be there (if not, it asks you to set them up before dispatching). `orch new-run` creates the run; `orch baseline` runs every gate twice on the default branch in the background (flags flaky tests) while a subagent writes `notes.md` about the code the task touches. A new app first gets a GitHub repo and a scaffold slice.
1. **Interview.** Ranked questions in rounds, each with a recommended answer; every answer is logged under `## Decisions` in `spec.md`.
2. **Spec.** EARS acceptance criteria with how each is checked, assumptions, no-gos, deploy impact, and slices: vertical, file-owned (no two slices touch the same file), in dependency waves, flagged `risky` or `native`. You approve; approval lets this run's workers push.
3. **Dispatch.** Up to 3 workers at once. Each gets a brief (`runs/<run>/slices/<id>.md`) and file locks on its Touches.
4. **Supervise.** The coordinator sleeps until a worker message (`QUESTION`, `NEEDS_FILES`, `BLOCKED`, `PROGRESS`, `MERGED`, `DONE`), an `orch-watch` event (`DEAD`, `STALLED` ≥15 min, `USAGE_LIMIT`, `RESUMED`) or the 30-minute heartbeat. Every wake runs `orch reap`, `orch report` and `orch doctor`. Usage-limited sessions resume themselves after the reset; `caffeinate` keeps the Mac awake while a run is active.
5. **Integrate** (multi-slice runs). Slices land on `orch/<run>`; the coordinator reviews and verifies the whole feature in an integration worktree with the same review rounds, then pushes to main once. Fixes go through new fix slices, never by hand.
6. **Report and retro.** What shipped, what the push deploys, evidence, unfixed advisories, and a separate *not exercised* list. Workers' `## Learned` notes are folded into the repo's project memory.

Tier S skips all of this (one confirmation, edit, gates, lite review rounds, push). Tier M is one interview round, one slice, one worker, straight to main, no integration phase.

## Inside a worker (`skills/worker/SKILL.md`)

1. **Set up.** `orch register --sync` points the worktree at the target branch and registers the worker (the push-guard reads that registration).
2. **Implement, red before green.** One failing test, then the minimal code, repeat. Every user-visible criterion gets a committed Playwright e2e spec (native ones: a Maestro flow), watched failing first. Bugs start by running the repro.
3. **Gates.** `orch gates --cmd …` runs every gate plus gitleaks on the exact commit and records the result. Failures also in `baseline.json` are pre-existing.
4. **Review rounds.** Each round reviews one gated, squashed commit:
   - in parallel and fresh: a `reviewer` in full mode, a `/code-review` run, and on risky slices an adversarial reviewer in round 1;
   - `/code-review` findings are classified: **blocking** (on lines this diff changes, a concrete failure needing at most one unusual condition), **advisory** (pre-existing behaviour, unchanged lines, several unusual conditions at once) or **rejected** (disproved by quoting the code, or contradicting a recorded decision — reported with the quote);
   - anything blocking → fix every blocking finding at the root cause plus the advisories inside the slice's files, re-gate, next round;
   - a clean round → (risky: an adversarial PASS on this commit first) the `verifier` runs. PASS → integrate; FAILURE → fix and another round.
   - Same finding in two consecutive rounds → `QUESTION` to the coordinator, which asks you. Blocking or a verifier FAILURE in round 4 or later → one `oracle` consult, `## Learned` notes, `BLOCKED`.
5. **Integrate.** Rebase on the target branch (gates again; verifier in specs-only mode if the patch is unchanged, a full new round if it changed), `orch gates-ok`, take the merge lock **as its own command**, plain `git push origin HEAD:<target>`, `orch merged`, unlock, report `MERGED`.

## What push-guard enforces (`orchestra/hooks/push-guard.py`)

A `PreToolUse` hook on every Bash command:
- **In a worker worktree:** a push must be exactly `git push origin HEAD:<registered branch>`, on top of the latest remote, with gates-ok recorded for that HEAD (gates + reviewer + verifier PASS), holding the merge lock. A compound command containing a push is denied, and so is anything it can't parse exactly or any error: when unsure, it denies. Write the push as one plain command with the branch written out (no `cd`, variables or `$(…)`).
- **Messaging:** workers may only send tagged messages to their own coordinator and may not drive other cmux workspaces.
- **Verdicts:** only the reviewer/verifier agents may record them.
- **Outside workers:** plain commits and pushes are not blocked by the guard, except while a tier record (`orch tier`) binds an unshipped change; compound commands are never auto-approved, so your own permission rules decide. Force and delete pushes are always denied.

Known limits are listed in the guard's header.

## State

`~/.claude/orchestra/runs/<run>/`: `spec.md`, `criteria.json`, `plan.json`, `baseline.json`, `notes.md`, `HANDOFF.md`, `slices/<id>.md` (briefs) and `<id>.progress.md`, `artifacts/<id>/` (screenshots, logs). Gate and verdict evidence lives in each worktree's git dir, keyed by commit.
