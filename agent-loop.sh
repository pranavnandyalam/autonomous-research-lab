#!/usr/bin/env bash
# agent-loop.sh — host-side supervisor for ONE autonomous research loop. Runs on the Mac, outside the sandbox.
#
#   ./agent-loop.sh [loop-id] [--once] [--print-cmd]
#
#   loop-id      [A-Za-z0-9_]+ ; default "main". Each loop needs its own project folders and state file.
#   --once       run a single cycle and exit (use this for the supervised hour)
#   --print-cmd  print the exact command that would run a cycle, then exit (quoting check, no model usage)
#
# Written for bash 3.2 (macOS default): no associative arrays, no mapfile, no flock, no GNU timeout.
# Run it as:  caffeinate -ims ./agent-loop.sh main     (agent-ctl.sh on does this inside tmux)
set -u -o pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ID="main"; ONCE=0; PRINT_CMD=0
for a in "$@"; do
  case "$a" in
    --once) ONCE=1 ;;
    --print-cmd) PRINT_CMD=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) LOOP_ID="$a" ;;
  esac
done
case "$LOOP_ID" in ""|*[!A-Za-z0-9_]*) echo "loop-id must match [A-Za-z0-9_]+" >&2; exit 2 ;; esac

# shellcheck disable=SC1091
. "$KIT/config.sh"
mkdir -p "$STATE_DIR/outputs" "$STATE_DIR/inbox-archive" "$STATE_DIR/alerts"
LOG="$STATE_DIR/loop-$LOOP_ID.log"
if [ "$LOOP_ID" = "main" ]; then STATE_FILE="STATE.md"; else STATE_FILE="STATE-$LOOP_ID.md"; fi

# ------------------------------------------------------------------ helpers
log() {
  # strip control characters: messages can include agent-written text (notes, questions) shown in terminals
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOOP_ID" "$(printf '%s' "$*" | LC_ALL=C tr -d '\000-\010\013-\037\177')" | tee -a "$LOG" >&2
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 5242880 ]; then mv "$LOG" "$LOG.1"; fi
}

# hto SECONDS CMD... : run a host command with a time limit (macOS has no `timeout`; perl is always present)
hto() { local s="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$s" "$@"; }

# getvar NAME : value of the variable called NAME (bash 3.2 safe; NAME is built from the validated loop id)
getvar() { eval "printf '%s' \"\${$1:-}\""; }

# to_seconds 50m|2h|90s|3000 : duration string to seconds
to_seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *)  echo "$1" ;;
  esac
}

# notify KEY MIN_SECONDS MESSAGE... : Telegram if configured, otherwise a macOS notification; throttled per KEY
notify() {
  local key="$1" min="$2"; shift 2
  local f now last=0 msg="$*"
  f="$STATE_DIR/alerts/$(printf '%s' "$key" | tr -c 'A-Za-z0-9_.-' '_')"
  now=$(date +%s)
  [ -f "$f" ] && last=$(cat "$f" 2>/dev/null || echo 0)
  case "$last" in ""|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge "$min" ]; then
    echo "$now" > "$f"
    log "ALERT[$key]: $msg"
    if ! python3 "$KIT/tg-bridge.py" send "[$LOOP_ID] $msg" >/dev/null 2>&1; then
      osascript -e "display notification \"$(printf '%s' "$msg" | tr -d '"\\' | cut -c1-180)\" with title \"agent-lab\"" >/dev/null 2>&1 || true
    fi
  fi
}

# each team (loop) has its own daily counter; main keeps the original file name
count_file() { if [ "$LOOP_ID" = "main" ]; then echo "$STATE_DIR/cycles-$(date +%Y-%m-%d).count"; else echo "$STATE_DIR/cycles-$(date +%Y-%m-%d)-$LOOP_ID.count"; fi; }
cycles_today() { local n; n=$(cat "$(count_file)" 2>/dev/null || echo 0); case "$n" in ""|*[!0-9]*) n=0 ;; esac; echo "$n"; }
bump_cycles() { local n; n=$(( $(cycles_today) + 1 )); echo "$n" > "$(count_file)"; echo "$n"; }

host_free_gb() { df -k / 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}'; }
on_battery() { pmset -g ps 2>/dev/null | head -1 | grep -q "Battery Power"; }
last_wake() { sysctl -n kern.waketime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p'; }  # epoch of the last wake from sleep
sleep_disabled_ok() { command -v pmset >/dev/null 2>&1 || return 0; pmset -g 2>/dev/null | grep -Eq 'SleepDisabled[[:space:]]+1'; }

paused_reason() {
  [ -f "$STATE_DIR/HOST_STOP" ] && { echo "HOST_STOP set (send /go)"; return 0; }
  [ -f "$STATE_DIR/TRIPWIRE" ] && { echo "TRIPWIRE: $(head -c 160 "$STATE_DIR/TRIPWIRE")"; return 0; }
  if [ -f "$STATE_DIR/PAUSE_UNTIL" ]; then
    local u; u=$(cat "$STATE_DIR/PAUSE_UNTIL" 2>/dev/null || echo 0)
    case "$u" in ""|*[!0-9]*) u=0 ;; esac
    if [ "$(date +%s)" -lt "$u" ]; then echo "PAUSE until epoch $u"; return 0; fi
    rm -f "$STATE_DIR/PAUSE_UNTIL"
  fi
  return 1
}

