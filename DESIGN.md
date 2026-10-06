# Design

Why the lab is built the way it is, what was verified, what was learned by testing, and what is still open.
Read this before changing anything in the kit.

## 1. Architecture

```
Mac host (outside the VM)                         sbx microVM "agent-lab" (half your cores/RAM, 60g disk, no mounts)
─────────────────────────                         ─────────────────────────────────────────────
caffeinate + tmux                                 /home/agent/agent-lab   (clone of your private lab repo)
 ├─ agent-loop.sh main ── sbx exec ──────────────▶ timeout 50m claude -p  (Lead, dontAsk mode)
 │    pre-check, tripwires, audit,                    ├─ scout ×≤3 (read-only + web)
 │    classify result, alerts, backoff                ├─ builder ×≤2 (one project folder each)
 ├─ tg-bridge.py ◀──▶ Telegram (owner only)           ├─ overseer / ethics-reviewer
 ├─ LaunchAgent: restore after login                  └─ safety-guard → git push main
 └─ LaunchAgent: bag guard (optional)
sbx host proxy: GitHub token + network allowlist ─────▶ github.com/<you>/agent-lab (private)
```

- **Why Docker Sandboxes (`sbx`) and not a plain container:** sbx gives deny-all networking with a domain allowlist,
  credentials injected by a host proxy (the token never exists inside the VM), and a separate kernel per sandbox.
  A plain container would need a hand-built egress proxy and token handling: more parts to get wrong.
- **Mountless:** no host folder is shared. Host and VM sync only through GitHub.
- **Only the Lead runs git.** Builders never share a folder.
- **Templates:** `prompt.md`, `agents.json` and `repo-seed/` contain `{{OWNER_NAME}}`, `{{GITHUB_USER}}`, `{{REPO}}`;
  `render.py` fills them from `config.local.sh` every cycle and refuses to run with anything unfilled.

## 2. Security model (defense in depth)

| Threat | Guards |
|---|---|
| Prompt injection from web pages and papers | manual §0.3 (data ≠ instructions); dontAsk + deny list; network allowlist; overseer and safety guard review every diff |
| Data exfiltration | deny-all network + allowlist; no secrets in the VM (GitHub token in the host proxy); pre-commit + safety-guard secret scans |
| Damage to your other GitHub repos | fine-grained token scoped to the lab repo only (no Administration → cannot create/delete repos); preflight checks private-repo visibility, a dry-run push to another repo, and repo creation |
| Force-push / history loss | GitHub ruleset on `main` (block force pushes, restrict deletions); host-side history audit with your own `gh` login; deny rules |
| Agent edits its own config or hooks | `--setting-sources user`; tripwires for `.claude/`, `CLAUDE.md`, `.mcp.json`; fingerprint of the VM's `~/.claude` (trust on first use, `agent-ctl.sh rebaseline` after review); deny rules |
| claude.ai connector leak | sbx `--deny-network mcp-proxy.anthropic.com` plus a global deny rule, `--strict-mcp-config`, `--disallowedTools "mcp__*"`; preflight test 11 |
| Host compromise | mountless VM with its own kernel, SSH agent forwarding off, diagnostics upload off, shared skills off |
| Malicious models/packages | safetensors/GGUF only, never `trust_remote_code`, pinned well-known packages, overseer reviews new dependencies |
| Runaway usage | 50 min timeout, 150 max turns, `MAX_CYCLES_PER_DAY` (default 6), backoff on idle and limits, halt after 5 failures |
| Hot laptop in a bag | portable power mode; bag guard (§6) |
| Terminal escape codes in agent text | the board, step viewer, supervisor log and log pane strip control characters before anything reaches your terminal (an injected `ESC ]52` could otherwise rewrite the clipboard) |
| Telegram summary model | runs inside the VM with `--tools ""` and no MCP: agent output may carry injected text, so it never reaches a Claude that has tools or connectors |

**Bash deny rules are prefix patterns and can be evaded by creative spelling; they are a speed bump.** The real guards
are the network allowlist, the token scope, the ruleset, and the host-side checks.

**Kill switches:** `STOP` file in the repo root (from GitHub mobile) · Telegram `/stop`, `/kill`, `/pause 2h`, `/go` ·
`agent-ctl.sh off`.

## 3. Verified commands

### Docker Sandboxes (`sbx`, v0.46)
- Create: `DOCKER_SANDBOXES_ROOT_SIZE=60g sbx create --name agent-lab --cpus N --memory Ng --deny-network mcp-proxy.anthropic.com -e ... claude`.
  No PATH = mountless. Root disk size applies only at create.
