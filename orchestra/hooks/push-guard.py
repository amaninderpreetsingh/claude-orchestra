#!/usr/bin/env python3
"""PreToolUse(Bash) guard for `git push` / `git commit`.

Orchestra worktree = its git dir holds orchestra-owner.json (written by `orch register`).
There, a push is allowed only when ALL hold (otherwise denied with the fix, exit 2):
  1. it is exactly one refspec to the registered branch: git push [-q|-v|-u|-n|-o x] origin HEAD:<target>
  2. HEAD contains the latest origin/<target>       (someone else pushed → rebase first)
  3. `orch gates-ok` was recorded for this exact HEAD (gates run + reviewer/verifier PASS)
  4. this worker holds the repo's merge lock         (pushes are serialized)
  5. it is the whole command: a worker push chained/piped with anything else is denied (one plain command)
Inside an orchestra worktree the guard FAILS CLOSED: any error denies the push.
Outside one, only a push or commit that is one plain command run by git itself is allowed without a prompt (user,
2026-10-28; see git_itself); a compound one, or git wrapped by bash -c/eval/ssh/sudo or pointed at another program,
gets no decision, so the user's own permission rules apply (auto mode avoids prompts in unattended runs); except while
a recorded tier change is unshipped (see check_tier): tier S needs passing gates + a reviewer PASS on the pushed commit, and
tier M/L never ships from a main checkout. Force/delete pushes are always denied.
Pushes are parsed like the shell would (backslash-newline joined, quotes removed, git global options before `push`
read, `&>`/`>&`/`>|` kept as redirections); a push it can't parse exactly (unbalanced quotes, $ ` { * ? [ expansion)
is denied in a worker or under a tier record and allowed elsewhere; a force flag or +/: refspec in any brace
alternative is denied outright. The guard never asks: unattended runs can't answer a prompt.
Every `git … push` in the text is a push, except inside a data string (see data_strings: grep -rn "git push" .).
"Inside a worker" is the session's cwd; a worker push command with cd/pushd, or -C elsewhere, is denied.
Threat model for the parser: accidental shortcuts, not a hostile agent — chasing every shell obfuscation is unbounded.
Known limits: data run later (echo "…" > f; ./f), python -c subprocesses, `env -C <dir>` in a worker.
Where a push runs is followed through ; && || newline, { } / if bodies, ( … ) / $( … ) scopes, quoted dirs, cd -- and
pushd/popd (cwd_at); a cd it can't resolve ($X, -, a glob, a missing dir, one inside quotes such as bash -c "cd x && …")
makes the checkout unknown: denied in a worker, or when any checkout it may run in is a worker or has a tier record.
So does a cd that may not run: inside an if/while/until/for/select/case or function body, next to ||, or after &&
once that && chain ends (false && cd x; git push). A cd inside cmux-typed text (cmux send "cd <worktree> && …") adds
only non-worker candidates: it binds tier records, not the coordinator's worker instructions.
So inside a worker, any command that mentions push AND uses shell indirection ($'…', $VAR, ${…}, $(…), backticks,
{a,b}, eval, xargs, sh/bash -c, alias), or any git push written with a quote/backslash, is denied: write it plainly. Outside workers obfuscation (a quoted or
escaped verb such as git 'push', a shell-built one, args fed by xargs) is out of scope.
Outside workers the guard never allows a compound command (chained, piped, a subshell or $( … ), a heredoc fed to
anything but cat/git/tee): it gives no decision, so the user's own permission rules (ask/deny) still cover the rest of
the command (an allow would approve `git commit -m x && rm -rf build` whole). Nor one whose program isn't git itself
(bash -c / sh -c / eval / ssh / sudo … run quoted text it can't vouch for), a grep that only reads aside, nor git
pointed at another program or file: an env prefix other than LC_*/LANG/TZ (GIT_SSH_COMMAND=, PATH=), -c with a key
other than color.*/advice.*/core.quotepath/user.name/user.email, --config-env/--exec-path, push --receive-pack/--exec
(any abbreviation), a redirection into a file (/dev/null and &N aside), or a backgrounded command (&). Inside a worker a compound command
holding a push is denied (workers run unattended, a prompt would stall them): push with one plain command.
Every cmux command a worker runs is checked (each ; && || | & newline segment), and every `orch verdict|criterion`
call with every --role; text only a reader program reads (READERS: a cat/git heredoc, echo/printf/grep/…, a commit
message, orch --summary, a cmux report) isn't a call — except where RUNS_ARGS lists a subcommand/flag that runs it
(orch gates/baseline --cmd, git grep -O, rg --pre, gh alias); any other program's quoted text is searched as text.
Deadline: Claude Code runs the command when a hook times out (settings.json gives it 60s) or python3 is missing, so
python3 is required and the guard keeps its own clock: about 45s overall (ORCH_GUARD_DEADLINE may lower it, never raise
it); out of time inside a worker, under a tier record, or when it can't tell, a push or a worker's cmux call is denied.

Known limits of the parser (deliberate bypasses by a hostile local agent; out of scope, not fixed): a cd target it
can't know ($d from a loop or set earlier in the same command, xargs-built), env -C <dir>, zsh-only cd/pushd flags
(-q) and ~+ paths, a reader program that runs text by a route not in RUNS_ARGS, text written to a file and run later,
$'…'/variable-built verbs outside workers, orch held in a variable other than $ORCH or fed its subcommand by xargs,
and cmux spelled in another case (CMUX on a case-insensitive volume), a cd target built by $(pwd) (only $PWD and
$(git rev-parse --show-toplevel) are guessed), an absolute path to a program named git, and --git-dir=<repo>
running that repo's hooks, a cat heredoc body inside an unquoted $( … ) / <( … ) (its output runs, but the body is
read as data), printf -v capture later run by eval, and pushd -n / popd -n (taken as a cd; -n only edits the stack).
Most get no decision (the user's rules apply);
env -C and text run later are still allowed, as before this parser. The other way, a worker's non-reader command
quoting a cmux verb (sed 's/cmux send/…/', python -c "…cmux send…") is denied: its text may run; and a cd named
in a multi-line git commit -m "…" or a gh … --body "…" text can make a worker worktree a candidate, denying the
coordinator's commit/PR (fails closed; write the message to a file: git commit -F file, gh … --body-file file).
Also open (follow-up): a worker's `orch broadcast` is a case-sensitive text match, so $ORCH/${ORCH} broadcast isn't
caught (as before this parser), while grep/commit text naming it is denied. Fail-closed false denies: the
coordinator's cmux send after visiting a worktree ((cd <wt> && …) or pushd/popd) is checked as a worker's; a worker
report with a $( … ) in its text, a cmux argument value equal to a forbidden verb (--body send), a worker push with a
trailing # comment, and a verdict with a $( … ) argument plus a --summary naming a verdict call are denied. Cost:
each cmux command re-parses the text before it, so a coordinator command with hundreds of cmux lines can reach the
deadline (fails closed in a worker or under a tier record).

Threat model for the tier checks: they stop ACCIDENTAL shortcuts (pushing an unreviewed S change, shipping escalated
M/L work from the main checkout, a copy made by amend/rebase/cherry-pick/merge), not a hostile agent — anything that
can run shell can rewrite orchestra-tier.json. Documented limits: `orch tier --set` (incl. --replace, or re-tiering
M/L as S) replaces an unshipped record without checking what it still binds; a copy kept only in the reflog, a raw
sha, a stash or a patch isn't scanned by `orch tier --clear`; remote-tracking refs are trusted as last fetched.
"""
import codecs, json, os, re, shlex, signal, subprocess, sys, time
from pathlib import Path