# nap SECONDS : interruptible sleep (a plain `sleep` would delay SIGTERM/trap handling until it finishes)
SLEEP_PID=""
nap() { sleep "$1" & SLEEP_PID=$!; wait "$SLEEP_PID" 2>/dev/null; SLEEP_PID=""; }

# status_write KEY=VALUE... : writes $STATE_DIR/status-<loop>.json (read by tg-bridge /status and the digest)
status_write() {
  python3 - "$STATE_DIR/status-$LOOP_ID.json" "$@" <<'PY'
import json, sys, time
path, kv = sys.argv[1], sys.argv[2:]
try: d = json.load(open(path))
except Exception: d = {}
for item in kv:
    k, _, v = item.partition("=")
    d[k] = v
d["loop"] = path.rsplit("status-", 1)[-1].rsplit(".json", 1)[0]
d["updated"] = int(time.time())
json.dump(d, open(path, "w"))
PY
}

vm_alive() { hto 25 sbx exec "$SBX_NAME" true >/dev/null 2>&1; }
vm_up() {
  vm_alive && return 0
  log "VM not responding; starting it"
  hto 60 sbx daemon status >/dev/null 2>&1 || hto 60 sbx daemon start >>"$LOG" 2>&1
  # there is no `sbx start`: exec auto-starts a stopped sandbox (verified in the sbx exec docs)
  hto 240 sbx exec "$SBX_NAME" true >>"$LOG" 2>&1
  nap 5
  vm_alive
}

fails=0; trans=0; idle=0; timeouts=0; ratelim=0; blocked=0
register_fail() {
  fails=$((fails + 1)); log "failure $fails/$FAIL_LIMIT: $1"
  if [ "$fails" -ge "$FAIL_LIMIT" ]; then
    touch "$STATE_DIR/HOST_STOP"
    notify "halt-$LOOP_ID" 3600 "HALTED after $fails consecutive failures. Last: $1. Fix it, then send /go."
    status_write state=halted
    fails=0
  fi
}

