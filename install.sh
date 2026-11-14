#!/usr/bin/env bash
# Install claude-orchestra into ~/.claude (macOS).
#   usage: ./install.sh [--yes] [--web | --no-web] [--skip-tests]
#     --yes         non-interactive: take every default (web setup yes when node/npx is found, CLAUDE.md block yes, shell rc no)
#     --web         set up Playwright MCP + browsers without asking;  --no-web: skip it without asking
#     --skip-tests  don't run tests/run.sh at the end
# What it does, in order (nothing is written until every check passes):
#   1. prints a dependency table; a missing required one (cmux first) → how to install it, exit 1
#   2. asks its questions (web projects? CLAUDE.md block? shell rc PATH line?)
#   3. copies skills/ agents/ orchestra/ statusline/ into ~/.claude, backing up every file it replaces to
#      ~/.claude/backups/claude-orchestra-<timestamp>/
#   4. merges settings.example.json's hook, statusLine and deny rules into ~/.claude/settings.json (never
#      overwrites it; an existing statusLine is kept) and puts CLAUDE.template.md into ~/.claude/CLAUDE.md
#      between claude-orchestra markers (your own text is kept; a rerun replaces only the block)
#   5. web: `claude mcp add` Playwright (npx form, user scope) unless present, then the Playwright browsers
#   6. runs tests/run.sh
# A second run with the same answers changes nothing. ./uninstall.sh reverses it (from the manifest at
# ~/.claude/orchestra/.install-manifest.json). ORCH_CMUX overrides the cmux binary (tests).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
BIN_DIR="$DEST/orchestra/bin"
PATH_LINE='export PATH="$HOME/.claude/orchestra/bin:$PATH"'
CMUX="${ORCH_CMUX:-cmux}"
YES=0; WEB=""; RUN_TESTS=1; WEB_FAIL=""
usage(){ sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; }
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    --web) WEB=1 ;;
    --no-web) WEB=0 ;;
    --skip-tests) RUN_TESTS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option $a" >&2; usage >&2; exit 2 ;;
  esac
done

# ask "<question>" y|n  → 0 = yes. --yes or no answer (EOF, empty line) takes the default.
ask(){
  local a=""
  if [ "$YES" = 1 ]; then [ "$2" = y ]; return; fi
  printf '%s ' "$1"
  IFS= read -r a || a=""
  [ -t 0 ] || echo
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    n|no) return 1 ;;
    *) [ "$2" = y ] ;;
  esac
}
has(){ command -v "$1" >/dev/null 2>&1; }
row(){ printf '  %-15s %-9s %s\n' "$1" "$2" "$3"; }
# user-scope MCP server present in ~/.claude.json? (0 = yes)
mcp_has(){ python3 - "$HOME/.claude.json" "$1" <<'PY' 2>/dev/null
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[2] in (d.get("mcpServers") or {}) else 1)
PY
}

# ---------- 1. dependencies (read-only) ----------
if [ "$(uname -s)" != Darwin ]; then echo "install.sh: claude-orchestra needs macOS (cmux, caffeinate)." >&2; exit 1; fi
MISSING=()
echo "Dependencies"
row NAME KIND STATUS
if has "$CMUX"; then row cmux required found; else row cmux required "missing — brew install --cask cmux"; MISSING+=(cmux); fi
if has python3 && PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2]); sys.exit(sys.version_info < (3, 9))' 2>/dev/null); then
  row python3 required "found $PYV"
else row python3 required "missing or older than 3.9 — brew install python"; MISSING+=(python3); fi
for t in git gh gitleaks claude; do
  case $t in git) h="xcode-select --install" ;; gh) h="brew install gh" ;; gitleaks) h="brew install gitleaks" ;;
    claude) h="install Claude Code: https://docs.claude.com/en/docs/claude-code" ;; esac
  if has "$t"; then row "$t" required found; else row "$t" required "missing — $h"; MISSING+=("$t"); fi
