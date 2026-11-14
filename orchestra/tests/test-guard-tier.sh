#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Tier S (lite) path: main-checkout pushes need gates + a reviewer PASS on HEAD once `orch tier --set S` is recorded.
set -u
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-guard-tier.XXXXXX"); trap 'rm -rf $S' EXIT; cd $S  # unique: workers run suites concurrently
export ORCH_HOME=$S/home; O=$ROOT/bin/orch; H=$ROOT/hooks/push-guard.py
P=0; F=0
expect(){ # expect <label> <want: allow|deny> <cwd> <cmd> [agent_type]
  out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"agent_type":sys.argv[3],"tool_input":{"command":sys.argv[2]}}))' "$3" "$4" "${5:-}" | python3 $H 2>&1); rc=$?
  got=silent; [ $rc = 2 ] && got=deny; echo "$out" | grep -q '"allow"' && got=allow; echo "$out" | grep -q '"ask"' && got=ask
  if [ $got = $2 ]; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1: want $2 got $got :: $out"; fi; }
ok(){ if eval "$2" >/dev/null 2>&1; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1"; fi; }
V="ver""dict"  # keep the evidence-writer pair out of this file's own command text

git init -q --bare -b main origin.git; git clone -q origin.git repo 2>/dev/null; cd repo; R=$S/repo
echo 'echo ok' > gate.sh; echo 'exit 1' > fail.sh; echo a > a.txt; git add .; git commit -qm init; git push -q origin main; git remote set-head origin main
PUSH="git push origin main"

echo "-- no tier recorded: today's behaviour"
echo b > a.txt; git commit -qam b
expect "no tier → main-checkout push allowed" allow $R "$PUSH"

echo "-- tier S"
ok "tier --set S recorded" "$O tier --set S --repo $R"
ok "tier file holds HEAD" "python3 -c 'import json,sys;t=json.load(open(\"$R/.git/orchestra-tier.json\"));assert t[\"tier\"]==\"S\" and t[\"sha\"]==sys.argv[1]' $(git rev-parse HEAD)"
ok "tier rejects other values" "! $O tier --set X --repo $R"
expect "tier S, nothing else → deny" deny $R "$PUSH"
ok "gates run on main checkout (unregistered)" "$O gates --worktree $R --cmd 'bash gate.sh'"
expect "tier S + gates, no reviewer → deny" deny $R "$PUSH"
ok "lite mode accepted" "$O $V --worktree $R --role reviewer --verdict BLOCK --mode lite"
expect "latest reviewer BLOCK → deny" deny $R "$PUSH"
ok "lite PASS" "$O $V --worktree $R --role reviewer --verdict PASS --mode lite"
expect "tier S + gates + lite PASS → allow" allow $R "$PUSH"
expect "cd-prefixed push resolves the checkout (not denied; compound: no decision, H4)" silent $S "cd $R && $PUSH"
expect "-C push from elsewhere resolves the evidenced checkout → allow" allow $S "git -C $R push origin main"

echo "-- evidence must be for HEAD"
echo c > a.txt; git commit -qam c
expect "new commit after tier S (unshipped) → deny" deny $R "$PUSH"
ok "re-tier S for new HEAD" "$O tier --set S --repo $R"
expect "verdict + gates are for the old HEAD → deny" deny $R "$PUSH"
ok "failing gate" "! $O gates --worktree $R --cmd 'bash fail.sh'"
ok "lite PASS on new HEAD" "$O $V --worktree $R --role reviewer --verdict PASS --mode lite"
expect "failed gate → deny" deny $R "$PUSH"
ok "gates pass" "$O gates --worktree $R --cmd 'bash gate.sh'"
expect "gates + lite PASS on the new HEAD → allow" allow $R "$PUSH"

echo "-- shipped tier no longer applies"
git push -q origin main
echo d > a.txt; git commit -qam d
expect "tier S already on origin → next push behaves as today" allow $R "$PUSH"
ok "tier M recorded" "$O tier --set M --repo $R"
expect "tier M on the pushed commit → main-checkout push denied" deny $R "$PUSH"
out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"git push origin main"}}))' $R | python3 $H 2>&1)
ok "M deny names the worker path and --replace" "echo '$out' | grep -q 'orch spawn' && echo '$out' | grep -q -- '--replace'"
ok "tier L recorded" "$O tier --set L --repo $R"
expect "tier L on the pushed commit → denied" deny $R "$PUSH"