# ------------------------------------------------------------------ in-VM pre-check (runs every iteration; no model usage)
read -r -d '' VM_PRECHECK <<'EOS'
set +e
git fetch -q origin main 2>/dev/null || { echo "FETCH_FAIL"; exit 91; }
git cat-file -e origin/main:STOP 2>/dev/null && echo "STOP_PRESENT"
bad=$(git ls-tree -r --name-only origin/main | grep -E '(^|/)(\.claude/|CLAUDE\.md$|\.mcp\.json$|\.claude\.json$)' | head -3 | tr '\n' ' ')
[ -n "$bad" ] && echo "TRIPWIRE_REMOTE:$bad"
bad2=$(find . \( -name .venv -o -name venv -o -name node_modules -o -name .git \) -prune -o \( -name .claude -o -name CLAUDE.md -o -name .mcp.json -o -name .claude.json \) -print 2>/dev/null | head -3 | tr '\n' ' ')
[ -n "$bad2" ] && echo "TRIPWIRE_LOCAL:$bad2"
fp=$( { for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude/CLAUDE.md"; do [ -f "$f" ] && sha256sum "$f"; done; ls -A "$HOME/.claude/hooks" "$HOME/.claude/commands" "$HOME/.claude/agents" "$HOME/.claude/skills" "$HOME/.claude/plugins" 2>/dev/null; } | sha256sum | cut -d' ' -f1)
echo "FINGERPRINT:$fp"
echo "LAST_PUSH:$(git log -1 --format=%ct origin/main 2>/dev/null)"
echo "HEAD_SHA:$(git rev-parse origin/main 2>/dev/null)"
echo "VM_FREE_KB:$(df -k / | awk 'NR==2{print $4}')"
echo "QHASH:$(git show origin/main:questions.md 2>/dev/null | sha256sum | cut -d' ' -f1)"
echo "OK"
EOS

# ------------------------------------------------------------------ cycle command
CLAIMED=""
# owner messages: one queue per team (main keeps inbox.txt); the bridge and goals.sh write to every team's queue
if [ "$LOOP_ID" = "main" ]; then INBOX="$STATE_DIR/inbox.txt"; else INBOX="$STATE_DIR/inbox-$LOOP_ID.txt"; fi
# manager advice: written by manager.sh once a day, handed to this team's next cycle as advice (never as owner text)
ADVICE="$STATE_DIR/manager-advice-$LOOP_ID.txt"; ADV_CLAIMED=""
claim_advice() {
  ADV_CLAIMED=""
  if [ -s "$ADVICE" ]; then ADV_CLAIMED="$ADVICE.claimed"; mv "$ADVICE" "$ADV_CLAIMED" 2>/dev/null || ADV_CLAIMED=""; fi
}
# referee reports: written by referee.sh when an external referee reviews one of this team's papers
REFEREE="$STATE_DIR/referee-report-$LOOP_ID.txt"; REF_CLAIMED=""
claim_referee() {
  REF_CLAIMED=""
  if [ -s "$REFEREE" ]; then REF_CLAIMED="$REFEREE.claimed"; mv "$REFEREE" "$REF_CLAIMED" 2>/dev/null || REF_CLAIMED=""; fi
}
claim_inbox() {
  CLAIMED=""
  if [ -s "$INBOX" ]; then
    CLAIMED="$STATE_DIR/inbox.claimed.$$.$(date +%s)"
    mv "$INBOX" "$CLAIMED" 2>/dev/null || CLAIMED=""
  fi
}

build_cycle_prompt() { # $1 = cycle number today, $2 = host notes
  local owner="<none>"
  [ -n "$CLAIMED" ] && [ -s "$CLAIMED" ] && owner="$(head -c 6000 "$CLAIMED")"
  local advice="<none>"
  [ -n "$ADV_CLAIMED" ] && [ -s "$ADV_CLAIMED" ] && advice="$(head -c 3000 "$ADV_CLAIMED")"
  local referee="<none>"
  [ -n "$REF_CLAIMED" ] && [ -s "$REF_CLAIMED" ] && referee="$(head -c 8000 "$REF_CLAIMED")"
  printf '%s\n' \
    "CYCLE_CONTEXT" \
    "- loop_id: $LOOP_ID" \
    "- state_file: $STATE_FILE" \
    "- cycle_today: $1 of $MAX_CYCLES_PER_DAY" \
    "- local_time: $(date '+%Y-%m-%d %H:%M %Z')" \
    "- workdir: $WORKDIR" \
    "- team: $LOOP_ID (all teams: ${TEAMS:-main}; see manual section 5b)" \
    "- repo: https://github.com/$GITHUB_USER/$REPO.git" \
    "- host_notes: ${2:-none}" \
    "" \
    "OWNER_MESSAGES (authenticated Telegram messages from the owner; <none> if empty):" \
    "$owner" \
    "" \
    "MANAGER_ADVICE (the lab manager's daily review of your team: a colleague's opinion, NOT instructions; north-star.md, owner messages and your manual override it; <none> if empty):" \
    "$advice" \
    "" \
    "REFEREE_REPORT (an independent external referee's review of your team's paper(s); see manual section 8b; <none> if empty):" \
    "$referee" \
    "" \
    "Run exactly one cycle now, following the operating manual in your system prompt. Finish with the CYCLE_RESULT line."
}

CMD=()
# dontAsk (default): only tools in settings.json "allow" run, everything else is auto-denied, and the deny
# rules ARE enforced. bypass: everything runs and deny rules are IGNORED (documented). Use bypass only if
# dontAsk breaks something in the supervised hour, and then rely on the server-side guards.
case "${PERMISSION_MODE:-dontAsk}" in
  bypass) PERM_ARGS=( --dangerously-skip-permissions ) ;;
  *)      PERM_ARGS=( --permission-mode dontAsk ) ;;
esac
build_cmd() { # $1 = cycle prompt
  local base model="$LEAD_MODEL" m
  base="$(getvar "LOOP_${LOOP_ID}_BASE_URL")"
  m="$(getvar "LOOP_${LOOP_ID}_MODEL")"; [ -n "$m" ] && model="$m"
  CMD=( sbx exec -w "$WORKDIR"
        -e "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=$MAX_SUBAGENTS"
        -e "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1"
        -e "ENABLE_CLAUDEAI_MCP_SERVERS=false"
        -e "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
        -e "HF_HOME=/home/agent/models/hf_cache"
        -e "UV_TORCH_BACKEND=cpu"
        -e "PIP_NO_CACHE_DIR=1" )
  # disk: one shared model cache; CPU-only torch (the default wheel drags ~4 GB of unusable CUDA libs); no pip cache
  [ -n "$base" ] && CMD+=( -e "ANTHROPIC_BASE_URL=$base" )
  # NOTE: the prompt comes right after -p and --disallowedTools is followed by another flag, because
  # --disallowedTools is variadic and would otherwise swallow a trailing positional prompt.
  CMD+=( "$SBX_NAME" timeout -k 60 "$CYCLE_TIMEOUT"
         claude -p "$1"
         "${PERM_ARGS[@]}"
         --no-session-persistence
         --max-turns "$MAX_TURNS"
         --model "$model"
         --strict-mcp-config
         --setting-sources user
         --disallowedTools "mcp__*"
         --output-format stream-json --verbose
         --settings "$(cat "$KIT/settings.json")"
         --agents "$(python3 "$KIT/render.py" "$KIT/agents.json")"
         --append-system-prompt "$(python3 "$KIT/render.py" "$KIT/prompt.md")" )
}

