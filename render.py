#!/usr/bin/env python3
"""render.py — fill the kit's {{PLACEHOLDERS}} from config.sh and print the result. Standard library only.

    python3 render.py prompt.md | agents.json | repo-seed/<file>

Placeholders: {{OWNER_NAME}}, {{GITHUB_USER}}, {{REPO}} (exported by config.sh).
JSON files are filled inside their parsed strings, so values are always escaped correctly.
Exits non-zero if a value is missing or a placeholder is left over, so a half-configured kit never reaches the agent.
"""
import json
import os
import re
import sys

KEYS = ("OWNER_NAME", "GITHUB_USER", "REPO")


def values():
    vals = {k: (os.environ.get(k) or "").strip() for k in KEYS}
    missing = [k for k, v in vals.items() if not v]
    if missing:
        sys.exit("render.py: set %s in config.local.sh (see config.local.sh.example)" % ", ".join(missing))
    return vals


def fill(text, vals):
    for k, v in vals.items():
        text = text.replace("{{%s}}" % k, v)
    return text


def fill_json(node, vals):
    if isinstance(node, str):
        return fill(node, vals)
    if isinstance(node, list):
        return [fill_json(x, vals) for x in node]
    if isinstance(node, dict):
        return {k: fill_json(v, vals) for k, v in node.items()}
    return node


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path, vals = sys.argv[1], values()
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    out = json.dumps(fill_json(json.loads(raw), vals), ensure_ascii=False) if path.endswith(".json") else fill(raw, vals)
    left = sorted(set(re.findall(r"\{\{[A-Z_]+\}\}", out)))
    if left:
        sys.exit("render.py: unfilled placeholders in %s: %s" % (path, ", ".join(left)))
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
