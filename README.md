# Autonomous Research Lab

**by Pranav Nandyalam ([@pranavnandyalam](https://github.com/pranavnandyalam))**

An AI research lab that runs on your Mac while you do other things. A team of Claude Code agents scouts what is
happening in AI right now, picks small questions worth testing, plans and runs CPU-sized experiments, reviews its own
work, and pushes everything to a private GitHub repo. It runs inside an isolated Docker Sandboxes microVM, and you
watch and steer it from your phone over Telegram.

> **Experimental.** Built and tested on one Apple Silicon MacBook (October 2026: Docker Sandboxes `sbx` v0.46,
> Claude Code 2.1.280 in the sandbox). Expect rough edges, read [DESIGN.md](DESIGN.md) before running it, and
> start with the supervised single cycle.

## The team

| Agent | Default model | Job |
|---|---|---|
| 🧠 Lead | Sonnet | Runs each cycle: reads your goals, decides what to do, coordinates, commits and pushes |
| 🔍 Scouts (up to 3) | Sonnet | Search arXiv, Hugging Face, Hacker News, Semantic Scholar for trends and open problems |
| 🛠 Builder (up to 2) | Sonnet | Writes and runs the experiment code in one project folder each |
| 🧐 Overseer | Opus | Skeptical reviewer of every plan, diff and result; can reject |
| ⚖️ Ethics reviewer | Sonnet | Harm, privacy, licensing, honesty checks |
| 🛡 Safety guard | Sonnet | Gate before every commit: secrets, forbidden files, repo and remote checks |

You steer it with one file you own, `north-star.md` in the lab repo (the agent may never edit it). The default
example tells it to keep a live "radar" of the top things happening in AI and turn the best into small,
reproducible projects. Each project ends with a short write-up: takeaway, method, results over several seeds,
limitations, and an AI-authorship note.

## How it stays safe

The reviewer agents catch sloppy or harmful work, but they are AIs too, so the hard limits do not depend on them:

- **Sandbox:** a Docker Sandboxes microVM with its own kernel and no access to your files (no shared folders).
- **Network allowlist:** deny-all, plus arXiv, GitHub, Hugging Face, Semantic Scholar, HN, PyPI, npm. The claude.ai
  connector proxy is explicitly denied, so your Gmail/Drive/other connectors can never reach the agent.
- **GitHub token outside the VM:** a fine-grained token that can only touch the one lab repo is held by the host
  proxy; the VM only ever sees a placeholder.
- **Protected history:** a branch ruleset blocks force pushes and deletion on `main`; the host also audits that `main`
  only ever moves forward.
- **Permissions:** Claude runs in `dontAsk` mode with an allow list and enforced deny rules (no sudo, no force push,
  no editing its own config or hooks, no reading credentials).
- **A supervisor that is not an AI:** `agent-loop.sh` on your Mac enforces a 50-minute cycle limit, a daily cycle cap,
  tripwires for the agent changing its own configuration, a halt after repeated failures, and alerts.
- **You:** a pinned Telegram live board, a message after every cycle, and `/kill` to stop it instantly.

`preflight.sh` tests all of this automatically (network, isolation, secrets, token scope, connector leak); fix
every FAIL before turning it on.

## What you need

- An **Apple Silicon Mac** with macOS 14 or later, [Homebrew](https://brew.sh), and room for a 60 GB sandbox disk.
- A **Docker account** for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (no Docker Desktop needed).
- A **Claude subscription** (signed in inside the sandbox with `/login`) or an Anthropic API key.
- A **GitHub account** for the private lab repo, and the `gh` CLI (recommended).
- Optional: **Telegram** for the phone view; **Amphetamine** if you want it to run with the lid closed on the charger.

## Usage and cost

Every cycle is a long Claude Code session with several agents. On the author's Mac one planning cycle used about
**$3.40 of API-equivalent usage** (mostly Sonnet), and cycles that write and run code can use more. The default cap is
**6 cycles per day**. On a subscription this comes out of your plan's usage limits, so watch your usage page for a few
days before raising `MAX_CYCLES_PER_DAY`. Long unattended runs on a personal plan may not be what the plan is meant for:
check your provider's terms, and use an API key and a spending limit if you want to run it hard.

## Quick start

```bash
brew install tmux gh
brew trust docker/tap && brew install docker/tap/sbx    # Docker Sandboxes CLI
sbx login                                                # Docker account, opens a browser

git clone https://github.com/pranavnandyalam/autonomous-research-lab && cd autonomous-research-lab
cp config.local.sh.example config.local.sh               # set OWNER_NAME and GITHUB_USER (and Telegram id, optional)
```

On GitHub:
1. Create a **private** repo named `agent-lab` with "Add a README" ticked.
2. Settings → Rules → Rulesets → new branch ruleset on the default branch: tick **Restrict deletions** and
   **Block force pushes** (nothing else).
3. Create a **fine-grained token** with access to only `agent-lab`: Contents, Issues, Pull requests read/write;
   Metadata read. 90-day expiry.

Then:
```bash
bash setup.sh --dry-run          # preview
bash setup.sh                    # sandbox, network policy, settings, repo clone, seed files; it asks for the token
sbx exec -it agent-lab claude    # type /login once, finish in the browser, then /exit
bash preflight.sh && bash preflight.sh --live    # safety tests (the --live part makes 4 tiny Claude calls)
```
Edit `north-star.md` in your lab repo on GitHub, then run one supervised cycle and watch it:
```bash
./agent-loop.sh main --once      # in another terminal: ./watch-cycle.sh
```
When you are happy:
```bash
bash deploy.sh                   # copies the kit to ~/agent-lab-kit (macOS blocks background jobs in ~/Documents)
~/agent-lab-kit/agent-ctl.sh on  # runs until you stop it
```
Optional Telegram: create a bot with @BotFather, put your numeric id (from @userinfobot) in `config.local.sh`, press
Start in the bot chat, then `bash setup.sh telegram`. Turn on Telegram two-step verification.

## Daily use

| Want | Mac | Phone (Telegram) |
|---|---|---|
| Status | `~/agent-lab-kit/agent-ctl.sh status` | `/status` |
| Watch everything live | `./view.sh` (tmux: every step, the board, the log; reopen with `tmux attach -t agent-view`) | pinned live board, `/live` |
| Plain-English summary | | `/explain` (also added to the board when each cycle ends) |
| Last cycle's report, trend radar | `python3 activity.py` | `/last`, `/radar` |
| Pause / stop after this cycle / resume | `agent-ctl.sh pause 2h` / `stop` / `go` | `/pause 2h` / `/stop` / `/go` |
| Stop right now | `agent-ctl.sh kill` | `/kill` |
| Everything off | `agent-ctl.sh off` | add a `STOP` file to the repo |
| Tell the agent something | | any text message (read at the start of the next cycle) |
| Make your edits to the kit live | `bash deploy.sh` | |

Nothing here deletes work: a stopped sandbox keeps its files, and everything pushed stays on GitHub.
`bash uninstall.sh` removes everything the kit set up (it asks before each part and never deletes your repo).

## Laptop or desk (`POWER_MODE`)

- **portable** (default): closing the lid sleeps the Mac; the sandbox freezes and resumes when you open it (time
  asleep does not count toward the cycle limit). On battery no new cycle starts; it resumes by itself on the charger.
  No sudo. Safe in a bag.
- **Lid closed on the charger:** use an Amphetamine trigger on "power adapter connected" with closed-display mode and
  its Power Protect add-on, then `bash ~/agent-lab-kit/setup.sh bagguard`. The bag guard checks every 30 s and, on
  battery, turns lid-closed mode off and sleeps the Mac if the lid is closed (Amphetamine alone left it awake in
  testing, and so did any running `caffeinate`).
- **always-on:** `agent-ctl.sh on` runs `sudo pmset -a disablesleep 1`. Plugged in, hard surface, never in a bag.

## Files

`prompt.md` the Lead's manual · `agents.json` the subagents · `settings.json` permissions · `config.sh` settings ·
`config.local.sh.example` your values · `render.py` fills your values into the templates · `setup.sh` setup ·
`preflight.sh` safety tests · `agent-loop.sh` supervisor · `agent-ctl.sh` controls · `deploy.sh` make edits live ·
`tg-bridge.py` Telegram · `activity.py` live board · `narrate.py` plain-English summary · `watch-cycle.sh` terminal
viewer · `view.sh` all-in-one live view · `bag-guard.sh` battery safety · `uninstall.sh` remove everything · `pre-commit-hook.sh` installed in the lab
repo · `repo-seed/` the lab repo's starting files · [DESIGN.md](DESIGN.md) why it works this way

## License and disclaimer

[MIT](LICENSE). Everything the lab produces is generated by an autonomous AI agent and is not peer reviewed; you are
responsible for what it does with your accounts and what you publish from it.
