#!/usr/bin/env bash
# push-guard's three rules: (1) no force push anywhere, (2) no push at all from a registered worker, (3) a worker's
# cmux use is only messages to its coordinator + read-only verbs. Plus: fails closed on a crash, finishes fast.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-guard.XXXXXX"); trap 'rm -rf $S' EXIT; cd $S  # unique: suites run concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch; H=$ROOT/hooks/push-guard.py
hard(){ perl -MPOSIX -e '$t = shift; $p = fork // die; unless ($p) { POSIX::setsid(); exec @ARGV or exit 127 } $SIG{ALRM} = sub { kill 9, -$p, $p; exit 137 }; alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' 60 "$@"; }  # every hook call under a 60s wall clock: a hang fails the case, never stalls the suite
export ORCH_PORT_BASE=${ORCH_TEST_PORT_BASE:-$((30000 + $$ % 300 * 100))} ORCH_PORT_SPAN=90
mkdir -p $S/stub; for x in caffeinate xcrun osascript; do printf '#!/bin/sh\nexit 0\n' > $S/stub/$x; chmod +x $S/stub/$x; done; export PATH=$S/stub:$PATH
P=0; F=0
ok(){ if eval "$2" >/dev/null 2>&1; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }
call(){ python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$1" "$2" | hard python3 ${GUARD:-$H} 2>&1; }
# t <cwd> <command> <want exit: 0 = no decision, 2 = deny> <label>; a no-decision must also print nothing
t(){ out=$(call "$1" "$2"); r=$?; if [ $r = $3 ] && { [ $r = 2 ] || [ -z "$out" ]; }; then P=$((P+1)); echo "ok   $4"; else F=$((F+1)); echo "FAIL $4 (got $r) $out"; fi; }
NL=$'\n'; BS=$'\\\n'
G="git pu""sh"  # keeps this file's own text plain for the installed guard of whoever edits it

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo; echo a>a; git add .; git commit -qm i; git push -q origin main; git remote set-head origin main
R=$S/repo
RUN=$($O new-run --repo . --title g --coordinator surface:7)
git worktree add -q .claude/worktrees/w -b w origin/main; W=$R/.claude/worktrees/w
git worktree add -q .claude/worktrees/v -b v origin/main; V=$R/.claude/worktrees/v
$O register --worktree $W --run $RUN --slice s >/dev/null; $O register --worktree $V --run $RUN --slice v >/dev/null
OWN=$(git -C $W rev-parse --path-format=absolute --git-dir)/orchestra-owner.json
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.update(workspace="surface:5", coordinator="surface:70", coordinator_id="0A1B2C3D-0000-4000-8000-00000000C0DE"); json.dump(d, open(p, "w"))' "$OWN"
mkdir -p $W/sub

echo "-- C1: a force push is denied in every listed form, outside and inside workers"
for X in $R $W; do
  [ $X = $R ] && wh="main checkout:" || wh="worker:"
  t $X "$G --force origin main" 2 "$wh --force"
  t $X "$G -f origin main" 2 "$wh -f"
  t $X "$G -uf origin HEAD:main" 2 "$wh -uf (combined short flags)"
  t $X "$G -fu origin HEAD:main" 2 "$wh -fu"
  t $X "$G --force-with-lease origin main" 2 "$wh --force-with-lease"
  t $X "$G --force-with-lease=main:abc origin main" 2 "$wh --force-with-lease=…"
  t $X "$G --force-if-includes origin main" 2 "$wh --force-if-includes"
  t $X "$G --mirror origin" 2 "$wh --mirror"
  t $X "$G --mirr origin" 2 "$wh abbreviated --mirr"
  t $X "$G --forc origin main" 2 "$wh abbreviated --forc"
  t $X "$G --m origin" 2 "$wh one-letter --m (git reads it as --mirror)"
  t $X "$G --f origin main" 2 "$wh one-letter --f (ambiguous; denied too)"
  t $X "$G --fo origin main" 2 "$wh abbreviated --fo"
  t $X "$G --force-w origin main" 2 "$wh abbreviated --force-w"
  t $X "arch -arm64 $G -f origin main" 2 "$wh behind the arch wrapper"
  t $X "arch -arch arm64 -e A=b $G -f origin main" 2 "$wh behind arch -arch <name> -e <var>"
  t $X "arch --arch arm64 $G -f origin main" 2 "$wh behind arch --arch <name>"
  t $X "arch -arm64 --d HOME --e A $G -f origin main" 2 "$wh behind arch --d <var> --e <var>"
  t $X "$G origin +HEAD:main" 2 "$wh + refspec"
  t $X "$G origin \"+HEAD:main\"" 2 "$wh quoted + refspec"
  t $X "$G origin main +other" 2 "$wh second refspec forced"
  t $X "git -c remote.origin.mirror=true push origin" 2 "$wh -c remote.*.mirror"
  t $X "git -c a=b -C . pu""sh -f origin main" 2 "$wh -c/-C before push"
  t $X "git --no-pager pu""sh -f origin main" 2 "$wh --no-pager before push"
  t $X "/usr/bin/$G -f origin main" 2 "$wh /usr/bin/git"
  t $X "GIT_TRACE=1 $G -f origin main" 2 "$wh env prefix"
  t $X "env GIT_TRACE=1 timeout 30 $G -f origin main" 2 "$wh env + timeout wrappers"
  t $X ">/dev/null 2>&1 $G -f origin main" 2 "$wh redirections before the verb"
  t $X "$G origin main &>/dev/null --force" 2 "$wh --force after a &> redirection"
  t $X "$G origin HEAD:main ${BS}  --force" 2 "$wh --force on a continued line"
  t $X "git status; $G -f origin main" 2 "$wh second command in a list"
  t $X "git log -n \$((1<<2))${NL}$G -f origin main" 2 "$wh after a << shift that isn't a heredoc"
  t $X "git fetch${NL}$G -f origin main" 2 "$wh after a newline"
  t $X "bash -c \"$G -f origin main\"" 2 "$wh inside bash -c"
  t $X "sh -c '$G -f origin main'" 2 "$wh inside sh -c"
  t $X "eval \"$G -f origin main\"" 2 "$wh inside eval"
  t $X "sh <<< '$G -f origin main'" 2 "$wh as a here-string to sh"
  t $X "echo '$G -f origin main' | sh" 2 "$wh echo piped to sh"
  t $X "source <(echo '$G -f origin main')" 2 "$wh echo sourced through <( … )"
  t $X "git \$'push' \$'--force' origin main" 2 "$wh ANSI-C quoted verb and flag"
  t $X "\\git 'push' \"-f\" origin main" 2 "$wh escaped/quoted words"
  t $X "$G origin {+main,x}" 2 "$wh a brace alternative with a + refspec"
  t $X "$G {-f,} origin main" 2 "$wh a brace alternative with -f"
  t $X "echo \$($G -f origin main)" 2 "$wh in a \$( … )"
  t $X "echo \"\$($G -f origin main)\"" 2 "$wh in a quoted \$( … )"
  t $X "echo \`$G -f origin main\`" 2 "$wh in backticks"
  t $X "bash <<'EOF'${NL}$G -f origin main${NL}EOF" 2 "$wh in a heredoc fed to bash"
  t $X "cat <<'EOF' | sh${NL}$G -f origin main${NL}EOF" 2 "$wh in a cat heredoc piped to sh"
  t $X "python3 -c 'import os; os.system(\"$G -f origin x\")'" 2 "$wh in python3 -c"
  t $X "python3 - <<'PY'${NL}import subprocess${NL}subprocess.run(['git', 'push', '--force'])${NL}PY" 2 "$wh in a python heredoc (list form)"
  t $X "python3 - <<PY${NL}import os; os.system(\"$G -f origin \$(echo x)\")${NL}PY" 2 "$wh in an unquoted python heredoc with a \$( … )"
  t $X "$G -f origin \"main" 2 "$wh with an unbalanced quote"
  t $X "$G origin \$(git branch --show-current) --force" 2 "$wh --force after an unquoted \$( … ) refspec"
  t $X "$G -u origin \`git rev-parse --abbrev-ref HEAD\` -f" 2 "$wh -f after a backtick refspec"
  t $X "$G origin HEAD:\$(git branch --show-current) --force-with-lease" 2 "$wh --force-with-lease after HEAD:\$( … )"
  t $X "$G origin \$((1)) -f" 2 "$wh -f after a \$(( … ))"
  t $X "true;>/dev/null $G --force origin main" 2 "$wh after ;> (a separator merged with a redirection)"
  t $X "sudo -u root $G --force origin main" 2 "$wh sudo -u <user>"
  t $X "env -u GIT_DIR $G -f origin main" 2 "$wh env -u <var>"
  t $X "timeout -s KILL 30 $G -f origin main" 2 "$wh timeout -s <signal>"
  t $X "timeout --signal KILL 30 $G -f origin main" 2 "$wh timeout --signal <signal>"
  t $X "sudo --user root $G --force origin main" 2 "$wh sudo --user <user>"
  t $X "eval $G --force origin main" 2 "$wh unquoted eval"
  t $X "ssh host $G -f origin main" 2 "$wh unquoted over ssh"
  t $X "cat <<'PY' | python3${NL}import os; os.system('$G -f origin x')${NL}PY" 2 "$wh a cat heredoc piped to python3"
  t $X "git commit -qm \"see <<EOF\"${NL}$G -f origin main" 2 "$wh after a quoted <<EOF that has no delimiter line"
  t $X "find . -maxdepth 0 -exec $G -f origin main \\;" 2 "$wh run by find -exec"
  t $X "function f { $G -f origin main; }; f" 2 "$wh in a function body"
  t $X "git -c 'remote.origin.push=+refs/heads/*:refs/heads/*' pu""sh origin" 2 "$wh a + refspec set with -c remote.*.push"
  t $X "git send-pack --force origin main" 2 "$wh git send-pack --force"
done
out=$(call $R "$G -f origin main"); ok "the force denial says so in one line" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ] && grep -q "Force pushes are never allowed" <<< "$out"'

