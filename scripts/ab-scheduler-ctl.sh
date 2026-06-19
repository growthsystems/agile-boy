#!/bin/zsh
# Control panel for the AB Scheduler — the unattended hourly CODE-task loop.
# Multi-project: the set of repos lives in ~/.gsai/ab-scheduler/projects.conf
# (managed by `register`/`unregister`). Each repo gets its own launchd job
# `com.absched.<name>` and its own backlog/{queue,blocked,.scheduler}.
#
# Usage: ab-scheduler-ctl.sh {status|list|on|off|run-now|logs|blockers|ready|
#                             approve|unhold|unblock|watch|register|unregister|test-notify} [args]

set -u
unsetopt NOMATCH 2>/dev/null   # unmatched globs pass through literally instead of erroring
LA="$HOME/Library/LaunchAgents"
CONF="$HOME/.gsai/ab-scheduler/projects.conf"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
WORKER="$SCRIPTS/ab-scheduler.sh"
LABEL_PREFIX="com.absched"

mkdir -p "$(dirname "$CONF")"
[[ -f "$CONF" ]] || : > "$CONF"

# Emit "name<TAB>dir<TAB>minute" for each active (non-comment) registry line.
read_projects() {
  [[ -f "$CONF" ]] || return 0
  while IFS='|' read -r name dir minute; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    print -r -- "$name	${dir}	${minute}"
  done < "$CONF"
}
proj_dir() { read_projects | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }

cmd="${1:-status}"
which="${2:-all}"