done
if has npx; then row node/npx optional found; else row node/npx optional "missing — brew install node (needed for Playwright MCP, context7)"; fi
if mcp_has playwright; then row "Playwright MCP" optional "found (user scope)"; elif has npx; then row "Playwright MCP" optional "not set up — answer yes to web projects, or --web"
else row "Playwright MCP" optional "not set up — needs node/npx first (brew install node), then --web"; fi
if mcp_has context7; then row context7 optional "found (user scope)"
elif has npx; then row context7 optional "found (workers start it with npx via orchestra/worker-mcp.json)"
else row context7 optional "missing — needs node/npx (workers start it via orchestra/worker-mcp.json)"; fi
for t in maestro xcbeautify; do
  n=$([ $t = maestro ] && echo Maestro || echo xcbeautify)
  if has $t; then row "$n" optional "found (iOS native slices)"; else row "$n" optional "missing — only for iOS native slices"; fi
done
echo
if [ ${#MISSING[@]} -gt 0 ]; then
  if [[ " ${MISSING[*]} " == *" cmux "* ]]; then
    cat >&2 <<'EOF'
cmux is required: every worker runs in its own cmux workspace, and the coordinator talks to it with
`cmux agent message`. Install it, open it once, and run this installer again from a cmux terminal:
    brew install --cask cmux
(or download it from the cmux website). Check: `cmux identify --json` prints a caller.
EOF
  fi
  echo "install.sh: missing required: ${MISSING[*]} — install them (hints above) and rerun. Nothing was written." >&2
  exit 1
fi
# ---------- 2. questions (before anything is written) ----------
if [ -z "$WEB" ]; then
  # Playwright MCP runs on npx: without node/npx the default is no (the question is still asked, so piped answers line up)
  if has npx; then q="[Y/n]"; d=y; else q="(needs node/npx, which is missing: brew install node) [y/N]"; d=n; fi
  if ask "Will you build websites or web apps? (sets up Playwright MCP + browsers) $q" "$d"; then WEB=1; else WEB=0; fi
fi
if [ "$WEB" = 1 ] && ! has npx; then
  echo "install.sh: web setup needs node/npx — brew install node and rerun (or use --no-web). Nothing was written." >&2; exit 1
fi
MD=0; ask "Add the workflow rules (CLAUDE.template.md) to ~/.claude/CLAUDE.md between claude-orchestra markers? Your own text is kept. [Y/n]" y && MD=1
RC=""
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) case "${SHELL:-}" in  # bash: never create ~/.bash_profile next to an existing ~/.profile (it would shadow it)
       */zsh) rcf="${ZDOTDIR:-$HOME}/.zshrc" ;;
       */bash) if [ ! -e "$HOME/.bash_profile" ] && [ -e "$HOME/.profile" ]; then rcf="$HOME/.profile"; else rcf="$HOME/.bash_profile"; fi ;;
       *) rcf="" ;; esac  # other shells (fish, …) use other syntax: print the line only
     if [ -n "$rcf" ] && ask "Append the PATH line for orch to ${rcf/#$HOME/~}? [y/N]" n; then RC="$rcf"; fi ;;
esac
# ---------- 3–4. plan everything in memory (any problem → exit, nothing written), then copy, back up, merge ----------
python3 - "$SRC" "$DEST" "$(date +%Y%m%d-%H%M%S)" "$MD" "$RC" "$PATH_LINE" <<'PY'
import copy, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path
src, dest, ts, want_md, rc, path_line = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
START, END = "<!-- claude-orchestra:start -->", "<!-- claude-orchestra:end -->"
MAN = dest / "orchestra" / ".install-manifest.json"
sha = lambda b: hashlib.sha256(b).hexdigest()

def die(msg):
    sys.exit(f"install.sh: {msg} — fix it and rerun. Nothing was written.")

class Bad(Exception):
    pass

def need(v, typ, where):  # the merge only edits these containers; anything else is the user's to fix
    if not isinstance(v, typ):
        raise Bad(f"{where} should be {'an object' if typ is dict else 'a list'}")
    return v

def hook_script(cmd):  # "orchestra/hooks/<name>" when the command runs one of ~/.claude/orchestra/hooks
    m = re.search(r"\.claude/(orchestra/hooks/[\w.-]+)", cmd if isinstance(cmd, str) else "")
    return m.group(1) if m else None

def same_hook(a, b):  # same command, or the same ~/.claude/orchestra/hooks script written another way
    k = lambda c: (re.search(r"\.claude/orchestra/hooks/[\w.-]+", c if isinstance(c, str) else "") or [c])[0]
    return a == b or k(a) == k(b)

