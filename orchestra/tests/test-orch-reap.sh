#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# reap / close / end-run retry what didn't finish (no helper processes or port polls: the timing-bound checks
# live in test-orch-reap-timing.sh). Isolated ORCH_HOME, private port range, stub cmux/caffeinate.
set -u; unset ORCH_CMUX  # the stub cmux on PATH only, even when run outside tests/run.sh
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-orch-reap.XXXXXX"); cd $S  # unique: suites run concurrently
trap 'rm -rf $S' EXIT
export ORCH_HOME=$S/home; O=$ROOT/bin/orch
export ORCH_PORT_BASE=${ORCH_TEST_PORT_BASE:-$((30000 + $$ % 300 * 100))} ORCH_PORT_SPAN=90  # private port range for this suite
mkdir -p $S/stub; for x in caffeinate xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; done
printf '#!/bin/sh\nexit 1\n' > $S/stub/cmux; chmod +x $S/stub/*; export PATH=$S/stub:$PATH  # never the real ones
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }
reap(){ $O reap >/dev/null 2>&1; }
reapout(){ $O reap --dry-run 2>&1; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main; cd $S
R=$($O new-run --repo $S/repo --title reap$$ --coordinator workspace:0); D=$ORCH_HOME/runs/$R
REPO=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["repo"])' $D/run.json)
WT=$REPO/.claude/worktrees; mkdir -p $WT

echo "-- orch close whose cleanup didn't finish isn't marked cleaned, so reap retries it"
echo '{"run":"'$R'","slice":"C4","name":"'$R-C4'","status":"dead"}' > $D/workers/C4.json
mkdir -p $WT/$R-C4   # a dead worker (pane gone, tree kept for --resume) whose close can't remove the tree
cout=$($O close --run $R --slice C4 2>&1)
ok "closing a dead worker makes it finished (done), not dead, and says it isn't finished" 'grep -q "\"status\": *\"done\"" $D/workers/C4.json && ! grep -q cleaned $D/workers/C4.json && grep -q "not finished" <<< "$cout"'
rm -rf $WT/$R-C4; git -C $REPO worktree add -q --detach $WT/$R-C4
reap
ok "...so the next reap retries it in full (removes the tree) and marks it cleaned" '[ ! -d $WT/$R-C4 ] && grep -q cleaned $D/workers/C4.json'
echo '{"run":"'$R'","slice":"C5","name":"'$R-C5'","status":"done","finished":"2026-01-02T03:04:05"}' > $D/workers/C5.json
touch -t 202601020304 $D/workers/C5.json   # closed long ago; nothing of it is left (its close couldn't confirm)
reap
ok "a finished worker with nothing left is marked cleaned once (not re-cleaned every heartbeat)" 'grep -q "\"cleaned\": *\"2026-01-02T03:04:05\"" $D/workers/C5.json'
ok "...without counting as activity (its file keeps its old mtime)" '[ "$(stat -f %Sm -t %Y%m%d%H%M $D/workers/C5.json)" = 202601020304 ]'
echo '{"run":"'$R'","slice":"C3","name":"'$R-C3'","status":"active"}' > $D/workers/C3.json
git -C $REPO worktree add -q --detach $WT/$R-C3
$O close --run $R --slice C3 >/dev/null 2>&1
ok "a close that finished is marked cleaned at once" '[ ! -d $WT/$R-C3 ] && grep -q cleaned $D/workers/C3.json'
rm -f $D/workers/C?.json

echo "-- end-run whose cleanup didn't finish isn't marked cleaned, so reap --run retries it"
R3=$($O new-run --repo $S/repo --title endrun$$ --coordinator workspace:0); D3=$ORCH_HOME/runs/$R3
echo '{"run":"'$R3'","slice":"E1","name":"'$R3-E1'","status":"active"}' > $D3/workers/E1.json
echo '{"run":"'$R3'","slice":"E2","name":"'$R3-E2'","status":"active"}' > $D3/workers/E2.json
echo '{"run":"'$R3'","slice":"E3","name":"'$R3-E3'","status":"dead"}' > $D3/workers/E3.json
mkdir -p $WT/$R3-E1 $WT/$R3-E3; git -C $REPO worktree add -q --detach $WT/$R3-E2
eout=$($O end-run --run $R3 --status aborted 2>&1)
ok "end-run with a worktree it couldn't remove doesn't mark that worker cleaned" '[ -d $WT/$R3-E1 ] && ! grep -q cleaned $D3/workers/E1.json'
ok "...and says so, naming the retry" 'grep "NOT finished $R3-E1" <<< "$eout" | grep -q "orch reap --run $R3"'
ok "end-run makes a dead worker finished too (so a retry cleans it in full)" 'grep -q "\"status\": *\"aborted\"" $D3/workers/E3.json'
rm -rf $WT/$R3-E3; git -C $REPO worktree add -q --detach $WT/$R3-E3
ok "end-run marks a worker it fully cleaned as cleaned" '[ ! -d $WT/$R3-E2 ] && grep -q cleaned $D3/workers/E2.json'
ok "...and reap --run retries the unfinished one" 'grep -q "$R3-E1" <<< "$($O reap --run $R3 --dry-run 2>&1)"'
rm -rf $WT/$R3-E1; git -C $REPO worktree add -q --detach $WT/$R3-E1; $O reap --run $R3 >/dev/null 2>&1
ok "...then marks it cleaned" '[ ! -d $WT/$R3-E1 ] && grep -q cleaned $D3/workers/E1.json'
ok "...and the formerly dead one is removed in full and cleaned" '[ ! -d $WT/$R3-E3 ] && grep -q cleaned $D3/workers/E3.json'

echo; echo "PASSED $P  FAILED $F"; [ $F = 0 ]