case "$cmd" in
  status)
    print "Loaded AB Scheduler jobs (col1=pid '-'=idle, col2=last exit):"
    launchctl list | grep "$LABEL_PREFIX" || print "  (none loaded)"
    ;;
  list)
    print "Registered projects (~/.gsai/ab-scheduler/projects.conf):"
    read_projects | while IFS=$'\t' read -r name dir minute; do
      print "  • $name  (:$minute)  → $dir"
    done
    [[ -z "$(read_projects)" ]] && print "  (none registered yet — use: $0 register <name> <project-dir>)"
    ;;
  on)
    read_projects | while IFS=$'\t' read -r name dir minute; do
      launchctl load -w "$LA/$LABEL_PREFIX.$name.plist" 2>/dev/null && print "  enabled $name (:$minute)"
    done
    ;;
  off)
    read_projects | while IFS=$'\t' read -r name dir minute; do
      launchctl unload -w "$LA/$LABEL_PREFIX.$name.plist" 2>/dev/null && print "  disabled $name"
    done
    ;;
  run-now)
    # run-now [name|all] — trigger immediately (don't wait for the hour).
    if [[ "$which" == "all" ]]; then
      read_projects | while IFS=$'\t' read -r name dir minute; do
        launchctl start "$LABEL_PREFIX.$name" && print "kicked $name"
      done
    else
      launchctl start "$LABEL_PREFIX.$which" && print "kicked $which"
    fi
    print "Tail logs with: $0 logs $which"
    ;;
  logs)
    read_projects | while IFS=$'\t' read -r name dir minute; do
      [[ "$which" != "all" && "$which" != "$name" ]] && continue
      print "═══ $name runs.log (last 15) ═══"
      tail -15 "$dir/backlog/.scheduler/runs.log" 2>/dev/null || print "  (no runs yet)"
    done
    ;;
  blockers)
    /bin/zsh "$SCRIPTS/ab-blocked-surface.sh"
    ;;
  ready)
    # What the scheduler WOULD work next (status:ready, unblocked), per project.
    read_projects | while IFS=$'\t' read -r name dir minute; do
      print "═══ $name — approved & eligible (status:ready) ═══"
      found=0
      for f in "$dir"/backlog/queue/*.md(N); do
        st="$(grep -m1 '^status:' "$f" | sed 's/status:[[:space:]]*//; s/["'\'' ]//g')"
        [[ "$st" == "ready" ]] || continue
        pri="$(grep -m1 '^priority:' "$f" | sed 's/priority:[[:space:]]*//; s/["'\'' ]//g')"
        print "  • [$pri] $(basename "$f" .md)"
        found=1
      done
      (( found == 0 )) && print "  (none — nothing will run; mark a task status: ready to approve it)"
    done
    ;;
  approve)
    pat="${2:?usage: $0 approve <task-id-or-filename-substring>}"
    hit=""
    while IFS=$'\t' read -r name dir minute; do
      for f in "$dir"/backlog/queue/*"$pat"*.md(N); do hit="$f"; break; done
      [[ -n "$hit" ]] && break
    done < <(read_projects)
    [[ -z "$hit" ]] && { print "No queued task matching '$pat'"; exit 1; }
    /usr/bin/sed -i '' -E 's/^status:.*/status: ready/' "$hit"
    print "Approved → $(basename "$hit")  (now status: ready)"
    ;;
  unhold|unapprove)
    pat="${2:?usage: $0 unhold <task-id-or-filename-substring>}"
    hit=""
    while IFS=$'\t' read -r name dir minute; do
      for f in "$dir"/backlog/queue/*"$pat"*.md(N); do hit="$f"; break; done
      [[ -n "$hit" ]] && break
    done < <(read_projects)
    [[ -z "$hit" ]] && { print "No queued task matching '$pat'"; exit 1; }
    /usr/bin/sed -i '' -E 's/^status:.*/status: backlog/' "$hit"
    print "Held → $(basename "$hit")  (now status: backlog — scheduler will skip it)"
    ;;
  unblock)
    # unblock <task-id> <answer...> — clear a blocker, fold the answer into the
    # task, set it ready, requeue it, delete the blocked note.
    id="${2:?usage: $0 unblock <task-id> <answer text>}"; shift 2
    answer="$*"
    [[ -z "$answer" ]] && { print "Provide the unblock answer: $0 unblock $id \"the answer\""; exit 1; }
    proj=""; pdir=""; note=""
    while IFS=$'\t' read -r name dir minute; do
      n="$(ls "$dir"/backlog/blocked/*"$id"*.md 2>/dev/null | head -1)"
      [[ -n "$n" ]] && { proj="$name"; pdir="$dir"; note="$n"; break; }
    done < <(read_projects)
    [[ -z "$note" ]] && { print "No blocker matching '$id' in any registered project."; exit 1; }
    realid="$(basename "$note" .md)"
    tf="$(grep -rl "task-id:.*$realid" "$pdir/backlog/queue" "$pdir/backlog/wip" 2>/dev/null | head -1)"
    if [[ -n "$tf" ]]; then
      { print ""; print "## Owner resolution ($(date +%F))"; print "$answer"; } >> "$tf"
      /usr/bin/sed -i '' -E 's/^status:.*/status: ready/' "$tf"
      case "$tf" in
        *"/backlog/wip/"*) mv "$tf" "$pdir/backlog/queue/$(basename "$tf")"
                           tf="$pdir/backlog/queue/$(basename "$tf")" ;;
      esac
      print "Unblocked → $realid : answer folded in, status: ready, back in $proj queue."
    else
      print "WARN: cleared blocker but no task file found for $realid (it may already be done)."
    fi
    rm -f "$note"
    "$SCRIPTS/ab-blocked-write-root.sh" >/dev/null 2>&1
    ;;
  watch)
    # Auto-unblock loop. For any blocked note whose `answer:` field is filled,
    # unblock it and kick an immediate run. Safe to /loop.
    acted=0
    while IFS=$'\t' read -r name dir minute; do
      for note in "$dir"/backlog/blocked/*.md(N); do
        ans="$(grep -m1 '^answer:' "$note" | sed 's/^answer:[[:space:]]*//; s/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$ans" ]] && continue
        id="$(basename "$note" .md)"
        print "▶ [$name] answer found for $id — unblocking…"
        "$0" unblock "$id" "$ans"
        launchctl start "$LABEL_PREFIX.$name" 2>/dev/null && print "  ↻ kicked $name run — work resumes now"
        acted=1
      done
    done < <(read_projects)
    (( acted == 0 )) && print "watch: no blocked note has a filled answer: field — nothing to resume."
    ;;
  register)
    # register <name> <project-dir> — add a code repo to the loop (fires every 30 min).
    name="${2:?usage: $0 register <name> <project-dir>}"
    dir="${3:?usage: $0 register <name> <project-dir>}"
    dir="${dir:A}"   # absolutize
    [[ -d "$dir" ]] || { print "✗ not a directory: $dir"; exit 1; }
    grep -q "^$name|" "$CONF" 2>/dev/null && { print "✗ '$name' already registered"; exit 1; }
    TARGET="${AB_MERGE_TARGET:-develop}"
    # the parallel worker uses git worktrees — must be a git repo
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      print "✗ $dir is not a git repo — the parallel worker needs worktrees. Aborting."; exit 1
    fi
    # ensure the merge-target branch exists locally + on origin, else the worker FATALs
    if ! git -C "$dir" show-ref --verify --quiet "refs/heads/$TARGET"; then
      base="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo main)"
      git -C "$dir" branch "$TARGET" >/dev/null 2>&1 && print "  ↳ created branch '$TARGET' from '$base'"
    fi
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      if ! git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$TARGET"; then
        if git -C "$dir" push -u origin "$TARGET" >/dev/null 2>&1; then
          print "  ↳ pushed '$TARGET' to origin"
        else
          print "  ⚠ couldn't push '$TARGET' to origin — push it manually or the merge worktree can't reset"
        fi
      fi
    else
      print "  ⚠ no 'origin' remote — the worker resets to origin/$TARGET and will fail without one"
    fi
    # pick a free BASE minute in [0,30); job fires at base and base+30 (twice/hour, staggered)
    used="$(read_projects | cut -f3 | tr '\n' ' ')"
    minute=""
    for m in 0 15 7 22 3 18 11 26 5 20 13 28 1 16 9 24; do
      [[ " $used " == *" $m "* ]] || { minute=$m; break; }
    done
    [[ -z "$minute" ]] && minute=$(( RANDOM % 30 ))
    minute2=$(( (minute + 30) % 60 ))
    mkdir -p "$dir/backlog/queue" "$dir/backlog/blocked" "$dir/backlog/.scheduler"
    # warn if the repo lacks the ab-* command suite (the loop runs /ab-work-on-it)
    if ! ls "$dir"/.claude/commands/ab-work-on-it.md >/dev/null 2>&1; then
      print "⚠ $dir has no .claude/commands/ab-work-on-it.md — the loop will SKIP until the ab-* suite is installed there."
    fi
    plist="$LA/$LABEL_PREFIX.$name.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL_PREFIX.$name</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$WORKER</string>
        <string>$dir</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Minute</key><integer>$minute</integer></dict>
        <dict><key>Minute</key><integer>$minute2</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$dir/backlog/.scheduler/launchd.out</string>
    <key>StandardErrorPath</key>
    <string>$dir/backlog/.scheduler/launchd.err</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
    print "$name|$dir|$minute" >> "$CONF"
    launchctl load -w "$plist" 2>/dev/null
    print "✓ registered $name → $dir  (every 30 min at :$minute/:$minute2, job $LABEL_PREFIX.$name, merge → $TARGET)"
    print "  next: write tasks into $dir/backlog/queue/ then '$0 approve <id>'"
    ;;
  unregister)
    name="${2:?usage: $0 unregister <name>}"
    grep -q "^$name|" "$CONF" 2>/dev/null || { print "✗ '$name' not registered"; exit 1; }
    launchctl unload -w "$LA/$LABEL_PREFIX.$name.plist" 2>/dev/null || true
    rm -f "$LA/$LABEL_PREFIX.$name.plist"
    /usr/bin/sed -i '' "/^$name|/d" "$CONF"
    print "✓ unregistered $name (job + plist removed; its backlog/ left intact)"
    ;;
  test-notify)
    title="🚧 AB Scheduler (test)"
    msg="This is how a real block reaches you. Click to open the blocked note."
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "$title" -message "$msg" -sound Glass -open "obsidian://open?vault=cfw" >/dev/null 2>&1
      print "Fired via terminal-notifier — clickable."
    else
      /usr/bin/osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" 2>/dev/null
      print "Fired via osascript — NOT clickable. For click-to-open: brew install terminal-notifier"
    fi
    ;;
  *)
    print "Usage: $0 {status|list|on|off|ready|approve <id>|unhold <id>|blockers|unblock <id> <answer>|watch|run-now [name|all]|logs [name|all]|register <name> <dir>|unregister <name>|test-notify}"
    ;;
esac
