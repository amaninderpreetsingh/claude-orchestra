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
for x in caffeinate xcrun osascript; do
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
ok "suite runs isolated: stubs first, own HOME/ORCH_HOME, env scrubbed" '[ $rc = 0 ] && grep -qE "^env.sh +10 +0  ok" <<< "$out"'
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

echo; echo "PASSED $P  FAILED $F"; [ $F = 0 ]
