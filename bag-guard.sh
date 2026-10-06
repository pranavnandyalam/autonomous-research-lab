#!/usr/bin/env bash
# bag-guard.sh — run every 30s by the com.agentlab.bagguard LaunchAgent (POWER_MODE=portable only).
#
# Amphetamine keeps the Mac awake with the lid closed on the charger (pmset disablesleep 1). Tested 2026-10-05:
# after unplugging with the lid closed, Amphetamine ended its session but disablesleep stayed 1, so the Mac stayed
# awake on battery: the hot-bag case. A Claude Code session's `caffeinate -i` did the same with the override off.
# On battery this guard turns the override off and, if the lid is closed, puts the Mac to sleep (pmset sleepnow).
#
# It only ever runs `/usr/bin/pmset -a disablesleep 0`, through the passwordless rule Amphetamine's Power Protect
# installed (/private/etc/sudoers.d/amphetamine_powerProtect), plus `pmset sleepnow`. It never turns lid-closed mode on,
# and never sleeps the Mac while the lid is open or the charger is connected.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"

[ "$POWER_MODE" = "portable" ] || exit 0
pmset -g ps 2>/dev/null | head -1 | grep -q "Battery Power" || exit 0

lid=$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null | sed -nE 's/.*"AppleClamshellState" = (Yes|No).*/\1/p' | head -1)
sd=0; pmset -g 2>/dev/null | grep -Eq 'SleepDisabled[[:space:]]+1' && sd=1
[ "$sd" -eq 1 ] || [ "$lid" = "Yes" ] || exit 0   # on battery, lid open, override off: nothing to do

msg=""
if [ "$sd" -eq 1 ]; then
  if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then msg="Turned lid-closed mode off (on battery)."
  else msg="On battery with lid-closed mode on and could NOT turn it off (Power Protect rule missing?)."; fi
fi
if [ "$lid" = "Yes" ]; then
  # Tested 2026-10-05: unplugging with the lid already closed sends no new lid event, and any idle-sleep blocker
  # (e.g. Claude Code runs `caffeinate -i` while it works) keeps the Mac awake in the bag. Put it to sleep now.
  msg="${msg:+$msg }Lid closed on battery: putting the Mac to sleep."
fi
mkdir -p "$STATE_DIR"
echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$STATE_DIR/bag-guard.log"
if [ "$lid" = "Yes" ]; then
  pmset sleepnow >/dev/null 2>&1 || echo "$(date '+%Y-%m-%d %H:%M:%S') pmset sleepnow failed" >> "$STATE_DIR/bag-guard.log"
else
  python3 "$KIT/tg-bridge.py" send "[bag-guard] $msg" >/dev/null 2>&1   # lid open: the Mac is awake to send it
fi
exit 0
