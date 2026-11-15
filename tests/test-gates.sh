#!/usr/bin/env bash
# Tests for the repo's own gates: scripts/leak-check.sh, scripts/lint.sh, tests/run.sh.
# Every gate must fail on a planted error. Fake identifiers only (never real ones in this file).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-gates.XXXXXX"); trap 'rm -rf "$S"' EXIT
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1 :: rc=$rc out=[$out]"; fi; }
gitc(){ git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
newrepo(){ rm -rf "$S/r"; mkdir -p "$S/r"; git -C "$S/r" init -q; echo "# clean" > "$S/r/README.md"; }
commit(){ git -C "$S/r" add -A; gitc -C "$S/r" commit -qm "${1:-x}"; }

# ---------- leak-check (with a fixture pattern list of fake tokens) ----------
h(){ printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
cat > "$S/pat.txt" <<EOF
# fixture
word 7 $(h zorblax) fake-word
joined 8 $(h quuxbarn) fake-joined
EOF
LC(){ out=$(LEAK_PATTERNS="$S/pat.txt" bash "$ROOT/scripts/leak-check.sh" "$S/r" 2>&1); rc=$?; }
echo "-- leak-check"
newrepo; commit init; LC
ok "clean repo exits 0" '[ $rc = 0 ]'
echo "hello ZorbLax world" > "$S/r/a.md"; LC
ok "word token (any case) in new file exits 1" '[ $rc = 1 ]'
ok "hit printed as file:line with rule" 'grep -q "^a.md:1  fake-word" <<< "$out"'
ok "matched text is never printed" '! grep -qi zorblax <<< "$out"'
echo "x xzorblaxy z" > "$S/r/a.md"; LC
ok "word token inside a longer word" '[ $rc = 1 ]'
printf 'line\nthe Quux-Barn app\n' > "$S/r/a.md"; LC
ok "joined token across a hyphen" '[ $rc = 1 ] && grep -q "^a.md:2  fake-joined" <<< "$out"'
printf 'the quux barn app\n' > "$S/r/a.md"; LC
ok "joined token across a space" '[ $rc = 1 ]'
printf 'see github.com/plainhand/claude-orchestra\n' > "$S/r/a.md"; LC
ok "owner handle in a github URL is clean" '[ $rc = 0 ]'
printf 'see github.com/zorblax-other\n' > "$S/r/a.md"; LC
ok "other github handle is a hit" '[ $rc = 1 ]'
rm "$S/r/a.md"; echo x > "$S/r/zorblax-notes.md"; LC
ok "file name hit" '[ $rc = 1 ] && grep -q "zorblax-notes.md:0 (file name)" <<< "$out"'
rm "$S/r/zorblax-notes.md"
for t in "home /Use""rs/someone/x" "brew /opt/home""brew/bin/x" "mail a@gm""ail.com" "team AB12CD""EF3G"; do
  echo "${t#* }" > "$S/r/a.md"; LC; ok "generic rule: ${t%% *}" '[ $rc = 1 ]'; done
echo "SHA abcdef1234 and PERMISSION and C1 and ABCDEFGHIJ" > "$S/r/a.md"; LC
ok "no team-id false positive on words / lowercase hex" '[ $rc = 0 ]'
rm "$S/r/a.md"
echo "zorblax" > "$S/r/b.md"; commit add; git -C "$S/r" rm -q b.md; commit clean; LC
ok "token only in history is a hit" '[ $rc = 1 ] && grep -q "^history [0-9a-f]*:b.md:1  fake-word" <<< "$out"'
newrepo; commit "notes for Zorblax"; LC
ok "token in a commit message is a hit" '[ $rc = 1 ] && grep -q "(message)" <<< "$out"'
newrepo; LC
ok "repo without commits scans files only" '[ $rc = 0 ]'
as(){ n=$1 e=$2; shift 2; git -C "$S/r" add -A; git -C "$S/r" -c user.name="$n" -c user.email="$e" -c commit.gpgsign=false commit -q --allow-empty "$@"; }
newrepo; as plainhand 123+plainhand@users.noreply.github.com -m init; LC
ok "owner handle + its noreply email as author is clean" '[ $rc = 0 ]'
newrepo; as "Some One" 9+someone@users.noreply.github.com -m init; LC
ok "other noreply author is clean" '[ $rc = 0 ]'
newrepo; as "Some One" someone@laptop.local -m init; LC
ok "author with a real mailbox/host email is a hit" '[ $rc = 1 ] && grep -q "(author)" <<< "$out" && ! grep -q laptop <<< "$out"'
newrepo; as "Ann Zorblax" t@example.invalid -m init; LC
ok "token in author name is a hit" '[ $rc = 1 ] && grep -q "(author)" <<< "$out"'
newrepo; git -C "$S/r" add -A; GIT_COMMITTER_NAME=c GIT_COMMITTER_EMAIL=c@corp.co git -C "$S/r" -c user.name=t -c user.email=t@example.invalid commit -qm init; LC
ok "committer identity is checked too" '[ $rc = 1 ] && grep -q "(committer)" <<< "$out"'
newrepo; printf 'hi zorblax\n' | iconv -f UTF-8 -t UTF-16 > "$S/r/u16.txt"; LC
ok "UTF-16 file is scanned" '[ $rc = 1 ] && grep -q "u16.txt:0 (binary)" <<< "$out"'
newrepo; echo '*.dat -diff' > "$S/r/.gitattributes"; echo zorblax > "$S/r/x.dat"; commit add; rm "$S/r/x.dat"; commit rm; LC
ok "history hidden behind -diff attribute is scanned" '[ $rc = 1 ] && grep -q "x.dat:1" <<< "$out"'
newrepo; commit init; git -C "$S/r" checkout -qb side; echo s > "$S/r/s.txt"; commit side; git -C "$S/r" checkout -q main
echo m > "$S/r/m.txt"; commit main; gitc -C "$S/r" merge -q --no-commit side >/dev/null 2>&1; echo zorblax > "$S/r/evil.txt"; git -C "$S/r" add -A
gitc -C "$S/r" commit -qm merge; git -C "$S/r" rm -q evil.txt; commit clean; LC
ok "content added only in a merge commit is a hit" '[ $rc = 1 ] && grep -q "evil.txt:1" <<< "$out"'
newrepo; gitc -C "$S/r" commit -q --allow-empty -m "title" -m "diff --git a/x b/x" -m "zorblax"; LC
ok "message line that looks like a diff header doesn't hide the rest" '[ $rc = 1 ] && grep -q "(message)" <<< "$out"'
newrepo; printf '++zorblax\n' > "$S/r/p.txt"; commit add; rm "$S/r/p.txt"; commit rm; LC
ok "added line starting with ++ is scanned" '[ $rc = 1 ] && grep -q "p.txt:1" <<< "$out"'
newrepo; commit init; gitc -C "$S/r" tag -a v1 -m "zorblax release"; LC
ok "annotated tag message is scanned" '[ $rc = 1 ] && grep -q "^tag v1" <<< "$out"'
# GitHub-written identities and text (web merges, squash trailers, bots, PR test-merges)
GH="GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com"
newrepo; git -C "$S/r" add -A; env $GH git -C "$S/r" -c user.name=plainhand -c user.email=1+plainhand@users.noreply.github.com commit -qm init; LC
ok "committer GitHub <noreply@github.com> is clean" '[ $rc = 0 ]'
newrepo; as "x" x@noreply.github.com -m init; LC
ok "other mailbox at the noreply.github.com domain is a hit" '[ $rc = 1 ] && grep -q "(author)" <<< "$out"'
newrepo; as "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com" -m init; LC
ok "bot noreply identity is clean" '[ $rc = 0 ]'
newrepo; as plainhand 1+plainhand@users.noreply.github.com -m "Merge pull request #12 from plainhand/feature-x"; LC
ok "GitHub merge title with the owner handle is clean" '[ $rc = 0 ]'
newrepo; as plainhand 1+plainhand@users.noreply.github.com -m "Merge pull request #12 from zorblax-other/feature-x"; LC
ok "merge title from another handle with a token is a hit" '[ $rc = 1 ]'
newrepo; as t t@example.invalid -m "Squash" -m "Co-authored-by: plainhand <1+plainhand@users.noreply.github.com>"; LC
ok "Co-authored-by trailer with the owner noreply is clean" '[ $rc = 0 ]'
newrepo; as t t@example.invalid -m "Squash" -m "Co-authored-by: Some One <some.one@corp.co>"; LC
ok "Co-authored-by trailer with a real mailbox is a hit" '[ $rc = 1 ] && grep -q "(message)" <<< "$out" && ! grep -q corp <<< "$out"'
newrepo; as t t@example.invalid -m "Fix" -m "Signed-off-by: Ann Zorblax <t@example.invalid>"; LC
ok "Signed-off-by trailer with a token in the name is a hit" '[ $rc = 1 ]'
for msg in "Merge pull request #3 from plainhand/plainhand-patch-1" "Merge pull request #4 from plainhand/revert-3-plainhand-patch-1" \
           "Reverts plainhand/claude-orchestra#3" "Merge remote-tracking branch 'origin/plainhand-patch-1'"; do
  newrepo; as t t@example.invalid -m "$msg"; LC; ok "GitHub-written message form is clean: ${msg:0:24}" '[ $rc = 0 ]'; done
newrepo; as t t@example.invalid -m "Merge pull request #3 from plainhand/zorblax-patch-1"; LC
ok "listed token in a GitHub branch name is still a hit" '[ $rc = 1 ]'
newrepo; echo "see plainhand/claude-orchestra#3 and @plainhand" > "$S/r/a.md"; LC
ok "owner handle in any form in file content is clean" '[ $rc = 0 ]'
for u in "raw.githubusercontent.com/plainhand/r/main/x" "https://plainhand.github.io/r" "api.github.com/repos/plainhand/r"; do
  newrepo; echo "see $u" > "$S/r/a.md"; LC; ok "owner handle in GitHub URL form: ${u%%/*}" '[ $rc = 0 ]'; done
newrepo; commit init; git -C "$S/r" tag v0; LC
ok "lightweight tag (no tagger) is clean" '[ $rc = 0 ]'
newrepo; commit init; git -C "$S/r" -c user.name=t -c user.email=t@laptop.local tag -a v2 -m rel; LC
ok "annotated tag with a real tagger email is a hit" '[ $rc = 1 ] && grep -q "^tag v2:(tagger)" <<< "$out"'
newrepo; commit init; git -C "$S/r" -c user.name=plainhand -c user.email=1+plainhand@users.noreply.github.com tag -a v3 -m rel; LC
ok "annotated tag by the owner noreply tagger is clean" '[ $rc = 0 ]'
# PR test-merge: GitHub's synthetic merge commit (opener's account identity) is not the repo's history
newrepo; commit init; git -C "$S/r" checkout -qb pr; echo f > "$S/r/f.txt"; commit feature; PRHEAD=$(git -C "$S/r" rev-parse HEAD)
git -C "$S/r" checkout -q main; echo m > "$S/r/m.txt"; commit main
env $GH git -C "$S/r" -c user.name="Ann Zorblax" -c user.email=ann@corp.co merge -q --no-ff -m "Merge $PRHEAD into main" pr; LC
ok "synthetic PR merge identity is a hit without LEAK_REV" '[ $rc = 1 ]'
out=$(LEAK_REV=$PRHEAD LEAK_PATTERNS="$S/pat.txt" bash "$ROOT/scripts/leak-check.sh" "$S/r" 2>&1); rc=$?
ok "LEAK_REV=<PR head> scans the PR's own history, not GitHub's merge" '[ $rc = 0 ]'
echo zorblax > "$S/r/w.txt"; out=$(LEAK_REV=$PRHEAD LEAK_PATTERNS="$S/pat.txt" bash "$ROOT/scripts/leak-check.sh" "$S/r" 2>&1); rc=$?
ok "LEAK_REV still scans the working tree" '[ $rc = 1 ] && grep -q "^w.txt:1" <<< "$out"'
rm "$S/r/w.txt"; out=$(LEAK_REV=deadbeef LEAK_PATTERNS="$S/pat.txt" bash "$ROOT/scripts/leak-check.sh" "$S/r" 2>&1); rc=$?
ok "LEAK_REV that isn't a commit fails closed" '[ $rc = 2 ] && grep -q "not a commit" <<< "$out"'
newrepo; commit init; git -C "$S/r" checkout -qb rel; echo zorblax > "$S/r/t.txt"; commit rel; git -C "$S/r" tag v9
git -C "$S/r" checkout -q main; git -C "$S/r" branch -qD rel; LC
ok "commit reachable only from a tag is scanned" '[ $rc = 1 ] && grep -q "t.txt:1" <<< "$out"'

# ---------- lint ----------
LT(){ out=$(bash "$ROOT/scripts/lint.sh" "$S/r" 2>&1); rc=$?; }
echo "-- lint"
newrepo; printf '#!/usr/bin/env bash\necho ok\n' > "$S/r/a.sh"; printf 'x = 1\n' > "$S/r/a.py"; echo '{"a": 1}' > "$S/r/a.json"; commit init; LT
ok "clean repo exits 0" '[ $rc = 0 ]'
printf 'if then fi\n' > "$S/r/bad.sh"; LT
ok "bash syntax error in *.sh" '[ $rc = 1 ] && grep -q "FAIL bad.sh" <<< "$out"'; rm "$S/r/bad.sh"
printf '#!/usr/bin/env bash\nif then fi\n' > "$S/r/tool"; LT
ok "bash syntax error in extensionless script" '[ $rc = 1 ] && grep -q "FAIL tool" <<< "$out"'; rm "$S/r/tool"
printf 'def x(:\n' > "$S/r/bad.py"; LT
ok "python syntax error in *.py" '[ $rc = 1 ] && grep -q "FAIL bad.py" <<< "$out"'; rm "$S/r/bad.py"
printf '#!/usr/bin/env python3\ndef x(:\n' > "$S/r/pytool"; LT
ok "python syntax error in python-shebang script" '[ $rc = 1 ] && grep -q "FAIL pytool" <<< "$out"'; rm "$S/r/pytool"
echo '{"a": 1,}' > "$S/r/bad.json"; LT
ok "invalid JSON" '[ $rc = 1 ] && grep -q "FAIL bad.json" <<< "$out"'; rm "$S/r/bad.json"
mkdir -p "$S/r/__pycache__"; echo 'def x(:' > "$S/r/__pycache__/ign.py"; echo "__pycache__/" > "$S/r/.gitignore"; LT
ok "ignored files are skipped" '[ $rc = 0 ]'
mkdir -p "$S/nogit"; printf 'if then fi\n' > "$S/nogit/bad.sh"; out=$(GIT_CEILING_DIRECTORIES="$S" bash "$ROOT/scripts/lint.sh" "$S/nogit" 2>&1); rc=$?
ok "git ls-files failure exits non-zero" '[ $rc != 0 ] && grep -q "git ls-files failed" <<< "$out"'

# ---------- run.sh ----------
RS(){ out=$(bash "$ROOT/tests/run.sh" "$@" 2>&1); rc=$?; }
echo "-- run.sh"
mkdir -p "$S/suites"
printf '#!/usr/bin/env bash\necho "ok   a"; echo "ok   b"; exit 0\n' > "$S/suites/pass.sh"
printf '#!/usr/bin/env bash\necho "ok   a"; echo "FAIL b"; exit 1\n' > "$S/suites/fail.sh"
printf '#!/usr/bin/env bash\necho "ok   a"; exit 3\n' > "$S/suites/crash.sh"
cat > "$S/suites/env.sh" <<EOF
#!/usr/bin/env bash
[ "\$HOME" != "$HOME" ] && echo "ok   isolated HOME" || echo "FAIL HOME is the real one"
[ "\${ORCH_HOME:-}" = "\$(dirname "\$HOME")/orch" ] && [ -d "\$ORCH_HOME" ] && echo "ok   isolated ORCH_HOME" || echo "FAIL ORCH_HOME"
[ "\$(dirname "\$(command -v cmux)")" = "\$(dirname "\$HOME")/bin" ] && echo "ok   stub cmux first on PATH" || echo "FAIL real cmux reachable"
cmux new-workspace --name x >/dev/null 2>&1 && echo "FAIL stub cmux succeeded" || echo "ok   stub cmux exits non-zero"
[ "\$(git config user.email)" = test@example.invalid ] && echo "ok   throwaway git identity" || echo "FAIL git identity"
for x in caffeinate osascript; do
  [ "\$(command -v \$x)" = "\$(dirname "\$HOME")/bin/\$x" ] && \$x -is >/dev/null 2>&1 && echo "ok   stub \$x" || echo "FAIL real \$x reachable"; done
[ -z "\$(env | grep -E '^(CMUX|ORCH_PORT|CLAUDE)')" ] && echo "ok   CMUX/ORCH/CLAUDE env scrubbed" || echo "FAIL inherited env"
[ -z "\${GIT_DIR:-}\${GIT_CONFIG_GLOBAL:-}" ] && echo "ok   GIT_* env scrubbed" || echo "FAIL inherited GIT_*"
EOF
printf '#!/usr/bin/env bash\necho nothing ran\n' > "$S/suites/silent.sh"
RS "$S/suites/pass.sh"
ok "all suites pass → exit 0" '[ $rc = 0 ] && grep -qE "^pass.sh +2 +0  ok" <<< "$out"'
RS "$S/suites/pass.sh" "$S/suites/fail.sh"
ok "a failing suite → exit 1 with counts and its name" '[ $rc = 1 ] && grep -qE "^fail.sh +1 +1  FAILED" <<< "$out" && grep -q "failed: fail.sh" <<< "$out"'
ok "failing assertion is shown" 'grep -q "    FAIL b" <<< "$out"'
RS "$S/suites/crash.sh"
ok "non-zero exit without FAIL lines still fails" '[ $rc = 1 ] && grep -q "FAILED (exit 3)" <<< "$out"'
out=$(CMUX_SOCKET_PATH=/x/sock ORCH_PORT=1 CLAUDE_FAKE=1 GIT_DIR=/x/.git GIT_CONFIG_GLOBAL=/x/cfg bash "$ROOT/tests/run.sh" "$S/suites/env.sh" 2>&1); rc=$?
ok "suite runs isolated: stubs first, own HOME/ORCH_HOME, env scrubbed" '[ $rc = 0 ] && grep -qE "^env.sh +9 +0  ok" <<< "$out"'
RS "$S/suites/silent.sh"
ok "suite with no ok lines fails" '[ $rc = 1 ] && grep -q "FAILED (no ok lines)" <<< "$out"'
# ORCH_PYTHON: a fake interpreter (logs each call, then runs the real one) must serve python3 calls and shebangs
REALPY=$(python3 -c 'import sys; print(sys.executable)')
printf '#!/bin/sh\necho "$*" >> "%s/fakepy.log"\nexec "%s" "$@"\n' "$S" "$REALPY" > "$S/fakepy"; chmod +x "$S/fakepy"
printf '#!/usr/bin/env python3\nprint("ok   shebang script ran")\n' > "$S/pyscript"; chmod +x "$S/pyscript"
printf '#!/usr/bin/env bash\npython3 -c "print(\\"ok   python3 call\\")"\n"%s"\n' "$S/pyscript" > "$S/suites/py.sh"
rm -f "$S/fakepy.log"; out=$(ORCH_PYTHON="$S/fakepy" bash "$ROOT/tests/run.sh" "$S/suites/py.sh" 2>&1); rc=$?
ok "ORCH_PYTHON serves python3 calls and python3 shebangs" '[ $rc = 0 ] && grep -qE "^py.sh +2 +0  ok" <<< "$out" && grep -q "print(\"ok   python3 call\")" "$S/fakepy.log" && grep -q pyscript "$S/fakepy.log"'
ok "…and run.sh names the interpreter" 'grep -q "^run.sh: python3 = " <<< "$out"'
mkdir -p "$S/py \$dir \"q"; cp "$S/fakepy" "$S/py \$dir \"q/fakepy"; rm -f "$S/fakepy.log"
out=$(cd "$S" && ORCH_PYTHON='./py $dir "q/fakepy' bash "$ROOT/tests/run.sh" "$S/suites/py.sh" 2>&1); rc=$?
ok "a relative ORCH_PYTHON with a space, \$ and \" in its path works from every suite's own dir" '[ $rc = 0 ] && grep -qE "^py.sh +2 +0  ok" <<< "$out" && grep -q pyscript "$S/fakepy.log"'
mkdir -p "$S/mod"; echo 'X = 1' > "$S/mod/m.py"
printf '#!/usr/bin/env bash\npython3 -c "import sys; sys.path.insert(0, \\"%s\\"); import m; print(\\"ok   imported\\")"\n' "$S/mod" > "$S/suites/pyc.sh"
RS "$S/suites/pyc.sh"
ok "suites write no bytecode into the trees they import from" '[ $rc = 0 ] && [ ! -e "$S/mod/__pycache__" ]'
out=$(ORCH_PYTHON="$S/no-such-python" bash "$ROOT/tests/run.sh" "$S/suites/pass.sh" 2>&1); rc=$?
ok "a missing ORCH_PYTHON fails the run" '[ $rc = 1 ] && grep -q "ORCH_PYTHON=.*not found" <<< "$out"'
out=$(cd "$S" && bash "$ROOT/tests/run.sh" suites/pass.sh 2>&1); rc=$?
ok "relative suite path works" '[ $rc = 0 ] && grep -qE "^pass.sh +2 +0  ok" <<< "$out"'
RS "$S/suites/nope.sh"
ok "missing suite → exit 1" '[ $rc = 1 ] && grep -q "no such suite" <<< "$out"'
mkdir -p "$S/empty"; out=$(SUITES_DIR="$S/empty" EXTRA_SUITES_DIR="$S/empty" bash "$ROOT/tests/run.sh" 2>&1); rc=$?
ok "no suites found → exit 1" '[ $rc = 1 ]'
out=$(SUITES_DIR="$S/suites" EXTRA_SUITES_DIR="$S/empty" bash "$ROOT/tests/run.sh" 2>&1); rc=$?
ok "default discovery runs every suite in the dir" '[ $rc = 1 ] && grep -q "^TOTAL" <<< "$out" && [ $(grep -cE "^(pass|fail|crash|env|silent).sh " <<< "$out") = 5 ]'

echo "-- run.sh in parallel"
# meet <name> <n>: a suite that logs "start <name> <suites live now>", then waits (≤ 30s) until <n> suites have
# started and logs "end <name>". Only the load-proof direction is asserted: waiting can't make suites overlap
# less than a rendezvous proves, and a cap or a one-at-a-time order holds however slow the machine is.
meet(){ printf '#!/usr/bin/env bash\nmkdir "%s/live/%s"; echo "start %s $(ls "%s/live" | wc -l | tr -d " ")" >> "%s/span.log"; : > "%s/here/%s"\nfor i in $(seq 1 300); do [ "$(ls "%s/here" | wc -l)" -ge %s ] && break; sleep 0.1; done\n[ "$(ls "%s/here" | wc -l)" -ge %s ] && echo "ok   met" || echo "FAIL never met"\necho "end %s" >> "%s/span.log"; rmdir "%s/live/%s"\n' \
  "$S" "$1" "$1" "$S" "$S" "$S" "$1" "$S" "$2" "$S" "$2" "$1" "$S" "$S" "$1"; }
fresh(){ rm -rf "$S/live" "$S/here" "$S/span.log"; mkdir -p "$S/live" "$S/here"; }
maxlive(){ awk '/^start/{if($3>m)m=$3} END{print m+0}' "$S/span.log"; }
mkdir -p "$S/par" "$S/cap" "$S/one" "$S/solo"
for n in p1 p2 p3; do meet $n 3 > "$S/par/$n.sh"; meet $n 2 > "$S/cap/$n.sh"; meet $n 1 > "$S/one/$n.sh"; done
fresh; out=$(ORCH_TEST_JOBS=3 bash "$ROOT/tests/run.sh" "$S/par/p1.sh" "$S/par/p2.sh" "$S/par/p3.sh" 2>&1); rc=$?
ok "suites run at the same time (3 jobs: all three meet)" '[ $rc = 0 ] && grep -qE "^p3.sh +1 +0  ok" <<< "$out"'
fresh; out=$(ORCH_TEST_JOBS=2 bash "$ROOT/tests/run.sh" "$S/cap/p1.sh" "$S/cap/p2.sh" "$S/cap/p3.sh" 2>&1); rc=$?
ok "ORCH_TEST_JOBS caps how many run at once (2 meet, never 3 live)" '[ $rc = 0 ] && [ "$(maxlive)" = 2 ]'
fresh; out=$(ORCH_TEST_JOBS=1 bash "$ROOT/tests/run.sh" "$S/one/p1.sh" "$S/one/p2.sh" 2>&1); rc=$?
ok "ORCH_TEST_JOBS=1 runs them one at a time" '[ $rc = 0 ] && [ "$(maxlive)" = 1 ]'
for j in 0 x -2; do out=$(ORCH_TEST_JOBS=$j bash "$ROOT/tests/run.sh" "$S/suites/pass.sh" 2>&1); rc=$?
  ok "ORCH_TEST_JOBS=$j is refused" '[ $rc = 1 ] && grep -q "ORCH_TEST_JOBS must be a positive integer" <<< "$out"'; done
# timing-sensitive suites (by name) run after the rest, alone; parallel ones sorting after them prove the reorder
meet test-watch 1 > "$S/solo/test-watch.sh"; meet test-orch-reap-timing 1 > "$S/solo/test-orch-reap-timing.sh"; meet z1 2 > "$S/solo/z1.sh"; meet z2 2 > "$S/solo/z2.sh"
fresh; out=$(ORCH_TEST_JOBS=4 SUITES_DIR="$S/solo" EXTRA_SUITES_DIR="$S/empty" bash "$ROOT/tests/run.sh" 2>&1); rc=$?
ok "the parallel ones ran together (z1 and z2 met)" '[ $rc = 0 ] && grep -qE "^z1.sh +1 +0  ok" <<< "$out" && grep -qE "^z2.sh +1 +0  ok" <<< "$out"'
ok "timing-sensitive suites start only after the parallel ones ended" '[ "$(grep -n "start test-" "$S/span.log" | head -1 | cut -d: -f1)" -gt "$(grep -n "end z" "$S/span.log" | tail -1 | cut -d: -f1)" ]'
ok "...one at a time, alone" '[ "$(grep -cE "^start test-(orch-reap-timing|watch) 1$" "$S/span.log")" = 2 ]'
ok "the table keeps suite order, not finishing order" '[ "$(grep -oE "^(test-orch-reap-timing|test-watch|z1|z2)\.sh" <<< "$out" | tr "\n" " ")" = "test-orch-reap-timing.sh test-watch.sh z1.sh z2.sh " ]'
# failing suites printing at the same moments: each one's lines stay together under its own row
mkdir -p "$S/mix"; for n in m1 m2; do printf '#!/usr/bin/env bash\nfor i in 1 2 3 4; do echo "FAIL %s-$i"; sleep 0.1; done; exit 1\n' $n > "$S/mix/$n.sh"; done
out=$(ORCH_TEST_JOBS=2 bash "$ROOT/tests/run.sh" "$S/mix/m1.sh" "$S/mix/m2.sh" "$S/suites/pass.sh" 2>&1); rc=$?
ok "a failing suite fails a parallel run, with every suite reported" '[ $rc = 1 ] && grep -q "failed: m1.sh m2.sh$" <<< "$out" && grep -qE "^pass.sh +2 +0  ok" <<< "$out"'
ok "output isn't interleaved: each suite's lines are one block under its row" '[ "$(sed -n "/^m1.sh /,/^pass.sh /p" <<< "$out" | sed "s/^ *//" | cut -c1-7 | tr "\n" " ")" = "m1.sh   FAIL m1 FAIL m1 FAIL m1 FAIL m1 m2.sh   FAIL m2 FAIL m2 FAIL m2 FAIL m2 pass.sh " ]'
cp "$S/suites/pass.sh" "$S/mix/pass.sh"
out=$(ORCH_TEST_JOBS=2 bash "$ROOT/tests/run.sh" "$S/suites/pass.sh" "$S/mix/pass.sh" "$S/suites/fail.sh" 2>&1); rc=$?
ok "two suites with one name get their own boxes" '[ $rc = 1 ] && [ $(grep -cE "^pass.sh +2 +0  ok" <<< "$out") = 2 ] && grep -qE "^fail.sh +1 +1  FAILED" <<< "$out"'
# interrupted: every running suite's whole process tree is stopped (helpers in their own session too, and a
# suite that ignores TERM is KILLed after a grace period), and the run says which suites were running
printf '#!/usr/bin/env bash\nsleep 60 & echo $! > "%s/kid.a"\nperl -MPOSIX -e '"'"'POSIX::setsid(); exec "sleep", "60"'"'"' & echo $! > "%s/kid.c"\necho "ok   started a"; wait\n' "$S" "$S" > "$S/mix/hang-a.sh"
printf '#!/usr/bin/env bash\ntrap "" TERM; sleep 60 & echo $! > "%s/kid.b"; echo "ok   started b"; wait\n' "$S" > "$S/mix/hang-b.sh"
gone(){ for i in $(seq 1 50); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
rm -f "$S"/kid.*; ORCH_TEST_JOBS=2 bash "$ROOT/tests/run.sh" "$S/mix/hang-a.sh" "$S/mix/hang-b.sh" > "$S/int.out" 2>&1 & RP=$!
for i in $(seq 1 100); do [ -s "$S/kid.a" ] && [ -s "$S/kid.b" ] && [ -s "$S/kid.c" ] && break; sleep 0.1; done
kill -TERM $RP; for i in $(seq 1 300); do kill -0 $RP 2>/dev/null || break; sleep 0.1; done
kill -0 $RP 2>/dev/null && { kill -KILL $RP; rc=hung; } || { wait $RP; rc=$?; }
ok "TERM stops the run (exit 130) and every running suite's children" '[ $rc = 130 ] && [ -s "$S/kid.a" ] && gone "$(cat "$S/kid.a")"'
ok "...a helper the suite put in its own session too" '[ -s "$S/kid.c" ] && gone "$(cat "$S/kid.c")"'
ok "...and a suite that ignores TERM (KILLed after the grace period)" '[ -s "$S/kid.b" ] && gone "$(cat "$S/kid.b")"'
ok "...naming each suite it stopped, with its last lines" 'out=$(cat "$S/int.out"); grep -q "interrupted while running hang-a.sh" <<< "$out" && grep -q "interrupted while running hang-b.sh" <<< "$out" && grep -q "    ok   started a" <<< "$out"'
for k in a b c; do kill -KILL "$(cat "$S/kid.$k" 2>/dev/null)" 2>/dev/null; done
# bash starts background jobs with INT/QUIT ignored; suites must get them back as in a foreground run
printf '#!/usr/bin/env bash\npython3 -c "import signal,sys; sys.exit(0 if signal.getsignal(signal.SIGINT) is signal.default_int_handler and signal.getsignal(signal.SIGQUIT) == signal.SIG_DFL else 1)" && echo "ok   INT/QUIT default" || echo "FAIL INT/QUIT ignored"\n' > "$S/mix/sig.sh"
out=$(bash "$ROOT/tests/run.sh" "$S/mix/sig.sh" 2>&1); rc=$?
ok "suites start with INT and QUIT at their defaults, not ignored" '[ $rc = 0 ] && grep -qE "^sig.sh +1 +0  ok" <<< "$out"'

echo "-- run.sh port blocks"
# portsuite <name> <n>: records its ORCH_TEST_PORT_BASE, then waits (≤ 30s) until <n> suites have recorded theirs,
# so every block is held at once when they are compared
portsuite(){ printf '#!/usr/bin/env bash\necho "${ORCH_TEST_PORT_BASE:-none}" > "%s/pb/%s"\nfor i in $(seq 1 300); do [ "$(ls "%s/pb" | wc -l)" -ge %s ] && break; sleep 0.1; done\necho "ok   %s"\n' "$S" "$1" "$S" "$2" "$1"; }
mkdir -p "$S/ps" "$S/locks"; for n in q1 q2 q3 q4; do portsuite $n 4 > "$S/ps/$n.sh"; done
blocks(){ cat "$S"/pb/* | sort; }
distinct(){ [ "$(blocks | sort -u | wc -l)" -eq "$1" ] && ! blocks | grep -qvE '^(3[0-9]|4[0-8])[0-9]00$|^49000$'; }
rm -rf "$S/pb"; mkdir -p "$S/pb"
out=$(PORT_LOCKS_DIR="$S/locks" ORCH_TEST_JOBS=4 bash "$ROOT/tests/run.sh" "$S/ps/q1.sh" "$S/ps/q2.sh" "$S/ps/q3.sh" "$S/ps/q4.sh" 2>&1); rc=$?
ok "each suite gets its own 100-port block (ORCH_TEST_PORT_BASE)" '[ $rc = 0 ] && distinct 4'
ok "...released when the run ends" '[ -z "$(ls "$S/locks")" ]'
rm -rf "$S/pb"; mkdir -p "$S/pb"
PORT_LOCKS_DIR="$S/locks" ORCH_TEST_JOBS=2 bash "$ROOT/tests/run.sh" "$S/ps/q1.sh" "$S/ps/q2.sh" > "$S/c1.out" 2>&1 & C1=$!
PORT_LOCKS_DIR="$S/locks" ORCH_TEST_JOBS=2 bash "$ROOT/tests/run.sh" "$S/ps/q3.sh" "$S/ps/q4.sh" > "$S/c2.out" 2>&1 & C2=$!
wait $C1; r1=$?; wait $C2; r2=$?
ok "two run.sh copies at once never hand out the same block" '[ $r1 = 0 ] && [ $r2 = 0 ] && distinct 4'
rm -rf "$S/pb"; mkdir -p "$S/pb"; portsuite q1 1 > "$S/ps/solo-q.sh"
mkdir -p "$S/locks/30000" "$S/locks/30100"; echo 99999999 > "$S/locks/30000/pid"; echo $$ > "$S/locks/30100/pid"
out=$(PORT_LOCKS_DIR="$S/locks" bash "$ROOT/tests/run.sh" "$S/ps/solo-q.sh" 2>&1); rc=$?
ok "a block whose owner is gone is taken over" '[ $rc = 0 ] && [ "$(cat "$S/pb/q1")" = 30000 ]'
ok "...a live owner's block is left alone" '[ "$(cat "$S/locks/30100/pid")" = $$ ] && [ ! -e "$S/locks/30000" ]'
rm -rf "$S/pb"; mkdir -p "$S/pb"; mkdir -p "$S/locks/30000" "$S/locks/30200"; touch -t 202001010000 "$S/locks/30000"   # no pid: old / fresh
out=$(PORT_LOCKS_DIR="$S/locks" bash "$ROOT/tests/run.sh" "$S/ps/solo-q.sh" 2>&1); rc=$?
ok "a lock left without a pid is taken over once it is a minute old" '[ $rc = 0 ] && [ "$(cat "$S/pb/q1")" = 30000 ]'
ok "...a fresh one without a pid is left alone (its taker is still writing it)" '[ -d "$S/locks/30200" ] && [ ! -e "$S/locks/30200/pid" ]'
rm -rf "$S/locks" "$S/pb"; mkdir -p "$S/locks" "$S/pb"
printf '#!/usr/bin/env bash\necho %s > "%s/locks/$ORCH_TEST_PORT_BASE/pid"; echo "$ORCH_TEST_PORT_BASE" > "%s/pb/r"; echo "ok   handed over"\n' $$ "$S" "$S" > "$S/ps/handover.sh"
out=$(PORT_LOCKS_DIR="$S/locks" bash "$ROOT/tests/run.sh" "$S/ps/handover.sh" 2>&1); rc=$?
ok "at exit a run removes only the locks it still owns" '[ $rc = 0 ] && [ "$(cat "$S/locks/$(cat "$S/pb/r")/pid")" = $$ ]'
mkdir -p "$S/locks/30000"; echo 99999999 > "$S/locks/30000/pid"; mkdir "$S/locks/.take.30000"; rm -f "$S/pb/q1"
out=$(PORT_LOCKS_DIR="$S/locks" bash "$ROOT/tests/run.sh" "$S/ps/solo-q.sh" 2>&1); rc=$?
ok "a stale block another run is taking over is skipped" '[ $rc = 0 ] && [ "$(cat "$S/pb/q1")" != 30000 ] && [ "$(cat "$S/locks/30000/pid")" = 99999999 ]'
touch -t 202001010000 "$S/locks/.take.30000"; rm -f "$S/pb/q1"   # its taker died mid-takeover
out=$(PORT_LOCKS_DIR="$S/locks" bash "$ROOT/tests/run.sh" "$S/ps/solo-q.sh" 2>&1); rc=$?
ok "...unless that takeover was left behind a minute ago" '[ $rc = 0 ] && [ "$(cat "$S/pb/q1")" = 30000 ] && [ ! -e "$S/locks/.take.30000" ]'
rm -rf "$S/locks"; mkdir -p "$S/locks"; for ((b = 30000; b <= 49000; b += 100)); do mkdir "$S/locks/$b"; echo $$ > "$S/locks/$b/pid"; done; rm -f "$S/pb/q1"
out=$(PORT_LOCKS_DIR="$S/locks" bash "$ROOT/tests/run.sh" "$S/ps/solo-q.sh" 2>&1); rc=$?
ok "blocks end below the ephemeral ports (49152): none free → the suite gets none" '[ $rc = 0 ] && [ "$(cat "$S/pb/q1")" = none ] && [ ! -e "$S/locks/49100" ]'
ok "...and the run says so" 'grep -q "no free port block under $S/locks" <<< "$out"'
rm -rf "$S/locks"
# a kill sent to run.sh's whole process group (Ctrl-C, a harness timeout's SIGKILL) reaches every suite
printf '#!/usr/bin/env bash\nsleep 60 & echo $! > "%s/kid.g"; echo "ok   started"; wait\n' "$S" > "$S/mix/grp.sh"
rm -f "$S/kid.g"; mkdir -p "$S/locks"; PORT_LOCKS_DIR="$S/locks" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$ROOT/tests/run.sh" "$S/mix/grp.sh" > /dev/null 2>&1 & GP=$!
for i in $(seq 1 100); do [ -s "$S/kid.g" ] && break; sleep 0.1; done
kill -KILL -- -$GP 2>/dev/null; wait $GP 2>/dev/null
ok "SIGKILL to run.sh's process group kills the suites too (no orphans)" '[ -s "$S/kid.g" ] && gone "$(cat "$S/kid.g")"'
kill -KILL "$(cat "$S/kid.g" 2>/dev/null)" 2>/dev/null

echo; echo "PASSED $P  FAILED $F"; [ $F = 0 ]
