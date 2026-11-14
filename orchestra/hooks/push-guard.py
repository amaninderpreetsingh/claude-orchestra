#!/usr/bin/env python3
"""PreToolUse(Bash) guard for `git push` / `git commit`.

Orchestra worktree = its git dir holds orchestra-owner.json (written by `orch register`).
There, a push is allowed only when ALL hold (otherwise denied with the fix, exit 2):
  1. it is exactly one refspec to the registered branch: git push [-q|-v|-u|-n|-o x] origin HEAD:<target>
  2. HEAD contains the latest origin/<target>       (someone else pushed → rebase first)
  3. `orch gates-ok` was recorded for this exact HEAD (gates run + reviewer/verifier PASS)
  4. this worker holds the repo's merge lock         (pushes are serialized)
Inside an orchestra worktree the guard FAILS CLOSED: any error denies the push.
Outside one, normal push and commit are allowed without a prompt (user, 2026-10-28), except while a recorded
tier change is unshipped (see check_tier): tier S needs passing gates + a reviewer PASS on the pushed commit, and
tier M/L never ships from a main checkout. Force/delete pushes are always denied.
Pushes are parsed like the shell would (backslash-newline joined, quotes removed, git global options before `push`
read, `&>`/`>&`/`>|` kept as redirections); a push it can't parse exactly (unbalanced quotes, $ ` { * ? [ expansion)
is denied in a worker or under a tier record and allowed elsewhere; a force flag or +/: refspec in any brace
alternative is denied outright. The guard never asks: unattended runs can't answer a prompt.
Every `git … push` in the text is a push, except inside a data string (see data_strings: grep -rn "git push" .).
"Inside a worker" is the session's cwd; a worker push command with cd/pushd, or -C elsewhere, is denied.
Threat model for the parser: accidental shortcuts, not a hostile agent — chasing every shell obfuscation is unbounded.
Known limits: data run later (echo "…" > f; ./f), python -c subprocesses, `env -C <dir>` in a worker.
So inside a worker, any command that mentions push AND uses shell indirection ($'…', $VAR, ${…}, $(…), backticks,
{a,b}, eval, xargs, sh/bash -c, alias), or any git push written with a quote/backslash, is denied: write it plainly. Outside workers obfuscation (a quoted or
escaped verb such as git 'push', a shell-built one, args fed by xargs) is out of scope.

Threat model for the tier checks: they stop ACCIDENTAL shortcuts (pushing an unreviewed S change, shipping escalated
M/L work from the main checkout, a copy made by amend/rebase/cherry-pick/merge), not a hostile agent — anything that
can run shell can rewrite orchestra-tier.json. Documented limits: `orch tier --set` (incl. --replace, or re-tiering
M/L as S) replaces an unshipped record without checking what it still binds; a copy kept only in the reflog, a raw
sha, a stash or a patch isn't scanned by `orch tier --clear`; remote-tracking refs are trusted as last fetched.
"""
import codecs, json, os, re, shlex, subprocess, sys
from pathlib import Path

ORCH_HOME = Path(os.environ.get("ORCH_HOME", Path.home() / ".claude" / "orchestra"))
# `git` (bare, by path, after a separator/space/quote), its global options (group g), then the verb
VAL = r"""(?:"[^"]*"|'[^']*'|[^\s;&|"'])+"""
REDIR = rf"(?:\d*|&)(?:>>|>&|>\||>|<)[ \t]*{VAL}"  # a redirection may sit before the verb: git 2>/dev/null push
GIT = (r"(?:^|(?<=[\s;&|(`'\"/\\]))git[\"']?(?P<g>(?>(?:[ \t]+(?:(?:-C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source|--super-prefix)"
       rf"(?:[ \t]+|=){VAL}|--?[A-Za-z][\w-]*(?:={VAL})?|{REDIR}))*))[ \t]+")  # atomic: an option value is never the verb
PUSH = re.compile(GIT + r"push\b")
COMMIT = re.compile(GIT + r"commit\b")
OTHER_REPO = re.compile(r"\bGIT_(?:DIR|WORK_TREE|NAMESPACE|CONFIG\w*)=")


def join_lines(cmd):
    """Backslash-newline continues the command; a bare newline still separates commands."""
    return re.sub(r"\\\r?\n", " ", cmd)