echo "-- evidence writer still agent-only"
expect "main session can't record lite reviewer" deny $R "orch $V --role reviewer --verdict PASS --mode lite"
expect "reviewer records lite" silent $R "orch $V --role reviewer --verdict PASS --mode lite" reviewer

echo "-- tier binds to a committed, unshipped change"
git push -q origin main                                                        # HEAD == origin/main
ok "tier S refused before the change is committed" "! $O tier --set S --repo $R"
git checkout -q -b fix; echo e > a.txt; git commit -qam e; ok "tier S on branch fix" "$O tier --set S --repo $R"
git checkout -q main; echo f > b.txt; git add b.txt; git commit -qm f
expect "tier S on an unrelated sibling branch → main push as today" allow $R "$PUSH"
expect "pushing the tier-S commit by refspec from another branch → deny" deny $R "git push origin fix:main"
git checkout -q fix; echo g > a.txt; git commit -qam g
expect "commit on top of tier S, no evidence → deny" deny $R "git push origin fix"
ok "gates on fix" "$O gates --worktree $R --cmd 'bash gate.sh'"
ok "full reviewer PASS" "$O $V --worktree $R --role reviewer --verdict PASS --mode full"
expect "full-mode reviewer PASS counts → allow" allow $R "git push origin fix"
expect "redirections and option values aren't refspecs" allow $R "git push -o ci.skip origin fix >/dev/null 2>&1"

echo "-- rewrites/copies stay bound to the tier-S change; unrelated work doesn't"
fresh(){ git checkout -q main; git reset -q --hard origin/main; git branch -q -D fix backup 2>/dev/null; rm -f .git/orchestra-tier.json; true; }
tierS(){ $O tier --set S --repo $R >/dev/null; }
evid(){ $O gates --worktree $R --cmd 'bash gate.sh' >/dev/null; $O $V --worktree $R --role reviewer --verdict PASS --mode lite >/dev/null; }
fresh; echo h > a.txt; git commit -qam h; tierS; echo h2 > a.txt; git commit -q --amend -am h2
expect "amend, no new evidence → deny" deny $R "$PUSH"
ok "re-tier S on the amended commit" "$O tier --set S --repo $R"; evid
expect "amended + re-tiered + evidence → allow" allow $R "$PUSH"
fresh; git checkout -q -b fix; echo j > a.txt; git commit -qam j; tierS; git checkout -q main; git cherry-pick fix >/dev/null
expect "cherry-pick onto main, original still on fix → deny" deny $R "$PUSH"
fresh; git checkout -q -b fix; echo k > a.txt; git commit -qam k; tierS; git checkout -q main; git merge -q --squash fix; git commit -qm k
expect "squash-merge onto main → deny" deny $R "$PUSH"
fresh; echo l > a.txt; git commit -qam l; tierS; git branch backup; echo l2 > a.txt; git commit -q --amend -am l2
expect "amend while a backup branch keeps the original → deny" deny $R "$PUSH"
fresh; echo r > a.txt; git commit -qam r; tierS; git mv a.txt a2.txt; git commit -q --amend -m r2
expect "amend that renames the touched file → deny" deny $R "$PUSH"
fresh; echo m > a.txt; git commit -qam m; tierS; evid; git push -q origin HEAD:refs/heads/preview; echo m2 > a.txt; git commit -q --amend -am m2
expect "original on a preview branch, amended copy to main → deny" deny $R "$PUSH"
fresh; git checkout -q -b fix; echo n > a.txt; git commit -qam n; tierS; git checkout -q main; echo n2 > b.txt; git add b.txt; git commit -qm n2
ok "tier S on unrelated work while fix's S is unshipped → refused" "! $O tier --set S --repo $R"
expect "fix still needs evidence" deny $R "git push origin fix"
ok "--replace drops the old tier" "$O tier --set S --repo $R --replace"
fresh; git checkout -q -b fix; echo s > a.txt; git commit -qam s; tierS; git checkout -q main; echo s2 > b.txt; git add b.txt; git commit -qm s2
expect "second push in one command carries the S commit → deny" deny $R "$PUSH && git push origin fix"
fresh; echo p > a.txt; git commit -qam p; tierS; git reset -q --hard origin/main; echo p2 > b.txt; git add b.txt; git commit -qm p2
expect "abandoned S change, unrelated push → allow" allow $R "$PUSH"
echo p3 > a.txt; git commit -qam p3
expect "abandoned, then new work in the same file → deny" deny $R "$PUSH"
ok "--clear refused while unpushed work touches the S files" "! $O tier --clear --repo $R"
git reset -q --hard HEAD~1
ok "tier --clear drops the abandoned record" "$O tier --clear --repo $R && test ! -e .git/orchestra-tier.json"
echo p4 > a.txt; git commit -qam p4
expect "after --clear, same-file push behaves as today" allow $R "$PUSH"
fresh; echo q > a.txt; git commit -qam q; tierS; git commit -q --amend -m q2
ok "--clear refused for an amended S copy (no evidence)" "! $O tier --clear --repo $R"
expect "amended S copy still denied" deny $R "$PUSH"
fresh; mkdir -p "My App"; echo u > "My App/View.swift"; git add .; git commit -qm u; tierS; echo u2 > "My App/View.swift"; git commit -q --amend -am u2
expect "amend of a file under a spaced folder → deny" deny $R "$PUSH"
fresh; echo v > a.txt; git commit -qam v; tierS
git clone -q $S/origin.git $S/other; (cd $S/other && echo w > w.txt && git add w.txt && git commit -qm w && git push -q origin main)
git pull -q --rebase origin main
expect "pull --rebase rewrote the tier-S commit → deny" deny $R "$PUSH"
fresh; git checkout -q -b fix; echo t > a.txt; git commit -qam t; tierS; git checkout -q main
expect "--branches pushes every branch (incl. unshipped S) → deny" deny $R "git push origin --branches"
git worktree add -q $S/wt fix
expect "S branch pushed from another checkout of the repo → deny" deny $S/wt "git push origin fix"
git worktree remove --force $S/wt

