#!/usr/bin/env python3
"""Host-side Telegram bridge for the agent-lab loop. Standard library only. Runs on the Mac, never inside the VM.

  tg-bridge.py run              long-poll for your commands (run it in tmux; agent-ctl.sh on does this)
  tg-bridge.py send "text"      send one message to you (used by agent-loop.sh for alerts)
  tg-bridge.py selftest         check the token and your user id, send a hello

Configuration comes from environment variables exported by config.sh:
  TG_ALLOWED_USER_ID   your numeric Telegram user id (the ONLY account the bot listens to)
  KEYCHAIN_SERVICE     macOS Keychain service holding the bot token (create it with setup.sh or:
                       security add-generic-password -a "$USER" -s agent-lab-telegram -U -w)
  STATE_DIR, SBX_NAME, WORKDIR, DIGEST_HOUR
Testing only: TG_BOT_TOKEN overrides the Keychain, TG_API_BASE overrides https://api.telegram.org

Commands: /status /stop /kill /go /pause 2h /digest /help. Any other text is queued for the agent's next cycle.
"""
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import activity  # noqa: E402  (kit-local modules: live board rendering, plain-English summary)
import narrate  # noqa: E402

STATE = os.path.expanduser(os.environ.get("STATE_DIR", "~/.agent-lab"))
SBX = os.environ.get("SBX_NAME", "agent-lab")
SERVICE = os.environ.get("KEYCHAIN_SERVICE", "agent-lab-telegram")
API_BASE = os.environ.get("TG_API_BASE", "https://api.telegram.org").rstrip("/")
DIGEST_HOUR = int(os.environ.get("DIGEST_HOUR", "20") or 20)
ALLOWED = (os.environ.get("TG_ALLOWED_USER_ID") or "").strip()
MAX_MSG = 3900          # Telegram limit is 4096
MAX_INBOX_TEXT = 1500   # per owner message handed to the agent
LIVE_BOARD = (os.environ.get("TG_LIVE_BOARD") or "1").strip() == "1"
LIVE_EVERY = 45        # seconds between live board edits
LIVE_MAX_AGE = 7200    # only follow a cycle file written to in the last 2h
NARRATE = (os.environ.get("TG_NARRATE") or "1").strip() == "1"

_token_cache = None


def workdir():
    w = os.environ.get("WORKDIR", "").strip()
    if w:
        return w
    try:
        return open(os.path.join(STATE, "workdir")).read().strip()
    except OSError:
        return ""


def token():
    global _token_cache
    if _token_cache:
        return _token_cache
    t = os.environ.get("TG_BOT_TOKEN", "").strip()
    if not t:
        try:
            r = subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-w"],
                               capture_output=True, text=True, timeout=15)
            t = r.stdout.strip() if r.returncode == 0 else ""
        except Exception:
            t = ""
    _token_cache = t
    return t


def api(method, params=None, timeout=60):
    """Call the Bot API. Errors never include the URL (it contains the token)."""
    tok = token()
    if not tok:
        raise RuntimeError("no bot token (Keychain service %r not found)" % SERVICE)
    url = "%s/bot%s/%s" % (API_BASE, tok, method)
    data = urllib.parse.urlencode(params or {}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError("telegram HTTP %s on %s" % (e.code, method)) from None
    except Exception as e:
        raise RuntimeError("telegram request failed on %s: %s" % (method, type(e).__name__)) from None


def send(text):
    if not ALLOWED:
        raise RuntimeError("TG_ALLOWED_USER_ID is not set")
    text = str(text) or "(empty)"
    for i in range(0, len(text), MAX_MSG):
        api("sendMessage", {"chat_id": ALLOWED, "text": text[i:i + MAX_MSG], "disable_web_page_preview": "true"})


def send_one(text):
    """Send a single message (<= MAX_MSG chars) and return its message_id."""
    r = api("sendMessage", {"chat_id": ALLOWED, "text": str(text)[:MAX_MSG] or "(empty)", "disable_web_page_preview": "true"})
    return (r.get("result") or {}).get("message_id")


def sh(cmd, timeout=40):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except Exception as e:
        return "[%s]" % type(e).__name__


def vm_ok():
    try:
        return subprocess.run(["sbx", "exec", SBX, "true"], capture_output=True, timeout=30).returncode == 0
    except Exception:
        return False


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def touch(name, content=""):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, name), "w") as f:
        f.write(content)


