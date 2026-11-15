---
name: new-task
description: Start any repo task - a tiny change takes the fast path (confirm once, edit on a branch, gates, one fresh reviewer, push); anything else goes to `orchestrate`. --answers <file> runs unattended; --resume <run> continues.
argument-hint: <task> [--answers <file>] [--resume <run>]
disable-model-invocation: true
---

# New task — tiny fast path, or a plan

`ORCH=~/.claude/orchestra/bin/orch` · runs in `~/.claude/orchestra/runs/<run>/`. Read the repo `CLAUDE.md` first; it wins over this file.

## 0. Flags
- `--resume <run>`: read `runs/<run>/HANDOFF.md` and continue with `orchestrate --resume <run>`. Skip triage.
- `--answers <file>`: **unattended**. Format: [answers.example.md](answers.example.md). Every question you would ask is answered from the file (match by meaning, not exact text). No matching answer → take your recommended option and log it under `## Decisions` in the run's `spec.md` (fast path: in your final report) as `Q → A (default, not in answers file)`. `approve: yes` stands in for every approval. Never call `AskUserQuestion`; run to the end, then report.

## 1. Triage — your first output, before any other step
Print exactly one line: `Path: tiny | plan — <reason>`. Judge from the task text plus a glance at the files it names (no subagents).
- **tiny** — ≤~30 changed lines, ≤3 files, and not risky.
- **plan** — everything else, including any **risky** change: auth, security rules, payments/money, data writes/migrations, CI/test infra.
- Unsure → plan. New project (no repo, `origin`, or commits) → plan.
- Repo has no `CLAUDE.md` → draft one (gate, setup, dev-server commands from build files) and show it; tiny: commit it with the change after the confirmation.

## 2. Tiny — the fast path
No run, worker, worktree, cron, dashboard, baseline, or exploration subagent. You edit in the main checkout.
1. **One confirmation**: restate the change + the files + the proving command (the test or check that shows it works); ask Approve.
2. `git switch -c t/<slug>` from an up-to-date default branch (or stay on it when the repo `CLAUDE.md` says so). Edit; add or adjust the test that proves it.
3. Commit (repo message format).
4. **Gates**, only what the change touches: the affected tests, typecheck, lint, and `gitleaks git --no-banner --log-opts=origin/<default>..HEAD`. Red → fix, amend, re-run.
5. **One fresh `reviewer`** (mode `full`, `model: sonnet`): the main checkout path, range `origin/<default>..HEAD`, the change as its criterion, the proving command (it runs it), the user's answers. BLOCKING → fix, amend, re-gate, then one `re-review` round (its open findings + the sha it reviewed). The change turns out bigger than tiny or risky → switch back to the default branch, delete `t/<slug>`, and go to §3 with what you learned (unattended too). Still blocking after the re-review → ask the user: go to §3, or stop (unattended: report the open findings and stop; nothing is pushed).
6. Clean → `git push origin HEAD:<default>`, or push the branch and `gh pr create --fill` when the repo `CLAUDE.md` wants PRs. Rejected because `<default>` moved → `git fetch origin && git rebase origin/<default>`, re-run step 4, then retry (conflicts that change the patch → step 5 again). Then switch back, `git pull --ff-only`, delete `t/<slug>`.
7. `.github/workflows` exists → background `ci-monitor` (sha + branch). Report: change, gates, reviewer verdict, unfixed advisories, CI line.

## 3. Plan — everything else
Invoke the `orchestrate` skill with the task (and what triage or the fast path learned). A one-task plan is fine. Everything from its Phase 0 on applies unchanged; with `--answers`, §0 still answers every question and approval it asks.