ORCH_HOME = Path(os.environ.get("ORCH_HOME", Path.home() / ".claude" / "orchestra"))
try:  # the overall budget; tests lower it, nothing raises it past the hook's own 60s timeout
    DEADLINE = max(1.0, min(45.0, float(os.environ.get("ORCH_GUARD_DEADLINE") or 45)))
except ValueError:
    DEADLINE = 45.0
START, RESERVE = time.monotonic(), DEADLINE / 6  # the checks get DEADLINE - RESERVE, the fail-closed fallback the rest
PHASE = {"reserve": RESERVE}


class Deadline(Exception):
    pass


def left():
    """Seconds the current phase (checks, then fallback) may still spend."""
    return START + DEADLINE - PHASE["reserve"] - time.monotonic()


def _alarm(*_):
    raise Deadline()


def arm(seconds):
    """Interrupt whatever runs (a git call, a slow parse) once seconds pass."""
    if hasattr(signal, "setitimer"):
        signal.signal(signal.SIGALRM, _alarm)
        signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.01))


def disarm():
    if hasattr(signal, "setitimer"):
        signal.setitimer(signal.ITIMER_REAL, 0)
# `git` (bare, by path, after a separator/space/quote), its global options (group g), then the verb
VAL = r"""(?:"[^"]*"|'[^']*'|[^\s;&|"'])+"""
REDIR = rf"(?:\d*|&)(?:>>|>&|>\||>|<)[ \t]*{VAL}"  # a redirection may sit before the verb: git 2>/dev/null push
GIT = (r"(?:^|(?<=[\s;&|(`'\"/\\]))git[\"']?(?P<g>(?>(?:[ \t]+(?:(?:-C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source|--super-prefix)"
       rf"(?:[ \t]+|=){VAL}|--?[A-Za-z][\w-]*(?:={VAL})?|{REDIR}))*))[ \t]+")  # atomic: an option value is never the verb
PUSH = re.compile(GIT + r"push\b")
COMMIT = re.compile(GIT + r"commit\b")
OTHER_REPO = re.compile(r"\bGIT_(?:DIR|WORK_TREE|NAMESPACE|CONFIG\w*)=")


def join_lines(cmd):
    """Backslash-newline continues the command; a bare newline still separates commands, and so does one after an
    escaped backslash (`\\` + newline is a literal backslash, then a new command)."""
    return re.sub(r"(?<!\\)((?:\\\\)*)\\\r?\n", r"\1 ", cmd)


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


def quoted_args(cmd, void=NO_DATA, pipes=True):
    """(start, end, start of its simple command) of each quoted string that opens and closes on one line, or [] when
    quoting can change how strings pair or what runs them (void: NO_DATA; a comment; with pipes, a pipe into a
    non-reader)."""
    if void.search(cmd):
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
            if pipes and ch == "|" and cmd[i - 1:i] != ">" and cmd[i + 1:i + 2] != "|" and cmd[i - 1:i] != "|":
                nxt = cmd[i + 1:].lstrip("&").split(None, 1)
                if not nxt or nxt[0] not in PIPE_READERS:
                    return []
            head = i + 1
        i += 1
    return [] if q else spans


def is_agent_message(words):
    """`cmux agent message …`: its text goes to another agent's session, which runs it under its own guard. Every
    other cmux subcommand's text (send, new-workspace --command, …) is typed into or run by a shell: not data."""
    return bool(words) and words[0].rsplit("/", 1)[-1] == "cmux" and words[1:3] == ["agent", "message"]


def data_strings(cmd, void=NO_DATA):
    """(start, end) of each quoted string that opens and closes on one line and is an argument of a DATA_PROGS word,
    `git commit` / `git log` or `cmux agent message` at the start of its simple command (void: see quoted_args)."""
    out = []
    for s, e, h in quoted_args(cmd, void):
        words = cmd[h:s].split()
        if words and (words[0] in DATA_PROGS and not (words[0] == "printf" and any(w.startswith("-v") for w in words))
                      or words[:2] in (["git", "commit"], ["git", "log"]) or is_agent_message(words)):
            out.append((s, e))
    return out


PAIRING = re.compile(r"<<|\$[({\['\"]|`")  # what can change how quotes pair (heredocs, $( ${ $' $", backticks)
READ_PAIRING = re.compile(PAIRING.pattern + r"|[<>]\(")  # …or feed a reader's output on (<( … ) / >( … ))


def cmux_quotes(cmd):
    """(start, end) of each quoted argument of a cmux command (typed or sent to another session); only where quotes
    pair plainly (not the NO_DATA test: it marks where text goes; cwd_at drops only worker guesses from it)."""
    return [(s, e) for s, e, h in quoted_args(cmd, PAIRING, pipes=False) if cmd[h:s].split()[:1]
            and cmd[h:s].split()[0].rsplit("/", 1)[-1] == "cmux"]


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
    budget = min(30.0, left())
    if budget <= 0:
        raise Deadline()
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=budget)
    except subprocess.TimeoutExpired:
        raise Deadline() from None
    return r.returncode, r.stdout.strip()


def decide(decision, reason):
    disarm()
    if decision == "deny":  # exit 2 blocks before permission rules, in every permission mode
        print(reason, file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": decision,
        "permissionDecisionReason": reason}}))
    sys.exit(0)


