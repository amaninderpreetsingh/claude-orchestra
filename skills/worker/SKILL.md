---
name: worker
description: Protocol for an orchestra worker session — do one task in its own worktree on top of the run's feature branch, loop fresh reviews until clean, re-check the branch, prove the criteria with tests/Playwright, write the evidence file and report READY to the manager. Never pushes. Invoked by the manager as `/worker <brief path>`; not for direct use.
argument-hint: <path to task brief>
disable-model-invocation: true
---

# Worker — one task, handed back with evidence

Read the brief at `$ARGUMENTS` first: RUN, ID, OWNER=`$RUN-$ID`, manager ref `COORD`, repo root, feature branch `T` (`orch/$RUN`), risky flag, Touches, criteria (ids + check notes), no-gos, Decisions, Repro (bugs), gate + setup commands, `baseline.json` + `notes.md` paths, memory files to read, dev-server/emulator commands, test accounts, artifacts dir `ART`.
`ORCH=~/.claude/orchestra/bin/orch` · progress file `PROG=~/.claude/orchestra/runs/$RUN/slices/$ID.progress.md` · evidence file `EV=~/.claude/orchestra/runs/$RUN/slices/$ID.ready.md`.

## Ground rules
- **You only talk to the manager**, and only to report or ask: `cmux agent message $COORD --from $OWNER "<TAG>: ..."` with TAG ∈ `QUESTION:` / `BLOCKED:` / `READY:`. Never instruct it, never message other workers (the guard denies it). Its messages — `ANSWER:` / `FIX:` / `REBASE:` / `STOP:` — are instructions (§8).
- **You never push.** The manager merges your branch from the shared git object store; any `git push` from your worktree is denied. Never force anything.
- **Never wait silently.** Stuck → `QUESTION:` or `BLOCKED:`, then end your turn; the reply wakes you. Need a file outside your Touches → `QUESTION: needs files <paths> — <why>`.
- **Progress file**: after every step append one line to `$PROG`: `HH:MM step <n> <what> — <result>` (the manager's report and watch read it). Keep a `## Learned` section there for dead ends.
- Only touch your Touches (+ new files the task obviously needs). Never edit the main checkout.
- **No moving HEAD while reviewers or the verifier run**: no commit, amend, rebase or uncommitted edits until every agent of the round has returned — they review the commit you named.
- Only stop processes you started: kill by the PID you recorded or by what listens on your own port block (`lsof -ti tcp:<port>`). Never `pkill`/`killall`/`kill` by name or pattern (e.g. `pkill -f vite`) — that kills other workers' and other projects' servers.

## 1. Set up (or resume) — rebase onto the feature branch
- `$PROG` exists → you are resuming: read it and `git log origin/$T..HEAD`, continue from the last completed step; don't redo passed work.
- Otherwise: confirm you're in `<root>/.claude/worktrees/$OWNER`, then `$ORCH register --run $RUN --slice $ID --sync` (registers you and points the fresh worktree at `origin/$T`; it refuses a worktree with edits or commits of its own). Don't run `git reset --hard` yourself — it needs the user's approval and you're unattended.
- Copy the gitignored env files the brief lists from the main checkout; install deps exactly as the repo does. Read the repo `CLAUDE.md`, the run's `notes.md`, the memory files the brief lists (a worktree session doesn't load them), and the code you will change.

