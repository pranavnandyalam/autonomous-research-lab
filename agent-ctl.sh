#!/usr/bin/env bash
# agent-ctl.sh — control the agent from your Mac's terminal.
#
#   ./agent-ctl.sh on [loop-id ...]   start sandbox, loop(s) and Telegram bridge in tmux (POWER_MODE=always-on also asks for sudo for pmset)
#   ./agent-ctl.sh off                stop everything, restore normal sleep (asks for sudo)
#   ./agent-ctl.sh status             what is running, last cycle, flags, disk, sleep setting
#   ./agent-ctl.sh logs [N]           tail the loop log(s)
#   ./agent-ctl.sh attach [loop|tg]   attach to the tmux session (detach with Ctrl-b d)
#   ./agent-ctl.sh pause 2h | go | stop | kill     soft controls (same as the Telegram commands)
#   ./agent-ctl.sh rebaseline         accept the sandbox's current ~/.claude config after a tripwire, clear the pause
#   ./agent-ctl.sh test-notify        send a test alert
#   ./agent-ctl.sh boot               used by the LaunchAgent after login/reboot (no sudo): restarts things if you had them ON
#
# Soft kill from your phone: push a file named STOP to the repo root on GitHub (the agent and the loop both honour it).
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"

# Always operate the deployed copy (see deploy.sh), so the loop, bridge and LaunchAgent all run the same code.
if [ "$KIT" != "$AGENT_DEPLOY_DIR" ] && [ -x "$AGENT_DEPLOY_DIR/agent-ctl.sh" ]; then
  if ! diff -rq --exclude .git --exclude .gitignore --exclude __pycache__ --exclude .DS_Store "$KIT" "$AGENT_DEPLOY_DIR" >/dev/null 2>&1; then
    echo "agent-ctl: note: $KIT has changes that are not deployed yet (run: bash $KIT/deploy.sh)" >&2
  fi
  exec "$AGENT_DEPLOY_DIR/agent-ctl.sh" "$@"
fi
mkdir -p "$STATE_DIR"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' (brew install $1)"; }

# tmux keeps the environment of whatever process first started its server, including old exported kit settings;
# config.sh only fills unset values, so strip every kit variable and let config.sh decide (e.g. a new LEAD_MODEL).
clean_env() { printf 'env'; sed -nE 's/^export ([A-Z_][A-Z0-9_]*)=.*/ -u \1/p' "$KIT/config.sh" | grep -v ' -u PATH$' | tr -d '\n'; }

session_name() { if [ "$1" = "main" ]; then echo "agent-loop"; else echo "agent-loop-$1"; fi; }

ensure_vm() {
  sbx daemon status >/dev/null 2>&1 || sbx daemon start >/dev/null 2>&1
  # no `sbx start` exists; exec auto-starts a stopped sandbox
  sbx exec "$SBX_NAME" true >/dev/null 2>&1 || { sleep 10; sbx exec "$SBX_NAME" true >/dev/null 2>&1; }
}

start_all() { # $1 = nosudo|sudo, rest = loop ids
  local mode="$1"; shift
  local ids="${*:-${TEAMS:-main}}" id s
  need tmux; need sbx; need caffeinate
  echo "$ids" > "$STATE_DIR/ENABLED"; rm -f "$STATE_DIR/HOST_STOP" "$STATE_DIR/PAUSE_UNTIL"   # ENABLED lists the teams to restore after a reboot
  if [ "$mode" = "sudo" ] && [ "$POWER_MODE" != "portable" ]; then
    say "Disabling system sleep (needs your password): sudo pmset -a disablesleep 1"
    sudo pmset -a disablesleep 1 || say "WARNING: pmset failed; the Mac will sleep when the lid closes."
  fi
  ensure_vm || die "sandbox '$SBX_NAME' would not start"
  # portable: stay awake only on the charger (-s); on battery the Mac may idle-sleep while the loop waits for power
  local caf="-ims"; [ "$POWER_MODE" = "portable" ] && caf="-ms"
  for id in $ids; do
    s="$(session_name "$id")"
    if tmux has-session -t "=$s" 2>/dev/null; then say "loop '$id' already running (tmux: $s)"
    else tmux new-session -d -s "$s" "cd '$KIT' && exec $(clean_env) caffeinate $caf ./agent-loop.sh $id" && say "started loop '$id' (tmux: $s)"; fi
  done
  if [ -n "${TG_ALLOWED_USER_ID:-}" ] && security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    if tmux has-session -t =agent-tg 2>/dev/null; then say "telegram bridge already running"
    else tmux new-session -d -s agent-tg "cd '$KIT' && exec $(clean_env) bash -c '. ./config.sh && exec python3 tg-bridge.py run'" && say "started telegram bridge (tmux: agent-tg)"; fi
  else
    say "telegram bridge not started (TG_ALLOWED_USER_ID or Keychain token missing; alerts fall back to macOS notifications)"
  fi
}

