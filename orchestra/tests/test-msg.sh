#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-msg.XXXXXX"); trap 'rm -rf $S' EXIT; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch; H=$ROOT/hooks/push-guard.py
export ORCH_PORT_BASE=$((30000 + $$ % 300 * 100)) ORCH_PORT_SPAN=90  # private port block: reap kills unowned listeners in its range
mkdir -p $S/stub; for x in caffeinate xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; chmod +x $S/stub/$x; done; export PATH=$S/stub:$PATH  # never the real caffeinate/simulators
git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo; echo a>a; git add .; git commit -qm i; git push -q origin main; git remote set-head origin main
RUN=$($O new-run --repo . --title m --coordinator workspace:7); git worktree add -q .claude/worktrees/w -b w origin/main; W=$S/repo/.claude/worktrees/w
$O register --worktree $W --run $RUN --slice s >/dev/null
P=0; F=0
t(){ out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$1" "$2" | python3 $H 2>&1); r=$?; [ $r = $3 ] && { P=$((P+1)); echo "ok   $4"; } || { F=$((F+1)); echo "FAIL $4 (got $r) $out"; }; }
t $W 'cmux agent message workspace:7 --from x "PROGRESS: step 3 gates green"' 0 "tagged report to own coordinator"
t $W 'cmux agent message workspace:7 --from x -- "QUESTION: which copy?"' 0 "question with -- separator"
t $W 'cmux agent message workspace:7 "please merge my branch now"' 2 "untagged instruction to coordinator"
t $W 'cmux agent message workspace:9 "PROGRESS: hi"' 2 "message to another workspace (worker)"
t $W 'cmux agent message other-worker-title "MERGED: x"' 2 "message to worker by title"
t $W 'cmux send --workspace workspace:9 "git push"' 2 "typing into another terminal"
t $W 'cmux new-workspace --command claude' 2 "spawning workspaces"
t $W 'orch broadcast --run x "hi"' 2 "worker broadcast"
t $W 'cd / && cmux agent message workspace:9 "PROGRESS: x"' 2 "cd-escape still restricted"
t $W 'cmux agent message --reply-to abc123 "QUESTION: ok?"' 0 "tagged reply"
t $S/repo 'cmux agent message workspace:9 "REBASE: main moved"' 0 "coordinator can command workers"
t $S/repo 'cmux send --workspace workspace:9 "x"' 0 "coordinator unrestricted"
echo "PASSED $P FAILED $F"; [ $F = 0 ]
