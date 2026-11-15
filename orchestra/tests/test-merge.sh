#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# run-branch / merge / ship against a local bare remote, note --wait notifications, register's coordinator id.
# A cmux stub logs every call (notify included) and answers tree/identify; nothing reaches the real cmux.
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-merge.XXXXXX"); trap 'rm -rf $S' EXIT; cd $S
export ORCH_HOME=$S/home; O=$ROOT/bin/orch
export ORCH_PORT_BASE=${ORCH_TEST_PORT_BASE:-$((30000 + $$ % 300 * 100))} ORCH_PORT_SPAN=90
mkdir -p $S/stub; for x in caffeinate xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; chmod +x $S/stub/$x; done
export CMUX_LOG=$S/cmux.log; : > $CMUX_LOG
cat > $S/stub/cmux <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1" in
  notify) [ -n "${CMUX_NOTIFY_FAIL:-}" ] && exit 1; exit 0 ;;
  identify) case "$*" in
      *--id-format*) echo '{"caller":{"surface_ref":"surface:9","surface_id":"SURF-UUID-9","workspace_ref":"workspace:3","workspace_id":"WS-UUID-3"}}' ;;
      *) echo '{"caller":{"surface_ref":"surface:9","workspace_ref":"workspace:3"}}' ;;
    esac ;;
  tree) echo '{"windows":[{"workspaces":[{"ref":"workspace:3","id":"WS-UUID-3","title":"coord","surfaces":[{"ref":"surface:7","id":"COORD-UUID-7","title":"coord"}]}]}]}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x $S/stub/cmux; export PATH=$S/stub:$PATH
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }
J(){ python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"; }   # J <file> <python expr on d>
notifies(){ grep -c '^notify ' $CMUX_LOG; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; R=$S/repo; cd $R
echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main
M0=$(git rev-parse HEAD)
RUN=$($O new-run --repo $R --title m$$ --coordinator surface:7); D=$ORCH_HOME/runs/$RUN; FEAT=$D/feature; BR=orch/$RUN
remote(){ git -C $S/origin.git rev-parse -q --verify "refs/heads/$1"; }

echo "-- run-branch"
out=$($O run-branch --run $RUN 2>&1); rc=$?
ok "run-branch exits 0" '[ $rc = 0 ]'
ok "origin has orch/<run> at origin/main" '[ "$(remote $BR)" = "$M0" ]'
ok "feature worktree at runs/<run>/feature on orch/<run>" '[ "$(git -C $FEAT symbolic-ref --short HEAD 2>/dev/null)" = "$BR" ]'
ok "run.json records the target" '[ "$(J $D/run.json "d[\"target\"]")" = "$BR" ]'
FGD=$(git -C $FEAT rev-parse --path-format=absolute --git-dir)
ok "no owner record in the feature worktree" '[ -n "$FGD" ] && [ ! -e $FGD/orchestra-owner.json ]'

echo "-- register: coordinator + its stable id in the owner record"
wt(){ git -C $R fetch -q origin; git -C $R worktree add -q $R/.claude/worktrees/$RUN-$1 -b worktree-$RUN-$1 origin/$BR; echo $R/.claude/worktrees/$RUN-$1; }
commit(){ echo "$2" > $1/$3; git -C $1 add $3; git -C $1 commit -qm "$2"; git -C $1 rev-parse HEAD; }
evidence(){ printf 'sha: %s\n## Gates\nall pass\n' "$2" > $D/slices/$1.ready.md; }
WA=$(wt A); $O register --worktree $WA --run $RUN --slice A >/dev/null
OR=$(git -C $WA rev-parse --path-format=absolute --git-dir)/orchestra-owner.json
ok "owner record: coordinator = the run's ref" '[ "$(J $OR "d.get(\"coordinator\")")" = surface:7 ]'
ok "owner record: coordinator_id = its stable cmux id" '[ "$(J $OR "d.get(\"coordinator_id\")")" = COORD-UUID-7 ]'

cat > $S/plan.json <<'EOF'
{"merge_policy":"auto","tasks":[
 {"id":"A","title":"alpha","wave":1,"depends":[],"criteria":["C1"],"goal":"a","risky":false},
 {"id":"B","title":"beta","wave":1,"depends":[],"criteria":["C2"],"goal":"b","risky":true},
 {"id":"C","title":"gamma","wave":2,"depends":["A"],"criteria":["C3"],"goal":"c","risky":false}]}
EOF
ok "note --plan takes the object shape" '$O note --run $RUN --plan $S/plan.json >/dev/null && [ "$(J $D/plan.json "d[\"merge_policy\"]")" = auto ]'

# state merge must leave alone when it refuses: remote branch, feature HEAD, locks, worker record, events, NEEDS YOU
snap(){ echo "$(remote $BR) $(git -C $FEAT rev-parse HEAD) $($O locks --repo $R | cksum) $(cat $D/workers/$1.json 2>/dev/null | cksum) $(cat $ORCH_HOME/events/*.jsonl 2>/dev/null | cksum) $(cat $D/waiting.json 2>/dev/null | cksum)"; }
merge(){ out=$($O merge --run $RUN "$@" 2>&1); rc=$?; }

echo "-- merge: exit 4 (evidence missing / stale / sha mismatch), nothing changed"
HA1=$(commit $WA a1 a1.txt)
$O lock --repo $R --owner $RUN-A a1.txt >/dev/null
before=$(snap A)
merge --slice A --sha $HA1
ok "no evidence → 4" '[ $rc = 4 ]'; ok "  …nothing changed" '[ "$(snap A)" = "$before" ]'
evidence A $HA1; HA2=$(commit $WA a2 a2.txt)
merge --slice A --sha $HA2
ok "evidence names an older sha → 4" '[ $rc = 4 ]'; ok "  …nothing changed" '[ "$(snap A)" = "$before" ]'
evidence A $HA2
merge --slice A --sha $HA1
ok "--sha isn't the branch head → 4" '[ $rc = 4 ]'; ok "  …nothing changed" '[ "$(snap A)" = "$before" ]'
merge --slice A --sha HEAD
ok "--sha that isn't a sha → 4" '[ $rc = 4 ]'; ok "  …nothing changed" '[ "$(snap A)" = "$before" ]'
ok "--sha is required" '! $O merge --run $RUN --slice A >/dev/null 2>&1 && [ "$(snap A)" = "$before" ]'

echo "-- merge: a failed push rolls the feature worktree back"
printf '#!/bin/sh\n[ -f %s/reject ] && exit 1\nexit 0\n' $S > $S/origin.git/hooks/pre-receive; chmod +x $S/origin.git/hooks/pre-receive
touch $S/reject; merge --slice A --sha $HA2
ok "push refused → non-zero" '[ $rc != 0 ]'; ok "  …nothing changed (feature HEAD back, lock kept)" '[ "$(snap A)" = "$before" ]'
rm $S/reject

echo "-- merge: exit 0"
merge --slice A --sha ${HA2:0:12}
ok "merge A → 0" '[ $rc = 0 ]'
ok "origin orch/<run> = A's head" '[ "$(remote $BR)" = "$HA2" ]'
ok "feature worktree fast-forwarded" '[ "$(git -C $FEAT rev-parse HEAD)" = "$HA2" ] && [ "$(git -C $FEAT symbolic-ref --short HEAD)" = "$BR" ]'
ok "A's file locks released" '! $O locks --repo $R | grep -q "$RUN-A "'
ok "A marked merged with its sha" '[ "$(J $D/workers/A.json "d[\"status\"] + \" \" + d[\"sha\"]")" = "merged $HA2" ]'
ok "merged event appended" 'grep "\"event\": \"merged\"" $ORCH_HOME/events/*.jsonl | grep -q "$HA2"'
ok "an auto merge doesn't notify" '[ "$(notifies)" = 0 ]'
$O close --run $RUN --slice A >/dev/null 2>&1
ok "close after the merge: worktree gone, A still merged" '[ ! -d $WA ] && [ "$(J $D/workers/A.json "d[\"status\"]")" = merged ]'

echo "-- merge: exit 2 (not a fast-forward)"
WB=$(git -C $R worktree add -q $R/.claude/worktrees/$RUN-B -b worktree-$RUN-B $M0 && echo $R/.claude/worktrees/$RUN-B)
HB1=$(commit $WB b1 b1.txt); evidence B $HB1
before=$(snap B); merge --slice B --sha $HB1
ok "B based on the old orch/<run> → 2" '[ $rc = 2 ] && grep -q REBASE <<< "$out"'; ok "  …nothing changed" '[ "$(snap B)" = "$before" ]'

echo "-- merge: exit 3 (risky task), then --user-ok"
git -C $WB rebase -q origin/$BR; HB2=$(git -C $WB rev-parse HEAD); evidence B $HB2
before=$(snap B); merge --slice B --sha $HB2
ok "risky B → 3" '[ $rc = 3 ]'
ok "  …one NEEDS YOU item naming B and its sha" '[ "$(J $D/waiting.json "len(d)")" = 1 ] && grep -q "$HB2" $D/waiting.json && grep -q B $D/waiting.json'
ok "  …prints the item number" 'grep -qw 1 <<< "$out"'
ok "  …exactly one notification" '[ "$(notifies)" = 1 ] && grep "^notify " $CMUX_LOG | grep -q "Orchestra: needs you"'
ok "  …nothing else changed" '[ "$(remote $BR) $(git -C $FEAT rev-parse HEAD)" = "$HA2 $HA2" ] && [ "$(J $D/workers/B.json "d.get(\"status\")" 2>/dev/null)" != merged ]'
merge --slice B --sha $HB2
ok "asked again → 3, still one item, no second notification" '[ $rc = 3 ] && [ "$(J $D/waiting.json "len(d)")" = 1 ] && [ "$(notifies)" = 1 ]'
merge --slice B --sha $HA2 --user-ok
ok "--user-ok with a sha that isn't B's head → 4" '[ $rc = 4 ] && [ "$(remote $BR)" = "$HA2" ]'
merge --slice B --sha $HB2 --user-ok
ok "--user-ok → 0" '[ $rc = 0 ] && [ "$(remote $BR)" = "$HB2" ] && [ "$(J $D/workers/B.json "d[\"status\"]")" = merged ]'
ok "  …and its NEEDS YOU item is cleared" '[ "$(J $D/waiting.json "len(d)")" = 0 ]'
$O note --run $RUN --done 1 >/dev/null
ok "the skill's follow-up --done of that number is harmless" '[ "$(J $D/waiting.json "len(d)")" = 0 ]'

echo "-- merge: exit 3 under merge_policy manual"
python3 - $S/plan.json <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["merge_policy"]="manual"; json.dump(d,open(p,"w"))
PY
$O note --run $RUN --plan $S/plan.json >/dev/null
WC=$(wt C); HC=$(commit $WC c1 c1.txt); evidence C $HC
merge --slice C --sha $HC --user-ok
ok "--user-ok for a sha the user was never asked about → 3, not merged" '[ $rc = 3 ] && grep -q "wasn.t asked" <<< "$out" && [ "$(remote $BR)" = "$HB2" ] && grep -q "$HC" $D/waiting.json'
merge --slice C --sha $HC
ok "manual policy, non-risky C → 3, the same item (one more notification in all)" '[ $rc = 3 ] && [ "$(notifies)" = 2 ] && [ "$(J $D/waiting.json "len(d)")" = 1 ] && [ "$(remote $BR)" = "$HB2" ]'
git -C $WC commit -q --allow-empty -m c2; HC2=$(git -C $WC rev-parse HEAD); evidence C $HC2
merge --slice C --sha $HC2 --user-ok
ok "the worker moved on (new sha): the old OK doesn't cover it → 3, a new item" '[ $rc = 3 ] && [ "$(remote $BR)" = "$HB2" ] && grep -q "$HC2" $D/waiting.json'
merge --slice C --sha $HC2 --user-ok
ok "--user-ok → 0" '[ $rc = 0 ] && [ "$(remote $BR)" = "$HC2" ] && ! grep -q "$HC2" $D/waiting.json'
ok "  …the stale question about C's older sha is cleared too" '! grep -q "OK to merge C " $D/waiting.json'
$O note --run $RUN --done all >/dev/null

echo "-- ship: exit 2 while a plan task isn't merged"
python3 - $S/plan.json <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["tasks"].append({"id":"E","title":"eps","wave":3,"depends":[],"criteria":[],"goal":"e","risky":False}); json.dump(d,open(p,"w"))
PY
$O note --run $RUN --plan $S/plan.json >/dev/null
out=$($O ship --run $RUN 2>&1); rc=$?
ok "E unmerged → 2, names E" '[ $rc = 2 ] && grep -q E <<< "$out"'; ok "  …main untouched" '[ "$(remote main)" = "$M0" ] && [ "$(remote $BR)" = "$HC2" ]'
python3 - $S/plan.json <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["tasks"]=[t for t in d["tasks"] if t["id"]!="E"]; json.dump(d,open(p,"w"))
PY
$O note --run $RUN --plan $S/plan.json >/dev/null

echo "-- ship: exit 4 (main moved; rebased locally, nothing pushed)"
git -C $R checkout -q main; echo m > $R/m.txt; git -C $R add m.txt; git -C $R commit -qm moved; git -C $R push -q origin main; M1=$(git -C $R rev-parse HEAD)
out=$($O ship --run $RUN 2>&1); rc=$?
NEW=$(git -C $FEAT rev-parse HEAD)
ok "moved main → 4 with 'rebased to <sha>'" '[ $rc = 4 ] && grep -q "rebased to $NEW" <<< "$out"'
ok "  …feature worktree now sits on the new main" 'git -C $FEAT merge-base --is-ancestor $M1 $NEW && [ "$NEW" != "$HC2" ]'
ok "  …nothing pushed" '[ "$(remote main)" = "$M1" ] && [ "$(remote $BR)" = "$HC2" ]'
WX=$(wt X); HX=$(commit $WX x1 x1.txt); evidence X $HX; before=$(snap X)
merge --slice X --sha $HX
ok "merge after the ship rebase is refused, nothing changed" '[ $rc != 0 ] && [ "$(snap X)" = "$before" ]'

echo "-- ship: exit 0 (fast-forward, never forced)"
out=$($O ship --run $RUN 2>&1); rc=$?
ok "ship → 0, prints the sha" '[ $rc = 0 ] && grep -q "$NEW" <<< "$out"'
ok "main = the feature head" '[ "$(remote main)" = "$NEW" ]'
ok "never forced: the old main is an ancestor of the new one" 'git -C $S/origin.git merge-base --is-ancestor $M1 $NEW'
ok "per-task commits kept" '[ "$(git -C $S/origin.git log --format=%s $M1..main | tr "\n" " ")" = "c2 c1 b1 a2 a1 " ]'
ok "remote feature branch deleted" '[ -z "$(remote $BR)" ]'
out=$($O run-branch --run $RUN 2>&1); rc=$?
ok "run-branch after the ship refuses (doesn't bring the remote branch back)" '[ $rc != 0 ] && grep -q "already shipped" <<< "$out" && [ -z "$(remote $BR)" ]'

echo "-- end-run after ship tears down the feature worktree"
$O end-run --run $RUN >/dev/null 2>&1
ok "feature worktree gone" '[ ! -d $FEAT ] && ! git -C $R worktree list | grep -q "$FEAT"'
ok "shipped local branch deleted" '! git -C $R rev-parse -q --verify refs/heads/$BR >/dev/null'

echo "-- ship: exit 3 (conflict with main), nothing pushed"
RUN2=$($O new-run --repo $R --title k$$ --coordinator surface:7); D2=$ORCH_HOME/runs/$RUN2; F2=$D2/feature; BR2=orch/$RUN2
$O run-branch --run $RUN2 >/dev/null
echo '[{"id":"K","title":"kappa","wave":1,"depends":[]}]' > $S/plan2.json; $O note --run $RUN2 --plan $S/plan2.json >/dev/null
git -C $R fetch -q origin; git -C $R worktree add -q $R/.claude/worktrees/$RUN2-K -b worktree-$RUN2-K origin/$BR2; WK=$R/.claude/worktrees/$RUN2-K
HK=$(commit $WK kappa a.txt); printf 'sha: %s\n' $HK > $D2/slices/K.ready.md
out=$($O merge --run $RUN2 --slice K --sha $HK 2>&1); rc=$?
ok "bare-list plan = auto, not risky → merge 0" '[ $rc = 0 ] && [ "$(remote $BR2)" = "$HK" ]'
git -C $R pull -q --ff-only origin main; echo other > $R/a.txt; git -C $R commit -qam conflict; git -C $R push -q origin main; M2=$(git -C $R rev-parse HEAD)
out=$($O ship --run $RUN2 2>&1); rc=$?
ok "conflict → 3" '[ $rc = 3 ]'
ok "  …nothing pushed" '[ "$(remote main)" = "$M2" ] && [ "$(remote $BR2)" = "$HK" ]'
ok "  …rebase aborted, feature worktree unchanged" '[ "$(git -C $F2 rev-parse HEAD)" = "$HK" ] && [ "$(git -C $F2 symbolic-ref --short HEAD)" = "$BR2" ] && [ ! -d "$(git -C $F2 rev-parse --git-path rebase-merge)" ] && [ -z "$(git -C $F2 status --porcelain --untracked-files=no)" ]'

echo "-- the conflict-fix task (merges main), main moves again: ship rebases keeping that merge, then ships"
echo '[{"id":"K","title":"kappa","wave":1,"depends":[]},{"id":"Q","title":"fix","wave":2,"depends":[]}]' > $S/plan2.json; $O note --run $RUN2 --plan $S/plan2.json >/dev/null
git -C $R worktree add -q $R/.claude/worktrees/$RUN2-Q -b worktree-$RUN2-Q origin/$BR2; WQ=$R/.claude/worktrees/$RUN2-Q
git -C $WQ merge -q origin/main >/dev/null 2>&1; echo both > $WQ/a.txt; git -C $WQ add a.txt; git -C $WQ commit -qm "merge main"
HQ=$(git -C $WQ rev-parse HEAD); printf 'sha: %s\n' $HQ > $D2/slices/Q.ready.md
out=$($O merge --run $RUN2 --slice Q --sha $HQ 2>&1); rc=$?
ok "merge-fix task merges (fast-forward) → 0" '[ $rc = 0 ] && [ "$(remote $BR2)" = "$HQ" ]'
echo z > $R/z.txt; git -C $R add z.txt; git -C $R commit -qm "main again"; git -C $R push -q origin main; M3=$(git -C $R rev-parse HEAD)
out=$($O ship --run $RUN2 2>&1); rc=$?
# a rebase can't replay a merge's conflict resolution: the conflict comes back → 3 again, nothing pushed
ok "main moved again after a conflict fix → 3 again, nothing pushed" '[ $rc = 3 ] && [ "$(remote main)" = "$M3" ] && [ "$(git -C $F2 rev-parse HEAD)" = "$HQ" ]'
echo '[{"id":"K","title":"kappa","wave":1,"depends":[]},{"id":"Q","title":"fix","wave":2,"depends":[]},{"id":"Q2","title":"fix2","wave":3,"depends":[]}]' > $S/plan2.json; $O note --run $RUN2 --plan $S/plan2.json >/dev/null
git -C $R worktree add -q $R/.claude/worktrees/$RUN2-Q2 -b worktree-$RUN2-Q2 origin/$BR2; WQ2=$R/.claude/worktrees/$RUN2-Q2
git -C $WQ2 merge -q --no-edit origin/main; HQ2=$(git -C $WQ2 rev-parse HEAD); printf 'sha: %s\n' $HQ2 > $D2/slices/Q2.ready.md
$O merge --run $RUN2 --slice Q2 --sha $HQ2 >/dev/null 2>&1
out=$($O ship --run $RUN2 2>&1); rc=$?
ok "a second merge-fix → ship 0, a fast-forward keeping both merge commits" '[ $rc = 0 ] && [ "$(remote main)" = "$HQ2" ] && git -C $S/origin.git merge-base --is-ancestor $M3 main && [ "$(git -C $S/origin.git rev-list --count --merges $M2..main)" = 2 ] && [ "$(git -C $S/origin.git show main:a.txt)" = both ]'
$O end-run --run $RUN2 >/dev/null 2>&1
ok "end-run: feature worktree and the shipped local branch gone" '[ ! -d $F2 ] && ! git -C $R rev-parse -q --verify refs/heads/$BR2 >/dev/null'

echo "-- end-run of an unshipped run keeps its local feature branch"
RUN4=$($O new-run --repo $R --title u$$ --coordinator surface:7); D4=$ORCH_HOME/runs/$RUN4; F4=$D4/feature; BR4=orch/$RUN4
$O run-branch --run $RUN4 >/dev/null
ok "the feature branch tracks nothing (not origin/main)" '! git -C $F4 rev-parse -q --verify "@{upstream}" >/dev/null 2>&1'
echo '[{"id":"U","title":"u","wave":1,"depends":[]},{"id":"V","title":"auth","wave":1,"depends":[],"risky":true}]' > $S/plan4.json; $O note --run $RUN4 --plan $S/plan4.json >/dev/null
git -C $R worktree add -q $R/.claude/worktrees/$RUN4-U -b worktree-$RUN4-U origin/$BR4; WU=$R/.claude/worktrees/$RUN4-U; HU=$(commit $WU u u.txt)
printf 'sha: %s\n' $HU > $D4/slices/U.ready.md; $O register --worktree $WU --run $RUN4 --slice U >/dev/null
out=$(cd $WU && $O merge --run $RUN4 --slice U --sha $HU 2>&1); rc=$?
ok "a worker's own checkout can't merge" '[ $rc != 0 ] && grep -q "workers never merge" <<< "$out" && [ "$(remote $BR4)" != "$HU" ]'
out=$(cd $WU && $O ship --run $RUN4 2>&1); rc=$?
ok "…nor ship" '[ $rc != 0 ] && grep -q "workers never merge or ship" <<< "$out"'
$O merge --run $RUN4 --slice U --sha $HU >/dev/null 2>&1
ok "merge from the manager → pushed" '[ "$(remote $BR4)" = "$HU" ]'

echo "-- bare-list plan: a task's own risky flag counts"
git -C $R worktree add -q $R/.claude/worktrees/$RUN4-V -b worktree-$RUN4-V origin/$BR4; HV=$(commit $R/.claude/worktrees/$RUN4-V v v.txt); printf 'sha: %s\n' $HV > $D4/slices/V.ready.md
out=$($O merge --run $RUN4 --slice V --sha $HV 2>&1); rc=$?
ok "bare list with risky:true → 3" '[ $rc = 3 ] && [ "$(remote $BR4)" = "$HU" ]'

echo "-- a slice not in plan.json (or no plan.json): 3, the manager fixes the plan — no NEEDS YOU item, no notification"
git -C $R worktree add -q $R/.claude/worktrees/$RUN4-W -b worktree-$RUN4-W origin/$BR4; HW=$(commit $R/.claude/worktrees/$RUN4-W w w.txt); printf 'sha: %s\n' $HW > $D4/slices/W.ready.md
n0=$(notifies); w0=$(cksum < $D4/waiting.json)
out=$($O merge --run $RUN4 --slice W --sha $HW 2>&1); rc=$?
ok "slice not in plan.json → 3, told to add it to plan.json" '[ $rc = 3 ] && grep -q "add W to plan.json" <<< "$out" && [ "$(remote $BR4)" = "$HU" ]'
ok "  …no NEEDS YOU item, no notification" '[ "$(cksum < $D4/waiting.json)" = "$w0" ] && [ "$(notifies)" = "$n0" ]'
out=$($O merge --run $RUN4 --slice W --sha $HW --user-ok 2>&1); rc=$?
ok "  …--user-ok doesn't get past it either" '[ $rc = 3 ] && [ "$(remote $BR4)" = "$HU" ] && [ "$(cksum < $D4/waiting.json)" = "$w0" ]'
mv $D4/plan.json $S/plan4.keep
out=$($O merge --run $RUN4 --slice W --sha $HW 2>&1); rc=$?
ok "no plan.json → 3, no item, no notification" '[ $rc = 3 ] && grep -q "add W to plan.json" <<< "$out" && [ "$(remote $BR4)" = "$HU" ] && [ "$(cksum < $D4/waiting.json)" = "$w0" ] && [ "$(notifies)" = "$n0" ]'
mv $S/plan4.keep $D4/plan.json

echo "-- an open item for another reason never counts as the user's OK (W added to plan.json as risky afterwards)"
$O note --run $RUN4 --wait "OK to merge W at $HW into $BR4? (not in plan.json; evidence $D4/slices/W.ready.md)" >/dev/null
NS=$(J $D4/waiting.json "[x[\"n\"] for x in d if \"not in plan.json\" in x[\"text\"]][0]")
echo '[{"id":"U","title":"u","wave":1,"depends":[]},{"id":"V","title":"auth","wave":1,"depends":[],"risky":true},{"id":"W","title":"w","wave":1,"depends":[],"risky":true}]' > $S/plan4.json; $O note --run $RUN4 --plan $S/plan4.json >/dev/null
out=$($O merge --run $RUN4 --slice W --sha $HW --user-ok 2>&1); rc=$?
ok "a 'not in plan.json' item for W at this sha + --user-ok → 3, not merged" '[ $rc = 3 ] && grep -q "wasn.t asked" <<< "$out" && [ "$(remote $BR4)" = "$HU" ] && [ ! -f $D4/workers/W.json ]'
ok "  …a risky-task item for W opens (the user is asked now)" 'grep -q "OK to merge W w at $HW into $BR4? (risky task;" $D4/waiting.json'
$O note --run $RUN4 --done $NS >/dev/null

echo "-- NEEDS YOU numbers stay fixed when an earlier item is cleared"
NV=$(J $D4/waiting.json "[x[\"n\"] for x in d if \" V \" in x[\"text\"]][0]"); NW=$(J $D4/waiting.json "[x[\"n\"] for x in d if \" W \" in x[\"text\"]][0]")
$O note --run $RUN4 --done $NV >/dev/null
ok "clearing V's number removes V only" '! grep -q " V " $D4/waiting.json && grep -q " W " $D4/waiting.json'
$O note --run $RUN4 --wait "Another question" >/dev/null
NA=$(J $D4/waiting.json "[x[\"n\"] for x in d if x[\"text\"] == \"Another question\"][0]")
ok "a new item gets a number never used before" '[ "$NA" -gt "$NW" ] && [ "$NA" -gt "$NV" ]'
out=$($O merge --run $RUN4 --slice W --sha $HW 2>/dev/null)
ok "merge exit 3 again prints W's same number" '[ "$(echo "$out" | head -1)" = "$NW" ]'
$O note --run $RUN4 --done $NW >/dev/null
ok "W's saved number clears W, not the newer item" '! grep -q " W " $D4/waiting.json && grep -q "Another question" $D4/waiting.json'
$O note --run $RUN4 --done all >/dev/null

echo "-- only the question merge itself asked counts: not a hand-written look-alike, not one asked for another reason"
EV4=$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]))" $D4/slices/V.ready.md)   # the path as merge writes it (TMPDIR may end in /)
$O note --run $RUN4 --wait "OK to merge V auth at $HV into $BR4? (risky task; evidence $EV4)" >/dev/null
n0=$(notifies); out=$($O merge --run $RUN4 --slice V --sha $HV --user-ok 2>&1); rc=$?
ok "a note --wait with merge's exact wording + --user-ok → 3, not merged" '[ $rc = 3 ] && grep -q "wasn.t asked" <<< "$out" && [ "$(remote $BR4)" = "$HU" ] && [ ! -f $D4/workers/V.json ]'
ok "  …merge takes that item as its own question (one item, no second notification)" '[ "$(J $D4/waiting.json "len(d)")" = 1 ] && [ "$(notifies)" = "$n0" ]'
$O note --run $RUN4 --done all >/dev/null
echo '{"merge_policy":"manual","tasks":[{"id":"U","title":"u","wave":1,"depends":[]},{"id":"W","title":"w","wave":1,"depends":[]}]}' > $S/plan4m.json; $O note --run $RUN4 --plan $S/plan4m.json >/dev/null
out=$($O merge --run $RUN4 --slice W --sha $HW 2>&1); rc=$?
ok "manual policy: W → 3, asked as 'merge policy manual'" '[ $rc = 3 ] && grep -q "(merge policy manual;" $D4/waiting.json'
$O note --run $RUN4 --plan $S/plan4.json >/dev/null   # W risky again
out=$($O merge --run $RUN4 --slice W --sha $HW --user-ok 2>&1); rc=$?
ok "W made risky after that question: --user-ok → 3, not merged, asked again as a risky task" '[ $rc = 3 ] && [ "$(remote $BR4)" = "$HU" ] && [ ! -f $D4/workers/W.json ] && grep -q "OK to merge W w at $HW into $BR4? (risky task;" $D4/waiting.json'
$O note --run $RUN4 --done all >/dev/null

