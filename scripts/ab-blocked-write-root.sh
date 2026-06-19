#!/bin/zsh
# Regenerates /Users/vasanth/Code/cfw/BLOCKED.md from EVERY registered project's
# blocked/ dir (~/.gsai/ab-scheduler/projects.conf). Removes the file when nothing
# is blocked. Prints the blocker count to stdout. Single source of truth for
# blocker rendering — the surface hook, the Stop hook, and the worker all call this.

set -u
unsetopt NOMATCH 2>/dev/null
CONF="$HOME/.gsai/ab-scheduler/projects.conf"
# Aggregate blocker file. Override with AB_BLOCKED_ROOT; default kept for the
# existing cfw setup so live behavior is unchanged.
ROOT_FILE="${AB_BLOCKED_ROOT:-/Users/vasanth/Code/cfw/BLOCKED.md}"

BODY=""
COUNT=0

[[ -f "$CONF" ]] && while IFS='|' read -r name dir minute; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  BDIR="$dir/backlog/blocked"
  [[ -d "$BDIR" ]] || continue
  for f in "$BDIR"/*.md(N); do
    COUNT=$((COUNT+1))
    TID="$(basename "$f" .md)"
    WHAT="$(grep -A1 '## What.s blocked' "$f" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')"
    HOW="$(grep 'action needed' "$f" 2>/dev/null | head -1 | sed 's/.*needed:\**[[:space:]]*//')"
    REPLY="$(grep 'reply:' "$f" 2>/dev/null | head -1 | sed 's/.*reply:\**[[:space:]]*//')"
    BODY+=$'\n'"## 🚧 [$name] $TID"$'\n'
    BODY+="- **blocked:** ${WHAT:-see file}"$'\n'
    BODY+="- **needs:** ${HOW:-open the file}"$'\n'
    BODY+="- **reply with:** ${REPLY:-n/a}"$'\n'
    BODY+="- file: \`$f\`"$'\n'
  done
done < "$CONF"

if (( COUNT > 0 )); then
  {
    print -r -- "# 🚧 AB Scheduler — $COUNT blocker(s) need you"
    print -r --
    print -r -- "_Auto-generated. Reply in chat, run \`ab-scheduler-ctl.sh unblock\`, or fill the note's \`answer:\` field; the blocker clears and the task requeues._"
    print -r -- "$BODY"
  } > "$ROOT_FILE"
else
  rm -f "$ROOT_FILE"
fi

print -r -- "$COUNT"
exit 0
