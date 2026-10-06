# config.sh — settings for the autonomous research lab kit.
# POSIX-sh compatible: it is sourced by bash (agent-loop.sh, setup.sh), zsh (tmux) and sh.
# Every value can be overridden from the environment, e.g.:  CYCLE_PAUSE=5 ./agent-loop.sh main --once
#
# YOUR personal values (name, GitHub user, Telegram id) go in config.local.sh, which git ignores:
#   cp config.local.sh.example config.local.sh   and edit it. Leave this file generic.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

_kit_dir="${KIT:-$(pwd)}"
# shellcheck disable=SC1091
[ -f "$_kit_dir/config.local.sh" ] && . "$_kit_dir/config.local.sh"

# ---------------------------------------------------------------- you (set these in config.local.sh)
export OWNER_NAME="${OWNER_NAME:-}"                      # how the agent addresses you, e.g. "Ada"
export GITHUB_USER="${GITHUB_USER:-}"                    # your GitHub username
export TG_ALLOWED_USER_ID="${TG_ALLOWED_USER_ID:-}"      # your numeric Telegram user id (message @userinfobot). Empty = Telegram disabled.

# ---------------------------------------------------------------- identity / repo
export REPO="${REPO:-agent-lab}"                          # PRIVATE repo the agent works in, one folder per project
export GIT_NAME="${GIT_NAME:-AI Agent (for $GITHUB_USER)}"
export GITHUB_NOREPLY_EMAIL="${GITHUB_NOREPLY_EMAIL:-}"  # empty = setup.sh looks up "<id>+<user>@users.noreply.github.com" from the public API

# ---------------------------------------------------------------- sandbox (Docker Sandboxes / sbx)
# Defaults: half your CPU cores and half your RAM (capped at 16 cores / 32 GB, sbx's own maximum is 75% of RAM).
_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8); _ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1073741824 ))
_vcpu=$(( _cores / 2 )); [ "$_vcpu" -gt 16 ] && _vcpu=16; [ "$_vcpu" -lt 2 ] && _vcpu=2
_vmem=$(( _ram_gb / 2 )); [ "$_vmem" -gt 32 ] && _vmem=32; [ "$_vmem" -lt 4 ] && _vmem=4
export SBX_NAME="${SBX_NAME:-agent-lab}"
export VM_CPUS="${VM_CPUS:-$_vcpu}"
export VM_MEMORY="${VM_MEMORY:-${_vmem}g}"
export VM_ROOT_SIZE="${VM_ROOT_SIZE:-60g}"                # DOCKER_SANDBOXES_ROOT_SIZE (default 20g). Only applies when the sandbox is created.
export WORKDIR="${WORKDIR:-}"                             # path of the repo clone INSIDE the VM; empty = auto-detected by setup.sh ($HOME/agent-lab in the VM)

# ---------------------------------------------------------------- loop behaviour
export LEAD_MODEL="${LEAD_MODEL:-sonnet}"                 # model for the Lead; subagent models are in agents.json. Aliases (sonnet/opus/haiku) resolve
                                                          # per the sandbox's Claude Code version, which auto-update does NOT change: check the
                                                          # model names in a cycle's output and use full ids (e.g. claude-sonnet-5-5) to pin newer ones.
export PERMISSION_MODE="${PERMISSION_MODE:-dontAsk}"     # dontAsk = allow-list + ENFORCED deny rules (settings.json). bypass = --dangerously-skip-permissions (deny rules ignored). Keep dontAsk unless the supervised hour shows it blocks git.
export MAX_TURNS="${MAX_TURNS:-150}"                      # --max-turns per cycle (hitting it is a NORMAL end, not a crash)
export CYCLE_TIMEOUT="${CYCLE_TIMEOUT:-50m}"              # GNU timeout inside the VM
export CYCLE_PAUSE="${CYCLE_PAUSE:-600}"                  # seconds between productive cycles
export IDLE_PAUSE="${IDLE_PAUSE:-300}"                    # after NOTHING_TO_DO
export IDLE_PAUSE_LONG="${IDLE_PAUSE_LONG:-1800}"         # after 3 consecutive NOTHING_TO_DO
export RATE_LIMIT_SLEEP="${RATE_LIMIT_SLEEP:-3600}"       # when the Max plan limit is hit
export TRANSIENT_SLEEP="${TRANSIENT_SLEEP:-300}"          # API overloaded / network blips
export MAX_CYCLES_PER_DAY="${MAX_CYCLES_PER_DAY:-6}"     # duty-cycle cap, GLOBAL across loops (see DESIGN.md, plan limits)
export FAIL_LIMIT="${FAIL_LIMIT:-5}"                      # consecutive hard failures before the loop halts itself (resume with /go)
export MAX_SUBAGENTS="${MAX_SUBAGENTS:-5}"                # CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS (3 scouts + 2 builders)
export MIN_HOST_FREE_GB="${MIN_HOST_FREE_GB:-150}"        # alert + pause below this much free space on the Mac
export MIN_VM_FREE_GB="${MIN_VM_FREE_GB:-3}"              # pause below this much free space in the VM
# portable  = laptop mode: the lid closing just sleeps the Mac (everything freezes and resumes), no sudo/pmset,
#             and no new cycles start on battery (they resume by themselves when you plug in)
# always-on = desk mode: 'agent-ctl.sh on' runs sudo pmset -a disablesleep 1 so it keeps working with the lid closed.
#             Plugged in, hard surface, NEVER in a bag.
export POWER_MODE="${POWER_MODE:-portable}"
export DEADMAN_HOURS="${DEADMAN_HOURS:-3}"                # alert if main has no new commit for this long while the loop is running

