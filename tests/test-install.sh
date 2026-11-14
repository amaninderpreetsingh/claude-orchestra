#!/usr/bin/env bash
# Tests for install.sh / uninstall.sh (and make-demo-repo --no-launch), always in a fake HOME.
# Stubs (cmux, gh, gitleaks, claude, npx) live in this suite's own bin dir and log their calls;
# the real ~/.claude, cmux, claude and npx are never reached.
set -u
unset ZDOTDIR  # the installer would otherwise write a zsh PATH line into the real $ZDOTDIR/.zshrc
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-test-install.XXXXXX"); trap 'rm -rf "$S"' EXIT
P=0; F=0; rc=0; out=""
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1 :: rc=$rc out=[$(tail -5 <<< "$out")]"; fi; }

mkdir -p "$S/bin"
for x in cmux gh gitleaks claude npx; do
  printf '#!/bin/sh\necho "$*" >> "%s/%s.log"\nexit 0\n' "$S" "$x" > "$S/bin/$x"; done
chmod +x "$S/bin/"*
# snapshot of a tree: every file path + content hash (and mode), so "unchanged" means byte-identical
snap(){ ( cd "$1" 2>/dev/null && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s %s %s\n' "$f" "$(stat -f %Lp "$f")" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done ); }
newhome(){  # $1 = home dir; an existing ~/.claude with the user's own CLAUDE.md, settings and one clashing agent
  rm -rf "$1"; mkdir -p "$1/.claude/agents"
  printf '# my own rules\n- be nice\n' > "$1/.claude/CLAUDE.md"
  cat > "$1/.claude/settings.json" <<'EOF'
{
    "model": "my-model",
    "permissions": {"allow": ["Bash(ls *)"], "deny": ["Bash(git push -f *)"]},
    "hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "echo mine"}]}]}
}
EOF
  printf 'my reviewer\n' > "$1/.claude/agents/reviewer.md"; }
INST(){ out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$ROOT/install.sh" "$@" < /dev/null 2>&1); rc=$?; }
UNINST(){ out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$ROOT/uninstall.sh" "$@" < /dev/null 2>&1); rc=$?; }
J(){ python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$H/.claude/settings.json" "$1"; }
H=""; C=""

echo "-- cmux missing: explain, exit 1, write nothing"
H="$S/h0"; newhome "$H"; before=$(snap "$H")
out=$(cd "$S" && HOME="$H" ORCH_CMUX="$S/none/cmux" PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --yes --no-web --skip-tests < /dev/null 2>&1); rc=$?
ok "exits 1" '[ $rc = 1 ]'
ok "explains how to install cmux" 'grep -q "brew install --cask cmux" <<< "$out"'
ok "nothing written under HOME" '[ "$(snap "$H")" = "$before" ]'

echo "-- push-guard.py doesn't load with the found python3: explain, exit 1, write nothing"
mkdir -p "$S/srcpy"; for f in install.sh uninstall.sh settings.example.json CLAUDE.template.md skills agents orchestra statusline; do cp -R "$ROOT/$f" "$S/srcpy/"; done
python3 - "$S/srcpy/orchestra/hooks/push-guard.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); a = "\nimport codecs, re,"
assert a in s
open(p, "w").write(s.replace(a, '\nraise SyntaxError("needs a newer Python")' + a, 1))  # as (?>…) failed on 3.9
PY
H="$S/hpy"; newhome "$H"; before=$(snap "$H")
out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$S/srcpy/install.sh" --yes --no-web --skip-tests < /dev/null 2>&1); rc=$?
ok "exits 1" '[ $rc = 1 ]'
ok "says push-guard.py fails to load with that python3" 'grep -q "push-guard.py fails to load" <<< "$out" && grep -q "needs a newer Python" <<< "$out"'
ok "nothing written under HOME" '[ "$(snap "$H")" = "$before" ]'

echo "-- invalid settings.json: exit 1, write nothing"
H="$S/h0b"; newhome "$H"; echo '{ nope' > "$H/.claude/settings.json"; before=$(snap "$H")
INST --yes --no-web --skip-tests
ok "exits 1" '[ $rc = 1 ] && grep -qi "settings.json" <<< "$out"'
ok "nothing written under HOME" '[ "$(snap "$H")" = "$before" ]'

echo "-- first install over an existing ~/.claude"
H="$S/h1"; C="$H/.claude"; newhome "$H"
cp "$C/CLAUDE.md" "$S/orig-claude.md"; cp "$C/settings.json" "$S/orig-settings.json"
INST --yes --no-web --skip-tests
ok "exits 0" '[ $rc = 0 ]'
for dep in cmux python3 git gh gitleaks Playwright context7 Maestro xcbeautify; do
  ok "dependency table lists $dep" 'grep -E "^ *$dep" <<< "$out" | grep -qE "found|missing|optional|required"'; done
ok "skills/agents/orchestra/statusline copied" 'cmp -s "$ROOT/skills/worker/SKILL.md" "$C/skills/worker/SKILL.md" && cmp -s "$ROOT/agents/verifier.md" "$C/agents/verifier.md" && cmp -s "$ROOT/orchestra/hooks/push-guard.py" "$C/orchestra/hooks/push-guard.py" && cmp -s "$ROOT/statusline/statusline.py" "$C/statusline/statusline.py"'
ok "orch is executable" '[ -x "$C/orchestra/bin/orch" ]'
ok "repo-only files not copied" '[ ! -e "$C/install.sh" ] && [ ! -e "$C/scripts" ] && [ ! -e "$C/tests" ]'
BK=$(ls -d "$C"/backups/claude-orchestra-* 2>/dev/null | head -1)
ok "one backup dir" '[ "$(ls -d "$C"/backups/claude-orchestra-* | wc -l | tr -d " ")" = 1 ]'
ok "replaced agent backed up" '[ "$(cat "$BK/agents/reviewer.md")" = "my reviewer" ]'
ok "settings.json + CLAUDE.md backed up" 'cmp -s "$BK/settings.json" "$S/orig-settings.json" && cmp -s "$BK/CLAUDE.md" "$S/orig-claude.md"'
ok "CLAUDE.md keeps the user's text first" '[ "$(head -2 "$C/CLAUDE.md")" = "$(cat "$S/orig-claude.md")" ]'
ok "CLAUDE.md has one marked block" '[ "$(grep -c "^<!-- claude-orchestra:start -->$" "$C/CLAUDE.md")" = 1 ] && [ "$(grep -c "^<!-- claude-orchestra:end -->$" "$C/CLAUDE.md")" = 1 ]'
ok "block holds the template" 'grep -qF "$(sed -n 3p "$ROOT/CLAUDE.template.md")" "$C/CLAUDE.md"'
ok "user settings kept" '[ "$(J "\"|\".join([d[\"model\"]] + d[\"permissions\"][\"allow\"] + [d[\"hooks\"][\"PostToolUse\"][0][\"hooks\"][0][\"command\"]])")" = "my-model|Bash(ls *)|echo mine" ]'
ok "push-guard hook merged, HOME-relative" '[ "$(J "\"|\".join(h[\"command\"] for e in d[\"hooks\"][\"PreToolUse\"] if e[\"matcher\"]==\"Bash\" for h in e[\"hooks\"])")" = "python3 \"\$HOME/.claude/orchestra/hooks/push-guard.py\"" ]'
ok "statusline merged" 'J "d[\"statusLine\"][\"command\"]" | grep -qF "\$HOME/.claude/statusline/statusline.py"'
ok "deny rules merged without duplicates" '[ "$(J "d[\"permissions\"][\"deny\"].count(\"Bash(git push -f *)\"), \"Bash(git push --force *)\" in d[\"permissions\"][\"deny\"], \"Bash(rm -rf /)\" in d[\"permissions\"][\"deny\"]")" = "(1, True, True)" ]'
ok "no settings key outside hooks/statusLine/permissions added" '[ "$(J "\" \".join(sorted(d))")" = "hooks model permissions statusLine" ]'
ok "prints the PATH line" 'grep -qF "export PATH=\"\$HOME/.claude/orchestra/bin:\$PATH\"" <<< "$out"'
ok "shell rc untouched without consent" '[ ! -e "$H/.zshrc" ] && [ ! -e "$H/.bash_profile" ] && [ ! -e "$H/.bashrc" ]'
ok "web skipped: no claude/npx calls" '[ ! -e "$S/claude.log" ] && [ ! -e "$S/npx.log" ]'

echo "-- second run is byte-identical"
s1=$(snap "$H"); INST --yes --no-web --skip-tests
ok "exits 0" '[ $rc = 0 ]'
ok "nothing under HOME changed (no new backup)" '[ "$(snap "$H")" = "$s1" ]'

echo "-- rerun replaces an edited marked block, never duplicates it"
python3 - "$C/CLAUDE.md" <<'PY'
import sys; p = sys.argv[1]; t = open(p).read()
a = t.index("<!-- claude-orchestra:start -->"); b = t.index("<!-- claude-orchestra:end -->")
open(p, "w").write(t[:a] + "<!-- claude-orchestra:start -->\nOLD RULES\n" + t[b:] + "# my later note\n")
PY
INST --yes --no-web --skip-tests
ok "block content back to the template" '! grep -q "OLD RULES" "$C/CLAUDE.md" && grep -qF "$(sed -n 3p "$ROOT/CLAUDE.template.md")" "$C/CLAUDE.md"'
ok "still one block; text after it kept" '[ "$(grep -c "claude-orchestra:start" "$C/CLAUDE.md")" = 1 ] && [ "$(tail -1 "$C/CLAUDE.md")" = "# my later note" ]'
python3 - "$C/CLAUDE.md" <<'PY'
import sys; p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("# my later note\n", ""))
PY

echo "-- uninstall restores"
mkdir -p "$C/orchestra/runs/r1"; echo keep > "$C/orchestra/runs/r1/notes.md"
UNINST --yes
ok "exits 0" '[ $rc = 0 ]'
ok "CLAUDE.md byte-identical to the original" 'cmp -s "$C/CLAUDE.md" "$S/orig-claude.md"'
ok "settings.json equal to the original" 'python3 -c "import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))" "$C/settings.json" "$S/orig-settings.json"'
ok "replaced agent restored from backup" '[ "$(cat "$C/agents/reviewer.md")" = "my reviewer" ]'
ok "copied files removed" '[ ! -e "$C/skills/worker/SKILL.md" ] && [ ! -e "$C/orchestra/bin/orch" ] && [ ! -e "$C/statusline/statusline.py" ] && [ ! -e "$C/agents/verifier.md" ]'
ok "run state kept" '[ "$(cat "$C/orchestra/runs/r1/notes.md")" = keep ]'
ok "backups kept" '[ -f "$BK/agents/reviewer.md" ]'

echo "-- fresh HOME (no ~/.claude), interactive answers"
H="$S/h2"; C="$H/.claude"; rm -rf "$H"; mkdir -p "$H"
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" SHELL=/bin/zsh PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1); rc=$?
ok "exits 0" '[ $rc = 0 ]'
ok "web answer n: no claude/npx calls" '[ ! -e "$S/claude.log" ] && [ ! -e "$S/npx.log" ]'
ok "CLAUDE.md answer n: no CLAUDE.md" '[ ! -e "$C/CLAUDE.md" ]'
ok "settings.json created" '[ "$(J "\" \".join(sorted(d))")" = "hooks permissions statusLine" ]'
ok "PATH answer y: one line in .zshrc" '[ "$(grep -c "orchestra/bin" "$H/.zshrc")" = 1 ]'
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" SHELL=/bin/zsh PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1); rc=$?
ok "rerun: still one PATH line" '[ $rc = 0 ] && [ "$(grep -c "orchestra/bin" "$H/.zshrc")" = 1 ]'
UNINST --yes
ok "uninstall: settings.json, .zshrc line and copies gone" '[ $rc = 0 ] && [ ! -e "$C/settings.json" ] && ! grep -q "orchestra/bin" "$H/.zshrc" && [ ! -e "$C/skills" ]'

echo "-- existing statusLine is kept"
H="$S/h3"; C="$H/.claude"; newhome "$H"
python3 - "$C/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["statusLine"] = {"type": "command", "command": "my-line"}
json.dump(d, open(p, "w"))
PY
INST --yes --no-web --skip-tests
ok "user's statusLine untouched" '[ $rc = 0 ] && [ "$(J "d[\"statusLine\"][\"command\"]")" = my-line ] && grep -qi "statusline" <<< "$out"'
UNINST --yes
ok "uninstall keeps the user's statusLine" '[ "$(J "d[\"statusLine\"][\"command\"]")" = my-line ]'

echo "-- --web sets up Playwright MCP (npx form) unless present"
H="$S/h4"; C="$H/.claude"; newhome "$H"; rm -f "$S/claude.log" "$S/npx.log"
INST --yes --web --skip-tests
ok "exits 0" '[ $rc = 0 ]'
ok "claude mcp add playwright, user scope, npx form" 'grep -qE "^mcp add (-s|--scope) user playwright -- npx -y @playwright/mcp@latest" "$S/claude.log"'
ok "no absolute path in the mcp command" '! grep -q "/" <<< "$(sed "s#@playwright/mcp##" "$S/claude.log")"'
ok "browsers installed via npx" 'grep -qE "playwright(@[^ ]+)? install chromium" "$S/npx.log"'
ok "worker-mcp.json has playwright via npx" '[ "$(python3 -c "import json,sys; s=json.load(open(sys.argv[1]))[\"mcpServers\"][\"playwright\"]; print(s[\"command\"], *s[\"args\"][:2])" "$C/orchestra/worker-mcp.json")" = "npx -y @playwright/mcp@latest" ]'
printf '{"mcpServers": {"playwright": {"type": "stdio", "command": "npx", "args": []}}}\n' > "$H/.claude.json"
rm -f "$S/claude.log"; INST --yes --web --skip-tests
ok "already present: no second mcp add" '[ $rc = 0 ] && ! grep -q "mcp add" "$S/claude.log" 2>/dev/null'
rm -f "$S/claude.log" "$S/npx.log"

echo "-- install runs the test suite unless --skip-tests"
H="$S/h5"; C="$H/.claude"; rm -rf "$H"; mkdir -p "$H"
mkdir -p "$S/src4"; for f in install.sh uninstall.sh settings.example.json CLAUDE.template.md skills agents orchestra statusline tests; do cp -R "$ROOT/$f" "$S/src4/"; done
printf '#!/usr/bin/env bash\necho selftest-ran\n' > "$S/src4/tests/run.sh"
out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$S/src4/install.sh" --yes --no-web < /dev/null 2>&1); rc=$?
ok "runs tests/run.sh step" '[ $rc = 0 ] && grep -q selftest-ran <<< "$out"'
printf '#!/usr/bin/env bash\nexit 1\n' > "$S/src4/tests/run.sh"
out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$S/src4/install.sh" --yes --no-web < /dev/null 2>&1); rc=$?
ok "failing self-test → exit non-zero" '[ $rc != 0 ]'

echo "-- settings.json of the wrong shape: exit 1, write nothing"
for bad in '[]' '{"hooks": []}' '{"permissions": {"deny": "x"}}' '{"hooks": {"PreToolUse": {}}}' '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": ["oops"]}]}}'; do
  H="$S/hbad"; newhome "$H"; printf '%s\n' "$bad" > "$H/.claude/settings.json"; before=$(snap "$H")
  INST --yes --no-web --skip-tests
  ok "rejects $bad" '[ $rc = 1 ] && [ "$(snap "$H")" = "$before" ]'
done

ok "names the bad key path" 'grep -qF "hooks.PreToolUse[0].hooks[0]" <<< "$out"'

echo "-- broken CLAUDE.md markers: exit 1, write nothing"
H="$S/hmark"; newhome "$H"; printf '# mine\n<!-- claude-orchestra:start -->\nbroken\nUSER TEXT\n' > "$H/.claude/CLAUDE.md"; before=$(snap "$H")
INST --yes --no-web --skip-tests
ok "start marker without end is refused" '[ $rc = 1 ] && grep -q "marker" <<< "$out" && [ "$(snap "$H")" = "$before" ]'

echo "-- symlinked files are backed up and restored as symlinks"
H="$S/hlink"; C="$H/.claude"; newhome "$H"; mkdir -p "$S/dotfiles"; echo "dotfile reviewer" > "$S/dotfiles/rev.md"
rm "$C/agents/reviewer.md"; ln -s "$S/dotfiles/rev.md" "$C/agents/reviewer.md"; ln -s "$S/nowhere/v.md" "$C/agents/verifier.md"
INST --yes --no-web --skip-tests
BK=$(ls -d "$C"/backups/claude-orchestra-* | head -1)
ok "install ok with a live and a dangling link" '[ $rc = 0 ] && cmp -s "$ROOT/agents/reviewer.md" "$C/agents/reviewer.md" && [ ! -L "$C/agents/reviewer.md" ]'
ok "backups are the links themselves" '[ "$(readlink "$BK/agents/reviewer.md")" = "$S/dotfiles/rev.md" ] && [ "$(readlink "$BK/agents/verifier.md")" = "$S/nowhere/v.md" ]'
ok "link target untouched" '[ "$(cat "$S/dotfiles/rev.md")" = "dotfile reviewer" ]'
UNINST --yes
ok "uninstall restores both links" '[ $rc = 0 ] && [ "$(readlink "$C/agents/reviewer.md")" = "$S/dotfiles/rev.md" ] && [ "$(readlink "$C/agents/verifier.md")" = "$S/nowhere/v.md" ]'

echo "-- symlinked settings.json / CLAUDE.md: backups hold the original bytes"
H="$S/hdot"; C="$H/.claude"; newhome "$H"; mkdir -p "$S/dot"
mv "$C/settings.json" "$S/dot/settings.json"; mv "$C/CLAUDE.md" "$S/dot/CLAUDE.md"
cp "$S/dot/settings.json" "$S/dot-settings.orig"; cp "$S/dot/CLAUDE.md" "$S/dot-claude.orig"
ln -s "$S/dot/settings.json" "$C/settings.json"; ln -s "$S/dot/CLAUDE.md" "$C/CLAUDE.md"
INST --yes --no-web --skip-tests
BK=$(ls -d "$C"/backups/claude-orchestra-* | head -1)
ok "backups are regular files with the original content" '[ $rc = 0 ] && [ ! -L "$BK/settings.json" ] && [ ! -L "$BK/CLAUDE.md" ] && cmp -s "$BK/settings.json" "$S/dot-settings.orig" && cmp -s "$BK/CLAUDE.md" "$S/dot-claude.orig"'
ok "links kept, targets merged" '[ -L "$C/settings.json" ] && [ -L "$C/CLAUDE.md" ] && grep -q push-guard "$S/dot/settings.json" && grep -q "claude-orchestra:start" "$S/dot/CLAUDE.md"'

echo "-- bash user with only ~/.profile: the PATH line goes there"
H="$S/hbash"; rm -rf "$H"; mkdir -p "$H"; echo "export FOO=1" > "$H/.profile"
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" SHELL=/bin/bash PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1); rc=$?
ok "no ~/.bash_profile created" '[ $rc = 0 ] && [ ! -e "$H/.bash_profile" ] && grep -q "orchestra/bin" "$H/.profile" && grep -q "FOO=1" "$H/.profile"'

echo "-- upgrade: rerun from a newer version drops what it no longer ships"
H="$S/hup"; C="$H/.claude"; newhome "$H"; INST --yes --no-web --skip-tests
mkdir -p "$S/src2"; for f in install.sh uninstall.sh settings.example.json CLAUDE.template.md skills agents orchestra statusline; do cp -R "$ROOT/$f" "$S/src2/"; done
rm "$S/src2/skills/retro/SKILL.md"
python3 - "$S/src2/settings.example.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = 'python3 "$HOME/.claude/orchestra/hooks/guard-v2.py"'
d["permissions"]["deny"].remove("Bash(rm -rf ~)"); json.dump(d, open(p, "w"), indent=2)
PY
out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$S/src2/install.sh" --yes --no-web --skip-tests < /dev/null 2>&1); rc=$?
ok "removed file is gone" '[ $rc = 0 ] && [ ! -e "$C/skills/retro/SKILL.md" ] && [ -e "$C/skills/worker/SKILL.md" ]'
ok "old hook replaced, not duplicated" '[ "$(J "\"|\".join(h[\"command\"] for e in d[\"hooks\"][\"PreToolUse\"] for h in e[\"hooks\"])")" = "python3 \"\$HOME/.claude/orchestra/hooks/guard-v2.py\"" ]'
ok "dropped deny rule removed, user rule kept" '[ "$(J "\"Bash(rm -rf ~)\" in d[\"permissions\"][\"deny\"], \"Bash(git push -f *)\" in d[\"permissions\"][\"deny\"]")" = "(False, True)" ]'
UNINST --yes
ok "uninstall after upgrade restores settings" '[ $rc = 0 ] && [ "$(J "\" \".join(sorted(d)) + \"|\" + \",\".join(d[\"permissions\"][\"deny\"])")" = "hooks model permissions|Bash(git push -f *)" ]'

echo "-- push-guard already hooked under an absolute path: no second entry"
H="$S/habs"; C="$H/.claude"; newhome "$H"
python3 - "$C/settings.json" "$H" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["PreToolUse"] = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 " + sys.argv[2] + "/.claude/orchestra/hooks/push-guard.py"}]}]
json.dump(d, open(p, "w"))
PY
INST --yes --no-web --skip-tests
ok "one PreToolUse hook" '[ $rc = 0 ] && [ "$(J "sum(len(e[\"hooks\"]) for e in d[\"hooks\"][\"PreToolUse\"])")" = 1 ]'

echo "-- non-ASCII text in settings.json is kept as written"
H="$S/hutf"; C="$H/.claude"; newhome "$H"
python3 - "$C/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["note"] = "café"; open(p, "w").write(json.dumps(d, ensure_ascii=False))
PY
INST --yes --no-web --skip-tests
ok "no \\u escapes" '[ $rc = 0 ] && grep -q "café" "$C/settings.json" && ! grep -qF "\\u00e9" "$C/settings.json"'

echo "-- uninstall removes a push-guard hook even after you edited its command"
H="$S/hedit"; C="$H/.claude"; newhome "$H"; INST --yes --no-web --skip-tests
python3 - "$C/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
for e in d["hooks"]["PreToolUse"]:
    for h in e["hooks"]:
        h["command"] += " --verbose"
json.dump(d, open(p, "w"), indent=2)
PY
UNINST --yes
ok "no hook left calling the removed script" '[ $rc = 0 ] && ! grep -q "push-guard" "$C/settings.json" && [ ! -e "$C/orchestra/hooks/push-guard.py" ]'

echo "-- your own push-guard (older copy) and its hook survive install + uninstall"
H="$S/hown"; C="$H/.claude"; newhome "$H"; mkdir -p "$C/orchestra/hooks"; echo "# my old guard" > "$C/orchestra/hooks/push-guard.py"
python3 - "$C/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["PreToolUse"] = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ~/.claude/orchestra/hooks/push-guard.py"}]}]
json.dump(d, open(p, "w"))
PY
cp "$C/settings.json" "$S/own-settings.orig"
INST --yes --no-web --skip-tests; UNINST --yes
ok "old script restored, own hook kept" '[ $rc = 0 ] && [ "$(cat "$C/orchestra/hooks/push-guard.py")" = "# my old guard" ] && python3 -c "import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))" "$C/settings.json" "$S/own-settings.orig"'

