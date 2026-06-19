#!/bin/zsh
# SessionStart hook — surfaces AB scheduler blockers + last-run status into the
# Claude Code session when you open the folder. Reads EVERY registered project's
# backlog (~/.gsai/ab-scheduler/projects.conf). Silent when nothing is blocked.

set -u
unsetopt NOMATCH 2>/dev/null
CONF="$HOME/.gsai/ab-scheduler/projects.conf"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
MARKER="$SCRIPTS/.blocked-seen"

# Keep the repo-root BLOCKED.md fresh on session start.
"$SCRIPTS/ab-blocked-write-root.sh" >/dev/null 2>&1

OUT=""
BLOCKED_COUNT=0

[[ -f "$CONF" ]] && while IFS='|' read -r name dir minute; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  BDIR="$dir/backlog/blocked"
  LOG="$dir/backlog/.scheduler/runs.log"

  if [[ -d "$BDIR" ]]; then
    for f in "$BDIR"/*.md(N); do
      BLOCKED_COUNT=$((BLOCKED_COUNT+1))
      TID="$(basename "$f" .md)"
      WHAT="$(grep -A1 '## What.s blocked' "$f" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')"
      HOW="$(grep 'action needed' "$f" 2>/dev/null | head -1 | sed 's/.*needed:\**[[:space:]]*//')"
      REPLY="$(grep 'reply:' "$f" 2>/dev/null | head -1 | sed 's/.*reply:\**[[:space:]]*//')"
      OUT+=$'\n'"  🚧 [$name] $TID"
      OUT+=$'\n'"     • blocked: ${WHAT:-see file}"
      OUT+=$'\n'"     • needs:   ${HOW:-open the file}"
      OUT+=$'\n'"     • reply with: ${REPLY:-n/a}   →   $f"
    done
  fi

  if [[ -f "$LOG" ]]; then
    LAST="$(grep -E ' (DONE|BLOCKED|TIMEOUT|SKIP) ' "$LOG" 2>/dev/null | tail -1)"
    [[ -n "$LAST" ]] && OUT+=$'\n'"  ⏱ [$name] last: ${LAST}"
  fi
done < "$CONF"

# Seed the Stop-hook marker with the current set so it only fires for blockers
# that appear AFTER this session started.
{ [[ -f "$CONF" ]] && while IFS='|' read -r name dir minute; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    for f in "$dir/backlog/blocked/"*.md(N); do print -r -- "$name/$(basename "$f")"; done
  done < "$CONF"; } | sort > "$MARKER"

if (( BLOCKED_COUNT > 0 )); then
  printf '%s%s\n\n%s\n' "═══ AB Scheduler — $BLOCKED_COUNT blocker(s) need you ═══" "$OUT" "Reply in chat with the unblock answer and I'll clear it + requeue the task."
elif [[ -n "$OUT" ]]; then
  printf '%s%s\n' "═══ AB Scheduler — all clear ═══" "$OUT"
fi
exit 0