def shell_words(cmd, i):
    """The rest of the simple command from cmd[i]: up to an unquoted ; & | ) ` or newline (`>&`, `&>`, `>|` redirect)."""
    q, j = None, i
    while j < len(cmd):
        ch = cmd[j]
        if q:
            if ch == q:
                q = None
            elif ch == "\\" and q == '"':
                j += 1
        elif ch in "'\"":
            q = ch
        elif ch == "\\":
            j += 1
        elif (ch in ";)`\n" or (ch == "|" and cmd[j - 1:j] != ">")
              or (ch == "&" and cmd[j - 1:j] not in ("<", ">") and cmd[j + 1:j + 2] != ">")):
            break
        j += 1
    return cmd[i:j]


# Data strings: text in a quoted argument of a program that only reads it is not a push (grep -rn "git push" .).
# Not a shell parser: one positively recognised shape is exempt, everything else stays a push (fail closed). Any
# construct that can change how quotes pair or run the text (heredoc/<<<, $'…', $( ${ $[ $" ((, backticks, a comment,
# a multi-line or unbalanced string, a function, an interpreter, read/printf -v capture) voids every exemption.
DATA_PROGS = {"grep", "egrep", "fgrep", "rg", "echo", "printf"}  # not sed/awk: they can run their script (e, system)
NO_DATA = re.compile(r"<<|\$[({\['\"]|`|\(\(|\(\s*\)|\bfunction\b|--pre\b|(?:^|[;&|(\n])\s*\.\s|(?<![\w.-])(?:(?:ba|z|da|k|c|tc|fi)?sh"
                     r"|eval|exec|xargs|source|alias|read|mapfile|readarray|python\d*|perl|ruby|node|php|lua|osascript"
                     r"|[gnm]?awk|g?sed|parallel)(?![\w.-])")  # interpreters/executors a data string could be fed to
PIPE_READERS = {"head", "tail", "wc", "sort", "uniq", "grep", "egrep", "fgrep", "rg", "less", "cat", "cut", "tr"}


def data_strings(cmd):
    """(start, end) of each quoted string that opens and closes on one line and is an argument of a DATA_PROGS word
    (or `git commit` / `git log`) at the start of its simple command."""
    if NO_DATA.search(cmd):
        return []
    spans, q, start, head, i = [], None, 0, 0, 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            if ch == "\\" and q == '"':
                i += 1
            elif ch == q:
                spans.append((start, i + 1, head))
                q = None
            elif ch == "\n":
                return []
        elif ch in "'\"":
            q, start = ch, i
        elif ch == "\\":
            i += 1
        elif ch == "#":
            return []
        elif ch in ";&|()\n":
            # data piped on must reach a reader, not an executor (| at, | sudo -s, | $SHELL, | make -f -)
            if ch == "|" and cmd[i - 1:i] != ">" and cmd[i + 1:i + 2] != "|" and cmd[i - 1:i] != "|":
                nxt = cmd[i + 1:].lstrip("&").split(None, 1)
                if not nxt or nxt[0] not in PIPE_READERS:
                    return []
            head = i + 1
        i += 1
    if q:
        return []
    out = []
    for s, e, h in spans:
        words = cmd[h:s].split()
        if words and (words[0] in DATA_PROGS and not (words[0] == "printf" and any(w.startswith("-v") for w in words))
                      or words[:2] in (["git", "commit"], ["git", "log"])):
            out.append((s, e))
    return out


def blank_data(cmd):
    """cmd with each data string's text blanked (quotes kept), so no push check sees it."""
    for s, e in data_strings(cmd):
        cmd = cmd[:s + 1] + "_" * (e - s - 2) + cmd[e - 1:]
    return cmd


QUOTED, UNQUOTED = str.maketrans("<>", "\x00\x01"), str.maketrans("\x00\x01", "<>")


def mark_quoted(words):
    """words with quoted/escaped < and > swapped for placeholders, so after shlex a real redirection is still told
    apart from a quoted '>' word (which git receives as an argument)."""
    out, q, esc = [], None, False
    for ch in words:
        inside = q is not None or esc
        if esc:
            esc = False
        elif q:
            if ch == q:
                q = None
            elif ch == "\\" and q == '"':
                esc = True
        elif ch in "'\"":
            q = ch
        elif ch == "\\":
            esc = True
        out.append(ch.translate(QUOTED) if inside else ch)
    return "".join(out)


def git(*args, cwd):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout.strip()