# Optional per-loop overrides (phase 2: a second loop, e.g. a local-model loop). Name pattern: LOOP_<id>_BASE_URL / LOOP_<id>_MODEL
#   export LOOP_local_BASE_URL="http://host.docker.internal:11434"   # verified pattern: needs `sbx policy allow network localhost:11434` first; 127.0.0.1 does NOT reach the host
#   export LOOP_local_MODEL="qwen3-coder"

# ---------------------------------------------------------------- Telegram
export KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-agent-lab-telegram}"   # bot token lives in the macOS Keychain under this service name
export DIGEST_HOUR="${DIGEST_HOUR:-20}"                              # daily digest at 20:00 local time
export TG_CYCLE_UPDATES="${TG_CYCLE_UPDATES:-1}"                     # 1 = a short message after every cycle (class, project, pushed, turns, note); 0 = alerts only
export TG_LIVE_BOARD="${TG_LIVE_BOARD:-1}"                           # 1 = pinned live board in Telegram, edited ~every 45s while a cycle runs (/live off to mute)
export TG_NARRATE="${TG_NARRATE:-1}"                                 # 1 = plain-English summary on the board when each cycle ends (one tool-less Haiku call in the VM, ~$0.02); /explain for one on demand
export TG_NARRATE_MODEL="${TG_NARRATE_MODEL:-haiku}"                 # model alias for that summary

# ---------------------------------------------------------------- network allowlist (deny-all baseline + these)
# Domain level only. Comma separated, no spaces. Wildcards like *.hf.co are supported by sbx.
export ALLOW_ANTHROPIC="${ALLOW_ANTHROPIC:-api.anthropic.com}"
#   If an in-VM `claude /login` token refresh fails, check `sbx policy log` for blocked anthropic/claude domains and add them here.
export ALLOW_GITHUB="${ALLOW_GITHUB:-github.com,api.github.com,codeload.github.com,raw.githubusercontent.com,objects.githubusercontent.com}"
#   Hugging Face's Xet storage serves file bytes from us.aws.cdn.hf.co and cas-server.xethub.hf.co ('*.hf.co' matches one label only).
export ALLOW_RESEARCH="${ALLOW_RESEARCH:-arxiv.org,export.arxiv.org,huggingface.co,*.huggingface.co,hf.co,*.hf.co,us.aws.cdn.hf.co,cas-server.xethub.hf.co,api.semanticscholar.org,hn.algolia.com,hacker-news.firebaseio.com}"
export ALLOW_PACKAGES="${ALLOW_PACKAGES:-pypi.org,files.pythonhosted.org,registry.npmjs.org}"
# Always denied on purpose (the connector proxy). Kept explicit so a typo in an allow rule can never open it.
export DENY_DOMAINS="${DENY_DOMAINS:-mcp-proxy.anthropic.com}"

# ---------------------------------------------------------------- host state (logs, counters, kill switches)
export STATE_DIR="${STATE_DIR:-$HOME/.agent-lab}"
export AGENT_DEPLOY_DIR="${AGENT_DEPLOY_DIR:-$HOME/agent-lab-kit}"   # where the loop, bridge and LaunchAgent run from (outside ~/Documents: macOS blocks LaunchAgents there). deploy.sh copies the kit here.
if [ -z "$WORKDIR" ] && [ -f "$STATE_DIR/workdir" ]; then
  WORKDIR="$(cat "$STATE_DIR/workdir")"
  export WORKDIR
fi
