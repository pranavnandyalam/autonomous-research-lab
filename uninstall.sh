#!/usr/bin/env bash
# uninstall.sh — remove everything the agent-lab kit set up on this Mac. Asks before each part.
#
#   bash uninstall.sh [--dry-run]
#
# Never touches the GitHub repo by itself (your research lives there); it prints what to do on GitHub/Telegram.
# Order: stop -> save check -> sandbox -> background jobs -> secrets -> sbx config -> files -> optional tools.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"
DRYRUN=0; [ "${1:-}" = "--dry-run" ] && DRYRUN=1

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
run()  { if [ "$DRYRUN" -eq 1 ]; then printf '  [dry]  %s\n' "$*"; else "$@"; fi; }
ask()  { [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would ask: %s\n' "$1"; return 0; }
         local r; printf '  ?  %s [y/N] ' "$1"; read -r r; case "$r" in y|Y|yes) return 0 ;; *) return 1 ;; esac; }

hdr "1. stop everything"
for s in $(tmux ls -F '#S' 2>/dev/null | grep '^agent-'); do run tmux kill-session -t "$s" && say "  stopped tmux session $s"; done
rm -f "$STATE_DIR/ENABLED" 2>/dev/null
if pmset -g 2>/dev/null | grep -Eq 'SleepDisabled[[:space:]]+1'; then
  run sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || run sudo pmset -a disablesleep 0
  say "  normal sleep restored"
fi

hdr "2. unpushed work check"
wd="${WORKDIR:-$(cat "$STATE_DIR/workdir" 2>/dev/null)}"
if [ -n "$wd" ] && sbx ls 2>/dev/null | grep -q "$SBX_NAME"; then
  dirty=$(sbx exec -w "$wd" "$SBX_NAME" bash -c 'git status --porcelain | head -5; git log --oneline origin/main..HEAD 2>/dev/null | head -5' 2>/dev/null </dev/null)
  if [ -n "$dirty" ]; then say "  The sandbox has work that is NOT on GitHub:"; printf '%s\n' "$dirty" | sed 's/^/    /'
  else say "  everything in the sandbox is on GitHub"; fi
fi

hdr "3. sandbox"
if sbx ls 2>/dev/null | grep -q "$SBX_NAME" && ask "Delete the sandbox '$SBX_NAME' (its disk and its stored GitHub token)?"; then
  run sbx rm -f "$SBX_NAME" && say "  sandbox removed"
fi

hdr "4. background jobs (LaunchAgents)"
for label in com.agentlab.boot com.agentlab.bagguard com.agentlab.manager; do
  plist="$HOME/Library/LaunchAgents/$label.plist"
  [ -f "$plist" ] || continue
  run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; run rm -f "$plist"; say "  removed $label"
done

hdr "5. secrets on this Mac"
if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 && ask "Delete the Telegram bot token from the Keychain?"; then
  run security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null && say "  Telegram token removed"
fi

hdr "6. Docker Sandboxes configuration"
if command -v sbx >/dev/null 2>&1 && ask "Reset sbx network policy and the 3 settings the kit changed, and sign out of Docker?"; then
  run sbx policy reset --force
  for k in ssh.agentForwardingEnabled diagnostics.autoUpload skills.defaultMode; do run sbx settings unset "$k"; done
  run sbx logout -y
fi

hdr "7. files"
if ask "Delete ~/.agent-lab (logs, cycle outputs, state) and the deployed copy $AGENT_DEPLOY_DIR?"; then
  run rm -rf "$STATE_DIR" "$AGENT_DEPLOY_DIR" && say "  removed"
fi

hdr "8. tools (optional)"
if ask "Uninstall the sbx and tmux Homebrew packages (skip if you use tmux elsewhere)?"; then
  run brew uninstall --cask sbx; run brew untap docker/tap; run brew uninstall tmux
fi

hdr "Left for you (outside this Mac, or not ours to delete)"
cat <<EOF
  - GitHub: revoke the fine-grained token at https://github.com/settings/personal-access-tokens
  - GitHub: keep, archive (gh repo archive $GITHUB_USER/$REPO) or delete the repo $REPO; the ruleset goes with it
  - Telegram: message @BotFather, /deletebot, pick your bot
  - Amphetamine: delete the "power adapter connected" trigger; Power Protect lives in
    ~/Library/Application Scripts/com.if.Amphetamine/ and /private/etc/sudoers.d/amphetamine_powerProtect
    (remove with: sudo rm /private/etc/sudoers.d/amphetamine_powerProtect)
  - this kit folder itself ($KIT) and its git repo are yours to keep or delete
EOF
