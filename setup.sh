#!/usr/bin/env bash
# setup.sh — idempotent setup for the agent-lab kit. Safe to re-run; each step skips what is already done.
#
#   bash setup.sh [--dry-run] [step ...]
#
# Steps (default: all, in this order):
#   check      tools, FileVault note, config sanity
#   sbx        sbx settings (no SSH agent forwarding, no diagnostics upload, no shared skills) + daemon restart
#   policy     network policy: deny-all baseline + explicit allowlist from config.sh
#   vm         create the mountless sandbox (CPU/RAM/disk, connector isolation env) and verify its disk
#   secrets    GitHub token (host proxy, never inside the VM) and Claude auth (you paste/sign in)
#   identity   git identity inside the VM (your GitHub noreply email so commits count on your profile)
#   clone      clone the repo inside the VM and record its path
#   seed       copy repo-seed/ files that are missing into the clone, push them, install the pre-commit hook
#   telegram   bot token into the Keychain + selftest (optional)
#   launchd    LaunchAgent that restores the agent after login/reboot if you had it ON
#   team       (not in the default run) TEAM=<id> bash setup.sh team: give another agent team its own clone
#   manager    (not in the default run) daily read-only manager review: its own clone + LaunchAgent at MANAGER_HOUR:MINUTE
#   referee    (not in the default run) external paper referee: its own clone (referee.sh runs after pushed cycles)
#   bagguard   (not in the default run) LaunchAgent that turns lid-closed mode off on battery; needs Amphetamine Power Protect
#   pmset      keep the Mac awake with the lid closed (sudo)
#   summary    what only you can do
#
# Everything the script runs against sbx/sudo goes through run(); --dry-run prints instead of executing.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"
DRYRUN=0; STEPS=""
for a in "$@"; do case "$a" in --dry-run) DRYRUN=1 ;; -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; *) STEPS="$STEPS $a" ;; esac; done
[ -n "$STEPS" ] || STEPS="check sbx policy vm secrets identity clone seed telegram launchd pmset summary"
mkdir -p "$STATE_DIR"

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; WARNED=1; }
info() { printf '  [..]   %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }
hdr()  { printf '\n== %s\n' "$*"; }
WARNED=0
run() { if [ "$DRYRUN" -eq 1 ]; then printf '  [dry]  %s\n' "$*"; return 0; fi; "$@"; }
getvar() { eval "printf '%s' \"\${$1:-}\""; }
ask() { # ask "question" -> 0 if yes
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would ask: %s\n' "$1"; return 1; }
  local r; printf '  ?  %s [y/N] ' "$1"; read -r r; case "$r" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}
vmx() { sbx exec "$SBX_NAME" "$@"; }
split_commas() { printf '%s' "$1" | tr ',' ' '; }

step_check() {
  hdr "check"
  [ "$(uname -s)" = "Darwin" ] || warn "this kit is written for macOS (found $(uname -s))"
  [ "$(uname -m)" = "arm64" ] || warn "expected Apple Silicon (arm64), found $(uname -m)"
  local miss=0 c
  for c in sbx tmux python3 perl git security caffeinate pmset curl; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c: $(command -v "$c")"; else warn "missing: $c"; miss=1; fi
  done
  if [ "$miss" -eq 1 ] && [ "$DRYRUN" -eq 0 ]; then
    info "install tmux with: brew install tmux"
    info "install Docker Sandboxes (sbx): https://docs.docker.com/ai/sandboxes/get-started/"
    die "install the missing tools and re-run"
  fi
  command -v sbx >/dev/null 2>&1 && info "sbx version: $(sbx version 2>&1 | head -1)  (record it; update deliberately, not automatically)"
  if command -v fdesetup >/dev/null 2>&1 && fdesetup status 2>/dev/null | grep -qi 'is On'; then
    ok "FileVault is on. After a cold reboot nothing runs until you type your password at the login screen."
    info "for planned restarts use: sudo fdesetup authrestart   (reboots once without the pre-boot password prompt; test it once)"
  fi
  [ -f "$KIT/config.local.sh" ] || die "no config.local.sh: cp config.local.sh.example config.local.sh, then edit it"
  [ -n "$GITHUB_USER" ] || die "GITHUB_USER is empty: set it in config.local.sh"
  [ -n "$OWNER_NAME" ] || die "OWNER_NAME is empty: set it in config.local.sh"
  for t in prompt.md agents.json; do python3 "$KIT/render.py" "$KIT/$t" >/dev/null || die "$t could not be filled from config.local.sh"; done
  [ -n "$TG_ALLOWED_USER_ID" ] || info "TG_ALLOWED_USER_ID is empty: Telegram stays off and alerts use macOS notifications"
  for f in prompt.md agents.json settings.json agent-loop.sh tg-bridge.py agent-ctl.sh preflight.sh render.py; do [ -f "$KIT/$f" ] || die "missing kit file: $f"; done
  python3 -m json.tool "$KIT/agents.json" >/dev/null && python3 -m json.tool "$KIT/settings.json" >/dev/null && ok "agents.json and settings.json are valid JSON"
  chmod +x "$KIT"/*.sh "$KIT"/tg-bridge.py 2>/dev/null
}

step_sbx() {
  hdr "sbx settings"
  run sbx settings set ssh.agentForwardingEnabled false || warn "could not set ssh.agentForwardingEnabled"
  run sbx settings set diagnostics.autoUpload no || warn "could not set diagnostics.autoUpload (check 'sbx settings set --help' for the value format)"
  run sbx settings set skills.defaultMode off || warn "could not set skills.defaultMode"
  run sbx daemon restart || warn "daemon restart failed (try: sbx daemon start)"
  ok "settings applied"
}

step_policy() {
  hdr "network policy (deny-all baseline + allowlist)"
  if [ "$DRYRUN" -eq 0 ] && sbx policy ls 2>/dev/null | grep -q 'arxiv.org'; then
    ok "allowlist already present (review with: sbx policy ls). Skipping. Edit config.sh and run 'sbx policy rm network --resource <domain>' / re-allow to change it."
    return 0
  fi
  run sbx policy init deny-all || warn "policy init failed or already initialised"
  local name list
  for name in ALLOW_ANTHROPIC ALLOW_GITHUB ALLOW_RESEARCH ALLOW_PACKAGES; do
    list="$(getvar "$name")"
    [ -n "$list" ] || continue
    run sbx policy allow network "$list" && ok "allowed ($name): $list" || warn "allow failed for $name"
  done
  local d
  for d in $(split_commas "$DENY_DOMAINS"); do run sbx policy deny network "$d" && ok "denied: $d" || warn "deny failed for $d"; done
  if [ "$DRYRUN" -eq 0 ] && sbx policy allow network --help 2>&1 | grep -q -- '--method'; then
    info "this sbx build advertises --method/--path on 'policy allow network'. The docs disagree about it, so the kit does not depend on it."
    info "optional hardening (see DESIGN.md): restrict github.com to /$GITHUB_USER/$REPO.git/** with --path, after testing."
  fi
  info "if something legitimate is blocked later, 'sbx policy log' shows the denied domain"
}

step_vm() {
  hdr "sandbox"
  if [ "$DRYRUN" -eq 0 ] && sbx ls 2>/dev/null | grep -qE "(^|[[:space:]])$SBX_NAME([[:space:]]|$)"; then
    ok "sandbox '$SBX_NAME' already exists"
  else
    local denies="" d
    for d in $(split_commas "$DENY_DOMAINS"); do denies="$denies --deny-network $d"; done
    # shellcheck disable=SC2086
    if [ "$DRYRUN" -eq 1 ]; then
      printf '  [dry]  DOCKER_SANDBOXES_ROOT_SIZE=%s sbx create --name %s --cpus %s --memory %s%s -e ENABLE_CLAUDEAI_MCP_SERVERS=false -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude\n' "$VM_ROOT_SIZE" "$SBX_NAME" "$VM_CPUS" "$VM_MEMORY" "$denies"
    else
      DOCKER_SANDBOXES_ROOT_SIZE="$VM_ROOT_SIZE" sbx create --name "$SBX_NAME" --cpus "$VM_CPUS" --memory "$VM_MEMORY" $denies \
        -e ENABLE_CLAUDEAI_MCP_SERVERS=false -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude || die "sbx create failed"
      ok "created '$SBX_NAME' (mountless: no host folder is shared)"
    fi
  fi
  run sbx exec "$SBX_NAME" true >/dev/null 2>&1   # there is no `sbx start`; exec auto-starts the sandbox
  if [ "$DRYRUN" -eq 0 ]; then
    vmx true >/dev/null 2>&1 || die "cannot exec into '$SBX_NAME'"
    local sizegb; sizegb=$(vmx df -k / 2>/dev/null | awk 'NR==2{printf "%d", $2/1048576}')
    info "VM root disk: ${sizegb:-?}GB total"
    if [ -n "${sizegb:-}" ] && [ "$sizegb" -lt 40 ]; then
      warn "VM disk is only ${sizegb}GB. DOCKER_SANDBOXES_ROOT_SIZE only applies at create time: sbx rm $SBX_NAME, then re-run setup (and re-set the github secret)."
    fi
    for c in git python3 pip3 node gh timeout curl; do vmx bash -c "command -v $c" >/dev/null 2>&1 && ok "in VM: $c" || warn "in VM: $c is missing (the agent works around it or asks)"; done
    { echo "date: $(date)"; echo "sbx: $(sbx version 2>&1 | head -1)"; echo "claude (in VM): $(vmx claude --version 2>&1 | head -1)"; } > "$STATE_DIR/versions.txt"
    info "versions recorded in $STATE_DIR/versions.txt (CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 also disables Claude Code auto-update)"
  fi
}

step_secrets() {
  hdr "secrets (never stored inside the VM)"
  info "GitHub: create a fine-grained PAT at https://github.com/settings/personal-access-tokens/new"
  info "  Resource owner: you | Repository access: ONLY select repositories -> $REPO | Expiry: 90 days"
  info "  Permissions: Contents RW, Issues RW, Pull requests RW, Metadata R. Nothing else."
  if ask "Run 'sbx secret set github --sandbox $SBX_NAME' now (it prompts for the token)?"; then
    sbx secret set github --sandbox "$SBX_NAME" && ok "github secret stored in the host proxy for '$SBX_NAME'" || warn "secret set failed"
  else info "do it later: sbx secret set github --sandbox $SBX_NAME"; fi
  info "  Do NOT use 'sbx secret set github --command \"gh auth token\"': that hands the proxy your broad gh login token (every repo), not the agent-lab-only PAT."
  info "Claude auth (Max subscription): sbx exec -it $SBX_NAME claude   then type /login and finish in the browser."
  info "  Docker docs: with a Claude subscription the session token stays on the host and is never stored inside the sandbox."
  info "  ('sbx secret set anthropic --oauth' is not an option locally: sbx v0.46 limits local --oauth to openai.) preflight.sh still scans the VM for tokens."
  info "after any 'sbx rm' + re-create you must set the github secret again (sandbox-scoped secrets are deleted with the sandbox)"
}

step_identity() {
  hdr "git identity in the VM"
  local email="$GITHUB_NOREPLY_EMAIL" id
  if [ -z "$email" ]; then
    id=$(curl -fsS "https://api.github.com/users/$GITHUB_USER" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)
    [ -n "${id:-}" ] || { warn "could not look up your GitHub numeric id; set GITHUB_NOREPLY_EMAIL in config.sh (https://github.com/settings/emails shows it)"; return 0; }
    email="${id}+${GITHUB_USER}@users.noreply.github.com"
  fi
  run sbx exec "$SBX_NAME" git config --global user.email "$email"
  run sbx exec "$SBX_NAME" git config --global user.name "$GIT_NAME"
  run sbx exec "$SBX_NAME" git config --global pull.rebase true
  run sbx exec "$SBX_NAME" git config --global rebase.autoStash true
  run sbx exec "$SBX_NAME" git config --global init.defaultBranch main
  ok "commits will be authored as '$GIT_NAME' <$email>"
  info "for the contribution graph: GitHub profile -> Contribution settings -> enable 'Include private contributions'; commits must be on the default branch"
}

step_clone() {
  hdr "repo clone inside the VM"
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would clone https://github.com/%s/%s.git into the VM home and record the path\n' "$GITHUB_USER" "$REPO"; return 0; }
  local home wd
  home=$(vmx bash -c 'echo $HOME' | tr -d '\r'); [ -n "$home" ] || die "could not read the VM home directory"
  wd="$home/$REPO"
  if vmx test -d "$wd/.git"; then ok "already cloned at $wd"
  else
    vmx git ls-remote "https://github.com/$GITHUB_USER/$REPO.git" >/dev/null 2>&1 \
      || { warn "cannot reach the repo from the VM. Check: the repo exists (create it PRIVATE with 'Add a README' ticked so main exists), the github secret is set, 'sbx policy log' for blocked domains."; return 0; }
    vmx git clone "https://github.com/$GITHUB_USER/$REPO.git" "$wd" && ok "cloned to $wd" || { warn "clone failed"; return 0; }
  fi
  echo "$wd" > "$STATE_DIR/workdir"; ok "recorded WORKDIR=$wd in $STATE_DIR/workdir"
}

step_seed() {
  hdr "seed the repo (only files that do not exist yet) + pre-commit hook"
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would copy missing repo-seed/ files into the clone, commit [meta] seed, push, install hook\n'; return 0; }
  local wd; wd="$(cat "$STATE_DIR/workdir" 2>/dev/null)"; [ -n "$wd" ] || { warn "no clone recorded; run: bash setup.sh clone"; return 0; }
  local f n=0
  # sbx exec reads stdin even without -i, so every non -i call in this loop needs </dev/null or it eats the file list
  ( cd "$KIT/repo-seed" && find . -type f | sed 's|^\./||' ) | while read -r f; do
    if sbx exec -w "$wd" "$SBX_NAME" test -e "$f" </dev/null; then continue; fi
    sbx exec -w "$wd" "$SBX_NAME" mkdir -p "$(dirname "$f")" </dev/null
    python3 "$KIT/render.py" "$KIT/repo-seed/$f" | sbx exec -i -w "$wd" "$SBX_NAME" sh -c "cat > '$f'" && echo "  [ok]   added $f"
  done
  if [ -n "$(sbx exec -w "$wd" "$SBX_NAME" git status --porcelain)" ]; then
    sbx exec -w "$wd" "$SBX_NAME" git add -A
    sbx exec -w "$wd" "$SBX_NAME" git commit -q -m "[meta] seed lab structure" && \
      sbx exec -w "$wd" "$SBX_NAME" git push -q origin HEAD:main && ok "seed files pushed to main" || warn "seed commit/push failed"
  else ok "repo already has every seed file"; fi
  sbx exec -i -w "$wd" "$SBX_NAME" sh -c 'cat > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit' < "$KIT/pre-commit-hook.sh" && ok "pre-commit hook installed (secrets, >5MB files, .claude/CLAUDE.md/.mcp.json/workflows/north-star.md blocked)"
  info "now edit north-star.md on GitHub with your real goals (the agent may never edit it)"
}

step_telegram() {
  hdr "telegram (optional)"
  if [ -z "$TG_ALLOWED_USER_ID" ]; then
    info "skipped: set TG_ALLOWED_USER_ID in config.sh (message @userinfobot for your numeric id), create a bot with @BotFather, then re-run: bash setup.sh telegram"
    info "also turn on two-step verification in Telegram, and press Start in the new bot's chat once."
    return 0
  fi
  if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then ok "bot token already in the Keychain ($KEYCHAIN_SERVICE)"
  elif ask "Store the bot token in the Keychain now (you will be prompted to paste it)?"; then
    security add-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -U -w && ok "stored" || warn "could not store the token"
  fi
  if [ "$DRYRUN" -eq 0 ] && security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    python3 "$KIT/tg-bridge.py" selftest && ok "telegram works" || warn "telegram selftest failed"
  fi
}

step_launchd() {
  hdr "LaunchAgent (restore after login/reboot if the agent was ON)"
  local label="com.agentlab.boot" plist="$HOME/Library/LaunchAgents/com.agentlab.boot.plist"
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would write %s and bootstrap it\n' "$plist"; return 0; }
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>-lc</string><string>"$KIT/agent-ctl.sh" boot</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/boot.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/boot.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$plist" && ok "LaunchAgent installed ($plist)" || warn "launchctl bootstrap failed"
  info "it only restarts the agent if you had it ON (./agent-ctl.sh on). Turning it OFF removes that flag."
  info "FileVault: after a cold reboot you must log in before any LaunchAgent runs."
}

step_team() {
  hdr "agent team '${TEAM:-}' (its own clone, so two Leads never share a working tree)"
  case "${TEAM:-}" in ""|main|*[!A-Za-z0-9_]*) die "usage: TEAM=<id> bash setup.sh team   (id: letters/digits/_, not 'main')" ;; esac
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would clone the repo to ~/%s-%s in the VM, install the pre-commit hook, record %s/workdir-%s\n' "$REPO" "$TEAM" "$STATE_DIR" "$TEAM"; return 0; }
  local home wd; home=$(vmx bash -c 'echo $HOME' </dev/null | tr -d '\r'); [ -n "$home" ] || die "could not read the VM home directory"
  wd="$home/$REPO-$TEAM"
  if vmx test -d "$wd/.git" </dev/null; then ok "already cloned at $wd"
  else vmx git clone -q "https://github.com/$GITHUB_USER/$REPO.git" "$wd" </dev/null && ok "cloned to $wd" || die "clone failed"; fi
  sbx exec -i -w "$wd" "$SBX_NAME" sh -c 'cat > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit' < "$KIT/pre-commit-hook.sh" && ok "pre-commit hook installed"
  echo "$wd" > "$STATE_DIR/workdir-$TEAM"; ok "recorded $STATE_DIR/workdir-$TEAM"
  case " ${TEAMS:-main} " in *" $TEAM "*) : ;; *) info "add '$TEAM' to TEAMS in config.sh (now: ${TEAMS:-main}) so agent-ctl.sh on starts it" ;; esac
  info "start it: ~/agent-lab-kit/agent-ctl.sh on   (or: agent-ctl.sh on $TEAM)   | watch it: ./view.sh $TEAM"
}

step_referee() {
  hdr "external paper referee (read-only, runs after pushed cycles)"
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would clone ~/%s-referee in the VM\n' "$REPO"; return 0; }
  local home wd; home=$(vmx bash -c 'echo $HOME' </dev/null | tr -d '\r'); [ -n "$home" ] || die "could not read the VM home directory"
  wd="$home/$REPO-referee"
  if vmx test -d "$wd/.git" </dev/null; then ok "referee clone exists at $wd"
  else vmx git clone -q "https://github.com/$GITHUB_USER/$REPO.git" "$wd" </dev/null && ok "cloned to $wd" || die "clone failed"; fi
  echo "$wd" > "$STATE_DIR/workdir-referee"
  vmx bash -c 'command -v latexmk >/dev/null && kpsewhich IEEEtran.cls >/dev/null' </dev/null && ok "LaTeX with IEEEtran present in the VM" \
    || warn "no LaTeX in the VM: papers cannot compile. Allow ports.ubuntu.com briefly, then: sbx exec $SBX_NAME sudo apt-get install -y --no-install-recommends latexmk texlive-latex-recommended texlive-latex-extra texlive-fonts-recommended texlive-publishers texlive-science lmodern (and remove the allow rule)"
  info "papers are reviewed automatically; review one now with: bash $KIT/referee.sh --force <slug>"
}

step_manager() {
  hdr "manager review (daily at ${MANAGER_HOUR}:${MANAGER_MINUTE}, read-only)"
  local label="com.agentlab.manager" plist="$HOME/Library/LaunchAgents/com.agentlab.manager.plist"
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would clone ~/%s-manager in the VM and write %s\n' "$REPO" "$plist"; return 0; }
  local home wd; home=$(vmx bash -c 'echo $HOME' </dev/null | tr -d '\r'); [ -n "$home" ] || die "could not read the VM home directory"
  wd="$home/$REPO-manager"
  if vmx test -d "$wd/.git" </dev/null; then ok "manager clone exists at $wd"
  else vmx git clone -q "https://github.com/$GITHUB_USER/$REPO.git" "$wd" </dev/null && ok "cloned to $wd" || die "clone failed"; fi
  echo "$wd" > "$STATE_DIR/workdir-manager"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$KIT/manager.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>$((10#$MANAGER_HOUR))</integer><key>Minute</key><integer>$((10#$MANAGER_MINUTE))</integer></dict>
  <key>StandardOutPath</key><string>$STATE_DIR/manager.out</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/manager.out</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$plist" && ok "manager scheduled daily at ${MANAGER_HOUR}:${MANAGER_MINUTE} ($plist)" || warn "launchctl bootstrap failed"
  info "it only runs while the lab is ON; run one now from Telegram with /review (or: bash $KIT/manager.sh --force)"
}

step_bagguard() {
  hdr "bag guard (portable mode + Amphetamine lid-closed mode)"
  local label="com.agentlab.bagguard" plist="$HOME/Library/LaunchAgents/com.agentlab.bagguard.plist"
  [ -f /private/etc/sudoers.d/amphetamine_powerProtect ] \
    || { warn "Amphetamine Power Protect is not installed: the guard could not turn lid-closed mode off. Skipping."; return 0; }
  [ "$DRYRUN" -eq 1 ] && { printf '  [dry]  would write %s (every 30s: %s/bag-guard.sh) and bootstrap it\n' "$plist" "$KIT"; return 0; }
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$KIT/bag-guard.sh</string></array>
  <key>StartInterval</key><integer>30</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/bag-guard.out</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/bag-guard.out</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$plist" && ok "bag guard installed ($plist): on battery it turns lid-closed mode off within ~30s" || warn "launchctl bootstrap failed"
  info "log: $STATE_DIR/bag-guard.log  | remove: launchctl bootout gui/\$(id -u)/$label; rm $plist"
}

step_pmset() {
  hdr "keep the Mac awake with the lid closed"
  info "'agent-ctl.sh on' runs: sudo pmset -a disablesleep 1   (and 'off' reverts it). Apple does not document this flag, so the loop checks it every cycle and alerts if it flips."
  info "rules: plugged in, hard surface, airflow, never in a bag; run './agent-ctl.sh off' before packing the laptop."
  info "alternative if the flag ever stops working: Amphetamine with Closed-Display Mode (+ Power Protect add-on on Apple Silicon)."
}

step_summary() {
  hdr "what only you can do"
  cat <<EOF
  1. Anthropic terms: the Max plan limits assume ordinary individual usage. A 24/7 autonomous loop is a gray area. Ask Anthropic support, and keep MAX_CYCLES_PER_DAY modest until you hear back.
  2. Create the PRIVATE repo $GITHUB_USER/$REPO with 'Add a README' ticked. Then Settings > Rules > Rulesets > New branch ruleset
     on the default branch: tick 'Restrict deletions' and 'Block force pushes' (nothing else, or the agent can't push to main).
     Rulesets on PRIVATE repos need GitHub Pro (free with the Student Developer Pack). Without it the loop's history audit is your guard.
  3. GitHub profile -> enable 'Include private contributions'.
  4. Create the fine-grained PAT (only $REPO) and run: sbx secret set github --sandbox $SBX_NAME
  5. Sign Claude in (step 'secrets'), then run:  bash preflight.sh    (all FAIL lines must be fixed)
  6. Supervised hour: ./agent-loop.sh main --once   and watch (DESIGN.md has the checklist). Then: bash preflight.sh --live
  7. When happy: ./agent-ctl.sh on    (and put your goals in north-star.md in the repo)
  8. macOS: turn OFF automatic update restarts (System Settings > General > Software Update > Automatic Updates). Keep the Mac plugged in.
  9. Re-run 'bash setup.sh' any time; it skips what is done.
EOF
  [ "$WARNED" -eq 1 ] && printf '\n  Some steps printed [WARN]. Read them before moving on.\n'
}

for s in $STEPS; do
  case "$s" in
    check|sbx|policy|vm|secrets|identity|clone|seed|telegram|launchd|bagguard|team|manager|referee|pmset|summary) "step_$s" ;;
    *) die "unknown step '$s'" ;;
  esac
done