def decide(decision, reason):
    if decision == "deny":  # exit 2 blocks before permission rules, in every permission mode
        print(reason, file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": decision,
        "permissionDecisionReason": reason}}))
    sys.exit(0)


def resolve_cwd(data, cmd, dash_c=()):
    cwd = data.get("cwd") or os.getcwd()
    cd = re.match(r"\s*cd\s+(\S+)\s*&&", cmd)
    if cd:
        cwd = os.path.join(cwd, os.path.expanduser(shlex.split(cd.group(1))[0]))
    for d in dash_c:  # each -C is relative to the previous one, like git
        cwd = os.path.join(cwd, os.path.expanduser(d))
    return cwd


def git_globals(gopts):
    """-C dirs of `git <global options>`, and why the push can't be checked (another repo, push-changing config)."""
    toks, dirs, i = shlex.split(gopts), [], 0
    while i < len(toks):
        t, v = toks[i], toks[i + 1] if i + 1 < len(toks) else ""
        name, step = t.split("=", 1)[0], 2 if t in ("-C", "-c", "--config-env", "--attr-source", "--super-prefix") else 1
        if re.match(r"(?:\d*|&)[<>]", t):  # redirection (REDIR); a bare one's target is the next word
            i += 2 if re.fullmatch(r"(?:\d*|&)(?:>>|>&|>\||>|<)", t) else 1
            continue
        if name == "--config-env" and "=" in t:  # --config-env=<name>=<envvar>: the value is attached
            t, v = name, t.split("=", 1)[1]
        if name in ("--git-dir", "--work-tree", "--namespace"):
            return dirs, f"`git {name}` points the push at another repository; cd there and push instead."
        if t == "-C":
            dirs.append(v)
        if t in ("-c", "--config-env") and re.match(r"(remote|push|url|include|includeif)\.", v.split("=", 1)[0].lower()):
            return dirs, f"`git {t} {v}` changes what or where a push sends; set it with git config, not per push."
        i += step
    return dirs, None


def owner_of(cwd):
    rc, gitdir = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=cwd)
    if rc != 0:
        return None, None
    p = Path(gitdir) / "orchestra-owner.json"
    return (json.loads(p.read_text()) if p.exists() else None), Path(gitdir)


def read(p, default):
    return json.loads(p.read_text()) if p.exists() else default


VALUE_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
# long options git also accepts abbreviated (--mirr); any prefix of these, or extension of them, is force/delete
FORCE_LONG = ("force", "force-with-lease", "force-if-includes", "mirror", "delete", "all", "branches", "tags", "prune")
# a worker push may carry only these; the -o/--push-option value is skipped
WORKER_OPTS = {"-q", "--quiet", "-v", "--verbose", "-u", "--set-upstream", "-n", "--dry-run", "--porcelain",
               "--progress", "--no-progress", "--atomic", "-o", "--push-option"}


def is_force(t):
    """A force/delete/mirror flag (any cluster with f or d before -o's value), or a + / :dst refspec."""
    if t.startswith("--"):
        name = t[2:].split("=", 1)[0]
        return bool(name) and any(f.startswith(name) or name.startswith(f) for f in FORCE_LONG)
    if t.startswith("-"):
        flags = t[1:].split("o", 1)[0]
        return "f" in flags or "d" in flags
    return t.startswith("+") or (t.startswith(":") and t != ":")


def push_tokens(toks):
    """(remote + refspecs, options) of a push's words (from mark_quoted): option values and unquoted shell
    redirections dropped."""
    pos, opts, skip, end = [], [], False, False
    for t in toks:
        if skip or (not end and re.match(r"^(?:\d*|&)[<>]", t)):
            skip = not skip and bool(re.fullmatch(r"(?:\d*|&)(>>?|<|>&|>\|)", t))  # bare redirection: target follows
            continue
        t = t.translate(UNQUOTED)
        if t == "--" and not end:
            end = True
        elif t.startswith("-") and not end:
            opts.append(t)
            skip = t in VALUE_OPTS or bool(re.fullmatch(r"-[^-o]*o", t))  # -o / -uo take the next word
        else:
            pos.append(t)
    return pos, opts


# unquoted (non-ASCII) paths; merges list files that differ from every parent, so a merge-carried copy binds
LOG_FILES = ("-c", "core.quotepath=off", "log", "--diff-merges=combined", "--no-renames", "--name-only", "--format=")