def commands(text):
    """How the shell splits text into simple commands, quote-aware (a ; ( | inside quotes doesn't split). Returns
    (events, heredocs, bad): events are ("cmd", text, sep, offset) with sep one of ; && || | & ( ) ` end, ("(", kind) opening a
    scope (kind "$" for $( … ) / backticks / <( … ) / >( … ), whose output is used; "(" for a subshell) and (")",)
    closing one; heredocs are (index of their command's event, body start, body end, delimiter quoted) in text; bad
    means quoting push-guard can't follow (unbalanced, an unterminated heredoc, $( or a backtick inside "…")."""
    ev, docs, pending, bad, q, start, i, tick = [], [], [], False, None, 0, 0, False
    note = [None]  # where a comment began in the current command

    def cut(j, sep):
        end = note[0] if note[0] is not None and start <= note[0] < j else j
        ev.append(("cmd", text[start:end], sep, start))
        note[0] = None

    while i < len(text):
        ch = text[i]
        if q:
            if ch == q:
                q = None
            elif q == '"' and ch == "\\":
                i += 1
            elif q == '"' and (ch == "`" or text.startswith("$(", i)):
                bad = True
            i += 1
            continue
        if ch in "'\"":
            q, i = ch, i + 1
            continue
        if ch == "\\":
            i += 2
            continue
        if ch == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):  # a comment, to the end of the line
            nl = text.find("\n", i)
            note[0], i = i, len(text) if nl < 0 else nl
            continue
        if text.startswith("<<<", i):  # a here-string: one word, not a heredoc
            i += 3
            continue
        if text.startswith("<<", i):
            h = re.match(r"<<(-?)[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|([^\s;&|<>()]+))", text[i:])
            if h:
                word = h.group(4)
                quoted = word is None or bool(re.search(r"[\"'\\]", word))
                delim = re.sub(r"[\"'\\]", "", word) if word is not None else next(
                    g for g in h.groups()[1:3] if g is not None)
                pending.append((delim, quoted, len(ev), bool(h.group(1))))
                i += h.end()
                continue
        if ch in ";\n":
            cut(i, ";")
            i += 1
            if ch == "\n":
                for delim, quoted, idx, dash in pending:  # bodies start on the next line, in order; only the exact
                    b, end = i, None                      # delimiter line ends one (<<- strips leading tabs), as bash
                    while i < len(text):
                        nl = text.find("\n", i)
                        nl = len(text) if nl < 0 else nl
                        line, i = text[i:nl], min(nl + 1, len(text))
                        if (line.lstrip("\t") if dash else line) == delim:
                            end = nl - len(line)
                            break
                    docs.append((idx, b, len(text) if end is None else end, quoted))
                    bad = bad or end is None
                pending = []
            start = i
            continue
        if text.startswith("&&", i) or text.startswith("||", i):
            cut(i, text[i:i + 2])
            i += 2
            start = i
            continue
        if ch == "|" and text[i - 1:i] != ">":
            cut(i, "|")
        elif ch == "&" and text[i - 1:i] not in ("<", ">") and text[i + 1:i + 2] != ">":
            cut(i, "&")
        elif ch == "$" and text[i + 1:i + 2] == "(":
            cut(i, "(")
            ev.append(("(", "$"))
            i += 1
        elif ch == "(":
            cut(i, "(")
            ev.append(("(", "$" if text[i - 1:i] in ("<", ">") else "("))  # <( … ) / >( … ): output is used
        elif ch == ")":
            cut(i, ")")
            ev.append((")",))
        elif ch == "`":
            cut(i, "`")
            ev.append((")",) if tick else ("(", "$"))
            tick = not tick
        else:
            i += 1
            continue
        i += 1
        start = i
    cut(len(text), "end")
    return ev, docs, bad or q is not None or tick or bool(pending)


KEYWORDS = {"{", "}", "!", "if", "then", "do", "else", "elif", "while", "until", "time", "builtin", "command"}


def words_of(seg):
    """A simple command's words, quotes removed, without leading keywords ({, if, then, …) and VAR=value prefixes."""
    try:
        toks = shlex.split(seg)
    except ValueError:
        toks = re.sub(r"[\"'\\]", " ", seg).split()
    while toks and (toks[0] in KEYWORDS or re.fullmatch(r"[A-Za-z_]\w*=.*", toks[0])):
        toks.pop(0)
    return toks


CD = re.compile(r"(?<![\w./-])(?:cd|pushd|chdir)(?![\w.-])")
POPD = re.compile(r"(?<![\w./-])popd(?![\w.-])")
UNSURE_DIR = re.compile(r"[$`*?\[{]|^~[^/]|^-$|^[+-]\d")  # $X, a glob/brace, ~user, cd -, pushd +1
OPENS, CLOSES = {"if", "while", "until", "for", "select", "case"}, {"fi", "done", "esac"}
FUNC = re.compile(r"(?<![\w.:-])function\s+[\w.:-]+|[\w.:-]+[ \t]*\([ \t]*\)")  # a function definition: its body
# runs only when called


