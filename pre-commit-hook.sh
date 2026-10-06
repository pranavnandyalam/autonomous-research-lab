#!/bin/sh
# Installed by setup.sh into the VM clone's .git/hooks/pre-commit. Blocks secrets, big files and agent-config files.
fail=0
added=$(git diff --cached -U0 --no-color | grep '^+' | grep -v '^+++')
if printf '%s' "$added" | grep -nEq '(sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|AIza[0-9A-Za-z_-]{30,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,})'; then
  echo "pre-commit: possible secret in staged changes. Remove it." >&2; fail=1
fi
for f in $(git diff --cached --name-only --diff-filter=AM); do
  case "$f" in .claude/*|*/.claude/*|CLAUDE.md|*/CLAUDE.md|.mcp.json|*/.mcp.json|.github/workflows/*|north-star.md)
    echo "pre-commit: forbidden path $f" >&2; fail=1 ;;
  esac
  [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 5242880 ] && { echo "pre-commit: $f is over 5MB" >&2; fail=1; }
done
exit $fail
