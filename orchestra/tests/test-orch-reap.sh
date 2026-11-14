#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# reap / close kill only what orchestra can tie to itself: orphan listeners need a block orchestra handed out AND a
# process (or ancestor) running in that run's worktree; closing <run>-S1 never touches <run>-S10's (or api-docs's for
# api) processes or /tmp dirs. Isolated ORCH_HOME, private port range, stub cmux/caffeinate.
set -u; unset ORCH_CMUX  # the stub cmux on PATH only, even when run outside tests/run.sh
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-orch-reap.XXXXXX"); cd $S  # unique: suites run concurrently
PIDS=(); TMPS=()
trap 'for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill $p 2>/dev/null; done; for t in "${TMPS[@]:-}"; do [ -n "$t" ] && rm -rf "$t"; done; rm -rf $S' EXIT
export ORCH_HOME=$S/home; O=$ROOT/bin/orch
export ORCH_PORT_BASE=$((30000 + $$ % 300 * 100)) ORCH_PORT_SPAN=90  # private port range for this suite
mkdir -p $S/stub; for x in caffeinate xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; done
printf '#!/bin/sh\nexit 1\n' > $S/stub/cmux; chmod +x $S/stub/*; export PATH=$S/stub:$PATH  # never the real ones
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }
up(){ for i in $(seq 1 30); do nc -z 127.0.0.1 $1 2>/dev/null && return 0; sleep 0.2; done; return 1; }
down(){ for i in $(seq 1 30); do nc -z 127.0.0.1 $1 2>/dev/null || return 0; sleep 0.2; done; return 1; }
serve(){ # serve <dir> <port> → $SP: a plain http.server running in <dir>
  (cd "$1" && exec python3 -m http.server $2 --bind 127.0.0.1 >/dev/null 2>&1) & SP=$!; PIDS+=($SP); up $2; }
reap(){ $O reap --keep-sim >/dev/null 2>&1; }
alive(){ kill -0 $1 2>/dev/null; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main; cd $S
R=$($O new-run --repo $S/repo --title reap$$ --coordinator workspace:0); D=$ORCH_HOME/runs/$R
REPO=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["repo"])' $D/run.json)
WT=$REPO/.claude/worktrees; mkdir -p $WT/$R-S1 $WT/$R-S2 $WT/$R-integrate $S/elsewhere
B=$ORCH_PORT_BASE; NEVER=$((B + 85))  # the top block: allocation takes the lowest free one, and this suite takes < 8
wk(){ echo '{"run":"'$R'","slice":"'$1'","name":"'$R-$1'","status":"'$2'"}' > $D/workers/$1.json; }
wk S1 merged; wk S2 active

echo "-- orphan sweep: never allocated → survives"
serve $S/elsewhere $((B + 5)); A1=$SP
reap
ok "plain http.server on an unallocated port in the range survives reap (active run)" 'alive $A1 && up $((B + 5))'
kill $A1 2>/dev/null; wait $A1 2>/dev/null

echo "-- orphan sweep: allocated + released block, tied by worktree"
read PA PB < <($O ports --run $R --name job1); $O ports --run $R --name job1 --release >/dev/null
serve $S/elsewhere $PA; B1=$SP
serve $WT/$R-S1 $((PA + 1)); B2=$SP
serve $WT/$R-integrate $((PA + 2)); B3=$SP
(cd $WT/$R-S1 && exec sh -c "(cd / && exec python3 -m http.server $((PA + 3)) --bind 127.0.0.1 >/dev/null 2>&1); :") & B4=$!; PIDS+=($B4); up $((PA + 3))
serve $WT/$R-S2 $((PA + 4)); B5=$SP
reap
ok "a listener with no tie on a released orchestra block survives" 'alive $B1'
ok "a listener running in a finished worker's worktree of the block's run is swept" 'down $((PA + 1))'
ok "a listener whose parent runs in a finished worker's worktree is swept" 'down $((PA + 3))'
ok "a live worker's server on a released block of its run survives" 'alive $B5'
ok "the active run's integration server on a released block survives" 'alive $B3'
kill $(lsof -ti tcp:$((PA + 3)) 2>/dev/null) $B1 $B2 $B3 $B4 $B5 2>/dev/null; wait $B1 $B2 $B3 $B4 $B5 2>/dev/null

echo "-- blocks held before port history existed get a record"
HB=$((B + 70)); mkdir -p $ORCH_HOME/locks/ports/$HB; echo '{"owner":"'$R'-old"}' > $ORCH_HOME/locks/ports/$HB/owner.json
serve $S/elsewhere $NEVER; H1=$SP
$O reap --dry-run --keep-sim >/dev/null 2>&1
ok "reap --dry-run writes no port history" '[ ! -e $ORCH_HOME/state/port-history/$HB.json ]'
reap
ok "reap records a held block's owner (so a later orphan on it can be tied)" 'grep -q "\"$R-old\"" $ORCH_HOME/state/port-history/$HB.json'
kill $H1 2>/dev/null; wait $H1 2>/dev/null; rm -rf $ORCH_HOME/locks/ports/$HB

echo "-- S1 vs S10 and api vs api-docs on close"
wk S10 active; wk api merged; wk api-docs active
mkdir -p $WT/$R-S10 $WT/$R-api-docs
read JA JB < <($O ports --run $R --name api-e2e)   # a coordinator job whose name extends worker api's
for t in /tmp/$R-S1 /tmp/$R-S1-dd /tmp/$R-S1-cwd /tmp/$R-S10 /tmp/$R-S10-dd /tmp/$R-api-dd /tmp/$R-api-docs-dd /tmp/$R-api-e2e-cache; do
  mkdir -p $t; TMPS+=($t); done
hold(){ python3 -c 'import time; time.sleep(120)' "$1" & HP=$!; PIDS+=($HP); }
hold $WT/$R-S10/node_modules/.bin/vite; K10=$HP
hold /tmp/$R-S10-dd; K10T=$HP
hold $WT/$R-S1/node_modules/.bin/vite; K1=$HP
hold /tmp/$R-S1-dd; K1T=$HP
hold "$WT/$R-S1&&true"; K1A=$HP                                                  # shell metacharacter right after the path
(cd /tmp/$R-S1-cwd && exec python3 -c 'import time; time.sleep(120)') & K1C=$!; PIDS+=($K1C)   # cwd only, no path in argv
hold /tmp/$R-api-docs-dd; KAD=$HP
hold /tmp/$R-api-e2e-cache; KAE=$HP
sleep 0.3
$O close --run $R --slice S1 >/dev/null 2>&1
ok "closing S1 leaves a process running from S10's worktree" 'alive $K10'
ok "closing S1 leaves a process using /tmp/<run>-S10-dd" 'alive $K10T'
ok "closing S1 leaves S10's /tmp dirs" '[ -d /tmp/$R-S10 ] && [ -d /tmp/$R-S10-dd ]'
ok "closing S1 still kills a process running from S1's worktree" '! alive $K1'
ok "closing S1 still kills a process using /tmp/<run>-S1-dd" '! alive $K1T'
ok "closing S1 still kills a process naming S1's worktree before a shell '&'" '! alive $K1A'
ok "closing S1 kills a process whose cwd is /tmp/<run>-S1-* (resolved by lsof)" '! alive $K1C'
ok "closing S1 still removes /tmp/<run>-S1 and /tmp/<run>-S1-dd" '[ ! -e /tmp/$R-S1 ] && [ ! -e /tmp/$R-S1-dd ]'
$O close --run $R --slice api >/dev/null 2>&1
ok "closing api leaves api-docs's process" 'alive $KAD'
ok "closing api leaves api-docs's /tmp dir" '[ -d /tmp/$R-api-docs-dd ]'
ok "closing api leaves coordinator job api-e2e's process and /tmp dir" 'alive $KAE && [ -d /tmp/$R-api-e2e-cache ]'
ok "closing api removes /tmp/<run>-api-dd" '[ ! -e /tmp/$R-api-dd ]'
kill $K10 $K10T $KAD $KAE $K1 $K1T $K1A $K1C 2>/dev/null; wait $K10 $K10T $KAD $KAE $K1 $K1T $K1A $K1C 2>/dev/null

echo "-- no active run (only the orphan rule applies: no finished worker is cleaned)"
read EA EB < <($O ports --run $R --name job3)
R2=$($O new-run --repo $S/repo --title other$$ --coordinator workspace:0)
read QA QB < <($O ports --run $R2 --name job2)
$O end-run --run $R2 --status aborted --keep-sim >/dev/null 2>&1
$O end-run --run $R --status aborted --keep-sim >/dev/null 2>&1
LA=$((B + 60)); mkdir -p $ORCH_HOME/locks/ports/$LA; echo '{"owner":"ops-console"}' > $ORCH_HOME/locks/ports/$LA/owner.json
mkdir -p $WT/$R-S1 $WT/$R-integrate
ok "(the never-allocated block really never was)" '[ ! -e $ORCH_HOME/state/port-history/$((NEVER / 10 * 10)).json ]'
serve $S/elsewhere $NEVER; E1=$SP
serve $S/elsewhere $EA; E2=$SP
serve $WT/$R-S1 $((EA + 1)); E3=$SP
serve $WT/$R-integrate $((EA + 2)); E4=$SP
serve $WT/$R-S1 $((NEVER + 1)); E5=$SP
serve $WT/$R-S1 $QA; E6=$SP
serve $WT/$R-S1 $LA; E7=$SP
mkdir -p $ORCH_HOME/locks/ports/$EA; touch -t $(date -v-5M +%Y%m%d%H%M) $ORCH_HOME/locks/ports/$EA   # a dead taker's lock dir, no owner.json
reap
ok "plain http.server on an unallocated port in the range survives reap (no active run)" 'alive $E1'
ok "an untied listener on an ended run's block survives" 'alive $E2'
ok "a listener in an ended run's worktree on its old block is swept (even under a stale ownerless lock dir)" 'down $((EA + 1))'
ok "a listener in an ended run's integration worktree on its old block is swept" 'down $((EA + 2))'
ok "a server in a run worktree on a port orchestra never allocated survives" 'alive $E5'
ok "R's worktree server on a block only R2 was given survives" 'alive $E6'
ok "a tied listener on a live (ops-) owner's block survives" 'alive $E7'
kill $E1 $E2 $E3 $E4 $E5 $E6 $E7 2>/dev/null; wait $E1 $E2 $E3 $E4 $E5 $E6 $E7 2>/dev/null

echo; echo "PASSED $P  FAILED $F"; [ $F = 0 ]