# classify RC OUTFILE ERRFILE -> prints one 0x1f-separated line: CLASS MARKER PROJECT PUSHED TURNS COST NOTE
classify() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, re, sys
rc, out, err = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def rd(p):
    try: return open(p, errors="replace").read()
    except Exception: return ""
raw, errt = rd(out), rd(err)
d = None
s = raw.strip()
if s:
    try: d = json.loads(s)
    except Exception:
        # stream-json: one event per line; only the final {"type":"result"} line counts (none on timeout/kill)
        for line in reversed(s.splitlines()):
            try: x = json.loads(line)
            except Exception: continue
            if isinstance(x, dict) and x.get("type") == "result": d = x; break
if isinstance(d, list):
    d = next((x for x in reversed(d) if isinstance(x, dict) and x.get("type") == "result"), None)
if isinstance(d, dict) and d.get("type") not in (None, "result"):
    d = None  # a lone stream event (e.g. killed right after start) is not a result
d = d if isinstance(d, dict) else {}
res = d.get("result") if isinstance(d.get("result"), str) else ""
sub = str(d.get("subtype") or "")
is_err = bool(d.get("is_error"))
turns, cost = d.get("num_turns", ""), d.get("total_cost_usd", "")
marker = project = pushed = note = ""
for m in re.finditer(r"CYCLE_RESULT:\s*([A-Z_]+)\s*(?:\|\s*project=([^|]*))?(?:\|\s*pushed=([^|]*))?(?:\|\s*note=(.*))?", res):
    marker, project, pushed, note = (m.group(1) or "").strip(), (m.group(2) or "").strip(), (m.group(3) or "").strip(), (m.group(4) or "").strip()
# Error text is only inspected when the run actually failed, so a research summary that mentions "rate limit" cannot trigger it.
failed = is_err or rc != 0
etxt = ((res if is_err else "") + "\n" + errt + ("\n" + raw[:3000] if (not d and failed) else "")).lower()
if sub == "error_max_turns" or re.search(r"max[ _-]?turns", etxt) and failed:
    cls = "MAXTURNS"
elif rc in (124, 137, 142) and not d:
    cls = "TIMEOUT"
elif failed and re.search(r"hit your [a-z ]{0,20}limit|session limit|weekly limit|usage limit|rate[ _-]?limit|limit reached|too many requests|\b429\b|quota", etxt):
    cls = "RATELIMIT"
elif failed and re.search(r"not logged in|/login|authentication[_ ]failed|token has expired|oauth.*expired|invalid api key|\b401\b", etxt):
    cls = "AUTH"
elif failed and re.search(r"overloaded|\b529\b|\b50[234]\b|timed? ?out|econnreset|socket hang up|temporarily unavailable|connection (reset|refused|error)", etxt):
    cls = "TRANSIENT"
elif rc == 0 and not is_err:
    cls = "IDLE" if marker == "NOTHING_TO_DO" else "OK"
else:
    cls = "FAIL"
if cls in ("FAIL", "RATELIMIT", "AUTH", "TRANSIENT", "TIMEOUT") and not note:
    note = re.sub(r"\s+", " ", (etxt.strip() or "rc=%d" % rc))[:160]
clean = lambda x: re.sub(r"[\x1f\t\r\n]+", " ", str(x))[:160]
print("\x1f".join([cls, clean(marker), clean(project), clean(pushed), clean(turns), clean(cost), clean(note)]))
PY
}

# ------------------------------------------------------------------ teams
# Every team other than main works in ITS OWN clone of the repo (TEAM=<id> bash setup.sh team), so two Leads never
# share a working tree or git index. Per-team overrides: LOOP_<id>_WORKDIR, LOOP_<id>_MAX_CYCLES, LOOP_<id>_MODEL.
if [ "$LOOP_ID" != "main" ]; then
  WORKDIR="$(getvar "LOOP_${LOOP_ID}_WORKDIR")"
  [ -n "$WORKDIR" ] || WORKDIR="$(cat "$STATE_DIR/workdir-$LOOP_ID" 2>/dev/null)"
  [ -n "$WORKDIR" ] || { echo "team '$LOOP_ID' has no clone yet: run  TEAM=$LOOP_ID bash setup.sh team" >&2; exit 1; }
fi
m="$(getvar "LOOP_${LOOP_ID}_MAX_CYCLES")"; [ -n "$m" ] && MAX_CYCLES_PER_DAY="$m"