echo "-- C1/C2: outside workers, normal pushes and text naming a push get no decision"
t $R "$G origin main" 0 "plain push"
t $R "$G origin orch/r" 0 "manager pushes the feature branch"
t $R "$G -u origin orch/r" 0 "…with -u"
t $R "$G origin orch/r:main" 0 "manager ships orch/r:main"
t $R "$G origin --delete orch/r" 0 "manager deletes the remote feature branch"
t $R "$G origin HEAD:main" 0 "fast path HEAD:main"
t $R "cd $W && $G origin HEAD:orch/r" 0 "manager pushing from a worker's worktree (the session isn't a worker)"
t $R "git fetch origin && git rebase origin/main && $G origin HEAD:main" 0 "fetch, rebase, push"
t $R "$G -odf=1 origin main" 0 "-o value isn't a flag cluster"
t $R "$G --follow-tags origin main" 0 "--follow-tags isn't force"
t $R "$G --no-force-with-lease origin main" 0 "--no-force-with-lease isn't force"
t $R "$G --dry-run origin main" 0 "--dry-run"
t $R "$G -- origin main" 0 "a bare -- (end of options) isn't a flag"
t $R "arch -arm64 $G origin main" 0 "plain push behind the arch wrapper"
t $W "arch -arm64 $G origin main" 2 "worker: plain push behind the arch wrapper"
t $R "echo \"$G\"" 0 "echo of push text"
t $R "echo \"$G -f\"" 0 "echo of force-push text"
t $R "git commit -qm \"docs: never $G --force\"" 0 "commit message naming a force push"
t $R "grep -rn '$G -f' ." 0 "grep for force-push text"
t $R "git log --grep '$G'" 0 "git log --grep push text"
t $R "cat > notes.md <<'EOF'${NL}$G -f origin x${NL}EOF" 0 "cat heredoc body naming a force push"
t $R "git commit -F - <<'EOF'${NL}never $G -f${NL}EOF" 0 "commit -F - heredoc naming a force push"
t $R "$G origin \$(git branch --show-current)" 0 "push of a \$( … ) branch, no force"
t $R "git -c remote.origin.push=refs/heads/main pu""sh origin" 0 "-c remote.*.push without a +"
t $R "find . -name '*.sh' -exec grep -l '$G' {} +" 0 "find -exec grep for push text"
t $R "if grep -q x f; then echo $G --force is denied; fi" 0 "then echo naming a force push"
t $R "cat <<'EOF' | tee notes.md${NL}$G -f origin x${NL}EOF" 0 "cat heredoc piped to tee naming a force push"
t $R "git commit -qm \"\$(cat <<'EOF'${NL}guard: deny $G --force${NL}EOF${NL})\"" 0 "commit -m \"\$(cat <<'EOF' …)\" naming a force push"
t $R "git commit -qm \"\$(cat <<'EOF'${NL}Run $G origin HEAD:main then tag +1${NL}EOF${NL})\"" 0 "…a body with a bare +1"
t $R "gh pr create --body \"\$(cat <<'EOF'${NL}- no more $G --force through${NL}EOF${NL})\"" 0 "gh pr create --body \"\$(cat <<'EOF' …)\" naming a force push"
t $R "\$ORCH merge --run r --slice s" 0 "manager's \$ORCH merge"
t $R "\$ORCH ship --run r" 0 "manager's \$ORCH ship"
t $R "\$ORCH run-branch --run r" 0 "manager's \$ORCH run-branch"
t $R "~/.claude/orchestra/bin/orch status --run r" 0 "orch by path"
t $R "cmux send --workspace workspace:9 'git status'" 0 "manager cmux send"
t $R "cmux send --workspace workspace:9 '$G -f origin main'" 2 "…typing a force push is still denied"
t $R "cmux agent message surface:9 \"FIX: never $G -f\"" 0 "an agent message naming a force push is only text"

