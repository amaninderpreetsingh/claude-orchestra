#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# push-guard bypasses H1–H5: cd/subshell/quoted dirs, every cmux and evidence segment, no blanket allow for compound
# commands outside workers, an overall deadline that fails closed; plus quoted/heredoc text isn't evidence.
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-guard-bypass.XXXXXX"); trap 'rm -rf "$S"' EXIT; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch; H=$ROOT/hooks/push-guard.py
P=0; F=0
hook(){ # hook <cwd> <cmd> [agent_type] → hook output in $out, decision in $got
  out=$(python3 -c 'import json,sys;d={"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}
if sys.argv[3]: d["agent_type"]=sys.argv[3]
print(json.dumps(d))' "$1" "$2" "${3:-}" | python3 $H 2>&1); rc=$?
  got=silent; [ $rc = 2 ] && got=deny; echo "$out" | grep -q '"allow"' && got=allow; echo "$out" | grep -q '"ask"' && got=ask; true; }
expect(){ # expect <label> <want: allow|deny|silent> <cwd> <cmd> [agent_type]
  hook "$3" "$4" "${5:-}"
  if [ $got = $2 ]; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1: want $2 got $got :: $out"; fi; }
ok(){ if eval "$2" >/dev/null 2>&1; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }
V="ver""dict"; C="crit""erion"  # keep the evidence-writer pairs out of this file's own command text
NL=$'\n'

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo; R=$S/repo
echo 'echo ok' > gate.sh; echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main
echo b > a.txt; git commit -qam b
mkdir -p "$S/sp ace"; git clone -q $S/origin.git "$S/sp ace/r" 2>/dev/null
(cd "$S/sp ace/r" && echo c > c.txt && git add c.txt && git commit -qm c)

echo "-- H1: a tier record binds however the push reaches the checkout"
ok "tier M recorded in repo" "$O tier --set M --repo $R"
ok "tier M recorded in the spaced checkout" "$O tier --set M --repo '$S/sp ace/r'"
expect "plain push in the tiered checkout → deny (as before)" deny $R "git push origin main"
expect "cd repo; push → deny" deny $S "cd repo; git push origin main"
expect "cd repo newline push → deny" deny $S "cd repo${NL}git push origin main"
expect "(cd repo && push) subshell → deny" deny $S "(cd repo && git push origin main)"
expect "quoted spaced dir: cd \"sp ace/r\" && push → deny" deny $S "cd \"sp ace/r\" && git push origin main"
expect "single-quoted spaced dir → deny" deny $S "cd 'sp ace/r'; git push origin main"
expect "pushd repo; push → deny" deny $S "pushd repo >/dev/null; git push origin main"
expect "cd 2> /dev/null repo (spaced redirection); push → deny" deny $S "cd 2> /dev/null repo; git push origin main"
expect "cd > /dev/null repo && push → deny" deny $S "cd > /dev/null repo && git push origin main"
expect "apostrophe in a comment doesn't hide the cd → deny" deny $S "# it's${NL}cd repo; git push origin main # '"
expect "cd 2>/dev/null repo; push → deny" deny $S "cd 2>/dev/null repo; git push origin main"
expect "cd -- repo && push → deny" deny $S "cd -- repo && git push origin main"
expect "{ cd repo; push; } group → deny" deny $S "{ cd repo; git push origin main; }"
expect "if cd repo; then push; fi → deny" deny $S "if cd repo; then git push origin main; fi"
expect "cd inside bash -c (unresolvable) with a tiered candidate → deny" deny $S "bash -c \"cd repo && git push origin main\""
expect "cd \$X then push, session cwd tiered → deny" deny $R "cd \$X && git push origin main"
expect "cd repo && cd \$X && push: a visited dir is tiered → deny" deny $S "cd repo && cd \$X && git push origin main"
expect "-C \$X with a tiered session cwd → deny" deny $R "git -C \$X push origin main"
expect "subshell cd elsewhere doesn't move the push out of the tiered cwd → deny" deny $R "(cd $S && true); git push origin main"
expect "cd repo | push (pipeline cd has no effect) → deny" deny $R "cd $S | git push origin main"
expect "cd repo || cd elsewhere (may not run): tiered candidate → deny" deny $S "cd repo || cd $S/home; git push origin main"
expect "-C \"\$PWD/repo\" push (variable dir) → deny" deny $S "git -C \"\$PWD/repo\" push origin main"
expect "cd \"\$PWD/repo\" && push → deny" deny $S "cd \"\$PWD/repo\" && git push origin main"
export GUARD_TEST_DIR=$S  # an environment variable the hook shares with the shell, like $HOME
expect "cd \$VAR/repo (environment variable) && push → deny" deny $R/.. "cd \$GUARD_TEST_DIR/repo && git push origin main"
hook $S "cd \$X; cd $R && git push origin main"
ok "unknown cd then an absolute cd → tier deny, not a guard error" "[ $got = deny ] && echo \"\$out\" | grep -q 'tier' && ! echo \"\$out\" | grep -q 'push-guard error'"
rm -f $R/.git/orchestra-tier.json "$S/sp ace/r/.git/orchestra-tier.json"
expect "no tier: cd repo; push is no longer blanket-allowed (H4) → silent" silent $S "cd repo; git push origin main"
expect "no tier: cd \$(…) push → no decision (target computed), not allow" silent $S "cd \$(echo repo) && git push origin main"
expect "no tier: -C \$X push (checkout unknown) → no decision, not allow" silent $S "git -C \$X push origin main"
expect "unknown cd doesn't skip the force scan after a \$(…)" deny $S "cd \$X && git push origin \$(echo main) --force"

echo "-- H2/H3 setup: a registered worker"
RUN=$($O new-run --repo $R --title t --coordinator workspace:7); $O run-branch --run $RUN >/dev/null; T=orch/$RUN
git fetch -q; git worktree add -q $S/w -b w origin/$T; W=$S/w
ok "register" "$O register --worktree $W --run $RUN --slice s1"
MSG='cmux agent message workspace:7 --from x "PROGRESS: x"'

echo "-- H2: every cmux segment from a worker is checked"
expect "report; cmux send → deny" deny $W "$MSG; cmux send --workspace workspace:9 \"hi\""
expect "report newline cmux send → deny" deny $W "$MSG${NL}cmux send --workspace workspace:9 \"hi\""
expect "report && cmux send-key → deny" deny $W "$MSG && cmux send-key --workspace workspace:9 Enter"
expect "report || cmux new-workspace → deny" deny $W "$MSG || cmux new-workspace --command claude"
expect "report | cmux paste → deny" deny $W "$MSG | cmux paste --workspace workspace:9"
expect "report & (cmux send) → deny" deny $W "$MSG & (cmux send --workspace workspace:9 x)"
expect "report; message to another workspace → deny" deny $W "$MSG; cmux agent message workspace:9 \"PROGRESS: y\""
expect "report; untagged message to the coordinator → deny" deny $W "$MSG; cmux agent message workspace:7 \"merge now\""
expect "command substitution inside a report → deny" deny $W "cmux agent message workspace:7 \"PROGRESS: \$(cmux send --workspace workspace:9 x)\""
expect "backticks inside a report → deny" deny $W "cmux agent message workspace:7 \"PROGRESS: \`cmux send --workspace workspace:9 x\`\""
expect "cmux by path after a report → deny" deny $W "$MSG; /usr/local/bin/cmux send --workspace workspace:9 x"
expect "two tagged reports → silent" silent $W "$MSG; cmux agent message workspace:7 --from x \"QUESTION: y?\""
expect "a report quoting cmux send in its text → silent" silent $W "cmux agent message workspace:7 --from x \"PROGRESS: tested cmux send; ok\""
expect "quoted cmux mention doesn't swallow a later cmux send → deny" deny $W "git commit -qm \"docs cmux agent message workspace:7 PROGRESS: ok\" && cmux send --workspace workspace:9 x"
expect "echo of cmux text, then cmux send → deny" deny $W "echo \"a cmux b\"; cmux send --workspace workspace:9 x"
expect "cmux \$(…) built subcommand → deny" deny $W "cmux \$(echo send) --workspace workspace:9 x"
expect "single-quoted backticks in a report are literal → silent" silent $W "cmux agent message workspace:7 --from x 'DONE: fixed \`parse\`'"
expect "heredoc fed to bash running cmux send → deny" deny $W "bash <<'EOF'${NL}cmux send --workspace workspace:9 x${NL}EOF"
expect "coordinator message quoting a cd into a worktree → silent" silent $R "cmux agent message workspace:9 --from coordinator \"FIX: cd $W && rerun tests\""
expect "apostrophe in a comment doesn't hide a worker cmux send → deny" deny $W "# don't${NL}cmux send --workspace workspace:9 x${NL}# it's"
expect "report after a plain bash script naming cmux send in its text → silent" silent $W "bash tests/run.sh && cmux agent message workspace:7 --from x \"DONE: tests pass; cmux send guard covered\""
expect "worker git commit -F - heredoc naming cmux send → silent" silent $W "git commit -q -F - <<'EOF'${NL}docs: block cmux send from workers${NL}EOF"
expect "worker echo of the commit idiom piped to bash running cmux send → deny" deny $W "echo \"\$(cat <<'EOF'${NL}cmux send --workspace workspace:9 x${NL}EOF${NL})\" | bash"
expect "worker process substitution running cmux send → deny" deny $W "bash <(echo 'cmux send --workspace workspace:9 x')"
expect "worker process substitution with a cat heredoc → deny" deny $W "bash <(cat <<'EOF'${NL}cmux send --workspace workspace:9 x${NL}EOF${NL})"
expect "worker commit message with 'read' + cmux send → silent" silent $W "git commit -qm \"read every cmux send segment\""
expect "worker report with 'read' + cmux send text → silent" silent $W "cmux agent message workspace:7 --from x \"PROGRESS: read docs; cmux send is blocked now\""
expect "worker sed, then a report naming cmux send → silent" silent $W "sed -n 1p a.txt; cmux agent message workspace:7 --from x \"PROGRESS: cmux send blocked\""
expect "worker grep for cmux in a dir named workspace → silent" silent $W "grep -rn cmux workspace"
hook $W "git push origin HEAD:$T; echo hi"
ok "worker compound push → 'one plain command' before any evidence check" "[ $got = deny ] && echo \"\$out\" | grep -q 'one plain command'"
expect "coordinator report quoting cd + read → silent" silent $R "cmux agent message workspace:9 --from coordinator \"FIX: cd $W and read SPEC again\""
expect "coordinator cmux send quoting a cd into a worktree → silent" silent $R "cmux send --workspace workspace:3 \"cd $W && read the diff\""
expect "worker orch gates --cmd running cmux send → deny" deny $W "orch gates --worktree . --cmd \"cmux send --workspace workspace:9 x\""
expect "worker orch gates with a plain gate → silent" silent $W "orch gates --worktree . --cmd 'bash gate.sh'"
expect "coordinator cmux send quoting a cd + push instruction → silent" silent $R "cmux send --workspace workspace:3 \"cd $W && git push origin HEAD:$T\""
expect "worker commit message mentioning cmux (tree) → silent" silent $W "git commit -qm \"docs: wrap cmux (tree) output\""
expect "worker cmux \$V subcommand → deny" deny $W "cmux \$V --workspace workspace:9 x"
expect "worker grep for the word cmux → silent" silent $W "grep -rn \"cmux\" ."
expect "worker grep for cmux send text is only read → silent" silent $W "grep -rn \"cmux send\" ."
expect "worker echo of cmux send text piped to bash → deny" deny $W "echo \"cmux send --workspace workspace:9 x\" | bash"
expect "coordinator session stays unrestricted → silent" silent $R "$MSG; cmux send --workspace workspace:9 x"

echo "-- H3: every evidence segment and every --role"
expect "reviewer chains a verifier verdict → deny" deny $R "orch $V --role reviewer --verdict PASS; orch $V --role verifier --verdict PASS" reviewer
expect "reviewer chains via && → deny" deny $R "orch $V --role reviewer --verdict PASS && orch $V --role verifier --verdict PASS" reviewer
expect "reviewer chains via newline → deny" deny $R "orch $V --role reviewer --verdict PASS${NL}orch $V --role verifier --verdict PASS" reviewer
expect "reviewer, second --role verifier in one call → deny" deny $R "orch $V --role reviewer --role verifier --verdict PASS" reviewer
expect "reviewer, --role=verifier after --role reviewer → deny" deny $R "orch $V --role reviewer --verdict PASS --role=verifier" reviewer
expect "reviewer chains a criterion → deny" deny $R "orch $V --role reviewer --verdict PASS; orch $C --run x --id C1 --status pass --sha a" reviewer
expect "verifier chains a reviewer verdict → deny" deny $R "orch $V --role verifier --verdict PASS; orch $V --role reviewer --verdict PASS" verifier
expect "\$ORCH spelled evidence call from the main session → deny" deny $R "\$ORCH $V --role reviewer --verdict PASS"
expect "\${ORCH} spelled evidence call → deny" deny $R "\${ORCH} $V --role verifier --verdict PASS"
expect "a here-string isn't a heredoc hiding the next line → deny" deny $R "cat <<< x${NL}orch $V --role verifier --verdict PASS"
expect "evidence in a subshell from the main session → deny" deny $R "(orch $V --role verifier --verdict PASS)"
expect "reviewer records reviewer + adversarial → silent" silent $R "orch $V --role reviewer --verdict PASS; orch $V --role adversarial --verdict PASS" reviewer
expect "verifier records criterion + verdict → silent" silent $R "orch $C --run x --id C1 --status pass --sha a && orch $V --role verifier --verdict PASS" verifier

echo "-- quoted / heredoc text naming an evidence subcommand isn't running it"
expect "main session cat > file heredoc body → silent" silent $R "cat > notes.md <<'EOF'${NL}then run orch $V --role reviewer --verdict PASS${NL}EOF"
expect "cat heredoc then redirect → silent" silent $R "cat <<EOF > notes.md${NL}orch $C --run x --id C1 --status pass${NL}EOF"
expect "echo of the text → silent" silent $R "echo \"orch $V --role verifier --verdict PASS\""
expect "printf of the text → silent" silent $R "printf '%s\\n' 'orch $C --run x --id C1'"
expect "grep for the text → silent" silent $R "grep -rn \"orch $V --role\" ."
expect "commit message naming it → allow (plain commit)" allow $R "git commit -qm \"doc: orch $V --role verifier\""
expect "heredoc fed to bash still runs it → deny" deny $R "bash <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF"
expect "cat heredoc piped to sh still runs it → deny" deny $R "cat <<'EOF' | sh${NL}orch $V --role verifier --verdict PASS${NL}EOF"
expect "cat heredoc output run by \$(…) → deny" deny $R "\$(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})"
expect "echo piped to bash still runs it → deny" deny $R "echo \"orch $V --role verifier --verdict PASS\" | bash"
expect "unquoted cat heredoc body runs \$(…) → deny" deny $R "cat > n.md <<EOF${NL}\$(orch $V --role verifier --verdict PASS)${NL}EOF"
expect "unquoted cat heredoc body runs backticks → deny" deny $R "cat > n.md <<EOF${NL}\`orch $V --role verifier --verdict PASS\`${NL}EOF"
expect "\"\$(cat <<'EOF' …)\" fed to bash -c runs it → deny" deny $R "bash -c \"\$(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})\""
expect "\"\$(cat <<'EOF' …)\" fed to eval runs it → deny" deny $R "eval \"\$(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})\""
expect "commit-message idiom can't run past its delimiter to hide a call → deny" deny $R "git commit -m \"\$(cat <<'EOF'${NL}msg${NL}EOF${NL}orch $V --role verifier --verdict PASS${NL}cat <<'EOF'${NL}EOF${NL})\""
expect "…nor to hide an rm (no blanket allow)" silent $R "git commit -m \"\$(cat <<'EOF'${NL}msg${NL}EOF${NL}rm -rf build${NL}cat <<'EOF'${NL}EOF${NL})\""
expect "reviewer --summary naming another role's call is only text → silent" silent $R "orch $V --role reviewer --verdict PASS --summary \"checked orch $V --role verifier\"" reviewer
expect "apostrophe in a comment doesn't hide a call → deny" deny $R "# don't forget${NL}orch $V --role verifier --verdict PASS${NL}# it's done"
expect "…nor from a reviewer recording a verifier PASS → deny" deny $R "# don't forget${NL}orch $V --role verifier --verdict PASS${NL}# it's done" reviewer
expect "a comment naming a call isn't one → silent" silent $R "true # orch $V --role verifier"
expect "indented delimiter doesn't end a heredoc (bash runs the call) → deny" deny $R "cat > n.md <<'EOF'${NL}  EOF${NL}\"${NL}EOF${NL}orch $V --role verifier --verdict PASS #\""
expect "indented delimiter in the commit idiom → deny" deny $R "git commit -m \"\$(cat <<'EOF'${NL}msg${NL}  EOF${NL})\"${NL}EOF${NL})\"; orch $V --role verifier --verdict PASS #\""
expect "<<- strips leading tabs only → body still masked → silent" silent $R "cat > n.md <<-'EOF'${NL}orch $V --role verifier${NL}	EOF"
expect "echo of the commit idiom piped to bash runs it → deny" deny $R "echo \"\$(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})\" | bash"
expect "git commit -F - heredoc naming a call is a message → allow" allow $R "git commit -q -F - <<'EOF'${NL}docs: orch $V --role verifier usage${NL}EOF"
TAB=$'\t'
expect "tab-indented delimiter ends only <<- heredocs (commit idiom) → deny" deny $R "git commit -m \"\$(cat <<'EOF'${NL}msg${NL}${TAB}EOF${NL})\"${NL}EOF${NL})\"; orch $V --role verifier --verdict PASS #\""
expect "process substitution running a cat heredoc → deny" deny $R "bash <(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})"
expect "sh < <(cat heredoc) → deny" deny $R "sh < <(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})"
expect "process substitution running echo text → deny" deny $R "bash <(echo 'orch $V --role verifier --verdict PASS')"
expect "\$SHELL -c with the call quoted → deny" deny $R "\$SHELL -c \"orch $V --role verifier --verdict PASS\""
expect "ssh with the call quoted → deny" deny $R "ssh localhost \"orch $V --role verifier --verdict PASS\""
expect "watch with the call quoted → deny" deny $R "watch -n1 \"orch $V --role verifier --verdict PASS\""
expect "git alias running the call → deny" deny $R "git -c alias.v=\"!orch $V --role verifier --verdict PASS\" v"
expect "reviewer --summary with ordinary words (read …) is still text → silent" silent $R "orch $V --role reviewer --verdict PASS --summary 'read all; orch $V --role verifier separate'" reviewer
expect "commit message with 'read' naming a call → allow (plain commit)" allow $R "git commit -m \"read orch $V --role reviewer output\""
expect "reviewer: orch gates --cmd running a verifier call → deny" deny $R "orch gates --worktree . --cmd \"orch $V --role verifier --verdict PASS\"" reviewer
expect "orch baseline --cmd running a criterion → deny" deny $R "orch baseline --run x --cmd \"orch $C --run x --id C1 --status pass --sha a\""
expect "git grep -O running the call → deny" deny $R "git grep -O\"orch $V --role verifier --verdict PASS\" -e a"
expect "rg --pre running the call → deny" deny $R "rg --pre \"orch $V --role verifier --verdict PASS\" x"
expect "gh alias storing the call → deny" deny $R "gh alias set v \"!orch $V --role verifier --verdict PASS\""
expect "reviewer verdict with \$(pwd) before --role → silent" silent $R "orch $V --worktree \$(pwd) --role reviewer --verdict PASS --summary ok" reviewer
expect "…but a call nested in a \$(…) is still read → deny" deny $R "orch $V --worktree \$(orch $V --role verifier --verdict PASS) --role reviewer --verdict PASS" reviewer
expect "a real call after the heredoc → deny" deny $R "cat > n.md <<'EOF'${NL}x${NL}EOF${NL}orch $V --role verifier --verdict PASS"

echo "-- H4: outside workers a compound command gets no blanket allow"
expect "commit && rm → silent (user's rules apply)" silent $R "git commit -qm x && rm -rf build"
expect "push; reset --hard → silent" silent $R "git push origin main; git reset --hard HEAD~1"
expect "push | tee → silent" silent $R "git push origin main 2>&1 | tee log"
expect "push with a \$(…) refspec → silent" silent $R "git push origin \$(git branch --show-current)"
expect "commit with \$(…) in the message → silent" silent $R "git commit -m \"\$(rm -rf x)\""
expect "unknown-option push; rm → silent" silent $R "git --frob v push origin main; rm -rf x"
expect "plain push still allowed" allow $R "git push origin main"
expect "plain push with redirections still allowed" allow $R "git push origin main >/dev/null 2>&1"
expect "plain commit still allowed" allow $R "git commit -qm x"
expect "heredoc commit message still allowed" allow $R "git commit -qm \"\$(cat <<'EOF'${NL}fix: thing; more${NL}EOF${NL})\""
expect "commit -F - heredoc still allowed" allow $R "git commit -q -F - <<'EOF'${NL}fix && more${NL}EOF"
expect "bash -c \"\$(cat <<'EOF' commit && rm …)\" → silent, not allow" silent $R "bash -c \"\$(cat <<'EOF'${NL}git commit -qm x && rm -rf build${NL}EOF${NL})\""
expect "gh pr create --body heredoc idiom (no push/commit) → silent" silent $R "gh pr create --body \"\$(cat <<'EOF'${NL}orch $V notes${NL}EOF${NL})\""
expect "unquoted heredoc running \$(…) → silent" silent $R "git commit -qm \"\$(cat <<EOF${NL}\$(rm -rf x)${NL}EOF${NL})\""
expect "bash -c with a push && rm inside its quotes → silent, not allow" silent $R "bash -c \"git push origin main && rm -rf build\""
expect "sh -c with a commit; rm inside its quotes → silent, not allow" silent $R "sh -c 'git commit -qm x; rm -rf build'"
expect "eval of a push; rm → silent, not allow" silent $R "eval \"git push origin main; rm -rf build\""
expect "ssh running a push → silent, not allow" silent $R "ssh localhost \"git push origin main\""
expect "sudo git push (program isn't git itself) → silent, not allow" silent $R "sudo git push origin main"
expect "VAR=value git push (an env prefix can point git at a program) → silent, not allow" silent $R "GIT_TRACE=0 git push origin main"
expect "GIT_SSH_COMMAND push → silent, not allow" silent $R "GIT_SSH_COMMAND='touch x' git push origin main"
expect "git -c core.sshCommand push → silent, not allow" silent $R "git -c core.sshCommand='touch x' push origin main"
expect "git -c core.editor commit → silent, not allow" silent $R "git -c core.editor='rm -rf zz' commit"
expect "commit redirected into a file → silent, not allow" silent $R "git commit -qm x > \$HOME/.zshrc"
expect "./git (not git itself) → silent, not allow" silent $R "./git push origin main"
expect "push --receive-pack (runs a program) → silent, not allow" silent $R "git push --receive-pack='touch x' origin main"
expect "push --exec → silent, not allow" silent $R "git push --exec='touch x' origin main"
expect "push --rece (abbreviated --receive-pack) → silent, not allow" silent $R "git push --rece='touch x' origin main"
expect "env-prefixed grep for push text only reads → allow (as before)" allow $R "LC_ALL=C grep -rn \"git push\" ."
expect "…the same grep under bash -c → silent, not allow" silent $R "bash -c 'grep -rn \"git push\" .'"
expect "…grep writing a file → silent, not allow" silent $R "grep -rn \"git push\" . > hits.txt"
expect "…rg --pre (runs a program) → silent, not allow" silent $R "rg --pre ./x \"git push\" ."

echo "-- cmux typed/spawned text runs in an unguarded shell; only an agent message's text is data"
mkdir -p $S/plain
ok "tier M recorded in repo" "$O tier --set M --repo $R"
expect "cmux send typing a push into a terminal, tiered cwd → deny" deny $R "cmux send --workspace workspace:3 \"git push origin main\""
expect "cmux new-workspace --command running a push, tiered cwd → deny" deny $R "cmux new-workspace --command \"git push origin main\""
expect "cmux send typing a force push → deny" deny $S/plain "cmux send --workspace workspace:3 \"git push --force origin main\""
expect "cmux new-workspace --command running a force push → deny" deny $S/plain "cmux new-workspace --command 'git push -f origin main'"
expect "cmux send typing cd <tiered> && push → deny (tier candidate)" deny $S/plain "cmux send --workspace workspace:3 \"cd $R && git push origin main\""
expect "agent message naming a force push is only text → silent" silent $S/plain "cmux agent message workspace:9 --from c \"FIX: never git push --force\""
expect "…the same text under bash -c still runs it → deny" deny $S/plain "bash -c 'cmux agent message workspace:9 --from c \"FIX: git push --force origin main\"'"
expect "…and under sh -c a tier-bound push → deny" deny $R "sh -c 'cmux agent message workspace:9 \"x\"; git push origin main'"

echo "-- a conditional cd (it may not run) leaves the checkout unknown"
expect "false && cd other; push from a tiered cwd → deny" deny $R "false && cd \"$S/sp ace/r\"; git push origin main"
expect "false && cd other && true; push → deny" deny $R "false && cd \"$S/sp ace/r\" && true; git push origin main"
expect "cd other || true; push → deny" deny $R "cd \"$S/sp ace/r\" || true; git push origin main"
expect "if false; then cd other; fi; push → deny" deny $R "if false; then cd \"$S/sp ace/r\"; fi; git push origin main"
expect "if/else with a cd in one branch → deny" deny $R "if false; then cd \"$S/sp ace/r\"; else git push origin main; fi"
expect "while false; do cd other; done; push → deny" deny $R "while false; do cd \"$S/sp ace/r\"; done; git push origin main"
expect "for loop body cd; push → deny" deny $R "for d in x; do cd \"$S/sp ace/r\"; done; git push origin main"
expect "case branch cd; push → deny" deny $R "case x in y) cd \"$S/sp ace/r\";; esac; git push origin main"
expect "function body cd (never called); push → deny" deny $R "f() { cd \"$S/sp ace/r\"; }; git push origin main"
expect "function keyword body cd; push → deny" deny $R "function f { cd \"$S/sp ace/r\"; }; git push origin main"
expect "pushd inside an if body; push → deny" deny $R "if false; then pushd \"$S/sp ace/r\"; fi; git push origin main"
expect "true && cd other && push runs only after the cd → not a tier deny" silent $R "true && cd \"$S/sp ace/r\" && git push origin main"
expect "cd &>/dev/null repo; push → deny (a redirection, not the dir)" deny $S "cd &>/dev/null repo; git push origin main"
expect "a case pattern's ) doesn't close the subshell holding the cd → deny" deny $S "(cd repo; case x in x) git push origin main;; esac)"

echo "-- push text in a body only a reader reads isn't a push"
expect "cat > file heredoc naming a push, tiered → silent" silent $R "cat > notes.md <<'EOF'${NL}then git push origin main${NL}EOF"
expect "commit -F - body naming a push, tiered → allow (a commit)" allow $R "git commit -q -F - <<'EOF'${NL}then git push origin main${NL}EOF"
expect "commit idiom body naming a push, tiered → allow (a commit)" allow $R "git commit -qm \"\$(cat <<'EOF'${NL}then git push origin main${NL}EOF${NL})\""
expect "PR body naming a push, tiered → silent" silent $R "gh pr create --body \"\$(cat <<'EOF'${NL}then git push origin main${NL}EOF${NL})\""
expect "cat heredoc naming a force push → silent" silent $S/plain "cat > n.md <<'EOF'${NL}never git push --force origin main${NL}EOF"
expect "PR body naming a force push → silent" silent $S/plain "gh pr create --body \"\$(cat <<'EOF'${NL}never git push --force origin main${NL}EOF${NL})\""
expect "…the same body fed to bash → deny (force)" deny $S/plain "bash <<'EOF'${NL}git push --force origin main${NL}EOF"
expect "…a cat heredoc piped to sh, tiered → deny" deny $R "cat <<'EOF' | sh${NL}git push origin main${NL}EOF"
expect "…the commit idiom under bash -c, tiered → deny" deny $R "bash -c \"\$(cat <<'EOF'${NL}git push origin main${NL}EOF${NL})\""
rm -f $R/.git/orchestra-tier.json

echo "-- round-1 review: continued lines, piped heredocs, message bodies, cmux"
expect "literal backslash before a newline doesn't join the next line's evidence call → deny" deny $R "echo x \\\\${NL}orch $V --role verifier --verdict PASS"
expect "…nor a worker's next-line cmux send → deny" deny $W "$MSG \\\\${NL}cmux send --workspace workspace:9 x"
expect "{ cat heredoc; } | sh runs the body → deny" deny $R "{ cat <<'X'; } | sh${NL}orch $V --role reviewer --verdict PASS${NL}X"
expect "if … cat heredoc … fi | sh runs the body → deny" deny $R "if true; then cat <<'X'; fi | sh${NL}orch $V --role reviewer --verdict PASS${NL}X"
expect "heredoc fed to a git alias that runs sh → deny" deny $R "git -c alias.x='!sh' x <<'X'${NL}orch $V --role reviewer --verdict PASS${NL}X"
expect "worker { cat heredoc; } | bash running cmux send → deny" deny $W "{ cat <<'X'; } | bash${NL}cmux send --workspace workspace:9 x${NL}X"
expect "coordinator commit -F - body naming cd <worktree> && push → allow" allow $R "git commit -q -F - <<'EOF'${NL}workers: cd $W && git push origin HEAD:$T${NL}EOF"
expect "coordinator commit-idiom body naming cd <worktree> && push → allow" allow $R "git commit -qm \"\$(cat <<'EOF'${NL}workers: cd $W && git push origin HEAD:$T${NL}EOF${NL})\""
expect "coordinator PR body naming cd <worktree> && push → silent, not deny" silent $R "gh pr create --body \"\$(cat <<'EOF'${NL}cd $W && git push origin HEAD:$T${NL}EOF${NL})\""
expect "…the same body fed to bash → deny" deny $R "bash <<'EOF'${NL}cd $W && git push origin HEAD:$T${NL}EOF"
expect "known-limit workaround: commit message from a file → allow" allow $R "git commit -q -F msg.txt"
expect "…the same idiom under bash -c → deny" deny $R "bash -c \"\$(cat <<'EOF'${NL}cd $W && git push origin HEAD:$T${NL}EOF${NL})\""
expect "cd <worktree> && bash -c cmux send; cd back → deny (checked where it runs)" deny $R "cd $W && bash -c \"cmux send --workspace workspace:9 x\"; cd $R"
expect "gh alias set with the commit idiom storing a call → deny" deny $R "gh alias set v \"\$(cat <<'EOF'${NL}orch $V --role verifier --verdict PASS${NL}EOF${NL})\""
expect "worker cmux \$SUB agent message → deny" deny $W "cmux \$SUB agent message workspace:7 --from x \"PROGRESS: y\""
expect "orch -- verdict from the main session → deny" deny $R "orch -- $V --role verifier --verdict PASS"
expect "coordinator echo quoting cd <worktree>, then cmux send → silent" silent $R "echo \"next: cd $W\"; cmux send --workspace workspace:3 \"read SPEC\""
expect "coordinator git log --grep cd <worktree>, then cmux send → silent" silent $R "git log --grep \"cd $W\" -1; cmux send --workspace workspace:3 x"
expect "…a cd <worktree> under bash -c with cmux send → deny (worker candidate)" deny $R "bash -c \"cd $W && cmux send --workspace workspace:3 x\""
expect "…echo of cd <worktree> + cmux send piped to bash → deny" deny $R "echo \"cd $W && cmux send --workspace workspace:3 x\" | bash"
expect "…echo of cd <worktree> sourced by <( … ), then cmux send → deny" deny $R "source <(echo \"cd $W\"); cmux send --workspace workspace:3 x"
expect "worker xargs cmux (verb fed on stdin) → deny" deny $W "echo send --workspace w x | xargs cmux"
expect "worker xargs -I cmux → deny" deny $W "printf 'send x' | xargs -I{} cmux {} --workspace w x"
ok "a deadline raised while decoding \$'…' isn't swallowed" "python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location(\"pg\", sys.argv[1]); pg = importlib.util.module_from_spec(spec); spec.loader.exec_module(pg)
def boom(*a): raise pg.Deadline()
pg.codecs.decode = boom
try: pg.unquoted(\"x \$\x27a\x27\")
except pg.Deadline: sys.exit(0)
sys.exit(1)' $H"

echo "-- H5: one active_tier per invocation, overall deadline fails closed"
REALGIT=$(command -v git); mkdir -p $S/slow
cat > $S/slow/git <<EOF
#!/bin/sh
echo "\$*" >> $S/git.log
case " \$* " in *" \$SLOW "*) sleep 8;; esac
exec $REALGIT "\$@"
EOF
chmod +x $S/slow/git
ok "tier S recorded" "$O tier --set S --repo $R"
ok "gates" "$O gates --worktree $R --cmd 'bash gate.sh'"
ok "lite PASS" "$O $V --worktree $R --role reviewer --verdict PASS --mode lite"
: > $S/git.log; SLOW=none PATH=$S/slow:$PATH hook $R "git push origin main; git push origin main"
ok "two pushes, active_tier (rev-list scan) computed once" "[ \$(grep -c 'rev-list --max-count' $S/git.log) = 1 ]"
ok "tier M on the pushed commit" "$O tier --set M --repo $R"
t0=$(date +%s); SLOW=rev-list ORCH_GUARD_DEADLINE=3 PATH=$S/slow:$PATH hook $R "git push origin main"; el=$(( $(date +%s) - t0 ))
ok "slow tier scan under a tier record → deny" "[ $got = deny ]"
ok "…within the deadline (${el}s)" "[ $el -le 6 ]"
ok "…with a deadline message" "echo \"\$out\" | grep -qi 'deadline'"
SLOW=rev-list ORCH_GUARD_DEADLINE=3 PATH=$S/slow:$PATH hook $S "git -C $R push origin main"
ok "past the deadline, -C into a tiered checkout → deny (fallback follows -C)" "[ $got = deny ]"
rm -f $R/.git/orchestra-tier.json
cd $W; echo c > c.txt; git add .; git commit -qm s1
ok "gates" "$O gates --worktree $W --cmd 'bash $R/gate.sh'"
ok "reviewer PASS" "$O $V --worktree $W --role reviewer --verdict PASS"
ok "verifier PASS" "$O $V --worktree $W --role verifier --verdict PASS"
ok "gates-ok" "$O gates-ok --worktree $W"
ok "merge lock" "$O merge-lock --repo $W --owner $RUN-s1 --wait 0"
expect "worker push with evidence → allow" allow $W "git push origin HEAD:$T"
expect "worker push chained with rm → deny (one plain command)" deny $W "git push origin HEAD:$T; rm -rf build"
expect "worker push backgrounded with & → deny (its failure would be lost)" deny $W "git push origin HEAD:$T &"
hook $W "git push origin HEAD:$T 2>&1 | tail -3"
ok "worker push piped → deny naming the one plain command" "[ $got = deny ] && echo \"\$out\" | grep -q 'one plain command'"
t0=$(date +%s); SLOW=fetch ORCH_GUARD_DEADLINE=3 PATH=$S/slow:$PATH hook $W "git push origin HEAD:$T"; el=$(( $(date +%s) - t0 ))
ok "worker push, slow fetch past the deadline → deny" "[ $got = deny ]"
ok "…within the deadline (${el}s)" "[ $el -le 6 ]"
ok "…with a deadline message" "echo \"\$out\" | grep -qi 'deadline'"
SLOW=fetch ORCH_GUARD_DEADLINE=3 PATH=$S/slow:$PATH hook $R "git -C $W push origin HEAD:$T"
ok "coordinator -C into a worker, slow fetch past the deadline → deny" "[ $got = deny ]"
t0=$(date +%s); SLOW=rev-parse ORCH_GUARD_DEADLINE=3 PATH=$S/slow:$PATH hook $W "cmux send --workspace workspace:9 x"; el=$(( $(date +%s) - t0 ))
ok "worker cmux send, every git call slow → deny" "[ $got = deny ]"
ok "…within the deadline (${el}s)" "[ $el -le 6 ]"
t0=$(date +%s); SLOW=rev-parse ORCH_GUARD_DEADLINE=3 PATH=$S/slow:$PATH hook $S "ls"; el=$(( $(date +%s) - t0 ))
ok "unrelated command, slow git → no decision" "[ $got = silent ]"

echo; echo "PASSED $P  FAILED $F"; [ $F = 0 ]
