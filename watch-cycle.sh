#!/usr/bin/env bash
# watch-cycle.sh — follow the newest (or given) cycle output live, rendered for humans. Read-only.
#
#   ./watch-cycle.sh [loop-id | path/to/cycle-*.json]
#
# Needs agent-loop.sh to run claude with --output-format stream-json (one JSON event per line).
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"
arg="${1:-main}"
if [ -f "$arg" ]; then f="$arg"
else
  echo "waiting for a cycle of loop '$arg' to start (Ctrl-C to quit)..."
  f=""
  while [ -z "$f" ]; do
    f=$(ls -t "$STATE_DIR"/outputs/cycle-*-"$arg".json 2>/dev/null | head -1)
    [ -n "$f" ] && [ $(( $(date +%s) - $(stat -f %m "$f") )) -gt 3600 ] && f=""   # ignore stale cycles
    [ -z "$f" ] && sleep 2
  done
fi
echo "following $f"
read -r -d '' VIEWER <<'PY'
import json, re, sys, time
# agent-written text can carry terminal control codes (e.g. ESC ]52 rewrites the clipboard); strip them before printing
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
DIM, BOLD, CYAN, YEL, GRN, RED, OFF = "\033[2m", "\033[1m", "\033[36m", "\033[33m", "\033[32m", "\033[31m", "\033[0m"
def short(x, n=160):
    s = x if isinstance(x, str) else json.dumps(x, ensure_ascii=False)
    s = " ".join(_CTRL.sub(" ", s).split())
    return s if len(s) <= n else s[: n - 1] + "…"
def tool_desc(name, inp):
    for k in ("command", "description", "file_path", "pattern", "url", "query", "prompt", "subagent_type"):
        if isinstance(inp, dict) and inp.get(k):
            extra = " [" + inp["subagent_type"] + "]" if name == "Agent" and inp.get("subagent_type") and k != "subagent_type" else ""
            return extra + " " + short(inp[k])
    return " " + short(inp)
for line in sys.stdin:
    try: e = json.loads(line)
    except Exception: continue
    t = e.get("type"); ts = time.strftime("%H:%M:%S")
    pad = "    │ " if e.get("parent_tool_use_id") else ""
    if t == "system" and e.get("subtype") == "init":
        print(f"{DIM}{ts} session start · model {e.get('model')} · {len(e.get('tools', []))} tools{OFF}")
    elif t == "assistant":
        for c in e.get("message", {}).get("content", []):
            if c.get("type") == "text" and c.get("text", "").strip():
                print(f"{pad}{ts} {BOLD}{_CTRL.sub(' ', c['text']).strip()}{OFF}")
            elif c.get("type") == "tool_use":
                n = c.get("name", "?")
                col = YEL if n == "Agent" else CYAN
                print(f"{pad}{ts} {col}▶ {n}{OFF}{tool_desc(n, c.get('input', {}))}")
    elif t == "user":
        content = e.get("message", {}).get("content", [])
        for c in content if isinstance(content, list) else []:
            if c.get("type") == "tool_result":
                body = c.get("content")
                if isinstance(body, list): body = " ".join(b.get("text", "") for b in body if isinstance(b, dict))
                mark = f"{RED}✗" if c.get("is_error") else f"{DIM}←"
                print(f"{pad}{ts} {mark} {short(body or '', 140)}{OFF}")
    elif t == "result":
        col = RED if e.get("is_error") else GRN
        print(f"\n{col}{BOLD}== cycle finished: {e.get('subtype')} · {e.get('num_turns')} turns · {round((e.get('duration_ms') or 0)/60000, 1)} min{OFF}")
        print(short(e.get("result", ""), 2000))
        sys.exit(0)
PY
# tail -F never exits on its own, so run it in the background and stop it once the viewer sees the result
fifo="$(mktemp -u)"; mkfifo "$fifo"
tail -n +1 -F "$f" >"$fifo" 2>/dev/null & TP=$!
trap 'kill $TP 2>/dev/null; rm -f "$fifo"' EXIT INT TERM
python3 -u -c "$VIEWER" <"$fifo"
