#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# orch and cmux's stable ids: spawn records the workspace/surface UUIDs, liveness and closing go by them, a reused
# short ref (workspace:N pointing at someone else's workspace) is never closed; old records without ids close only
# when the ref still names the worker's own workspace. end-run treats the integration worktree like a worker
# (NOT finished + retry hint; reap --run retries it). caffeinate: an isolated ORCH_HOME never starts the real one.
# Isolated ORCH_HOME per section; fake cmux (ORCH_CMUX) only.
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-orch-ids.XXXXXX"); cd $S  # unique: suites run concurrently
trap 'chmod -R u+w $S 2>/dev/null; for c in $(cat $S/caff.log 2>/dev/null); do kill $c 2>/dev/null; done; rm -rf $S' EXIT
O=$ROOT/bin/orch
export ORCH_PORT_BASE=${ORCH_TEST_PORT_BASE:-$((30000 + $$ % 300 * 100))} ORCH_PORT_SPAN=90  # private port range
mkdir -p $S/stub; export CAFF_LOG=$S/caff.log LOG=$S/cmux.log TREE=$S/tree.json ORCH_SKIP_TRUST=1
printf '#!/bin/sh\ntrap '"'"'kill $! 2>/dev/null; exit'"'"' TERM\necho $$ >> "$CAFF_LOG"\nsleep 120 & wait\n' > $S/stub/caffeinate  # trap first: no orphan sleep
for x in xcrun osascript claude; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; done
printf '#!/bin/sh\nexit 1\n' > $S/stub/cmux                                          # PATH cmux: never used (ORCH_CMUX is set)
# fake cmux: tree from $TREE (ids only with --id-format both, like the real CLI); new-workspace --name X answers the
# ref of the workspace titled X; workspace close / close-workspace / close-surface log and drop that node from $TREE
cat > $S/fakecmux <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
open(os.environ["LOG"], "a").write(" ".join(a) + "\n")
if os.environ.get("TREE_FAIL") and a[:1] == ["tree"]:
    sys.exit(1)
if os.environ.get("OLD_CMUX") and "--id-format" in a:  # a cmux from before --id-format: unknown flag
    sys.exit(1)
try:
    t = json.load(open(os.environ["TREE"]))
except Exception:
    t = {"windows": [{"workspaces": []}]}
wss = t["windows"][0]["workspaces"]
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if k != "id"}
    return [strip(v) for v in o] if isinstance(o, list) else o
def val(flag):
    return a[a.index(flag) + 1] if flag in a else None
if a[:1] == ["tree"]:
    print(json.dumps(t if "--id-format" in a and val("--id-format") == "both" else strip(t)))
elif a[:1] == ["identify"]:
    print('{"caller":{"surface_ref":"surface:77","workspace_ref":"workspace:7"}}')
elif a[:1] == ["new-workspace"]:
    hit = [w["ref"] for w in wss if w.get("title") == val("--name")]
    print(f"OK {hit[0]}" if hit else "OK workspace:404")
elif a[:2] in (["workspace", "close"], ["close-workspace"]) or a[:1] == ["close-workspace"]:
    x = val("--workspace")
    t["windows"][0]["workspaces"] = [w for w in wss if x not in (w["ref"], w.get("id"))]
    json.dump(t, open(os.environ["TREE"], "w"))
elif a[:1] == ["close-surface"]:
    x = val("--surface")
    for w in wss:
        for p in w.get("panes", []):
            p["surfaces"] = [s for s in p.get("surfaces", []) if x not in (s["ref"], s.get("id"))]
    json.dump(t, open(os.environ["TREE"], "w"))
elif a[:2] == ["workspace-group", "list"]:
    print('{"groups":[]}')
elif a[:2] == ["workspace-group", "create"]:
    print("OK workspace_group:9")
