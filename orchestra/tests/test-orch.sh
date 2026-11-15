#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Scenario tests for orch (isolated ORCH_HOME, local bare origin); push-guard rules: test-guard.sh.
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-orch.XXXXXX"); trap 'for c in $(cat $S/caff.log 2>/dev/null); do kill $c 2>/dev/null; done; rm -rf $S' EXIT; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch
export ORCH_PORT_BASE=${ORCH_TEST_PORT_BASE:-$((30000 + $$ % 300 * 100))} ORCH_PORT_SPAN=90  # private port range: suites never share a block
# fakes on PATH: caffeinate logs its pid and idles; cmux (spawn tests only) logs args, answers from $S/groups.json
mkdir -p $S/stub $S/cmuxstub; export CAFF_LOG=$S/caff.log CMUX_LOG=$S/cmux.log
printf '#!/bin/sh\ntrap '"'"'kill $! 2>/dev/null; exit'"'"' TERM\necho $$ >> "$CAFF_LOG"\nsleep 120 & wait\n' > $S/stub/caffeinate  # trap first: no orphan sleep
cat > $S/cmuxstub/cmux <<'EOF'
#!/bin/sh
echo "$*" >> "$CMUX_LOG"
case "$1 $2" in
  "identify --json") echo '{"caller":{}}';;
  "tree --all"*) echo '{"windows":[{"workspaces":[{"ref":"workspace:5","id":"W5","panes":[{"ref":"surface:51","id":"S51"}]}]}]}';;
  "new-workspace "*) echo "OK workspace:5";;
  "workspace-group list") cat "$(dirname "$CMUX_LOG")/groups.json" 2>/dev/null || echo '{"groups":[]}';;
  "workspace-group create") echo "OK workspace_group:9";;
