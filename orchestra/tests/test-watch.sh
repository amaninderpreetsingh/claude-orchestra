#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Scenario tests for orch-watch (isolated ORCH_HOME, stub cmux + ps on PATH, fixture screens).
set -u; unset ORCH_CMUX  # its own stub only, even when run outside tests/run.sh
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-watch.XXXXXX"); trap 'rm -rf $S' EXIT; mkdir -p $S/bin $S/fx; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home TZ=UTC PATH=$S/bin:$PATH FX=$S/fx; W=$ROOT/bin/orch-watch
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 :: out=[$out] rc=$rc"; fi; }
watch(){ out=$($W "$@" 2>&1); rc=$?; }

# cmux stub: tree from $FX/tree.json, screens from $FX/screen-<ref> (then replaced by $FX/screen-<ref>.then if present),
# send/send-key appended to $FX/sent.log; $FX/send-fails fails both, $FX/key-fails only send-key
cat > $S/bin/cmux <<'EOF'
#!/usr/bin/env bash
case "$1" in
  tree) cat "$FX/tree.json" 2>/dev/null || exit 1 ;;
  read-screen) while [ $# -gt 0 ]; do case "$1" in --surface|--workspace) ref=$2 ;; esac; shift; done; cat "$FX/screen-$ref" 2>/dev/null
    [ -e "$FX/screen-$ref.then" ] && mv "$FX/screen-$ref.then" "$FX/screen-$ref"; true ;;
  send|send-key) [ -e "$FX/send-fails" ] && exit 1; [ "$1" = send-key ] && [ -e "$FX/key-fails" ] && exit 1; echo "$*" >> "$FX/sent.log" ;;
  *) exit 1 ;;
esac
EOF
# ps stub: `ps -o pid=,comm= -t <tty>` prints $FX/ps-<tty> (missing → ps fails = unknown)
cat > $S/bin/ps <<'EOF'
#!/usr/bin/env bash
for a; do tty=$a; done; cat "$FX/ps-$tty" 2>/dev/null || exit 1
EOF
chmod +x $S/bin/cmux $S/bin/ps

tree(){ # tree <ref:tty>... — live surfaces
  python3 - "$@" > $FX/tree.json <<'EOF'
import json, sys
s = [{"ref": a.split(":")[0] + ":" + a.split(":")[1], "tty": a.split(":")[2], "type": "terminal"} for a in sys.argv[1:]]
print(json.dumps({"windows": [{"ref": "window:1", "workspaces": [{"ref": "workspace:1", "panes": [{"ref": "pane:1", "surfaces": s}]}]}]}))
EOF
}
mkrun(){ # mkrun <run> <coord-surface> <slice:surface>...
  local d=$ORCH_HOME/runs/$1; mkdir -p $d/workers $d/slices
  echo "{\"id\":\"$1\",\"coordinator\":\"$2\",\"status\":\"active\"}" > $d/run.json; shift 2
  for a in "$@"; do sl=${a%%:*}; echo "{\"slice\":\"$sl\",\"workspace\":\"${a#*:}\",\"status\":\"active\",\"started\":\"2026-10-28T23:00:00\"}" > $d/workers/$sl.json
    echo "00:00 step 1 x" > $d/slices/$sl.progress.md; done; }
claude(){ printf '1 -zsh\n2 /usr/local/bin/claude\n' > $FX/ps-$1; }
st(){ python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],{}).get(sys.argv[3],""))' $ORCH_HOME/state/watch-$1.json $2 $3; }

echo "-- healthy run: no event"
mkrun r1 surface:90 S1:surface:11; tree surface:11:ttys1 surface:90:ttys9; claude ttys1; claude ttys9
watch --run r1 --once; ok "--once with nothing wrong exits 3, prints nothing" '[ $rc = 3 ] && [ -z "$out" ]'
watch --run nope --once; ok "unknown run is an error (not a silent timeout)" '[ $rc != 0 ] && [ $rc != 3 ]'
start=$(date +%s); watch --run r1 --interval 1 --timeout 2; el=$(( $(date +%s) - start ))
ok "--timeout with no event exits 3 after the timeout" '[ $rc = 3 ] && [ $el -ge 2 ] && [ $el -le 6 ]'

