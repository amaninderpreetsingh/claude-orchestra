#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# orch fixes: live-owner rule (doctor/reap), atomic locks, group cleanup, no-cmux errors, ORCH_CMUX + spawn --dry-run,
# gc of ended runs, idle-run reap, run id collisions, help text. Isolated ORCH_HOME per section; fake cmux only.
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-orch-fixes.XXXXXX"); trap 'for c in $(cat $S/caff.log 2>/dev/null); do kill $c 2>/dev/null; done; rm -rf $S' EXIT; cd $S  # unique: suites run concurrently
O=$ROOT/bin/orch
export ORCH_PORT_BASE=${ORCH_TEST_PORT_BASE:-$((30000 + $$ % 300 * 100))} ORCH_PORT_SPAN=90  # private port range: suites never share a block
mkdir -p $S/stub; export CAFF_LOG=$S/caff.log FAKE_LOG=$S/fake.log PATHCMUX_LOG=$S/pathcmux.log CLAUDE_LOG=$S/claude.log
# caffeinate stub: matches orch's `caffeinate -is` check, idles until TERM
printf '#!/bin/sh\ntrap '"'"'kill $! 2>/dev/null; exit'"'"' TERM\necho $$ >> "$CAFF_LOG"\nsleep 120 & wait\n' > $S/stub/caffeinate  # trap first: no orphan sleep
for x in xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; done
printf '#!/bin/sh\necho "$*" >> "$PATHCMUX_LOG"\nexit 1\n' > $S/stub/cmux               # the cmux on PATH: must not be used when ORCH_CMUX is set
printf '#!/bin/sh\necho "$*" >> "$CLAUDE_LOG"\nexit 0\n' > $S/stub/claude
# fake cmux for ORCH_CMUX: logs args; IDENT_SLEEP slows `identify` (widens the lock race window)
cat > $S/fakecmux <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "identify --json") [ -n "${IDENT_SLEEP:-}" ] && sleep "$IDENT_SLEEP"; echo '{"caller":{"surface_ref":"surface:77","workspace_ref":"workspace:7"}}';;
  "tree --all") [ -n "${TREE_FAIL:-}" ] && exit 1; [ -n "${TREE_SLEEP:-}" ] && sleep "$TREE_SLEEP"; echo '{"windows":[{"workspaces":[{"ref":"workspace:5","id":"W5","panes":[{"ref":"surface:51","id":"S51"}]},{"ref":"workspace:7","id":"W7","panes":[{"ref":"surface:77","id":"S77"}]}]}]}';;
  "new-workspace "*) [ -n "${FAIL_NEW:-}" ] && { echo "error: $FAIL_NEW" >&2; exit 1; }; echo "OK workspace:5";;
  "workspace-group list") echo '{"groups":[]}';;
  "workspace-group create") echo "OK workspace_group:9";;