def shipped(top):  # a git clone ships only its tracked files (never stray local ones); a tarball, everything
    if not (src / ".git").exists():
        return list((src / top).rglob("*"))
    r = subprocess.run(["git", "-C", str(src), "ls-files", "-z", "--", top], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"`git ls-files` failed in {src}: {r.stderr.strip()}")
    return [src / f for f in r.stdout.split("\0") if f]

# ---------- plan: everything computed in memory; any problem exits before the first write ----------
try:
    man = json.loads(MAN.read_text()) if MAN.exists() else {}
except ValueError as e:
    die(f"{MAN} is not valid JSON ({e})")
man_before = json.dumps(man, sort_keys=True)
plan = copy.deepcopy(man)
files = plan.setdefault("files", {})
S = plan.setdefault("settings", {"hook_commands": [], "statusLine": None, "deny": [], "created": [], "file_created": False})
ship = sorted(p for top in ("skills", "agents", "orchestra", "statusline") for p in shipped(top)
              if p.is_file() and p.name != ".DS_Store" and "__pycache__" not in p.parts)
ship_rels = {str(p.relative_to(src)) for p in ship}
# hook scripts this run deletes for good (shipped before, not now, and nothing of yours to restore)
gone = {rel for rel, e in files.items() if rel.startswith("orchestra/hooks/") and rel not in ship_rels
        and not e.get("preexisting") and not e.get("orig")}

sp = dest / "settings.json"
ex = json.loads((src / "settings.example.json").read_text())
try:
    cur = json.loads(sp.read_text()) if sp.exists() else {}
except ValueError as e:
    die(f"{sp} is not valid JSON ({e})")

def merge(cur):
    new = copy.deepcopy(need(cur, dict, "settings.json (top level)"))
    def hook_lists(ev):  # new["hooks"][ev] → its entries, checked
        ents = need(need(new.get("hooks", {}), dict, "hooks").get(ev, []), list, f"hooks.{ev}")
        for i, ent in enumerate(ents):
            need(need(ent, dict, f"hooks.{ev}[{i}]").get("hooks", []), list, f"hooks.{ev}[{i}].hooks")
            for j, h in enumerate(ent.get("hooks", [])):
                need(h, dict, f"hooks.{ev}[{i}].hooks[{j}]")
        return ents
    def container(a, b):  # make new[a][b] exist (object, then list), recording what we created
        if a not in new:
            new[a] = {}; S["created"].append(a)
        if b not in need(new[a], dict, a):
            new[a][b] = []; S["created"].append(f"{a}.{b}")
        return need(new[a][b], list, f"{a}.{b}")
    deny = lambda: need(need(new.get("permissions", {}), dict, "permissions").get("deny", []), list, "permissions.deny")
    # entries an earlier install merged that this version no longer ships (e.g. a moved hook) go first
    ex_hooks = {(ev, h["command"]) for ev, ents in ex.get("hooks", {}).items() for ent in ents for h in ent["hooks"]}
    stale = [hc for hc in S["hook_commands"] if tuple(hc) not in ex_hooks]
    for ev in list(need(new.get("hooks", {}), dict, "hooks")):
        keep = []
        for ent in hook_lists(ev):
            hs = [h for h in ent.get("hooks", []) if not ([ev, h.get("command")] in stale or hook_script(h.get("command")) in gone)]
            if hs or not ent.get("hooks"):  # drop only entries this emptied
                keep.append({**ent, "hooks": hs} if "hooks" in ent else ent)
        new["hooks"][ev] = keep
    for hc in stale:
        S["hook_commands"].remove(hc)
    ex_deny = ex.get("permissions", {}).get("deny", [])
    for r in [r for r in S["deny"] if r not in ex_deny]:
        if r in deny():
            deny().remove(r)
        S["deny"].remove(r)
    if S.get("statusLine") is not None and new.get("statusLine") == S["statusLine"] != ex["statusLine"]:
        new["statusLine"] = ex["statusLine"]; S["statusLine"] = ex["statusLine"]
    for ev, entries in ex.get("hooks", {}).items():
        for ent in entries:
            for h in ent["hooks"]:
                if not any(same_hook(hh.get("command"), h["command"]) for ee in hook_lists(ev) for hh in ee.get("hooks", [])):
                    container("hooks", ev).append({"matcher": ent["matcher"], "hooks": [h]})
                    S["hook_commands"].append([ev, h["command"]])
    if "statusLine" not in new:
        new["statusLine"] = ex["statusLine"]; S["statusLine"] = ex["statusLine"]
    elif new["statusLine"] != ex["statusLine"] and S.get("statusLine") is None:
        print(f"settings.json: keeping your own statusLine; ours is {ex['statusLine']['command']}")
    for r in ex_deny:
        if r not in deny():
            container("permissions", "deny").append(r); S["deny"].append(r)
    return new