echo "-- unreadable plan.json: merge refuses, nothing changed"
cp $D4/plan.json $S/plan4.bak; echo '{not json' > $D4/plan.json
out=$($O merge --run $RUN4 --slice W --sha $HW --user-ok 2>&1); rc=$?
ok "bad plan.json → 1, nothing pushed" '[ $rc = 1 ] && [ "$(remote $BR4)" = "$HU" ]'
cp $S/plan4.bak $D4/plan.json

echo "-- two merges at once: they take turns (one merges, the other is told to rebase)"
echo '[{"id":"U","title":"u","wave":1,"depends":[]},{"id":"G","title":"g","wave":1,"depends":[]},{"id":"H","title":"h","wave":1,"depends":[]}]' > $S/plan4.json; $O note --run $RUN4 --plan $S/plan4.json >/dev/null
for x in G H; do git -C $R worktree add -q $R/.claude/worktrees/$RUN4-$x -b worktree-$RUN4-$x origin/$BR4; done
HG=$(commit $R/.claude/worktrees/$RUN4-G g g.txt); HH=$(commit $R/.claude/worktrees/$RUN4-H h h.txt)
printf 'sha: %s\n' $HG > $D4/slices/G.ready.md; printf 'sha: %s\n' $HH > $D4/slices/H.ready.md
$O merge --run $RUN4 --slice G --sha $HG >/dev/null 2>&1 & PG=$!
$O merge --run $RUN4 --slice H --sha $HH >/dev/null 2>&1 & PH=$!
wait $PG; RG=$?; wait $PH; RH=$?
WIN=$([ $RG = 0 ] && echo $HG || echo $HH); LOSE=$([ $RG = 0 ] && echo H || echo G)
ok "exactly one merged (0), the other told to rebase (2)" '[ "$RG $RH" = "0 2" ] || [ "$RG $RH" = "2 0" ]'
ok "  …origin and the feature worktree agree on the winner" '[ "$(remote $BR4)" = "$WIN" ] && [ "$(git -C $F4 rev-parse HEAD)" = "$WIN" ]'
ok "  …the loser isn't marked merged" '[ ! -f $D4/workers/$LOSE.json ]'
LH=$([ $LOSE = G ] && echo $HG || echo $HH)
ok "  …no commits lost: the loser's branch still holds its head" '[ "$(git -C $R rev-parse refs/heads/worktree-$RUN4-$LOSE)" = "$LH" ]'
git -C $R worktree remove --force $R/.claude/worktrees/$RUN4-$LOSE
WON=$([ $LOSE = G ] && echo H || echo G)   # the plan drops the loser so ship below gets past "not merged"
echo '[{"id":"U","title":"u","wave":1,"depends":[]},{"id":"'$WON'","title":"w","wave":1,"depends":[]}]' > $S/plan4.json; $O note --run $RUN4 --plan $S/plan4.json >/dev/null