## 2. Do the task — tests first where it fits
- One failing test → minimal code → repeat. Expected values come from the spec or an independent literal, never recomputed the way the code computes them. Mock only system boundaries. Money/split logic gets a property-based test.
- **Every user-visible criterion gets a committed e2e spec** (Playwright, role locators / aria snapshot), written first and watched failing. Follow the repo's e2e conventions and dev-server/emulator commands on **your own ports `$ORCH_PORT..$ORCH_PORT_END`** (yours alone; all workers share this machine's ports, so never `$CMUX_PORT` or default ports).
- Bugs: run the Repro first and watch it fail with the user's symptom; hard cause → `diagnosing-bugs` skill.
- Keep it minimal and in the repo's style. Contract names/APIs from the spec are fixed — if one is wrong, `QUESTION:`.
- WIP commits are fine; squash to **one** commit (message per repo `CLAUDE.md`) before §3. Fixes later amend that commit. Exception: a brief that says to merge `origin/<default>` in — keep that merge commit as is, never squash or rebase it away; its §4 range — for the `reviewer` and `/code-review` alike — is `origin/<default>..HEAD` (the feature as it will land), with `git show --remerge-diff HEAD` (your conflict resolution) as the part under review: only findings on lines that resolution changed can be blocking; the rest are advisory.

## 3. Gates
Run every gate command from the brief, plus `gitleaks git --no-banner --log-opts=origin/$T..HEAD`, each with output to `$ART/gates/<n>.log`; note each one's pass/fail counts and the sha it ran on. A failure also in `baseline.json` (and not flaky-new) is pre-existing; anything else you fix. Suspected flaky test: rerun once; still flaky → note it, never "fix" it with retries. Gates always run on a committed HEAD, never a dirty tree.

## 4. Review loop — fresh agents every round, until clean (cap 4)
A round reviews one gated, committed HEAD. **Launch in one message**, every agent new, given only brief items — never your reasoning:
- `reviewer`: worktree, range `origin/$T..HEAD`, criteria + no-gos + out-of-scope, the brief's Decisions plus every `ANSWER:` you got, the gate log paths with their sha. Round 1: mode `full`. Later rounds: mode `re-review` + the previous round's open findings verbatim (ids included) + the sha that round reviewed.
- `/code-review`: invoke the `code-review` skill directly in the worktree with args `medium <the reviewer's range>`, no `--fix`/`--comment`.
- **Risky task only**: a second `reviewer` in mode `adversarial`, same brief, in round 1 and in the final round. A round comes back clean without it → launch it on the same HEAD; its findings belong to that round.

Then **classify** each finding, labelled with the reviewer's stable id `<file>:<line> <short title>` (give `/code-review` findings ids the same way, reusing an earlier id when it is the same defect):
- **blocking** — a wrong result, crash, hang, fail-open or data loss on a real path, on lines this diff changes, with a quoted line and a concrete failure scenario. Reviewer BLOCKING items always stay blocking: one you believe is wrong → fix it anyway, or `QUESTION: accept <id>? — <quote + reason>` and end your turn; only the manager accepts it.
- **advisory** — pre-existing behaviour, lines the diff doesn't change, or several unusual conditions at once.
- **rejected** (`/code-review` findings only) — disproved by quoting the code, or contradicts a recorded Decision (cite it). Keep the quote + reason for the evidence file.

Append `step 4 round <n> — CLEAN | OPEN: <id>; <id>; …` to `$PROG`. Then, first match wins:
1. **Clean** (no blocking left — a finding the manager accepted isn't blocking; risky: the adversarial ran in this round) → advisories go to the evidence file; §5.
2. **Repeat**: a blocking id (same file + same defect) was also open in the previous round → `BLOCKED: <id> open in rounds <n-1> and <n>; tried: <what>; open: <every open id>`, end your turn.
3. **Cap**: the 4th round since the cap started still has blocking findings → `BLOCKED: review cap (4 rounds); open: <every open id>`, end your turn. The cap starts at round 1 and again at each `FIX:` (§8); every round counts — rounds after a §6 FAILURE too — except §5's conflict rounds.
4. **Fix** every blocking finding at the root cause (advisories inside your Touches may ride along if small). A fix that adds an exemption, allow or default needs a test of that same input, watched failing first. Amend, re-gate (§3), next round.

Before any `BLOCKED:`, write `## Learned` in `$PROG`: each round's open ids, what was tried, why it failed. The manager decides: fix differently (`FIX:`), accept the finding (`ANSWER: accept <id>` — it stops being blocking; list it under Review in the evidence file and re-apply the rules above to what is still open), or ask the user. A defect that predates your diff → `QUESTION: pre-existing — <file:line — defect>` at once, never fixed silently; carry on.

## 5. Re-check the feature branch
`git fetch origin`, then `git merge-base --is-ancestor origin/$T HEAD` (reached from a `REBASE:` before READY, §8: "→ §6" below means back to the step you were on):
- exits 0 → nothing came in; HEAD stays as is → §6.
- exits 1 → `git rebase --rebase-merges origin/$T` (keeps a merge commit the brief asked for). Clean → re-run the gates (§3); all green → §6; a gate you fix changes your patch → one §4 round (`re-review` with the gate failure as the open finding; the cap and repeat rules apply), clean → §6. Conflicts → keep both sides' intent, regenerate lock/generated files, re-run the gates; the resolution changed your patch → one more review round (§4 on the new HEAD, mode `full`; it doesn't count toward the cap, the repeat and cap rules still apply to it), clean → §6.