try:
    new = merge(cur)
except Bad as e:
    die(f"{sp}: {e}")
settings_text = json.dumps(new, indent=2, ensure_ascii=False) + "\n" if (new != cur or not sp.exists()) else None
if settings_text is not None and not sp.exists():
    S["file_created"] = True

md_text = None; mp = dest / "CLAUDE.md"
if want_md == "1":
    block = START + "\n" + (src / "CLAUDE.template.md").read_text().rstrip("\n") + "\n" + END
    old = mp.read_text() if mp.exists() else None
    s, e = (old or "").count(START), (old or "").count(END)
    if (s, e) == (1, 1) and old.index(START) < old.index(END):
        a, b = old.index(START), old.index(END) + len(END)
        text = old[:a] + block + old[b:]
    elif (s, e) == (0, 0):
        prefix = "" if not old else ("\n" if old.endswith("\n") else "\n\n")
        text = (old or "") + prefix + block + "\n"
        plan["claude_md"] = {"created": old is None, "prefix": prefix}
    else:
        die(f"{mp} has a broken claude-orchestra:start/end marker pair (fix or remove the markers)")
    md_text = text if text != old else None

rc_text = None
if rc:
    rp = Path(rc); line = path_line + "  # claude-orchestra"
    old = rp.read_text() if rp.exists() else None
    if old is None or line not in old.splitlines():
        rc_text = (old or "") + ("" if not old or old.endswith("\n") else "\n") + line + "\n"
        rcs = plan.setdefault("rcs", [])
        if not any(x["file"] == str(rp) for x in rcs):
            rcs.append({"file": str(rp), "line": line, "created": old is None})

# ---------- write ----------
orig_man = man; man = plan
wrote = set()
bk, n = dest / "backups" / f"claude-orchestra-{ts}", 1
while bk.exists():
    n += 1; bk = dest / "backups" / f"claude-orchestra-{ts}-{n}"
backed = []
def backup(path, rel, content=False):
    # A file we replace keeps its symlink as a symlink. A file we edit in place (content=True: settings.json,
    # CLAUDE.md, the shell rc) is written through its link, so the backup must hold the bytes it had.
    t = bk / rel; t.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, t, follow_symlinks=content); backed.append(rel)
    return str(t.relative_to(dest))
def write(p, text):
    p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text)
def save_manifest():
    if json.dumps(man, sort_keys=True) != man_before:
        write(MAN, json.dumps(man, indent=2, sort_keys=True) + "\n")

