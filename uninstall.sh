#!/usr/bin/env bash
# Remove claude-orchestra from ~/.claude, using the manifest install.sh wrote
# (~/.claude/orchestra/.install-manifest.json).
#   usage: ./uninstall.sh [--yes]
# Removes every file install.sh copied (a file you edited since is moved to
# ~/.claude/backups/claude-orchestra-uninstall-<timestamp>/ instead) and restores the file it replaced
# from its install backup; removes the claude-orchestra block from ~/.claude/CLAUDE.md, the hook /
# statusLine / deny entries it merged into settings.json, and the PATH line it added to your shell rc.
# Kept: run state (~/.claude/orchestra/runs …), ~/.claude/backups, and the Playwright MCP server
# (remove it with `claude mcp remove -s user playwright`).
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1  # macOS's own python3 would cache bytecode under ~/Library/Caches (a refusal writes nothing)
DEST="$HOME/.claude"
YES=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
MAN="$DEST/orchestra/.install-manifest.json"
[ -f "$MAN" ] || { echo "uninstall.sh: no install manifest at $MAN — nothing to remove." >&2; exit 1; }
if [ "$YES" != 1 ]; then
  printf 'Remove claude-orchestra from ~/.claude? [y/N] '
  IFS= read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "Nothing removed."; exit 0 ;; esac
fi
python3 - "$DEST" "$(date +%Y%m%d-%H%M%S)" <<'PY'
import hashlib, json, os, re, shutil, sys
from pathlib import Path
dest, ts = Path(sys.argv[1]), sys.argv[2]
START, END = "<!-- claude-orchestra:start -->", "<!-- claude-orchestra:end -->"
MAN = dest / "orchestra" / ".install-manifest.json"
man = json.loads(MAN.read_text())
kept = dest / "backups" / f"claude-orchestra-uninstall-{ts}"
removed = restored = moved = 0
sp, S = dest / "settings.json", man.get("settings", {})
try:  # parse first: a broken settings.json stops the uninstall before anything is removed
    cur = json.loads(sp.read_text()) if sp.exists() else None
except ValueError as e:
    sys.exit(f"uninstall.sh: {sp} is not valid JSON ({e}) — fix it and rerun. Nothing was removed.")
def keep_copy(p, rel):  # the content of a file about to be edited in place, kept beside the moved files
    t = kept / rel; t.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(p, t)

# settings.json edits are computed before anything is removed; any surprise → exit, nothing removed.
# Hooks removed: the ones install merged, plus any hook running a ~/.claude/orchestra/hooks script that this
# uninstall deletes without restoring a backup of it (left in place it would call a missing file and block
# every Bash call). A hook whose script comes back from the install backup was yours: it stays.
# (the same rule install.sh uses when an upgrade drops a hook script)
gone = {rel for rel, e in man.get("files", {}).items()
        if rel.startswith("orchestra/hooks/") and not e.get("preexisting") and not e.get("orig")}
def hook_script(cmd):
    m = re.search(r"\.claude/(orchestra/hooks/[\w.-]+)", cmd if isinstance(cmd, str) else "")
    return m.group(1) if m else None
def ours(ev, cmd):
    return [ev, cmd] in S.get("hook_commands", []) or hook_script(cmd) in gone
def unmerge(cur):
    for ev, entries in list((cur.get("hooks") or {}).items()):
        keep = []
        for ent in entries:
            ent["hooks"] = [h for h in ent.get("hooks", []) if not ours(ev, h.get("command"))]
            if ent["hooks"]:
                keep.append(ent)
        cur["hooks"][ev] = keep
    if S.get("statusLine") is not None and cur.get("statusLine") == S["statusLine"]:
        del cur["statusLine"]
    deny = (cur.get("permissions") or {}).get("deny")
    if isinstance(deny, list):
        cur["permissions"]["deny"] = [r for r in deny if r not in S.get("deny", [])]
    for path in sorted(S.get("created", []), key=lambda s: -s.count(".")):  # inner containers first
        a, _, b = path.partition(".")
        if b and a in cur and cur[a].get(b) == []:
            del cur[a][b]
        elif not b and cur.get(a) == {}:
            del cur[a]
    return cur
settings_after = None
if isinstance(cur, dict):
    try:
        settings_after = unmerge(cur)
    except (AttributeError, TypeError, KeyError) as e:
        sys.exit(f"uninstall.sh: {sp} has an unexpected shape ({e!r}) — fix it and rerun. Nothing was removed.")

dirs = set()
for rel, e in sorted(man.get("files", {}).items()):
    if e.get("preexisting"):
        continue  # you had this exact file before installing
    d = dest / rel
    if d.is_file() or d.is_symlink():
        if d.is_file() and not d.is_symlink() and hashlib.sha256(d.read_bytes()).hexdigest() != e.get("sha"):
            t = kept / rel; t.parent.mkdir(parents=True, exist_ok=True); shutil.move(str(d), t); moved += 1
        else:
            d.unlink(); removed += 1
    if e.get("orig") and os.path.lexists(dest / e["orig"]):  # a backed-up symlink comes back as a symlink
        d.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(dest / e["orig"], d, follow_symlinks=False); restored += 1
    p = d.parent
    while p != dest and dest in p.parents:
        dirs.add(p); p = p.parent

if settings_after is not None:
    keep_copy(sp, "settings.json")
    if S.get("file_created") and settings_after == {}:
        sp.unlink()
    else:
        sp.write_text(json.dumps(settings_after, indent=2, ensure_ascii=False) + "\n")
    print("settings.json: removed the merged hook, statusLine and deny entries")

mp = dest / "CLAUDE.md"
if mp.exists():
    t = mp.read_text(); a = t.find(START); b = t.find(END, a) if a >= 0 else -1
    if b >= 0:
        b += len(END)
        md = man.get("claude_md", {}); pre = md.get("prefix", "")
        if t[b:b + 1] == "\n":
            b += 1
        if pre and t[a - len(pre):a] == pre:
            a -= len(pre)
        t = t[:a] + t[b:]
        keep_copy(mp, "CLAUDE.md")
        if md.get("created") and not t.strip():
            mp.unlink()
        else:
            mp.write_text(t)
        print("CLAUDE.md: removed the claude-orchestra block")

for rc in man.get("rcs", []):
    rp = Path(rc["file"])
    if not rp.exists():
        continue
    lines = rp.read_text().splitlines(keepends=True)
    rest = [l for l in lines if l.rstrip("\n") != rc["line"]]
    if rest != lines:
        keep_copy(rp, "shell-rc/" + rp.name)
        if rc.get("created") and not "".join(rest).strip():
            rp.unlink()
        else:
            rp.write_text("".join(rest))
        print(f"{rp}: removed the PATH line")

MAN.unlink()
for p in sorted(dirs, key=lambda p: -len(p.parts)):
    try:
        p.rmdir()
    except OSError:
        pass  # not empty: holds your own files or run state
print(f"files: {removed} removed, {restored} restored from install backups"
      + (f", {moved} you edited moved to {kept}" if moved else ""))
print("Kept: run state under ~/.claude/orchestra (if any), ~/.claude/backups, the Playwright MCP server.")
PY
