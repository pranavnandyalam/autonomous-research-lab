#!/usr/bin/env bash
# view.sh — one tmux screen that shows the whole lab live. Read-only.
#
#   ./view.sh [loop-id]     (re)create the "agent-view" tmux session and attach to it
#   tmux attach -t agent-view     re-open it later from any terminal (detach with Ctrl-b d)
#
# Left: every step as it happens (the lead and, indented, its scouts/builders/reviewers), following each new cycle.
# Top right: who is doing what (the same board as Telegram), refreshed every 10s. Bottom right: the supervisor log.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"
mode="${1:-main}"

case "$mode" in
  --steps)
    loop="${2:-main}"; last=""
    while :; do
      f=$(ls -t "$STATE_DIR"/outputs/cycle-*-"$loop".json 2>/dev/null | head -1)
      if [ -n "$f" ] && [ "$f" != "$last" ]; then
        last="$f"; bash "$KIT/watch-cycle.sh" "$f"
        printf '\n== waiting for the next cycle ==\n\n'
      fi
      sleep 5
    done ;;
  --board)
    while :; do
      f=$(ls -t "$STATE_DIR"/outputs/cycle-*-"${2:-main}".json 2>/dev/null | head -1)
      out=$( [ -n "$f" ] && python3 "$KIT/activity.py" "$f" 2>&1 || echo "no cycles yet" )
      clear; printf '%s\n\n(refreshes every 10s)\n' "$out"; sleep 10
    done ;;
esac

loop="$mode"; s="agent-view"
if ! tmux has-session -t "$s" 2>/dev/null; then
  tmux new-session -d -s "$s" -x 220 -y 55 "exec bash '$KIT/view.sh' --steps $loop"
  tmux split-window -h -l 45% -t "$s" "exec bash '$KIT/view.sh' --board $loop"
  tmux split-window -v -l 30% -t "$s:0.1" "exec tail -n 30 -F '$STATE_DIR/loop-$loop.log'"
  tmux set -t "$s" mouse on >/dev/null
fi
[ -t 1 ] && exec tmux attach -t "$s"
echo "view ready: tmux attach -t $s"
