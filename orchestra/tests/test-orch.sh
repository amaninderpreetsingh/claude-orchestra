#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Scenario tests for orch + push-guard (isolated ORCH_HOME, local bare origin).
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-orch.XXXXXX"); trap 'rm -rf $S' EXIT; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch; H=$ROOT/hooks/push-guard.py
export ORCH_PORT_BASE=$((30000 + $$ % 300 * 100)) ORCH_PORT_SPAN=90  # private port range: suites never share a block
# fakes on PATH: caffeinate logs its pid and idles; cmux (spawn tests only) logs args, answers from $S/groups.json
mkdir -p $S/stub $S/cmuxstub; export CAFF_LOG=$S/caff.log CMUX_LOG=$S/cmux.log
printf '#!/bin/sh\necho $$ >> "$CAFF_LOG"\nsleep 120 & trap "kill $! 2>/dev/null; exit" TERM\nwait\n' > $S/stub/caffeinate
cat > $S/cmuxstub/cmux <<'EOF'
#!/bin/sh
echo "$*" >> "$CMUX_LOG"
case "$1 $2" in
  "identify --json") echo '{"caller":{}}';;
  "tree --all"*) echo '{"windows":[{"workspaces":[{"ref":"workspace:5","panes":[{"ref":"surface:51"}]}]}]}';;
  "new-workspace "*) echo "OK workspace:5";;
  "workspace-group list") cat "$(dirname "$CMUX_LOG")/groups.json" 2>/dev/null || echo '{"groups":[]}';;
  "workspace-group create") echo "OK workspace_group:9";;
