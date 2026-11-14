#!/usr/bin/env bash
# Leak check: fail if any tracked (or new, not ignored) file (binaries/UTF-16 as their text),
# file path, commit author/committer, commit message, tag, or past patch reachable from HEAD
# (merges included) contains a personal identifier or a machine-specific path. Commit identities
# must use a GitHub noreply or reserved test-domain email.
#   usage: [LEAK_REV=<commit>] scripts/leak-check.sh [repo-dir]   (default: this repo, history from HEAD)
# Prints each hit as `file:line  <rule>` (history hits as `history <sha>:file:line  <rule>`),
# never the matched text itself, so CI logs of a public repo don't republish what was found.
# Identifiers live hashed in scripts/leak-patterns.txt (see the comment there for why).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${1:-$HERE/..}" && pwd)"
PATTERNS="${LEAK_PATTERNS:-$HERE/leak-patterns.txt}"
exec python3 - "$REPO" "$PATTERNS" <<'PY'
import hashlib, os, re, subprocess, sys

repo, patterns = sys.argv[1], sys.argv[2]
words, joined = {}, {}
for raw in open(patterns, encoding="utf-8"):
    f = raw.split()
    if not f or f[0].startswith("#"):
        continue
    kind, n, digest, label = f[0], int(f[1]), f[2], (f[3] if len(f) > 3 else f[0])
    {"word": words, "joined": joined}[kind].setdefault(n, {})[digest] = label

# Generic, non-personal rules (written so this file doesn't match itself).
REGEX = [
    (re.compile(r"/use" r"rs/", re.I), "macOS home path"),
    (re.compile(r"/opt/home" r"brew", re.I), "Homebrew path"),
    (re.compile(r"@gm" r"ail\b", re.I), "personal email domain"),
    # Apple Team ID shape: exactly 10 uppercase letters/digits, at least one of each.
    (re.compile(r"(?<![A-Za-z0-9])(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}(?![A-Za-z0-9])"),
     "team-id-like token"),
]
RUN = re.compile(r"[a-z0-9]+")
sha = lambda s: hashlib.sha256(s.encode()).hexdigest()
cache = {}

def substr_hits(run, table):
    key = (id(table), run)
    if key not in cache:
        hit = None
        for n, digests in table.items():
            for i in range(len(run) - n + 1):
                label = digests.get(sha(run[i:i + n]))
                if label:
                    hit = label
                    break
            if hit:
                break
        cache[key] = hit
    return cache[key]

def scan(line):
    """Rule names hit by one line of text (empty list = clean)."""
    hits = [name for rx, name in REGEX if rx.search(line)]
    low = line.lower()
    for run in set(RUN.findall(low)):
        h = substr_hits(run, words)
        if h:
            hits.append(h)
    for run in set(RUN.findall(re.sub(r"[-_.\s]+", "", low))):
        h = substr_hits(run, joined)
        if h:
            hits.append(h)
    return sorted(set(hits))