echo "-- run-branch again after the feature worktree was lost: rebuilt from origin/orch/<run>, not main"
rm -rf $F4; git -C $R branch -q -f $BR4 $HU   # deleted by hand (git still lists it), and the local branch behind origin
out=$($O run-branch --run $RUN4 2>&1); rc=$?
ok "run-branch → 0, feature worktree caught up to the merged head" '[ $rc = 0 ] && [ "$(git -C $F4 rev-parse HEAD)" = "$WIN" ] && [ "$(remote $BR4)" = "$WIN" ]'

echo "-- ship refuses a head that lacks commits on origin/orch/<run>"
git -C $R fetch -q origin; git -C $R worktree add -q $S/stray -b stray origin/$BR4; HS=$(commit $S/stray stray s.txt)
git -C $S/stray push -q origin HEAD:$BR4; git -C $R worktree remove --force $S/stray
out=$($O ship --run $RUN4 2>&1); rc=$?
ok "a commit only on origin/orch/<run> → 1, nothing pushed, branch kept" '[ $rc = 1 ] && grep -q stray <<< "$out" && [ "$(remote main)" != "$WIN" ] && [ "$(remote $BR4)" = "$HS" ]'
git -C $R checkout -q main; git -C $R pull -q --ff-only origin main; echo mv > $R/mv4.txt; git -C $R add mv4.txt; git -C $R commit -qm "main moves"; git -C $R push -q origin main; MV4=$(git -C $R rev-parse HEAD)
out=$($O ship --run $RUN4 2>&1); rc=$?
ok "…and with main moved too: still 1 before any rebase (no record vouches for the stray commit)" '[ $rc = 1 ] && grep -q stray <<< "$out" && [ "$(git -C $F4 rev-parse HEAD)" = "$WIN" ] && [ "$(J $D4/run.json "d.get(\"rebased\")")" = None ]'
out=$($O ship --run $RUN4 2>&1); rc=$?
ok "  …every retry: 1, main and origin/orch/<run> untouched" '[ $rc = 1 ] && [ "$(remote main)" = "$MV4" ] && [ "$(remote $BR4)" = "$HS" ]'

