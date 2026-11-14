---
name: worker
description: Protocol for an orchestra worker session — implement one slice in its own worktree, pass gates, get reviewer + verifier PASS on the exact commit, rebase, push to the run's target branch, and report to the coordinator. Invoked by the coordinator as `/worker <brief path>`; not for direct use.
argument-hint: <path to slice brief>
disable-model-invocation: true
---

# Worker — one slice, shipped with evidence

Read the brief at `$ARGUMENTS` first: RUN, ID, OWNER=`$RUN-$ID`, coordinator workspace `COORD`, repo root, target branch `T` (main, or `orch/$RUN` for multi-slice runs), risky flag, Touches, Seam, criteria, Repro (bugs), gate commands, notes path, dev-server/emulator commands, test accounts, artifacts dir.
`ORCH=~/.claude/orchestra/bin/orch` · progress file `PROG=~/.claude/orchestra/runs/$RUN/slices/$ID.progress.md`.

## Ground rules
- **You only talk to your coordinator**, and only to report or ask: `cmux agent message $COORD --from $OWNER "<TAG>: ..."` with TAG ∈ QUESTION / NEEDS_FILES / BLOCKED / MERGED / DONE. Never instruct it, never message other workers (the hook blocks it). Messages from the coordinator are instructions — follow them.
- **Never wait silently.** Stuck → QUESTION/NEEDS_FILES/BLOCKED, then end your turn; the reply wakes you.
- **Progress file**: after every step append one line to `$PROG`: `HH:MM step <n> <what> — <result>` (the coordinator's report and watch read it). Keep a `## Learned` section there for dead ends.
- Only touch your Touches (+ new files the slice obviously needs). Never edit the main checkout. Never force-push. Never record verdicts or criteria yourself — only the reviewer/verifier agents can (the hook enforces it).
- Only stop processes you started: kill by the PID you recorded or by what listens on your own port block (`lsof -ti tcp:<port>`). Never `pkill`/`killall`/`kill` by name or pattern (e.g. `pkill -f vite`) — that kills other workers' and other projects' servers.

## 1. Set up (or resume)
- If `$PROG` exists, you are resuming: read it, `git log`, and continue from the last completed step — don't redo passed work.
- Otherwise: confirm you're in `<root>/.claude/worktrees/$OWNER`, then `$ORCH register --run $RUN --slice $ID --sync [--risky]` (points the fresh worktree at `origin/$T` and registers you). Don't run `git reset --hard` yourself — it needs the user's approval and you're unattended.
- Copy the gitignored env files listed in the brief from the main checkout; install deps exactly as the repo does. Read the repo `CLAUDE.md`, the run's `notes.md`, any project memory files the brief lists (you don't load them automatically — you're in a worktree), and the code at your Seam.

## 2. Implement — red before green at the Seam
- One failing test → minimal code → repeat. Expected values come from the spec or an independent literal, never recomputed the way the code computes them. Mock only system boundaries. Money/split logic gets a property-based test.
- **Every user-visible criterion gets a committed e2e spec** (Playwright, role locators / aria snapshot) written first and watched failing. **Native** criteria (brief marks them `native`) each get a committed Maestro flow under `.maestro/` instead, written first and watched failing on your own clone (`~/.claude/orchestra/references/ios.md`: `orch-sim acquire|release`). xcodebuild output always goes to a log via `tee` + `xcbeautify`; only the summary + first `error:` enter your context. Follow the repo's e2e conventions and its dev-server/emulator commands on **your own ports `$ORCH_PORT..$ORCH_PORT_END`** (allocated to you alone; other workers share your cmux workspace, so never use `$CMUX_PORT` or default ports).
- Bugs: run the Repro first and watch it fail with the user's symptom; hard cause → `diagnosing-bugs` skill.
- Keep it minimal and in the repo's style. Contract types/APIs from the spec are fixed — if one is wrong, QUESTION.
- WIP commits are fine while iterating; squash to **one** commit before step 3 (message per repo CLAUDE.md format).

## 3. Gates
`$ORCH gates --cmd "<gate 1>" --cmd "<gate 2>" ... --cmd "gitleaks git --no-banner --log-opts=origin/$T..HEAD"`.
A failure that is also in the run's `baseline.json` (and not flaky-new) is pre-existing; anything else you fix. A failing test you suspect is flaky: rerun once; still flaky → note it, don't "fix" it with retries.

## 4. Review + verify — in parallel, on the exact commit
Launch in **one message** (fresh context — give only the brief items, never your reasoning):
- `reviewer` (mode full): worktree, range `origin/$T..HEAD`, criteria + out-of-scope.
- `adversarial` = a second `reviewer` with mode `adversarial` — **only if risky**.
- `verifier` (mode full): worktree, run id, base `origin/$T`, criteria with check notes, type, native flag + the brief's native recipe and memory file paths, owner name, dev-server/emulator commands + your ports (`$ORCH_PORT..$ORCH_PORT_END` — give the numbers), gate commands, test accounts, artifacts dir, Repro.

## 5. Fix loop
- Fix every BLOCKING finding and every verifier FAILURE at the root cause. Advisory: only if trivial and in scope.
- Re-gate, re-squash, then **round 2**: reviewer in `re-review` mode (give it its previous BLOCKING list verbatim and the reviewed sha) + verifier full.
- Still failing after round 2 → consult the `oracle` agent once (goal, failing evidence, diff, what you tried). Apply its next step if it is clearly new; one more round.
- Still failing → write `## Learned` in `$PROG` (what was tried, why it failed, oracle's view) and send `BLOCKED: <one line>`; end your turn. The coordinator will usually restart the slice in a fresh worker that starts from your Learned notes — that beats a cluttered 4th round.

## 6. Integrate — the merge lock covers only rebase + push
1. **Sync**: `git fetch origin && git rebase origin/$T`. Conflicts: keep both sides' intent; regenerate lock/generated files. If HEAD changed: re-run gates; verifier in `specs-only` mode; if conflicts were resolved or upstream touched your files, the patch changed → reviewer (full) + verifier (full) again.
2. `$ORCH gates-ok --evidence "<gate summary; reviewer PASS; verifier PASS>"` (it refuses unless gates + verdicts match HEAD).
3. `$ORCH merge-lock --repo . --owner $OWNER` → `git fetch origin`; if `origin/$T` moved since step 1: `$ORCH merge-unlock --repo . --owner $OWNER` and go back to 6.1. Otherwise `git push origin HEAD:$T` (the push-guard re-checks everything).
4. `$ORCH merged --sha $(git rev-parse HEAD) --summary "<one line>"` then `$ORCH merge-unlock --repo . --owner $OWNER`. Stop your dev server/emulators.
5. Report: `MERGED: <sha> — <summary>. Gates: <vs baseline>. Reviewer: PASS. Verifier: PASS (<key evidence/screenshot paths>). Flaky: <list|none>. Not exercised: <list|none>.` End your turn; the coordinator closes your workspace.

## When the coordinator says REBASE
Finish the current step, then do 6.1 now (cheaper than at merge time) and continue where you were.