echo "-- uninstall with a settings.json of a new shape removes nothing"
H="$S/hushape"; C="$H/.claude"; newhome "$H"; INST --yes --no-web --skip-tests
python3 - "$C/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["hooks"]["PreToolUse"] = "oops"; json.dump(d, open(p, "w"))
PY
before=$(snap "$H"); UNINST --yes
ok "exit 1, HOME unchanged" '[ $rc = 1 ] && grep -q "Nothing was removed" <<< "$out" && [ "$(snap "$H")" = "$before" ]'

echo "-- uninstall with a broken settings.json removes nothing"
H="$S/hubad"; C="$H/.claude"; newhome "$H"; INST --yes --no-web --skip-tests; echo '{ nope' > "$C/settings.json"; before=$(snap "$H")
UNINST --yes
ok "exit 1, HOME unchanged" '[ $rc = 1 ] && grep -q "Nothing was removed" <<< "$out" && [ "$(snap "$H")" = "$before" ]'

echo "-- shell rc: ZDOTDIR, other shells, two shells"
H="$S/hz"; rm -rf "$H"; mkdir -p "$H/zd"
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" ZDOTDIR="$H/zd" SHELL=/bin/zsh PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1); rc=$?
ok "zsh with ZDOTDIR: line in \$ZDOTDIR/.zshrc" '[ $rc = 0 ] && grep -q "orchestra/bin" "$H/zd/.zshrc" && [ ! -e "$H/.zshrc" ]'
H="$S/hfish"; rm -rf "$H"; mkdir -p "$H"
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" SHELL=/opt/bin/fish PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1); rc=$?
ok "fish: no rc written, line printed" '[ $rc = 0 ] && [ ! -e "$H/.profile" ] && [ ! -e "$H/.bash_profile" ] && grep -qF "export PATH=" <<< "$out"'
H="$S/h2sh"; C="$H/.claude"; rm -rf "$H"; mkdir -p "$H"
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" SHELL=/bin/bash PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1)
out=$(cd "$S" && printf 'n\nn\ny\n' | HOME="$H" SHELL=/bin/zsh PATH="$S/bin:$PATH" bash "$ROOT/install.sh" --skip-tests 2>&1)
ok "both rc files got the PATH line" 'grep -q "orchestra/bin" "$H/.bash_profile" && grep -q "orchestra/bin" "$H/.zshrc"'
UNINST --yes
ok "uninstall removes the line from both rc files" '[ $rc = 0 ] && ! grep -qs "orchestra/bin" "$H/.bash_profile" && ! grep -qs "orchestra/bin" "$H/.zshrc"'