$O end-run --run $RUN4 --status aborted >/dev/null 2>&1
ok "end-run (aborted): feature worktree gone, local orch/<run> carries everything origin/orch/<run> had" '[ ! -d $F4 ] && [ "$(git -C $R rev-parse -q --verify refs/heads/$BR4)" = "$HS" ] && git -C $R merge-base --is-ancestor $WIN $HS'
ok "  …the remote branch is deleted only after that" '[ -z "$(remote $BR4)" ]'

echo "-- ship after a clean rebase whose context changed (main edits a line near a task's edit): 4, then 0"
git -C $R checkout -q main; git -C $R pull -q --ff-only origin main
seq 1 20 > $R/f.txt; git -C $R add f.txt; git -C $R commit -qm lines; git -C $R push -q origin main
RUN6=$($O new-run --repo $R --title r$$ --coordinator surface:7); D6=$ORCH_HOME/runs/$RUN6; F6=$D6/feature; BR6=orch/$RUN6
$O run-branch --run $RUN6 >/dev/null
echo '[{"id":"N","title":"near","wave":1,"depends":[]}]' > $S/plan6.json; $O note --run $RUN6 --plan $S/plan6.json >/dev/null
git -C $R worktree add -q $R/.claude/worktrees/$RUN6-N -b worktree-$RUN6-N origin/$BR6; WN=$R/.claude/worktrees/$RUN6-N
sed -i '' 's/^12$/twelve/' $WN/f.txt; git -C $WN commit -qam twelve; HN=$(git -C $WN rev-parse HEAD); printf 'sha: %s\n' $HN > $D6/slices/N.ready.md
$O merge --run $RUN6 --slice N --sha $HN >/dev/null 2>&1
sed -i '' 's/^10$/ten/' $R/f.txt; git -C $R commit -qam ten; git -C $R push -q origin main; M6=$(git -C $R rev-parse HEAD)
out=$($O ship --run $RUN6 2>&1); rc=$?; N6=$(git -C $F6 rev-parse HEAD)
ok "near-line main edit → 4 (clean rebase)" '[ $rc = 4 ] && [ "$(sed -n 10p $F6/f.txt) $(sed -n 12p $F6/f.txt)" = "ten twelve" ]'
out=$($O ship --run $RUN6 2>&1); rc=$?
ok "…ship again → 0 (the rebased head carries origin/orch/<run>'s work)" '[ $rc = 0 ] && [ "$(remote main)" = "$N6" ] && git -C $S/origin.git merge-base --is-ancestor $M6 main && [ -z "$(remote $BR6)" ]'
$O end-run --run $RUN6 >/dev/null 2>&1

