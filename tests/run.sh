#!/usr/bin/env bash
# Run every test suite (orchestra/tests/*.sh, then tests/test-*.sh) in isolation and report
# per-suite pass/fail counts. Exits non-zero if any suite fails.
#   usage: tests/run.sh [suite.sh ...]        (default: all suites)
# Suites run in parallel, up to ORCH_TEST_JOBS at once (default: the CPU count; ORCH_TEST_JOBS=1 runs
# them one by one); the timing-sensitive ones in SOLO (below) run afterwards, one at a time, alone.
# Each suite's output is buffered and the table is printed in suite order once all have finished.
# Each suite gets its own temp HOME and ORCH_HOME, a throwaway git identity, no inherited
# CMUX_*/ORCH_*/CLAUDE*/GIT_* variables, and stubs FIRST on PATH: `cmux` (a test must never reach the
# real one — it would open real workspaces) plus `caffeinate`, `osascript` (no real
# sleep blockers or UI scripting). A suite may still put its own stubs before these.
# It also gets ORCH_TEST_PORT_BASE: the first port of a 100-port block no other suite or run.sh copy holds.
# ORCH_PYTHON=<interpreter> (e.g. /usr/bin/python3, macOS's 3.9) runs every suite with that interpreter as `python3`:
# a shim first on PATH, so `python3 …`, `#!/usr/bin/env python3` scripts and hooks all resolve to it.
# A suite fails if it exits non-zero, prints any `FAIL` line, or prints no `ok` line at all.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Timing-sensitive suites: they assert on wall-clock windows, so they run alone after the parallel
# batch instead of sharing the CPU with it (their tolerances stay as they are):
#   test-watch.sh         orch-watch --timeout/--interval: elapsed time must fall in [2,6]s / ≤ 6s
#   test-orch-reap-timing.sh  close/reap read the argv/cwd of helpers given a 0.3s head start, and wait on
#                         listeners with 6s up/down polls (test-orch-reap.sh keeps the non-timing checks)
#   test-guard.sh         a hung or slow guard must answer within seconds: elapsed time ≤ 10s / ≤ 15s (its hook timeout is 60s)
# Only suites that were found or named are matched against this list, so a name here without a file is harmless.
SOLO=" test-watch.sh test-orch-reap-timing.sh test-guard.sh "
JOBS=${ORCH_TEST_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
case "$JOBS" in ''|*[!0-9]*|0) echo "run.sh: ORCH_TEST_JOBS must be a positive integer (got '$JOBS')"; exit 1 ;; esac
if [ $# -gt 0 ]; then
  SUITES=(); for a in "$@"; do  # absolute, since each suite runs from its own temp dir
    [ -f "$a" ] || { echo "run.sh: no such suite: $a"; exit 1; }
    SUITES+=("$(cd "$(dirname "$a")" && pwd)/$(basename "$a")"); done
else
  SUITES=(); for f in "${SUITES_DIR:-$ROOT/orchestra/tests}"/*.sh "${EXTRA_SUITES_DIR:-$ROOT/tests}"/test-*.sh; do
    [ -f "$f" ] && SUITES+=("$f"); done
fi
[ ${#SUITES[@]} -gt 0 ] || { echo "run.sh: no suites found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-run.XXXXXX")
running(){ local b; for b in "$TMP"/[0-9]*; do [ -f "$b/started" ] && [ ! -f "$b/rc" ] && echo "$b"; done; }
tree(){ local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; tree "$c"; done; }  # every descendant of a pid
alive(){ local p; for p; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
stop_all(){ # TERM every descendant of every running suite's wrapper (own-session helpers too), KILL what's left after 5s
  local b i j all=""; for b in $(running); do
    echo "run.sh: interrupted while running $(cat "$b/name"); its last lines:"; tail -5 "$b/out.log" 2>/dev/null | sed 's/^/    /'; done
  for j in $(jobs -p); do all="$all $(tree "$j")"; done
  [ -n "${all// }" ] || { wait 2>/dev/null; return; }
  kill -TERM $all 2>/dev/null
  for i in $(seq 1 50); do alive $all || break; sleep 0.1; done
  # KILL only what is still a descendant of a job now: a pid from the first pass that has exited may belong to
  # another process by now
  all=""; for j in $(jobs -p); do all="$all $(tree "$j")"; done
  [ -n "${all// }" ] && kill -KILL $all 2>/dev/null; wait 2>/dev/null; }
# Port blocks: each suite gets its own 100-port block as ORCH_TEST_PORT_BASE (suites use it for ORCH_PORT_BASE
# and their servers), claimed under PORT_LOCKS_DIR so concurrent run.sh copies never hand out the same one.
# Blocks stay below 49152, where macOS's ephemeral (outgoing) ports start. A block is held until this run ends.
# One whose owner pid is gone (or with no pid a minute after it was made) is taken over, one taker at a time
# (.take.<base>, itself dropped once a minute old), re-checked once that taker holds it.
PORT_LOCKS=${PORT_LOCKS_DIR:-/tmp/orchestra-test-ports}; mkdir -p "$PORT_LOCKS" 2>/dev/null; HELD=(); NOBLOCK=
old(){ [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }
stale(){ # stale <base> <owner read earlier>: the lock still names that owner, and that owner is gone
  local d=$PORT_LOCKS/$1; [ "$(cat "$d/pid" 2>/dev/null)" = "$2" ] || return 1
  if [ -n "$2" ]; then ! kill -0 "$2" 2>/dev/null; else old "$d"; fi; }
take_block(){ # take_block: sets PB to a free block's base port (30000..49000), or to "" if none is free
  local b o got t; PB=""; for ((b = 30000; b <= 49000; b += 100)); do
    got=; t=$PORT_LOCKS/.take.$b
    if mkdir "$PORT_LOCKS/$b" 2>/dev/null; then got=1
    else o=$(cat "$PORT_LOCKS/$b/pid" 2>/dev/null)
      if stale "$b" "$o"; then old "$t" && rmdir "$t" 2>/dev/null  # a taker that died mid-takeover
        if mkdir "$t" 2>/dev/null; then
          stale "$b" "$o" && rm -rf "$PORT_LOCKS/$b"; mkdir "$PORT_LOCKS/$b" 2>/dev/null && got=1; rmdir "$t"; fi; fi; fi
    [ -n "$got" ] && { echo $$ > "$PORT_LOCKS/$b/pid"; HELD+=("$b"); PB=$b; return; }
  done
  [ -n "$NOBLOCK" ] || echo "run.sh: no free port block under $PORT_LOCKS: suites fall back to their own port choice" >&2
  NOBLOCK=1; }
release(){ local b; for b in ${HELD[@]+"${HELD[@]}"}; do [ "$(cat "$PORT_LOCKS/$b/pid" 2>/dev/null)" = $$ ] && rm -rf "$PORT_LOCKS/$b"; done; }
trap 'rm -rf "$TMP"; release' EXIT
trap 'echo "run.sh: interrupted, stopping running suites"; stop_all; exit 130' INT TERM HUP
PYSHIM=""
if [ -n "${ORCH_PYTHON:-}" ]; then
  PY=$(command -v "$ORCH_PYTHON") || { echo "run.sh: ORCH_PYTHON=$ORCH_PYTHON not found"; exit 1; }
  case "$PY" in /*) ;; *) PY="$PWD/$PY" ;; esac  # each suite runs in its own dir: a relative path wouldn't resolve
  mkdir -p "$TMP/pyshim"; printf '#!/bin/bash\nexec %q "$@"\n' "$PY" > "$TMP/pyshim/python3"; chmod +x "$TMP/pyshim/python3"
  PYSHIM="$TMP/pyshim:"
fi
echo "run.sh: python3 = $(PATH="$PYSHIM$PATH" python3 -c 'import sys; print(sys.executable, "%d.%d.%d" % sys.version_info[:3])')"

box_of(){ local n; n=$(basename "${SUITES[$1]}"); echo "$TMP/$1-${n%.sh}"; }  # by index: two suites may share a name
start(){ # start <index>: run that suite in the background in its own box; its exit code lands in $box/rc
  local suite=${SUITES[$1]} box; box=$(box_of "$1"); mkdir -p "$box/home" "$box/orch" "$box/bin"
  # Stub cmux: records its args, prints nothing, exits 1 — the same as "cmux not running".
  printf '#!/bin/sh\necho "$*" >> "%s/cmux-calls.log"\nexit 1\n' "$box" > "$box/bin/cmux"
  # Stub caffeinate/osascript: record their args and exit 0 at once (a real `caffeinate -is`
  # started by `orch new-run` would outlive the suite and keep the machine awake).
  for x in caffeinate osascript; do
    printf '#!/bin/sh\necho "$*" >> "%s/%s-calls.log"\nexit 0\n' "$box" "$x" > "$box/bin/$x"; done
  chmod +x "$box/bin/"*
  printf '[user]\n\tname = orchestra-test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$box/home/.gitconfig"
  basename "$suite" > "$box/name"; take_block
  ( : > "$box/started"; cd "$box" || exit 1
    for v in $(env | grep -oE '^(CMUX|ORCH|CLAUDE|GIT_)[A-Za-z0-9_]*=' | tr -d =); do unset "$v"; done
    # perl puts INT/QUIT back to default: bash starts background jobs with them ignored, and that survives exec.
    # The suite stays in run.sh's process group, so a signal to the whole group (Ctrl-C, a harness kill) reaches it.
    perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV or exit 127' env HOME="$box/home" ORCH_HOME="$box/orch" ORCH_TEST_PORT_BASE="$PB" \
      PATH="$box/bin:$PYSHIM$PATH" GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1 XDG_CONFIG_HOME="$box/home/.config" \
      bash "$suite" < /dev/null
    echo $? > "$box/rc" ) > "$box/out.log" 2>&1 &
}
PAR=(); SER=()
for i in "${!SUITES[@]}"; do case "$SOLO" in *" $(basename "${SUITES[$i]}") "*) SER+=("$i") ;; *) PAR+=("$i") ;; esac; done
for i in ${PAR[@]+"${PAR[@]}"}; do
  while [ "$(jobs -pr | wc -l)" -ge "$JOBS" ]; do sleep 0.1; done
  start "$i"; done
wait
for i in ${SER[@]+"${SER[@]}"}; do start "$i"; wait; done

FAILED=(); TP=0; TF=0
printf '%-28s %6s %6s  %s\n' SUITE PASS FAIL RESULT
for i in "${!SUITES[@]}"; do
  name=$(basename "${SUITES[$i]}"); box=$(box_of "$i")
  rc=$(cat "$box/rc" 2>/dev/null || echo 1)
  p=$(grep -cE '^ok ' "$box/out.log"); f=$(grep -cE '^FAIL' "$box/out.log")
  TP=$((TP + p)); TF=$((TF + f))
  if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$p" -gt 0 ]; then res=ok
  elif [ "$rc" -eq 0 ] && [ "$f" -eq 0 ]; then res="FAILED (no ok lines)"; FAILED+=("$name")
  else res="FAILED (exit $rc)"; FAILED+=("$name"); fi
  printf '%-28s %6s %6s  %s\n' "$name" "$p" "$f" "$res"
  if [ "$res" != ok ]; then grep -E '^FAIL' "$box/out.log" | head -20 | sed 's/^/    /'
    [ "$f" -eq 0 ] && tail -15 "$box/out.log" | sed 's/^/    /'; fi
done
printf '%-28s %6s %6s\n' TOTAL "$TP" "$TF"
if [ ${#FAILED[@]} -gt 0 ]; then echo "run.sh: ${#FAILED[@]} suite(s) failed: ${FAILED[*]}"; exit 1; fi
echo "run.sh: all ${#SUITES[@]} suites passed"