echo "-- C2: a registered worker runs no push at all"
t $W "$G origin HEAD:orch/r" 2 "worker push to its target"
out=$(call $W "$G origin HEAD:orch/r"); ok "…the denial points to READY:" 'grep -q "READY:" <<< "$out" && grep -q "Workers never push" <<< "$out"'
t $W "$G" 2 "bare git push"
t $W "$G --dry-run origin HEAD:x" 2 "--dry-run push"
t $W "git subtree pu""sh --prefix x origin main" 2 "git subtree push"
t $W "git lfs pu""sh origin main" 2 "git lfs push"
t $W "git send-pack origin main" 2 "git send-pack"
t $W "$G origin --delete w" 2 "delete push"
t $W "git -C $R pu""sh origin main" 2 "-C to another checkout"
t $W "cd $R && $G origin main" 2 "cd elsewhere first (the session decides)"
t $W/sub "$G origin HEAD:x" 2 "from a subdirectory of the worktree"
t $V "$G origin HEAD:x" 2 "a worker whose record has no coordinator fields"
t $W "/usr/bin/$G origin HEAD:x" 2 "/usr/bin/git"
t $W "env $G origin HEAD:x" 2 "env wrapper"
t $W "echo x | xargs $G origin" 2 "xargs feeding git push"
t $W "bash -c '$G origin HEAD:x'" 2 "inside bash -c"
t $W "eval '$G origin HEAD:x'" 2 "inside eval"
t $W "echo \$($G origin HEAD:x)" 2 "inside \$( … )"
t $W "bash <<'EOF'${NL}$G origin HEAD:x${NL}EOF" 2 "heredoc fed to bash"
t $W "python3 -c \"import subprocess; subprocess.run(['git', 'push'])\"" 2 "python3 -c list form"
t $W "$G origin \"HEAD:x" 2 "unbalanced quote"
t $W "git commit -qm wip" 0 "worker commit"
t $W "git stash push -u -m s1-tag" 0 "worker git stash push (not a push)"
t $W "git commit -qm \"explain why workers never $G\"" 0 "worker commit message naming a push"
t $W "git fetch origin && git rebase origin/main" 0 "worker fetch + rebase"
t $W "git log --oneline -3; git status --short" 0 "worker log + status"
t $W "git log --grep push" 0 "worker git log --grep push"
t $W "grep -rn '$G' orchestra/" 0 "worker grep for push text"
t $W "echo \"$G\"" 0 "worker echo of push text"
t $W "cat >> notes.md <<'EOF'${NL}step 6 $G${NL}EOF" 0 "worker cat heredoc naming a push"
t $W "\$ORCH register --run r --slice s" 0 "worker's \$ORCH register"
t $W "$G origin \$(git branch --show-current)" 2 "worker push of a \$( … ) branch"
t $W "sudo -u root $G origin HEAD:x" 2 "worker push under sudo -u"
t $W "git commit -qm \"\$(cat <<'EOF'${NL}guard: workers never $G${NL}EOF${NL})\"" 0 "worker commit -m \"\$(cat <<'EOF' …)\" naming a push"
t $W "git commit -qm \"\$(cat <<'EOF'${NL}fix: cmux identify docs${NL}EOF${NL})\"" 0 "…naming cmux"