# ------------------------------------------------------------------ startup
if [ "$PRINT_CMD" -eq 1 ]; then
  [ -n "${WORKDIR:-}" ] || WORKDIR="/home/agent/$REPO"
  CLAIMED=""; build_cmd "$(build_cycle_prompt 1 'print-cmd test')"
  printf '%q ' "${CMD[@]}"; echo; exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v perl >/dev/null || { echo "perl is required" >&2; exit 1; }
command -v sbx >/dev/null || { echo "sbx is not on PATH (config.sh sets /opt/homebrew/bin)" >&2; exit 1; }
[ -n "${WORKDIR:-}" ] || { echo "WORKDIR is empty. Run setup.sh first (it records the clone path) or set WORKDIR in config.sh." >&2; exit 1; }
for f in prompt.md agents.json settings.json; do [ -f "$KIT/$f" ] || { echo "missing $KIT/$f" >&2; exit 1; }; done
python3 -m json.tool "$KIT/agents.json" >/dev/null || { echo "agents.json is not valid JSON" >&2; exit 1; }
python3 -m json.tool "$KIT/settings.json" >/dev/null || { echo "settings.json is not valid JSON" >&2; exit 1; }

LOCKDIR="$STATE_DIR/loop-$LOOP_ID.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo 0)
  if kill -0 "$oldpid" 2>/dev/null && ps -p "$oldpid" -o command= 2>/dev/null | grep -q "agent-loop"; then
    echo "loop '$LOOP_ID' is already running (pid $oldpid)" >&2; exit 0
  fi
  rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" || exit 1
fi
echo $$ > "$LOCKDIR/pid"
trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; rm -rf "$LOCKDIR"' EXIT
trap 'log "signal received, exiting"; exit 0' INT TERM HUP

find "$STATE_DIR" -maxdepth 1 -name 'cycles-*.count' -mtime +7 -delete 2>/dev/null
find "$STATE_DIR/outputs" -type f -mtime +3 -delete 2>/dev/null
find "$STATE_DIR/inbox-archive" -type f -mtime +30 -delete 2>/dev/null
# prompt.md and agents.json are templates ({{OWNER_NAME}} etc.); refuse to start with an incomplete config
for t in prompt.md agents.json; do
  python3 "$KIT/render.py" "$KIT/$t" >/dev/null || { echo "agent-loop: $t could not be filled; check config.local.sh" >&2; exit 2; }
done
log "loop starting (pid $$) kit=$KIT sbx=$SBX_NAME workdir=$WORKDIR model=$LEAD_MODEL cap=$MAX_CYCLES_PER_DAY/day"
status_write state=starting