def touched(cwd, rev, *base):
    """Files changed by rev's commits not in base (default: on no remote). Renames count as delete + add."""
    rc, out = git(*LOG_FILES, rev, "--not", *(base or ("--remotes",)), cwd=cwd)
    return {f for f in out.splitlines() if f} if rc == 0 else None


def shipped(cwd, tier):
    """The tier change reached its target: its commit is an ancestor, or some target commit since holds the change's
    content for every file it touched (squash-merged PR, rebase-merge, landed identically). Later target commits may
    change those files again; a partial landing doesn't count."""
    x, files, target = tier["sha"], tier.get("files", []), tier["target"]
    if git("merge-base", "--is-ancestor", x, target, cwd=cwd)[0] == 0:
        return True
    rc, out = git("--literal-pathspecs", "rev-list", "--max-count=500", target, "--not", x, "--", *files, cwd=cwd)
    return bool(files) and rc == 0 and any(
        git("--literal-pathspecs", "diff", "--quiet", x, c, "--", *files, cwd=cwd)[0] == 0 for c in out.splitlines())


def bare_push_refs(cwd, matching=False):
    """What a refspec-less `git push [remote]` (or the `:` matching refspec) may send: HEAD, or every local branch when
    matching (`:`, push.default=matching) or a remote.<r>.push refspec is configured."""
    matching = matching or git("config", "push.default", cwd=cwd)[1] == "matching"
    if not matching and git("config", "--get-regexp", r"^remote\..*\.push$", cwd=cwd)[0] != 0:
        return ["HEAD"]
    rc, out = git("for-each-ref", "--format=%(refname)", "refs/heads", cwd=cwd)
    return ["HEAD", *out.splitlines()] if rc == 0 else None


def active_tier(cwd):
    """The repo's unshipped tier record, or None."""
    rc, common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)
    tier = read(Path(common) / "orchestra-tier.json", {}) if rc == 0 else {}
    return tier if tier.get("tier") in ("S", "M", "L") and not shipped(cwd, tier) else None


def check_tier(cwd, gitdir, pos):
    """`orch tier --set S|M|L` binds the committed change (its sha + the files its unpushed commits touch; one record
    per repo, in the git common dir) until it ships: its sha is an ancestor of the target, or a target commit holds its
    content for all those files (see shipped()), or `orch tier --clear` drops it (refused while HEAD or a local branch
    is still bound as below). Until then every ref the push sends is checked — the explicit refspecs' sources, or
    for a bare `git push [remote]` / the `:` refspec HEAD plus, when matching or remote.*.push applies, every branch:
      - contains the change: S needs passing gates + a reviewer PASS on that exact commit; M/L is denied (ship via a
        worker).
      - touches its files without containing it (amend, rebase, cherry-pick, squash): denied until re-tiered (S) or
        until the record ships or is cleared (M/L — a worker's own version of the files never equals the tiered one,
        so after it merges, `orch tier --clear`).
    Unrelated work pushes as today. Remote-tracking refs are read as last fetched; `git fetch` after a merge elsewhere."""
    tier = active_tier(cwd)
    if not tier:
        return
    t = tier["tier"]
    toks = pos[1:]
    explicit = [s.split(":", 1)[0] or "HEAD" for s in toks if s != ":"]
    implied = []
    if not toks or ":" in toks:
        implied = bare_push_refs(cwd, matching=":" in toks)
        if implied is None:
            decide("deny", f"Tier {t} is recorded; can't list the branches a bare push may send. Push an explicit branch.")
    for src in explicit + implied:
        rc, sha = git("rev-parse", "--verify", "--quiet", f"{src}^{{commit}}", cwd=cwd)
        if rc != 0:
            decide("deny", f"Tier {t} is recorded; can't resolve what `{src}` pushes. Push an explicit branch.")
        why = tier_problem(cwd, gitdir, tier, src, sha)
        if why and src not in explicit and src != "HEAD":
            why = (f"This push may also send {src} (bare push under push.default=matching or remote.*.push, or "
                   f"the `:` refspec), and it isn't "
                   f"pushable: {why} Push an explicit refspec instead: git push origin HEAD:<branch>.")
        if why:
            decide("deny", why)


