#!/bin/zsh
# Stop hook — when this session goes idle, re-check blocked/ across EVERY
# registered project (~/.gsai/ab-scheduler/projects.conf). Fires ONCE per NEW
# blocker (dedup via marker), injecting it back into the session so a mid-session
# block isn't missed until the next restart.
#
# Reads Claude's hook JSON on stdin; respects stop_hook_active to avoid loops.

set -u
unsetopt NOMATCH 2>/dev/null
CONF="$HOME/.gsai/ab-scheduler/projects.conf"
BLOCKED_ROOT="${AB_BLOCKED_ROOT:-/Users/vasanth/Code/cfw/BLOCKED.md}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
MARKER="$SCRIPTS/.blocked-seen"

INPUT="$(cat)"
if print -r -- "$INPUT" | grep -q '"stop_hook_active":[[:space:]]*true'; then
  exit 0
fi

"$SCRIPTS/ab-blocked-write-root.sh" >/dev/null 2>&1

# name → dir map
typeset -A DIRS
[[ -f "$CONF" ]] && while IFS='|' read -r name dir minute; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  DIRS[$name]="$dir"
done < "$CONF"

CURRENT=""
for name in ${(k)DIRS}; do
  for f in "${DIRS[$name]}/backlog/blocked/"*.md(N); do
    CURRENT+="$name/$(basename "$f")"$'\n'
  done
done
CURRENT="$(print -r -- "$CURRENT" | grep -v '^$' | sort)"

SEEN=""
[[ -f "$MARKER" ]] && SEEN="$(sort "$MARKER" 2>/dev/null)"

NEW="$(comm -13 <(print -r -- "$SEEN") <(print -r -- "$CURRENT") 2>/dev/null | grep -v '^$')"

print -r -- "$CURRENT" > "$MARKER"

[[ -z "$NEW" ]] && exit 0

REASON="🚧 A new AB Scheduler blocker appeared while you were working. Surface it to the user now:"$'\n'
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  proj="${entry%%/*}"; base="${entry#*/}"
  file="${DIRS[$proj]}/backlog/blocked/$base"
  tid="${base%.md}"
  what="$(grep -A1 '## What.s blocked' "$file" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')"
  reply="$(grep 'reply:' "$file" 2>/dev/null | head -1 | sed 's/.*reply:\**[[:space:]]*//')"
  REASON+=$'\n'"• [$proj] $tid — $what"$'\n'"  to unblock, ask the user to reply: $reply"
done <<< "$NEW"
REASON+=$'\n\n'"Full detail in $BLOCKED_ROOT. Do not invent an answer — relay the blocker and wait for the user."

ESC="$(print -r -- "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')"
printf '{"decision":"block","reason":"%s"}\n' "$ESC"
exit 0