def cwd_at(data, cmd, pos=None, dash_c=()):
    """(cwd, candidates): the directory the command at cmd[pos] runs in (None: can't tell), and every directory the
    command may run in (the session cwd, each cd/pushd/popd/chdir target, -C dirs; a best guess for one it can't
    resolve). Follows ; && || newline, { } and if/while bodies; a cd inside ( … ) / $( … ) / backticks ends with them;
    a cd next to a pipe may or may not take effect (zsh runs the last pipeline element in the shell), nor one after ||
    (it runs only if the command before failed), one before || or inside an if/while/until/for/select/case or a
    function body, nor one after && once the && chain ends (; || & newline); one backgrounded by & doesn't. A cd it can't read ($X, -, ~user, a
    glob, $( … ), a missing dir, one it can't see as a command such as bash -c "cd x && …") makes the cwd unknown;
    cd $(git rev-parse --show-toplevel) adds the repo root as a candidate."""
    base = data.get("cwd") or os.getcwd()
    text = cmd if pos is None else cmd[:pos]
    cands, cwd, stack, dirs, seen, prev, depth, cond, cases = {base}, base, [], [], 0, ";", 0, False, 0
    func = next((m.start() for m in FUNC.finditer(text)), len(text))

    def guess(word, at, typed=False):  # $PWD is the session cwd, $HOME/… the hook's environment (the shell's, usually)
        w = re.sub(r"\$(?:PWD\b|\{PWD\})", lambda _: base, re.sub(r"[\"'\\]", "", word))
        w = os.path.expanduser(os.path.expandvars(w))
        for root in {at or base, base}:
            p = os.path.normpath(os.path.join(root, w))
            # text typed into another session (cmux send "cd <wt> && ...") or only read (echo "cd <wt>") binds a tier
            # record, not worker rules
            if os.path.isdir(p) and not (typed and owner_of(p)[0] is not None):
                cands.add(p)

    events, unknown_at = commands(text)[0], None
    for n, e in enumerate(events):
        if e[0] == "(":
            stack.append((cwd, list(dirs), cond))
            continue
        if e[0] == ")":
            if cases:  # a case pattern's `x)` (or a scope closing inside a case body): don't pop; where it runs is unsure
                cwd = None
                continue
            if stack:
                cwd, dirs, cond = stack.pop()
            if unknown_at == len(stack):  # the $( … ) a cd took its target from has closed
                cwd, unknown_at = None, None
            continue
        seg, sep = e[1], e[2]
        toks, was, prev = words_of(seg), prev, sep
        for t in seg.split():  # if/while/.../case bodies may not run: a cd inside one may or may not take effect
            if t in OPENS:
                depth, cases = depth + 1, cases + (t == "case")
            elif t in CLOSES:
                depth, cases = max(0, depth - 1), max(0, cases - (t == "esac"))
            elif t not in KEYWORDS:
                break
        ends = sep in (";", "||", "&")  # the end of an && chain: a cd that ran only if its head succeeded is unsure
        if not toks or toks[0] not in ("cd", "chdir", "pushd", "popd"):
            if cond and ends:
                cwd, cond = None, False
            continue
        seen += 1
        if sep in ("(", "`"):  # cd $(…) / cd `…`: the target is computed; the repo root is the usual one
            inner = events[n + 2][1].strip() if n + 2 < len(events) and events[n + 2][0] == "cmd" else ""
            if inner == "git rev-parse --show-toplevel" and cwd and owner_of(cwd)[1] is not None:
                if ("top", cwd) not in GITDIRS:
                    GITDIRS["top", cwd] = git("rev-parse", "--show-toplevel", cwd=cwd)
                rc, top = GITDIRS["top", cwd]
                if rc == 0:
                    cands.add(top)
            unknown_at = len(stack)
            continue
        verb, rest, done, skip = toks[0], [], False, False
        for a in toks[1:]:
            if skip:
                skip = False
            elif not done and a == "--":
                done = True
            elif re.match(r"(?:\d*|&)[<>]", a):  # a redirection (cd 2>/dev/null x / cd > /dev/null x / cd &>/dev/null x)
                skip = bool(re.fullmatch(r"(?:\d*|&)(?:>>?|<|>&)", a))  # a bare one: its target is the next word
                continue
            elif not done and re.fullmatch(r"-[LPe@n]+", a):
                continue
            else:
                rest.append(a)
                done = True
        new = None
        if verb == "popd":
            new = dirs.pop() if dirs and not rest else None
        elif not rest:
            new = None if verb == "pushd" else os.path.expanduser("~")
        elif UNSURE_DIR.search(rest[0]) or (cwd is None and not os.path.isabs(os.path.expanduser(rest[0]))):
            guess(rest[0], cwd)
        else:
            p = os.path.normpath(os.path.join(base if cwd is None else cwd, os.path.expanduser(rest[0])))  # abs if None
            new = p if os.path.isdir(p) else None
            if new is None:
                guess(rest[0], cwd)
        if new:
            cands.add(new)
        if sep == "&":  # backgrounded: runs in a subshell, the shell's cwd stays
            continue
        if verb == "pushd" and new and cwd:
            dirs.append(cwd)
        if "|" in (sep, was) or "||" in (sep, was) or depth or e[3] > func:  # after ||: only if the last command
            cwd, cond = None, False  # failed; before ||: what follows may run after it failed
        else:
            cwd, cond = new, cond or was == "&&"
            if cond and ends:
                cwd, cond = None, False
    inert = inert_text(cmd)[:len(text)]  # the whole command: text may stop inside a quote or a body
    if len(CD.findall(inert)) + len(POPD.findall(inert)) > seen:
        cwd = None  # a cd/pushd it didn't follow as a command (inside quotes, a heredoc body, bash -c "…", eval)
        # typed into another session, or only read (echo, git log; not piped into a runner, not fed on by <( … ))
        typed = cmux_quotes(cmd) + data_strings(cmd, READ_PAIRING)
        for m in CD.finditer(inert):
            w = re.match(r"\s+(?:-[LPe@n]+\s+)*(?:--\s+)?([^\s;&|()]+)", text[m.end():])
            if w:
                guess(w.group(1), None, any(s < m.start() < e for s, e in typed))
    for d in dash_c:  # each -C is relative to the previous one, like git
        if cwd is None or UNSURE_DIR.search(d):
            guess(d, cwd)
            cwd = None
            continue
        cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(d)))
    if cwd:
        cands.add(cwd)
    return cwd, cands


# "$(cat <<'EOF' … EOF)" as an argument (the usual commit message): one quoted word, its body only read by cat
ARG_HEREDOC = re.compile(r"""(?<=[^\s;&|(][ \t])"\$\([ \t]*cat[ \t]+<<(-)?[ \t]*(['"]?)(\w+)\2[ \t]*\n"""
                         r"""((?:(?!^(?(1)\t*)\3$).)*?)^(?(1)\t*)\3\n[ \t]*\)\"""", re.S | re.M)  # the body never
# holds its exact delimiter line (<<- strips tabs only): the first one ends it, and only `)"` may follow
RUNS = re.compile(r"\$\(|`")


def arg_is_data(cmd, m):
    """The "$(cat <<'EOF' … EOF)" argument m runs nothing (a quoted delimiter or no $( … ) / backticks in the body) and
    the command taking it only stores it: git commit/tag, gh (not gh alias; never echo/printf, bash -c, eval …)."""
    if not (m.group(2) or not RUNS.search(m.group(4))):
        return False
    seg = re.split(r"[;&|(\n]", cmd[:m.start()])[-1]
    w = words_of(seg)
    return bool(w[:2] in (["git", "commit"], ["git", "tag"]) or (w and w[0] == "gh")) and reads_only(seg)


def arg_heredocs(cmd):
    """cmd with each "$(cat <<'EOF' … EOF)" argument that is data (arg_is_data) replaced by "_"."""
    return ARG_HEREDOC.sub(lambda m: '"_"' if arg_is_data(cmd, m) else m.group(0), cmd)