# ------------------------------------------------------------------ main loop
while :; do
  sleep_for=60
  if reason=$(paused_reason); then
    status_write state=paused "reason=$reason"
    [ "$ONCE" -eq 1 ] && { log "paused: $reason"; exit 0; }
    nap 60; continue
  fi

  if [ "$POWER_MODE" = "portable" ] && on_battery; then
    if [ ! -f "$STATE_DIR/ON_BATTERY" ]; then
      date +%s > "$STATE_DIR/ON_BATTERY"
      notify "battery" 0 "On battery: no new cycles until you plug in (they resume by themselves)."
    fi
    status_write state=waiting_for_power
    [ "$ONCE" -eq 1 ] && { log "on battery (POWER_MODE=portable): not starting a cycle"; exit 0; }
    nap 60; continue
  fi
  if [ -f "$STATE_DIR/ON_BATTERY" ]; then
    rm -f "$STATE_DIR/ON_BATTERY"
    notify "power" 0 "Plugged in: resuming cycles."
  fi

  [ "$POWER_MODE" = "portable" ] || sleep_disabled_ok || notify "pmset" 10800 "Mac sleep is NOT disabled (pmset SleepDisabled != 1). Closing the lid will stop the agent. Run: sudo pmset -a disablesleep 1"

  free=$(host_free_gb)
  if [ -n "$free" ] && [ "$free" -lt "$MIN_HOST_FREE_GB" ]; then
    notify "hostdisk" 21600 "Mac free disk is ${free}GB, below ${MIN_HOST_FREE_GB}GB. Pausing cycles."
    status_write state=low_disk
    [ "$ONCE" -eq 1 ] && exit 0
    nap 1800; continue
  fi

  n=$(cycles_today)
  if [ "$n" -ge "$MAX_CYCLES_PER_DAY" ]; then
    notify "cap-$(date +%F)-$LOOP_ID" 86400 "Team $LOOP_ID reached its daily cycle cap ($n/$MAX_CYCLES_PER_DAY). Resuming after midnight."
    status_write state=daily_cap
    [ "$ONCE" -eq 1 ] && exit 0
    nap 900; continue
  fi

  if ! vm_up; then register_fail "sandbox '$SBX_NAME' not reachable"; [ "$ONCE" -eq 1 ] && exit 1; nap 120; continue; fi

  pre=$(hto 300 sbx exec -w "$WORKDIR" "$SBX_NAME" bash -c "$VM_PRECHECK" 2>&1); prerc=$?
  if [ "$prerc" -ne 0 ] || ! printf '%s\n' "$pre" | grep -q '^OK$'; then
    register_fail "pre-check failed (rc=$prerc): $(printf '%s' "$pre" | tr '\n' ' ' | cut -c1-140)"
    [ "$ONCE" -eq 1 ] && exit 1
    nap 120; continue
  fi

  trip=$(printf '%s\n' "$pre" | grep -E '^TRIPWIRE_(REMOTE|LOCAL):' | head -2 | tr '\n' ' ')
  if [ -n "$trip" ]; then
    echo "$trip" > "$STATE_DIR/TRIPWIRE"
    notify "tripwire" 3600 "TRIPWIRE: agent-controlled config found ($trip). Loop paused. Review, remove it, then run: agent-ctl.sh rebaseline"
    status_write state=tripwire
    [ "$ONCE" -eq 1 ] && exit 1
    continue
  fi

  fp=$(printf '%s\n' "$pre" | sed -n 's/^FINGERPRINT://p' | head -1)
  if [ -n "$fp" ]; then
    if [ -f "$STATE_DIR/fingerprint.$SBX_NAME" ]; then
      if [ "$fp" != "$(cat "$STATE_DIR/fingerprint.$SBX_NAME")" ]; then
        echo "~/.claude fingerprint changed (was $(cat "$STATE_DIR/fingerprint.$SBX_NAME" | cut -c1-12), now $(printf '%s' "$fp" | cut -c1-12))" > "$STATE_DIR/TRIPWIRE"
        notify "tripwire-fp" 3600 "TRIPWIRE: the sandbox's ~/.claude config changed since baseline. Loop paused. Inspect it (sbx exec -it $SBX_NAME bash), then run: agent-ctl.sh rebaseline"
        status_write state=tripwire
        [ "$ONCE" -eq 1 ] && exit 1
        continue
      fi
    else
      echo "$fp" > "$STATE_DIR/fingerprint.$SBX_NAME"; log "recorded ~/.claude fingerprint baseline (trust on first use)"
    fi
  fi

  # history audit: main must only ever move forward. Checked from the HOST with your own gh login when
  # available (the VM's view of origin could be tampered with), else from inside the VM.
  sha=$(printf '%s\n' "$pre" | sed -n 's/^HEAD_SHA://p' | head -1)
  shaf="$STATE_DIR/main-sha.$LOOP_ID"
  if [ -n "$sha" ] && [ -f "$shaf" ] && [ "$sha" != "$(cat "$shaf")" ]; then
    prev=$(cat "$shaf"); st=""
    if command -v gh >/dev/null 2>&1; then
      st=$(hto 60 gh api "repos/$GITHUB_USER/$REPO/compare/$prev...$sha" --jq .status 2>/dev/null)
    fi
    if [ -z "$st" ]; then
      hto 60 sbx exec -w "$WORKDIR" "$SBX_NAME" git merge-base --is-ancestor "$prev" "$sha" >/dev/null 2>&1 && st=ahead || st=unknown
    fi
    case "$st" in
      ahead|identical) : ;;
      *) echo "main history rewritten or unverifiable ($prev -> $sha, status=$st)" > "$STATE_DIR/TRIPWIRE"
         notify "history" 3600 "TRIPWIRE: main on GitHub did not move forward cleanly ($st). Possible force-push. Loop paused. Check the repo, then: agent-ctl.sh rebaseline"
         status_write state=tripwire
         [ "$ONCE" -eq 1 ] && exit 1
         continue ;;
    esac
  fi
  [ -n "$sha" ] && echo "$sha" > "$shaf"

  vmfree=$(printf '%s\n' "$pre" | sed -n 's/^VM_FREE_KB://p' | head -1)
  if [ -n "$vmfree" ] && [ "$vmfree" -lt $((MIN_VM_FREE_GB * 1048576)) ] 2>/dev/null; then
    notify "vmdisk" 21600 "Sandbox free disk is $((vmfree / 1048576))GB, below ${MIN_VM_FREE_GB}GB. Pausing; clean caches in the VM."
    status_write state=vm_low_disk
    [ "$ONCE" -eq 1 ] && exit 1
    nap 1800; continue
  fi

  qh=$(printf '%s\n' "$pre" | sed -n 's/^QHASH://p' | head -1)
  if [ -n "$qh" ]; then
    # per-team hash: each clone fetches origin at its own time, so a shared file flip-flopped and re-alerted
    if [ -f "$STATE_DIR/qhash.$LOOP_ID" ] && [ "$qh" != "$(cat "$STATE_DIR/qhash.$LOOP_ID")" ]; then
      open_q=$(hto 60 sbx exec -w "$WORKDIR" "$SBX_NAME" bash -c 'git show origin/main:questions.md 2>/dev/null | grep "^### .*\[OPEN\]" | sed "s/^### //"' 2>/dev/null | cut -c1-160)
      [ -n "$open_q" ] || open_q="none (all answered)"
      # keyed on the open list, shared across teams: the same set of open questions alerts once a day
      notify "questions-$(printf '%s' "$open_q" | cksum | cut -d' ' -f1)" 86400 "questions.md changed. Open questions:
$open_q"
    fi
    echo "$qh" > "$STATE_DIR/qhash.$LOOP_ID"
  fi

  lp=$(printf '%s\n' "$pre" | sed -n 's/^LAST_PUSH://p' | head -1)
  if [ -n "$lp" ] && [ "$(cycles_today)" -ge 1 ]; then
    age=$(( $(date +%s) - lp ))
    # a Mac that slept (lid closed) in that window explains the silence, so only alert after a full awake stretch
    woke=$(last_wake); [ -n "$woke" ] || woke=0
    [ "$age" -gt $((DEADMAN_HOURS * 3600)) ] && [ $(( $(date +%s) - woke )) -gt $((DEADMAN_HOURS * 3600)) ] && notify "deadman" $((DEADMAN_HOURS * 3600)) "No commit on main for $((age / 3600))h while the loop is running. Check the agent."
  fi

  if printf '%s\n' "$pre" | grep -q '^STOP_PRESENT$'; then
    log "STOP file present in repo; idling"
    status_write state=stopped_by_repo
    [ "$ONCE" -eq 1 ] && exit 0
    nap 300; continue
  fi

  # ---- run one cycle
  cyc=$(bump_cycles)
  claim_inbox
  claim_advice
  claim_referee
  notes="none"
  [ "$timeouts" -gt 0 ] && notes="previous cycle hit the wall-clock limit; resume from the state file and commit in smaller steps"
  build_cmd "$(build_cycle_prompt "$cyc" "$notes")"
  stamp=$(date +%Y%m%dT%H%M%S)
  out="$STATE_DIR/outputs/cycle-$stamp-$LOOP_ID.json"
  log "cycle $cyc/$MAX_CYCLES_PER_DAY starting (timeout $CYCLE_TIMEOUT, max-turns $MAX_TURNS)"
  status_write state=running "cycle_today=$cyc" "cycle_started=$(date +%s)"
  t0=$(date +%s)
  hto $(( $(to_seconds "$CYCLE_TIMEOUT") + 900 )) "${CMD[@]}" >"$out" 2>"$out.err"
  rc=$?
  dur=$(( $(date +%s) - t0 ))

  # fields are separated by the ASCII unit separator (0x1f): unlike tab it is not IFS-whitespace, so empty fields survive
  IFS=$'\x1f' read -r CLASS MARKER PROJECT PUSHED TURNS COST NOTE <<EOF
$(classify "$rc" "$out" "$out.err")
EOF
  # the Mac slept during the cycle (lid closed): a failed API connection is expected, not the agent's fault
  woke=$(last_wake)
  if [ -n "$woke" ] && [ "$woke" -gt "$t0" ] && { [ "$CLASS" = "FAIL" ] || [ "$CLASS" = "TRANSIENT" ]; }; then
    NOTE="interrupted by sleep (was $CLASS): ${NOTE:-}"; CLASS="INTERRUPTED"
  fi
  log "cycle $cyc finished: class=$CLASS marker=${MARKER:--} project=${PROJECT:--} pushed=${PUSHED:--} turns=${TURNS:--} cost=${COST:--} rc=$rc dur=${dur}s note=${NOTE:--}"
  if [ "${TG_CYCLE_UPDATES:-1}" = "1" ]; then
    notify "cycle-$stamp" 0 "cycle $cyc/$MAX_CYCLES_PER_DAY: $CLASS${MARKER:+ ($MARKER)} | project=${PROJECT:--} | pushed=${PUSHED:--} | ${TURNS:-?} turns | $((dur / 60))m${NOTE:+