esac
EOF
for x in xcrun osascript; do printf '#!/bin/sh\necho "$*" >> "$(dirname "$CAFF_LOG")/xcrun.log"\n' > $S/stub/$x; done   # no suite may touch real simulators
printf '#!/bin/sh\nexit 0\n' > $S/stub/pgrep                                       # "Simulator app is running"
chmod +x $S/stub/caffeinate $S/stub/xcrun $S/stub/osascript $S/stub/pgrep $S/cmuxstub/cmux; export PATH=$S/stub:$PATH
PASS=0; FAIL=0
expect(){ # expect <label> <want: allow|ask|deny|silent> <cwd> <cmd>
  out=$(printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"$3\",\"tool_input\":{\"command\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$4")}}" | python3 $H 2>&1); rc=$?
  got=silent; { [ $rc != 0 ] || [ -n "$out" ]; } && got=noisy; [ $rc = 2 ] && got=deny; echo "$out" | grep -q '"allow"' && got=allow; echo "$out" | grep -q '"ask"' && got=ask
  if [ $got = $2 ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1: want $2 got $got :: $out"; fi; }
ok(){ if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   cmd: ${*:2:3}"; else FAIL=$((FAIL+1)); echo "FAIL cmd should succeed: $*"; "$@"; fi; }
no(){ if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL cmd should fail: $*"; else PASS=$((PASS+1)); echo "ok   refused: ${*:2:3}"; fi; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo 'echo ok' > gate.sh; echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main
R=$S/repo; RUN=$($O new-run --repo $R --title t --coordinator workspace:0); ok $O run-branch --run $RUN
git fetch -q; git worktree add -q .claude/worktrees/w1 -b w1 origin/orch/$RUN; git worktree add -q .claude/worktrees/w2 -b w2 origin/orch/$RUN; git worktree add -q .claude/worktrees/plain -b plain origin/main
W1=$R/.claude/worktrees/w1; W2=$R/.claude/worktrees/w2; P=$R/.claude/worktrees/plain
echo "-- unregistered"
expect "push from main checkout → no decision (user's rules)" silent $R "git push origin main"
expect "commit in plain claude -w worktree → no decision (user's rules)" silent $P "git commit -m x"
expect "force push always denied" deny $R "git push --force origin main"
expect "delete refspec denied" deny $R "git push origin :main"
ok $O register --worktree $W1 --run $RUN --slice s1; ok $O register --worktree $W2 --run $RUN --slice s2 --risky
echo "-- registered worker"
expect "commit in worker silent" silent $W1 "git commit -m x"
cd $W1; echo b > b.txt; git add .; git commit -qm s1
expect "no gates-ok → deny" deny $W1 "git push origin HEAD:orch/$RUN"
no $O gates-ok --worktree $W1
ok $O gates --worktree $W1 --cmd "bash gate.sh"
no $O gates-ok --worktree $W1                                    # no verdicts yet
ok $O verdict --worktree $W1 --role reviewer --verdict PASS
no $O gates-ok --worktree $W1                                    # verifier missing
ok $O verdict --worktree $W1 --role verifier --verdict FAIL
no $O gates-ok --worktree $W1                                    # verifier FAIL
ok $O verdict --worktree $W1 --role verifier --verdict PASS
ok $O gates-ok --worktree $W1
expect "wrong destination (main) denied" deny $W1 "git push origin HEAD:main"
expect "no explicit refspec denied" deny $W1 "git push"
expect "no merge lock → deny" deny $W1 "git push origin HEAD:orch/$RUN"
ok $O merge-lock --repo $W1 --owner $RUN-s1 --wait 0
no $O merge-lock --repo $W2 --owner $RUN-s2 --wait 0
expect "all good → allow" allow $W1 "cd $W1 && git push origin HEAD:orch/$RUN"
git push -q origin HEAD:orch/$RUN; ok $O merge-unlock --repo $W1 --owner $RUN-s1
echo "-- second worker, risky, after first merged"
cd $W2; echo c > c.txt; git add .; git commit -qm s2; S2_OLD=$(git rev-parse HEAD)
ok $O gates --worktree $W2 --cmd "bash gate.sh"; ok $O verdict --worktree $W2 --role reviewer --verdict PASS; ok $O verdict --worktree $W2 --role verifier --verdict PASS
no $O gates-ok --worktree $W2                                    # risky → adversarial missing
ok $O verdict --worktree $W2 --role adversarial --verdict PASS
ok $O gates-ok --worktree $W2; ok $O merge-lock --repo $W2 --owner $RUN-s2 --wait 0
expect "stale base → deny" deny $W2 "git push origin HEAD:orch/$RUN"
git fetch -q origin; git rebase -q origin/orch/$RUN
no $O gates-ok --worktree $W2                                    # gates not run on new HEAD
ok $O gates --worktree $W2 --cmd "bash gate.sh"
no $O gates-ok --worktree $W2                                    # verifier must re-run on HEAD
ok $O verdict --worktree $W2 --role verifier --verdict PASS --mode specs-only
ok $O gates-ok --worktree $W2                                    # reviewer+adversarial carried: identical patch
expect "rebased + regated → allow" allow $W2 "git push origin HEAD:orch/$RUN"
echo "-- patch changed during rebase → reviewer must re-run"
git reset -q --hard $S2_OLD; echo "c2" > c.txt; git commit -qam "conflict-ish change"
ok $O gates --worktree $W2 --cmd "bash gate.sh"; ok $O verdict --worktree $W2 --role verifier --verdict PASS
no $O gates-ok --worktree $W2
echo "-- gate failure"
echo 'exit 1' > fail.sh; git add .; git commit -qm f
no $O gates --worktree $W2 --cmd "bash fail.sh"
ok $O verdict --worktree $W2 --role reviewer --verdict PASS; ok $O verdict --worktree $W2 --role adversarial --verdict PASS; ok $O verdict --worktree $W2 --role verifier --verdict PASS
no $O gates-ok --worktree $W2
ok $O gates-ok --worktree $W2 --accept-failures "fail.sh fails on baseline too"
echo "-- crash inside worker fails closed"
mv $(git -C $W2 rev-parse --git-dir)/orchestra-owner.json /tmp/o.json.$$; echo '{bad json' > $(git -C $W2 rev-parse --git-dir)/orchestra-owner.json
expect "corrupt owner file → deny" deny $W2 "git push origin HEAD:orch/$RUN"
mv /tmp/o.json.$$ $(git -C $W2 rev-parse --git-dir)/orchestra-owner.json
echo "-- criteria + end-run"
echo '[{"id":"C1","text":"x"},{"id":"C2","text":"y"}]' > $S/c.json; ok $O criteria-init --run $RUN --file $S/c.json
no $O criteria-check --run $RUN
ok $O criterion --run $RUN --id C1 --status pass --sha $(git -C $W1 rev-parse HEAD)
no $O end-run --run $RUN --keep-sim
ok $O criterion --run $RUN --id C2 --status pass --sha $(git -C $W1 rev-parse HEAD)
no $O end-run --run $RUN --keep-sim                                         # passed sha not on origin/main yet
cd $R; git fetch -q; git push -q origin origin/orch/$RUN:main
ok $O end-run --run $RUN --keep-sim
git fetch -q --prune; git branch -r | grep -q "orch/$RUN" && { FAIL=$((FAIL+1)); echo "FAIL run branch not deleted"; } || { PASS=$((PASS+1)); echo "ok   run branch deleted"; }

echo "-- caffeinate held while any run is active"
CP=$ORCH_HOME/state/caffeinate.pid; alive(){ [ -f $CP ] && kill -0 "$(cat $CP)" 2>/dev/null; }
ok test "$(wc -l < $CAFF_LOG | tr -d ' ')" = 1                    # new-run at the top started exactly one
ok test ! -f $CP                                                  # ...and the last end-run released it
CA=$($O new-run --repo $R --title ca --coordinator workspace:0); ok alive
CB=$($O new-run --repo $R --title cb --coordinator workspace:0)
ok test "$(wc -l < $CAFF_LOG | tr -d ' ')" = 2                    # second run reuses the held one
ok $O end-run --run $CA --status aborted --keep-sim; ok alive    # CB still active
CPID=$(cat $CP); ok $O end-run --run $CB --status aborted --keep-sim
no alive; no kill -0 $CPID
echo 99999999 > $CP; CC=$($O new-run --repo $R --title cc --coordinator workspace:0); ok alive   # stale pid → new one
python3 - $ORCH_HOME/runs/$CC/run.json <<'PY'
import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["status"]="aborted"; json.dump(r,open(p,"w"))
PY
CPID=$(cat $CP); ok $O reap --keep-sim; no alive; no kill -0 $CPID   # reap with no active run releases it

echo "-- spawn: --model + coordinator-anchored group"
SP=$($O new-run --repo $R --title sp --coordinator surface:30 --coordinator-workspace workspace:3); D=$ORCH_HOME/runs/$SP
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
unset ORCH_SKIP_TRUST; env PATH=$S/cmuxstub:$PATH $O end-run --run $SP --status aborted --keep-sim >/dev/null 2>&1

echo "-- gates: logs + summary, hygiene"
HY=$($O new-run --repo $R --title hy --coordinator workspace:0); cd $R; git fetch -q
git worktree add -q .claude/worktrees/hy -b hy origin/main; WH=$R/.claude/worktrees/hy; ok $O register --worktree $WH --run $HY --slice h
cd $WH; printf 'echo compiling\necho "src/a.ts:3 error TS2322: bad type"\necho trailing\nexit 2\n' > tsc.sh
printf 'for i in 1 2 3 4 5 6 7; do echo line$i; done\nexit 1\n' > quiet.sh; git add .; git commit -qm gatescripts
out=$($O gates --worktree $WH --cmd "bash tsc.sh" --cmd "bash gate.sh" 2>&1)
ok grep -qE '^FAIL +bash tsc.sh +\([0-9]+s\) +.*\.log' <<< "$out"
ok grep -q 'error TS2322' <<< "$out"; no grep -q 'compiling' <<< "$out"; no grep -q trailing <<< "$out"   # only the first error line
ok grep -qE '^ok +bash gate.sh' <<< "$out"
ok test "$(grep -c . <<< "$out")" -le 4
LOGF=$(sed -nE 's/^FAIL +bash tsc.sh .* (\/[^ ]+\.log)$/\1/p' <<< "$out"); ok grep -q trailing "$LOGF"   # full output in the log
ok grep -q "$(git -C $WH rev-parse --git-dir)" <<< "$LOGF"                                                # under the worktree git dir
out=$($O gates --worktree $WH --cmd "bash quiet.sh" 2>&1)
ok grep -q line7 <<< "$out"; ok grep -q line3 <<< "$out"; no grep -q line2 <<< "$out"                      # no error line → last 5
ok $O gates --worktree $WH --cmd "bash gate.sh"
hy(){ # hy <label> <file> <content> <want: ok|no> — commit file, gates must pass/fail naming the reason
  mkdir -p "$(dirname "$2")"; printf '%s\n' "$3" > "$2"; git add -f "$2"; git commit -qm "$1"
  o=$($O gates --worktree $WH --cmd "bash gate.sh" 2>&1); rc=$?
  if { [ $4 = ok ] && [ $rc = 0 ]; } || { [ $4 = no ] && [ $rc != 0 ] && grep -qiF "$1" <<< "$(grep -i hygiene <<< "$o")"; }; then PASS=$((PASS+1)); echo "ok   hygiene $1 → $4"
  else FAIL=$((FAIL+1)); echo "FAIL hygiene $1: want $4 rc=$rc :: $o"; fi
  git reset -q --hard HEAD~1; }
hy .env .env.local 'K=1' no
hy node_modules node_modules/x/index.js 'x' no
hy .pem certs/key.pem 'k' no
hy .DS_Store sub/.DS_Store 'x' no
hy console.log src/a.ts 'console.log("hi")' no
hy debugger src/b.js '  debugger;' no
hy example .env.example 'K=' ok
hy plain src/c.ts 'export const c = 1' ok
hy shell s.sh 'console.log "not js"' ok
for x in vue svelte html jsx tsx mjs cjs; do hy console.log src/v.$x '<script>console.log("hi")</script>' no; hy debugger src/d.$x '  debugger;' no; done
hy text notes.md 'console.log("in prose")' ok
printf 'x\n' > .env; git add -f .env                                               # staged, not committed
ok grep -qi 'hygiene.*\.env' <<< "$($O gates --worktree $WH --cmd 'bash gate.sh' 2>&1)"; git reset -q; rm .env
printf '# repo\norch-allow: console.log, .DS_Store\n' > CLAUDE.md
hy console.log src/a.ts 'console.log("hi")' no                                     # uncommitted opt-out doesn't count
git add .; git commit -qm allow
hy console.log src/a.ts 'console.log("hi")' ok
hy .DS_Store .DS_Store 'x' ok
hy console.log src/a.vue 'console.log(1)' ok                                       # opt-out covers every extension
hy debugger src/b.js 'debugger' no
cd $R; $O end-run --run $HY --status aborted --keep-sim >/dev/null 2>&1

echo "-- simulators: only orch-sim reap, never 'simctl shutdown all'"
mkdir -p $S/bin; cp $O $S/bin/orch; printf '#!/bin/sh\necho "$*" >> "%s/orch-sim.log"\n' $S > $S/bin/orch-sim; chmod +x $S/bin/orch-sim
SM=$($O new-run --repo $R --title sm --coordinator workspace:0); : > $S/xcrun.log
ok $S/bin/orch end-run --run $SM --status aborted                                  # no --keep-sim: last run ends
ok grep -qx reap $S/orch-sim.log
no grep -q shutdown $S/xcrun.log
SM=$($O new-run --repo $R --title sm2 --coordinator workspace:0); ok $O end-run --run $SM --status aborted   # no orch-sim beside it
ok $O reap; no grep -q shutdown $S/xcrun.log

echo; echo "PASSED $PASS  FAILED $FAIL"; [ $FAIL = 0 ]