def tier_problem(cwd, gitdir, tier, src, sha):
    t, x, files = tier["tier"], tier["sha"], set(tier.get("files", []))
    ml = ("M/L ship via a worker (orch spawn); use `orch tier --set S --replace` if this is unrelated S work, "
          "or, once the worker merged it, reset the local copies and `orch tier --clear`.")
    if git("merge-base", "--is-ancestor", x, sha, cwd=cwd)[0] == 0:
        return f"{src} ({sha[:10]}) contains the tier-{t} change {x[:10]}. {ml}" if t != "S" else \
            tier_evidence_problem(gitdir, src, sha)
    hit = touched(cwd, sha)
    if hit is None or hit & files:
        what = ("Same change: `orch tier --set S` on it, gates + lite reviewer. Abandoned: reset/delete its copies, then `orch tier --clear`. "
                "Already merged elsewhere: `git fetch` first." if t == "S" else ml)
        return (f"{src} ({sha[:10]}) touches the unshipped tier-{t} change's files "
                f"({', '.join(sorted(hit & files)[:3]) if hit else '?'}) but doesn't contain {x[:10]} "
                f"(amended/rebased/copied?). {what}")
    return None


def tier_evidence_problem(gitdir, src, sha):
    fix = ("run the affected gates (orch gates --cmd ...) and have the reviewer subagent (mode lite) record "
           "its PASS on this commit, then push.")
    gr = read(gitdir / "orchestra-gates-run.json", {})
    if gr.get("sha") != sha or any(x.get("exit") for x in gr.get("results", [])):
        return f"Tier S push needs passing gates on {src} {sha[:10]}: {fix}"
    vs = [v for v in read(gitdir / "orchestra-verdicts.json", []) if v.get("role") == "reviewer" and v.get("sha") == sha]
    if not vs or vs[-1].get("verdict") != "PASS":
        return (f"Tier S push needs a reviewer PASS on {src} {sha[:10]} "
                f"(latest: {vs[-1]['verdict'] if vs else 'none'}): {fix}")
    return None


def deny_force(toks):
    """Force/delete anywhere in a push's words, including inside a brace alternative ({-f,}, {+x,})."""
    for t in toks:
        t = t.translate(UNQUOTED)
        if any(is_force(w) for w in (t, *re.split(r"[{},]", t))):
            decide("deny", "Force/delete/mirror pushes are never allowed. Rebase and push normally.")


# ANSI-C/locale quoting, $VAR ${…} $(…), backticks, brace lists, eval, xargs, sh/bash -c, alias
INDIRECTION = re.compile(r"\$['\"({A-Za-z_]|`|\{[^{}\s]*,[^{}]*\}|\b(?:eval|xargs|alias)\b|\b(?:ba|z|da|k)?sh\s+-c\b")
PUSH_WORD = re.compile(r"(?<![\w-])push(?![\w-])", re.I)  # the verb, not push-guard / pushed


def unquoted(cmd):
    """cmd with $'…' decoded and quotes/backslashes removed: how the shell would spell the words."""
    def ansi(m):
        try:
            return codecs.decode(m.group(1), "unicode_escape")
        except Exception:
            return m.group(1)
    return re.sub(r"[\"'\\]", "", re.sub(r"\$'((?:[^'\\]|\\.)*)'", ansi, cmd))


def check_worker_indirection(data, cmd, raw):
    """Inside a worker, a command that mentions push in any spelling AND uses shell indirection, or a git push written
    with any quote/backslash, is denied instead of parsed (threat model: accidental shortcuts, not a hostile agent;
    parsing every obfuscation is unbounded). The one allowed push needs neither. A `cat <<EOF` body is data (the
    usual heredoc commit message), so it doesn't count unless the opener line pipes it on. cmd has its data strings
    blanked (blank_data): their text and $VAR inside them don't count as indirection or a quoted push, but a push
    mentioned in them still pairs with indirection elsewhere (raw)."""
    # only the body lines go; the opener line stays, and a body piped on (cat <<EOF | sh) is never stripped
    cmd, raw = (re.sub(r"(\bcat\s+<<-?\s*(['\"]?)(\w+)\2[^\n|]*)\n.*?^\s*\3\s*$", r"\1", c, flags=re.S | re.M)
                for c in (cmd, raw))
    # a git push spelled with quotes/backslashes anywhere in its simple command (git 'push', git"" push, -c 'a b')
    quoted = any(re.search(r"[\"'\\]", seg) and PUSH.search(unquoted(seg)) for seg in re.split(r"[;&|\n]", cmd))
    if not quoted and not (INDIRECTION.search(cmd) and (PUSH_WORD.search(raw) or PUSH_WORD.search(unquoted(raw)))):
        return
    for cwd in {data.get("cwd") or os.getcwd(), resolve_cwd(data, cmd)}:
        owner = owner_of(cwd)[0]
        if owner is not None:
            decide("deny", f"Write the push plainly, without shell indirection ($'…', $VAR, ${{…}}, $(…), backticks, "
                           f"{{a,b}}, eval, xargs, sh -c, alias): git push origin HEAD:{owner['target']}")