echo "-- C3: a worker's cmux: its coordinator, replies, identify, its own screen; nothing else"
t $W 'cmux agent message surface:70 --from o "READY: s abc evidence=x"' 0 "message to the coordinator's short ref"
t $W 'cmux agent message 0A1B2C3D-0000-4000-8000-00000000C0DE --from o "QUESTION: x"' 0 "…by its stable id"
t $W 'cmux agent message --from o surface:70 "BLOCKED: x"' 0 "…with --from first"
t $W 'cmux agent message --reply-to m123 "ANSWER received"' 0 "reply to a message"
t $W 'cmux agent message surface:70 "READY: s abc; never cmux tree --all"' 0 "a message whose text names cmux verbs"
t $W 'cmux agent message surface:70 --from o "READY: s $(git rev-parse HEAD) evidence=x"' 0 "a READY message with a \$(git rev-parse HEAD)"
t $V 'cmux agent message surface:7 "QUESTION: x"' 0 "no coordinator in the owner record: run.json's coordinator"
t $W 'cmux agent message surface:7 "QUESTION: x"' 2 "the record's coordinator wins over run.json's"
t $W 'cmux agent message surface:9 "QUESTION: x"' 2 "message to another surface"
t $W 'cmux agent message other-title "READY: x"' 2 "message by title"
t $W 'cmux agent message $C "READY: x"' 2 "message to a \$VAR target"
t $W 'cmux agent message --reply-to m1 --from o "ANSWER: ok"' 0 "a reply with --from"
t $W 'cmux agent message --reply-to m1 workspace:9 "x"' 2 "a reply that also names another target"
t $W 'cmux agent message --surface surface:9 surface:70 "x"' 2 "--surface naming another surface"
t $W 'cmux agent message --workspace workspace:9 surface:70 "x"' 2 "--workspace naming another workspace"
t $W 'sudo -u x cmux tree' 2 "cmux tree under sudo -u"
t $W 'cmux agent message surface:70 --surface surface:9 "x"' 2 "--surface after the coordinator target"
t $W 'cmux agent message surface:70 workspace:9 "x"' 2 "a second target after the coordinator"
t $W 'cmux agent message --quiet surface:70 "x"' 0 "a flag without a value before the coordinator"
t $W 'cmux identify --workspace workspace:9' 2 "identify of another workspace"
t $W 'cmux identify --surface surface:9 --json' 2 "identify of another surface"
t $W 'cmux identify --surface surface:5 --json' 0 "identify of its own surface"
t $W 'cmux identify --json --socket /tmp/other' 2 "identify against another --socket"
t $W 'cmux agent message surface:70 --socket /tmp/other "x"' 2 "a message through another --socket"
t $W 'cmux identify --json' 0 "identify"
t $W 'cmux read-screen --surface surface:5 --lines 20' 0 "read-screen of its own surface"
t $W 'cmux read-screen --surface=surface:5' 0 "…--surface=<own>"
t $W 'cmux read-screen --surface surface:9' 2 "read-screen of another surface"
t $W 'cmux read-screen --lines 20' 2 "read-screen without --surface"
t $W 'cmux read-screen --surface surface:5 --workspace workspace:9' 2 "read-screen with another --workspace"
t $W 'cmux read-screen --surface surface:5 surface:9' 2 "read-screen with another surface as an argument"
t $W 'cmux read-screen --surface surface:5 --surface other-title' 2 "read-screen with a second --surface by title"
t $W 'cmux send --surface surface:5 "y"' 2 "send (even to its own surface)"
t $W 'cmux tree --all' 2 "tree"
t $W 'cmux notify --body x' 2 "notify"
t $W 'cmux set-status k v' 2 "set-status"
t $W 'cmux new-workspace --command claude' 2 "new-workspace"
t $W 'cmux --json identify' 2 "an option before the verb"
t $W 'cmux' 2 "bare cmux"
t $W 'cmux identify; cmux tree' 2 "an allowed command chained with a denied one"
t $W 'command cmux tree' 2 "command cmux tree"
t $W 'echo tree | xargs cmux' 2 "xargs cmux"
t $W "bash -c 'cmux tree --all'" 2 "cmux inside bash -c"
t $W "bash -c '\$0 tree --all' cmux" 2 "cmux passed as \$0 to bash -c"
t $W 'eval "cmux tree"' 2 "cmux inside eval"
t $W 'echo $(cmux tree)' 2 "cmux inside \$( … )"
t $W "python3 -c \"import os; os.system('cmux tree')\"" 2 "cmux inside python3 -c"
t $W "bash <<'EOF'${NL}A=1;cmux tree --all${NL}EOF" 2 "cmux in a heredoc fed to bash"
t $W 'CMUX_SURFACE_ID=surface:9 cmux identify' 2 "a CMUX_* prefix"
t $W 'export CMUX_WORKSPACE_ID=workspace:9; cmux identify' 2 "an exported CMUX_*"
t $W 'orch broadcast --run x "hi"' 2 "worker orch broadcast"
t $W '$ORCH broadcast --run x "hi"' 2 "worker \$ORCH broadcast"
t $W 'command -v cmux' 0 "command -v cmux (a lookup)"
t $W 'find . -name cmux -type f' 0 "find -name cmux"
t $W "grep -rn 'cmux send' skills/" 0 "grep for cmux text"
t $W 'if grep -q cmux README.md; then echo yes; fi' 0 "if grep -q cmux (cmux is grep's pattern)"
t $W 'timeout 30 grep -rn cmux orchestra/' 0 "timeout 30 grep cmux"
t $W 'grep -rl cmux . | xargs grep -n cmux' 0 "xargs grep cmux"
t $W 'for f in *.sh; do grep -c cmux "$f"; done' 0 "a for loop grepping cmux"
t $W 'env LC_ALL=C grep cmux f; time rg cmux; ! grep -q cmux f; { grep cmux f; }' 0 "env/time/!/{ } before grep cmux"
t $W 'sudo -E grep cmux f' 0 "sudo -E (no value) before grep cmux"
t $W 'eval echo cmux tree' 0 "eval echo naming cmux"
t $W "cat <<'EOF' | tee -a notes.md${NL}cmux tree is denied for workers${NL}EOF" 0 "cat heredoc piped to tee naming cmux"
t $W 'xargs -0 grep -l cmux < list' 0 "xargs -0 grep -l cmux"
t $W 'env --unset FOO cmux tree' 2 "env --unset <var> cmux tree"
t $W 'xargs -i grep cmux {} < list' 0 "GNU xargs -i (optional attached value) grep cmux"
t $W 'watch -n 5 cmux tree' 2 "watch -n 5 cmux tree"
t $W 'ssh -p 22 host cmux tree' 2 "ssh -p 22 host cmux tree"
t $W 'echo ${CMUX_PORT}' 0 "reading a CMUX_* variable"
t $W 'git commit -qm "the guard denies cmux tree from workers"' 0 "commit message naming cmux"
out=$(call $W 'cmux tree'); ok "the cmux denial names the allowed forms" 'grep -q "agent message" <<< "$out" && grep -q "identify" <<< "$out" && grep -q "read-screen" <<< "$out"'
t $R 'cmux tree --all' 0 "coordinator cmux tree unrestricted"
t $R 'CMUX_SURFACE_ID=surface:9 cmux send x' 0 "coordinator CMUX_* + send unrestricted"
t $R 'cmux agent message surface:9 "REBASE: main moved"' 0 "coordinator messages workers"
t $R 'orch broadcast --run x "REBASE: y"' 0 "coordinator broadcast"