echo "-- the merge lock: a second merge waits a bounded time, then says so (nothing changed)"
RUN7=$($O new-run --repo $R --title l$$ --coordinator surface:7); D7=$ORCH_HOME/runs/$RUN7; $O run-branch --run $RUN7 >/dev/null
echo '[{"id":"L","title":"l","wave":1,"depends":[]}]' > $S/plan7.json; $O note --run $RUN7 --plan $S/plan7.json >/dev/null
git -C $R worktree add -q $R/.claude/worktrees/$RUN7-L -b worktree-$RUN7-L origin/orch/$RUN7; HL=$(commit $R/.claude/worktrees/$RUN7-L l l.txt); printf 'sha: %s\n' $HL > $D7/slices/L.ready.md
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(30)' $ORCH_HOME/state/feature-$RUN7.flock $S/held & HOLD=$!
for i in $(seq 50); do [ -f $S/held ] && break; sleep 0.1; done
out=$(ORCH_FEATURE_LOCK_SECS=1 $O merge --run $RUN7 --slice L --sha $HL 2>&1); rc=$?
ok "lock held elsewhere → 1 after the bounded wait, with a clear message" '[ $rc = 1 ] && grep -q "another orch merge/ship.* of $RUN7 is still running after 1s" <<< "$out"'
ok "  …nothing changed" '[ "$(remote orch/$RUN7)" != "$HL" ] && [ ! -f $D7/workers/L.json ]'
kill $HOLD; wait $HOLD 2>/dev/null
out=$($O merge --run $RUN7 --slice L --sha $HL 2>&1); rc=$?
ok "released when its holder exits → the merge goes through" '[ $rc = 0 ] && [ "$(remote orch/$RUN7)" = "$HL" ]'
out=$(ORCH_FEATURE_LOCK_SECS=abc $O status 2>&1); rc=$?
ok "a bad ORCH_FEATURE_LOCK_SECS breaks no other command" '[ $rc = 0 ]'
out=$(ORCH_FEATURE_LOCK_SECS=abc $O merge --run $RUN7 --slice L --sha $HL 2>&1); rc=$?
ok "…merge says what's wrong with it" '[ $rc = 1 ] && grep -q "ORCH_FEATURE_LOCK_SECS must be a number" <<< "$out"'

