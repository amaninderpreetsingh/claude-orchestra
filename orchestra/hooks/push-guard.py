#!/usr/bin/env python3
"""PreToolUse(Bash) guard-rail, three rules. A denial exits 2 with one line on stderr; anything else gets no decision
(exit 0, no output), so the user's own permission rules decide: it never allows or asks.
1. Nobody force-pushes: git push with --force, -f (in a cluster too: -uf), --force-with-lease[=…], --force-if-includes
   --mirror (or an abbreviation git accepts: --m, --forc, --mirr), a + refspec, or -c remote.*.mirror / .push=+….
2. A registered worker (orchestra-owner.json in its worktree's git dir, from `orch register`) runs no git … push.
3. A worker's cmux is only `agent message <its coordinator>` (short ref or stable id, owner record else run.json),
   `agent message --reply-to <id>`, `identify`, `read-screen --surface <its own>`; no CMUX_* variable or orch broadcast.
Best effort, no parser: shlex words cut into simple commands at ; & | ( ) ` newline ($( … ) runs on its own and stays
a word of its command); VAR=…, wrappers (env, sudo, xargs, if, …) and redirections skipped. Text a program only reads
is data (echo, a commit message, grep, a cat/tee/git/gh heredoc); text a shell runs is checked as commands (sh
-c, eval, ssh, | sh, a here-string, a heredoc fed to a shell, cmux send); text another interpreter runs (python, perl,
node) or shlex can't split is searched for the words. A guard-rail against accidents, NOT a sandbox: a script written
then run, a verb built in a variable or an alias gets past it. Loads on Python 3.9, runs no subprocess, fails closed:
a crash (import time too), SIGTERM/SIGHUP or its own 20s alarm (hook timeout 60s; exit 1 would let the command run)
denies any command naming push, cmux or broadcast.
"""
import os, sys

RAW = {}  # the hook input as read

def fail(why, read=True):
    """Last resort: deny (exit 2) if the input names something guarded or can't be read; else no decision."""
    if "text" not in RAW:  # a signal mid-read (read=False) never reads again: the input counts as unreadable
        try:
            RAW["text"] = sys.stdin.buffer.read().decode("utf-8", "replace") if read else None
        except BaseException:
            RAW["text"] = None
    flat = "".join(c for c in (RAW["text"] or "").lower() if c not in " \t\r\n\"'\\")  # pu""sh, p\ush, pu sh
    if RAW["text"] is None or any(w in flat for w in ("push", "cmux", "broadcast")):
        print(f"push-guard error ({' '.join(why.split())}); refused (push/cmux/broadcast)", file=sys.stderr, flush=True)
        os._exit(2)
    os._exit(0)

if __name__ == "__main__":  # run as the hook, a crash at import time too denies (never exit 1); imported (install.sh
    sys.excepthook = lambda kind, e, tb: fail(f"{kind.__name__}: {e}")  # smoke test), a crash stays an error
import json, re, shlex, signal, string

PUNCT = ";&|()<>\n`"  # shlex punctuation: separators and redirections
WORDCHARS = "".join(c for c in string.printable if c not in PUNCT + "'\"\\ \t\r\x0b\x0c")
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "source", ".", "su"}
RUNNERS = {"eval": 0, "watch": 0, "ssh": 1}  # they join their words into one command line (ssh: past its host)
INTERPRETERS = re.compile(r"python[\d.]*|pypy3?|perl|ruby|node|deno|bun|php|osascript|lua|tclsh")
WRAPPERS = {"env", "command", "builtin", "exec", "nohup", "sudo", "doas", "time", "timeout", "nice", "xargs",
            "caffeinate", "stdbuf", "arch", "if", "then", "else", "elif", "do", "while", "until", "!", "{", "function"}
VALUE_OPTS = {"sudo": "ugCDhpRTU user group chdir", "doas": "uC", "env": "uCS unset chdir", "timeout": "sk signal "
              "kill-after", "nice": "n adjustment", "xargs": "ILnPdEsa max-args max-procs delimiter eof arg-file",
              "stdbuf": "ioe", "watch": "nd interval", "ssh": "bcDEeFIiJLlmOopQRSWw",
              "arch": "de rch arch d e"}  # value-taking short, long (arch: -arch reads as "rch"; --arch, --d, --e)