- `sbx exec [-i] [-t] [-w DIR] [-e K=V] NAME CMD...` auto-starts a stopped sandbox. There is no `sbx start`.
- **`sbx exec` reads stdin even without `-i`:** inside a `while read` loop every call needs `</dev/null`.
- `sbx exec` rejects empty arguments (`--tools ""`): pass such commands through `bash -c`.
- `sbx version` (not `--version`). `sbx stop` keeps state; `sbx rm` deletes the sandbox and its sandbox-scoped secrets.
- Policy: `sbx policy init deny-all`, `sbx policy allow|deny network "a.com,b.com"`, `sbx policy ls|check|log|reset`.
  Deny beats allow. `--method`/`--path` exist for HTTP rules.
- `*.hf.co` matches one label only: Hugging Face's Xet storage serves file bytes from `us.aws.cdn.hf.co` and
  `cas-server.xethub.hf.co`, so both are allow-listed explicitly (found when every model download returned 403).
- **The built-in `claude` agent kit adds a per-sandbox allow for `mcp-proxy.anthropic.com:443`** (plus a few claude.com
  hosts used by `/login`). The kit's explicit deny wins; never remove `DENY_DOMAINS`.
- GitHub secret: `sbx secret set github --sandbox agent-lab`. The VM sees `GH_TOKEN` as a sentinel that the host proxy
  swaps on github.com/api.github.com. A wrong stored token shows up as HTTP 401 even on requests sent without auth.
- Local `sbx secret set --oauth` is OpenAI-only. With a Claude subscription, `/login` inside the sandbox keeps the
  session token on the host (per Docker's docs).
- Settings used: `ssh.agentForwardingEnabled false` (needs `sbx daemon restart`), `diagnostics.autoUpload no`,
  `skills.defaultMode off`.

### Claude Code (headless)
- Flags: `-p`, `--permission-mode dontAsk`, `--no-session-persistence`, `--max-turns`, `--model`, `--strict-mcp-config`,
  `--setting-sources user`, `--disallowedTools`, `--output-format stream-json --verbose`, `--settings`, `--agents`,
  `--append-system-prompt`, `--system-prompt`, `--tools ""`, `--effort`.
- `dontAsk` with `Bash` allowed **does** permit `git commit` (preflight `--live` checks it).
- A Lead running a model newer than the sandbox's Claude Code (log: `unrecognized_model`) called the Agent tool
  without `subagent_type`, so work ran as the built-in general-purpose agent. `settings.json` now denies
  `Agent(general-purpose|Explore|Plan|claude|statusline-setup)` (verified: untyped calls are refused, named ones
  work) and the manual says to always name the subagent. Keep the sandbox's Claude Code new enough for your models.
- Subagents accept full model ids in `agents.json` (verified: a `claude-sonnet-5-5` Lead called a `claude-opus-5-5`
  subagent). Aliases resolve per the sandbox's Claude Code version, which does not auto-update here.
- Usage-limit messages ("hit your … limit", 429) → the loop sleeps an hour. `--max-turns` reached is a normal end.
- Each cycle ends with `CYCLE_RESULT: <PROGRESS|NOTHING_TO_DO|ASK_USER|REJECTED|BLOCKED> | project=… | pushed=… | note=…`.

## 4. Decision log

1. **Permission mode:** `--dangerously-skip-permissions` ignores deny rules, so the default is `dontAsk` (auto-denies
   anything not allow-listed and enforces deny rules). `PERMISSION_MODE=bypass` exists as a fallback only.
2. **Owner messages** from Telegram are queued on the host and injected into the next cycle's prompt (authenticated
   by numeric user id), never committed. They are returned to the queue if the cycle fails.
3. **Host history audit:** each pre-check records `origin/main`; on change the host asks GitHub `compare/OLD...NEW`
   with your own login (the VM cannot fake it). Anything other than `ahead` pauses the loop.
4. **Streamed output:** cycles run with `stream-json`, so the live board and `watch-cycle.sh` show progress; the
   classifier only accepts the final `result` event, so a timeout (no result) is still classed TIMEOUT.
5. **Telegram summary:** once per cycle at the end, plus `/explain` on demand. A short custom system prompt and low
   effort roughly halve its cost (~$0.017 per summary with Haiku in testing).
6. **Deployed copy:** macOS blocks LaunchAgents from reading `~/Documents` ("Operation not permitted"), so the kit runs
   from `~/agent-lab-kit` (`deploy.sh`). `rsync` replaces files by rename, so a running loop keeps its old copy.
7. **Personal values** live in the git-ignored `config.local.sh`, so a fork cannot leak them by accident.
10. **Manager review is advisory and read-only.** It reads agent-written files (a prompt-injection surface), so it
    gets only Read/Glob/Grep in its own clone, numbers come from the host's logs (HOST_FACTS), and its advice enters a
    team's cycle in a separate MANAGER_ADVICE block that the manual says never overrides goals, owner messages or
    the manual. It never writes into the owner-message queue.
