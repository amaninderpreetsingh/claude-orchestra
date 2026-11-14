#!/usr/bin/env python3
"""Claude Code status line: this chat's context %, plus 5-hour and weekly plan usage % with reset times."""
import json, sys, time

try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("statusline: bad input"); sys.exit(0)

G, Y, R, DIM, X = "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"

def pct(v):
    c = G if v < 50 else Y if v < 80 else R
    return f"{c}{v:.0f}%{X}"

def reset(ts):
    if not ts:
        return ""
    if isinstance(ts, str):  # ISO 8601
        import re
        from datetime import datetime
        # Python 3.9's fromisoformat reads only 0, 3 or 6 fraction digits: pad/cut them to 6
        iso = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], ts.replace("Z", "+00:00"), count=1)
        try:
            ts = datetime.fromisoformat(iso).timestamp()
        except ValueError:
            return ""
    left = ts - time.time()
    when = time.strftime("%H:%M" if left < 86400 else "%a %H:%M", time.localtime(ts))
    h, m = int(max(left, 0) // 3600), int(max(left, 0) % 3600 // 60)
    return f" {DIM}↻ {when} ({f'{h // 24}d{h % 24}h' if h >= 24 else f'{h}h{m:02d}m'}){X}"

parts = [d.get("model", {}).get("display_name", "?")]
cw = d.get("context_window") or {}
if cw.get("used_percentage") is not None:
    parts.append(f"ctx {pct(cw['used_percentage'])}")

rl = d.get("rate_limits") or {}
for key, label in (("five_hour", "5h"), ("seven_day", "week")):
    w = rl.get(key) or {}
    if w.get("used_percentage") is not None:
        parts.append(f"{label} {pct(w['used_percentage'])}{reset(w.get('resets_at'))}")
if not rl:
    parts.append(f"{DIM}usage: after first reply{X}")

print(" │ ".join(parts))
