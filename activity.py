"""activity.py — turn a cycle's stream-json output into a plain-English board. Standard library only, read-only.

    python3 activity.py [path/to/cycle-*.json]     print the board for a cycle (default: the newest one)

Used by tg-bridge.py for the live Telegram board. The cycle file is written by agent-loop.sh
(claude -p --output-format stream-json): one JSON event per line.
"""
import glob
import json
import os
import re
import sys
import time
from datetime import datetime
from urllib.parse import urlparse

STATE = os.path.expanduser(os.environ.get("STATE_DIR", "~/.agent-lab"))
ICONS = {"lead": "🧠", "scout": "🔍", "builder": "🛠", "overseer": "🧐", "ethics-reviewer": "⚖️", "safety-guard": "🛡"}
NAMES = {"lead": "Lead", "scout": "Scout", "builder": "Builder", "overseer": "Overseer",
         "ethics-reviewer": "Ethics", "safety-guard": "Safety guard"}
MAX_AGENTS = 8
MAX_FEED = 8
MAX_LINE = 90
# agent-written text can carry terminal control codes (e.g. ESC ]52 rewrites the clipboard); strip them before printing
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def clip(text, n=MAX_LINE):
    s = " ".join(_CTRL.sub(" ", str(text or "")).split())
    return s if len(s) <= n else s[: n - 1] + "…"


FRIENDLY = (  # (regex on the repo-relative path, plain-English name); first match wins
    (r"(^|/)north-star\.md$", "the owner's goals for the lab"),
    (r"(^|/)radar\.md$", "the trend radar (what's hot in AI)"),
    (r"(^|/)backlog\.md$", "the list of project ideas"),
    (r"(^|/)questions\.md$", "the questions for the owner"),
    (r"(^|/)STATE[^/]*\.md$", "its working notes"),
    (r"^logs/", "the lab diary"),
    (r"(^|/)PLAN\.md$", "the research plan"),
    (r"(^|/)RESULTS\.md$", "the results write-up"),
    (r"(^|/)README\.md$", "the project summary"),
    (r"\.(py|ipynb)$", "the experiment code"),
    (r"(^|/)requirements[^/]*\.txt$", "the list of software it needs"),
    (r"\.(png|svg)$", "a chart"),
    (r"\.(csv|jsonl?|parquet)$", "a data/results file"),
)


def short_path(p):
    p = re.sub(r"^/home/agent/agent-lab/", "", str(p or ""))
    proj = re.match(r"projects/([^/]+)/", p)
    for pat, name in FRIENDLY:
        if re.search(pat, p):
            return name + (" for " + proj.group(1) if proj and "for " not in name else "")
    return p


def describe(name, inp):
    """One plain-English phrase for a tool call."""
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        cmd = str(inp.get("command", ""))
        if re.search(r"\bgit push\b", cmd):
            return "pushing to GitHub"
        m = (re.search(r"git commit[\s\S]*?<<-?['\"]?\w+['\"]?\n\s*([^\n]+)", cmd)  # -m "$(cat <<'EOF' ...)"
             or re.search(r"git commit[^\n]*?-m\s+[\"']([^\"'$][^\"']*)", cmd))
        if m:
            return "committing: " + clip(m.group(1), 60)
        if re.search(r"\bgit commit\b", cmd):
            return "committing changes"
        if inp.get("description"):
            return clip(inp["description"])
        if re.search(r"\bpip3? install\b", cmd):
            return "installing Python packages"
        if re.match(r"\s*python3?\s", cmd):
            return "running " + clip(cmd.split()[1], 50)
        return "running: " + clip(cmd, 60)
    if name == "Read":
        return "reading " + short_path(inp.get("file_path"))
    if name == "Write":
        return "writing " + short_path(inp.get("file_path"))
    if name in ("Edit", "MultiEdit"):
        return "editing " + short_path(inp.get("file_path"))
    if name in ("Glob", "Grep"):
        return "searching files for " + clip(inp.get("pattern"), 50)
    if name == "WebSearch":
        return "searching the web: " + clip(inp.get("query"), 70)
    if name == "WebFetch":
        u = urlparse(str(inp.get("url", "")))
        m = re.search(r"arxiv\.org/(?:abs|pdf)/([0-9.]+)", inp.get("url", ""))
        return "reading arXiv " + m.group(1) if m else "reading " + clip(u.netloc + u.path, 60)
    if name == "Agent":
        return "asked %s: %s" % (NAMES.get(inp.get("subagent_type"), inp.get("subagent_type") or "an agent"),
                                 clip(inp.get("description"), 60))
    if name == "TodoWrite":
        return "updating its checklist"
    if name in ("ScheduleWakeup", "ListAgents"):
        return "waiting for its agents to report back"
    return name


def newest_cycle(loop="main"):
    files = glob.glob(os.path.join(STATE, "outputs", "cycle-*-%s.json" % loop))
    return max(files, key=os.path.getmtime) if files else None


