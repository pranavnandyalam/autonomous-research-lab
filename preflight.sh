#!/usr/bin/env bash
# preflight.sh — automated safety checks for the sandbox. Run after setup.sh and after any change to policy/secrets.
#
#   bash preflight.sh           isolation, network, secrets, repo scope, sleep (no model usage)
#   bash preflight.sh --live    also runs two tiny Claude calls inside the VM (uses a little of your Max quota)
#
# PASS = good, FAIL = fix before turning the agent on, WARN = look at it, INFO = for your eyes.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"
LIVE=0; [ "${1:-}" = "--live" ] && LIVE=1
PASS=0; FAIL=0; WARN=0
pass() { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  WARN  %s\n' "$*"; WARN=$((WARN + 1)); }
info() { printf '  INFO  %s\n' "$*"; }
vmx() { sbx exec "$SBX_NAME" "$@"; }
vmsh() { sbx exec "$SBX_NAME" bash -c "$1"; }
code() { vmsh "curl -sS -m 10 -o /dev/null -w '%{http_code}' '$1' 2>/dev/null" 2>/dev/null; }

echo "== reachability"
vmx true >/dev/null 2>&1 && pass "can exec into '$SBX_NAME'" || { fail "cannot exec into '$SBX_NAME' (is the sbx daemon running? sbx daemon start; sbx ls)"; echo; echo "Result: $PASS pass, $FAIL fail"; exit 1; }

echo "== 1-3 network: deny-all baseline with a working allowlist"
c=$(code https://example.com);            case "$c" in 2*|3*) fail "example.com reachable ($c): the baseline is not deny-all" ;; *) pass "example.com blocked (${c:-no response})" ;; esac
c=$(code https://mcp-proxy.anthropic.com); case "$c" in 2*|3*) fail "mcp-proxy.anthropic.com reachable ($c): connectors can leak in" ;; *) pass "mcp-proxy.anthropic.com blocked (${c:-no response})" ;; esac
c=$(code https://arxiv.org/);              [ "$c" = "200" ] && pass "arxiv.org allowed (200)" || fail "arxiv.org returned '${c:-none}' (expected 200). Check: sbx policy ls ; sbx policy log"
c=$(code https://pypi.org/simple/pip/);   [ "$c" = "200" ] && pass "pypi.org allowed (200)" || warn "pypi.org returned '${c:-none}'"
c=$(code https://huggingface.co/api/models?limit=1); [ "$c" = "200" ] && pass "huggingface.co allowed (200)" || warn "huggingface.co returned '${c:-none}'"
info "policy rules: run 'sbx policy ls' (look for deny-all baseline + your allow lines) and 'sbx policy log' for denials"

echo "== 5 host isolation"
# the sbx image always exports SSH_AUTH_SOCK; what matters is whether a live socket is behind it (ssh.agentForwardingEnabled false)
r=$(vmsh '[ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] && echo "$SSH_AUTH_SOCK"'); [ -z "$r" ] && pass "no live SSH agent socket in the VM" || fail "SSH agent is forwarded into the VM: $r (sbx settings set ssh.agentForwardingEnabled false; sbx daemon restart)"
r=$(vmsh 'ls /Users 2>/dev/null | head -1'); [ -z "$r" ] && pass "no /Users (host home is not mounted)" || fail "/Users exists in the VM: $r"
r=$(vmsh 'mount | grep -Ei "virtiofs|9p|fuse.sshfs|osxfs" | head -3'); [ -z "$r" ] && pass "no shared-folder mounts" || warn "shared mounts present: $r"

echo "== 6-7 secrets never inside the VM"
r=$(vmsh 'env | grep -iE "token|secret|key|password" | grep -v "proxy-managed" | sed "s/=.*/=<redacted>/"'); [ -z "$r" ] && pass "no secret-looking env vars (proxy-managed sentinels are fine)" || warn "env vars that look like secrets (values hidden): $(echo "$r" | tr '\n' ' ')"
# in-VM /login legitimately stores a token under ~/.claude, so that is excluded; anywhere else is a FAIL
# match a real token shape, not the literal prefix: the pre-commit hook's own detection regex contains "sk-ant-["
r=$(vmsh 'grep -rIlE --exclude-dir=.claude --exclude=.claude.json "sk-ant-[A-Za-z0-9_-]{20,}" "$HOME" 2>/dev/null | head -3'); [ -z "$r" ] && pass "no Anthropic tokens outside ~/.claude" || fail "Anthropic token string found outside ~/.claude: $r"
r=$(vmsh 'grep -rIlE "ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}" "$HOME" 2>/dev/null | head -3'); [ -z "$r" ] && pass "no GitHub tokens under the VM home" || fail "GitHub token found in: $r"
r=$(vmsh 'git config --global --get credential.helper; ls ~/.git-credentials ~/.config/gh/hosts.yml 2>/dev/null'); [ -z "$r" ] && pass "no stored git/gh credentials" || warn "credential files/helpers present: $r"

echo "== 8-10 GitHub scope (token injected by the host proxy)"
if vmsh 'command -v gh' >/dev/null 2>&1; then
  c=$(vmsh "gh api repos/$GITHUB_USER/$REPO -i 2>/dev/null | head -1"); case "$c" in *200*) pass "can read $GITHUB_USER/$REPO" ;; *) fail "cannot read $GITHUB_USER/$REPO: '$c' (is the github secret set for this sandbox?)" ;; esac
  # user/repos also lists PUBLIC repos to any token, and .permissions reflects the account, not the token,
  # so check (a) the only PRIVATE repo visible is $REPO and (b) a dry-run push to another repo is refused
  r=$(vmsh "gh api user/repos --paginate --jq '.[] | select(.private) | .full_name' 2>/dev/null" | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'); n=$(printf '%s\n' "$r" | grep -c .)
  if [ "$n" -eq 1 ] && [ "$r" = "$GITHUB_USER/$REPO" ]; then pass "only private repo visible to the token: $r"; elif [ "$n" -eq 0 ]; then warn "could not list repos (token may lack Metadata:read)"; else fail "token can see $n private repos (expected only $GITHUB_USER/$REPO): $(echo "$r" | head -5 | tr '\n' ' ')"; fi
  other=$(vmsh "gh api user/repos --paginate --jq '.[] | select(.owner.login == \"$GITHUB_USER\" and .full_name != \"$GITHUB_USER/$REPO\") | .full_name' 2>/dev/null" | head -1)
  if [ -n "$other" ] && [ -n "${WORKDIR:-}" ]; then
    # --dry-run authenticates for write but sends nothing and creates no ref
    out=$(sbx exec -w "$WORKDIR" "$SBX_NAME" git push --dry-run "https://github.com/$other.git" HEAD:refs/heads/zz-preflight-probe 2>&1 </dev/null)
    case "$out" in *403*|*denied*|*"not found"*) pass "token cannot write to other repos ($other refused)" ;; *) fail "token may be able to write to $other: $(echo "$out" | tail -1)" ;; esac
  else info "write-scope probe skipped (no other repo visible, or WORKDIR unknown)"; fi
  tname="agent-preflight-$(date +%s)"
  out=$(vmsh "gh repo create $GITHUB_USER/$tname --private 2>&1"); rc=$?
  if [ "$rc" -ne 0 ]; then pass "repo creation fails as intended"; else fail "REPO CREATION SUCCEEDED ($tname). Delete it on GitHub now and tighten the token: $out"; fi
else
  warn "gh is not installed in the VM; testing with git instead"
  vmx git ls-remote "https://github.com/$GITHUB_USER/$REPO.git" >/dev/null 2>&1 && pass "git can reach $REPO" || fail "git cannot reach $REPO"
fi
r=$(vmx git config --global --get user.email); [ -n "$r" ] && pass "git identity set ($r)" || fail "git user.email not set (run: bash setup.sh identity)"
case "$r" in *users.noreply.github.com) : ;; *) [ -n "$r" ] && warn "email is not a GitHub noreply address; commits may not link to your profile" ;; esac

echo "== 11 connector leak (claude.ai MCP)"
r=$(vmsh 'ENABLE_CLAUDEAI_MCP_SERVERS=false timeout 60 claude mcp list 2>&1 | head -20')
if printf '%s' "$r" | grep -qiE 'gmail|drive|vercel|robinhood|claude\.ai'; then fail "claude.ai connectors visible even with the env var: $(echo "$r" | head -5 | tr '\n' ' ')"
else pass "no claude.ai connectors listed (loop also passes --strict-mcp-config and --disallowedTools 'mcp__*')"; fi
info "ENABLE_CLAUDEAI_MCP_SERVERS is real but undocumented; the other two flags are documented and are the real guard"

echo "== 12 sleep / disk"
if [ "${POWER_MODE:-portable}" = "portable" ]; then
  info "POWER_MODE=portable: the lid closing sleeps the Mac; no new cycles on battery"
  launchctl print "gui/$(id -u)/com.agentlab.bagguard" >/dev/null 2>&1 && pass "bag guard LaunchAgent loaded" \
    || info "bag guard not installed (only needed with Amphetamine lid-closed mode: bash setup.sh bagguard)"
elif command -v pmset >/dev/null 2>&1; then pmset -g | grep -Eq 'SleepDisabled[[:space:]]+1' && pass "SleepDisabled=1 (lid-closed operation ok)" || warn "SleepDisabled is not 1 (fine until you run ./agent-ctl.sh on)"; fi
df -k / | awk -v m="$MIN_HOST_FREE_GB" 'NR==2{g=$4/1048576; if (g<m) printf "  WARN  Mac free disk %.0fGB is below %dGB\n", g, m; else printf "  PASS  Mac free disk %.0fGB\n", g}'
sz=$(vmsh 'df -k / | awk "NR==2{printf \"%d %d\", \$2/1048576, \$4/1048576}"'); info "VM disk (total free GB): $sz"

echo "== tooling inside the VM"
for c in git python3 pip3 node gh timeout curl; do vmsh "command -v $c" >/dev/null 2>&1 && pass "$c present" || warn "$c missing in the VM"; done
vmsh 'sudo -n true' >/dev/null 2>&1 && info "the agent user has passwordless sudo (the manual and settings.json forbid using it)" || info "no passwordless sudo"

if [ "$LIVE" -eq 1 ]; then
  echo "== live Claude checks (uses a little quota)"
  PM="--permission-mode dontAsk"; [ "${PERMISSION_MODE:-dontAsk}" = "bypass" ] && PM="--dangerously-skip-permissions"
  SET="$(tr -d '\n' < "$KIT/settings.json")"
  out=$(sbx exec "$SBX_NAME" timeout 180 claude -p "Reply with exactly: PREFLIGHT_OK" --max-turns 3 $PM --settings "$SET" --no-session-persistence --strict-mcp-config --disallowedTools "mcp__*" --output-format json 2>&1)
  printf '%s' "$out" | grep -q 'PREFLIGHT_OK' && pass "claude -p works in the VM (auth + api.anthropic.com allowed)" || fail "claude -p failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  agents=$(python3 "$KIT/render.py" "$KIT/agents.json")
  out=$(sbx exec -w "${WORKDIR:-/tmp}" "$SBX_NAME" timeout 240 claude -p "Use the Agent tool to call the scout subagent with the task: reply with the single word SCOUT_OK and nothing else. Then print the subagent's reply." --max-turns 6 $PM --settings "$SET" --no-session-persistence --strict-mcp-config --disallowedTools "mcp__*" --output-format json --agents "$agents" 2>&1)
  printf '%s' "$out" | grep -q 'SCOUT_OK' && pass "--agents injection works and a scout subagent ran" || warn "subagent test inconclusive: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  out=$(sbx exec -w "${WORKDIR:-/tmp}" "$SBX_NAME" timeout 180 claude -p "Run this exact shell command and show its output: sudo true" --max-turns 4 $PM --no-session-persistence --strict-mcp-config --disallowedTools "mcp__*" --output-format json --settings "$SET" 2>&1)
  printf '%s' "$out" | grep -qiE 'denied|not allowed|permission|blocked|refus' && pass "deny rule canary: 'sudo' was refused" || warn "deny rule canary inconclusive (expected under bypass, where deny rules are ignored): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  # git must still work under the chosen permission mode (.git is a protected path)
  vmsh 'rm -rf /tmp/pf-git && mkdir -p /tmp/pf-git && cd /tmp/pf-git && git init -q' >/dev/null 2>&1
  sbx exec -w /tmp/pf-git "$SBX_NAME" timeout 180 claude -p "Create a file a.txt containing hi, then run: git add a.txt && git commit -m preflight" --max-turns 6 $PM --no-session-persistence --strict-mcp-config --disallowedTools "mcp__*" --output-format json --settings "$SET" >/dev/null 2>&1
  out=$(vmsh 'git -C /tmp/pf-git log --oneline 2>/dev/null | head -1')
  [ -n "$out" ] && pass "claude can write files and git commit under $PM ($out)" || fail "claude could NOT commit under $PM. If dontAsk blocks git, set PERMISSION_MODE=bypass in config.sh (deny rules then stop working; see DESIGN.md)"
fi

echo
echo "Result: $PASS pass, $WARN warn, $FAIL fail"
[ "$FAIL" -eq 0 ] || { echo "Fix every FAIL before turning the agent on."; exit 1; }
exit 0