remote(){ (cd $S/other && git fetch -q origin && git reset -q --hard origin/main && eval "$1" && git push -q origin main); git fetch -q origin; }
nobranches(){ git checkout -q main; git for-each-ref --format='%(refname:short)' refs/heads | grep -vx main | while read b; do git branch -q -D "$b"; done; }
echo "-- tier S shipped some other way stops binding"
fresh; nobranches; git checkout -q -b s/x; echo sq > a.txt; echo sq > b.txt; git add .; git commit -qm sq1; echo sq2 > b.txt; git commit -qam sq2; tierS; evid
expect "push the S branch for a PR" allow $R "git push origin s/x"; git push -q origin s/x
remote "git merge -q --squash origin/s/x && git commit -qm 'squash PR'"
git checkout -q main; git pull -q --ff-only origin main; git branch -q -D s/x
echo sq3 > a.txt; git commit -qam sq3
expect "squash-merged S, later change to its files → allow" allow $R "$PUSH"
git reset -q --hard origin/main; echo sq4 > c.txt; git add c.txt; git commit -qm sq4
ok "squash-merged S doesn't block tier S for unrelated work" "$O tier --set S --repo $R"
fresh; echo z1 > a.txt; echo z1 > b.txt; git add .; git commit -qm z1; tierS
remote "echo z1 > a.txt && echo z1 > b.txt && git add -A && git commit -qm same && echo z2 > a.txt && git commit -qam later"
git checkout -q -b redo1 origin/main; echo z3 > a.txt; git commit -qam z3; git checkout -q main
expect "S content landed on origin then moved on → still shipped" allow $R "git push origin redo1"
fresh; echo y1 > a.txt; echo y1 > b.txt; git add .; git commit -qm y1; tierS
remote "echo y1 > a.txt && git commit -qam half"
git checkout -q -b redo2 origin/main; echo y3 > b.txt; git commit -qam y3; git checkout -q main
expect "only part of the S change on origin → still binds" deny $R "git push origin redo2"

