#!/usr/bin/env bash
# deploy.sh — copy this kit to the run location outside ~/Documents and (re)point everything at it.
#
#   bash deploy.sh [--no-restart]
#
# Why: macOS privacy protection stops LaunchAgents from reading ~/Documents ("Operation not permitted"),
# so the loop, the Telegram bridge and the LaunchAgent run from $AGENT_DEPLOY_DIR (default ~/agent-lab-kit).
# You keep editing the kit where it is; run this to make the edits live.
#
# Safe while a loop runs: rsync replaces files by rename, so a running agent-loop.sh keeps reading its old copy
# and picks up the new one the next time it starts. The Telegram bridge is restarted (it has no in-flight work).
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SRC/config.sh"
DEST="$AGENT_DEPLOY_DIR"
RESTART=1; [ "${1:-}" = "--no-restart" ] && RESTART=0

[ "$SRC" = "$DEST" ] && { echo "deploy.sh: already running from $DEST; run the copy you edit instead." >&2; exit 2; }
case "$DEST" in "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*)
  echo "deploy.sh: AGENT_DEPLOY_DIR=$DEST is a macOS-protected folder; LaunchAgents cannot read it." >&2; exit 2 ;;
esac

mkdir -p "$DEST"
rsync -a --delete --exclude .git --exclude .gitignore --exclude __pycache__ --exclude .DS_Store "$SRC/" "$DEST/" \
  || { echo "deploy.sh: copy failed" >&2; exit 1; }
chmod +x "$DEST"/*.sh "$DEST"/tg-bridge.py 2>/dev/null
echo "  [ok]   kit copied to $DEST"

plist="$HOME/Library/LaunchAgents/com.agentlab.boot.plist"
if ! grep -q "$DEST/agent-ctl.sh" "$plist" 2>/dev/null; then
  bash "$DEST/setup.sh" launchd
fi

mplist="$HOME/Library/LaunchAgents/com.agentlab.manager.plist"
if [ -f "$mplist" ] && ! grep -q "$DEST/manager.sh" "$mplist"; then
  bash "$DEST/setup.sh" manager
fi
gplist="$HOME/Library/LaunchAgents/com.agentlab.bagguard.plist"
if [ -f "$gplist" ] && ! grep -q "$DEST/bag-guard.sh" "$gplist"; then
  bash "$DEST/setup.sh" bagguard
fi

if [ "$RESTART" -eq 1 ] && tmux has-session -t agent-tg 2>/dev/null; then
  tmux kill-session -t agent-tg
  envclean="env$(sed -nE 's/^export ([A-Z_][A-Z0-9_]*)=.*/ -u \1/p' "$DEST/config.sh" | grep -v ' -u PATH$' | tr -d '\n')"   # see agent-ctl.sh clean_env
  tmux new-session -d -s agent-tg "cd '$DEST' && exec $envclean bash -c '. ./config.sh && exec python3 tg-bridge.py run'" \
    && echo "  [ok]   Telegram bridge restarted on the new code"
fi
if tmux ls -F '#S' 2>/dev/null | grep -q '^agent-loop'; then
  echo "  [..]   running loop(s) switch to the new code at their next restart (./agent-ctl.sh off && ./agent-ctl.sh on)"
fi