echo "-- a git clone ships only tracked files"
mkdir -p "$S/src3"; for f in install.sh uninstall.sh settings.example.json CLAUDE.template.md skills agents orchestra statusline; do cp -R "$ROOT/$f" "$S/src3/"; done
git -C "$S/src3" init -q && git -C "$S/src3" add -A && echo stray > "$S/src3/orchestra/stray.log"
H="$S/hgit"; C="$H/.claude"; newhome "$H"
out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$S/src3/install.sh" --yes --no-web --skip-tests < /dev/null 2>&1); rc=$?
ok "untracked file not installed" '[ $rc = 0 ] && [ -e "$C/orchestra/bin/orch" ] && [ ! -e "$C/orchestra/stray.log" ]'

echo "-- upgrade that drops the hook script also drops an edited hook calling it"
H="$S/hup2"; C="$H/.claude"; newhome "$H"; INST --yes --no-web --skip-tests
python3 - "$C/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
for e in d["hooks"]["PreToolUse"]:
    for h in e["hooks"]:
        h["command"] += " --verbose"
json.dump(d, open(p, "w"), indent=2)
PY
rm -rf "$S/src5"; mkdir -p "$S/src5"; for f in install.sh uninstall.sh settings.example.json CLAUDE.template.md skills agents orchestra statusline; do cp -R "$ROOT/$f" "$S/src5/"; done
mv "$S/src5/orchestra/hooks/push-guard.py" "$S/src5/orchestra/hooks/guard-v3.py"
python3 - "$S/src5/settings.example.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = 'python3 "$HOME/.claude/orchestra/hooks/guard-v3.py"'; json.dump(d, open(p, "w"), indent=2)
PY
out=$(cd "$S" && HOME="$H" PATH="$S/bin:$PATH" bash "$S/src5/install.sh" --yes --no-web --skip-tests < /dev/null 2>&1); rc=$?
ok "only the new hook remains" '[ $rc = 0 ] && [ ! -e "$C/orchestra/hooks/push-guard.py" ] && [ "$(J "\"|\".join(h[\"command\"] for e in d[\"hooks\"][\"PreToolUse\"] for h in e[\"hooks\"])")" = "python3 \"\$HOME/.claude/orchestra/hooks/guard-v3.py\"" ]'

