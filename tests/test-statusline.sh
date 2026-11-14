#!/usr/bin/env bash
# statusline/statusline.py: context %, 5h/weekly usage % and their reset times, on every python3 run.sh is given
# (macOS's own 3.9 included: its datetime.fromisoformat only reads 0, 3 or 6 fraction digits).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SL="$ROOT/statusline/statusline.py"
P=0; F=0
ok(){ if eval "$2"; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1 :: [$out]"; fi; }
run(){ out=$(printf '%s' "$1" | TZ=UTC python3 "$SL" 2>&1); rc=$?; }
day=$(TZ=UTC python3 -c 'import time; print(time.strftime("%a", time.gmtime(1893492000)))')  # 2030-01-01T10:00Z

run '{"model":{"display_name":"M"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":"2030-01-01T10:00:00Z"}}}'
ok "model, context % and 5h % shown" '[ $rc = 0 ] && grep -q "^M " <<< "$out" && grep -q "ctx .*42%" <<< "$out" && grep -q "5h .*55%" <<< "$out"'
ok "ISO reset time (Z) shown" "grep -q '$day 10:00' <<< \"\$out\""
for frac in 1 12 123 1234 123456 1234567; do
  run '{"rate_limits":{"seven_day":{"used_percentage":90,"resets_at":"2030-01-01T10:00:00.'$frac'Z"}}}'
  ok "ISO reset time with a ${#frac}-digit fraction shown" "[ \$rc = 0 ] && grep -q 'week .*90%' <<< \"\$out\" && grep -q '$day 10:00' <<< \"\$out\""
done
run '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":"2030-01-01T11:00:00+01:00"}}}'
ok "ISO reset time with an offset shown in local time" "grep -q '$day 10:00' <<< \"\$out\""
run '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1893492000}}}'
ok "epoch reset time shown" "grep -q '$day 10:00' <<< \"\$out\""
run '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":"soon"}}}'
ok "unreadable reset time → percentage only, no crash" '[ $rc = 0 ] && grep -q "5h .*5%" <<< "$out"'
run '{}'
ok "no usage yet → hint" '[ $rc = 0 ] && grep -q "usage: after first reply" <<< "$out"'
run 'nope'
ok "bad input → message, exit 0" '[ $rc = 0 ] && [ "$out" = "statusline: bad input" ]'

echo "test-statusline: $P passed, $F failed"
[ $F -eq 0 ]