def check_unmatched_git(data, cmd):
    """`git <options we don't know> push …`: the verb is push (only option-like words, each with at most one value,
    sit between git and it) but PUSH didn't match. Unparseable: deny in a worker or under a tier record, else allow."""
    found = None
    for seg in re.split(r"[;&|\n]", cmd):
        if PUSH.search(seg) or not PUSH_WORD.search(seg):
            continue
        words = seg.split()
        i = next((k + 1 for k, w in enumerate(words) if re.fullmatch(r"(?:\S*/)?git[\"']?", w)), None)
        while i is not None and i < len(words) and re.match(r"-|(?:\d*|&)[<>]", words[i]):
            if re.match(r"(?:\d*|&)[<>]", words[i]):  # redirection; a bare one's target is the next word
                i += 2 if re.fullmatch(r"(?:\d*|&)(?:>>|>&|>\||>|<)", words[i]) else 1
                continue
            value = "=" not in words[i] and words[i + 1:i + 2] and not re.match(r"-|push$", words[i + 1].lower())
            i += 2 if value else 1
        if i is not None and i < len(words) and words[i].lower() == "push":
            deny_force(words[i + 1:])
            for cwd in {data.get("cwd") or os.getcwd(), resolve_cwd(data, cmd)}:
                owner = owner_of(cwd)[0]
                if owner is not None:
                    decide("deny", f"push-guard doesn't know an option before `push`; run it plainly: "
                                   f"git push origin HEAD:{owner['target']}")
                if active_tier(cwd):
                    decide("deny", "A tier record is unshipped and push-guard doesn't know an option before `push`; "
                                   "run it plainly: git push origin <branch>")
            found = "allow", "push with an option push-guard doesn't know, outside a worker (no force, no tier record)"
    return found


CD = re.compile(r"(?<![\w./-])(?:cd|pushd|chdir)(?![\w.-])")