echo "-- a rerun that replaces a file you edited says so"
H="$S/hed2"; C="$H/.claude"; newhome "$H"; INST --yes --no-web --skip-tests; echo "my tweak" >> "$C/agents/verifier.md"
INST --yes --no-web --skip-tests
ok "names the file and its backup" '[ $rc = 0 ] && grep -q "replaced agents/verifier.md, which you had edited" <<< "$out" && cmp -s "$ROOT/agents/verifier.md" "$C/agents/verifier.md"'

echo "-- no node/npx: web defaults to no; yes or --web stops before writing"
mkdir -p "$S/nonpx"
for x in cmux gh gitleaks claude; do ln -sf "$S/bin/$x" "$S/nonpx/$x"; done
ln -sf "$(python3 -c 'import sys; print(sys.executable)')" "$S/nonpx/python3"; ln -sf "$(command -v git)" "$S/nonpx/git"
NP="$S/nonpx:/usr/bin:/bin:/usr/sbin:/sbin"
ok "test PATH really has no npx" '! PATH="$NP" command -v npx >/dev/null'
NOWEB(){ H="$S/hnp"; newhome "$H"; before=$(snap "$H"); out=$(cd "$S" && printf "$1" | HOME="$H" PATH="$NP" bash "$ROOT/install.sh" --skip-tests $2 2>&1); rc=$?; }
NOWEB '' --yes
ok "--yes: installs, skips web, exit 0" '[ $rc = 0 ] && [ -e "$H/.claude/orchestra/bin/orch" ] && grep -q "web: skipped" <<< "$out"'
NOWEB '' --web
ok "--web: exit 1, nothing written" '[ $rc = 1 ] && grep -q "needs node/npx" <<< "$out" && [ "$(snap "$H")" = "$before" ]'
NOWEB '\n\n\n' ''
ok "Enter at every prompt: web no, exit 0" '[ $rc = 0 ] && grep -qF "[y/N]" <<< "$out" && [ -e "$H/.claude/orchestra/bin/orch" ]'
NOWEB 'y\n\n\n' ''
ok "typed y: exit 1, nothing written" '[ $rc = 1 ] && [ "$(snap "$H")" = "$before" ]'