def doc_is_data(ev, k, text, b, e, quoted):
    """A heredoc body only read: fed to cat or a git reader subcommand (commit -F -, …) at the start of its command,
    not piped on, with a quoted delimiter or no $( … ) / backticks in it."""
    return command_word(ev[k][1])[1] in ("cat", "git") and reads_only(ev[k][1]) \
        and ev[k][2] in (";", "&&", "||", "&", "end") and (quoted or not RUNS.search(text[b:e]))


def piped_to_runner(ev):
    """Something is piped into a program that isn't a PIPE_READER (| sh, | bash, | xargs …)."""
    cmds = [e for e in ev if e[0] == "cmd"]
    return any(a[2] == "|" and command_word(b[1])[1] not in PIPE_READERS for a, b in zip(cmds, cmds[1:]))


INERT = {}  # cmd → inert_text(cmd): cwd_at reads it once per push


def inert_text(cmd):
    """cmd with every body that is only data (arg_is_data / doc_is_data) blanked to the same length, so a cd named in a
    commit or PR message isn't counted as one; nothing is blanked when it is piped into a runner or can't be parsed."""
    if cmd not in INERT:
        out = cmd
        for m in ARG_HEREDOC.finditer(cmd):
            if arg_is_data(cmd, m):
                b, e = m.span(4)
                out = out[:b] + re.sub(r"[^\n]", "_", out[b:e]) + out[e:]
        ev, docs, bad = commands(cmd)
        if not bad and not piped_to_runner(ev):
            for k, b, e, quoted in docs:
                if doc_is_data(ev, k, cmd, b, e, quoted):
                    out = out[:b] + re.sub(r"[^\n]", "_", out[b:e]) + out[e:]
        INERT[cmd] = out
    return INERT[cmd]


def parsed(cmd):
    """(text with the commit-message idiom made inert, events, heredocs, bad) — commands() of arg_heredocs(cmd)."""
    t = arg_heredocs(cmd).strip()
    return (t, *commands(t))


def compound(cmd, p=None):
    """More than one command: chained, piped, backgrounded (its failure is lost), a subshell or a $( … ) / backtick
    (except the "$(cat <<'EOF' … EOF)" argument idiom), a heredoc fed to anything but cat/git/tee or one whose
    unquoted body runs a substitution — or quoting push-guard can't follow. p: parsed(cmd), if already made."""
    t, ev, docs, bad = p or parsed(cmd)
    if bad or any(e[0] != "cmd" or e[2] == "&" for e in ev) or sum(bool(e[1].strip()) for e in ev) > 1:
        return True
    return any((words_of(ev[k][1]) or [""])[0] not in ("cat", "git", "tee") or (not quoted and RUNS.search(t[b:e]))
               for k, b, e, quoted in docs)


RUNNING_OPTS = ("--receive-pack", "--exec", "--upload-pack")
GIT_VALUE_OPTS = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--attr-source", "--super-prefix"}
SAFE_CONFIG = re.compile(r"(?:color|advice)\.[\w.-]+|core\.quotepath|user\.(?:name|email)", re.I)  # run nothing


def git_itself(cmd):
    """One simple command whose program is git itself (not bash -c / sh -c / eval / ssh / sudo … around it), or a
    grep that only reads (no redirection, nothing in RUNS_ARGS): the only command push-guard may allow outright outside
    a worker."""
    p = parsed(cmd)
    if compound(cmd, p):
        return False
    t, ev, docs, _ = p
    words = t
    for _, b, e, _ in docs:  # a body is read, not redirection text
        words = words[:b] + " " * (e - b) + words[e:]
    try:
        toks = shlex.split(words)
    except ValueError:
        return False
    while toks and re.fullmatch(r"(?:LC_\w+|LANG|TZ)=.*", toks[0]):  # only locale prefixes: GIT_SSH_COMMAND=, PATH=,
        toks.pop(0)                                                  # DYLD_*= … make it run another program
    plain = re.sub(r"\"(?:[^\"\\]|\\.)*\"|'[^']*'", "", words)
    if not toks or ">" in re.sub(r"(?:\d*|&)>>?[ \t]*(?:/dev/null(?![^\s;&|])|&[\d-])", "", plain):
        return False  # writes a file (git commit > ~/.zshrc)
    if toks[0] == "git" or (toks[0].startswith("/") and toks[0].endswith("/git")):
        i = 1
        while i < len(toks) and toks[i].startswith("-"):  # global options: -c <key> can name a program to run
            tok = toks[i]
            if tok.startswith(("--config-env", "--exec-path")):
                return False
            val = toks[i + 1] if i + 1 < len(toks) else ""
            i += 2 if tok in GIT_VALUE_OPTS else 1
            if tok.startswith("-c") and not SAFE_CONFIG.fullmatch((val if tok == "-c" else tok[2:]).split("=", 1)[0]):
                return False
        # push/fetch options naming a program to run, in any abbreviation git accepts (--rece, --e)
        return not any(len(n) > 2 and o.startswith(n) for n in (t.split("=", 1)[0] for t in toks[i:] if t[:2] == "--")
                       for o in RUNNING_OPTS)
    return toks[0] in ("grep", "egrep", "fgrep") and reads_only(t)


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


GITDIRS = {}  # cwd → (rc, git dir): one rev-parse per directory per invocation


def owner_of(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None, None
    if cwd not in GITDIRS:
        GITDIRS[cwd] = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=cwd)
    rc, gitdir = GITDIRS[cwd]
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


TIERS = {}  # git common dir → its unshipped tier record: shipped() is costly, so once per invocation


def tier_record(cwd):
    """(git common dir, the repo's S/M/L tier record, shipped or not), or (…, None)."""
    if not cwd or not os.path.isdir(cwd):
        return None, None
    if ("common", cwd) not in GITDIRS:
        GITDIRS["common", cwd] = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)
    rc, common = GITDIRS["common", cwd]
    tier = read(Path(common) / "orchestra-tier.json", {}) if rc == 0 else {}
    return common, (tier if tier.get("tier") in ("S", "M", "L") else None)


def active_tier(cwd):
    """The repo's unshipped tier record, or None."""
    common, tier = tier_record(cwd)
    if tier is None:
        return None
    if common not in TIERS:
        TIERS[common] = None if shipped(cwd, tier) else tier
    return TIERS[common]


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
        except ValueError:  # a bad escape (never Deadline: the alarm must reach the fallback)
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
    for cwd in sorted(cwd_at(data, cmd)[1]):
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
            for cwd in sorted(cwd_at(data, cmd)[1]):
                owner = owner_of(cwd)[0]
                if owner is not None:
                    decide("deny", f"push-guard doesn't know an option before `push`; run it plainly: "
                                   f"git push origin HEAD:{owner['target']}")
                if active_tier(cwd):
                    decide("deny", "A tier record is unshipped and push-guard doesn't know an option before `push`; "
                                   "run it plainly: git push origin <branch>")
            found = "allow", "push with an option push-guard doesn't know, outside a worker (no force, no tier record)"
    return found