def rm(name):
    try:
        os.remove(os.path.join(STATE, name))
    except OSError:
        pass


def ago(epoch):
    try:
        s = int(time.time()) - int(float(epoch))
    except Exception:
        return "?"
    if s < 90:
        return "%ds ago" % s
    if s < 5400:
        return "%dm ago" % (s // 60)
    return "%.1fh ago" % (s / 3600.0)


def cycles_today():
    try:
        return int(open(os.path.join(STATE, "cycles-%s.count" % datetime.now().strftime("%Y-%m-%d"))).read().strip())
    except Exception:
        return 0


def sleep_disabled():
    out = sh(["pmset", "-g"], 10)
    for line in out.splitlines():
        if "SleepDisabled" in line:
            return line.split()[-1] == "1"
    return False if "Sleep" in out else None  # pmset only lists SleepDisabled once it has been set


def host_free_gb():
    try:
        st = os.statvfs("/")
        return int(st.f_bavail * st.f_frsize / (1024 ** 3))
    except Exception:
        return None


def flags():
    out = []
    if os.path.exists(os.path.join(STATE, "HOST_STOP")):
        out.append("HOST_STOP set (send /go)")
    if os.path.exists(os.path.join(STATE, "TRIPWIRE")):
        out.append("TRIPWIRE: " + open(os.path.join(STATE, "TRIPWIRE")).read().strip()[:120])
    try:
        until = int(open(os.path.join(STATE, "PAUSE_UNTIL")).read().strip())
        if until > time.time():
            out.append("paused until %s" % datetime.fromtimestamp(until).strftime("%H:%M"))
    except Exception:
        pass
    return out


def cmd_status():
    lines = []
    sts = [read_json(p) for p in sorted(glob.glob(os.path.join(STATE, "status-*.json")))]
    sts = [s for s in sts if s]
    if not sts:
        lines.append("No loop status yet (is the loop running?).")
    for s in sts:
        lines.append("loop %s: %s | cycle %s today | last: %s %s %s turns=%s | %s" % (
            s.get("loop", "?"), s.get("state", "?"), s.get("cycle_today", "?"),
            s.get("last_class", "-"), s.get("last_marker", "") or "-", s.get("last_project", "") or "-",
            s.get("last_turns", "-") or "-", ago(s.get("last_cycle_end", s.get("updated", 0)))))
        if s.get("last_note"):
            lines.append("  note: %s" % s["last_note"][:160])
    fl = flags()
    lines.append("flags: " + ("; ".join(fl) if fl else "none"))
    lines.append("cycles today (all loops): %d" % cycles_today())
    sd = sleep_disabled()
    power = "on battery" if "Battery Power" in sh(["pmset", "-g", "ps"], 10) else "plugged in"
    if os.environ.get("POWER_MODE", "portable") == "portable":
        mode = "portable mode: sleeps when the lid closes, no new cycles on battery"
    else:
        mode = "always-on mode: lid-closed operation " + {True: "on", False: "OFF (run agent-ctl.sh on)", None: "n/a"}[sd]
    lines.append("mac: %s | %s | free disk %sGB (the loop pauses below %sGB)" % (
        power, mode, host_free_gb(), os.environ.get("MIN_HOST_FREE_GB", "150")))
    vm = [l for l in sh(["sbx", "ls"], 25).splitlines() if SBX in l]
    lines.append("sandbox: " + (vm[0].strip()[:140] if vm else "not listed"))
    return "\n".join(lines)


def cmd_digest():
    lines = ["Daily digest " + datetime.now().strftime("%Y-%m-%d %H:%M"), cmd_status(), ""]
    wd = workdir()
    if wd:
        sh(["sbx", "exec", "-w", wd, SBX, "git", "fetch", "-q", "origin", "main"], 60)
        log = sh(["sbx", "exec", "-w", wd, SBX, "git", "log", "origin/main", "--since=24 hours ago", "--pretty=%s"], 45)
        subj = [l for l in log.splitlines() if l.strip()]
        lines.append("commits in the last 24h: %d" % len(subj))
        lines.extend("  " + l[:100] for l in subj[:12])
        q = sh(["sbx", "exec", "-w", wd, SBX, "bash", "-c", "git show origin/main:questions.md 2>/dev/null | grep -ci 'open'"], 30)
        lines.append("questions.md lines mentioning 'open': %s" % (q.splitlines()[-1] if q else "?"))
    else:
        lines.append("(workdir unknown; run setup.sh)")
    return "\n".join(lines)


def cmd_last():
    """The Lead's own end-of-cycle report (the stream-json result line of the newest cycle)."""
    files = sorted(glob.glob(os.path.join(STATE, "outputs", "cycle-*.json")), key=os.path.getmtime)
    if not files:
        return "No cycles yet."
    path = files[-1]
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError as e:
        return "Could not read the last cycle: %s" % type(e).__name__
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("type") == "result":
            head = "%s | %s | %s turns | %s min" % (os.path.basename(path), e.get("subtype"), e.get("num_turns"),
                                                   round((e.get("duration_ms") or 0) / 60000, 1))
            return head + "\n\n" + str(e.get("result") or "(no report text)")[:3500]
    return "%s is still running (or ended without a result). Last output %s." % (os.path.basename(path), ago(os.path.getmtime(path)))


def repo_file(name, missing, limit=3500):
    """A file from the lab repo's main branch, read inside the sandbox (truncated for one Telegram message)."""
    wd = workdir()
    if not wd:
        return "(workdir unknown; run setup.sh)"
    sh(["sbx", "exec", "-w", wd, SBX, "git", "fetch", "-q", "origin", "main"], 60)
    txt = sh(["sbx", "exec", "-w", wd, SBX, "git", "show", "origin/main:" + name], 45)
    if not txt or "fatal:" in txt[:200]:
        return missing
    return txt[:limit]


def cmd_radar():
    return repo_file("radar.md", "No radar.md on main yet.")


def cmd_goals():
    txt = repo_file("north-star.md", "No north-star.md on main yet.", limit=12000)  # sent as several messages
    return txt + "\n\nTo change the goals: edit north-star.md on github.com, or run ./goals.sh edit on your Mac."


def parse_duration(txt):
    txt = (txt or "").strip().lower()
    if not txt:
        return None
    mult = 60
    if txt.endswith("h"):
        mult, txt = 3600, txt[:-1]
    elif txt.endswith("m"):
        txt = txt[:-1]
    elif txt.endswith("d"):
        mult, txt = 86400, txt[:-1]
    try:
        v = float(txt)
    except ValueError:
        return None
    return int(v * mult) if 0 < v <= 1000 else None


def handle(text):
    t = text.strip()
    low = t.lower()
    cmd, _, arg = low.partition(" ")
    cmd = cmd.split("@", 1)[0]  # /status@MyBot in groups
    if cmd in ("/start", "/help"):
        return ("agent-lab bridge. Commands:\n/status  state of the loop\n/stop  idle after the current cycle\n"
                "/kill  stop the sandbox now and idle\n/go  resume (also clears pause)\n/pause 2h  pause for a duration (m or h)\n"
                "/digest  summary now\n/live  live board of what every agent is doing (/live off, /live on)\n"
                "/explain  plain-English summary of what the lab is doing right now\n"
                "/last  the agent's report from the latest cycle\n/radar  current trend radar\n/goals  the lab's goals (north-star.md)\n"
                "Any other text is queued for the agent's next cycle.")
    if cmd == "/status":
        return cmd_status()
    if cmd == "/live":
        if arg == "off":
            touch("tg.live_off")
            return "Live board off. /live on to resume."
        rm("tg.live_off")
        path = activity.newest_cycle()
        if not path:
            return "No cycles yet. The board appears when the next cycle starts."
        live_post(path)
        return None  # the board itself is the reply
    if cmd == "/explain":
        path = activity.newest_cycle()
        if not path:
            return "No cycles yet."
        return narrate.narrate(path) or "Could not write a summary right now (is the sandbox running?). Try /last."
    if cmd == "/last":
        return cmd_last()
    if cmd == "/radar":
        return cmd_radar()
    if cmd == "/goals":
        return cmd_goals()
    if cmd == "/digest":
        return cmd_digest()
    if cmd == "/stop":
        touch("HOST_STOP", "stopped via telegram %s\n" % datetime.now().isoformat())
        return "OK. The loop will idle after the current cycle finishes. /go to resume, /kill to interrupt now."
    if cmd == "/kill":
        touch("HOST_STOP", "killed via telegram %s\n" % datetime.now().isoformat())
        out = sh(["sbx", "stop", SBX], 120)
        return "Loop idled and sandbox stop requested. %s\nSend /go to restart." % out[:200]
    if cmd == "/go":
        rm("HOST_STOP")
        rm("PAUSE_UNTIL")
        note = ""
        if not vm_ok():
            note = " Sandbox was not running; start requested: " + sh(["sbx", "exec", SBX, "true"], 180)[:120]
        return "Resumed. The loop picks up on its next check (within a minute)." + note
    if cmd == "/pause":
        secs = parse_duration(arg)
        if not secs:
            return "Usage: /pause 2h  (or 30m)"
        touch("PAUSE_UNTIL", str(int(time.time()) + secs))
        return "Paused until %s." % datetime.fromtimestamp(time.time() + secs).strftime("%H:%M")
    if cmd.startswith("/") and cmd != "/note":
        return "Unknown command. /help"
    body = t[5:].strip() if cmd == "/note" else t
    if not body:
        return "Nothing to queue."
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "inbox.txt"), "a") as f:
        f.write("[%s] %s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M"), body[:MAX_INBOX_TEXT].replace("\r", " ")))
    return "Queued for the agent's next cycle."