## 6. Prove the criteria — tests / Playwright via the `verifier`
Launch the `verifier` (mode `full`; `specs-only` when this is a re-run after a rebase that left your patch unchanged): worktree, run id, base `origin/$T`, criteria with check notes, type (frontend/backend/both), dev-server + emulator commands and your ports (`$ORCH_PORT..$ORCH_PORT_END` — give the numbers), gate commands + log paths, test accounts, `$ART`, Repro.
- PASS → §7.
- FAILURE → fix at the root cause, then §3 → a §4 round (`re-review` with the failure as the open finding) → §5 → §6 again.
- BLOCKED, or a criterion it can't exercise here (needs a device, a real account, an owner-only step) → `QUESTION: can't exercise <Cn> — <why>; propose <how to check it / leave not-exercised>`, end your turn.

## 7. Evidence file, then READY
Write `$EV` (overwrite it on every READY). First line exactly `sha: <git rev-parse HEAD>`; then:
```
## Gates
- <command> → pass <n> / fail <n> (<baseline match | pre-existing: …>)
## Review
- rounds: <n>; reviewed sha: <the HEAD the last round reviewed>; last round: reviewer <PASS|BLOCK>, /code-review <clean|findings>, adversarial <PASS|n/a>
- accepted / rejected findings: <id — reason>  · advisories unfixed: <id>
## Tests/Playwright
- <Cn> — <command | viewport> → <result> (<screenshot/log path>)
## Not exercised
- <item — why | none>
```
Then `cmux agent message $COORD --from $OWNER "READY: $ID <full sha> evidence=$EV"`, append `step 7 READY <sha>` to `$PROG`, and end your turn. Leave your dev server running only if the brief says so; otherwise stop it now.

## 8. The manager's messages
- `ANSWER: …` → apply it and continue the step that asked.
- `FIX: …` that names only the evidence file or the READY (a missing section, a criterion with no result, a stale sha — no code defect) → redo the step it names (§6 for a missing result, else §7; a stale sha: §5 first) and send READY again; no review round.
- Any other `FIX: …` (after READY, or in reply to your `BLOCKED:`) → treat it as a blocking finding: fix, §3, a §4 round (`re-review` with the FIX text as the open finding; a new cap of 4 starts here, the repeat rule still applies), §5, §6, §7.
- `REBASE: …` **before READY** (you're anywhere in §1–§6) → finish the step you're on (a running round or verifier included), commit any WIP, run §5 in full (its conflict review round included), and **go back to the step you were on** — every remaining step still runs, on the new HEAD. It never skips §4 or §6, and a round with open findings stays open.
- `REBASE: …` **after READY** → §5. HEAD changed → §6 in `specs-only` (or `full` if the patch changed), §7 with the new sha.
- `STOP: …` → stop your processes (by PID/port), append `## Learned` if anything was learned, end your turn without a reply. The manager closes your workspace.
