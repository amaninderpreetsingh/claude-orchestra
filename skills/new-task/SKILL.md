---
name: new-task
description: Start any repo task sized to its tier - triage S/M/L, then a lite S edit, one M worker, or full orchestrate for L. --answers <file> runs unattended; --resume <run> continues.
argument-hint: <task> [--answers <file>] [--resume <run>]
disable-model-invocation: true
---

# New task — spend tokens to match the tier

`ORCH=~/.claude/orchestra/bin/orch` · runs in `~/.claude/orchestra/runs/<run>/`. Read the repo `CLAUDE.md` first; it wins over this file.

## 0. Flags
- `--resume <run>`: read `runs/<run>/HANDOFF.md` and continue from the step it names, in the tier it records. Skip triage.
- `--answers <file>`: **unattended**. Format: [answers.example.md](answers.example.md). Every question you would ask is answered from the file (match by meaning, not exact text). No matching answer → take your recommended option and log it under `## Decisions` in the run's `spec.md` (S: in your final report) as `Q → A (default, not in answers file)`. `approve: yes` stands in for every approval. Never call `AskUserQuestion`; run to the end, then report.

## 1. Triage — your first output, before any other step
Print exactly one line: `Tier: S|M|L — <reason>`. Judge from the task text plus a glance at the files it names (no subagents).
- **S** — ≤~30 changed lines, ≤3 files, not risky.
- **M** — one coherent feature or fix, one worker.
- **L** — needs several slices, or is risky.
- **Risky** (never S; M only if one worker can own it, else L): auth, security rules, payments/money, data writes/migrations, CI/test infra.
- Unsure between two tiers → pick the larger one. New project (no repo, `origin`, or commits) → L.
- Repo has no `CLAUDE.md` → draft one (gate, setup, dev-server commands from build files) and show it; commit it with the task only after the S/M approval.

## 2. Tier S — lite path, lite review rounds (+ ci-monitor after push if .github/workflows)
No worker, worktree, cron, dashboard, baseline, or exploration subagent. You edit in the main checkout.
1. One confirmation: restate the change + the files + the proving command (the test or check that shows it works); ask Approve.
2. `git switch -c s/<slug>` from an up-to-date default branch (or stay on main when the repo `CLAUDE.md` says so). Edit; add or adjust the test that proves it.
3. Commit (repo message format). Gates record the HEAD they ran on, so they always follow the commit.
4. Gates, only what the change touches: `$ORCH gates --worktree . --cmd "<affected tests>" --cmd "<typecheck>" --cmd "<lint>"`; red → fix, amend, re-gate. Green → `$ORCH tier --set S` (records tier S for this HEAD).
5. **Review rounds**: review tier `lite` of `~/.claude/skills/worker/SKILL.md` §4–5 on `origin/<default>..HEAD`, except: the `reviewer` (lite) works in the main checkout with `model: sonnet` (brief: main checkout path, range, the criterion, the proving command, the user's answers; it runs the command and records its own verdict); no verifier; round lines go in your report, not `$PROG`; your Touches are the files from step 1; a fix is amend, re-gate, `tier --set S` again; the cap or a repeat → stop and ask the user (unattended: report the blockers and stop).
   - BLOCK "re-tier" (instead of a fix) → `$ORCH tier --set M`, switch back to the default branch, delete `s/<slug>` (the worker starts from origin), and go to §3 (§3.6 clears the record after the merge).
6. Clean round (lite PASS on HEAD) → `git push origin HEAD:<default>` (push-guard checks tier S + gates + lite PASS for HEAD), or push the branch and `gh pr create --fill` when the repo `CLAUDE.md` wants PRs. Then switch back, `git pull --ff-only`, delete `s/<slug>`.
7. `.github/workflows` exists → background `ci-monitor` (sha + branch). Report: change, gates, rounds, reviewer PASS, unfixed advisories, CI line.

## 3. Tier M — one worker, straight to main
1. The `orchestrate` Phase 0 setup checks (step 3), all before `new-run`: Playwright missing → ask the user with its fixes and wait (unattended: report what's missing and stop). Then `$ORCH new-run --repo <root> --title "<short>"` → `RUN`; start `$ORCH baseline` in the background as in `orchestrate` Phase 0.
2. **One** interview round: restate the ask, list Assumptions, and ask only what code/docs can't answer (≤4 questions, each with a recommended answer). Then write `spec.md` (Decisions, criteria `C1..Cn` in EARS with checks, no-gos), `criteria.json` + `$ORCH criteria-init`, and ask Approve.
3. Exactly one slice `S1` covering the whole task. No `run-branch`: the worker pushes straight to main. Write the brief and spawn as in `orchestrate` Phase 3 steps 1–3 (lock, brief, `$ORCH spawn --run $RUN --slice S1`); the brief points at the code to read instead of a `notes.md`. Its `Review:` tier (worker §4) is prose, code, or risky when it touches a risky path (then also mark it risky); the `worker` skill runs the review rounds and `verifier`.
4. Supervise: background Bash `orch-watch --run $RUN --timeout 1800` (from `~/.claude/orchestra/bin`). Exit 0 prints `EVENT <kind> <slice> <detail>` → act per `orchestrate` SUPERVISE.md; exit 3 = 30-min heartbeat → one-line status, re-arm. Worker messages (QUESTION/BLOCKED/PROGRESS/DONE/MERGED) wake you too; answer from the answers file when unattended.
5. After you act on each event, write `runs/$RUN/HANDOFF.md`: tier M, current step, open questions, next action.
6. MERGED → no integration phase. `git pull --ff-only`, then `$ORCH tier --clear` (drops any tier record, e.g. from an S re-tier; until then push-guard denies pushes touching its files). `ci-monitor` if `.github/workflows` exists, `$ORCH end-run --run $RUN`, close the worker workspace, report: criteria, gates vs baseline, reviewer/verifier PASS, CI, not-exercised.

## 4. Tier L — full orchestra
Invoke the `orchestrate` skill with the task. Everything from its Phase 0 on applies unchanged; with `--answers`, §0 still answers every question and approval it asks.