echo "-- end-run keeps a remote feature branch nothing else carries (local and origin diverged)"
F7=$D7/feature; echo loc > $F7/loc.txt; git -C $F7 add loc.txt; git -C $F7 commit -qm local-only; HLOC=$(git -C $F7 rev-parse HEAD)
git -C $R fetch -q origin; git -C $R worktree add -q $S/stray7 -b stray7 origin/orch/$RUN7; HS7=$(commit $S/stray7 stray7 s7.txt)
git -C $S/stray7 push -q origin HEAD:orch/$RUN7; git -C $R worktree remove --force $S/stray7
out=$($O end-run --run $RUN7 --status aborted 2>&1)
ok "diverged: origin/orch/<run> kept (its commit is nowhere else), and the local branch too" '[ "$(remote orch/$RUN7)" = "$HS7" ] && [ "$(git -C $R rev-parse -q --verify refs/heads/orch/$RUN7)" = "$HLOC" ] && grep -q "kept origin/orch/$RUN7" <<< "$out"'

echo "-- new-run records the coordinator's stable id"
RUN5=$($O new-run --repo $R --title c$$); D5=$ORCH_HOME/runs/$RUN5
ok "from cmux identify: coordinator = its surface ref, coordinator_id = its surface uuid" '[ "$(J $D5/run.json "d[\"coordinator\"] + \" \" + str(d[\"coordinator_id\"])")" = "surface:9 SURF-UUID-9" ]'
ok "--coordinator <ref>: its uuid from cmux tree" '[ "$(J $D/run.json "d.get(\"coordinator_id\")")" = COORD-UUID-7 ]'
$O end-run --run $RUN5 --status aborted >/dev/null 2>&1

