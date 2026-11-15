# Orchestra — how to use it

## Everyday use
In any repo, open a cmux chat (`claude` in the repo) and type `/new-task <task>`: it sizes the task S / M / L and spends tokens to match (S = an edit in the main checkout with lite review rounds, M = one worker, L = full orchestra). `/orchestrate <task>` (the L path) skips triage; `/orchestrate --resume <run>` continues a run from its `runs/<run>/HANDOFF.md`.

1. **Interview** — it asks ranked questions with a recommended answer each ("yes" accepts), suggests better ideas, and logs every decision.
2. **Spec** — EARS acceptance criteria, slices (file-owned, vertical, waves), deploy impact. You approve or change.
3. **Workers** — up to 3 at once, each its own cmux workspace in the coordinator's sidebar group (next to a live dashboard workspace), each a `claude -w` worktree with its own 10-port block (`$ORCH_PORT..$ORCH_PORT_END`). They write tests first, run gates, then **review rounds** (`skills/worker/SKILL.md` §4–5): fresh agents each round, picked by the slice's review tier (the tier table in §4 sets the agents and the round cap), fix every blocking finding, re-gate, repeat until a full round is clean; then the `verifier`. Same finding twice in a row → a question for you; the cap round still blocking → `oracle` → BLOCKED. Then rebase and push. The coordinator closes a finished worker's workspace (`orch close`).
4. **Updates when something happens** — worker reports, `orch-watch` events (dead, stalled ≥15 min, usage limit hit/resumed), or a 30-min heartbeat (also on demand: ask "status"). Usage-limited sessions resume themselves after the reset; `caffeinate` keeps the Mac awake while a run is active. Pushes to repos with `.github/workflows` get one `ci-monitor` PASS/FAIL line.
5. **Integration** (multi-slice) — whole-feature review + verification on a run branch, then one push to main. Final report: what shipped, what deployed, evidence, what wasn't exercised. Workers' `## Learned` notes are folded into the repo's project memory and checked with `memory-lint`.

## New app
Make an empty folder for the app and `cd` into it (e.g. `mkdir -p ~/code && mkdir ~/code/<name> && cd ~/code/<name>`; the second `mkdir` fails if the folder already exists), run `claude` (accept the trust prompt), describe the app. It asks name, private/public and stack, creates the GitHub repo, builds a scaffold slice first (typecheck, lint, tests, build, Playwright, repo `CLAUDE.md`), then the features on top.

## End-to-end test on a throwaway repo (nothing leaves your Mac)
```
~/.claude/orchestra/bin/make-demo-repo          # creates ~/orchestra-demo/app + opens it in cmux
~/.claude/orchestra/bin/make-demo-repo --no-launch [dir]   # only creates the repo (tests, verifiers)
```
Accept the folder-trust prompt once, then paste the suggested `/orchestrate …` task. Delete `~/orchestra-demo` afterwards.

## Commands you might use
| Command | What |
|---|---|
| `orch status` | all active runs + workers |
| `orch report --run <run>` | the status table, now |
| `orch-watch --run <run> [--once] [--timeout S]` | wait for the next `EVENT <kind> <slice> <detail>` (exit 3 = none) |
| `orch doctor --run <run> [--fix]` | dead workers, orphan locks (+ respawn command) |
| `orch locks --repo <path>` | who owns which files / the merge lock |
| `orch criteria-check --run <run>` | acceptance criteria status |
| `orch spawn --run <run> --slice <id> [--resume] [--native] [--all-mcp] [--dry-run]` | open a worker workspace (coordinator uses this); `--native` for an iOS Simulator slice (keeps cmux Computer Use), `--all-mcp` gives the worker every MCP server instead of only `worker-mcp.json`'s, `--dry-run` prints what it would run |
| `orch close --run <run> --slice <id>` | close a worker workspace + worktree, free its locks/ports |
| `orch reap [--run <run>] [--dry-run]` | kill/clean anything finished or dead still using memory (runs on every coordinator wake) |
| `orch gc [--ended-older-than 14d] [--dry-run]` | runs that ended long ago keep only spec, HANDOFF, criteria, plan and run.json; the rest (artifacts, logs, watch state) is deleted |
| `orch-sim acquire\|release --owner <o>` | per-owner iOS Simulator clone (native slices) |
| `memory-lint <memory dir>` | check a project memory dir (frontmatter, index, dups) |
| `orch end-run --run <run> --status aborted` | abandon a run — tears down all its workspaces, processes, worktrees |

State: `~/.claude/orchestra/runs/<run>/` (spec, criteria, briefs, progress, artifacts/screenshots).

## Guarantees (enforced by `hooks/push-guard.py`, not by prompts)
- A worker can push only as exactly `git push origin HEAD:<its branch>` (or `HEAD:refs/heads/<its branch>`; at most a `cd <its worktree> && ` before it; no options, prefixes, wrappers or redirections), only on top of the latest remote, only with gates + reviewer + verifier PASS recorded **on that exact commit**, and only holding the merge lock (taken in its own command). Force/delete pushes are denied in every plain spelling (see the guard header's known limits).
- Only the reviewer/verifier agents can record their own verdicts — workers can't self-certify.
- Workers only send tagged reports/questions to their own coordinator; they can't message other workers or drive other terminals.
- Outside orchestra worktrees (a worker's, or the coordinator's integration worktree), the guard never approves anything: it only denies or stays silent, so your own permission rules decide a normal `git commit` / `git push` (under conservative settings they prompt) — a push into an orchestra worktree from another session included. A change bound by `orch tier` is denied unless its checks pass (even then the guard doesn't approve it): tier S pushes only with gates + a lite reviewer PASS on that commit, tier M/L never ships from a main checkout (a worker ships it; then `orch tier --clear`). Force/delete pushes are denied in every plain spelling (see the guard header's known limits).

## Native + real-browser checks
- Slices marked **native** need committed Maestro flows, run on each owner's own Simulator clone (`orch-sim`), so native verifications run in parallel. Recipe: the repo's own (e.g. a project memory file), else `orchestra/references/ios.md`.
- **real-browser** checks (your own Chrome via Claude in Chrome, macOS device only) are used only by the coordinator at integration, for things that need a real signed-in session, under `orch resource-lock --name chrome`. Never a pass/fail gate on its own, never prod accounts.

## Manual chores (not code)
Console/web chores (store products, console settings, uploads) are not part of this repo: the coordinator does them itself at the right point in the run (with your own console-chores skill, if you have one), and owner-only steps (signatures, payments, final submit/publish) come back to you.

## Files
`~/.claude/skills/new-task/` (front door) · `skills/orchestrate/` (coordinator) · `skills/worker/` · `skills/{diagnosing-bugs,retro,writing-for-agents}/` · `agents/{reviewer,verifier,oracle,ci-monitor}.md` · `orchestra/bin/{orch,orch-watch,orch-sim,memory-lint,make-demo-repo}` · `orchestra/hooks/push-guard.py` · `orchestra/worker-mcp.json` · `statusline/statusline.py`
