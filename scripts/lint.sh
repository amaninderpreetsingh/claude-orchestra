#!/usr/bin/env bash
# Lint every tracked (or new, not ignored) file: `bash -n` on shell scripts, a byte-compile on
# Python files, and a JSON parse on *.json. Prints each failure; exits 1 if any.
#   usage: scripts/lint.sh [repo-dir]      (default: the repo this script lives in)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${1:-$HERE/..}" && pwd)"
cd "$REPO" || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-lint.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
F=0; SH=0; PY=0; JS=0
fail(){ F=$((F + 1)); echo "FAIL $1"; sed 's/^/    /' "$TMP/err"; }
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  first=$(head -c 200 "$f" | head -1)
  case "$f" in
    *.json) JS=$((JS + 1))
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>"$TMP/err" || fail "$f (invalid JSON)" ;;
    *.py) PY=$((PY + 1))
      python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$f" "$TMP/c.pyc" 2>"$TMP/err" || fail "$f (python syntax)" ;;
    *.sh) SH=$((SH + 1)); bash -n "$f" 2>"$TMP/err" || fail "$f (bash syntax)" ;;
    *) case "$first" in
         '#!'*python*) PY=$((PY + 1))
           python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$f" "$TMP/c.pyc" 2>"$TMP/err" || fail "$f (python syntax)" ;;
         '#!'*bash*|'#!'*/sh|'#!'*' sh') SH=$((SH + 1)); bash -n "$f" 2>"$TMP/err" || fail "$f (bash syntax)" ;;
       esac ;;
  esac
done < <(git ls-files -z --cached --others --exclude-standard)
echo "lint: $SH shell, $PY python, $JS json checked — $F failure(s)"
[ $F -eq 0 ]