def own_lead(data, cmd, here):
    """End of a leading `cd <this worker's own worktree> &&` (the one cd a worker push may carry), or None."""
    lead = re.match(rf"\s*cd\s+{VAL}\s*&&\s*", cmd)
    if lead and here is not None and (owner_of(cwd_at(data, cmd, lead.end())[0])[0] or {}).get("owner") == here["owner"]:
        return lead.end()
    return None


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
    pos, opts = push_tokens(toks)
    if cmd[m.end() + len(words):][:1] in (")", "`"):  # words cut at a $(…) / backtick: the rest is unseen
        parsed = False
    unsure = not parsed or any(c in t for t in toks for c in "$`{*?[")
    # the words may stop early (at a $(…)'s `)`, a backtick, which may span lines): any force marker in the rest
    # of the command denies
    if unsure and any(is_force(w) for w in re.split(r"[\s\"'{},;&|()`$]+", cmd[m.end():]) if w):
        decide("deny", "Force/delete/mirror pushes are never allowed. Rebase and push normally.")
    cwd, cands = cwd_at(data, cmd, m.start(), dirs)
    here = owner_of(data.get("cwd") or os.getcwd())[0]
    if cwd is None and here is None:  # can't tell which checkout: deny if any it may be is a worker or tiered
        for c in sorted(cands):
            if owner_of(c)[0] is not None:
                decide("deny", f"push-guard can't tell which checkout this push runs in (a cd/pushd/-C it can't "
                               f"resolve) and {c} is an orchestra worktree; cd into it plainly and push from there.")
            if active_tier(c):
                decide("deny", f"A tier record is unshipped in {c} and push-guard can't tell which checkout this push "
                               f"runs in (a cd/pushd/-C it can't resolve); cd there plainly and push.")
        return "none", "push in a checkout push-guard can't resolve: no decision, the user's rules apply"
    owner, gitdir = owner_of(cwd)
    end = own_lead(data, cmd, here)  # `cd <own worktree> && git push …` stays fine
    rest = cmd if end is None else cmd[end:]
    if here is not None and (CD.search(rest) or POPD.search(rest) or owner is None or owner["owner"] != here["owner"]):
        decide("deny", f"From a worker, push only your own worktree, without cd/pushd/-C: "
                       f"git push origin HEAD:{here['target']}")
    if unsure:
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


ORCH_WORD = re.compile(r"(?<![\w.-])orch\}?(?![\w.-])", re.I)  # orch, …/bin/orch, $ORCH, ${ORCH}; not orchestra
ORCH_TOKEN = re.compile(r"(?:.*/)?(?:\$\{?)?orch\}?", re.I)  # the same, as one shell word
ROLE_OPT = re.compile(r"--r(?:o(?:le?)?)?(?:=(.*))?", re.S)  # argparse takes --r / --ro / --rol for --role
ROLE_AGENTS = {"reviewer": {"reviewer"}, "adversarial": {"reviewer"}, "verifier": {"verifier"}}


# programs whose quoted arguments are only read (printed, searched, stored as a message), never run
READERS = DATA_PROGS | {"cat", "gh", "orch", "true", "test", "["}
GIT_READERS = {"commit", "log", "tag", "show", "grep"}
WRAPPERS = {"env", "xargs", "sudo", "nohup", "nice", "exec", "time", "command", "builtin", "timeout", "stdbuf"}


def command_word(seg):
    """(index in words_of(seg), the program a simple command runs), looking past env/sudo/xargs/timeout-style
    wrappers and their options, or (None, "")."""
    w = words_of(seg)
    for k, t in enumerate(w):
        if not (t in WRAPPERS or t.startswith("-") or "=" in t or t.isdigit()):
            return k, t.rsplit("/", 1)[-1]
    return None, ""


# readers that also run an argument with some subcommand or flag: (program, subcommand or None, flags that run it)
RUNS_ARGS = {("orch", "gates"): (), ("orch", "baseline"): (), ("orch", None): ("--cmd", "--setup"),
             ("git", "grep"): ("-O", "--open-files-in-pager"), ("rg", None): ("--pre", "--hostname-bin"),
             ("gh", "alias"): ()}


def reads_only(seg):
    """The simple command only reads its quoted arguments: a READERS program, git commit/log/tag/show/grep or a cmux
    report — except where RUNS_ARGS says that subcommand or flag runs an argument (orch gates/baseline --cmd, git grep
    -O, rg --pre, gh alias)."""
    k, prog = command_word(seg)
    w = words_of(seg)
    sub = w[k + 1] if k is not None and len(w) > k + 1 else None
    for (p, s), flags in RUNS_ARGS.items():
        if p == prog and (s is None or s == sub) and (
                not flags or any(t == f or t.startswith(f + "=") or (f.startswith("-O") and t.startswith(f))
                                 for t in w for f in flags)):
            return False
    return prog in READERS or (prog == "git" and sub in GIT_READERS) or (
        prog == "cmux" and w[k + 1:k + 3] == ["agent", "message"])


def walk(cmd):
    """(text, simple commands, strict): text is cmd with the "$(cat <<'EOF' … EOF)" argument idiom made inert
    (arg_heredocs); simple commands are (words, offset in text, separator) for each command the shell runs (quotes
    removed, so a quoted argument is one word, not a call). Quoted text is data only where nothing can run it, so strict
    lists what is checked by text search instead: all of it when quoting doesn't balance, a $( … ) / backtick /
    <( … ) / >( … ) is used (its output can be run or fed to a program), or something is piped into a program that
    isn't a reader; else each command whose program isn't a reader (sh -c, eval, ssh, watch, git -c alias.x=!…: any
    quoted text in it may run), a command shlex can't split, and each heredoc body not only read by cat/git (at the
    start of its command, not piped on, a quoted delimiter or no $( … ) / backticks in the body)."""
    text = arg_heredocs(cmd)
    ev, docs, bad = commands(text)
    if bad or any(e[0] == "(" and e[1] == "$" for e in ev):
        return text, [], [text]
    cmds, strict = [], []
    for e in ev:
        if e[0] != "cmd":
            continue
        try:
            cmds.append((shlex.split(e[1]), e[3], e[2]))
        except ValueError:
            strict.append(e[1])
            continue
        if not reads_only(e[1]):
            strict.append(e[1])
    if piped_to_runner(ev):  # data piped into a program that may run it ({ cat <<X; } | sh): search all of it
        return text, cmds, [text]
    for k, b, e, quoted in docs:
        if not doc_is_data(ev, k, text, b, e, quoted):
            strict.append(text[b:e])
    return text, cmds, strict