echo "-- C4: size, no parser module, Python 3.9-safe, fails closed, fast"
ok "push-guard.py is ≤250 lines ($(wc -l < $H | tr -d ' '))" '[ $(wc -l < $H) -le 250 ]'
ok "imports only json/os/re/shlex/signal/string/sys" '[ "$(grep -E "^import |^from " $H | tr -d "\n")" = "import os, sysimport json, re, shlex, signal, string" ]'
ok "loads as a module without running (install.sh smoke test)" 'python3 -c "import importlib.util as u, sys; s = u.spec_from_file_location(\"hook\", sys.argv[1]); s.loader.exec_module(u.module_from_spec(s))" $H < /dev/null'
t $R 'ls -la' 0 "an ordinary command gets no decision"
out=$(printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | hard python3 $H 2>&1); r=$?
ok "another tool gets no decision" '[ $r = 0 ] && [ -z "$out" ]'
cp "$OWN" $S/own.bak; printf '[1, 2]' > "$OWN"
t $W 'cmux identify' 2 "planted crash (owner record not an object): cmux → deny"
out=$(call $W "$G origin HEAD:x"); ok "…a push → deny with a one-line push-guard error" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ] && grep -q "push-guard error (" <<< "$out"'
t $W 'ls -la' 0 "…ls still gets no decision"
printf '{not json' > "$OWN"
t $W "git p\\ush origin HEAD:x" 2 "planted crash (owner record not JSON): a backslash push spelling → deny"
t $W 'ls' 0 "…ls still gets no decision"
cp $S/own.bak "$OWN"
RJ=$ORCH_HOME/runs/$RUN/run.json; cp $RJ $S/run.bak; printf '{broken' > $RJ
t $W 'cmux agent message surface:70 "QUESTION: x"' 0 "a broken run.json isn't read when the owner record names the coordinator"
cp $S/run.bak $RJ
out=$(printf 'not json: git push -f origin main' | hard python3 $H 2>&1); r=$?
ok "input that isn't JSON, naming a push → deny" '[ $r = 2 ] && grep -q "push-guard error" <<< "$out"'
out=$(printf 'not json: ls' | hard python3 $H 2>&1); r=$?
ok "input that isn't JSON, naming nothing guarded → no decision" '[ $r = 0 ]'
out=$(printf '{"tool_name":"Bash","cwd":"/","tool_input":{"command":["cmux"]}}' | hard python3 $H 2>&1); r=$?
ok "a command that isn't a string, naming cmux → deny" '[ $r = 2 ]'
out=$(printf '{"tool_name":"Bash","cwd":"/","tool_input":{"command":"git pu\xffsh -f origin main; %s -f origin main"}}' "$G" | hard python3 $H 2>&1); r=$?
ok "invalid UTF-8 in a force push → deny" '[ $r = 2 ]'
python3 - "$H" "$S/pg-import.py" <<'PY'
import sys
src = open(sys.argv[1]).read(); anchor = "\nimport json, re, shlex, signal, string\n"
assert anchor in src
open(sys.argv[2], "w").write(src.replace(anchor, anchor + 're.compile("(")\n', 1))  # as (?>…) failed on 3.9
PY
GUARD=$S/pg-import.py t $R "$G origin main" 2 "import-time crash: a plain push → deny (never exit 1)"
GUARD=$S/pg-import.py t $R "cmux tree" 2 "import-time crash: cmux → deny"
out=$(printf '{"tool_name":"Bash","cwd":"/","tool_input":{"command":"ls"}}' | hard python3 $S/pg-import.py 2>&1); r=$?
ok "import-time crash: ls → no decision" '[ $r = 0 ]'
out=$(python3 -c 'import importlib.util as u, sys; s = u.spec_from_file_location("hook", sys.argv[1]); s.loader.exec_module(u.module_from_spec(s))' $S/pg-import.py < /dev/null 2>&1); r=$?
ok "…but imported (install.sh's smoke test) the crash stays an error (exit $r)" '[ $r = 1 ] && grep -q "re.error\|error" <<< "$out"'
python3 - "$H" "$S/pg-hang.py" <<'PY'
import sys
src = open(sys.argv[1]).read(); anchor = "    signal.alarm(20)\n"
assert anchor in src
read = '        data = json.loads(RAW["text"])\n'
assert read in src  # a hang in the checks, after the input is read
open(sys.argv[2], "w").write(src.replace(anchor, "    signal.alarm(1)\n", 1).replace(read, read + "        while True: pass\n", 1))
PY
s0=$(date +%s); GUARD=$S/pg-hang.py t $W "$G origin HEAD:x" 2 "a hang in the checks: its alarm denies a push"; el=$(( $(date +%s) - s0 ))
ok "…within seconds (${el}s), not the 60s hook timeout" '[ $el -le 10 ]'
GUARD=$S/pg-hang.py t $W 'ls' 0 "…and gives ls no decision"
python3 - "$H" "$S/pg-stall.py" <<'PY'
import sys
src = open(sys.argv[1]).read(); anchor = "    signal.alarm(20)\n"
assert anchor in src
open(sys.argv[2], "w").write(src.replace(anchor, "    signal.alarm(1)\n", 1))
PY
mkfifo $S/fifo; (printf '{"tool_name":"Bash","tool_input":{"command":"ls'; exec sleep 30) > $S/fifo & wpid=$!
s0=$(date +%s); hard python3 $S/pg-stall.py < $S/fifo > $S/stall.out 2>&1; r=$?; el=$(( $(date +%s) - s0 )); kill $wpid 2>/dev/null
ok "stdin that never closes: the alarm denies (exit $r) without reading again" '[ $r = 2 ] && grep -q "stopped by SIGALRM" $S/stall.out'
ok "…within seconds (${el}s), not when the writer gives up" '[ $el -le 10 ]'
python3 - "$H" "$S/pg-spin.py" <<'PY'
import sys
src = open(sys.argv[1]).read(); anchor = "    signal.alarm(20)\n"
assert anchor in src
read = '        data = json.loads(RAW["text"])\n'
assert read in src  # spins while checking, after the input is read
open(sys.argv[2], "w").write(src.replace(read, read + "        open(os.environ['SPIN_READY'], 'w').close()\n        while True: pass\n", 1))
PY
python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' $W "$G origin HEAD:x" > $S/in.json
for k in TERM HUP; do
  rm -f $S/ready; SPIN_READY=$S/ready python3 $S/pg-spin.py < $S/in.json > $S/sig.out 2>&1 & pid=$!
  for _ in $(seq 100); do [ -e $S/ready ] && break; sleep 0.1; done
  kill -$k $pid; wait $pid; r=$?
  ok "SIG$k (a cancelled hook) while checking a push → deny (exit $r, not $([ $k = TERM ] && echo 143 || echo 129))" '[ $r = 2 ] && grep -q "stopped by SIG$k" $S/sig.out'