LIVE_PATH = os.path.join(STATE, "tg.live.json")


def live_state():
    return read_json(LIVE_PATH) or {}


def compose(narr, board):
    """Plain-English summary on top, the detailed board underneath; fits one Telegram message."""
    if not narr:
        return board[:MAX_MSG]
    head = narr + "\n\n──────── details ────────\n"
    return head + board[: max(0, MAX_MSG - len(head))]


def save_live(st):
    with open(LIVE_PATH, "w") as f:
        json.dump(st, f)


def live_post(path):
    """Post a new board for this cycle file, pin it, and make it the one that gets edited."""
    board = activity.render(path)
    old = live_state().get("message_id")
    mid = send_one(board)
    for method, params in (("unpinChatMessage", {"message_id": old}), ("pinChatMessage", {"message_id": mid, "disable_notification": "true"})):
        if params["message_id"]:
            try:
                api(method, dict(params, chat_id=ALLOWED))
            except RuntimeError:
                pass  # pinning is cosmetic
    save_live({"path": path, "message_id": mid, "text": board, "done": False, "narr": "", "narr_at": 0})


def live_tick():
    """Called from the poll loop: start a board for a new cycle, or refresh the current one if it changed."""
    if not LIVE_BOARD or os.path.exists(os.path.join(STATE, "tg.live_off")):
        return
    path = activity.newest_cycle()
    if not path or time.time() - os.path.getmtime(path) > LIVE_MAX_AGE:
        return
    st = live_state()
    if st.get("path") != path:
        live_post(path)
        return
    if st.get("done") or not st.get("message_id"):
        return
    board = activity.render(path)
    finished = "Cycle finished" in board.splitlines()[0]
    if NARRATE and finished:  # one plain-English summary per cycle, when it ends (/explain for one on demand)
        narr = narrate.narrate(path)
        if narr:
            st.update(narr=narr, narr_at=time.time())
    text = compose(st.get("narr", ""), board)
    if text != st.get("text"):
        try:
            api("editMessageText", {"chat_id": ALLOWED, "message_id": st["message_id"], "text": text, "disable_web_page_preview": "true"})
        except RuntimeError:
            pass  # "message is not modified" or the message was deleted; /live posts a fresh one
    st.update(text=text, done=finished)
    save_live(st)


