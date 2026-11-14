#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Dashboard sections, criteria-add, coordinator job ports vs reap, spawn trust check (isolated ORCH_HOME).
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-dash.XXXXXX"); trap 'rm -rf $S' EXIT; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch
export ORCH_PORT_BASE=$((30000 + $$ % 300 * 100)) ORCH_PORT_SPAN=90  # private port range: suites never share a block
mkdir -p $S/stub; for x in caffeinate xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; chmod +x $S/stub/$x; done; export PATH=$S/stub:$PATH  # never the real caffeinate/simulators
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main
RUN=$($O new-run --repo $S/repo --title dash --coordinator workspace:0); D=$ORCH_HOME/runs/$RUN

# plan: S1 merged, S2 active at step 4, S3 queued behind S2
cat > $S/plan.json <<'EOF'
[{"id":"S1","title":"scaffold","wave":1,"depends":[]},
 {"id":"S2","title":"tasks","wave":2,"depends":["S1"]},
 {"id":"S3","title":"fixes","wave":3,"depends":["S2"],"goal":"keep valid tasks"}]
EOF
$O note --run $RUN --plan $S/plan.json >/dev/null
mkdir -p $D/workers $D/slices
for s in S1 S2 S3; do echo "# $s" > $D/slices/$s.md; done
echo '{"run":"'$RUN'","slice":"S1","name":"'$RUN'-S1","status":"merged"}' > $D/workers/S1.json
echo '{"run":"'$RUN'","slice":"S2","name":"'$RUN'-S2","status":"active","workspace":"surface:999999"}' > $D/workers/S2.json
printf '22:10 step 6 pushed abc1234 to orch/x\n' > $D/slices/S1.progress.md
printf '22:50 step 3 gates ok\n22:54 step 4 reviewers launched\n' > $D/slices/S2.progress.md
$O note --run $RUN --wait "Ship now or fix first?" >/dev/null
$O note --run $RUN --wait "Ship now or fix first?" >/dev/null   # deduplicated
out=$($O dash --run $RUN --once | sed 's/\x1b\[[0-9;]*m//g')
ok "five sections in order" '[ "$(echo "$out" | grep -oE "^(NEEDS YOU|WAITING|WORKING|PENDING|DONE)" | tr "\n" " ")" = "NEEDS YOU WAITING WORKING PENDING DONE " ]'
ok "needs-you deduplicated" 'echo "$out" | grep -q "NEEDS YOU (1)"'
ok "S3 waits for S2" 'echo "$out" | grep -E "S3 fixes.*← S2 merged" -q'
ok "S2 waits on its reviewers" 'echo "$out" | grep -q "← its reviewer + verifier"'
ok "S2 working at step 4" 'echo "$out" | grep -E "S2 tasks +step 4 review" -q'
ok "pending marks current step" 'echo "$out" | grep -E "S2  review \+ verify.*● now" -q'
ok "pending lists queued slice with goal" 'echo "$out" | grep -q "S3  fixes: keep valid tasks — all 6 steps"'
ok "pending lists run finish" 'echo "$out" | grep -q "run push to main"'
ok "done shows S1 with sha" 'echo "$out" | grep -E "✓ S1 scaffold +abc1234" -q'
$O note --run $RUN --finish 3 >/dev/null
out=$($O dash --run $RUN --once | sed 's/\x1b\[[0-9;]*m//g')
ok "finish step shows as working" 'echo "$out" | grep -E "run finish +final review" -q'
ok "earlier finish steps done" 'echo "$out" | grep -q "✓ run all checks"'
python3 -c "import json,time;json.dump({'next':time.time()-600},open('$D/ticks.json','w'))"   # last tick 10 min ago
m=$($O dash --run $RUN --once | sed 's/\x1b\[[0-9;]*m//g' | sed -nE 's/.*next tick [0-9:]+ \(([0-9]+)m.*/\1/p')
ok "next tick projected on the 30-min heartbeat" '[ "${m:-0}" -ge 15 ] && [ "$m" -le 20 ]'

# criteria-add keeps existing results
echo '[{"id":"C1","text":"one"}]' > $S/c1.json; $O criteria-init --run $RUN --file $S/c1.json >/dev/null
python3 - $D/criteria.json <<'PY'
import json,sys; p=sys.argv[1]; c=json.load(open(p)); c[0].update(status="pass",sha="abc"); json.dump(c,open(p,"w"))
PY
echo '[{"id":"C2","text":"two"}]' > $S/c2.json; $O criteria-add --run $RUN --file $S/c2.json >/dev/null
ok "criteria-add keeps C1 pass" 'python3 -c "import json;c=json.load(open(\"$D/criteria.json\"));assert [x[\"status\"] for x in c]==[\"pass\",\"pending\"]"'
ok "criteria-add refuses duplicate id" '! $O criteria-add --run $RUN --file $S/c2.json >/dev/null 2>&1'

# reap leaves a listener orchestra never handed a port to (the orphan rule itself: test-orch-reap.sh)
python3 -m http.server $ORCH_PORT_BASE --bind 127.0.0.1 >/dev/null 2>&1 & ORPH=$!
for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $ORCH_PORT_BASE 2>/dev/null && break; sleep 0.3; done
$O reap --run $RUN >/dev/null 2>&1
ok "reap leaves an unallocated listener in its own ORCH_PORT_BASE range" 'kill -0 $ORPH 2>/dev/null'
kill $ORPH 2>/dev/null; wait $ORPH 2>/dev/null

# coordinator job ports survive reap; released by end-run
read PA PB < <($O ports --run $RUN --name integrate-verifier)
python3 -m http.server $PA --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $PA 2>/dev/null && break; sleep 0.3; done
$O reap --run $RUN >/dev/null 2>&1
ok "reap keeps server on an orch ports block" 'kill -0 $SRV 2>/dev/null'
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
ok "ports block is registered" '[ -d $ORCH_HOME/locks/ports/$PA ]'
$O end-run --run $RUN --status aborted >/dev/null 2>&1
ok "end-run releases job port blocks" '[ ! -d $ORCH_HOME/locks/ports/$PA ]'

# spawn refuses an untrusted folder and asks the user
RUN2=$($O new-run --repo $S/repo --title trust --coordinator workspace:0); D2=$ORCH_HOME/runs/$RUN2
mkdir -p $D2/slices; echo "# b" > $D2/slices/A.md
ok "spawn refused in untrusted folder" '! $O spawn --run $RUN2 --slice A >/dev/null 2>&1'
ok "trust step added to NEEDS YOU" 'grep -q "Trust this folder" $D2/waiting.json'
ok "no worker registered" '[ ! -f $D2/workers/A.json ]'
$O end-run --run $RUN2 --status aborted >/dev/null 2>&1

echo "PASSED $P FAILED $F"; [ $F = 0 ]
