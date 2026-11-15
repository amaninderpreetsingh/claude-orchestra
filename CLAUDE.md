# claude-orchestra — contributor notes

This repo is a public, generic Claude Code workflow. Its layout **mirrors `~/.claude`**: every file lives at the path it is installed to (`skills/<name>/`, `agents/<name>.md`, `orchestra/{bin,hooks,tests}/`, `statusline/`), so installing is a copy. Keep it that way — a new skill goes in `skills/<name>/SKILL.md`, never in a repo-only folder. Repo-only files: `install.sh`, `uninstall.sh`, `settings.example.json` (merged into `settings.json`, never copied), `CLAUDE.template.md` (the block appended to `~/.claude/CLAUDE.md`), `docs/`, `scripts/` (gates, `leak-patterns.txt`), `tests/` (`run.sh`, `test-gates.sh`, `test-install.sh`, `test-statusline.sh`), `.github/`, `.gitignore`, `LICENSE`, `NOTICE`, this file, `README.md`.

## Gates (all must pass before a push; CI runs the same on macos-latest)
```
bash scripts/lint.sh          # bash -n on shell scripts, python compile, JSON validity
bash tests/run.sh             # every orchestra/tests/*.sh + tests/test-*.sh, isolated
ORCH_PYTHON=/usr/bin/python3 bash tests/run.sh   # the same suites on macOS's own python3 (3.9, the floor)
bash scripts/leak-check.sh    # personal identifiers / machine paths in files, names, history
gitleaks git --no-banner .    # secrets in history
gitleaks dir --no-banner .    # secrets in the working tree
```
CI runs both test runs: the default `python3` in the gates job, `/usr/bin/python3` in the python39 job. `tests/run.sh` runs suites in parallel by default (up to the CPU count; `ORCH_TEST_JOBS=<n>` caps it, `ORCH_TEST_JOBS=1` runs them one at a time), then the timing-sensitive suites listed in its `SOLO` one at a time, alone. It buffers each suite's output, prints per-suite pass/fail counts in suite order and exits non-zero if any suite fails. A new suite that asserts on wall-clock windows goes in `SOLO` (with the reason); never widen its tolerance instead. Each suite gets its own 100-port block as `ORCH_TEST_PORT_BASE` (locked under `/tmp/orchestra-test-ports`, so concurrent runs never share one): a suite that binds ports or sets `ORCH_PORT_BASE` takes it from there, e.g. `${ORCH_TEST_PORT_BASE:-<fallback>}`. Run one suite with `bash tests/run.sh orchestra/tests/test-orch.sh`.

## Rules
- **No personal data, ever** — names, emails, team/bundle/device ids, app names, absolute home paths (write `~` or `$HOME`), Homebrew paths. `scripts/leak-check.sh` enforces it on every tracked file (binaries as text), file name, commit author/committer, commit message, tag and past patch (merges included). Commit with a GitHub noreply email (or a reserved test domain in fixtures); GitHub's own `noreply@github.com`, `[bot]` noreply identities and `Co-authored-by:`-style trailers follow the same identity policy. The repo owner's public GitHub handle is never a leak, so the list holds specific personal forms (full or joined name, email local part), never a token that matches inside the handle. In CI on pull requests `LEAK_REV` points the history scan at the PR head instead of GitHub's synthetic merge. Its identifier list is stored as sha256 hashes in `scripts/leak-patterns.txt` so the list isn't readable at a glance (hashing deters, it isn't secrecy); add a new entry as a hash (instructions in that file), never as plain text. A hit in history means the commit must be rewritten before it is pushed.
- **Tests never reach the real cmux.** `tests/run.sh` puts stubs first on PATH — `cmux` (exits 1) and `caffeinate`/`xcrun`/`osascript` (exit 0), each logging its calls — drops inherited `CMUX_*`/`ORCH_*`/`CLAUDE*` variables, and gives each suite its own `HOME` and `ORCH_HOME`. A suite that needs cmux behaviour ships its own stub (see `orchestra/tests/test-orch.sh`); never call real `cmux`, `caffeinate`, `xcrun`/simulators or `osascript` from a test.
- Each suite prints `ok   <name>` / `FAIL <name>` per assertion and exits non-zero on any failure; the runner counts those lines and fails a suite that prints no `ok` line.
- A new gate or rule must be shown failing on a planted error in `tests/test-gates.sh` (with fake identifiers only).
- Never skip, delete or loosen a test to make a gate pass.