def main():
    copied = 0; seen = set()
    for p in ship:
        rel = str(p.relative_to(src)); d = dest / rel; data = p.read_bytes(); e = files.get(rel); seen.add(rel)
        if d.is_file() and not d.is_symlink() and d.read_bytes() == data:
            if (d.stat().st_mode & 0o777) != (p.stat().st_mode & 0o777):
                os.chmod(d, p.stat().st_mode & 0o777)
            if e is None:
                files[rel] = {"sha": sha(data), "orig": None, "preexisting": True}
            continue
        if d.exists() or d.is_symlink():
            b = backup(d, rel)
            if e is None or e.get("preexisting"):
                e = {"orig": b}
            elif d.is_file() and sha(d.read_bytes()) != e.get("sha"):
                print(f"replaced {rel}, which you had edited — your version is in {bk / rel}")
        elif e is None:
            e = {"orig": None}
        d.parent.mkdir(parents=True, exist_ok=True)
        if d.is_symlink():
            d.unlink()
        shutil.copy2(p, d)
        e["sha"] = sha(data); files[rel] = e; copied += 1
    for rel in [r for r in files if r not in seen]:  # shipped by an earlier install, gone from this version
        e = files.pop(rel); d = dest / rel
        if e.get("preexisting"):
            continue
        if d.is_file() and not d.is_symlink() and sha(d.read_bytes()) == e.get("sha"):
            d.unlink()
            if e.get("orig") and os.path.lexists(dest / e["orig"]):
                shutil.copy2(dest / e["orig"], d, follow_symlinks=False)
            print(f"removed {rel} (no longer shipped)")
        elif os.path.lexists(d):
            print(f"kept {rel}: no longer shipped, but you changed it")
    if settings_text is not None:
        if sp.exists():
            backup(sp, "settings.json", content=True)
        write(sp, settings_text); wrote.add("settings"); print("settings.json: merged push-guard hook, statusLine, deny rules")
    else:
        print("settings.json: already up to date")
    if want_md == "1":
        if md_text is not None:
            if mp.exists():
                backup(mp, "CLAUDE.md", content=True)
            write(mp, md_text); wrote.add("claude_md"); print("CLAUDE.md: workflow rules block written (between claude-orchestra markers)")
        else:
            print("CLAUDE.md: rules block already up to date")
    if rc_text is not None:
        rp = Path(rc)
        if rp.exists():
            backup(rp, "shell-rc/" + rp.name, content=True)
        write(rp, rc_text); wrote.add("rcs"); print(f"{rp}: PATH line added (open a new terminal)")
    print(f"files: {copied} copied" + (f"; {len(backed)} backed up to {bk}" if backed else "; nothing replaced"))

try:
    main()
    wrote.update({"settings", "claude_md", "rcs"})  # finished: whatever was planned (incl. "no change") holds
finally:  # whatever was copied before an I/O error stays removable by uninstall.sh; unwritten edits aren't recorded
    for k in {"settings", "claude_md", "rcs"} - wrote:
        if k in orig_man:
            man[k] = orig_man[k]
        else:
            man.pop(k, None)
    save_manifest()
PY

case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
  [ -n "$RC" ] || { echo "orch is not on your PATH. The skills call it by full path; to type it yourself add:"; echo "    $PATH_LINE"; } ;;
esac

# ---------- 5. web projects: Playwright MCP + browsers ----------
if [ "$WEB" = 1 ]; then
  if mcp_has playwright; then echo "web: Playwright MCP already set up"
  else
    if claude mcp add -s user playwright -- npx -y @playwright/mcp@latest --browser chrome --isolated --headless; then
      echo "web: Playwright MCP added (user scope); workers get it from ~/.claude/orchestra/worker-mcp.json"
    else WEB_FAIL="claude mcp add playwright failed"; fi
  fi
  if npx -y playwright install chromium; then echo "web: Playwright browsers installed (for repos' e2e specs)"
  else WEB_FAIL="${WEB_FAIL:+$WEB_FAIL; }npx playwright install chromium failed"; fi
  [ -d "/Applications/Google Chrome.app" ] || echo "web: the Playwright MCP server drives Google Chrome — install it: brew install --cask google-chrome"
elif ! has npx; then
  echo "web: skipped (Playwright MCP needs node/npx); later: brew install node, then ./install.sh --web"
fi

[ -z "$WEB_FAIL" ] || echo "install.sh: web setup failed: $WEB_FAIL — fix it, then rerun ./install.sh --web" >&2

# ---------- 6. self-tests ----------
if [ "$RUN_TESTS" = 1 ]; then
  echo "Running the test suites (a few minutes)…"
  if ! bash "$SRC/tests/run.sh"; then echo "install.sh: installed, but the self-tests failed (output above)." >&2; exit 1; fi
fi
cat <<EOF

Installed into ~/.claude. Next:
  1. In cmux, open a terminal in a repo, run \`claude\`, accept the folder-trust prompt.
  2. Try it on a throwaway repo first:  ~/.claude/orchestra/bin/make-demo-repo
  3. Day to day:  /new-task <what you want>
Uninstall: $SRC/uninstall.sh
EOF
[ -z "$WEB_FAIL" ] || exit 1