def check_push(data, cmd, m):
    """One `git push` in cmd (match m). Denies (exits); otherwise returns (allow, reason). "Inside a worker" is the
    session's cwd: a worker session can't leave its worktree by cd (any cd/pushd in a worker push command denies)."""
    words, parsed = shell_words(cmd, m.end()), True
    try:
        dirs, other_repo = git_globals(m.group("g"))
    except ValueError:
        dirs, other_repo, parsed = [], None, False
    try:
        toks = shlex.split(mark_quoted(words))
    except ValueError:  # unbalanced quotes etc.: still catch force spelled in the raw words, then fail closed
        toks, parsed = re.sub(r"[\"']", " ", words).split(), False
    deny_force(toks)
    if other_repo or OTHER_REPO.search(cmd):
        decide("deny", other_repo or "GIT_DIR/GIT_WORK_TREE/GIT_NAMESPACE/GIT_CONFIG* in a push command point it "
                                     "elsewhere; cd into the checkout and push plainly.")
    cwd = resolve_cwd(data, cmd, dirs)
    owner, gitdir = owner_of(cwd)
    here = owner_of(data.get("cwd") or os.getcwd())[0]
    lead, rest = re.match(r"\s*cd\s+\S+\s*&&", cmd), cmd  # `cd <own worktree> && git push …` stays fine
    if lead and here is not None and (owner_of(resolve_cwd(data, cmd))[0] or {}).get("owner") == here["owner"]:
        rest = cmd[lead.end():]
    if here is not None and (CD.search(rest) or owner is None or owner["owner"] != here["owner"]):
        decide("deny", f"From a worker, push only your own worktree, without cd/pushd/-C: "
                       f"git push origin HEAD:{here['target']}")
    pos, opts = push_tokens(toks)
    if cmd[m.end() + len(words):][:1] in (")", "`"):  # words cut at a $(…) / backtick: the rest is unseen
        parsed = False
    if not parsed or any(c in t for t in toks for c in "$`{*?["):
        # the words may stop early (at a $(…)'s `)`, a backtick, which may span lines): any force marker in the rest
        # of the command denies
        if any(is_force(w) for w in re.split(r"[\s\"'{},;&|()`$]+", cmd[m.end():]) if w):
            decide("deny", "Force/delete/mirror pushes are never allowed. Rebase and push normally.")
        if owner is not None:
            decide("deny", f"push-guard can't parse this push exactly; run it plainly: git push origin HEAD:{owner['target']}")
        if active_tier(cwd):
            decide("deny", "A tier record is unshipped and push-guard can't parse this push exactly (quoting or shell "
                           "expansion); run it plainly: git push origin <branch>")
        return "allow", "push outside an orchestra worker that push-guard can't parse exactly (no force, no tier record)"
    if owner is None:
        check_tier(cwd, gitdir, pos)
        return "allow", "normal push outside an orchestra worker (tier record checked if any)"
    target = owner["target"]

    bad = [o for o in opts if o.split("=", 1)[0] not in WORKER_OPTS and not re.fullmatch(r"-[qvun]+|-[qvun]*o.*", o)]
    if bad or len(pos) != 2 or pos[0] != "origin" or pos[1] not in (f"HEAD:{target}", f"HEAD:refs/heads/{target}"):
        decide("deny", f"Push exactly your registered branch, nothing else: git push origin HEAD:{target}"
                       + (f" (not allowed in a worker push: {' '.join(bad)})" if bad else ""))

    if git("fetch", "--quiet", "origin", target, cwd=cwd)[0] != 0:
        decide("deny", f"Could not fetch origin/{target}; can't prove you're current. Fix the remote and retry.")
    if git("merge-base", "--is-ancestor", f"origin/{target}", "HEAD", cwd=cwd)[0] != 0:
        decide("deny", f"origin/{target} moved (another worker pushed). Release nothing yet: "
                       f"git rebase origin/{target}, resolve keeping both intents. If HEAD's patch is unchanged, "
                       f"re-run gates + verifier (specs-only); if it changed, also the reviewer. Then orch gates-ok and push.")

    rec_path = gitdir / "orchestra-gates.json"
    rec = json.loads(rec_path.read_text()) if rec_path.exists() else {}
    _, head = git("rev-parse", "HEAD", cwd=cwd)
    if rec.get("sha") != head or rec.get("target") != target:
        decide("deny", f"No gates-ok for HEAD {head[:10]}. Gates + reviewer PASS + verifier PASS on this exact "
                       f"commit, then `orch gates-ok`, then push.")

    _, common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)
    slug = re.sub(r"[^A-Za-z0-9]+", "-", str(Path(common).parent)).strip("-")
    lock = ORCH_HOME / "locks" / slug / "merge" / "owner.json"
    holder = json.loads(lock.read_text()).get("owner") if lock.exists() else None
    if holder != owner["owner"]:
        decide("deny", f"Take the merge lock first: orch merge-lock --owner {owner['owner']} "
                       f"(held by {holder or 'nobody'}).")
    return "allow", f"orchestra: {head[:10]} on top of origin/{target}, gates-ok recorded, merge lock held"


VERDICT = re.compile(r"\borch\s+(verdict|criterion)\b(.*)")
ROLE_AGENTS = {"reviewer": {"reviewer"}, "adversarial": {"reviewer"}, "verifier": {"verifier"}}


def check_evidence_writer(data, cmd):
    """Only the reviewer/verifier subagents may record their own verdicts; workers can't self-certify."""
    m = VERDICT.search(cmd)
    if not m:
        return
    agent = data.get("agent_type") or ""
    if m.group(1) == "criterion":
        allowed = {"verifier"}
    else:
        role = re.search(r"--role[ =](\S+)", m.group(2))
        allowed = ROLE_AGENTS.get(role.group(1) if role else "", set())
    if agent not in allowed:
        decide("deny", f"`orch {m.group(1)}` must be run by the {'/'.join(sorted(allowed)) or '?'} subagent itself "
                       f"(caller: {agent or 'main session'}). Launch that agent; never record evidence yourself.")


CMUX = re.compile(r"\bcmux\s+(?:--\S+\s+\S+\s+)*([a-z-]+)(?:\s+([a-z-]+))?(.*)", re.S)
WORKER_TAGS = ("QUESTION:", "NEEDS_FILES:", "BLOCKED:", "MERGED:", "PROGRESS:", "DONE:")
WORKER_FORBIDDEN = {"send", "send-key", "paste", "new-workspace", "close-workspace", "workspace",
                    "new-split", "new-pane", "claude-teams"}


