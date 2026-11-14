#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H=$ROOT/hooks/push-guard.py; F=0; V="orch ver""dict"; C="orch crit""erion"
hard(){ perl -MPOSIX -e '$t = shift; $p = fork // die; unless ($p) { POSIX::setsid(); exec @ARGV or exit 127 } $SIG{ALRM} = sub { kill 9, -$p, $p; exit 137 }; alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' 60 "$@"; }  # every hook call under a 60s wall clock (SIGKILL: blocking signals can't dodge it): a hang fails the case, never stalls the suite
t(){ printf '%s' "$1" | hard python3 $H >/dev/null 2>&1; r=$?; [ $r = $3 ] && echo "ok   $2" || { F=1; echo "FAIL $2 (got $r)"; }; }
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"tool_input\":{\"command\":\"$V --role reviewer --verdict PASS\"}}" "main session can't record reviewer" 2
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"verifier\",\"tool_input\":{\"command\":\"$V --role reviewer --verdict PASS\"}}" "verifier can't record reviewer" 2
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"reviewer\",\"tool_input\":{\"command\":\"$ROOT/bin/$V --role reviewer --verdict PASS\"}}" "reviewer records reviewer" 0
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"reviewer\",\"tool_input\":{\"command\":\"$V --role adversarial --verdict PASS\"}}" "reviewer records adversarial" 0
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"verifier\",\"tool_input\":{\"command\":\"$C --run x --id C1 --status pass --sha a\"}}" "verifier records criterion" 0
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"reviewer\",\"tool_input\":{\"command\":\"$C --run x --id C1 --status pass --sha a\"}}" "reviewer can't record criterion" 2
exit $F