esac
exit 0
EOF
chmod +x $S/stub/* $S/fakecmux; export PATH=$S/stub:$PATH FAKE=$S/fakecmux ORCH_CAFFEINATE=$S/stub/caffeinate  # an isolated ORCH_HOME holds none otherwise
mkdir -p $S/pybin; ln -s "$(command -v python3)" $S/pybin/python3; ln -s "$(command -v git)" $S/pybin/git
NOCMUX_PATH=$S/pybin:/usr/bin:/bin:/usr/sbin:/sbin                                                 # no cmux anywhere on it
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1 :: rc=${rc:-} out=[${out:-}]"; fi; }
run(){ out=$("$@" 2>&1); rc=$?; }
home(){ export ORCH_HOME=$S/home-$1; }
ago(){ date -v-"$1" +%Y%m%d%H%M; }                                                 # touch -t stamp: ago 13H / 10M
setrun(){ python3 - "$ORCH_HOME/runs/$1/run.json" "$2" "$3" <<'PY'
import json,sys,time; p,k,v=sys.argv[1:]; r=json.load(open(p))
r[k]=time.strftime("%Y-%m-%dT%H:%M:%S",time.localtime(time.time()-float(v[:-1])*{"h":3600,"d":86400}[v[-1]])) if v[-1] in "hd" and v[:-1].replace(".","").isdigit() else v
json.dump(r,open(p,"w"))
PY
}
jget(){ python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main; R=$S/repo

echo "-- help / docstring"
home help; run $O -h
CMDS=$(grep -oE '\{[a-z,-]+\}' <<< "$out" | head -1 | tr -d '{}' | tr , ' '); DESC=$(awk 'f&&/^positional arguments/{exit} f{print} /^$/{f=1}' <<< "$out")  # description only, not the usage line
missing=""; for c in $CMDS; do grep -qE "(^|[ ,(])$c([ ,):]|$)" <<< "$DESC" || missing="$missing $c"; done
ok "help lists every subcommand (missing:${missing:- none})" '[ -n "$CMDS" ] && [ -z "$missing" ]'
ok "help lists gc" 'grep -qE "(^|[ ,])gc([ ,]|$)" <<< "$DESC"'
ok "worker MCP memory comment not duplicated" '[ "$(grep -c "Workers load only the MCP servers they use" $O)" = 1 ]'

echo "-- run id collision in the same minute"
home ids; M0=$(date +%m%d-%H%M); M1=$(date -v+1M +%m%d-%H%M); mkdir -p $ORCH_HOME/runs
mkdir $ORCH_HOME/runs/$M0-dup $ORCH_HOME/runs/$M1-dup
run $O new-run --repo $R --title dup --coordinator workspace:0
ok "same title, same minute → -2" '[ $rc = 0 ] && [[ "$out" =~ ^[0-9]{4}-[0-9]{4}-dup-2$ ]] && [ -f $ORCH_HOME/runs/$out/run.json ]'
ok "run.json id matches the suffixed dir" '[ "$(jget $ORCH_HOME/runs/$out/run.json id)" = "$out" ]'
for m in $M0 $M1; do mkdir -p $ORCH_HOME/runs/$m-tri $ORCH_HOME/runs/$m-tri-2; done
run $O new-run --repo $R --title tri --coordinator workspace:0
ok "base and -2 taken → -3" '[ $rc = 0 ] && [[ "$out" =~ ^[0-9]{4}-[0-9]{4}-tri-3$ ]]'
for d in $ORCH_HOME/runs/*; do [ -f $d/run.json ] && $O end-run --run $(basename $d) --status aborted >/dev/null 2>&1; done

echo "-- M5: ORCH_CMUX + spawn --dry-run"
home m5; RUN=$($O new-run --repo $R --title m5 --coordinator surface:30 --coordinator-workspace workspace:3); D=$ORCH_HOME/runs/$RUN
printf '# A\n' > $D/slices/A.md; printf '# B\n' > $D/slices/B.md
: > $PATHCMUX_LOG; : > $FAKE_LOG; : > $CLAUDE_LOG
run env ORCH_SKIP_TRUST=1 $O spawn --run $RUN --slice A --dry-run
ok "spawn --dry-run exits 0" '[ $rc = 0 ]'
ok "dry-run prints the claude command line" 'grep -q "claude .*-w $RUN-A" <<< "$out"'
ok "dry-run prints the cmux new-workspace it would run" 'grep -q "new-workspace" <<< "$out"'
ok "dry-run shows the group flags the real spawn adds" 'grep -q "would run: .*--group .*--group-placement end" <<< "$out"'
ok "dry-run calls no cmux" '[ ! -s $PATHCMUX_LOG ] && [ ! -s $FAKE_LOG ]'
ok "dry-run runs no claude" '[ ! -s $CLAUDE_LOG ]'
ok "dry-run registers no worker" '[ ! -f $D/workers/A.json ]'
ok "dry-run allocates no port block" '[ -z "$(ls -A $ORCH_HOME/locks/ports 2>/dev/null)" ]'
run env ORCH_SKIP_TRUST=1 ORCH_CMUX=$FAKE $O spawn --run $RUN --slice B
ok "spawn uses ORCH_CMUX" '[ $rc = 0 ] && grep -q "^new-workspace --name $RUN-B" $FAKE_LOG'
printf '# G\n' > $D/slices/G.md; run env ORCH_SKIP_TRUST=1 ORCH_CMUX=$FAKE FAIL_NEW="no such group" $O spawn --run $RUN --slice G
ok "failed new-workspace: cmux stderr shown, no worker, ports released" '[ $rc != 0 ] && grep -q "no such group" <<< "$out" && [ ! -f $D/workers/G.json ] && ! grep -rqs "$RUN-G" $ORCH_HOME/locks/ports'
ok "ORCH_CMUX set → PATH cmux never called" '[ ! -s $PATHCMUX_LOG ]'
ok "worker registered with fake surface" '[ "$(jget $D/workers/B.json workspace)" = surface:51 ]'
: > $FAKE_LOG; run env ORCH_CMUX=$FAKE $O broadcast --run $RUN "hello"
ok "broadcast uses ORCH_CMUX, to the surface uuid" '[ $rc = 0 ] && grep -q "^agent message S51 " $FAKE_LOG && [ ! -s $PATHCMUX_LOG ]'
: > $FAKE_LOG; run env ORCH_CMUX=$FAKE $O doctor
ok "doctor reads liveness through ORCH_CMUX" 'grep -q "^tree --all" $FAKE_LOG && grep -qE "B +alive" <<< "$out"'

echo "-- M3: end-run dissolves the run's cmux group"
ok "spawn stored the group in run.json" '[ "$(jget $D/run.json group)" = workspace_group:9 ]'
RUN2=$($O new-run --repo $R --title m3 --coordinator surface:30 --coordinator-workspace workspace:3); D2=$ORCH_HOME/runs/$RUN2
printf '# A\n' > $D2/slices/A.md; env ORCH_SKIP_TRUST=1 ORCH_CMUX=$FAKE $O spawn --run $RUN2 --slice A >/dev/null 2>&1
: > $FAKE_LOG; run env ORCH_CMUX=$FAKE $O end-run --run $RUN --status aborted
ok "group still used by another active run → kept" '[ $rc = 0 ] && ! grep -q "workspace-group ungroup" $FAKE_LOG'
: > $FAKE_LOG; run env ORCH_CMUX=$FAKE $O end-run --run $RUN2 --status aborted
ok "last run of the group ends → ungroup" '[ $rc = 0 ] && grep -qx "workspace-group ungroup workspace_group:9" $FAKE_LOG'
RUN3=$($O new-run --repo $R --title m3b --coordinator surface:30 --coordinator-workspace workspace:3); D3=$ORCH_HOME/runs/$RUN3
RUN4=$($O new-run --repo $R --title m3c --coordinator surface:30 --coordinator-workspace workspace:3)   # older orch: no "group" stored
printf '# A\n' > $D3/slices/A.md; env ORCH_SKIP_TRUST=1 ORCH_CMUX=$FAKE $O spawn --run $RUN3 --slice A >/dev/null 2>&1
cp $FAKE_LOG $S/fake-m3.log; : > $FAKE_LOG; run env ORCH_CMUX=$FAKE $O end-run --run $RUN3 --status aborted
ok "another active run on the same coordinator workspace (no group recorded) → kept" '[ $rc = 0 ] && ! grep -q "workspace-group ungroup" $FAKE_LOG'
env ORCH_CMUX=$FAKE $O end-run --run $RUN4 --status aborted >/dev/null 2>&1; cp $S/fake-m3.log $FAKE_LOG
ok "ungroup comes after the worker workspaces close" '[ "$(grep -n "workspace close" $FAKE_LOG | tail -1 | cut -d: -f1)" -lt "$(grep -n ungroup $FAKE_LOG | cut -d: -f1)" ]'
ok "M3/M5 never touched PATH cmux" '[ ! -s $PATHCMUX_LOG ]'

echo "-- M4: no cmux → one clear line, exit 2"
home m4; RUN=$($O new-run --repo $R --title m4 --coordinator surface:30 --coordinator-workspace workspace:3); D=$ORCH_HOME/runs/$RUN
printf '# A\n' > $D/slices/A.md
nocmux(){ # nocmux <label> <args...> — PATH has no cmux at all
  run env PATH=$NOCMUX_PATH ORCH_SKIP_TRUST=1 $O "${@:2}"
  ok "$1: exit 2" '[ $rc = 2 ]'; ok "$1: one line naming cmux + install hint, no traceback" \
    '[ "$(grep -c . <<< "$out")" = 1 ] && grep -qi "cmux" <<< "$out" && grep -qi "install" <<< "$out" && ! grep -q Traceback <<< "$out"'; }
nocmux "spawn" spawn --run $RUN --slice A
ok "spawn without cmux registers nothing" '[ ! -f $D/workers/A.json ] && [ -z "$(ls -A $ORCH_HOME/locks/ports 2>/dev/null)" ]'
nocmux "dash --open" dash --run $RUN --open
nocmux "broadcast" broadcast --run $RUN hi
run env ORCH_CMUX=$S/no-such-cmux ORCH_SKIP_TRUST=1 $O spawn --run $RUN --slice A
ok "ORCH_CMUX pointing nowhere → exit 2, names it" '[ $rc = 2 ] && grep -q "no-such-cmux" <<< "$out" && ! grep -q Traceback <<< "$out"'
run env PATH=$NOCMUX_PATH ORCH_SKIP_TRUST=1 $O spawn --run $RUN --slice A --dry-run
ok "spawn --dry-run works without cmux" '[ $rc = 0 ] && grep -q "claude " <<< "$out"'
echo '{"run":"'$RUN'","slice":"Z","name":"'$RUN'-Z","workspace":"surface:51","ws_ref":"workspace:5","status":"active"}' > $D/workers/Z.json
run env PATH=$NOCMUX_PATH $O reap
ok "reap without cmux: no traceback" '[ $rc = 0 ] && ! grep -q Traceback <<< "$out"'
run env PATH=$NOCMUX_PATH $O end-run --run $RUN --status aborted
ok "end-run without cmux: no traceback, run ended" '[ $rc = 0 ] && ! grep -q Traceback <<< "$out" && [ "$(jget $D/run.json status)" = aborted ]'

echo "-- M1: doctor/reap treat run-prefixed and ops- owners as live"
home m1; RUN=$($O new-run --repo $R --title m1 --coordinator workspace:0)
$O lock --repo $R --owner $RUN-integrate-verify iv.txt >/dev/null
$O lock --repo $R --owner ops-asc asc.txt >/dev/null
read PA PB < <($O ports --run $RUN --name integrate-verifier)
OPSB=$((ORCH_PORT_BASE + 40)); mkdir -p $ORCH_HOME/locks/ports/$OPSB; echo '{"owner":"ops-console"}' > $ORCH_HOME/locks/ports/$OPSB/owner.json
GONE=$((ORCH_PORT_BASE + 50)); mkdir -p $ORCH_HOME/locks/ports/$GONE; echo '{"owner":"0101-0000-gone-S1"}' > $ORCH_HOME/locks/ports/$GONE/owner.json
$O lock --repo $R --owner $RUN-integrate-x f.txt >/dev/null; $O lock --repo $R --owner 0101-0000-gone-S1 g.txt >/dev/null
$O lock --repo $R --owner $RUN-integrate i.txt >/dev/null
run $O doctor
ok "doctor: no false orphans for run-prefixed / ops- owners" '! grep -E "orphan.*($RUN-|ops-)" <<< "$out"'
ok "doctor: real orphans still reported" '[ "$(grep -c "orphan.*0101-0000-gone-S1" <<< "$out")" = 2 ]'
run $O doctor --fix
ok "doctor --fix keeps the integration verifier's lock" '$O locks --repo $R | grep -q "$RUN-integrate-verify .*iv.txt"'
ok "doctor --fix keeps the ops- lock" '$O locks --repo $R | grep -q "ops-asc .*asc.txt"'
ok "doctor --fix keeps the integrate-verifier port block" '[ -d $ORCH_HOME/locks/ports/$PA ]'
ok "doctor --fix keeps the ops- port block" '[ -d $ORCH_HOME/locks/ports/$OPSB ]'
ok "doctor --fix keeps the run-prefixed file lock" '$O locks --repo $R | grep -q "$RUN-integrate-x"'
ok "doctor --fix keeps the integration's own lock" '$O locks --repo $R | grep -q "$RUN-integrate .*i.txt"'
ok "doctor --fix releases real orphans" '[ ! -d $ORCH_HOME/locks/ports/$GONE ] && ! $O locks --repo $R | grep -q gone-S1'
python3 -m http.server $OPSB --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $OPSB 2>/dev/null && break; sleep 0.3; done
$O reap >/dev/null 2>&1
ok "reap keeps a server on an ops- port block" 'kill -0 $SRV 2>/dev/null'
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
$O end-run --run $RUN --status aborted >/dev/null 2>&1

echo "-- M2: atomic file-lock acquisition, an ownerless lock dir is never taken or unlocked"
home m2; M2R=$($O new-run --repo $R --title m2 --coordinator workspace:0)        # doctor scans active runs' repos
$O lock --repo $R --owner probe m.txt >/dev/null; FD=$(dirname "$(grep -l '"m.txt"' $ORCH_HOME/locks/*/files/*/owner.json)")
$O unlock --repo $R --owner probe m.txt >/dev/null
mkdir -p $FD; run $O lock --repo $R --owner x1 m.txt
ok "file lock dir without owner.json → held, not taken" '[ $rc != 0 ] && grep -q "LOCKED m.txt" <<< "$out" && [ ! -f $FD/owner.json ]'
run $O unlock --repo $R --owner x1 m.txt
ok "unlock leaves a lock dir without owner.json alone" '[ $rc = 0 ] && [ -d $FD ]'
run $O doctor --fix
ok "doctor --fix keeps a fresh ownerless lock dir (a taker may be mid-write)" '[ -d $FD ] && ! grep -q orphan <<< "$out"'
touch -t $(ago 10M) $FD; run $O doctor --fix
ok "...older than the grace period → doctor --fix releases it" '[ ! -e $FD ] && grep -q "orphan file lock" <<< "$out"'
run $O lock --repo $R --owner x1 m.txt
ok "lock takes it with owner.json in place, no temp lock dirs left" '[ $rc = 0 ] && grep -q "\"x1\"" $FD/owner.json && [ -z "$(ls -A $ORCH_HOME/locks/.tmp)" ] && [ "$(ls -A $(dirname $FD))" = "$(basename $FD)" ]'
$O unlock --repo $R --owner x1 m.txt >/dev/null
# concurrent takers of one lock: the exists-check and the rename into place must not let two of them win
bad=0; for t in $(seq 1 20); do rm -rf $FD
  for w in 1 2 3 4 5; do ( $O lock --repo $R --owner w$w m.txt >/dev/null 2>&1; echo $? > $S/w$w.rc ) & done; wait
  n=0; win=; for w in 1 2 3 4 5; do [ "$(cat $S/w$w.rc)" = 0 ] && { n=$((n+1)); win=w$w; }; done
  { [ $n = 1 ] && grep -q "\"$win\"" $FD/owner.json; } || bad=$((bad+1)); done
ok "5 concurrent takers of one file lock: exactly one holder, named in owner.json (bad trials: $bad/20)" '[ $bad = 0 ]'
# judge→steal gap (doctor --fix, unlock): a lock retaken after it was judged must be left alone
rm -rf $FD; $O lock --repo $R --owner new m.txt >/dev/null
run python3 -c 'import importlib.machinery as m, importlib.util as u, json, pathlib, sys
s = u.spec_from_loader("orch", m.SourceFileLoader("orch", sys.argv[1])); o = u.module_from_spec(s); s.loader.exec_module(o); d = pathlib.Path(sys.argv[2])
old = {"owner": "old", "file": "m.txt", "at": 1}; cur = json.load(open(d / "owner.json"))
print(o.steal_lock(d, old), d.is_dir(), o.steal_lock(d, cur), d.exists())' $O $FD
ok "steal_lock leaves a lock retaken since it was judged, removes the one it judged" '[ "$out" = "False True True False" ]'
rm -rf $FD; $O end-run --run $M2R --status aborted >/dev/null 2>&1

echo "-- gc of ended runs + end-run drops watch state"
home gc; mk(){ $O new-run --repo $R --title "$1" --coordinator workspace:0; }
OLD=$(mk old); NEW=$(mk new); ACT=$(mk act); NOEND=$(mk noend)
for r in $OLD $NEW $ACT $NOEND; do d=$ORCH_HOME/runs/$r
  for f in spec.md HANDOFF.md criteria.json plan.json baseline.json waiting.json; do echo x > $d/$f; done
  echo x > $d/slices/S1.md; echo y > $d/slices/S1.progress.md; echo '{}' > $d/workers/S1.json
  mkdir -p $d/artifacts/lab/.venv; head -c 20000 /dev/zero > $d/artifacts/lab/.venv/blob; mkdir -p $d/audit; echo a > $d/audit/a.md; done
mkdir -p $ORCH_HOME/state; for r in $OLD $NEW $ACT; do echo '{}' > $ORCH_HOME/state/watch-$r.json; done
$O end-run --run $OLD --status aborted >/dev/null 2>&1
ok "end-run deletes its watch state" '[ ! -e $ORCH_HOME/state/watch-$OLD.json ] && [ -e $ORCH_HOME/state/watch-$ACT.json ]'
$O end-run --run $NEW --status aborted >/dev/null 2>&1; $O end-run --run $NOEND --status aborted >/dev/null 2>&1
setrun $OLD ended 20d; setrun $NEW ended 3d; setrun $ACT created 40d
python3 -c 'import json,sys;p=sys.argv[1];r=json.load(open(p));r.pop("ended");json.dump(r,open(p,"w"))' $ORCH_HOME/runs/$NOEND/run.json
echo '{}' > $ORCH_HOME/state/watch-$OLD.json
run $O gc --dry-run
ok "gc --dry-run lists the old ended run with a size" '[ $rc = 0 ] && grep -E "$OLD.*[0-9]+(\.[0-9])?(B|K|M|G)" -q <<< "$out"'
ok "gc --dry-run deletes nothing" '[ -f $ORCH_HOME/runs/$OLD/artifacts/lab/.venv/blob ] && [ -f $ORCH_HOME/runs/$OLD/slices/S1.md ]'
ok "gc --dry-run skips runs ended <14d, active, and without an end time" '! grep -qE "$NEW|$ACT|$NOEND" <<< "$out"'
run $O gc
keep=$(cd $ORCH_HOME/runs/$OLD && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')
ok "gc keeps only spec/HANDOFF/criteria/plan/run.json (got: $keep)" '[ "$keep" = "./HANDOFF.md ./criteria.json ./plan.json ./run.json ./spec.md " ]'
ok "gc drops the run's watch state" '[ ! -e $ORCH_HOME/state/watch-$OLD.json ]'
ok "gc leaves the 3-day-old ended run" '[ -f $ORCH_HOME/runs/$NEW/artifacts/lab/.venv/blob ]'
ok "gc never touches an active run" '[ -f $ORCH_HOME/runs/$ACT/artifacts/lab/.venv/blob ] && [ -e $ORCH_HOME/state/watch-$ACT.json ]'
ok "gc skips an ended run with no end time" '[ -f $ORCH_HOME/runs/$NOEND/slices/S1.md ]'
run $O gc --ended-older-than 2d
ok "--ended-older-than 2d takes the 3-day-old one too" '[ $rc = 0 ] && [ ! -e $ORCH_HOME/runs/$NEW/artifacts ] && [ -f $ORCH_HOME/runs/$NEW/spec.md ]'
run $O gc; ok "gc again: nothing left to do" '[ $rc = 0 ] && ! grep -q "$OLD" <<< "$out"'
run $O gc --ended-older-than 14; ok "gc rejects a bad age" '[ $rc != 0 ]'
ln -s $S/repo $ORCH_HOME/runs/$NEW/link; setrun $NEW ended 30d; run $O gc
ok "gc removes a symlink without following it" '[ ! -L $ORCH_HOME/runs/$NEW/link ] && [ -f $S/repo/a.txt ]'

echo "-- run-id suffixes vs owner matching (X-2-S1 is X-2's, not X's)"
pair(){ local i; for i in 1 2 3; do home pfx-$1-$i   # fresh home per try: a minute rollover can't leave a stale base id
  P1=$($O new-run --repo $R --title $1 --coordinator workspace:0); P2=$($O new-run --repo $R --title $1 --coordinator workspace:0)
  [ "$P2" = "$P1-2" ] && return; done; }
pair dup; X=$P1; X2=$P2
read XA XB < <($O ports --run $X2 --name S1)
$O end-run --run $X --status aborted >/dev/null 2>&1
ok "end-run X keeps X-2's port block ($X2)" '[ "$X2" = "$X-2" ] && [ -d $ORCH_HOME/locks/ports/$XA ]'
pair yy; Y=$P1; Y2=$P2
$O lock --repo $R --owner $Y2-integrate-verifier-verify ivv.txt >/dev/null; $O lock --repo $R --owner $Y2-S4 pre.txt >/dev/null
$O end-run --run $Y2 --status aborted >/dev/null 2>&1
ok "end-run frees every lock under its names (non-standard integration owner, pre-spawn file lock)" '! $O locks --repo $R | grep -qE "ivv.txt|pre.txt"'
$O lock --repo $R --owner $Y2-S1-verify left.txt >/dev/null                           # a leftover taken after Y-2 ended
run $O doctor --fix
ok "ended Y-2's lock is an orphan while Y is active" '[ "$Y2" = "$Y-2" ] && grep -q "orphan file lock left.txt by $Y2-S1-verify" <<< "$out" && ! $O locks --repo $R | grep -q left.txt'
echo '{"run":"'$Y'","slice":"S1","name":"'$Y'-S1","status":"merged"}' > $ORCH_HOME/runs/$Y/workers/S1.json
$O lock --repo $R --owner $Y-S10-verify s10.txt >/dev/null
$O close --run $Y --slice S1 >/dev/null 2>&1
ok "closing S1 leaves S10's verify lock" '$O locks --repo $R | grep -q "$Y-S10-verify .*s10.txt"'
$O unlock --repo $R --owner $Y-S10-verify >/dev/null; $O end-run --run $Y --status aborted >/dev/null 2>&1

echo "-- cmux failing (not running) = liveness unknown, nobody marked dead"
home ce; CE=$($O new-run --repo $R --title ce --coordinator workspace:0)
echo '{"run":"'$CE'","slice":"A","name":"'$CE'-A","workspace":"surface:51","status":"active"}' > $ORCH_HOME/runs/$CE/workers/A.json
$O reap >/dev/null 2>&1                                                  # PATH cmux here exits 1
ok "reap with cmux exiting 1 keeps the worker active" '[ "$(jget $ORCH_HOME/runs/$CE/workers/A.json status)" = active ]'
$O doctor --fix >/dev/null 2>&1
ok "doctor --fix with cmux exiting 1 keeps it active" '[ "$(jget $ORCH_HOME/runs/$CE/workers/A.json status)" = active ]'
$O end-run --run $CE --status aborted >/dev/null 2>&1

echo "-- finished workers' locks are orphans; active/dead (resumable) workers' and coordinator jobs' are not"
home fin; Z=$($O new-run --repo $R --title fin --coordinator workspace:0); ZD=$ORCH_HOME/runs/$Z
wkr(){ echo '{"run":"'$Z'","slice":"'$1'","name":"'$Z-$1'","workspace":"surface:51","status":"'$2'"}' > $ZD/workers/$1.json; }
wkr S1 merged; wkr S2 active; wkr S3 dead; wkr api merged
$O lock --repo $R --owner $Z-S1 done.txt >/dev/null; $O lock --repo $R --owner $Z-S2 live.txt >/dev/null
$O lock --repo $R --owner $Z-S3 dead.txt >/dev/null; $O lock --repo $R --owner $Z-api-auth auth.txt >/dev/null   # api-auth not spawned yet
$O lock --repo $R --owner $Z-S1-verify v1.txt >/dev/null; $O lock --repo $R --owner $Z-integrate-verify iv.txt >/dev/null
run env ORCH_CMUX=$FAKE $O doctor --fix
ok "merged worker's file lock and -verify lock released" '! $O locks --repo $R | grep -qE "done.txt|v1.txt"'
ok "active worker's file lock and coordinator job's lock kept" '$O locks --repo $R | grep -q live.txt && $O locks --repo $R | grep -q iv.txt'
ok "dead worker's file lock kept for --resume" '$O locks --repo $R | grep -q dead.txt'
ok "lock for slice api-auth (taken before spawn) isn't matched to finished worker api" '$O locks --repo $R | grep -q auth.txt'
$O lock --repo $R --owner $Z-api-docs-verify docs.txt >/dev/null; $O close --run $Z --slice api >/dev/null 2>&1
ok "closing slice api leaves api-docs's verify lock" '$O locks --repo $R | grep -q "$Z-api-docs-verify .*docs.txt"'
$O unlock --repo $R --owner $Z-api-docs-verify >/dev/null
printf "# S3\n" > $ZD/slices/S3.md; run env ORCH_SKIP_TRUST=1 $O spawn --run $Z --slice S3 --resume --dry-run
ok "spawn --resume with no worktree → refused, no port block taken" '[ $rc != 0 ] && grep -q "no worktree" <<< "$out" && ! grep -rqs "\"$Z-S3\"" $ORCH_HOME/locks/ports'
printf '# S4\n' > $ZD/slices/S4.md; run env ORCH_SKIP_TRUST=1 ORCH_CMUX=$FAKE $O spawn --run $Z --slice S4 --resume
ok "...same for a real spawn" '[ $rc != 0 ] && ! grep -rqs "\"$Z-S4\"" $ORCH_HOME/locks/ports'
OD=$ORCH_HOME/locks/ports/.$ORCH_PORT_BASE.ab12.tmp; mkdir -p $OD; echo '{"owner":"'$Z'-iv"}' > $OD/owner.json   # temp dir left by a killed taker
run $O ports --run $Z --name iv
ok "a leftover temp dir in ports/ doesn't break allocation" '[ $rc = 0 ] && [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] && ! grep -q Traceback <<< "$out"'
$O ports --run $Z --name iv --release >/dev/null
echo '{"dash_ws":"workspace:5"}' > /dev/null; python3 -c 'import json,sys;p=sys.argv[1];r=json.load(open(p));r["dash_ws"]="workspace:5";json.dump(r,open(p,"w"))' $ZD/run.json
: > $FAKE_LOG; run env ORCH_CMUX=$FAKE TREE_FAIL=1 $O dash --run $Z --open
ok "dash --open with liveness unknown doesn't open a second dashboard" '! grep -q "^new-workspace" $FAKE_LOG'
FL=$(dirname "$(dirname "$(grep -l '"live.txt"' $ORCH_HOME/locks/*/files/*/owner.json)")"); chmod 500 $FL   # files/ not writable
run python3 -c 'import subprocess,sys
try: r=subprocess.run(sys.argv[1:],capture_output=True,text=True,timeout=8); print(r.stdout+r.stderr); sys.exit(r.returncode)
except subprocess.TimeoutExpired: print("HUNG"); sys.exit(124)' $O lock --repo $R --owner q q.txt
chmod 700 $FL
ok "lock dir that can't be created → error, not a busy loop" '[ $rc != 0 ] && [ $rc != 124 ] && grep -q "could not create lock" <<< "$out"'
$O unlock --repo $R --owner $Z-integrate-verify >/dev/null; $O end-run --run $Z --status aborted >/dev/null 2>&1

echo "-- a run whose workers all died (port blocks left behind) still goes idle"
home dead; DR=$($O new-run --repo $R --title dead --coordinator workspace:0)
echo '{"run":"'$DR'","slice":"S1","name":"'$DR'-S1","status":"dead","died":"2020-01-01T00:00:00"}' > $ORCH_HOME/runs/$DR/workers/S1.json
DB=$((ORCH_PORT_BASE + 60)); mkdir -p $ORCH_HOME/locks/ports/$DB; echo '{"owner":"'$DR'-S1"}' > $ORCH_HOME/locks/ports/$DB/owner.json
setrun $DR created 13h; find $ORCH_HOME/runs/$DR -type f -exec touch -t $(ago 13H) {} +
run $O reap
ok "dead worker's leftover port block doesn't keep the run busy" 'grep -q "IDLE run $DR" <<< "$out"'
$O end-run --run $DR --status aborted >/dev/null 2>&1

echo "-- an active run holding integration ports/locks is not idle"
home busy; CP=$ORCH_HOME/state/caffeinate.pid; BR=$($O new-run --repo $R --title busy --coordinator workspace:0)
read BA BB < <($O ports --run $BR --name integrate-verifier); $O lock --repo $R --owner $BR-S5 pre5.txt >/dev/null
setrun $BR created 13h; find $ORCH_HOME/runs/$BR -type f -exec touch -t $(ago 13H) {} +
run $O reap
ok "integration port block / pre-spawn lock taken just now → not IDLE, caffeinate kept" '! grep -q IDLE <<< "$out" && [ -f $CP ] && kill -0 "$(cat $CP)" 2>/dev/null'
old_at(){ python3 -c 'import json,sys,time;p=sys.argv[1];o=json.load(open(p));o["at"]=time.strftime("%Y-%m-%dT%H:%M:%S",time.localtime(time.time()-13*3600));json.dump(o,open(p,"w"))' "$1"; }
old_at $ORCH_HOME/locks/ports/$BA/owner.json
run $O reap --dry-run
ok "...pre-spawn file lock still fresh → not IDLE" '! grep -q IDLE <<< "$out"'
for f in $(find $ORCH_HOME/locks -path "*/files/*/owner.json"); do old_at $f; done
run $O reap --dry-run
ok "port block and pre-spawn file lock both 13h old (leftover reservations) → IDLE" 'grep -q "IDLE run $BR" <<< "$out"'
$O end-run --run $BR --status aborted >/dev/null 2>&1

echo "-- ORCH_CMUX that exists but can't run: no traceback"
home badcmux; BC=$($O new-run --repo $R --title bc --coordinator surface:30 --coordinator-workspace workspace:3); BD=$ORCH_HOME/runs/$BC
printf 'echo hi\n' > $S/noexec-cmux; printf 'echo hi\n' > $S/noshebang-cmux; chmod +x $S/noshebang-cmux
echo '{"run":"'$BC'","slice":"A","name":"'$BC'-A","workspace":"surface:51","status":"active"}' > $BD/workers/A.json
run env ORCH_CMUX=$S/noshebang-cmux $O broadcast --run $BC hi
ok "broadcast with a #!-less ORCH_CMUX → UNDELIVERED, no traceback" '[ $rc = 0 ] && grep -q UNDELIVERED <<< "$out" && ! grep -q Traceback <<< "$out"'
run env ORCH_CMUX=$S/noexec-cmux $O broadcast --run $BC hi
ok "broadcast with a non-executable ORCH_CMUX → exit 2, one line" '[ $rc = 2 ] && [ "$(grep -c . <<< "$out")" = 1 ]'
python3 -c 'import json,sys;p=sys.argv[1];r=json.load(open(p));r["dash_ws"]="workspace:9";json.dump(r,open(p,"w"))' $BD/run.json
run env ORCH_CMUX=$S/noshebang-cmux $O end-run --run $BC --status aborted
ok "end-run with a #!-less ORCH_CMUX completes (run ended, no traceback)" '[ $rc = 0 ] && ! grep -q Traceback <<< "$out" && [ "$(jget $BD/run.json status)" = aborted ]'

echo "-- reap flags idle active runs, releases caffeinate"
home idle; CP=$ORCH_HOME/state/caffeinate.pid; alive(){ [ -f $CP ] && kill -0 "$(cat $CP)" 2>/dev/null; }
IR=$($O new-run --repo $R --title idle --coordinator surface:30 --coordinator-workspace workspace:3); FR=$($O new-run --repo $R --title fresh --coordinator workspace:0)
echo '{"run":"'$IR'","slice":"A","name":"'$IR'-A","status":"merged","started":"2020-01-01T00:00:00","merged":"2020-01-01T01:00:00"}' > $ORCH_HOME/runs/$IR/workers/A.json
setrun $IR created 13h; find $ORCH_HOME/runs/$IR -type f -exec touch -t $(ago 13H) {} +
ok "caffeinate held" 'alive'
run $O reap
ok "reap flags the run idle >12h" 'grep -E "IDLE.*$IR" -q <<< "$out"'
ok "...not the fresh one" '! grep -E "IDLE.*$FR" -q <<< "$out"'
ok "...caffeinate kept while another active run is not idle" 'alive'
$O end-run --run $FR --status aborted >/dev/null 2>&1; ok "caffeinate kept: idle run still active" 'alive'
CPID=$(cat $CP); run $O reap --dry-run
ok "reap --dry-run flags but releases nothing" 'grep -q "IDLE.*$IR" <<< "$out" && alive'
run $O reap
ok "all active runs idle → caffeinate released" '! alive && ! kill -0 $CPID 2>/dev/null && grep -qi "caffeinate released" <<< "$out"'
ok "idle run is not ended" '[ "$(jget $ORCH_HOME/runs/$IR/run.json status)" = active ]'
$O note --run $IR --wait "back on it" >/dev/null; ok "coordinator's orch note on the idle run holds caffeinate again" 'alive'
touch -t $(ago 13H) $ORCH_HOME/runs/$IR/waiting.json; $O reap >/dev/null; ok "(released again)" '! alive'
read IA IB < <($O ports --run $IR --name integrate-verifier); ok "orch ports (integration) holds caffeinate again" 'alive'
$O ports --run $IR --name integrate-verifier --release >/dev/null
printf '# B\n' > $ORCH_HOME/runs/$IR/slices/B.md
env ORCH_SKIP_TRUST=1 ORCH_CMUX=$FAKE $O spawn --run $IR --slice B >/dev/null 2>&1
ok "spawning on the idle run holds caffeinate again" 'alive'
run env ORCH_CMUX=$FAKE $O reap
ok "run with an active worker is not idle" '! grep -q "IDLE" <<< "$out" && alive'
env ORCH_CMUX=$FAKE $O end-run --run $IR --status aborted >/dev/null 2>&1

echo "PASSED $P FAILED $F"; [ $F = 0 ]