SETTERS = {"export", "read", "declare", "typeset", "local", "readonly", "printf"}  # can set a CMUX_* variable
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--attr-source"}
FORCE_LONG = ("force", "force-with-lease", "force-if-includes", "mirror")
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(['\"]?)([A-Za-z_][\w.-]*)\2")  # not $((1<<2))
SHELL_WORD = re.compile(r"(?<![\w./-])(?:sh|bash|zsh|dash|ksh|source|eval)(?![\w.-])")
DATA_DOC = re.compile(r"(?:^|[;&|(`]|\$\()\s*(?:\w+=\S*\s+)*(?:cat|tee|git|gh)\b[^;&|(`]*$")  # they read it: data
TEXT_PUSH = re.compile(r"\bgit\b[^\n]{0,500}?\bpush\b([^\n]{0,500})")  # bounded: linear on long lines
MIRROR = re.compile(r"remote\..*\.(mirror|push=\s*\+)", re.I)  # -c remote.<r>.mirror / .push=+<refspec>
RUNS_OUT = re.compile(r"\|(?!\s*(tee|wc|grep|head|tail)\b)|`|[$<]\(")  # after a heredoc word: its output runs
CMUX_WORD = re.compile(r"(?<![\w.-])cmux(?![\w.-])")
TARGET_OPT = re.compile(r"--(surface|workspace|window|panel|tab|to|socket)")  # what a cmux command acts on
REF = re.compile(r"\b(surface|workspace|pane|window|tab):|^[\dA-F]{8}-", re.I)  # a cmux ref or stable id
FORCE_MSG = ("Force pushes are never allowed (--force, -f, --force-with-lease, --force-if-includes, --mirror, a + "
             "refspec). Rebase onto the remote branch and push normally.")
PUSH_MSG = ("Workers never push. Commit on your branch, then report to your coordinator: "
            "READY: <id> <sha> evidence=<path> — the manager merges and pushes it.")
CMUX_FORMS = ("cmux agent message <your coordinator> --from <owner> \"<TAG>: …\", cmux agent message --reply-to <id> "
              "\"…\", cmux identify, cmux read-screen --surface <your own surface>")
Deny = type("Deny", (Exception,), {})  # raised with the one-line reason

def owner_of(cwd):
    """The owner record of the checkout holding cwd (a worker's worktree), or None. Reads files only, never git."""
    d = os.path.abspath(cwd)
    while not os.path.exists(os.path.join(d, ".git")) and d != os.path.dirname(d):
        d = os.path.dirname(d)
    gitdir = os.path.join(d, ".git")
    if os.path.isfile(gitdir):  # a worktree: "gitdir: <its git dir>"
        gitdir = os.path.join(d, open(gitdir).read().partition("gitdir:")[2].strip())
    p = os.path.join(gitdir, "orchestra-owner.json")
    return dict(json.load(open(p))) if os.path.isfile(p) else None  # not an object: a crash, fail()

def coordinator(owner):
    """The coordinator's refs (short + stable id): the owner record's, else its run's run.json's."""
    refs = lambda rec: {rec.get("coordinator"), rec.get("coordinator_id")} - {None, ""}
    run = os.path.join(os.environ.get("ORCH_HOME") or os.path.expanduser("~/.claude/orchestra"), "runs",
                       str(owner.get("run")), "run.json")
    return refs(owner) or (refs(dict(json.load(open(run)))) if os.path.isfile(run) else set())

def heredocs(text):
    """Cut heredoc bodies out of text: (the rest, [(opener before <<, after its word, body, delimiter quoted?)])."""
    lines, rest, docs, i = text.split("\n"), [], [], 0
    while i < len(lines):
        rest.append(lines[i])
        i += 1
        for m in HEREDOC.finditer(rest[-1]):  # its body runs to the delimiter line (<<- strips leading tabs);
            j = next((j for j in range(i, len(lines)) if lines[j].lstrip("\t" * (m.group(1) == "-")) == m.group(3)),
                     None)  # no delimiter line: a quoted "<<EOF", not a heredoc
            docs, i = (docs, i) if j is None else (docs + [(rest[-1][:m.start()], rest[-1][m.end():],
                                                            "\n".join(lines[i:j]), bool(m.group(2)))], j + 1)
    return "\n".join(rest), docs

def commands(text):
    """Simple commands as (words, the separator after them); redirections dropped (a here-string's text kept)."""
    lex = shlex.shlex(text.replace("\\\n", ""), posix=True, punctuation_chars=PUNCT)
    lex.whitespace, lex.commenters, lex.wordchars = " \t\r", "", lex.wordchars + WORDCHARS
    toks, out, cmd, i, subs = list(lex), [], [], 0, []  # subs: (outer words, closer) of each open $( ), <( ), ` `
    while i < len(toks):
        t = toks[i]
        if t and all(c in PUNCT for c in t):  # separators, then a redirection: ;>, 2>&1, &>, <<, <<<
            sep, redir = (t, "") if t.endswith("(") else re.fullmatch(r"(.*?)(&?[<>].*|)", t, re.S).groups()
            while subs and sep.startswith(subs[-1][1]):  # a substitution closes: the command around it goes on
                out, sep, cmd = out + [(cmd, subs[-1][1])], sep[len(subs[-1][1]):], subs.pop()[0]
                cmd = cmd[:-1] + [cmd[-1] + "_"] if cmd[-1:] and cmd[-1][-1:] in "$=:" else cmd + ["_"]  # X=$( ), $( )
            if sep:
                out = out + [(cmd, sep)]
                if sep == "`" or sep.endswith("(") and (sep != "(" or cmd[-1:] and cmd[-1].endswith("$")):
                    subs.append((cmd, "`" if sep == "`" else ")" * sep.count("(")))
                cmd = []
            cmd = cmd[:-1] if redir and cmd[-1:] and cmd[-1].isdigit() else cmd  # the 2 of 2>
            i += bool(redir) and redir != "<<<"  # skip its target, except a here-string's text (a shell runs it)
        else:
            cmd.append(t)
        i += 1
    return out + [(cmd, "")]

def program(words):
    """(program word or None for a lookup/nothing, its arguments, the VAR=value words before it)."""
    i, assigns = 0, []
    while i < len(words) and (re.match(r"[A-Za-z_]\w*\+?=", words[i]) or words[i].rsplit("/", 1)[-1] in WRAPPERS):
        if words[i] == "command" and words[i + 1:i + 2] in (["-v"], ["-V"]):
            return None, [], assigns  # command -v cmux: a lookup, not a call
        wrapper, i, assigns = "=" not in words[i], i + 1, assigns + [words[i]] * ("=" in words[i])
        i = opts_end(words[i - 1].rsplit("/", 1)[-1], words, i) + (words[i - 1] == "function") if wrapper else i
    return (words[i], words[i + 1:], assigns) if i < len(words) else (None, [], assigns)

def opts_end(wrapper, words, i):
    """Index past a wrapper's options and their values from i: sudo -u root, timeout -s KILL 30, xargs -I {}."""
    short, *long = (VALUE_OPTS.get(wrapper) or "_").split()
    while i < len(words) and (words[i][:1] == "-" or re.fullmatch(r"[\d.]+[smhd]?", words[i])):
        i += 1 + (len(words[i]) == 2 and words[i][1] in short or words[i][2:] in long)  # --signal KILL
    return i

def push_args(args):
    """The arguments after `push` when git's subcommand (past its global options) is push, else None."""
    i, mirror, args = 0, False, [a.lstrip("$") for a in args]  # $'push', $'-f': ANSI-C quotes lexed as $word
    while i < len(args) and args[i].startswith("-"):
        o, _, value = args[i].partition("=")
        if args[i] in GIT_VALUE_OPTS:
            value, i = (args[i + 1] if i + 1 < len(args) else ""), i + 1
        mirror = mirror or (o in ("-c", "--config-env") and bool(MIRROR.match(value)))
        i += 1
    i += args[i:i + 1] in (["subtree"], ["lfs"])  # git subtree push, git lfs push; git send-pack pushes too
    return args[i + 1:] + ["--mirror"] * mirror if args[i:i + 1] in (["push"], ["send-pack"]) else None

def forced(args):
    for a in (p for a in args for p in re.split(r"[{,}]", a)):  # each brace alternative: {+main,x}, {-f,}
        n = a[2:].partition("=")[0]
        if (a[:2] == "--" and n and any(f.startswith(n) for f in FORCE_LONG) or a[:1] == "+" and len(a) > 1
                or a[:1] == "-" != a[1:2] and "f" in a[1:].partition("o")[0]):  # --forc, +main, -uf; not -o<value>
            return True
    return False

def search(text, owner):
    """Text another interpreter runs, or text shlex can't split: searched for the guarded words, not parsed."""
    for m in TEXT_PUSH.finditer(text):
        force = forced([w for w in re.split(r"[\s'\",\[\](){};]+", m.group(1)) if w])
        if force or owner:
            raise Deny(FORCE_MSG if force else PUSH_MSG)
    if owner and (CMUX_WORD.search(text) or "broadcast" in text):
        raise Deny(f"From a worker, write cmux commands plainly, not inside text another program runs: {CMUX_FORMS}")

def scan(text, owner):
    """Check shell text: every simple command in it, and the text it hands to a shell or interpreter."""
    text, docs = heredocs(text)
    for pre, post, body, quoted in docs:
        shell = SHELL_WORD.search(pre + post)
        if shell or (not quoted and ("$(" in body or "`" in body)):  # a shell runs it
            scan(body, owner)
        if not shell and (not DATA_DOC.search(pre) or re.match(r"\s*(\$\(|`)", pre) or RUNS_OUT.search(post)):
            search(body, owner)  # another program (python, node, …) runs it, or something runs or reads its output
    try:
        cmds = commands(text)
    except ValueError:  # an unbalanced quote
        return search(text, owner)
    names = [(program(words)[0] or "").rsplit("/", 1)[-1] for words, _ in cmds]
    for k, (words, sep) in enumerate(cmds):
        for w in (w for w in words if "$(" in w or "`" in w or "<(" in w):  # a substitution in a quoted word runs
            scan(w, owner)
        prog, args, assigns = program(words)
        name = names[k]  # its words run as shell: a shell's, piped into one, or in a <( … ) a shell reads (source)
        runs = name in SHELLS or name == "cmux" and args[:1] in (["send"], ["new-workspace"]) or (  # typed into one
            sep == "|" and names[k + 1] in SHELLS) or (k and cmds[k - 1][1] in ("<(", ">(") and names[k - 1] in SHELLS)
        if owner and any(re.match(r"(-v)?CMUX_", a) for a in assigns + args * (name in SETTERS)):
            raise Deny("Workers never set CMUX_* variables (they pick which surface cmux acts on). Run cmux plainly.")
        if name == "git" and push_args(args) is not None and (owner or forced(push_args(args))):
            raise Deny(FORCE_MSG if forced(push_args(args)) else PUSH_MSG)
        elif INTERPRETERS.fullmatch(name):
            search("\n".join(args), owner)  # each argument on its own line(s)
        elif name == "cmux" and owner:
            check_cmux(args, owner)
        elif owner and (name == "orch" or prog in ("$ORCH", "${ORCH}")) and args[:1] == ["broadcast"]:
            raise Deny("Workers never message other workers. Report to your coordinator instead.")
        for a in args if runs else ():
            scan(a, owner)
        if name in RUNNERS:  # eval git …, ssh -p 22 host git …, watch -n 5 git …: one command line
            scan(" ".join(args[opts_end(name, args, 0) + RUNNERS[name]:]), owner)
        for j in (j for j, a in enumerate(args) if name == "find" and a in ("-exec", "-execdir", "-ok", "-okdir")):
            scan(shlex.join(args[j + 1:]), owner)  # find … -exec git … \;

def check_cmux(args, owner):
    """One cmux command from a worker (args follow `cmux`): only the forms in CMUX_FORMS."""
    msg = args[:2] == ["agent", "message"]
    pos, opts, i = [], {}, 1 + msg
    while i < len(args):  # --from, --reply-to, --lines and a target option take a value; other options don't
        name, eq, value = args[i].partition("=") if args[i][:1] == "-" else ("", "", args[i])
        takes = bool(name) and not eq and (name in ("--from", "--reply-to", "--lines")
                                           or bool(TARGET_OPT.fullmatch(name)))
        (opts.setdefault(name, []) if name else pos).append(args[i + 1] if takes and i + 1 < len(args) else value)
        i += 1 + takes
    targets = [v for o in opts if TARGET_OPT.fullmatch(o) for v in opts[o]]
    if msg:  # to the coordinator (then its text), or a reply (only its text); no target option naming anyone else
        coord = coordinator(owner)
        to = pos[:1] and pos[0] in coord and len(pos) <= 2 or "--reply-to" in opts and len(pos) <= 1
        if to and set(targets) <= coord:
            return
        raise Deny(f"Workers message only their coordinator ({', '.join(sorted(coord)) or 'none recorded'}).")
    own = {owner.get("workspace"), owner.get("surface_id")} - {None, ""}  # the surface it registered from
    mine = set(targets + [p for p in pos if REF.search(p)]) <= own and all(o == "--surface" for o in opts
                                                                          if TARGET_OPT.fullmatch(o))
    if mine and (args[:1] == ["identify"] or args[:1] == ["read-screen"] and targets):
        return
    raise Deny(f"Workers may run only these cmux commands: {CMUX_FORMS} (not `cmux {' '.join(args[:2])}`).")

def main():
    for s in (signal.SIGALRM, signal.SIGTERM, signal.SIGHUP):  # its own deadline, or a cancelled hook: fail closed
        signal.signal(s, lambda n, _f: fail(f"stopped by {signal.Signals(n).name}", False))
    signal.alarm(20)
    try:
        RAW["text"] = sys.stdin.buffer.read().decode("utf-8", "replace")
        data = json.loads(RAW["text"])
        if data.get("tool_name") == "Bash":  # a command that isn't a string crashes: fail()
            scan(data["tool_input"]["command"], owner_of(data.get("cwd") or os.getcwd()))
    except Deny as d:
        os.write(2, (" ".join(str(d).split()) + "\n").encode("utf-8", "replace"))
        os._exit(2)
    except BaseException as e:
        fail(f"{type(e).__name__}: {e}")
    os._exit(0)

if __name__ == "__main__":
    main()