echo "-- DEAD"
tree surface:90:ttys9
watch --run r1 --once; ok "surface gone → EVENT DEAD S1, exit 0" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD S1 surface-gone surface:11" ]'
watch --run r1 --once; ok "same DEAD not re-emitted" '[ $rc = 3 ] && [ -z "$out" ]'
tree surface:11:ttys1 surface:90:ttys9
watch --run r1 --once; ok "surface back → no event" '[ $rc = 3 ]'
tree surface:90:ttys9
watch --run r1 --once; ok "dies again after recovering → DEAD re-emitted" '[ $rc = 0 ] && [[ "$out" == "EVENT DEAD S1 "* ]]'
tree surface:11:ttys1 surface:90:ttys9; watch --run r1 --once; printf '1 -zsh\n' > $FX/ps-ttys1
watch --run r1 --once; ok "surface alive but claude process gone → DEAD no-claude" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD S1 no-claude surface:11" ]'
rm $FX/ps-ttys1
watch --run r1 --once; ok "ps unavailable → not treated as dead" '[ $rc = 3 ]'
rm $FX/tree.json; claude ttys1
watch --run r1 --once; ok "cmux tree unavailable → nobody treated as dead" '[ $rc = 3 ]'
tree surface:11:ttys1 surface:90:ttys9

echo "-- STALLED"
mkrun r2 surface:90 S1:surface:11 S2:surface:12; tree surface:11:ttys1 surface:12:ttys2 surface:90:ttys9; claude ttys2
touch -t $(date -v-20M +%Y%m%d%H%M) $ORCH_HOME/runs/r2/slices/S2.progress.md
watch --run r2 --once; ok "progress 20m old → EVENT STALLED S2 20m" '[ $rc = 0 ] && [ "$out" = "EVENT STALLED S2 20m" ]'
watch --run r2 --once; ok "same stall not re-emitted" '[ $rc = 3 ]'
watch --run r2 --once --stall-min 30; ok "--stall-min 30 → 20m is not a stall" '[ $rc = 3 ]'
touch -t $(date -v-10M +%Y%m%d%H%M) $ORCH_HOME/runs/r2/slices/S2.progress.md
watch --run r2 --once; ok "progress 10m old → no stall at default 15m" '[ $rc = 3 ]'
touch -t $(date -v-16M +%Y%m%d%H%M) $ORCH_HOME/runs/r2/slices/S2.progress.md
watch --run r2 --once; ok "new progress line then stalls again → re-emitted" '[ $rc = 0 ] && [ "$out" = "EVENT STALLED S2 16m" ]'
echo '{"slice":"S1","workspace":"surface:11","status":"merged"}' > $ORCH_HOME/runs/r2/workers/S1.json
touch -t $(date -v-60M +%Y%m%d%H%M) $ORCH_HOME/runs/r2/slices/S1.progress.md
watch --run r2 --once; ok "finished (non-active) workers are not watched" '[ $rc = 3 ]'