$NOTE}
https://github.com/$GITHUB_USER/$REPO/commits/main   (/last = full report, /radar = trend radar)"
  fi
  status_write state=idle_between "last_class=$CLASS" "last_marker=$MARKER" "last_project=$PROJECT" "last_pushed=$PUSHED" \
    "last_turns=$TURNS" "last_cost=$COST" "last_note=$NOTE" "last_duration=$dur" "last_cycle_end=$(date +%s)" "cycle_today=$cyc"

  # owner messages: archive if the cycle really ran, give them back if it failed outright
  if [ -n "$CLAIMED" ] && [ -f "$CLAIMED" ]; then
    case "$CLASS" in
      FAIL|AUTH|TRANSIENT|RATELIMIT) cat "$CLAIMED" >> "$INBOX"; rm -f "$CLAIMED" ;;
      *) mv "$CLAIMED" "$STATE_DIR/inbox-archive/" ;;
    esac
  fi
  if [ -n "$ADV_CLAIMED" ] && [ -f "$ADV_CLAIMED" ]; then   # give advice back if the cycle never really ran
    case "$CLASS" in
      FAIL|AUTH|TRANSIENT|RATELIMIT|INTERRUPTED) [ -s "$ADVICE" ] && rm -f "$ADV_CLAIMED" || mv "$ADV_CLAIMED" "$ADVICE" ;;
      *) mv "$ADV_CLAIMED" "$STATE_DIR/inbox-archive/manager-advice-$LOOP_ID.$(date +%s).txt" ;;
    esac
  fi

  if [ -n "$REF_CLAIMED" ] && [ -f "$REF_CLAIMED" ]; then   # same for referee reports (a newer one wins)
    case "$CLASS" in
      FAIL|AUTH|TRANSIENT|RATELIMIT|INTERRUPTED) [ -s "$REFEREE" ] && rm -f "$REF_CLAIMED" || mv "$REF_CLAIMED" "$REFEREE" ;;
      *) mv "$REF_CLAIMED" "$STATE_DIR/inbox-archive/referee-report-$LOOP_ID.$(date +%s).txt" ;;
    esac
  fi
  # a pushed cycle may have added or changed a paper: let the external referee look (detached; it locks itself)
  if [ "$PUSHED" = "yes" ] && [ -f "$KIT/referee.sh" ]; then
    nohup bash "$KIT/referee.sh" </dev/null >>"$STATE_DIR/referee.out" 2>&1 &
  fi

  sleep_for="$CYCLE_PAUSE"
  case "$CLASS" in
    OK)       fails=0; trans=0; idle=0; timeouts=0; ratelim=0 ;;
    IDLE)     fails=0; trans=0; idle=$((idle + 1)); timeouts=0; ratelim=0
              if [ "$idle" -ge 3 ]; then sleep_for="$IDLE_PAUSE_LONG"; else sleep_for="$IDLE_PAUSE"; fi ;;
    MAXTURNS) fails=0; idle=0; log "hit --max-turns: normal end of cycle" ;;
    TIMEOUT)  fails=0; idle=0; timeouts=$((timeouts + 1))
              [ "$timeouts" -ge 3 ] && notify "timeouts" 7200 "$timeouts cycles in a row hit the ${CYCLE_TIMEOUT} limit. The agent may be stuck on a long job." ;;
    RATELIMIT) ratelim=$((ratelim + 1)); sleep_for="$RATE_LIMIT_SLEEP"
              [ "$ratelim" -ge 2 ] && notify "ratelimit" 10800 "Max plan limit still hit after $ratelim cycles (over an hour of waiting). Consider lowering MAX_CYCLES_PER_DAY or pausing." ;;
    AUTH)     touch "$STATE_DIR/HOST_STOP"; status_write state=halted
              notify "auth" 3600 "Claude auth failed inside the sandbox ($NOTE). Loop halted. Re-authenticate (see DESIGN.md, Auth), then send /go." ;;
    TRANSIENT) trans=$((trans + 1)); sleep_for="$TRANSIENT_SLEEP"
              [ "$trans" -ge 12 ] && notify "transient" 7200 "$trans consecutive transient API/network errors. Last: $NOTE" ;;
    FAIL)     register_fail "cycle failed rc=$rc: $NOTE" ;;
    INTERRUPTED) idle=0; sleep_for=60; log "cycle interrupted by Mac sleep; retrying soon (not counted as a failure)" ;;
  esac

  case "$MARKER" in
    ASK_USER) notify "ask-$PROJECT-$(printf '%s' "$NOTE" | cksum | cut -d' ' -f1)" 21600 "Agent needs you ($PROJECT): $NOTE" ;;
    REJECTED) notify "rej-$PROJECT-$(printf '%s' "$NOTE" | cksum | cut -d' ' -f1)" 21600 "Overseer/ethics REJECTED work on $PROJECT: $NOTE" ;;
    BLOCKED)  blocked=$((blocked + 1)); notify "blocked-$(printf '%s' "$NOTE" | cksum | cut -d' ' -f1)" 21600 "Agent BLOCKED ($PROJECT): $NOTE"
              if [ "$blocked" -ge 3 ]; then touch "$STATE_DIR/HOST_STOP"; status_write state=halted
                notify "blocked-halt" 3600 "Agent reported BLOCKED 3 cycles in a row. Loop halted. Look at questions.md and the logs, then send /go."; blocked=0; fi ;;
    "")       ;;
    *)        blocked=0 ;;
  esac
  if [ -n "$MARKER" ] && [ "$MARKER" != "BLOCKED" ]; then blocked=0; fi
  if [ "$CLASS" = "OK" ] && [ -z "$MARKER" ]; then log "warning: cycle ended without a CYCLE_RESULT line"; fi

  [ "$ONCE" -eq 1 ] && { log "--once: done (class=$CLASS)"; exit 0; }
  log "sleeping ${sleep_for}s"
  nap "$sleep_for"
done