def check_evidence_call(agent, toks):
    """toks = verdict|criterion and its arguments: deny unless every --role it passes belongs to the caller."""
    roles = [] if toks[0] == "criterion" else [
        r.group(1) if r.group(1) is not None else (toks[k + 1] if k + 1 < len(toks) else "")
        for k, r in ((k, ROLE_OPT.fullmatch(t)) for k, t in enumerate(toks)) if r]
    allowed = {"verifier"} if toks[0] == "criterion" else (
        set.intersection(*(ROLE_AGENTS.get(r, set()) for r in roles)) if roles else set())
    if agent not in allowed:
        decide("deny", f"`orch {toks[0]}` {('--role ' + '/'.join(roles) + ' ') if roles else ''}must be run by "
                       f"the {'/'.join(sorted(allowed)) or 'matching reviewer/verifier'} subagent itself, one role "
                       f"per call (caller: {agent or 'main session'}). Launch that agent; never record evidence "
                       f"yourself.")


def check_evidence_writer(data, cmd):
    """Only the reviewer/verifier subagents may record their own verdicts; workers can't self-certify. Every
    `orch verdict|criterion` call in the command is checked (each simple command; an orch word followed by the
    subcommand anywhere in it, so env/xargs/echo prefixes count), with every --role it passes. A quoted argument that
    names one (a --summary, an echo/grep/commit message) and a cat heredoc body are only read."""
    if not re.search(r"verdict|criterion", cmd):  # no subcommand word: nothing to check
        return
    agent = data.get("agent_type") or ""
    _, cmds, strict = walk(cmd)
    for toks, _, _ in cmds:
        for k in range(len(toks) - 1):
            j = k + 2 if toks[k + 1] == "--" else k + 1  # argparse takes orch -- verdict …
            if ORCH_TOKEN.fullmatch(toks[k]) and j < len(toks) and toks[j] in ("verdict", "criterion"):
                check_evidence_call(agent, toks[j:])
    for piece in strict:
        # a call's own arguments are read with any $( … ) / backtick in them blanked (--worktree $(pwd) --role x);
        # a call inside one is read as itself
        subs = [(s.start(), s.end()) for s in re.finditer(r"\$\([^()]*\)|`[^`]*`", piece)]
        flat = piece
        for s, e in subs:
            flat = flat[:s] + "_" * (e - s) + flat[e:]
        for m in ORCH_WORD.finditer(piece):
            inside = any(s <= m.start() < e for s, e in subs)
            words = shell_words(piece if inside else flat, m.end())
            try:
                toks = shlex.split(words)
            except ValueError:
                toks = re.sub(r"[\"'\\]", " ", words).split()
            toks = toks[1:] if toks[:1] == ["--"] else toks
            if toks and toks[0] in ("verdict", "criterion"):
                check_evidence_call(agent, toks)


CMUX_WORD = re.compile(r"(?<![\w.-])cmux(?![\w.-])")  # cmux, /path/to/cmux; not cmux-x / .cmux
WORKER_TAGS = ("QUESTION:", "NEEDS_FILES:", "BLOCKED:", "MERGED:", "PROGRESS:", "DONE:")
WORKER_FORBIDDEN = {"send", "send-key", "paste", "new-workspace", "close-workspace", "workspace",
                    "new-split", "new-pane", "claude-teams"}


def check_worker_messaging(data, cmd):
    """Workers only report to their own coordinator, with a tag; they never message or drive anyone else. Every
    cmux command in the command is checked (each simple command, wherever it sits: ; && || | & newline, a subshell,
    a heredoc fed to a shell); "a worker" is the session, or the checkout that command runs in."""
    if not CMUX_WORD.search(cmd) and not re.search(r"\borch\s+broadcast\b", cmd):
        return
    session = owner_of(data.get("cwd") or os.getcwd())[0]
    text, cmds, strict = walk(cmd)

    def owner_at(pos):
        if session is not None:
            return session
        cwd = cwd_at(data, text, pos)[0]  # a cd it can't resolve (say, quoted message text) isn't a worker's
        return owner_of(cwd)[0] if cwd is not None else None

    for m in re.finditer(r"\borch\s+broadcast\b", text):
        if owner_at(m.start()) is not None:
            decide("deny", "Workers never message other workers. Report to your coordinator instead.")
    run = None
    for toks, at, sep in cmds:
        if command_word(shlex.join(toks))[1] == "cmux":  # the program, past env/xargs/sudo; not grep cmux …
            k = next(k for k, t in enumerate(toks) if t.rsplit("/", 1)[-1] == "cmux")
            owner = owner_at(at)
            if owner is not None and "xargs" in (t.rsplit("/", 1)[-1] for t in toks[:k]):  # its args come from stdin
                decide("deny", "Write cmux commands from a worker plainly, without xargs: "
                               "cmux agent message <coordinator> --from <owner> \"PROGRESS: …\"")
            if owner is not None and sep in ("(", "`"):  # cut by a $( … ) / backtick: the rest is unseen
                decide("deny", "Write cmux commands from a worker plainly, without $( … ) or backticks: "
                               "cmux agent message <coordinator> --from <owner> \"PROGRESS: …\"")
            if owner is not None:
                run = check_cmux(owner, toks[k + 1:], run)
    if not strict:
        return
    owner = session or owner_at(len(text)) or next(  # a piece runs somewhere in the command: any worker it visits
        (o for o in (owner_of(c)[0] for c in sorted(cwd_at(data, text)[1])) if o is not None), None)
    for piece in strict if owner is not None else ():
        for m in CMUX_WORD.finditer(piece):
            words = shell_words(piece, m.start())
            if RUNS.search(words):
                decide("deny", "Write cmux commands from a worker plainly, without $( … ) or backticks: "
                               "cmux agent message <coordinator> --from <owner> \"PROGRESS: …\"")
            try:
                toks = shlex.split(words)[1:]
            except ValueError:  # a match inside someone else's quotes (grep "cmux" .): its words, quotes dropped
                toks = re.sub(r"[\"'\\]", " ", words).split()[1:]
            run = check_cmux(owner, toks, run)