echo "-- USAGE_LIMIT + auto-resume"
mkrun r3 surface:90 S1:surface:11; tree surface:11:ttys1 surface:90:ttys9
printf 'some output\n\n  ⎿  You'"'"'ve hit your limit · resets 3am (America/New_York)\n\n> \n' > $FX/screen-surface:11
watch --run r3 --once
day=$(sed -nE 's/^EVENT USAGE_LIMIT S1 (20[0-9-]+)T.*/\1/p' <<< "$out")   # 3am New York is the same UTC day
want=$(date -u -r "$(TZ=America/New_York date -j -f '%Y-%m-%d %H:%M:%S' "$day 03:00:00" +%s)" +%Y-%m-%dT%H:%M 2>/dev/null)
ok "banner → EVENT USAGE_LIMIT S1 <3am New York on that day, in UTC>" '[ $rc = 0 ] && [ -n "$want" ] && [ "$out" = "EVENT USAGE_LIMIT S1 $want" ]'
reset=$(st r3 S1 reset_at); left=$(( $(date -j -f %Y-%m-%dT%H:%M "$reset" +%s) - $(date +%s) ))
ok "reset_at recorded in watch state, next occurrence (0..24h ahead)" '[ $left -gt 0 ] && [ $left -le 86400 ]'
touch -t $(date -v-30M +%Y%m%d%H%M) $ORCH_HOME/runs/r3/slices/S1.progress.md
watch --run r3 --once; ok "limited worker: no repeat event, no STALLED while waiting" '[ $rc = 3 ]'
ok "nothing sent before reset" '[ ! -s $FX/sent.log ]'
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["S1"]["reset_at"]="2020-01-01T00:00";d["S1"]["reset_epoch"]=0;json.dump(d,open(p,"w"))' $ORCH_HOME/state/watch-r3.json
touch $FX/send-fails
watch --run r3 --once; ok "after reset but send fails (dialog open) → no RESUMED claimed" '[ $rc = 3 ] && [ "$(st r3 S1 kind)" = USAGE_LIMIT ]'
rm $FX/send-fails
watch --run r3 --once; ok "send works on the next poll → EVENT RESUMED S1 <reset_at>" '[ $rc = 0 ] && [ "$out" = "EVENT RESUMED S1 2020-01-01T00:00" ]'
ok "resume typed 'continue' + Enter into the worker surface" 'grep -q "^send --surface surface:11 continue$" $FX/sent.log && grep -q "^send-key --surface surface:11 enter$" $FX/sent.log && [ $(wc -l < $FX/sent.log) = 2 ]'
watch --run r3 --once; ok "stale banner still on screen right after resume → no new event, no re-send" '[ $rc = 3 ] && [ $(wc -l < $FX/sent.log) = 2 ]'
python3 -c 'import json,sys,time;p=sys.argv[1];d=json.load(open(p));d["S1"]["resumed_epoch"]=time.time()-31*60;json.dump(d,open(p,"w"))' $ORCH_HOME/state/watch-r3.json
touch -t $(date -v-40M +%Y%m%d%H%M) $ORCH_HOME/runs/r3/slices/S1.progress.md    # no progress since the resume
watch --run r3 --once; ok "same banner still up 31m after resume, no progress since → resume retried (not a new limit tomorrow)" '[ $rc = 0 ] && [ "$out" = "EVENT RESUMED S1 2020-01-01T00:00" ] && [ $(wc -l < $FX/sent.log) = 4 ]'
printf 'working again\n> \n' > $FX/screen-surface:11
watch --run r3 --once; ok "banner gone, progress file still old from the limit wait → no false STALLED" '[ $rc = 3 ]'
printf 'Claude usage limit reached. Your limit will reset at 5:30pm.\n' > $FX/screen-surface:11
watch --run r3 --once; ok "limit hit again (other banner wording, no tz → local) → USAGE_LIMIT re-emitted" '[ $rc = 0 ] && [[ "$out" =~ ^"EVENT USAGE_LIMIT S1 "20[0-9-]+T17:30$ ]]'
printf '5-hour limit reached ∙ resets soon\n' > $FX/screen-surface:11; rm -f $ORCH_HOME/state/watch-r3.json
watch --run r3 --once; t=$(( $(date -j -f %Y-%m-%dT%H:%M "$(st r3 S1 reset_at)" +%s) - $(date +%s) ))
ok "unparseable reset → now+60m" '[ $rc = 0 ] && [ $t -ge 3480 ] && [ $t -le 3660 ]'

