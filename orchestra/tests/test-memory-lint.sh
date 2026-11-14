#!/bin/bash
# memory-lint: frontmatter, index integrity, duplicate slugs. Fixtures live in a fresh mktemp dir.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L=$ROOT/bin/memory-lint
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=0; F=0
ok(){ P=$((P+1)); echo "ok   $1"; }
bad(){ F=$((F+1)); echo "FAIL $1"; }
mem(){ # mem <dir> <file> <name> [type] — writes a well-formed memory file
  printf -- '---\nname: %s\ndescription: d %s\nmetadata:\n  type: %s\n---\n\nbody\n' "$3" "$3" "${4:-project}" > "$1/$2"; }
clean(){ rm -rf "$T/m"; mkdir -p "$T/m"; mem "$T/m" a.md alpha; mem "$T/m" b.md beta feedback
  printf -- '- [Alpha](a.md) — hook\n- [Beta](b.md) — hook\n' > "$T/m/MEMORY.md"; }
run(){ out=$("$L" "$T/m" 2>&1); rc=$?; }
expect(){ # expect <desc> <rc> [regex the output must match]
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || printf '%s\n' "$out" | grep -qE "$3"; }; then ok "$1"; else bad "$1 (rc=$rc out=$out)"; fi; }

clean; run; expect "clean dir passes" 0
[ -z "$out" ] && ok "clean dir prints nothing" || bad "clean dir prints nothing (out=$out)"

clean; printf 'no frontmatter here\n' > "$T/m/a.md"; run; expect "missing frontmatter fails" 1 '^a\.md: .*frontmatter'
clean; printf -- '---\ndescription: d\nmetadata:\n  type: user\n---\n' > "$T/m/a.md"; run; expect "missing name fails" 1 '^a\.md: .*name'
clean; printf -- '---\nname: alpha\nmetadata:\n  type: user\n---\n' > "$T/m/a.md"; run; expect "missing description fails" 1 '^a\.md: .*description'
clean; printf -- '---\nname: alpha\ndescription: d\nmetadata:\n  node_type: memory\n---\n' > "$T/m/a.md"; run; expect "missing metadata.type fails" 1 '^a\.md: .*metadata\.type'
clean; printf -- '---\nname: alpha\ndescription: d\ntype: user\n---\n' > "$T/m/a.md"; run; expect "legacy top-level type passes" 0
clean; printf -- '---\nname: alpha\ndescription: d\ntype:\n---\n' > "$T/m/a.md"; run; expect "empty top-level type still fails" 1 '^a\.md: .*metadata\.type'
clean; printf -- '---\nname: alpha\ndescription: d\n---\n' > "$T/m/a.md"; run; expect "no type at all fails" 1 '^a\.md: .*metadata\.type'
clean; printf -- '---\nname: alpha\ndescription: d\nmetadata:\n  type: user\n' > "$T/m/a.md"; run; expect "unterminated frontmatter fails" 1 '^a\.md: .*frontmatter'

clean; printf -- '- [Gone](gone.md) — hook\n' >> "$T/m/MEMORY.md"; run; expect "dangling index line fails" 1 '^MEMORY\.md: .*gone\.md'
clean; mem "$T/m" c.md gamma; run; expect "unindexed file fails" 1 '^c\.md: .*not indexed'
clean; mem "$T/m" c.md alpha; printf -- '- [C](c.md) — hook\n' >> "$T/m/MEMORY.md"; run; expect "duplicate name fails" 1 'duplicate name.*alpha'
printf '%s\n' "$out" | grep -q 'a\.md' && printf '%s\n' "$out" | grep -q 'c\.md' && ok "duplicate names both files" || bad "duplicate names both files (out=$out)"
clean; rm "$T/m/MEMORY.md"; run; expect "missing MEMORY.md fails" 1 '^MEMORY\.md: missing'

clean; printf 'x\n' > "$T/m/a.md"; mem "$T/m" c.md beta; run
[ "$(printf '%s\n' "$out" | grep -c .)" -ge 3 ] && expect "one line per problem (frontmatter + unindexed + dup)" 1 || bad "one line per problem (out=$out)"

clean; printf -- '# Index\n\nSee [docs](https://example.com/x.md) and [Alpha](a.md).\n- [Beta](b.md) — hook\n' > "$T/m/MEMORY.md"; run; expect "external links ignored, inline links count" 0

clean; mkdir "$T/m/sub"; printf 'junk\n' > "$T/m/sub/x.md"; printf 'n\n' > "$T/m/notes.txt"; run; expect "only top-level .md files are memories" 0

clean; chmod -w "$T/m"; before=$(ls -l "$T/m" | shasum); run; chmod +w "$T/m"
[ "$before" = "$(ls -l "$T/m" | shasum)" ] && expect "read-only: works on unwritable dir, changes nothing" 0 || bad "read-only (changed files)"

out=$("$L" "$T/nope" 2>&1); rc=$?; expect "missing dir is a usage error" 2
out=$("$L" 2>&1); rc=$?; expect "no args is a usage error" 2

echo "PASS $P FAIL $F"
[ "$F" = 0 ]