EOF
chmod +x $S/stub/* $S/fakecmux; export PATH=$S/stub:$PATH ORCH_CMUX=$S/fakecmux ORCH_CAFFEINATE=$S/stub/caffeinate
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1 :: rc=${rc:-} out=[${out:-}]"; fi; }
run(){ out=$("$@" 2>&1); rc=$?; }
home(){ export ORCH_HOME=$S/home-$1; }
jget(){ python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }
tree(){ # tree <ref=id=title=surface-ref=surface-id>... — the live workspaces, one surface each
  python3 - "$@" > $TREE <<'PY'
import json, sys
ws = []
for spec in sys.argv[1:]:
    ref, wid, title, sref, sid = spec.split("=")
    ws.append({"ref": ref, "id": wid, "title": title,
               "panes": [{"ref": "pane:" + ref.split(":")[1], "surfaces": [{"ref": sref, "id": sid, "title": "claude"}]}]})
print(json.dumps({"windows": [{"ref": "window:1", "id": "WIN-1", "workspaces": ws}]}))
PY
}
closes(){ grep -E '^(workspace close|close-workspace|close-surface)' $LOG; }

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo
echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main; R=$S/repo

echo "-- spawn records cmux's stable ids"
home spawn; RUN=$($O new-run --repo $R --title ids$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
printf '# A\n' > $D/slices/A.md; printf '# B\n' > $D/slices/B.md
tree "workspace:5=W5-A=$RUN-A=surface:51=S51-A" "workspace:6=W6-B=$RUN-B=surface:61=S61-B" "workspace:9=D9-A=$RUN dashboard=surface:91=S91"
: > $LOG; run $O spawn --run $RUN --slice A
ok "spawn A: ok" '[ $rc = 0 ]'
ok "spawn asks the tree for ids (--id-format both)" 'grep -q "^tree --all --json --id-format both" $LOG'
ok "worker record: ws_id + surface_id next to the refs" '[ "$(jget $D/workers/A.json ws_id)" = W5-A ] && [ "$(jget $D/workers/A.json surface_id)" = S51-A ] && [ "$(jget $D/workers/A.json ws_ref)" = workspace:5 ] && [ "$(jget $D/workers/A.json workspace)" = surface:51 ]'
ok "dashboard: dash_id recorded" '[ "$(jget $D/run.json dash_ws)" = workspace:9 ] && [ "$(jget $D/run.json dash_id)" = D9-A ]'
run $O spawn --run $RUN --slice B; ok "spawn B: ok" '[ $rc = 0 ] && [ "$(jget $D/workers/B.json ws_id)" = W6-B ]'

echo "-- close goes by the id"
: > $LOG; run $O close --run $RUN --slice B
ok "close B: workspace closed by its UUID, never by the short ref" '[ "$(closes)" = "workspace close --workspace W6-B --force" ]'
ok "close B: finished (no retry pending)" '[ -n "$(jget $D/workers/B.json cleaned)" ] && ! grep -q "not finished" <<< "$out"'

echo "-- a reused short ref is never closed"
# cmux restarted: workspace:5 / surface:51 now belong to someone else's workspace; A's own workspace is gone
tree "workspace:5=W5-OTHER=someone-else=surface:51=S51-OTHER" "workspace:9=D9-OTHER=someone-else-2=surface:91=S91-OTHER"
: > $LOG; run $O reap --keep-sim
ok "reap: A's surface id is gone → marked dead (the reused ref doesn't keep it alive)" '[ "$(jget $D/workers/A.json status)" = dead ]'
ok "reap: nothing closed" '[ -z "$(closes)" ]'
: > $LOG; run $O close --run $RUN --slice A
ok "close A: the reused workspace:5 is not closed" '[ $rc = 0 ] && [ -z "$(closes)" ]'
ok "close A: done, nothing pending (its own pane is already gone)" '[ -n "$(jget $D/workers/A.json cleaned)" ]'
: > $LOG; run $O end-run --run $RUN --status aborted --keep-sim
ok "end-run: the reused dashboard ref workspace:9 is not closed" '[ $rc = 0 ] && [ -z "$(closes)" ]'
ok "end-run: the other workspaces are still there" 'grep -q W5-OTHER $TREE && grep -q D9-OTHER $TREE'

echo "-- doctor and report read liveness by id"
home live; RUN=$($O new-run --repo $R --title live$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
echo '{"run":"'$RUN'","slice":"A","name":"'$RUN'-A","workspace":"surface:51","ws_ref":"workspace:5","ws_id":"W5-A","surface_id":"S51-A","status":"active"}' > $D/workers/A.json
tree "workspace:5=W5-OTHER=someone-else=surface:51=S51-OTHER"
run $O doctor --run $RUN; ok "doctor: reused ref → DEAD" 'grep -E "^ +A +DEAD" <<< "$out"'
tree "workspace:5=W5-A=$RUN-A=surface:51=S51-A"
run $O doctor --run $RUN; ok "doctor: own ids → alive" 'grep -E "^ +A +alive" <<< "$out"'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1

echo "-- records from before ids: close only the worker's own workspace"
home legacy; RUN=$($O new-run --repo $R --title leg$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
for sl in L1 L2 L3; do n=${sl#L}; echo '{"run":"'$RUN'","slice":"'$sl'","name":"'$RUN-$sl'","workspace":"surface:'$n'1","ws_ref":"workspace:'$n'","status":"done"}' > $D/workers/$sl.json; done
tree "workspace:1=W1=someone-else=surface:11=S11" "workspace:2=W2=$RUN-L2=surface:21=S21"
: > $LOG; run $O close --run $RUN --slice L1
ok "L1 (ref now names another workspace): not closed" '[ $rc = 0 ] && [ -z "$(closes)" ] && grep -q W1 $TREE'
ok "L1: reported as skipped, naming the ref" 'grep -qi "skipped" <<< "$out" && grep -q "workspace:1" <<< "$out"'
: > $LOG; run $O close --run $RUN --slice L2
ok "L2 (ref still names the worker's workspace): closed by its id" '[ "$(closes)" = "workspace close --workspace W2 --force" ]'
: > $LOG; run env TREE_FAIL=1 $O close --run $RUN --slice L3
ok "L3 with cmux unreadable: not closed, reported" '[ -z "$(closes)" ] && grep -qi "skipped" <<< "$out"'
python3 - $D/run.json <<'PY'
import json, sys; p = sys.argv[1]; r = json.load(open(p)); r["dash_ws"] = "workspace:2"; json.dump(r, open(p, "w"))
PY
tree "workspace:2=W2X=someone-else=surface:21=S21X"
: > $LOG; run $O end-run --run $RUN --status aborted --keep-sim
ok "legacy dash_ws naming another workspace: not closed" '[ -z "$(closes)" ] && grep -q W2X $TREE'
home dash3; RUN=$($O new-run --repo $R --title d3$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
python3 - $D/run.json <<'PY'
import json, sys; p = sys.argv[1]; r = json.load(open(p)); r["dash_ws"] = "workspace:9"; json.dump(r, open(p, "w"))
PY
printf '# A\n' > $D/slices/A.md
tree "workspace:9=W9X=someone-else=surface:91=S91X" "workspace:5=W5=$RUN-A=surface:51=S51" "workspace:4=D4=$RUN dashboard=surface:41=S41"
: > $LOG; $O spawn --run $RUN --slice A >/dev/null 2>&1
ok "legacy dash_ws reused by another workspace: a dashboard of its own is opened" 'grep -q "^new-workspace --name $RUN dashboard" $LOG && [ "$(jget $D/run.json dash_ws)" = workspace:4 ]'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1

echo "-- end-run: integration worktree like a worker"
home integ; RUN=$($O new-run --repo $R --title int$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
git -C $R worktree add -q .claude/worktrees/$RUN-integrate -b $RUN-integrate origin/main
IW=$R/.claude/worktrees/$RUN-integrate; echo x > $IW/x.txt
tree; chmod a-w $IW                                                            # git can't remove it this time
run $O end-run --run $RUN --status aborted --keep-sim
ok "end-run: integration left → NOT finished + retry hint" '[ -d $IW ] && grep -q "NOT finished $RUN-integrate" <<< "$out" && grep -q "orch reap --run $RUN" <<< "$out"'
chmod u+w $IW
run $O reap --run $RUN --keep-sim
ok "reap --run retries it: worktree + branch gone" '[ $rc = 0 ] && [ ! -d $IW ] && ! git -C $R rev-parse -q --verify refs/heads/$RUN-integrate >/dev/null'
ok "reap --run names what it cleaned" 'grep -q "$RUN-integrate" <<< "$out"'
run $O reap --run $RUN --keep-sim
ok "reap again: nothing left for the integration" '! grep -q "$RUN-integrate" <<< "$out"'
home integ2; RUN=$($O new-run --repo $R --title in2$$ --coordinator surface:77 --coordinator-workspace workspace:7)
IW=$R/.claude/worktrees/$RUN-integrate; mkdir -p $IW; echo keep > $IW/notes.txt                  # not a worktree of this repo
echo "gitdir: $S/elsewhere/.git/worktrees/$RUN-integrate" > $IW/.git
run $O end-run --run $RUN --status aborted --keep-sim
ok "a directory that isn't this repo's worktree is never deleted (NOT finished instead)" '[ -f $IW/notes.txt ] && grep -q "NOT finished $RUN-integrate" <<< "$out"'
rm -rf $IW

echo "-- add-worker records the surface uuid; its pane closes by it"
home addw; RUN=$($O new-run --repo $R --title aw$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
tree "workspace:7=W7=coordinator=surface:12=S12-OWN"
run $O add-worker --run $RUN --slice X --workspace surface:12
ok "add-worker: surface_id recorded" '[ "$(jget $D/workers/X.json surface_id)" = S12-OWN ]'
: > $LOG; run $O close --run $RUN --slice X
ok "close: its pane closed by the surface uuid (never the coordinator's workspace)" '[ "$(closes)" = "close-surface --surface S12-OWN --force" ]'
ok "close: finished" '[ -n "$(jget $D/workers/X.json cleaned)" ]'
echo '{"run":"'$RUN'","slice":"Y","name":"'$RUN-Y'","workspace":"surface:13","surface_id":"S13-GONE","status":"active"}' > $D/workers/Y.json
tree "workspace:7=W7=coordinator=surface:13=S13-OTHER"
: > $LOG; run $O close --run $RUN --slice Y
ok "add-worker pane whose surface ref was reused: not closed" '[ -z "$(closes)" ]'
echo '{"run":"'$RUN'","slice":"V","name":"'$RUN-V'","workspace":"surface:14","surface_id":"S14-OWN","status":"active"}' > $D/workers/V.json
: > $LOG; run env TREE_FAIL=1 $O close --run $RUN --slice V
ok "pane with a uuid, cmux tree unreadable: closed by its uuid (a uuid names nobody else)" 'grep -q "^close-surface --surface S14-OWN --force" $LOG'
run $O add-worker --run $RUN --slice Z --workspace workspace:7
ok "add-worker given a workspace ref: no surface_id (a workspace uuid is never sent to close-surface)" '[ "$(jget $D/workers/Z.json surface_id)" = None ]'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1

echo "-- broadcast goes to the surface uuid"
home bc; RUN=$($O new-run --repo $R --title bc$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
echo '{"run":"'$RUN'","slice":"A","name":"'$RUN-A'","workspace":"surface:51","surface_id":"S51-A","status":"active"}' > $D/workers/A.json
: > $LOG; run $O broadcast --run $RUN "REBASE now"
ok "broadcast: agent message to S51-A, not surface:51" 'grep -q "^agent message S51-A " $LOG && ! grep -q "agent message surface:51" $LOG'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1

echo "-- a cmux without --id-format"
home old; RUN=$($O new-run --repo $R --title old$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
printf '# A\n' > $D/slices/A.md; tree "workspace:5=W5=$RUN-A=surface:51=S51" "workspace:9=D9=$RUN dashboard=surface:91=S91"
: > $LOG; run env OLD_CMUX=1 $O spawn --run $RUN --slice A
ok "spawn still works (plain tree fallback), refs only" '[ $rc = 0 ] && [ "$(jget $D/workers/A.json workspace)" = surface:51 ] && [ "$(jget $D/workers/A.json ws_id)" = None ]'
echo '{"run":"'$RUN'","slice":"B","name":"'$RUN-B'","workspace":"surface:51","ws_ref":"workspace:5","ws_id":"W5","surface_id":"S51","status":"active"}' > $D/workers/B.json
run env OLD_CMUX=1 $O reap --keep-sim
ok "a tree without uuids: a worker with a recorded uuid whose ref is listed stays alive" '[ "$(jget $D/workers/B.json status)" = active ]'
echo '{"run":"'$RUN'","slice":"C","name":"'$RUN-C'","workspace":"surface:81","ws_ref":"workspace:8","ws_id":"W8","surface_id":"S81","status":"active"}' > $D/workers/C.json
run env OLD_CMUX=1 $O reap --keep-sim
ok "...one whose ref isn't listed either is dead (like orch-watch says)" '[ "$(jget $D/workers/C.json status)" = dead ] && [ "$(jget $D/workers/B.json status)" = active ]'
: > $LOG; run env OLD_CMUX=1 $O close --run $RUN --slice A
ok "close of the ref-only record: by title match" 'grep -q "^workspace close --workspace workspace:5 --force" $LOG'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1
home dash2; RUN=$($O new-run --repo $R --title dd$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
printf '# A\n' > $D/slices/A.md; tree "workspace:5=W5=$RUN-A=surface:51=S51" "workspace:9=D9=$RUN dashboard=surface:91=S91"
$O spawn --run $RUN --slice A >/dev/null 2>&1; ok "(dash_id recorded)" '[ "$(jget $D/run.json dash_id)" = D9 ]'
printf '# B\n' > $D/slices/B.md; tree "workspace:5=W5=$RUN-A=surface:51=S51" "workspace:6=W6=$RUN-B=surface:61=S61" "workspace:9=D9=$RUN dashboard=surface:91=S91"
: > $LOG; run env OLD_CMUX=1 $O spawn --run $RUN --slice B
ok "a tree without uuids: the recorded dashboard counts as there (no second one opened)" '[ $rc = 0 ] && ! grep -q "dashboard" $LOG'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1
home empty; RUN=$($O new-run --repo $R --title em$$ --coordinator surface:77 --coordinator-workspace workspace:7); D=$ORCH_HOME/runs/$RUN
echo '{"run":"'$RUN'","slice":"A","name":"'$RUN-A'","workspace":"surface:51","ws_ref":"workspace:5","ws_id":"W5","surface_id":"S51","status":"active"}' > $D/workers/A.json
tree                                                                            # cmux runs, lists nothing
run $O reap --keep-sim
ok "an empty tree: a worker with a recorded uuid is dead (nothing is listed)" '[ "$(jget $D/workers/A.json status)" = dead ]'
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1

echo "-- a worktree remove that lost .git before failing is still finished on retry"
home lost; RUN=$($O new-run --repo $R --title lost$$ --coordinator surface:77 --coordinator-workspace workspace:7)
git -C $R worktree add -q .claude/worktrees/$RUN-integrate -b $RUN-integrate origin/main
IW=$R/.claude/worktrees/$RUN-integrate; echo x > $IW/x.txt; tree; chmod a-w $IW
run $O end-run --run $RUN --status aborted --keep-sim
ok "(first attempt left it)" '[ -d $IW ] && grep -q "NOT finished $RUN-integrate" <<< "$out"'
run $O reap --run $RUN --keep-sim
ok "a retry that fails again names the command that retries it (plain reap skips ended runs)" 'grep -q "still NOT finished.*orch reap --run $RUN" <<< "$out"'
chmod u+w $IW; rm -f $IW/.git                                       # as if git deleted .git first, then failed
run $O reap --run $RUN --keep-sim
ok "retry removes the leftover recorded at the first attempt" '[ ! -d $IW ] && ! grep -q "still NOT finished" <<< "$out"'
mkdir -p $IW; echo keep > $IW/notes.txt
run $O reap --run $RUN --keep-sim
ok "...a plain dir that appears there later is not deleted" '[ -f $IW/notes.txt ]'
rm -rf $IW
home lost2; RUN=$($O new-run --repo $R --title ls2$$ --coordinator surface:77 --coordinator-workspace workspace:7)
git -C $R worktree add -q .claude/worktrees/$RUN-integrate -b $RUN-integrate origin/main
IW=$R/.claude/worktrees/$RUN-integrate; echo x > $IW/x.txt; chmod a-w $IW
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1; chmod u+w $IW
mkdir -p $S/gitwrap; printf '#!/bin/sh\n[ "$1 $2" = "worktree list" ] && exit 1\nexec %s "$@"\n' "$(command -v git)" > $S/gitwrap/git; chmod +x $S/gitwrap/git
run env PATH=$S/gitwrap:$PATH $O reap --run $RUN --keep-sim
ok "git worktree list failing: the recorded leftover is not deleted (can't tell it's unlisted)" '[ -f $IW/x.txt ]'
run $O reap --run $RUN --keep-sim; ok "...and is once git answers" '[ ! -d $IW ]'
home lost3; RUN=$($O new-run --repo $R --title ls3$$ --coordinator surface:77 --coordinator-workspace workspace:7)
git -C $R worktree add -q .claude/worktrees/$RUN-integrate -b $RUN-integrate origin/main
IW=$R/.claude/worktrees/$RUN-integrate; echo x > $IW/x.txt; chmod a-w $IW
$O end-run --run $RUN --status aborted --keep-sim >/dev/null 2>&1; chmod u+w $IW
ok "(leftover recorded)" 'grep -q "$RUN-integrate" $ORCH_HOME/state/worktree-leftovers.json'
rm -rf $IW; mkdir -p $IW; echo mine > $IW/notes.txt                    # removed by hand, a new directory made there
run $O reap --run $RUN --keep-sim
ok "a directory recreated at a recorded leftover's path is not deleted (not the same directory)" '[ -f $IW/notes.txt ]'
rm -rf $IW


echo "-- caffeinate: an isolated ORCH_HOME never starts the real one"
caffs(){ ps -axo pid=,ppid=,command= | awk '$2 == 1 && $3 ~ /(^|\/)caffeinate$/ && $4 == "-is" && NF == 4 {print $1}' | sort; }
home caff; before=$(caffs)
# a sentinel named `caffeinate` first on PATH stands in for /usr/bin/caffeinate: orch reaching for the default binary
# logs here instead of starting the real one (a test never runs the real caffeinate/xcrun/osascript)
mkdir -p $S/sentinel; printf '#!/bin/sh\necho "$*" >> %s/sentinel.log\n' "$S" > $S/sentinel/caffeinate
for x in xcrun osascript; do cp $S/stub/$x $S/sentinel/$x; done; chmod +x $S/sentinel/*
REALPATH=/usr/bin:/bin:/usr/sbin:/sbin; PYDIR=$(dirname "$(command -v python3)"); GITDIR=$(dirname "$(command -v git)")
nostub(){ env -u ORCH_CAFFEINATE PATH="$S/sentinel:$PYDIR:$GITDIR:$REALPATH" ORCH_CMUX=$S/fakecmux "$@"; }
run nostub $O new-run --repo $R --title caff$$ --coordinator surface:77 --coordinator-workspace workspace:7; CR=$out
printf '# A\n' > $ORCH_HOME/runs/$CR/slices/A.md; tree "workspace:5=W5=$CR-A=surface:51=S51"
nostub $O ports --run $CR --name integrate-verifier >/dev/null 2>&1
nostub $O spawn --run $CR --slice A >/dev/null 2>&1
nostub $O note --run $CR --wait "x" >/dev/null 2>&1
sleep 1; new=$(comm -13 <(echo "$before") <(caffs) | grep .)
own=$(cat $ORCH_HOME/state/caffeinate.pid 2>/dev/null)
ok "new-run/ports/spawn/note under an isolated ORCH_HOME: no caffeinate.pid" '[ -z "$own" ]'
ok "...and the default caffeinate binary was never started" '[ ! -s $S/sentinel.log ]'
[ -n "$own" ] && kill "$own" 2>/dev/null
[ -n "$new" ] && [ -z "$own" ] && echo "note: ppid-1 caffeinate -is started elsewhere meanwhile (not this suite): $(echo $new)"
nostub $O end-run --run $CR --status aborted --keep-sim >/dev/null 2>&1
home caff2; run env ORCH_CAFFEINATE=$S/stub/caffeinate $O new-run --repo $R --title cf2$$ --coordinator surface:77 --coordinator-workspace workspace:7
ok "ORCH_CAFFEINATE set → that binary holds it for an isolated ORCH_HOME" '[ -s $ORCH_HOME/state/caffeinate.pid ] && grep -qx "$(cat $ORCH_HOME/state/caffeinate.pid)" $CAFF_LOG'
$O end-run --run $out --status aborted --keep-sim >/dev/null 2>&1
ok "end-run releases it" '! kill -0 "$(tail -1 $CAFF_LOG)" 2>/dev/null'
cp $S/stub/caffeinate $S/stub/keepawake; home caff3; : > $CAFF_LOG
K1=$(ORCH_CAFFEINATE=$S/stub/keepawake $O new-run --repo $R --title k1$$ --coordinator surface:77 --coordinator-workspace workspace:7)
K2=$(ORCH_CAFFEINATE=$S/stub/keepawake $O new-run --repo $R --title k2$$ --coordinator surface:77 --coordinator-workspace workspace:7)
ok "ORCH_CAFFEINATE named otherwise (keepawake): the second run reuses the held one" '[ "$(wc -l < $CAFF_LOG | tr -d " ")" = 1 ]'
KP=$(cat $ORCH_HOME/state/caffeinate.pid)
ORCH_CAFFEINATE=$S/stub/keepawake $O end-run --run $K1 --status aborted --keep-sim >/dev/null 2>&1
env -u ORCH_CAFFEINATE $O end-run --run $K2 --status aborted --keep-sim >/dev/null 2>&1
ok "...and end-run from a shell without ORCH_CAFFEINATE still releases it" '! kill -0 $KP 2>/dev/null'
run $O -h; ok "orch -h documents ORCH_CAFFEINATE" 'grep -q ORCH_CAFFEINATE <<< "$out"'

echo "PASSED $P FAILED $F"; [ $F = 0 ]