echo "-- resend safety"
setresumed(){ python3 -c 'import json,sys,time;p=sys.argv[1];d=json.load(open(p));d["S1"]["resumed_epoch"]=time.time()-int(sys.argv[2])*60;json.dump(d,open(p,"w"))' $ORCH_HOME/state/watch-$1.json $2; }
setreset0(){ python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["S1"]["reset_epoch"]=0;json.dump(d,open(p,"w"))' $ORCH_HOME/state/watch-$1.json; }
BAN='  ⎿  You'"'"'ve hit your limit · resets 3am (America/New_York)'
mkrun r6 surface:90 S1:surface:11; tree surface:11:ttys1 surface:90:ttys9; claude ttys1; : > $FX/sent.log
printf 'out\n%s\n\n> \n' "$BAN" > $FX/screen-surface:11; watch --run r6 --once; setreset0 r6
watch --run r6 --once; ok "resumed after reset" '[ "$out" = "EVENT RESUMED S1 $(st r6 S1 reset_at)" ] && [ $(wc -l < $FX/sent.log) = 2 ]'
setresumed r6 31; echo "00:40 step 2 working" >> $ORCH_HOME/runs/r6/slices/S1.progress.md
watch --run r6 --once; ok "stale banner 31m after resume but progress advanced since → no event, no resend" '[ $rc = 3 ] && [ $(wc -l < $FX/sent.log) = 2 ]'
watch --run r6 --once; ok "...and not re-detected as a new limit on the next poll" '[ $rc = 3 ] && [ $(wc -l < $FX/sent.log) = 2 ]'
touch -t $(date -v-20M +%Y%m%d%H%M) $ORCH_HOME/runs/r6/slices/S1.progress.md; setresumed r6 40
watch --run r6 --once; ok "...the stale banner doesn't hide a later stall" '[ $rc = 0 ] && [ "$out" = "EVENT STALLED S1 20m" ] && [ $(wc -l < $FX/sent.log) = 2 ]'
printf 'out\n%s\n> continue\nworking on step 2\n> \n' "$BAN" > $FX/screen-surface:11; setresumed r6 31
echo "01:10 step 3 working" >> $ORCH_HOME/runs/r6/slices/S1.progress.md
watch --run r6 --once; ok "stale banner with '> continue' typed under it + progress since resume → no event, no resend" '[ $rc = 3 ] && [ $(wc -l < $FX/sent.log) = 2 ]'
printf 'working\n> \n' > $FX/screen-surface:11; watch --run r6 --once
printf 'out\n%s\n\n> \n' "$BAN" > $FX/screen-surface:11
watch --run r6 --once; ok "banner left the screen, same banner text comes back later → new USAGE_LIMIT" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT S1 "* ]]'

mkrun r10 surface:90 S1:surface:11; : > $FX/sent.log
printf 'out\n%s\n\n> \n' "$BAN" > $FX/screen-surface:11; watch --run r10 --once; setreset0 r10; watch --run r10 --once
printf 'out\n%s\n> continue\n> \n' "$BAN" > $FX/screen-surface:11; setresumed r10 31
touch -t $(date -v-40M +%Y%m%d%H%M) $ORCH_HOME/runs/r10/slices/S1.progress.md
watch --run r10 --once; ok "same banner, line under it changed by the typed continue, no progress → resume retried" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED S1 "* ]] && [ $(wc -l < $FX/sent.log) = 4 ]'

mkrun r7 surface:90 S1:surface:11; : > $FX/sent.log; rm -f $ORCH_HOME/state/watch-r7.json
printf 'out\n%s\n\n> \n' "$BAN" > $FX/screen-surface:11; watch --run r7 --once; setreset0 r7
printf 'out\n> continue\nworking\n> \n' > $FX/screen-surface:11.then
watch --run r7 --once; ok "banner gone when re-read right before sending → nothing typed" '[ $rc = 3 ] && [ ! -s $FX/sent.log ]'
watch --run r7 --once; ok "...and the session counts as resumed by someone else (no send later)" '[ $rc = 3 ] && [ ! -s $FX/sent.log ] && [ "$(st r7 S1 kind)" = OK ]'
setresumed r7 31; touch -t $(date -v-40M +%Y%m%d%H%M) $ORCH_HOME/runs/r7/slices/S1.progress.md
printf 'out\n%s\n\n> \n' "$BAN" > $FX/screen-surface:11; rm -f $ORCH_HOME/state/watch-r7.json; watch --run r7 --once; setreset0 r7
watch --run r7 --once; setresumed r7 31; printf 'out\n> continue\nworking\n> \n' > $FX/screen-surface:11.then; : > $FX/sent.log
watch --run r7 --once; ok "retry after the grace: banner gone at send time → no resend" '[ $rc = 3 ] && [ ! -s $FX/sent.log ]'

mkrun r8 surface:90 S1:surface:11; : > $FX/sent.log
printf 'out\n%s\n\n> \n' "$BAN" > $FX/screen-surface:11; watch --run r8 --once; setreset0 r8; touch $FX/key-fails
watch --run r8 --once; ok "half-sent continue (text typed, Enter failed) → no RESUMED claimed" '[ $rc = 3 ] && [ "$(st r8 S1 kind)" = USAGE_LIMIT ]'
rm $FX/key-fails
watch --run r8 --once; ok "...next poll only presses Enter (doesn't type a second 'continue')" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED S1 "* ]] && [ $(grep -c " continue$" $FX/sent.log) = 1 ] && [ $(grep -c " enter$" $FX/sent.log) = 1 ]'

mkrun r9 surface:90 S1:surface:11; : > $FX/sent.log
printf '%s\n' 'BANNER = re.compile(r"usage limit reached|limit will reset")' '    if "usage limit reached" in line:  # resets at 3am' \
  'grep -q "You'"'"'ve hit your limit · resets 3am" log' '> ' > $FX/screen-surface:11
watch --run r9 --once; ok "'usage limit reached' in ordinary code/text → no event" '[ $rc = 3 ]'
{ printf '%s\n' "$BAN"; for i in $(seq 1 25); do echo "later output $i"; done; printf '> \n'; } > $FX/screen-surface:11
watch --run r9 --once; ok "banner-shaped line scrolled far above the bottom status area → no event" '[ $rc = 3 ]'
printf 'out\nClaude usage limit reached\n> \n' > $FX/screen-surface:11
watch --run r9 --once; ok "limit line without a reset time → not the banner" '[ $rc = 3 ]'
printf 'out\n%s\n\n> \n\n\n\n\n\n\n\n\n\n\n\n\n\n' "$BAN" > $FX/screen-surface:11
watch --run r9 --once; ok "real banner above the prompt (trailing blank rows) → USAGE_LIMIT" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT S1 "* ]]'
printf 'out\n  ⎿  Opus weekly limit reached ∙ resets Nov 2, 3pm\n> \n' > $FX/screen-surface:11; rm -f $ORCH_HOME/state/watch-r9.json
printf 'out\n  ⎿  Limit reached · resets 3pm\n> \n' > $FX/screen-surface:11; rm -f $ORCH_HOME/state/watch-r9.json
watch --run r9 --once; ok "bare 'Limit reached · resets 3pm' → USAGE_LIMIT" '[ $rc = 0 ] && [[ "$out" =~ ^"EVENT USAGE_LIMIT S1 "20[0-9-]+T15:00$ ]]'
printf 'out\n  ⎿  Opus weekly limit reached ∙ resets Nov 2, 3pm\n> \n' > $FX/screen-surface:11; rm -f $ORCH_HOME/state/watch-r9.json
watch --run r9 --once; ok "multi-word limit name (Opus weekly) → USAGE_LIMIT at its reset date" '[ $rc = 0 ] && [[ "$out" =~ ^"EVENT USAGE_LIMIT S1 "20[0-9]{2}-11-02T15:00$ ]]'

echo "-- coordinator"
mkrun r4 surface:90; tree surface:90:ttys9
printf 'You'"'"'ve hit your limit · resets 11pm\n' > $FX/screen-surface:90; : > $FX/sent.log
watch --run r4 --once; ok "coordinator not watched without --coordinator" '[ $rc = 3 ]'
watch --run r4 --once --coordinator; ok "--coordinator: banner → EVENT USAGE_LIMIT coordinator" '[ $rc = 0 ] && [[ "$out" =~ ^"EVENT USAGE_LIMIT coordinator "20[0-9-]+T23:00$ ]]'
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["coordinator"]["reset_epoch"]=0;json.dump(d,open(p,"w"))' $ORCH_HOME/state/watch-r4.json
watch --run r4 --once --coordinator; ok "--coordinator: resumed after reset" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED coordinator "* ]] && grep -q "^send --surface surface:90 continue$" $FX/sent.log'
tree
watch --run r4 --once --coordinator; ok "--coordinator: coordinator surface gone → DEAD coordinator" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD coordinator surface-gone surface:90" ]'

echo "-- polling loop returns on the first event"
mkrun r5 surface:90 S1:surface:11; tree surface:11:ttys1 surface:90:ttys9; claude ttys1; rm -f $FX/screen-surface:11
( sleep 2; tree surface:90:ttys9 ) & start=$(date +%s)
watch --run r5 --interval 1 --timeout 20; el=$(( $(date +%s) - start )); wait
ok "event mid-wait → exits 0 promptly with the event" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD S1 surface-gone surface:11" ] && [ $el -le 6 ]'

echo "-- ORCH_CMUX: the cmux binary orch uses, when cmux isn't on PATH"
mkdir -p $S/alt $S/nocmux; mv $S/bin/cmux $S/alt/mycmux
printf '#!/bin/sh\nexit 1\n' > $S/nocmux/cmux; chmod +x $S/nocmux/cmux               # the cmux on PATH: not running
mkrun r6 surface:90 S1:surface:11; tree surface:90:ttys9; claude ttys9
out=$(PATH=$S/nocmux:$PATH ORCH_CMUX=$S/alt/mycmux $W --run r6 --once 2>&1); rc=$?
ok "ORCH_CMUX set → its tree is read: EVENT DEAD S1" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD S1 surface-gone surface:11" ]'
mv $S/alt/mycmux $S/bin/cmux

echo "-- stable ids: a reused surface ref is someone else's"
mkdir -p $S/hang
mkrun r7 surface:90 S1:surface:11; claude ttys1; claude ttys9
python3 - $ORCH_HOME/runs/r7/workers/S1.json <<'EOF'
import json, sys; p = sys.argv[1]; w = json.load(open(p)); w["surface_id"] = "S-OWN"; json.dump(w, open(p, "w"))
EOF
idtree(){ printf '{"windows":[{"workspaces":[{"ref":"workspace:1","panes":[{"ref":"pane:1","surfaces":[{"ref":"surface:11","id":"%s","tty":"ttys1"},{"ref":"surface:90","tty":"ttys9"}]}]}]}]}' "$1" > $FX/tree.json; }
idtree S-OTHER
watch --run r7 --once; ok "worker's surface uuid gone, its ref reused → EVENT DEAD S1" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD S1 surface-gone surface:11" ]'
idtree S-OWN; printf 'some output\n\n  ⎿  You'"'"'ve hit your limit · resets 3am (America/New_York)\n\n> \n' > $FX/screen-surface:11; : > $FX/screen-S-OWN
watch --run r7 --once; ok "own uuid live → screen read by uuid, not by the ref (no event)" '[ $rc = 3 ] && [ -z "$out" ]'
mv $FX/screen-surface:11 $FX/screen-S-OWN
watch --run r7 --once; ok "...the uuid's own banner is seen" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT S1 "* ]]'
rm -f $ORCH_HOME/state/watch-r7.json; tree surface:11:ttys1 surface:90:ttys9   # a cmux that lists no uuids at all
watch --run r7 --once; ok "tree without uuids: a worker with a recorded uuid is not DEAD (read by its ref)" '[[ "$out" != *DEAD* ]]'
cat > $S/hang/cmux <<'EOF'
#!/bin/sh
[ "$1" = tree ] && sleep 30
exit 1
EOF
chmod +x $S/hang/cmux; rm -f $ORCH_HOME/state/watch-r7.json
t0=$(date +%s); out=$(PATH=$S/hang:$PATH $W --run r7 --once 2>&1); rc=$?; el=$(( $(date +%s) - t0 ))
ok "hung cmux: one tree timeout per poll, not two (${el}s)" '[ $el -lt 18 ]'

echo "-- stable ids: the coordinator, and records that hold only a short ref"
# ctree <surface:11 id> <surface:90 id> [workspace:1 id] — ids "" are left out (a ref the tree lists without a uuid)
ctree(){ python3 - "$@" > $FX/tree.json <<'EOF'
import json, sys
def node(ref, uid, **kw):
    n = {"ref": ref, **kw}
    if uid: n["id"] = uid
    return n
a = sys.argv[1:] + ["", "", ""]
s = [node("surface:11", a[0], tty="ttys1"), node("surface:90", a[1], tty="ttys9")]
print(json.dumps({"windows": [{"workspaces": [node("workspace:1", a[2], panes=[{"ref": "pane:1", "surfaces": s}])]}]}))
EOF
}
reset0(){ python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d[sys.argv[2]]["reset_epoch"]=0;json.dump(d,open(p,"w"))' $ORCH_HOME/state/watch-$1.json $2; }
rm -f $FX/screen-*; claude ttys1; claude ttys9
mkrun r11 surface:90; ctree "" C-OWN; : > $FX/sent.log
printf 'out\n  ⎿  You'"'"'ve hit your limit · resets 11pm\n\n> \n' > $FX/screen-C-OWN; : > $FX/screen-surface:90
watch --run r11 --once --coordinator; ok "coordinator's short ref resolved to its uuid: screen read by the uuid → USAGE_LIMIT coordinator" '[ $rc = 0 ] && [[ "$out" =~ ^"EVENT USAGE_LIMIT coordinator "20[0-9-]+T23:00$ ]]'
reset0 r11 coordinator
watch --run r11 --once --coordinator; ok "coordinator auto-continue after the reset: 'continue' + Enter typed into its uuid" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED coordinator "* ]] && grep -q "^send --surface C-OWN continue$" $FX/sent.log && grep -q "^send-key --surface C-OWN enter$" $FX/sent.log && [ $(wc -l < $FX/sent.log) = 2 ]'
ctree "" C-OTHER; cp $FX/screen-C-OWN $FX/screen-surface:90; cp $FX/screen-C-OWN $FX/screen-C-OTHER
watch --run r11 --once --coordinator; ok "resolved once: surface:90 reused by another surface → DEAD coordinator, nothing typed into it" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD coordinator surface-gone surface:90" ] && [ $(wc -l < $FX/sent.log) = 2 ]'

mkrun r12 surface:90; ctree; : > $FX/sent.log; rm -f $FX/screen-*      # a cmux that lists no uuids: the ref, as before
printf 'out\n  ⎿  You'"'"'ve hit your limit · resets 11pm\n\n> \n' > $FX/screen-surface:90
watch --run r12 --once --coordinator; ok "short-ref fallback: tree without uuids → coordinator read by its ref" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT coordinator "* ]]'
reset0 r12 coordinator
watch --run r12 --once --coordinator; ok "short-ref fallback: auto-continue typed into the ref" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED coordinator "* ]] && grep -q "^send --surface surface:90 continue$" $FX/sent.log'
ctree "" C-LATE
watch --run r12 --once --coordinator; ok "...a later tree with uuids resolves the ref then (no false DEAD)" '[[ "$out" != *DEAD* ]] && [ "$(st r12 coordinator id)" = C-LATE ]'
rm $FX/tree.json; rm -f $ORCH_HOME/state/watch-r12.json
watch --run r12 --once --coordinator; ok "cmux unreadable → coordinator read by its ref, not DEAD" '[[ "$out" != *DEAD* ]] && [ -z "$(st r12 coordinator id)" ]'

mkrun r13 surface:90 S1:surface:11; ctree W-OWN C-OWN; : > $FX/sent.log; rm -f $FX/screen-*   # worker record without surface_id
printf 'out\n  ⎿  You'"'"'ve hit your limit · resets 11pm\n\n> \n' > $FX/screen-W-OWN
watch --run r13 --once; ok "worker with only a short ref: resolved to its uuid, banner read there" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT S1 "* ]]'
reset0 r13 S1
watch --run r13 --once; ok "...auto-continue typed into the worker's uuid" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED S1 "* ]] && grep -q "^send --surface W-OWN continue$" $FX/sent.log'
ctree W-OTHER C-OWN
watch --run r13 --once; ok "...its ref reused later → DEAD S1" '[ $rc = 0 ] && [ "$out" = "EVENT DEAD S1 surface-gone surface:11" ]'

mkrun r14 surface:90 S1:workspace:1; ctree W-FIRST C-OWN WS-ONE; : > $FX/sent.log; rm -f $FX/screen-*  # a workspace ref: its own uuid
printf 'out\n  ⎿  You'"'"'ve hit your limit · resets 11pm\n\n> \n' > $FX/screen-WS-ONE
watch --run r14 --once; ok "worker recorded as workspace:N → the workspace's uuid, read with --workspace" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT S1 "* ]] && [ "$(st r14 S1 id)" = WS-ONE ]'
reset0 r14 S1; rm $FX/tree.json
watch --run r14 --once; ok "...cmux tree unreadable: the stored uuid is still the address (continue + Enter into --workspace WS-ONE)" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED S1 "* ]] && grep -q "^send --workspace WS-ONE continue$" $FX/sent.log && grep -q "^send-key --workspace WS-ONE enter$" $FX/sent.log'

mkrun r15 surface:90; : > $FX/sent.log; rm -f $FX/screen-*   # run.json records the coordinator's uuid; its ref is already reused
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["coordinator_id"]="C-REC";json.dump(d,open(p,"w"))' $ORCH_HOME/runs/r15/run.json
ctree C-REC C-OTHER; printf 'out\n  ⎿  You'"'"'ve hit your limit · resets 11pm\n\n> \n' > $FX/screen-C-REC; cp $FX/screen-C-REC $FX/screen-C-OTHER
watch --run r15 --once --coordinator; ok "run.json coordinator_id is the address even when the short ref names someone else" '[ $rc = 0 ] && [[ "$out" == "EVENT USAGE_LIMIT coordinator "* ]]'
reset0 r15 coordinator
watch --run r15 --once --coordinator; ok "...auto-continue typed into coordinator_id, never into the reused ref" '[ $rc = 0 ] && [[ "$out" == "EVENT RESUMED coordinator "* ]] && grep -q "^send --surface C-REC continue$" $FX/sent.log && ! grep -q "C-OTHER\|surface:90" $FX/sent.log'

mkrun r16 surface:90 S1:surface:12; ctree "" C-OWN; rm -f $FX/screen-*   # S1 is dead: the poll returns DEAD S1 first
watch --run r16 --once --coordinator; ok "an earlier target's event still lets the coordinator's ref be resolved that poll" '[ "$out" = "EVENT DEAD S1 surface-gone surface:12" ] && [ "$(st r16 coordinator id)" = C-OWN ]'

echo; echo "PASSED $PASS  FAILED $FAIL"; [ $FAIL = 0 ]