def newest_any():
    """The most recent cycle of any team."""
    files = glob.glob(os.path.join(STATE, "outputs", "cycle-*.json"))
    return max(files, key=os.path.getmtime) if files else None


def team_of(path):
    m = re.search(r"cycle-\d{8}T\d{6}-([A-Za-z0-9_]+)\.json$", os.path.basename(path))
    return m.group(1) if m else "main"


def cycle_start(path):
    m = re.search(r"cycle-(\d{8}T\d{6})-", os.path.basename(path))
    return datetime.strptime(m.group(1), "%Y%m%dT%H%M%S").timestamp() if m else os.path.getctime(path)


def parse(path):
    st = {"agents": {}, "order": [], "lead": "starting up", "feed": [], "todos": [], "steps": 0,
          "commits": 0, "result": None, "start": cycle_start(path)}

    def feed(who, text):
        if not st["feed"] or st["feed"][-1] != (who, text):
            st["feed"].append((who, text))

    with open(path, errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t, sub = e.get("type"), e.get("subtype")
            if t == "assistant" and not e.get("parent_tool_use_id"):
                for c in e.get("message", {}).get("content", []):
                    if c.get("type") != "tool_use":
                        continue
                    st["steps"] += 1
                    name, inp = c.get("name"), c.get("input") or {}
                    if name == "TodoWrite" and isinstance(inp.get("todos"), list):
                        st["todos"] = inp["todos"]
                    st["lead"] = describe(name, inp)
                    if name in ("Write", "Agent") or (name == "Bash" and re.search(r"git (push|commit)", str(inp.get("command")))):
                        feed("lead", st["lead"])
            elif t == "system" and sub == "task_started":
                tid = e.get("tool_use_id") or e.get("task_id")
                kind = e.get("subagent_type") or "job"
                st["agents"][tid] = {"kind": kind, "job": clip(e.get("description"), 60), "now": "starting", "status": "running",
                                     "tools": 0}
                st["order"].append(tid)
            elif t == "system" and sub == "task_progress":
                a = st["agents"].get(e.get("tool_use_id"))
                if a:
                    a["now"] = clip(e.get("description"), 70)
                    a["tools"] = (e.get("usage") or {}).get("tool_uses", a["tools"])
            elif t == "system" and sub == "task_notification":
                a = st["agents"].get(e.get("tool_use_id"))
                if a:
                    a["status"] = e.get("status") or "completed"
                    if a["kind"] != "job":
                        feed(a["kind"], "finished: " + a["job"])
            elif t == "system" and sub == "vcs_state_changed" and e.get("kind") == "commit":
                st["commits"] += 1
            elif t == "result":
                st["result"] = e
    return st


def render(path):
    st = parse(path)
    r = st["result"]
    mins = round((r.get("duration_ms") or 0) / 60000) if r else round((time.time() - st["start"]) / 60)
    if r:
        mark = re.search(r"CYCLE_RESULT:\s*([^\n]+)", str(r.get("result", "")))
        head = "%s Team %s · cycle finished · %d min · %s turns\n%s" % ("❌" if r.get("is_error") else "✅", team_of(path), mins, r.get("num_turns"),
                                                            clip(mark.group(1) if mark else r.get("subtype"), 300))
    else:
        head = "🔬 Team %s · cycle running · %d min · %d steps · %d commit%s" % (team_of(path), mins, st["steps"], st["commits"], "" if st["commits"] == 1 else "s")
    out = [head, "", "WHO'S DOING WHAT", "%s Lead — %s" % (ICONS["lead"], "done" if r else st["lead"])]
    agents = [st["agents"][k] for k in st["order"] if st["agents"][k]["kind"] != "job"]
    hidden = max(0, len(agents) - MAX_AGENTS)
    for a in agents[-MAX_AGENTS:]:
        icon, name = ICONS.get(a["kind"], "🤖"), NAMES.get(a["kind"], a["kind"])
        if a["status"] == "running":
            state = "🔄 " + a["now"]
        elif a["status"] == "completed":
            state = "✅ done (%s tool uses)" % a["tools"]
        else:
            state = "❌ " + a["status"]
        out.append("%s %s · %s\n      %s" % (icon, name, a["job"], state))
    if hidden:
        out.append("   …and %d earlier agents" % hidden)
    if st["todos"]:
        out += ["", "LEAD'S CHECKLIST"]
        marks = {"completed": "✅", "in_progress": "🔄", "pending": "⬜"}
        out += ["%s %s" % (marks.get(t.get("status"), "⬜"), clip(t.get("content"), 70)) for t in st["todos"][:10]]
    if st["feed"]:
        out += ["", "KEY STEPS SO FAR"]
        out += ["%s %s" % (ICONS.get(w, "🤖"), clip(txt, 80)) for w, txt in st["feed"][-MAX_FEED:]]
    return "\n".join(out)[:3900]


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else newest_cycle()
    if not p:
        sys.exit("no cycle output found in %s/outputs" % STATE)
    print(render(p))