echo "-- tier M/L: ship via a worker"
fresh; nobranches; git checkout -q -b s/m; echo mm > a.txt; git commit -qam mm; $O tier --set M --repo $R >/dev/null
git branch keep-m; git commit -q --amend -m mm2
expect "amended M change → deny" deny $R "git push origin s/m"
git checkout -q main; echo mu > b.txt; git add b.txt; git commit -qm mu
expect "M recorded, unrelated file → allow" allow $R "$PUSH"
remote "echo worker > a.txt && git commit -qam worker"; git pull -q --rebase origin main
echo mn > a.txt; git commit -qam mn
expect "origin touched M's files since → copies still bound" deny $R "$PUSH"
expect "the M commit itself never ships from here" deny $R "git push origin keep-m:main"
ok "--clear refused while a branch holds the M change" "! $O tier --clear --repo $R"
git branch -q -D keep-m
ok "--clear refused while main and s/m carry copies (unpushed, touch M files)" "! $O tier --clear --repo $R"
git branch -q -D s/m; git reset -q --hard origin/main
ok "--clear once nothing local carries the change" "$O tier --clear --repo $R"
echo mo > a.txt; git commit -qam mo
expect "after --clear, work on M's files pushes as today" allow $R "$PUSH"
ok "--set and --clear together refused" "! $O tier --set S --clear --repo $R"
ok "S work replaces an M record" "git checkout -q -b s/n main && echo sn > c.txt && git add c.txt && git commit -qm sn && $O tier --set M --repo $R && $O tier --set S --repo $R"
fresh; nobranches; echo ma > a.txt; echo ma > b.txt; git add .; git commit -qm ma; $O tier --set M --repo $R >/dev/null
remote "echo other > b.txt && git add -A && git commit -qm other"
git -c core.editor=true pull -q --rebase -X theirs origin main
expect "M on main, pull --rebase after an unrelated origin edit of one M file → deny" deny $R "$PUSH"
ok "--clear refused for the rebased M copy" "! $O tier --clear --repo $R"
fresh; nobranches; git checkout -q -b s/c; echo mc > a.txt; git commit -qam mc; $O tier --set M --repo $R >/dev/null
git checkout -q main; remote "echo worker2 > a.txt && git commit -qam worker2"; git pull -q --ff-only origin main
git cherry-pick -X theirs s/c >/dev/null 2>&1
expect "cherry-pick of the M change after the worker shipped → deny" deny $R "$PUSH"

echo "-- bare push sends HEAD, or every branch under matching / remote.*.push"
fresh; nobranches; git checkout -q -b fix; echo bp > a.txt; git commit -qam bp; tierS; git push -q origin fix:fix
git commit -q --amend -m bp2; git checkout -q main; echo bq > c.txt; git add c.txt; git commit -qm bq
expect "default push.default: bare push sends only HEAD → allow" allow $R "git push"
git config push.default matching
expect "matching: bare push would send amended S on fix → deny" deny $R "git push"
out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"git push origin"}}))' $R | python3 $H 2>&1)
echo "$out" > $S/bare.msg
ok "bare-push deny names the branch and the explicit-refspec fix" "grep -q refs/heads/fix $S/bare.msg && grep -q 'explicit refspec' $S/bare.msg"
expect "explicit main refspec unaffected" allow $R "$PUSH"
git config --unset push.default
expect "the ':' matching refspec checks every branch → deny" deny $R "git push origin :"
expect "':' alongside an explicit ref still checks every branch → deny" deny $R "git push origin main :"
git config remote.origin.push 'refs/heads/*:refs/heads/*'
expect "remote.origin.push configured: bare push checks every branch → deny" deny $R "git push origin"
git config --unset remote.origin.push
fresh; nobranches; echo bz > a.txt; git commit -qam bz; tierS; evid; git config push.default matching
expect "matching, tier S evidenced on HEAD, no other branch → allow" allow $R "git push"
git config --unset push.default

echo "-- merge-carried copies and non-ASCII paths stay bound"
fresh; nobranches; git checkout -q -b s/g; echo gg > a.txt; git commit -qam gg; X=$(git rev-parse HEAD); $O tier --set M --repo $R >/dev/null
git checkout -q -b side origin/main; echo sd > c.txt; git add c.txt; git commit -qm side
git checkout -q -b carrier origin/main; git merge -q --no-ff --no-commit side; git checkout $X -- a.txt; git commit -qm carrier
expect "copy of the M change carried only by a merge commit → deny" deny $R "git push origin carrier:main"
fresh; nobranches; echo n1 > a.txt; echo n1 > "é.txt"; git add .; git commit -qm n1; tierS
ok "tier file stores the non-ASCII path unquoted" "python3 -c 'import json;assert \"é.txt\" in json.load(open(\".git/orchestra-tier.json\"))[\"files\"]'"
remote "echo n1 > a.txt && git commit -qam half-ascii"
git checkout -q -b redo3 origin/main; echo n3 > "é.txt"; git add .; git commit -qm n3; git checkout -q main
expect "only the ASCII file landed; copy of the non-ASCII file → still bound" deny $R "git push origin redo3"

echo; echo "PASSED $P  FAILED $F"; [ $F = 0 ]
