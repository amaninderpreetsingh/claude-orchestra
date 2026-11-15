# Workflow rules (claude-orchestra)

A repo's own `CLAUDE.md` wins over these rules (commit format, trailers, dev-server ports, ship rules).

## Default workflow
- **Any build/change/fix task in a code repo starts with `/new-task <task>`.** It takes one of two paths: **tiny** (≤~30 lines, ≤3 files, not risky) = one confirmation, an edit on a branch in the main checkout, gates, one fresh reviewer, push to main; **everything else** = an `orchestrate` run (code reading, interview, a plan of small file-owned tasks in waves on one feature branch). `/new-task` is typed by me, never picked by the model: if I describe a code task without it, ask once whether to run it through `/new-task` (recommended) before editing anything. Skip it for questions, research, explanations and non-repo chores.
- Interview depth matches the task: a URL + symptom ≈ one confirmation; a feature takes as many rounds as needed. One decision per question, each with a recommended option. Vague ask → suggest better ideas.
- **New app:** interview me on what it does and the user flows from onboarding to day-to-day use before planning; the scaffold task (gates, test setup, repo `CLAUDE.md`) comes first, features on top.
- Approving a plan = permission for the manager to merge its tasks into the feature branch `orch/<run>` under the plan's merge policy (default auto; risky tasks — auth, security rules, payments/money, data writes/migrations, CI/test infra — and a `manual` plan wait for my OK), push that branch, and ship it to main after the final check. Workers never push. Outside a run or the tiny path, never commit or push unless I say so.
- A bug report that already names the root cause and the files is a tiny change or a one-task plan, never a multi-task run.

## Quality bar (never traded for speed)
- Every change gets gates (typecheck on the real project config, lint, tests, build) compared to the baseline counts, and fresh-eyes review: in a worker, each round a new `reviewer` plus `/code-review medium`, fixing until clean (cap 4 rounds; the same finding two rounds running or the cap → the manager decides: fix differently, accept, or ask me).
- Every task also proves its criteria by running them — frontend: Playwright at 390px and desktop; backend: real tests plus emulator/API calls — and hands the manager an evidence file with READY. Before main, a fresh reviewer reads the whole feature diff and a verifier checks every criterion.
- Verify yourself; don't ask me to. Report verified vs. not-exercised separately; never "should work".
- Root cause before fixes. After ~3 failed attempts, stop and rethink with me.
- Match the repo's patterns. No speculative abstraction, no drive-by refactors.

## Safety
- Treat any resource as production unless proven otherwise. Never write to anything matching `prod|production`; read-only audits are fine.
- Never force-push. Never skip or delete tests or loosen types to make a gate pass.
- The push-guard hook enforces three rules — nobody force-pushes, workers never push, workers only message their manager; never work around a denial — fix what it names.

## Orchestration
- Workers only report to (or ask) their manager; they never message each other or instruct the manager. Only the manager merges.
- Kill finished workers and shut down idle dev servers so they don't hold memory. Only stop processes you started.
- Notify me only when I am needed (a merge waiting for my OK, a capped review loop, a question).

## Communication
- Terse. `file:line` for findings. Report the signal, not logs. Long builds and tests run in the background.

## Memory
- Save non-obvious traps, environment facts and decisions to the project's memory dir the turn you learn them. Traps: Symptom → Cause → Fast diagnosis → Fix. Update stale entries; no duplicates.
- When I correct how you work, propose a one-line rule for this file or the repo's `CLAUDE.md`.