def check_cmux(owner, toks, run):
    """One cmux command from a worker (toks follow `cmux`). Returns run.json once read."""
    agent = next((k for k in range(len(toks) - 1) if toks[k:k + 2] == ["agent", "message"]), None)
    head = toks if agent is None else toks[:agent]  # a message body may name a verb; what precedes it may not
    verb = next((t for t in head if t in WORKER_FORBIDDEN), None)
    if verb:
        decide("deny", f"Workers may not run `cmux {verb}` (no driving other terminals/workspaces). "
                       f"Send a tagged report to your coordinator.")
    if any("$" in t for t in (toks[:1] if agent is None else head)):  # $V / ${V}: a subcommand it can't read
        decide("deny", "Write cmux commands from a worker plainly (no $-built or quoted subcommand).")
    if agent is None:
        return run
    run = run or json.loads((ORCH_HOME / "runs" / owner["run"] / "run.json").read_text())
    toks = toks[agent + 2:]
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
    return run


def main(data):
    if data.get("tool_name") != "Bash":
        return
    original = data.get("tool_input", {}).get("command", "")
    raw = join_lines(original)
    # joined lines may hide a separator (`\\` + newline is a literal backslash, then a new command): no data strings
    continued = bool(re.search(r"\\\r?\n", original))
    check_evidence_writer(data, raw)
    check_worker_messaging(data, raw)
    cmd = raw if continued else inert_text(blank_data(raw))  # quoted data and bodies only read aren't pushes
    check_worker_indirection(data, cmd, raw)
    here = owner_of(data.get("cwd") or os.getcwd())[0] if PUSH.search(cmd) else None
    if here is not None:  # a worker push is the whole command (an allow would approve the chain; a prompt would
        end = own_lead(data, original, here)  # stall the unattended worker) — `cd <own wt> &&` aside
        if compound(original if end is None else original[end:]):
            decide("deny", f"Worker pushes must be one plain command, nothing chained, piped or substituted: "
                           f"git push origin HEAD:{here['target']}")
    ok = [check_push(data, cmd, m) for m in PUSH.finditer(cmd)]  # every push in the command must pass
    ok += filter(None, [check_unmatched_git(data, cmd)])
    c = COMMIT.search(cmd)
    if not ok and c:
        cwd = cwd_at(data, cmd, c.start(), git_globals(c.group("g"))[0])[0]
        if cwd is None or owner_of(cwd)[0] is not None:
            return  # in a worker (or can't tell) a commit gets no decision
        ok = [("allow", "git commit outside an orchestra worker: no prompt")]
    if ok:  # never "ask": unattended runs can't answer a prompt
        if any(d == "none" for d, _ in ok):
            return  # a push it can't place: not approved, the user's own rules apply
        if here is None and not git_itself(original):  # outside a worker an allow would approve the whole chain
            return  # (or what bash -c / eval / ssh runs): no decision, the user's own rules apply
        decide("allow", "; ".join(r for _, r in ok) + ".")


def fallback(data, e):
    """The checks crashed or ran out of time. Fail closed for a push inside a worker, under a tier record (recorded at
    all, when out of time) or with a force/delete marker, for a worker's cmux/broadcast call and for an evidence call
    by the wrong agent; also when it can't tell. Elsewhere a plain (not compound) push or commit is allowed."""
    PHASE["reserve"] = 0  # the reserved seconds are the fallback's; then a hard stop
    arm(left())
    timed_out = isinstance(e, Deadline)
    why = f"push-guard ran past its {DEADLINE:g}s deadline" if timed_out else f"push-guard error ({e})"
    data = data if isinstance(data, dict) else {}
    original = (data.get("tool_input") or {}).get("command", "")
    original = original if isinstance(original, str) else ""
    cmd, agent = join_lines(original), data.get("agent_type") or ""
    try:
        cwds, unsure = {data.get("cwd") or os.getcwd()} | cwd_at(data, cmd)[1], False
        for m in [*PUSH.finditer(cmd), *COMMIT.finditer(cmd)]:  # each git -C <dir> it points at, too
            cwd, cands = cwd_at(data, cmd, m.start(), git_globals(m.group("g"))[0])
            cwds |= cands
            unsure = unsure or cwd is None
        in_orch = unsure or any(owner_of(c)[0] is not None for c in sorted(cwds))
        tier = unsure or any((tier_record(c)[1] if timed_out else active_tier(c)) for c in sorted(cwds))
    except Exception:
        in_orch = tier = True  # can't tell: as if inside a worker and under a tier record
    arm(max(left(), 2.0))  # the rest runs no git: a short hard stop even if the timer above already fired
    try:
        check_evidence_writer(data, cmd)
    except SystemExit:
        raise
    except Exception:  # the check couldn't finish: no call it may hide is cleared, whoever the caller is
        if re.search(r"\b(?:verdict|criterion)\b", cmd):
            decide("deny", f"{why}; refusing an evidence call it couldn't check.")
    if in_orch and (CMUX_WORD.search(cmd) or re.search(r"\borch\s+broadcast\b", cmd)):
        decide("deny", f"{why}; refusing a cmux/broadcast command from a worker (or where it can't tell).")
    if PUSH.search(cmd) or PUSH_WORD.search(unquoted(cmd)):
        if in_orch or tier or any(is_force(w) for w in re.split(r"[\s\"'{},;&|()]+", cmd) if w):
            decide("deny", f"{why}; refusing a push from a worker, under a tier record, with a force/delete marker "
                           f"or where it can't tell.")
        if git_itself(original):
            decide("allow", f"{why}; plain push outside a worker allowed.")
    elif COMMIT.search(cmd) and not in_orch and git_itself(original):  # in a worker: no decision, as normally
        decide("allow", f"{why}; git commit outside a worker allowed.")
    disarm()


if __name__ == "__main__":
    data = {}
    arm(left())
    try:
        data = json.load(sys.stdin)
        main(data)
        disarm()
    except SystemExit:
        raise
    except Exception as e:
        try:
            fallback(data, e)
        except SystemExit:
            raise
        except BaseException:  # even the fallback ran out of time: deny anything it guards
            c = str(((data if isinstance(data, dict) else {}).get("tool_input") or {}).get("command", ""))
            if re.search(r"push|commit|cmux|broadcast|verdict|criterion", c, re.I):
                decide("deny", f"push-guard ran past its {DEADLINE:g}s deadline; refusing a command it guards.")