def git(*args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout

found = 0
def report(where, hits):
    global found
    found += 1
    print(f"{where}  {', '.join(hits)}")

def text_of(data):
    """Lines to scan. Binary data (a NUL early on, e.g. UTF-16 text or an image) is scanned as its
    printable runs with NULs dropped, so UTF-16LE/BE text and strings inside binaries still match."""
    if b"\0" not in data[:8192]:
        return data.decode("utf-8", "replace").splitlines(), False
    flat = data.replace(b"\0", b"").decode("latin-1")
    return re.findall(r"[\x20-\x7e\t]{4,}", flat), True

files = [p for p in git("ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0") if p]
for path in files:
    hits = scan(path)
    if hits:
        report(f"{path}:0 (file name)", hits)
    try:
        data = open(f"{repo}/{path}", "rb").read()
    except (FileNotFoundError, IsADirectoryError):
        continue  # deleted in the working tree, or a submodule
    lines, binary = text_of(data)
    for no, line in enumerate(lines, 1):
        hits = scan(line)
        if hits:
            report(f"{path}:{'0 (binary)' if binary else no}", hits)

NOREPLY = re.compile(r"(?:\d+\+)?([A-Za-z0-9-]+)(?:\[bot\])?@users\.noreply\.github\.com", re.I)
RESERVED = re.compile(r"noreply@github\.com|[^@\s]+@(?:[a-z0-9-]+\.)*(?:example\.(?:com|org|net)|invalid|test|example)", re.I)
TRAILER = re.compile(r"\s*(?:co-authored-by|signed-off-by|reviewed-by|acked-by|tested-by|reported-by)\s*:\s*(.*?)\s*<([^<>]*)>\s*", re.I)

def message_hits(line):
    """A commit/tag message line; identity trailers get the same policy as commit identities."""
    m = TRAILER.fullmatch(line)
    return identity_hits(m.group(1), m.group(2)) if m else scan(line)

def identity_hits(name, email):
    """A commit identity may be any name without listed tokens, with a GitHub
    noreply email (bots included), GitHub's own noreply@github.com, or an address under a reserved
    test domain — never a real mailbox or host."""
    hits = scan(name)
    m = NOREPLY.fullmatch(email.strip())
    if m:
        hits += scan(m.group(1))
    elif RESERVED.fullmatch(email.strip()):
        hits += scan(email)
    else:
        hits += scan(email) + ["identity email is not a GitHub noreply or reserved test address"]
    return sorted(set(hits))

# History (everything reachable from REV or any tag): author/committer identities, commit
# messages, and every added line of every patch, merges included (-m), binaries as text (--text).
# REV is HEAD, or $LEAK_REV — CI sets it to the PR head on pull_request runs, because there HEAD
# is GitHub's synthetic test-merge commit, carrying the PR opener's account identity, which never
# lands in the repo's history.
is_commit = lambda r: subprocess.run(["git", "-C", repo, "rev-parse", "-q", "--verify", r + "^{commit}"],
                                     capture_output=True).returncode == 0
rev = os.environ.get("LEAK_REV", "").strip()
if rev and not is_commit(rev):  # fail closed: a wrong LEAK_REV must never skip the history scan
    print(f"leak-check: LEAK_REV={rev} is not a commit in this repo — history not scanned", file=sys.stderr)
    sys.exit(2)
rev = rev or "HEAD"
if is_commit(rev):  # only an empty repo (no HEAD yet) has no history to scan
    meta = git("log", "--no-color", "--format=%H%x01%an%x01%ae%x01%cn%x01%ce%x01%B%x02", rev, "--tags").decode("utf-8", "replace")
    for rec in meta.split("\x02"):
        rec = rec.lstrip("\n")
        if not rec:
            continue
        commit, an, ae, cn, ce, body = rec.split("\x01", 5)
        commit = commit[:7]
        for role, (n, e) in (("author", (an, ae)), ("committer", (cn, ce))):
            hits = identity_hits(n, e)
            if hits:
                report(f"history {commit}:({role})", hits)
        for no, line in enumerate(body.replace("\0", "").splitlines(), 1):
            hits = message_hits(line)
            if hits:
                report(f"history {commit}:(message):{no}", hits)
    tags = git("for-each-ref", "refs/tags", "--format=%(objecttype)%01%(refname:short)%01%(taggername)%01"
               "%(taggeremail:trim)%01%(contents:subject)%0a%(contents:body)%02").decode("utf-8", "replace")
    for rec in tags.split("\x02"):
        rec = rec.lstrip("\n")
        if not rec:
            continue
        kind, tag, tn, te, body = rec.split("\x01", 4)
        if kind == "tag":  # annotated: has a tagger; tagged commits are in the logs above (--tags)
            hits = identity_hits(tn, te)
            if hits:
                report(f"tag {tag}:(tagger)", hits)
        for no, line in enumerate([tag] + body.splitlines()):
            hits = message_hits(line)
            if hits:
                report(f"tag {tag}:{no}", hits)
    log = git("log", "-p", "-m", "--text", "--no-textconv", "--no-color", "--no-ext-diff",
              "--format=%x00commit %H", rev, "--tags").decode("utf-8", "replace")
    commit, path, new, header = "?", "?", 0, True
    for line in log.split("\n"):
        if line.startswith("\0commit "):
            commit, header = line[8:15], True
            continue
        if line.startswith("diff --git ") or line.startswith("diff --cc "):
            path, header = line.split(" b/", 1)[-1], True
            hits = scan(path)
            if hits:
                report(f"history {commit}:{path} (file name)", hits)
            continue
        m = re.match(r"@@+ -\d+(?:,\d+)? .*?\+(\d+)", line)
        if m:
            new, header = int(m.group(1)) - 1, False
            continue
        if header:
            continue  # ---/+++/index/mode lines
        if line.startswith("+"):
            new += 1
            hits = scan(line[1:].replace("\0", ""))
            if hits:
                report(f"history {commit}:{path}:{new}", hits)
        elif line.startswith(" "):
            new += 1

if found:
    print(f"leak-check: {found} hit(s) — remove them (and rewrite any commit that carries one) before pushing")
    sys.exit(1)
print(f"leak-check: clean ({len(files)} files + history)")
PY