done
python3 - "$S/big.txt" "$G" <<'PY'
import sys
lines = []
for i in range(3000):
    lines += [f'cmux agent message surface:9 "READY: {i}"', f'echo "{sys.argv[2]} -f origin x{i}"', f'git log -1 --format=%H x{i}']
open(sys.argv[1], "w").write("\n".join(lines))
PY
s0=$(date +%s); t $R "$(cat $S/big.txt)" 0 "a 9000-line coordinator command"; el=$(( $(date +%s) - s0 ))
ok "…finishes well under the hook timeout (${el}s ≤ 15s)" '[ $el -le 15 ]'
s0=$(date +%s); t $W "$(cat $S/big.txt)" 2 "the same command from a worker → deny"; el=$(( $(date +%s) - s0 ))
ok "…also fast (${el}s ≤ 15s)" '[ $el -le 15 ]'

echo "-- C4: the hook command settings.example.json installs fails closed when the guard can't run (hook exit 1 = allowed)"
HOOKCMD=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([h["command"] for e in d["hooks"]["PreToolUse"] if e["matcher"]=="Bash" for h in e["hooks"] if "push-guard.py" in h["command"]][0])' "$ROOT/../settings.example.json")
ok "settings.example.json has the push-guard hook command" '[ -n "$HOOKCMD" ]'
FH=$S/fakehome; mkdir -p $FH/.claude/orchestra/hooks $S/nopy
# hc <guard file to install as push-guard.py, or none> <cwd> <command> <want exit> <label> [shell] [PATH]: runs the exact
# command string with HOME=$FH, as Claude Code does (a shell; JSON on stdin); a no-decision must also print nothing
hc(){ rm -f $FH/.claude/orchestra/hooks/push-guard.py; [ "$1" = none ] || cp "$1" $FH/.claude/orchestra/hooks/push-guard.py
  out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$2" "$3" \
        | (cd "$2" && HOME=$FH hard env PATH="${7:-$PATH}" ${6:-/bin/sh} -c "$HOOKCMD" 2>&1)); r=$?
  if [ $r = $4 ] && { [ $r = 2 ] || [ -z "$out" ]; }; then P=$((P+1)); echo "ok   $5"; else F=$((F+1)); echo "FAIL $5 (got $r) $out"; fi; }
