#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Scenario tests for orch-sim (per-owner simulator clones). Stubbed xcrun on PATH; a real-simctl
# pass is opt-in (ORCH_SIM_REAL=1): other suites' `orch end-run` can shut sims down mid-test.
set -u
S=${TMPDIR:-/tmp}/orchestra-test-sim; rm -rf $S; mkdir -p $S/bin; cd $S
export ORCH_HOME=$S/home; SIM=$ROOT/bin/orch-sim
PASS=0; FAIL=0
check(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1: want '$3' got '$2'"; fi; }
ok(){ if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   cmd: ${*:2:3}"; else FAIL=$((FAIL+1)); echo "FAIL cmd should succeed: $*"; "$@"; fi; }
no(){ if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL cmd should fail: $*"; else PASS=$((PASS+1)); echo "ok   refused: ${*:2:3}"; fi; }

# ---- fake xcrun: `xcrun simctl ...` over a JSON state file, logs every call
cat > $S/bin/xcrun <<'EOF'
#!/usr/bin/env python3
import fcntl, json, os, sys, uuid
st, log = os.environ["FAKE_SIM_STATE"], os.environ["FAKE_SIM_LOG"]
a = sys.argv[1:]
assert a[0] == "simctl", a
a = a[1:]
with open(log, "a") as f: f.write(" ".join(a) + "\n")
fd = os.open(st + ".lock", os.O_CREAT | os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX)
d = json.load(open(st))
devs = d["devices"]
def get(u):
    for x in devs:
        if x["udid"] == u: return x
    sys.exit(f"Invalid device: {u}")
def save(): json.dump(d, open(st, "w"))
if a[0] == "list" and a[1] == "devices":
    print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [dict(x, isAvailable=True) for x in devs]}}))
elif a[0] == "list" and a[1] == "devicetypes":
    print(json.dumps({"devicetypes": [{"name": n, "identifier": "com.apple.CoreSimulator.SimDeviceType." + n.replace(" ", "-")} for n in d["types"]]}))
elif a[0] == "clone":
    b = get(a[1])
    if b["state"] != "Shutdown": sys.exit("Unable to clone device in current state: Booted")
    u = str(uuid.uuid4()).upper(); devs.append({"name": a[2], "udid": u, "state": "Shutdown", "from": b["name"]}); save(); print(u)
elif a[0] == "create":
    if a[2].rsplit(".", 1)[-1].replace("-", " ") not in d["types"]: sys.exit("Invalid device type")
    u = str(uuid.uuid4()).upper(); devs.append({"name": a[1], "udid": u, "state": "Shutdown", "from": "create"}); save(); print(u)
elif a[0] == "boot":
    x = get(a[1])
    if x["state"] == "Booted": sys.exit("Unable to boot device in current state: Booted")
    x["state"] = "Booted"; save()
elif a[0] == "bootstatus":
    get(a[1])
elif a[0] == "shutdown":
    x = get(a[1])
    if x["state"] != "Booted": sys.exit("Unable to shutdown device in current state: Shutdown")
    x["state"] = "Shutdown"; save()
elif a[0] == "delete":
    x = get(a[1])
    if x["state"] != "Shutdown": sys.exit("Unable to delete a booted device")
    devs.remove(x); save()
else:
    sys.exit("fake xcrun: unsupported " + " ".join(a))
EOF
chmod +x $S/bin/xcrun
export FAKE_SIM_STATE=$S/sim.json FAKE_SIM_LOG=$S/sim.log
cat > $S/sim.json <<'EOF'
{"types": ["iPhone 16", "iPhone 17"],
 "devices": [{"name": "iPhone 16", "udid": "BASE-16", "state": "Shutdown"},
             {"name": "iPhone 17", "udid": "BASE-17", "state": "Booted"},
             {"name": "orch-someone-else", "udid": "STRAY-1", "state": "Booted"}]}
EOF
st(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(x[sys.argv[3]] for x in d["devices"] if x["name"]==sys.argv[2]) or "-")' $S/sim.json "$@"; }

