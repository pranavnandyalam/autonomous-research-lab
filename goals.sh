#!/usr/bin/env bash
# goals.sh — read or change the lab's goals (north-star.md in your lab repo) from your Mac.
#
#   ./goals.sh show            print the current goals
#   ./goals.sh edit            open them in $EDITOR, show the diff, confirm, push, and tell the agent
#   ./goals.sh set FILE        replace the goals with FILE (same diff + confirm + push + notify)
#
# The agent may never edit north-star.md; this pushes it with YOUR GitHub login (gh), not the sandbox token.
# You can also edit north-star.md on github.com (phone works); the agent re-reads it at the start of every cycle.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$KIT/config.sh"
API="repos/$GITHUB_USER/$REPO/contents/north-star.md"
command -v gh >/dev/null 2>&1 || { echo "goals.sh needs the GitHub CLI: brew install gh && gh auth login" >&2; exit 1; }
[ -n "$GITHUB_USER" ] || { echo "GITHUB_USER is empty (config)" >&2; exit 1; }

fetch() { # $1 = output file; prints the blob sha
  gh api "$API" > "$1.json" || { echo "could not read $API (is gh logged in as the repo owner?)" >&2; return 1; }
  python3 - "$1" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1] + ".json"))
open(sys.argv[1], "wb").write(base64.b64decode(d["content"]))
print(d["sha"])
PY
  rm -f "$1.json"
}

push() { # $1 = new file, $2 = sha it was based on, $3 = summary
  local b64; b64=$(python3 -c 'import base64,sys; print(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$1")
  gh api -X PUT "$API" -f message="[meta] north star: $3" -f content="$b64" -f sha="$2" -f branch=main \
    --jq '"pushed " + .commit.sha[0:7]' \
    || { echo "push refused: north-star.md changed on GitHub since you opened it. Run the command again." >&2; return 1; }
}

notify() { # queue a note for the agent's next cycle (same channel as Telegram free text)
  mkdir -p "$STATE_DIR"
  local t q
  for t in ${TEAMS:-main}; do   # every team gets the note (main's queue is inbox.txt)
    q="$STATE_DIR/inbox-$t.txt"; [ "$t" = "main" ] && q="$STATE_DIR/inbox.txt"
    printf '[%s] north-star.md was updated by the owner (%s). Re-read it this cycle and adjust plans and the backlog to match.\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$1" >> "$q"
  done
  echo "the agent will see the change at the start of its next cycle"
}

review_and_push() { # $1 = original, $2 = new, $3 = sha
  if cmp -s "$1" "$2"; then echo "no changes"; return 0; fi
  [ -s "$2" ] || { echo "refusing to push an empty goals file" >&2; return 1; }
  echo "---- changes ----"; diff -u "$1" "$2" | tail -n +3; echo "-----------------"
  local r summary
  printf 'Push these goals? [y/N] '; read -r r
  case "$r" in y|Y|yes) ;; *) echo "not pushed"; return 1 ;; esac
  printf 'One-line summary for the history (Enter for "updated goals"): '; read -r summary
  summary="${summary:-updated goals}"
  push "$2" "$3" "$summary" && notify "$summary"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
case "${1:-show}" in
  show)
    fetch "$tmp/ns.md" >/dev/null && cat "$tmp/ns.md" ;;
  edit)
    sha=$(fetch "$tmp/orig.md") || exit 1
    cp "$tmp/orig.md" "$tmp/north-star.md"
    "${EDITOR:-${VISUAL:-nano}}" "$tmp/north-star.md"
    review_and_push "$tmp/orig.md" "$tmp/north-star.md" "$sha" ;;
  set)
    [ -f "${2:-}" ] || { echo "usage: ./goals.sh set FILE" >&2; exit 2; }
    sha=$(fetch "$tmp/orig.md") || exit 1
    review_and_push "$tmp/orig.md" "$2" "$sha" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
