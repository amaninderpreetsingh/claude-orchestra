# Workflow rules (claude-orchestra)

A repo's own `CLAUDE.md` wins over these rules (commit format, trailers, dev-server ports, ship rules).

## Default workflow
- **Any build/change/fix task in a code repo starts with `/new-task <task>`.** It sizes the task S / M / L and spends tokens to match: S = a small edit in the main checkout with a lite review, M = one worker, L = the full `orchestrate` run (interview, spec, parallel file-owned slices). `/new-task` is typed by me, never picked by the model: if I describe a code task without it, ask once whether to run it through `/new-task` (recommended) before editing anything. Skip it for questions, research, explanations and non-repo chores.
- Interview depth matches the task: a URL + symptom ≈ one confirmation; a feature takes as many rounds as needed. One decision per question, each with a recommended option. Vague ask → suggest better ideas.
- **New app:** interview me on what it does and the user flows from onboarding to day-to-day use before speccing; the scaffold slice (gates, test setup, repo `CLAUDE.md`) comes first, features on top.
- Approving a spec = permission for that run's workers to commit and push their slices to the run's target branch (main for a single-slice run, the run branch `orch/<run>` for multi-slice runs, which the coordinator integrates and pushes to main). Outside a run, never commit or push unless I say so.
- A bug report that already names the root cause and the files is tier S or M (one worker), never a multi-slice run.

## Quality bar (never traded for speed)
- Every change gets gates (typecheck on the real project config, lint, tests, build) compared to the baseline counts, and a fresh-eyes review loop sized by review tier (`~/.claude/skills/worker/SKILL.md` §4): each round new reviewers, fixes, re-gate, until a clean full round (capped at 2 or 4 rounds, then the `oracle`, then I decide).
- Every worker slice also needs a `verifier` PASS on the exact commit that ships — frontend: Playwright at 390px and desktop; backend: real tests plus emulator/API calls. A `/new-task` S change has a lite reviewer run its proving command instead, no verifier.
- Verify yourself; don't ask me to. Report verified vs. not-exercised separately; never "should work".
- Root cause before fixes. After ~3 failed attempts, stop and rethink with me.
- Match the repo's patterns. No speculative abstraction, no drive-by refactors.

## Safety
- Treat any resource as production unless proven otherwise. Never write to anything matching `prod|production`; read-only audits are fine.
- Never force-push. Never skip or delete tests or loosen types to make a gate pass.
- The push-guard hook enforces the push rules; never work around a denial — fix what it names.

## Orchestration
- Workers only report to (or ask) their coordinator; they never message each other or instruct the coordinator.
- Kill finished workers and shut down idle simulators and dev servers so they don't hold memory. Only stop processes you started.
- A review finding that repeats in two rounds becomes my decision, not another fix round.

## Communication
- Terse. `file:line` for findings. Report the signal, not logs. Long builds and tests run in the background.

## Memory
- Save non-obvious traps, environment facts and decisions to the project's memory dir the turn you learn them. Traps: Symptom → Cause → Fast diagnosis → Fix. Update stale entries; no duplicates.
- When I correct how you work, propose a one-line rule for this file or the repo's `CLAUDE.md`.