echo "-- stubbed simctl"
PATH=$S/bin:$PATH
A=$($SIM acquire --owner run1-A); check "acquire prints the clone's udid" "$A" "$(st orch-run1-A udid)"
check "clone of the shut-down base device" "$(st orch-run1-A from)" "iPhone 16"
check "clone is booted" "$(st orch-run1-A state)" "Booted"
grep -q "bootstatus $A" $S/sim.log && check "waits for boot to finish" y y || check "waits for boot to finish" n y
A2=$($SIM acquire --owner run1-A); check "acquire is idempotent per owner" "$A2" "$A"
check "no second clone for the same owner" "$(grep -c '^clone' $S/sim.log)" "1"
B=$($SIM acquire --owner run1-B); [ -n "$B" ] && [ "$B" != "$A" ] && check "second owner gets a distinct udid" y y || check "second owner gets a distinct udid" "$B" "≠$A"
check "both owners hold booted clones at once" "$(st orch-run1-A state) $(st orch-run1-B state)" "Booted Booted"
C=$($SIM acquire --owner run1-C --device "iPhone 17"); check "base booted → falls back to simctl create" "$(st orch-run1-C from)" "create"
check "base device left untouched" "$(st 'iPhone 17' state)" "Booted"
no $SIM acquire --owner run1-X --device "iPhone 99"
check "unknown device creates nothing" "$(st orch-run1-X udid)" "-"
no $SIM acquire
L=$($SIM list); echo "$L" | grep -q "orch-run1-A $A Booted" && echo "$L" | grep -q "orch-someone-else" && ! echo "$L" | grep -q "BASE-16" \
  && check "list shows only orch-* clones" y y || check "list shows only orch-* clones" "$L" "orch-* only"

echo "-- concurrency (no global lock)"
$SIM acquire --owner run1-P > $S/p.out 2>&1 & p1=$!
$SIM acquire --owner run1-Q > $S/q.out 2>&1 & p2=$!
$SIM acquire --owner run1-P > $S/p2.out 2>&1 & p3=$!
wait $p1; r1=$?; wait $p2; r2=$?; wait $p3; r3=$?
check "parallel acquires succeed" "$r1$r2$r3" "000"
check "parallel owners distinct" "$( [ "$(cat $S/p.out)" != "$(cat $S/q.out)" ] && echo y)" y
check "same owner in parallel → one clone" "$(cat $S/p2.out) $(grep -c 'orch-run1-P' $S/sim.json)" "$(st orch-run1-P udid) 1"
hold(){ # hold <owner> <secs>: another process takes that owner's lock; returns once it's held
  rm -f $S/held; python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2],"w"); time.sleep(float(sys.argv[3]))' \
    $ORCH_HOME/locks/sim-$1.lock $S/held $2 & HP=$!
  while [ ! -f $S/held ]; do sleep 0.05; done; }
mkdir -p $ORCH_HOME/locks
hold run1-Z 1.5; t0=$(date +%s)
Z=$($SIM acquire --owner run1-Z); t1=$(date +%s)
check "waits for the owner's live lock holder, then proceeds" "$Z $( [ $((t1-t0)) -ge 1 ] && echo waited)" "$(st orch-run1-Z udid) waited"
hold run1-Y 60; kill -9 $HP; wait $HP 2>/dev/null; t0=$(date +%s)
Y=$($SIM acquire --owner run1-Y); t1=$(date +%s)
check "a killed holder's lock doesn't block" "$Y $( [ $((t1-t0)) -lt 5 ] && echo fast)" "$(st orch-run1-Y udid) fast"
hold run1-Y 0.5; $SIM release --owner run1-Y >/dev/null; check "release waits for the lock too" "$(st orch-run1-Y udid)" "-"
no $SIM acquire --owner ../x
no $SIM release --owner a/b
check "bad owner names touch nothing" "$(ls $S/home | tr '\n' ' ')" "locks "

echo "-- release"
ok $SIM release --owner run1-A
check "release deletes the clone" "$(st orch-run1-A udid)" "-"
grep -q "shutdown $A" $S/sim.log && check "release shuts down before delete" y y || check "release shuts down before delete" n y
ok $SIM release --owner run1-A
check "other owner's clone kept" "$(st orch-run1-B udid)" "$B"