def check_worker_messaging(data, cmd):
    """Workers only report to their own coordinator, with a tag; they never message or drive anyone else."""
    owner = None
    for cwd in {data.get("cwd") or os.getcwd(), resolve_cwd(data, cmd)}:
        try:
            owner = owner or owner_of(cwd)[0]
        except Exception:
            pass
    if owner is None:
        return
    if re.search(r"\borch\s+broadcast\b", cmd):
        decide("deny", "Workers never message other workers. Report to your coordinator instead.")
    m = CMUX.search(cmd)
    if not m:
        return
    verb, sub, rest = m.group(1), m.group(2) or "", m.group(3)
    if verb in WORKER_FORBIDDEN:
        decide("deny", f"Workers may not run `cmux {verb}` (no driving other terminals/workspaces). "
                       f"Send a tagged report to your coordinator.")
    if verb != "agent" or sub != "message":
        return
    run = json.loads((ORCH_HOME / "runs" / owner["run"] / "run.json").read_text())
    toks = shlex.split(rest)
    target, text, i, reply = None, [], 0, False
    while i < len(toks):
        t = toks[i]
        if t in ("--from", "--thread"):
            i += 2
            continue
        if t == "--reply-to":
            reply, i = True, i + 2
            continue
        if t in ("--json", "--"):
            i += 1
            continue
        if target is None and not reply:
            target = t
        else:
            text.append(t)
        i += 1
    body = " ".join(text).strip()
    if not reply and target != run.get("coordinator"):
        decide("deny", f"Workers only message their coordinator ({run.get('coordinator')}), never other workers.")
    if not body.startswith(WORKER_TAGS):
        decide("deny", f"Worker messages are reports/questions only and must start with one of {', '.join(WORKER_TAGS)} "
                       f"— never instructions to the coordinator.")


def main(data):
    if data.get("tool_name") != "Bash":
        return
    raw = join_lines(data.get("tool_input", {}).get("command", ""))
    check_evidence_writer(data, raw)
    check_worker_messaging(data, raw)
    # joined lines may hide a separator (`\\` + newline is a literal backslash, then a new command): no data strings
    cmd = raw if re.search(r"\\\r?\n", data.get("tool_input", {}).get("command", "")) else blank_data(raw)
    check_worker_indirection(data, cmd, raw)
    ok = [check_push(data, cmd, m) for m in PUSH.finditer(cmd)]  # every push in the command must pass
    ok += filter(None, [check_unmatched_git(data, cmd)])
    if ok:  # never "ask": unattended runs can't answer a prompt
        decide("allow", "; ".join(r for _, r in ok) + ".")
    c = COMMIT.search(cmd)
    if c:
        owner, _ = owner_of(resolve_cwd(data, cmd, git_globals(c.group("g"))[0]))
        if owner is None:
            decide("allow", "git commit outside an orchestra worker: no prompt.")


if __name__ == "__main__":
    data = {}
    try:
        data = json.load(sys.stdin)
        main(data)
    except SystemExit:
        raise
    except Exception as e:
        # Fail closed for pushes inside orchestra worktrees, under a tier record, or with a force/delete marker;
        # elsewhere allow (never ask: unattended runs can't answer).
        cmd = join_lines((data.get("tool_input") or {}).get("command", "") if isinstance(data, dict) else "")
        cwd = (data.get("cwd") if isinstance(data, dict) else None) or os.getcwd()
        try:
            in_orch, tier = owner_of(cwd)[0] is not None, active_tier(cwd)
        except Exception:
            in_orch = tier = True
        if PUSH.search(cmd) or PUSH_WORD.search(unquoted(cmd)):
            if in_orch or tier or any(is_force(w) for w in re.split(r"[\s\"'{},;&|()]+", cmd) if w):
                decide("deny", f"push-guard error ({e}); refusing a push from a worker, under a tier record or "
                               f"with a force/delete marker.")
            decide("allow", f"push-guard error ({e}); plain push outside a worker allowed.")
        if COMMIT.search(cmd) and not in_orch:  # in a worker a commit gets no decision, as on the normal path
            decide("allow", f"push-guard error ({e}); git commit outside a worker allowed.")