def run():
    if not ALLOWED:
        sys.exit("TG_ALLOWED_USER_ID is not set (config.sh)")
    os.makedirs(STATE, exist_ok=True)
    off_path = os.path.join(STATE, "tg.offset")
    try:
        offset = int(open(off_path).read().strip())
    except Exception:
        offset = 0
    last_digest = os.path.join(STATE, "tg.last_digest")
    ignored = 0
    backoff = 2
    last_live = 0
    print("tg-bridge: running (allowed user %s)" % ALLOWED, flush=True)
    while True:
        try:
            now = datetime.now()
            if now.hour == DIGEST_HOUR:
                today = now.strftime("%Y-%m-%d")
                try:
                    done = open(last_digest).read().strip()
                except OSError:
                    done = ""
                if done != today:
                    send(cmd_digest())
                    open(last_digest, "w").write(today)
            if time.time() - last_live >= LIVE_EVERY:
                last_live = time.time()
                try:
                    live_tick()
                except Exception as e:
                    print("tg-bridge: live board: %s" % e, flush=True)
            res = api("getUpdates", {"timeout": 25 if LIVE_BOARD else 50, "offset": offset, "allowed_updates": json.dumps(["message"])}, timeout=70)
            backoff = 2
            for upd in res.get("result", []):
                offset = upd["update_id"] + 1
                open(off_path, "w").write(str(offset))
                msg = upd.get("message") or {}
                frm = str((msg.get("from") or {}).get("id", ""))
                chat = msg.get("chat") or {}
                text = msg.get("text")
                if not text:
                    continue  # service messages (e.g. the bot's own "pinned a message" notice) and media: nothing to do
                if frm != ALLOWED or chat.get("type") != "private":
                    ignored += 1
                    print("tg-bridge: ignored a text message from unauthorized sender id %s in a %s chat (%d so far)"
                          % (frm or "?", chat.get("type", "?"), ignored), flush=True)
                    continue
                try:
                    reply = handle(text)
                except Exception as e:
                    reply = "Error handling that: %s" % type(e).__name__
                if reply:
                    send(reply)
        except KeyboardInterrupt:
            return
        except Exception as e:
            print("tg-bridge: %s (retry in %ds)" % (e, backoff), flush=True)
            time.sleep(backoff)
            backoff = min(backoff * 2, 120)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    mode = sys.argv[1]
    if mode == "run":
        run()
    elif mode == "send":
        if not ALLOWED or not token():
            sys.exit(3)  # not configured: caller falls back to a macOS notification
        try:
            send(" ".join(sys.argv[2:]))
        except Exception as e:
            print(e, file=sys.stderr)
            sys.exit(1)
    elif mode == "selftest":
        if not token():
            sys.exit("No bot token found in Keychain service %r." % SERVICE)
        try:
            me = api("getMe")
            print("bot ok: @%s" % me.get("result", {}).get("username", "?"))
            if not ALLOWED:
                sys.exit("TG_ALLOWED_USER_ID is empty in config.sh")
            send("agent-lab bridge online. Send /help.")
        except RuntimeError as e:
            sys.exit("selftest failed: %s (check the token; press Start in the bot chat first)" % e)
        print("hello sent to user id %s" % ALLOWED)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