cp $H $S/pg-syntax.py; printf '\ndef broken(:\n' >> $S/pg-syntax.py
ok "the planted copy really fails to compile" '! python3 -m py_compile $S/pg-syntax.py'
hc $S/pg-syntax.py $W "$G origin HEAD:x" 2 "SyntaxError in the guard: a worker's push → deny (exit 2, not 1)"
hc $S/pg-syntax.py $R "ls" 2 "…and every other command too (the guard is off: refuse until it loads)"
ok "…saying why" 'grep -q "push-guard failed to run (exit 1)" <<< "$out"'
printf 'import sys\nsys.exit(1)\n' > $S/pg-exit1.py
hc $S/pg-exit1.py $R "$G -f origin main" 2 "a guard that exits 1 → deny"
hc none $R "ls" 2 "the guard file missing → deny"
hc $H $R "ls" 2 "no python3 on PATH → deny" /bin/sh $S/nopy
# no shell syntax at the top level: a non-POSIX shell (fish) only splits words — argvsh does just that, then execs
printf '#!/usr/bin/env python3\nimport os, shlex, sys\na = shlex.split(sys.argv[2])\nos.execvp(a[0], a)\n' > $S/argvsh; chmod +x $S/argvsh
for SH in /bin/sh $(command -v bash) $(command -v zsh) $(command -v fish) $S/argvsh; do
  hc $S/pg-syntax.py $W "$G origin HEAD:x" 2 "a broken guard via the hook command ($SH) → deny" $SH
  hc $H $R "ls" 0 "real guard via the hook command ($SH): ls → no decision, no output" $SH
  hc $H $R "$G origin main" 0 "  …a normal push from the main checkout → no decision" $SH
  hc $H $R "$G --force origin main" 2 "  …a force push → deny" $SH
  ok "  …with the guard's own message only" '[ "$out" = "$(call $R "$G --force origin main")" ] && ! grep -q "failed to run" <<< "$out"'
  hc $H $W "$G origin HEAD:x" 2 "  …a worker's push → deny" $SH
  hc $H $W "cmux send --surface surface:70 hi" 2 "  …a worker's cmux send → deny" $SH
done

echo "PASSED $P FAILED $F"; [ $F = 0 ]
