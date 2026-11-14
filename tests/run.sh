#!/usr/bin/env bash
# Run every test suite (orchestra/tests/*.sh, then tests/test-*.sh) in isolation and report
# per-suite pass/fail counts. Exits non-zero if any suite fails.
#   usage: tests/run.sh [suite.sh ...]        (default: all suites)
# Each suite gets its own temp HOME and ORCH_HOME, a throwaway git identity, no inherited
# CMUX_*/ORCH_*/CLAUDE*/GIT_* variables, and stubs FIRST on PATH: `cmux` (a test must never reach the
# real one — it would open real workspaces) plus `caffeinate`, `xcrun`, `osascript` (no real
# sleep blockers, simulators or UI scripting). A suite may still put its own stubs before these.
# ORCH_PYTHON=<interpreter> (e.g. /usr/bin/python3, macOS's 3.9) runs every suite with that interpreter as `python3`:
# a shim first on PATH, so `python3 …`, `#!/usr/bin/env python3` scripts and hooks all resolve to it.
# A suite fails if it exits non-zero, prints any `FAIL` line, or prints no `ok` line at all.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -gt 0 ]; then
  SUITES=(); for a in "$@"; do  # absolute, since each suite runs from its own temp dir
    [ -f "$a" ] || { echo "run.sh: no such suite: $a"; exit 1; }
    SUITES+=("$(cd "$(dirname "$a")" && pwd)/$(basename "$a")"); done
else
  SUITES=(); for f in "${SUITES_DIR:-$ROOT/orchestra/tests}"/*.sh "${EXTRA_SUITES_DIR:-$ROOT/tests}"/test-*.sh; do
    [ -f "$f" ] && SUITES+=("$f"); done
fi
[ ${#SUITES[@]} -gt 0 ] || { echo "run.sh: no suites found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-run.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
PYSHIM=""
if [ -n "${ORCH_PYTHON:-}" ]; then
  PY=$(command -v "$ORCH_PYTHON") || { echo "run.sh: ORCH_PYTHON=$ORCH_PYTHON not found"; exit 1; }
  case "$PY" in /*) ;; *) PY="$PWD/$PY" ;; esac  # each suite runs in its own dir: a relative path wouldn't resolve
  mkdir -p "$TMP/pyshim"; printf '#!/bin/bash\nexec %q "$@"\n' "$PY" > "$TMP/pyshim/python3"; chmod +x "$TMP/pyshim/python3"
  PYSHIM="$TMP/pyshim:"
fi
echo "run.sh: python3 = $(PATH="$PYSHIM$PATH" python3 -c 'import sys; print(sys.executable, "%d.%d.%d" % sys.version_info[:3])')"
FAILED=(); TP=0; TF=0
printf '%-28s %6s %6s  %s\n' SUITE PASS FAIL RESULT
for suite in "${SUITES[@]}"; do
  name=$(basename "$suite"); box="$TMP/${name%.sh}"; mkdir -p "$box/home" "$box/orch" "$box/bin"
  # Stub cmux: records its args, prints nothing, exits 1 — the same as "cmux not running".
  printf '#!/bin/sh\necho "$*" >> "%s/cmux-calls.log"\nexit 1\n' "$box" > "$box/bin/cmux"
  # Stub caffeinate/xcrun/osascript: record their args and exit 0 at once (a real `caffeinate -is`
  # started by `orch new-run` would outlive the suite and keep the machine awake).
  for x in caffeinate xcrun osascript; do
    printf '#!/bin/sh\necho "$*" >> "%s/%s-calls.log"\nexit 0\n' "$box" "$x" > "$box/bin/$x"; done
  chmod +x "$box/bin/"*
  printf '[user]\n\tname = orchestra-test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$box/home/.gitconfig"
  ( cd "$box" || exit 1
    for v in $(env | grep -oE '^(CMUX|ORCH|CLAUDE|GIT_)[A-Za-z0-9_]*=' | tr -d =); do unset "$v"; done
    exec env HOME="$box/home" ORCH_HOME="$box/orch" PATH="$box/bin:$PYSHIM$PATH" \
      GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1 XDG_CONFIG_HOME="$box/home/.config" bash "$suite" ) > "$box/out.log" 2>&1
  rc=$?
  p=$(grep -cE '^ok ' "$box/out.log"); f=$(grep -cE '^FAIL' "$box/out.log")
  TP=$((TP + p)); TF=$((TF + f))
  if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$p" -gt 0 ]; then res=ok
  elif [ $rc -eq 0 ] && [ "$f" -eq 0 ]; then res="FAILED (no ok lines)"; FAILED+=("$name")
  else res="FAILED (exit $rc)"; FAILED+=("$name"); fi
  printf '%-28s %6s %6s  %s\n' "$name" "$p" "$f" "$res"
  if [ "$res" != ok ]; then grep -E '^FAIL' "$box/out.log" | head -20 | sed 's/^/    /'
    [ "$f" -eq 0 ] && tail -15 "$box/out.log" | sed 's/^/    /'; fi
done
printf '%-28s %6s %6s\n' TOTAL "$TP" "$TF"
if [ ${#FAILED[@]} -gt 0 ]; then echo "run.sh: ${#FAILED[@]} suite(s) failed: ${FAILED[*]}"; exit 1; fi
echo "run.sh: all ${#SUITES[@]} suites passed"