9. **Multiple teams share one sandbox but not a working tree.** Each non-main team runs from its own clone
   (`setup.sh team`), with its own lock, log, state file, owner-message queue, daily counter and Telegram board.
   Coordination is in the manual (§5b): claim in `CLAIMS.md` before starting, `team: <id>` on every PLAN.md,
   append-only shared files, stage only your own paths. GitHub serializes pushes; pull --rebase resolves the rest.
8. **Novelty first by default.** The example goals and the manual's fallback both aim for new contributions;
   replication is a baseline step. Each PLAN.md opens with "What's new here" plus a literature check the
   overseer verifies. Owners change goals by editing `north-star.md` (GitHub, `goals.sh`, read via `/goals`);
   the agent can never edit it.

## 5. Operations

- **Loop:** every iteration checks pauses, power (portable mode), host disk, the daily cap, the VM, a pre-check in the
  VM (fetch, STOP, tripwires, fingerprint, VM disk, `questions.md` changes, dead-man), and the history audit; then one
  cycle; then classifies it (OK / IDLE / MAXTURNS / TIMEOUT / RATELIMIT / AUTH / TRANSIENT / INTERRUPTED / FAIL) and
  sleeps accordingly (10 min after a productive cycle, 5 → 30 min when idle, 1 h on a usage limit).
- **Telegram:** pinned live board (who is doing what, the Lead's checklist, key steps), a message after every cycle,
  `/status /live /explain /last /radar /pause /stop /go /kill /digest`, free text queued for the agent, a digest at
  20:00. Bot token in the macOS Keychain; only your numeric id, private chat only. Turn on two-step verification.
- **Restarts:** with FileVault, nothing runs after a cold reboot until you log in; then the LaunchAgent restores the lab
  if it was on. Turn off automatic macOS update restarts.
- **Several loops** are supported (`agent-loop.sh <id>`, `agent-ctl.sh on main second`): own lock, log and state file
  each, one global daily cap, one shared usage quota.
- **Local models (idea):** run a server on the host (Metal GPU) and point a second loop at it with
  `LOOP_<id>_BASE_URL=http://host.docker.internal:<port>` after `sbx policy allow network localhost:<port>`. The server
  must expose an Anthropic-compatible endpoint. Give local loops low-stakes work only.

## 6. Power and sleep (tested on battery, October 2026)

- **Closing the lid** sleeps the Mac and freezes the sandbox; it resumes on wake with the same `sbx exec` stream intact.
- **Time asleep does not count** toward the cycle limit: both the host's `perl alarm` timer and the VM's GNU `timeout`
  fired after 120 s of *awake* time in a test that slept 197 s in between.
- **A cycle cut off by sleep** (its API connection drops) is classed INTERRUPTED and retried in a minute instead of
  counting toward the failure halt; the dead-man alert waits for a full awake stretch after the last wake.
- **Amphetamine closed-display mode** (trigger: power adapter connected, plus Power Protect on Apple Silicon) kept the
  Mac awake with the lid closed on the charger. **After unplugging with the lid closed it stayed awake**: first because
  `disablesleep` stayed on, and with that fixed, because no new lid event fires and any `caffeinate -i` (a running
  Claude Code session holds one) blocks idle sleep. The **bag guard** (`bag-guard.sh`, every 30 s) fixes both: on
  battery it runs `pmset -a disablesleep 0` through Power Protect's passwordless rule and, if the lid is closed,
  `pmset sleepnow`. Measured: asleep 6 s after unplugging (worst case ≈ 35 s). It costs ~13 ms of CPU per check.

## 7. Still unverified

- Exact `--max-turns` exit code/text (the parser matches loosely).
- How a lapsed Docker login surfaces in `sbx` errors.
- A Claude API call in flight at the exact moment the lid closes (expected: INTERRUPTED and retried).
- Anthropic-compatible endpoints in local model servers.
- FileVault + `sudo fdesetup authrestart` on Apple Silicon.

## 8. Supervised first cycle checklist (`./agent-loop.sh main --once`)

- dontAsk lets Bash, writes, git, WebFetch and subagents run
- subagents load from `--agents`; scouts run in parallel; the builder cap holds
- usage per cycle (check your plan's usage page before and after) → set `MAX_CYCLES_PER_DAY`
- CPU/RAM under two builders (Activity Monitor); `df -h /` in the VM ≈ 60G
- the first commit on `main` links to your GitHub profile
- Telegram alerts, `/status`, the live board, and the `STOP` file work
- next day: Claude and Docker logins still valid