esac
EOF
chmod +x $S/stub/caffeinate $S/cmuxstub/cmux; export PATH=$S/stub:$PATH ORCH_CAFFEINATE=$S/stub/caffeinate  # an isolated ORCH_HOME holds none otherwise
PASS=0; FAIL=0
ok(){ if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   cmd: ${*:2:3}"; else FAIL=$((FAIL+1)); echo "FAIL cmd should succeed: $*"; "$@"; fi; }
no(){ if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL cmd should fail: $*"; else PASS=$((PASS+1)); echo "ok   refused: ${*:2:3}"; fi; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo 'echo ok' > gate.sh; echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main
R=$S/repo; RUN=$($O new-run --repo $R --title t$$ --coordinator workspace:0); ok $O run-branch --run $RUN
git fetch -q; git worktree add -q .claude/worktrees/w1 -b w1 origin/orch/$RUN
W1=$R/.claude/worktrees/w1
ok $O register --worktree $W1 --run $RUN --slice s1

echo "-- register: owner record, --sync only on a fresh worktree"
OR=$(git -C $W1 rev-parse --path-format=absolute --git-dir)/orchestra-owner.json
ok python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); assert (o["owner"], o["run"], o["slice"], o["target"]) == (sys.argv[2], sys.argv[3], "s1", sys.argv[4]) and "risky" not in o, o' $OR $RUN-s1 $RUN orch/$RUN
git checkout -q -b adv origin/main; echo n > n.txt; git add n.txt; git commit -qm adv; git push -q origin HEAD:orch/$RUN; git checkout -q main
git worktree add -q .claude/worktrees/w3 -b w3 origin/main; W3=$R/.claude/worktrees/w3
ok $O register --worktree $W3 --run $RUN --slice s3 --sync
ok test "$(git -C $W3 rev-parse HEAD)" = "$(git rev-parse adv)"                    # moved to origin/orch/<run>
echo dirty > $W3/a.txt; no $O register --worktree $W3 --run $RUN --slice s3 --sync  # uncommitted edits: refused
ok test "$(cat $W3/a.txt)" = dirty; git -C $W3 checkout -q a.txt
echo o > $W3/o.txt; git -C $W3 add o.txt; git -C $W3 commit -qm own; OWN=$(git -C $W3 rev-parse HEAD)
no $O register --worktree $W3 --run $RUN --slice s3 --sync                            # a commit of its own: refused
ok test "$(git -C $W3 rev-parse HEAD)" = "$OWN"

echo "-- removed commands and flags are usage errors"
usage(){ # usage <argparse message> <orch args...>: exit 2 with that message, nothing done
  local want=$1; shift; out=$($O "$@" 2>&1); rc=$?
  if [ $rc = 2 ] && grep -q "$want" <<< "$out"; then PASS=$((PASS+1)); echo "ok   orch $* → usage error"
  else FAIL=$((FAIL+1)); echo "FAIL orch $*: want exit 2 + '$want', got $rc :: $out"; fi; }
for c in tier gates verdict criterion gates-ok merge-lock merge-unlock resource-lock resource-unlock; do usage "invalid choice: '$c'" $c; done
usage "invalid choice: 'gates'" gates --worktree $W1 --cmd true
usage "invalid choice: 'merge-lock'" merge-lock --repo $R --owner $RUN-s1 --wait 0
ok test ! -e $ORCH_HOME/locks/*/merge                                                 # ...and took nothing
usage "unrecognized arguments: --native" spawn --run $RUN --slice s1 --native --dry-run
usage "unrecognized arguments: --keep-sim" reap --keep-sim
usage "unrecognized arguments: --keep-sim" end-run --run $RUN --keep-sim
usage "unrecognized arguments: --risky" register --worktree $W1 --run $RUN --slice s1 --risky
ok test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' $ORCH_HOME/runs/$RUN/run.json)" = active   # end-run --keep-sim ended nothing
HELP=$($O -h 2>&1)
no grep -qwE 'tier|gates|verdict|criterion|gates-ok|merge-lock|merge-unlock|resource-lock|resource-unlock|orch-sim|native' <<< "$HELP"
ok grep -q 'register (--sync)' <<< "$HELP"

echo "-- spawn: workers get the lean MCP set unless --all-mcp (no native exception)"
printf '# L\n' > $ORCH_HOME/runs/$RUN/slices/L.md; echo '{"mcpServers":{}}' > $ORCH_HOME/worker-mcp.json
out=$(ORCH_SKIP_TRUST=1 $O spawn --run $RUN --slice L --dry-run 2>&1); ok grep -qE -- "--strict-mcp-config --mcp-config [^ ]*/home/worker-mcp.json " <<< "$out"
out=$(ORCH_SKIP_TRUST=1 $O spawn --run $RUN --slice L --dry-run --all-mcp 2>&1); no grep -q -- "--strict-mcp-config" <<< "$out"
rm $ORCH_HOME/worker-mcp.json $ORCH_HOME/runs/$RUN/slices/L.md

echo "-- criteria + end-run"
echo '[{"id":"C1","text":"x"},{"id":"C2","text":"y"}]' > $S/c.json; ok $O criteria-init --run $RUN --file $S/c.json
no $O criteria-check --run $RUN                                                       # both pending
crit(){ python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); [x.update(status=sys.argv[3], sha=sys.argv[4]) for x in c if x["id"] in sys.argv[2].split(",")]; json.dump(c,open(p,"w"))' $ORCH_HOME/runs/$RUN/criteria.json "$@"; }
crit C1,C2 pass abc123; ok $O criteria-check --run $RUN; ok $O criteria-check --run $RUN --sha abc123
no $O criteria-check --run $RUN --sha def456                                          # passed on another commit
crit C2 pending ""
ok $O end-run --run $RUN                                                              # a pending criterion no longer blocks end-run
ok test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' $ORCH_HOME/runs/$RUN/run.json)" = done
git fetch -q --prune; git branch -r | grep -q "orch/$RUN" && { FAIL=$((FAIL+1)); echo "FAIL run branch not deleted"; } || { PASS=$((PASS+1)); echo "ok   run branch deleted"; }

echo "-- caffeinate held while any run is active"
CP=$ORCH_HOME/state/caffeinate.pid; alive(){ [ -f $CP ] && kill -0 "$(cat $CP)" 2>/dev/null; }
ok test "$(wc -l < $CAFF_LOG | tr -d ' ')" = 1                    # new-run at the top started exactly one
ok test ! -f $CP                                                  # ...and the last end-run released it
CA=$($O new-run --repo $R --title ca$$ --coordinator workspace:0); ok alive
CB=$($O new-run --repo $R --title cb$$ --coordinator workspace:0)
ok test "$(wc -l < $CAFF_LOG | tr -d ' ')" = 2                    # second run reuses the held one
ok $O end-run --run $CA --status aborted; ok alive    # CB still active
CPID=$(cat $CP); ok $O end-run --run $CB --status aborted
no alive; no kill -0 $CPID
echo 99999999 > $CP; CC=$($O new-run --repo $R --title cc$$ --coordinator workspace:0); ok alive   # stale pid → new one
python3 - $ORCH_HOME/runs/$CC/run.json <<'PY'
import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["status"]="aborted"; json.dump(r,open(p,"w"))
PY
CPID=$(cat $CP); ok $O reap; no alive; no kill -0 $CPID   # reap with no active run releases it

echo "-- spawn: --model + coordinator-anchored group"
SP=$($O new-run --repo $R --title sp$$ --coordinator surface:30 --coordinator-workspace workspace:3); D=$ORCH_HOME/runs/$SP
printf '# A\n- RUN: x\n' > $D/slices/A.md; printf '# B\n- MODEL: sonnet\n' > $D/slices/B.md
cat > $S/groups.json <<'EOF'
{"groups":[{"ref":"workspace_group:1","anchor_workspace_ref":"workspace:2","member_workspace_refs":["workspace:2","workspace:3"]}]}
EOF
: > $CMUX_LOG; export ORCH_SKIP_TRUST=1
ok env PATH=$S/cmuxstub:$PATH $O spawn --run $SP --slice A
WL=$(grep -- '/worker' $CMUX_LOG)
ok grep -q -- "--model opus " <<< "$WL"
ok grep -q -- "workspace-group remove --workspace workspace:3" $CMUX_LOG        # coordinator was a non-anchor member
ok grep -q -- "workspace-group create .*--from workspace:3 --idempotency-key $SP" $CMUX_LOG
ok grep -q -- "--group workspace_group:9" <<< "$WL"
no grep -q -- "--group workspace_group:1" $CMUX_LOG
cat > $S/groups.json <<'EOF'
{"groups":[{"ref":"workspace_group:7","anchor_workspace_ref":"workspace:3","member_workspace_refs":["workspace:3","workspace:5"]}]}
EOF
: > $CMUX_LOG; ok env PATH=$S/cmuxstub:$PATH $O spawn --run $SP --slice B
WL=$(grep -- '/worker' $CMUX_LOG)
ok grep -q -- "--model sonnet " <<< "$WL"; no grep -q -- "--model opus" <<< "$WL"   # brief MODEL: overrides
ok grep -q -- "--group workspace_group:7" <<< "$WL"                                # coordinator anchors it → reused
no grep -qE -- "workspace-group (create|remove)" $CMUX_LOG
printf '# C\n- **MODEL:** haiku\n' > $D/slices/C.md; printf '# E\nset it with a `MODEL: <name>` line\n' > $D/slices/E.md
: > $CMUX_LOG; ok env PATH=$S/cmuxstub:$PATH $O spawn --run $SP --slice C; ok grep -q -- "--model haiku " <<< "$(grep -- /worker $CMUX_LOG)"
: > $CMUX_LOG; ok env PATH=$S/cmuxstub:$PATH $O spawn --run $SP --slice E; ok grep -q -- "--model opus " <<< "$(grep -- /worker $CMUX_LOG)"   # placeholder ≠ model
unset ORCH_SKIP_TRUST; env PATH=$S/cmuxstub:$PATH $O end-run --run $SP --status aborted >/dev/null 2>&1


echo; echo "PASSED $PASS  FAILED $FAIL"; [ $FAIL = 0 ]
