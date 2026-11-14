#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H=$ROOT/hooks/push-guard.py; F=0; V="orch ver""dict"; C="orch crit""erion"
t(){ printf '%s' "$1" | python3 $H >/dev/null 2>&1; r=$?; [ $r = $3 ] && echo "ok   $2" || { F=1; echo "FAIL $2 (got $r)"; }; }
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"tool_input\":{\"command\":\"$V --role reviewer --verdict PASS\"}}" "main session can't record reviewer" 2
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"verifier\",\"tool_input\":{\"command\":\"$V --role reviewer --verdict PASS\"}}" "verifier can't record reviewer" 2
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"reviewer\",\"tool_input\":{\"command\":\"$ROOT/bin/$V --role reviewer --verdict PASS\"}}" "reviewer records reviewer" 0
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"reviewer\",\"tool_input\":{\"command\":\"$V --role adversarial --verdict PASS\"}}" "reviewer records adversarial" 0
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"verifier\",\"tool_input\":{\"command\":\"$C --run x --id C1 --status pass --sha a\"}}" "verifier records criterion" 0
t "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"agent_type\":\"reviewer\",\"tool_input\":{\"command\":\"$C --run x --id C1 --status pass --sha a\"}}" "reviewer can't record criterion" 2
exit $F