parse_dur() { # 2h | 30m | 45 -> seconds
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    ''|*[!0-9]*) echo 0 ;;
    *)  echo $(( $1 * 60 )) ;;
  esac
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
  on)  start_all sudo "$@"; say "ON. Check: ./agent-ctl.sh status   |   Logs: ./agent-ctl.sh logs" ;;
  boot)
    sleep 20
    if [ -f "$STATE_DIR/ENABLED" ]; then start_all nosudo $(cat "$STATE_DIR/ENABLED" 2>/dev/null); else say "ENABLED flag not set; nothing to restart"; fi ;;
  off)
    rm -f "$STATE_DIR/ENABLED"
    need tmux
    for s in $(tmux ls -F '#S' 2>/dev/null | grep '^agent-'); do tmux kill-session -t "=$s" && say "stopped tmux session $s"; done
    sbx stop "$SBX_NAME" >/dev/null 2>&1 && say "stopped sandbox $SBX_NAME"
    if pmset -g 2>/dev/null | grep -Eq 'SleepDisabled[[:space:]]+1'; then
      say "Restoring normal sleep (needs your password): sudo pmset -a disablesleep 0"
      sudo pmset -a disablesleep 0 || say "WARNING: could not reset pmset; run it yourself."
    fi
    say "OFF." ;;
  status)
    say "== flags"; for f in ENABLED HOST_STOP TRIPWIRE PAUSE_UNTIL; do [ -e "$STATE_DIR/$f" ] && say "  $f: $(head -c 100 "$STATE_DIR/$f" | tr '\n' ' ')"; done
    say "== loops"; for f in "$STATE_DIR"/status-*.json; do [ -f "$f" ] && python3 - "$f" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
age = int(time.time()) - int(d.get("updated", 0))
print("  %s: %s | cycle %s today | last %s %s %s | status age %ds" % (d.get("loop"), d.get("state"), d.get("cycle_today", "?"), d.get("last_class", "-"), d.get("last_marker") or "-", d.get("last_project") or "-", age))
if d.get("last_note"): print("    note:", d["last_note"][:140])
PY
    done
    say "== tmux"; tmux ls 2>/dev/null | grep '^agent-' | sed 's/^/  /' || say "  (none)"
    say "== sandbox"; sbx ls 2>/dev/null | head -5 | sed 's/^/  /'
    say "== mac"; pmset -g 2>/dev/null | grep -i SleepDisabled | sed 's/^/  /'; df -h / | awk 'NR==2{print "  free disk: " $4}'
    n=$(cat "$STATE_DIR/cycles-$(date +%Y-%m-%d).count" 2>/dev/null || echo 0); say "  cycles today: $n / $MAX_CYCLES_PER_DAY"
    say "== last log lines"; for f in "$STATE_DIR"/loop-*.log; do [ -f "$f" ] && tail -n 4 "$f" | sed 's/^/  /'; done ;;
  logs)  n="${1:-50}"; tail -n "$n" -f "$STATE_DIR"/loop-*.log ;;
  attach) case "${1:-loop}" in tg) tmux attach -t =agent-tg ;; loop|main) tmux attach -t =agent-loop ;; *) tmux attach -t "=$(session_name "$1")" ;; esac ;;
  pause)
    secs=$(parse_dur "${1:-}"); [ "$secs" -gt 0 ] || die "usage: pause 2h | 30m"
    echo $(( $(date +%s) + secs )) > "$STATE_DIR/PAUSE_UNTIL"; say "paused for ${1}" ;;
  stop)  touch "$STATE_DIR/HOST_STOP"; say "loop will idle after the current cycle (./agent-ctl.sh go to resume)" ;;
  go)    rm -f "$STATE_DIR/HOST_STOP" "$STATE_DIR/PAUSE_UNTIL"; ensure_vm || say "sandbox did not start"; say "resumed" ;;
  kill)  touch "$STATE_DIR/HOST_STOP"; sbx stop "$SBX_NAME" && say "sandbox stopped, loop idle (./agent-ctl.sh go to resume)" ;;
  rebaseline)
    rm -f "$STATE_DIR/TRIPWIRE" "$STATE_DIR/fingerprint.$SBX_NAME" "$STATE_DIR"/main-sha.* "$STATE_DIR"/alerts/tripwire* "$STATE_DIR"/alerts/history
    say "Cleared. The next cycle records a fresh ~/.claude baseline. Make sure you inspected the VM first:"
    say "  sbx exec -it $SBX_NAME bash   (check ~/.claude/settings.json, hooks/, commands/, agents/, skills/, plugins/ and the repo for .claude/ CLAUDE.md .mcp.json)" ;;
  test-notify) python3 "$KIT/tg-bridge.py" send "test alert from agent-ctl.sh" && say "sent" || say "Telegram not configured or failed (macOS notification used by the loop instead)" ;;
  help|-h|--help|*) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