echo "-- reap"
mkdir -p $ORCH_HOME/runs/run1/workers $ORCH_HOME/runs/run2/workers
echo '{"name": "run1-B", "status": "active"}' > $ORCH_HOME/runs/run1/workers/B.json
echo '{"name": "run1-C", "status": "merged"}' > $ORCH_HOME/runs/run1/workers/C.json
echo '{"name": "run2-P", "status": "active"}' > $ORCH_HOME/runs/run2/workers/P.json
BV=$($SIM acquire --owner run1-B-verify); $SIM acquire --owner run1-Bx >/dev/null
before=$(cat $S/sim.json)
D=$($SIM reap --dry-run); check "dry-run deletes nothing" "$(cat $S/sim.json)" "$before"
echo "$D" | grep -q "orch-run1-C" && ! echo "$D" | grep -q "orch-run1-B " && check "dry-run names the orphans only" y y || check "dry-run names the orphans only" "$D" "C, not B"
ok $SIM reap
check "reap keeps active owner's clone" "$(st orch-run1-B udid)" "$B"
check "reap deletes finished owner's clone" "$(st orch-run1-C udid)" "-"
check "reap deletes ownerless clones" "$(st orch-someone-else udid)$(st orch-run1-Q udid)" "--"
check "reap ignores non-orch devices" "$(st 'iPhone 16' udid) $(st 'iPhone 17' udid)" "BASE-16 BASE-17"
check "reap matches the exact owner name" "$(st orch-run1-P udid)" "-"
check "reap keeps the active worker's -verify clone" "$(st orch-run1-B-verify udid)" "$BV"
check "reap: owner prefix without '-' is not a match" "$(st orch-run1-Bx udid)" "-"

echo "-- docs"
D=$ROOT/..
grep -q 'orch-sim acquire' $D/agents/verifier.md && grep -q 'orch-sim release' $D/agents/verifier.md && grep -qi 'maestro' $D/agents/verifier.md && check "verifier.md: Maestro on a per-owner clone" y y || check "verifier.md: Maestro on a per-owner clone" n y
grep -qi 'missing.*maestro\|maestro.*missing\|no.*flow.*FAILURE\|flow.*FAILURE' $D/agents/verifier.md && check "verifier.md: missing flow = FAILURE" y y || check "verifier.md: missing flow = FAILURE" n y
grep -qi 'maestro' $D/skills/worker/SKILL.md && grep -q 'xcbeautify' $D/skills/worker/SKILL.md && check "worker SKILL: Maestro flows + xcbeautify" y y || check "worker SKILL: Maestro flows + xcbeautify" n y
I=$D/orchestra/references/ios.md
grep -q 'xcodebuild.*tee.*xcbeautify' $I && grep -q 'maestro --device' $I && grep -q '\.maestro/' $I && check "ios.md: xcodebuild → log → xcbeautify, Maestro flows" y y || check "ios.md: xcodebuild → log → xcbeautify, Maestro flows" n y

grep -q 'set -o pipefail' $I && ! grep -q 'rc=\${PIPESTATUS' $I && grep -q 'xcbeautify --quieter >' $I \
  && check "ios.md: exit code via pipefail (zsh-safe), xcbeautify output kept out of context" y y || check "ios.md: exit code via pipefail (zsh-safe), xcbeautify output kept out of context" n y
! grep -q "trap '" $I $D/agents/verifier.md && grep -q 'orch-sim release --owner <owner>-verify' $D/agents/verifier.md \
  && check "release is an explicit step, not a per-call trap" y y || check "release is an explicit step, not a per-call trap" n y

echo "-- real simctl"
if [ "${ORCH_SIM_REAL:-0}" != 1 ] || ! /usr/bin/xcrun simctl list devices >/dev/null 2>&1; then
  echo "SKIP real simctl (set ORCH_SIM_REAL=1 with Xcode present to run it)"
else
  PATH=${PATH#$S/bin:}; export ORCH_HOME=$S/realhome
  dev=$(/usr/bin/xcrun simctl list devicetypes | grep -o '^iPhone [^(]*' | sed 's/ *$//' | head -1)
  o1=test-sim-$$-1; o2=test-sim-$$-2
  trap '$SIM release --owner $o1 >/dev/null 2>&1; $SIM release --owner $o2 >/dev/null 2>&1' EXIT
  R1=$($SIM acquire --owner $o1 --device "$dev"); R2=$($SIM acquire --owner $o2 --device "$dev")
  [ -n "$R1" ] && [ -n "$R2" ] && [ "$R1" != "$R2" ] && check "real: two owners → two distinct udids ($dev)" y y || check "real: two owners → two distinct udids" "$R1 $R2" distinct
  /usr/bin/xcrun simctl list devices | grep "$R1" | grep -q Booted && check "real: clone booted" y y || check "real: clone booted" "$(/usr/bin/xcrun simctl list devices | grep "$R1")" Booted
  ok $SIM release --owner $o1; ok $SIM release --owner $o2
  /usr/bin/xcrun simctl list devices | grep -q "orch-test-sim-$$" && check "real: release deleted both" n y || check "real: release deleted both" y y
fi

echo; echo "PASS $PASS  FAIL $FAIL"; [ $FAIL = 0 ]