echo "-- web setup failure is reported and fails the install"
H="$S/hwf"; newhome "$H"; mkdir -p "$S/failbin"; printf '#!/bin/sh\nexit 1\n' > "$S/failbin/claude"; chmod +x "$S/failbin/claude"
out=$(cd "$S" && HOME="$H" PATH="$S/failbin:$S/bin:$PATH" bash "$ROOT/install.sh" --yes --web --skip-tests < /dev/null 2>&1); rc=$?
ok "exit non-zero with a web setup message" '[ $rc != 0 ] && grep -q "web setup failed" <<< "$out"'
rm -f "$S/claude.log" "$S/npx.log"

echo "-- make-demo-repo --no-launch never calls cmux"
rm -f "$S/cmux.log"
out=$(cd "$S" && ORCH_CMUX="$S/bin/cmux" bash "$ROOT/orchestra/bin/make-demo-repo" --no-launch "$S/demo1" 2>&1); rc=$?
ok "demo repo created" '[ $rc = 0 ] && [ -f "$S/demo1/app/package.json" ] && [ -d "$S/demo1/origin.git" ]'
ok "no cmux call with --no-launch" '[ ! -e "$S/cmux.log" ]'
echo "-- the demo dev server serves only its app dir, on loopback only"
if command -v node >/dev/null; then
  DP=$((40000 + $$ % 2000 * 10)); echo secret > "$S/demo1/outside.txt"
  (cd "$S/demo1/app" && PORT=$DP exec node server.js >/dev/null 2>&1) & DS=$!
  for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$DP/" && break; sleep 0.1; done
  code(){ curl -s --path-as-is -o "$S/dbody" -w '%{http_code}' "http://127.0.0.1:$DP$1"; }
  ok "demo server serves index.html at /" '[ "$(code /)" = 200 ] && grep -q "Tip Calculator" "$S/dbody"'
  ok "demo server serves app.js" '[ "$(code /app.js)" = 200 ]'
  ctype(){ curl -s --path-as-is -o /dev/null -w '%{content_type}' "http://127.0.0.1:$DP$1"; }
  ok "/ is served as text/html (utf-8)" '[ "$(ctype /)" = "text/html; charset=utf-8" ]'
  ok "/index.html is served as text/html" '[ "$(ctype /index.html)" = "text/html; charset=utf-8" ]'
  ok "/app.js has a JavaScript Content-Type (module scripts need one)" '[ "$(ctype /app.js)" = "text/javascript; charset=utf-8" ]'
  printf 'x' > "$S/demo1/app/a.css"; printf '{}' > "$S/demo1/app/a.json"; printf '<svg/>' > "$S/demo1/app/a.svg"; printf 'x' > "$S/demo1/app/a.mjs"; printf 'x' > "$S/demo1/app/a.bin"; printf 'x' > "$S/demo1/app/A.JS"
  ok ".css → text/css" '[ "$(ctype /a.css)" = "text/css; charset=utf-8" ]'
  ok ".json → application/json" '[ "$(ctype /a.json)" = "application/json; charset=utf-8" ]'
  ok ".svg → image/svg+xml" '[ "$(ctype /a.svg)" = "image/svg+xml" ]'
  ok ".mjs → text/javascript" '[ "$(ctype /a.mjs)" = "text/javascript; charset=utf-8" ]'
  ok "an upper-case .JS is still JavaScript" '[ "$(ctype /A.JS)" = "text/javascript; charset=utf-8" ]'
  ok "an unknown extension → application/octet-stream" '[ "$(ctype /a.bin)" = "application/octet-stream" ]'
  ok "a 404 is plain text, not the extension's type" '[ "$(ctype /nope.js)" = "text/plain; charset=utf-8" ]'
  ok "a ../ request outside the app dir → 404" '[ "$(code /../outside.txt)" = 404 ] && ! grep -q secret "$S/dbody"'
  ok "a deep ../ request (/etc/passwd) → 404" '[ "$(code /../../../../../../../../etc/passwd)" = 404 ]'
  ok "an encoded %2e%2e request → 404" '[ "$(code /%2e%2e/outside.txt)" = 404 ] && [ "$(code /..%2foutside.txt)" = 404 ]'
  ok "a missing file → 404" '[ "$(code /nope.js)" = 404 ]'
  ok "the clone's .git (and any dot path) → 404" '[ "$(code /.git/config)" = 404 ] && [ "$(code /.gitignore)" = 404 ] && [ "$(code /%2egit/HEAD)" = 404 ]'
  ok "it listens on 127.0.0.1 only (not every interface)" '[ "$(lsof -nP -a -p $DS -iTCP -sTCP:LISTEN -Fn | grep "^n")" = "n127.0.0.1:$DP" ]'
  kill $DS 2>/dev/null; wait $DS 2>/dev/null
else
  echo "test-install: node missing, demo server not exercised"
fi
out=$(cd "$S" && ORCH_NO_LAUNCH=0 ORCH_CMUX="$S/bin/cmux" bash "$ROOT/orchestra/bin/make-demo-repo" "$S/demo4" 2>&1); rc=$?
ok "ORCH_NO_LAUNCH=0 still launches" '[ $rc = 0 ] && grep -q "new-workspace" "$S/cmux.log"'; rm -f "$S/cmux.log"
out=$(cd "$S" && ORCH_CMUX="$S/bin/cmux" bash "$ROOT/orchestra/bin/make-demo-repo" "$S/demo3" --no-launch 2>&1); rc=$?
ok "--no-launch after the dir also never calls cmux" '[ $rc = 0 ] && [ -f "$S/demo3/app/package.json" ] && [ ! -e "$S/cmux.log" ]'
out=$(cd "$S" && ORCH_CMUX="$S/bin/cmux" bash "$ROOT/orchestra/bin/make-demo-repo" "$S/demo2" 2>&1); rc=$?
ok "launching form uses ORCH_CMUX" '[ $rc = 0 ] && grep -q "new-workspace" "$S/cmux.log"'

echo "test-install: $P passed, $F failed"
[ $F -eq 0 ]