echo "-- note --wait: one notification per new item; a cmux failure doesn't fail the note"
RUN3=$($O new-run --repo $R --title n$$ --coordinator surface:7); D3=$ORCH_HOME/runs/$RUN3; : > $CMUX_LOG
$O note --run $RUN3 --wait "Pick a colour" >/dev/null
$O note --run $RUN3 --wait "Pick a colour" >/dev/null
ok "same item twice → one notification" '[ "$(notifies)" = 1 ]'
ok "  …titled 'Orchestra: needs you', body = the item" 'grep "^notify " $CMUX_LOG | grep -q -- "--title Orchestra: needs you" && grep "^notify " $CMUX_LOG | grep -q -- "--body Pick a colour"'
$O note --run $RUN3 --next-tick 10:00 >/dev/null; $O note --run $RUN3 --finish 2 >/dev/null; $O note --run $RUN3 --done 1 >/dev/null
$O dash --run $RUN3 --once >/dev/null; $O report --run $RUN3 >/dev/null; $O status >/dev/null
ok "nothing else notifies" '[ "$(notifies)" = 1 ]'
CMUX_NOTIFY_FAIL=1 $O note --run $RUN3 --wait "Second question" >/dev/null 2>&1; rc=$?
ok "cmux notify failing: note still exits 0 and records the item" '[ $rc = 0 ] && grep -q "Second question" $D3/waiting.json'
$O end-run --run $RUN3 --status aborted >/dev/null 2>&1

echo "PASSED $P FAILED $F"; [ $F = 0 ]
