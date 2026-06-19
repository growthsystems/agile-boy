#!/bin/zsh
# ============================================================================
# CFW AB Scheduler — unattended PARALLEL backlog worker
# ----------------------------------------------------------------------------
# Picks up to AB_FANOUT (default 3) status:ready tasks and works them
# CONCURRENTLY, each in its own git worktree on branch ab/<TASK-ID>. Each
# headless agent ONLY implements + tests + commits to its own branch — it does
# NOT merge or touch the shared branch. After all agents finish, THIS wrapper
# merges each successful branch into the merge target (default `develop`) one
# at a time, in a dedicated merge worktree, so there are zero index/HEAD races
# (no flock needed — macOS doesn't ship it). On a HARD block the agent writes
# backlog/blocked/<task>.md and we fire a macOS notification + log it.
#
# Usage:  ab-scheduler.sh <ABSOLUTE_PROJECT_DIR>
# Invoked by launchd (see ~/Library/LaunchAgents/com.absched.<name>.plist)
#
# Knobs (env or backlog/.scheduler/config):
#   AB_FANOUT        how many tasks to work in parallel        (default 3)
#   AB_MERGE_TARGET  branch the wrapper merges into            (default develop)
#   AB_READY_STATUS  task status that counts as approved       (default ready)
#   AB_AGENT_TIMEOUT per-agent wall-clock cap, seconds         (default 1500)
# ============================================================================

set -u

PROJECT_DIR="${1:?usage: ab-scheduler.sh <project-dir>}"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Environment (launchd starts with a bare PATH) --------------------------
export PATH="/Users/vasanth/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/cmux.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/vasanth}"

STATE_DIR="$PROJECT_DIR/backlog/.scheduler"
BLOCKED_DIR="$PROJECT_DIR/backlog/blocked"
LOG="$STATE_DIR/runs.log"
LOCK="$STATE_DIR/run.lock"
WT_BASE="$HOME/.claude-worktrees"

mkdir -p "$STATE_DIR" "$BLOCKED_DIR" "$WT_BASE"

# --- Optional per-repo config overrides -------------------------------------
[[ -f "$STATE_DIR/config" ]] && source "$STATE_DIR/config"

FANOUT="${AB_FANOUT:-3}"
MERGE_TARGET="${AB_MERGE_TARGET:-develop}"
READY_STATUS="${AB_READY_STATUS:-ready}"
AGENT_TIMEOUT="${AB_AGENT_TIMEOUT:-1500}"   # 25 min/agent — under the 30-min cadence

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [$PROJECT_NAME] $*" >> "$LOG"; }

# Percent-encode a string (pure zsh, ASCII-safe) for obsidian:// URLs.
urlencode() {
  local s="$1" out="" i c
  for (( i=1; i<=${#s}; i++ )); do
    c="${s[i]}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  print -r -- "$out"
}

# Build a click target for a blocked note (Obsidian deep-link for cfw vault).
open_target() {
  local abs="$1" rel
  case "$abs" in
    /Users/vasanth/Code/cfw/*)
      rel="${abs#/Users/vasanth/Code/cfw/}"; rel="${rel%.md}"
      print -r -- "obsidian://open?vault=cfw&file=$(urlencode "$rel")" ;;
    *)
      local enc="" seg IFS=/
      for seg in ${abs#/}; do enc+="/$(urlencode "$seg")"; done
      print -r -- "file://$enc" ;;
  esac
}

# notify <title> <message> [open-url]
notify() {
  local title="$1" msg="$2" open="${3:-}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    if [[ -n "$open" ]]; then
      terminal-notifier -title "$title" -message "$msg" -sound Glass -open "$open" >/dev/null 2>&1
    else
      terminal-notifier -title "$title" -message "$msg" -sound Glass >/dev/null 2>&1
    fi
  else
    /usr/bin/osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" 2>/dev/null
  fi
}

# fatal <msg> — loud, non-silent abort (Tier 2). Old code did `log + exit 1`
# silently, so cfw-social died every 30 min for hours with nobody told.
fatal() {
  log "FATAL — $1"
  notify "🆘 $PROJECT_NAME scheduler FATAL" "$1"
  rm -rf "$LOCK" 2>/dev/null
  exit 1
}

# preflight — Tier 1 self-heal. Verify + auto-fix the environment before doing
# any work; notify (never silently die) on anything unfixable.
preflight() {
  command -v claude >/dev/null 2>&1 || fatal "claude CLI not on PATH (launchd PATH drift → the old 'exit 127' failures)"
  command -v git   >/dev/null 2>&1 || fatal "git not on PATH"
  git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || fatal "$PROJECT_DIR is not a git repo"

  git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1   # clear stale worktree refs
  git -C "$PROJECT_DIR" fetch origin --prune >/dev/null 2>&1

  # Ensure the integration branch exists on origin; bootstrap from main if missing.
  if ! git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/remotes/origin/$MERGE_TARGET"; then
    log "PREFLIGHT — origin/$MERGE_TARGET missing; bootstrapping from origin/main"
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/remotes/origin/main"; then
      git -C "$PROJECT_DIR" push origin "refs/remotes/origin/main:refs/heads/$MERGE_TARGET" >/dev/null 2>&1
      git -C "$PROJECT_DIR" fetch origin "$MERGE_TARGET" >/dev/null 2>&1
    fi
    git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/remotes/origin/$MERGE_TARGET" || \
      fatal "merge target '$MERGE_TARGET' missing on origin and could not be bootstrapped from main"
  fi

  # Disk headroom (warn-only — worktrees + node_modules are hungry).
  local avail_kb
  avail_kb="$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "$avail_kb" ]] && (( avail_kb < 2000000 )); then
    log "PREFLIGHT — low disk: $((avail_kb/1024))MB free under $HOME"
    notify "⚠️ $PROJECT_NAME low disk" "$((avail_kb/1024))MB free under $HOME — builds may fail"
  fi
}

# --- Overlap guard: one BATCH at a time per repo ----------------------------
if [[ -d "$LOCK" ]]; then
  OLDPID="$(cat "$LOCK/pid" 2>/dev/null)"
  if [[ -n "$OLDPID" ]] && kill -0 "$OLDPID" 2>/dev/null; then
    log "SKIP — previous batch (pid $OLDPID) still active"
    exit 0
  fi
  log "WARN — stale lock found (pid $OLDPID gone), reclaiming"
  rm -rf "$LOCK"
fi
mkdir -p "$LOCK" && print -r -- "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT INT TERM

# --- Tier 1: self-healing preflight (verify/auto-fix env, loud on failure) ---
preflight

# --- Snapshot blocked/ before the run so we can detect NEW blocks ------------
BEFORE="$(ls -1 "$BLOCKED_DIR"/*.md 2>/dev/null | sort)"

# --- The protocol injected into every agent's system prompt -----------------
# NOTE the key difference vs the old serial worker: the agent must NOT merge,
# must NOT switch branches, must NOT remove its worktree, must NOT archive.
# It commits to ITS OWN branch and stops. The wrapper owns merge + cleanup.
read -r -d '' AGENT_PROTOCOL <<'PROTO'
You are running UNATTENDED as one of several parallel workers. No human is watching.

ISOLATION CONTRACT — read carefully, this is non-negotiable:
- You are ALREADY inside a dedicated git worktree, checked out on a branch named ab/<TASK-ID>.
- Do ALL work here. Implement the task, run the project's tests/build/lint, fix until green,
  and COMMIT everything to the CURRENT branch.
- Do NOT create another git worktree. Do NOT `git checkout` or `git switch` to any other
  branch. Do NOT merge. Do NOT push. Do NOT remove this worktree. Do NOT archive the task.
  The scheduler merges your branch into the integration branch and cleans up AFTER you exit.
- If /ab-work-on-it or /ab-test-and-complete try to create a worktree, merge, or switch
  branches, SKIP those steps — they are handled by the scheduler. Keep only the
  implement + validate + commit parts.

Be fully autonomous on normal decisions — make the call a competent engineer would make.

EVIDENCE & HONESTY CONTRACT — how you report completion (non-negotiable):
- For EVERY acceptance criterion, you must EITHER back it with a concrete, REPRODUCIBLE artifact
  OR mark it PARTIAL/UNMET. Prose is not evidence. There is no third option.
  * Code criteria  → cite the real `file:line` that implements it.
  * Behaviour/validation criteria → commit an ACTUAL test (Playwright/vitest/etc.) or paste the
    REAL command output. A described "validation table" with no committed test and no captured
    output does NOT count as done — do not invent one.
  * Content/asset criteria you cannot fully satisfy (e.g. a real video URL you don't have) →
    mark PARTIAL and list under "Follow-ups". Do NOT mark such a task 100% / complete.
- UNDER-CLAIM, never overstate. If you are not certain a criterion is genuinely met with a real
  artifact, mark it PARTIAL. Reporting a placeholder or aspiration as "done" is the WORST failure
  mode — worse than leaving the task open.
- In your completion notes include a table:
  | criterion | MET / PARTIAL / UNMET | artifact (file:line / test / output) |
  If ANY criterion is not MET with an artifact, set the task `status: coding_done` (NOT complete)
  so a human reviews it — do not self-certify 100%.

ONLY stop for a HARD block: a missing credential/secret you cannot obtain, an irreversible or
destructive decision, a genuine product ambiguity where guessing wrong is costly, or an external
dependency that is down. When (and only when) that happens, do NOT guess. Instead:

1. Write a file `backlog/blocked/<TASK-ID>.md` (path relative to the repo root) with EXACTLY:

---
task-id: "<TASK-ID>"
blocked-at: "<current ISO timestamp>"
needs: decision | info | access | dependency
severity: hard
answer: ""
---

## What's blocked
<one or two sentences — the specific task and the specific point it stalled>

## Why
<the precise reason you cannot proceed autonomously>

## How to unblock
- **The decision/info/action needed:** <specific>
- **My recommended option:** <your pick + one-line rationale>
- **To auto-resume:** fill the `answer:` field in this file's frontmatter with the single
  answer that unblocks it — the `watch` verb requeues the task on its next pass.
  (Or reply in chat / run `ab-scheduler-ctl.sh unblock <TASK-ID> "<answer>"`.)
- **Commands/files involved:** <paths, env vars, or commands>

2. Commit whatever partial work is safe to keep, then END the run cleanly. Do not leave
   the worktree in a broken/uncommitted state.

If you finish with no block, do NOT create any blocked/ file.
PROTO

# --- APPROVAL GATE: collect the top FANOUT status:ready, unblocked tasks -----
# Sort key: priority rank (high<normal<low<other), then mtime (FIFO).
typeset -a CAND_RANK CAND_MT CAND_ID CAND_FILE
for f in "$PROJECT_DIR"/backlog/queue/*.md; do
  [[ -e "$f" ]] || continue
  st="$(grep -m1 '^status:' "$f" | sed 's/status:[[:space:]]*//; s/["'\'' ]//g')"
  [[ "$st" == "$READY_STATUS" ]] || continue
  bb="$(grep -m1 '^blocked-by:' "$f" | sed 's/blocked-by:[[:space:]]*//; s/[[:space:]]//g')"
  [[ -n "$bb" && "$bb" != "null" && "$bb" != "[]" && "$bb" != "—" ]] && continue
  pri="$(grep -m1 '^priority:' "$f" | sed 's/priority:[[:space:]]*//; s/["'\'' ]//g')"
  case "$pri" in high) rank=0 ;; normal|medium) rank=1 ;; low) rank=2 ;; *) rank=3 ;; esac
  mt="$(stat -f %m "$f" 2>/dev/null || echo 0)"
  tid="$(grep -m1 '^task-id:' "$f" | sed 's/task-id:[[:space:]]*//; s/["'\'' ]//g')"
  [[ -z "$tid" ]] && tid="$(basename "$f" .md)"
  CAND_RANK+=("$rank"); CAND_MT+=("$mt"); CAND_ID+=("$tid"); CAND_FILE+=("$f")
done

if (( ${#CAND_ID} == 0 )); then
  log "SKIP — no status:$READY_STATUS unblocked task in queue (nothing approved to work)"
  exit 0
fi

# Order candidates: build "rank:mtime:index" keys, sort, take first FANOUT.
typeset -a ORDER
for i in {1..${#CAND_ID}}; do
  ORDER+=("$(printf '%d:%012d:%d' "${CAND_RANK[$i]}" "${CAND_MT[$i]}" "$i")")
done
typeset -a SORTED; SORTED=(${(on)ORDER})   # numeric-ish lexical sort, ascending

typeset -a SEL_ID SEL_FILE
for key in "${SORTED[@]}"; do
  (( ${#SEL_ID} >= FANOUT )) && break
  idx="${key##*:}"
  SEL_ID+=("${CAND_ID[$idx]}"); SEL_FILE+=("${CAND_FILE[$idx]}")
done

log "BATCH START — fan-out ${#SEL_ID}/$FANOUT → ${SEL_ID[*]} (target: $MERGE_TARGET)"

# --- Ensure the dedicated merge worktree exists & is current -----------------
# DETACHED on purpose: if it claimed the $MERGE_TARGET branch, git would refuse
# to create it whenever the primary repo is itself checked out on $MERGE_TARGET
# (which is the normal state for cfw-social). A detached HEAD at origin/$MERGE_TARGET
# sidesteps that entirely; we push with HEAD:$MERGE_TARGET.
MERGE_WT="$WT_BASE/${PROJECT_NAME}-ab-${MERGE_TARGET}"
git -C "$PROJECT_DIR" fetch origin "$MERGE_TARGET" >/dev/null 2>&1
if [[ ! -d "$MERGE_WT/.git" && ! -f "$MERGE_WT/.git" ]]; then
  git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1
  if ! git -C "$PROJECT_DIR" worktree add --detach "$MERGE_WT" "origin/$MERGE_TARGET" >/dev/null 2>&1; then
    fatal "cannot create detached merge worktree at $MERGE_WT (origin/$MERGE_TARGET=$(git -C "$PROJECT_DIR" rev-parse --short origin/$MERGE_TARGET 2>/dev/null))"
  fi
fi
git -C "$MERGE_WT" reset --hard "origin/$MERGE_TARGET" >/dev/null 2>&1

# Helper: link gitignored runtime deps/secrets into a fresh task worktree so
# the agent can build/test without a 3x `pnpm install`.
# CRITICAL: a `node_modules` SYMLINK is not matched by a `node_modules/`
# (trailing-slash) .gitignore rule, so a careless `git add -A` will commit it.
# Belt-and-braces: add the names to the SHARED git exclude (covers all worktrees)
# so they can never be staged regardless of the repo's .gitignore.
link_runtime() {  # link_runtime <worktree>
  local wt="$1" item excl
  excl="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)/info/exclude"
  for item in node_modules .env .env.local .env.development; do
    [[ -e "$PROJECT_DIR/$item" && ! -e "$wt/$item" ]] && ln -s "$PROJECT_DIR/$item" "$wt/$item"
    [[ -f "$excl" ]] && ! grep -qxF "$item" "$excl" 2>/dev/null && print -r -- "$item" >> "$excl"
  done
}

# on_merged — shared success path: archive the task, drop branch + worktree.
on_merged() {  # on_merged <branch> <wt> <tfile>
  local branch="$1" wt="$2" tfile="$3"
  if [[ -f "$tfile" ]]; then
    local arch="$PROJECT_DIR/backlog/done/$(date +%Y-%m)"; mkdir -p "$arch"
    perl -0pi -e 's/^status:.*$/status: complete/m' "$tfile" 2>/dev/null
    mv "$tfile" "$arch/" 2>/dev/null
  fi
  git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
  git -C "$PROJECT_DIR" branch -D "$branch" >/dev/null 2>&1
}

# guard_forbidden — Tier 4. Strip never-commit junk (node_modules, .env*, build
# artifacts) that an agent's `git add -A` may have leaked onto its branch, BEFORE
# it can ride a merge to origin. Adds one cleanup commit on the branch. Returns 0.
guard_forbidden() {  # guard_forbidden <tid> <branch>
  local tid="$1" branch="$2" f cw
  typeset -a strip
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      node_modules|node_modules/*|.env|.env.*|.next/*|dist/*|build/*|coverage/*|*.log|.DS_Store) strip+=("$f") ;;
    esac
  done < <(git -C "$PROJECT_DIR" diff --name-only "origin/$MERGE_TARGET..$branch" 2>/dev/null)
  (( ${#strip} == 0 )) && return 0
  cw="$WT_BASE/${PROJECT_NAME}-${tid}-clean"
  git -C "$PROJECT_DIR" worktree remove --force "$cw" >/dev/null 2>&1
  if git -C "$PROJECT_DIR" worktree add "$cw" "$branch" >/dev/null 2>&1; then
    for f in "${strip[@]}"; do git -C "$cw" rm -r --cached --ignore-unmatch "$f" >/dev/null 2>&1; done
    git -C "$cw" commit -m "chore(ab-scheduler): strip forbidden paths before merge (${strip[*]})" >/dev/null 2>&1
    git -C "$PROJECT_DIR" worktree remove --force "$cw" >/dev/null 2>&1
    log "  🧹 $tid — stripped forbidden paths from $branch: ${strip[*]}"
    notify "🧹 $PROJECT_NAME cleaned: $tid" "Stripped ${strip[*]} before merge"
  fi
  return 0
}

# rebase_retry — Tier 3. A first-pass merge conflict is often just batch-ordering
# (this branch was cut before a sibling merged). Rebase it onto the fresh target
# and report whether it now replays cleanly. Echoes "ok" on success.
rebase_retry() {  # rebase_retry <tid> <branch>
  local tid="$1" branch="$2" rb result="no"
  rb="$WT_BASE/${PROJECT_NAME}-${tid}-rb"
  git -C "$PROJECT_DIR" worktree remove --force "$rb" >/dev/null 2>&1
  if git -C "$PROJECT_DIR" worktree add "$rb" "$branch" >/dev/null 2>&1; then
    if git -C "$rb" rebase "origin/$MERGE_TARGET" >/dev/null 2>&1; then
      result="ok"
    else
      git -C "$rb" rebase --abort >/dev/null 2>&1
    fi
    git -C "$PROJECT_DIR" worktree remove --force "$rb" >/dev/null 2>&1
  fi
  print -r -- "$result"
}

# --- Launch the agents in parallel, one worktree each ------------------------
typeset -a A_ID A_WT A_BRANCH A_PID A_OUT
for i in {1..${#SEL_ID}}; do
  tid="${SEL_ID[$i]}"
  branch="ab/$tid"
  wt="$WT_BASE/${PROJECT_NAME}-${tid}"
  out="$STATE_DIR/last-run-${PROJECT_NAME}-${tid}.out"
  : > "$out"

  # Fresh worktree off the up-to-date target. Reuse an existing ab/<id> branch
  # (resumed/blocked task) instead of recreating it.
  git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
  git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1
  if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$PROJECT_DIR" worktree add "$wt" "$branch" >/dev/null 2>>"$out"
  else
    git -C "$PROJECT_DIR" worktree add "$wt" -b "$branch" "$MERGE_TARGET" >/dev/null 2>>"$out"
  fi
  if [[ ! -d "$wt" ]]; then
    log "ERROR — could not create worktree for $tid (see $out); skipping"
    continue
  fi
  link_runtime "$wt"

  # AB task files are typically UNTRACKED, so a fresh worktree won't contain the
  # task markdown — copy it in so /ab-work-on-it can actually read the task.
  mkdir -p "$wt/backlog/queue"
  [[ -f "${SEL_FILE[$i]}" && ! -e "$wt/backlog/queue/$(basename "${SEL_FILE[$i]}")" ]] && \
    cp "${SEL_FILE[$i]}" "$wt/backlog/queue/" 2>/dev/null

  DISPATCH="You have been dispatched to work EXACTLY ONE pre-approved task: ${tid}.
You are in worktree: ${wt} on branch: ${branch}. Work ONLY that task. Do NOT pick a
different task. If ${tid} is already done or invalid, do nothing and end the run."

  # Run the agent headless inside its worktree.
  ( cd "$wt" && claude -p "/ab-work-on-it \"$tid\"" \
      --dangerously-skip-permissions \
      --append-system-prompt "${AGENT_PROTOCOL}

${DISPATCH}" \
      --output-format text >> "$out" 2>&1 ) &
  pid=$!
  # Per-agent watchdog.
  ( sleep "$AGENT_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) &

  A_ID+=("$tid"); A_WT+=("$wt"); A_BRANCH+=("$branch"); A_PID+=("$pid"); A_OUT+=("$out")
  log "  ↪ launched $tid (pid $pid) → $wt"
done

# --- Wait for every agent ----------------------------------------------------
typeset -a A_EXIT
for i in {1..${#A_PID}}; do
  wait "${A_PID[$i]}"; A_EXIT+=("$?")
done
# Reap watchdogs.
for j in $(jobs -p 2>/dev/null); do kill "$j" 2>/dev/null; done
log "BATCH agents finished — exits: ${A_EXIT[*]}"

# --- SERIAL merge: integrate each successful branch one at a time ------------
MERGED=(); SKIPPED=(); CONFLICTED=()
for i in {1..${#A_ID}}; do
  tid="${A_ID[$i]}"; branch="${A_BRANCH[$i]}"; wt="${A_WT[$i]}"; ex="${A_EXIT[$i]}"

  # Did the agent raise a hard block this run? (file appeared that wasn't there before)
  blk="$BLOCKED_DIR/${tid}.md"
  is_new_block=0
  [[ -f "$blk" ]] && ! grep -qx "$blk" <<< "$BEFORE" && is_new_block=1

  # Commits on the branch beyond the target?
  ahead="$(git -C "$PROJECT_DIR" rev-list --count "origin/$MERGE_TARGET..$branch" 2>/dev/null || echo 0)"

  if (( is_new_block )); then
    log "  ⛔ $tid blocked — leaving branch $branch for resume, removing worktree"
    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
    SKIPPED+=("$tid(blocked)")
    continue
  fi

  if (( ex == 143 )); then
    log "  ⏱ $tid timed out (${AGENT_TIMEOUT}s)"
    notify "CFW AB ⏱ $PROJECT_NAME" "$tid timed out after $((AGENT_TIMEOUT/60))m — branch $branch kept"
    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
    SKIPPED+=("$tid(timeout)")
    continue
  fi

  if (( ahead == 0 )); then
    log "  ∅ $tid produced no commits (agent exit $ex) — discarding branch+worktree"
    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
    git -C "$PROJECT_DIR" branch -D "$branch" >/dev/null 2>&1
    SKIPPED+=("$tid(empty)")
    continue
  fi

  # Don't merge a crashed agent's commits onto the integration branch.
  if (( ex != 0 )); then
    log "  ✗ $tid agent exited $ex with commits — NOT merging; keeping branch $branch for review"
    notify "🚧 $PROJECT_NAME failed: $tid" "Agent exited $ex — work kept on $branch, not merged"
    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
    [[ -f "${SEL_FILE[$i]}" ]] && perl -0pi -e 's/^status:.*$/status: coding_done/m' "${SEL_FILE[$i]}" 2>/dev/null
    SKIPPED+=("$tid(failed:$ex)")
    continue
  fi

  # Honor the agent's own EVIDENCE self-report: if it couldn't fully evidence the
  # acceptance criteria it sets status:coding_done — that needs a human, don't auto-merge.
  wt_task="$(ls "$wt"/backlog/queue/*"${tid}"*.md 2>/dev/null | head -1)"
  agent_status="$(grep -m1 '^status:' "$wt_task" 2>/dev/null | sed 's/status:[[:space:]]*//; s/["'\'' ]//g')"
  if [[ "$agent_status" == "coding_done" || "$agent_status" == "needs_review" ]]; then
    log "  🔎 $tid agent flagged '$agent_status' (acceptance not fully evidenced) — NOT auto-merging; branch $branch kept"
    notify "🔎 $PROJECT_NAME review: $tid" "Built but agent flagged '$agent_status' — not merged, kept on $branch"
    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
    [[ -f "${SEL_FILE[$i]}" ]] && perl -0pi -e 's/^status:.*$/status: coding_done/m' "${SEL_FILE[$i]}" 2>/dev/null
    SKIPPED+=("$tid(review)")
    continue
  fi

  # Tier 4: strip never-commit junk the agent may have leaked onto the branch
  # (node_modules symlink, .env, build dirs) BEFORE it can ride a merge to origin.
  guard_forbidden "$tid" "$branch"

  tfile="${SEL_FILE[$i]}"
  # Merge ab/<id> → target in the dedicated detached merge worktree. Refresh first
  # so each merge sees the prior ones (sequential integration).
  git -C "$MERGE_WT" fetch origin "$MERGE_TARGET" >/dev/null 2>&1
  git -C "$MERGE_WT" reset --hard "origin/$MERGE_TARGET" >/dev/null 2>&1

  merged_ok=0; conflicted=0
  if git -C "$MERGE_WT" merge --no-ff "$branch" -m "Merge $tid (ab-scheduler parallel batch)" >/dev/null 2>&1; then
    merged_ok=1
  else
    git -C "$MERGE_WT" merge --abort >/dev/null 2>&1
    # Tier 3: a first-pass conflict is often just batch-ordering. Rebase on the
    # fresh target and retry the merge ONCE before bothering a human.
    if [[ "$(rebase_retry "$tid" "$branch")" == "ok" ]]; then
      git -C "$MERGE_WT" reset --hard "origin/$MERGE_TARGET" >/dev/null 2>&1
      if git -C "$MERGE_WT" merge --no-ff "$branch" -m "Merge $tid (ab-scheduler, auto-rebased)" >/dev/null 2>&1; then
        merged_ok=1
        log "  ♻️ $tid auto-rebased on $MERGE_TARGET — conflict resolved without a human"
      else
        git -C "$MERGE_WT" merge --abort >/dev/null 2>&1
        conflicted=1
      fi
    else
      conflicted=1
    fi
  fi

  if (( merged_ok )); then
    if git -C "$MERGE_WT" push origin "HEAD:$MERGE_TARGET" >/dev/null 2>&1; then
      log "  ✅ $tid merged → $MERGE_TARGET and pushed"
      on_merged "$branch" "$wt" "$tfile"
      MERGED+=("$tid")
    else
      log "  ⚠️ $tid merged locally but PUSH failed — branch kept for retry"
      git -C "$MERGE_WT" reset --hard "origin/$MERGE_TARGET" >/dev/null 2>&1
      notify "🚧 $PROJECT_NAME push failed: $tid" "Couldn't push to $MERGE_TARGET — likely needs a manual pull/push"
      CONFLICTED+=("$tid(push)")
    fi
  elif (( conflicted )); then
    log "  ⚔️ $tid CONFLICTS with $MERGE_TARGET (even after auto-rebase) — blocking for a human"
    cat > "$BLOCKED_DIR/${tid}.md" <<EOF
---
task-id: "$tid"
blocked-at: "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
needs: decision
severity: hard
answer: ""
---

## What's blocked
\`$tid\` built successfully on branch \`$branch\` but **genuinely conflicts** with
\`$MERGE_TARGET\` — the scheduler already tried auto-rebasing it and the conflict remained.

## Why
This branch and something already on \`$MERGE_TARGET\` edited the same lines. A clean
auto-merge isn't possible, so a human needs to resolve it.

## How to unblock
- **Action needed:** resolve the merge by hand.
- **Commands:**
  \`\`\`
  git -C "$PROJECT_DIR" worktree add /tmp/$tid "$branch" && cd /tmp/$tid
  git rebase origin/$MERGE_TARGET     # resolve conflicts, then:
  git push origin HEAD:$MERGE_TARGET
  \`\`\`
- Then delete this note and \`git branch -D $branch\`, or fill \`answer:\` with "resolved"
  once you've pushed so \`watch\` archives the task.
- **Branch with the work:** \`$branch\` (the built commits are safe there).
EOF
    notify "🚧 $PROJECT_NAME conflict: $tid" "Real conflict with $MERGE_TARGET (rebase didn't help) — manual merge" "$(open_target "$BLOCKED_DIR/${tid}.md")"
    # Flip the queue task OFF 'ready' so it isn't re-picked+rebuilt every batch.
    [[ -f "$tfile" ]] && perl -0pi -e 's/^status:.*$/status: blocked/m' "$tfile" 2>/dev/null
    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1
    CONFLICTED+=("$tid")
  fi
done

log "BATCH DONE — merged:[${MERGED[*]}] skipped:[${SKIPPED[*]}] conflicts:[${CONFLICTED[*]}]"

# --- Tier 2: standing status digest (low-noise observability) ----------------
ready_n=0; review_n=0; blocked_n=0
for f in "$PROJECT_DIR"/backlog/queue/*.md; do
  [[ -e "$f" ]] || continue
  s="$(grep -m1 '^status:' "$f" | sed 's/status:[[:space:]]*//; s/["'\'' ]//g')"
  case "$s" in
    "$READY_STATUS") (( ready_n++ )) ;;
    coding_done|needs_review) (( review_n++ )) ;;
    blocked) (( blocked_n++ )) ;;
  esac
done
open_blocks="$(ls -1 "$BLOCKED_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')"
{
  print -r -- "# AB Scheduler status — $PROJECT_NAME"
  print -r -- "_updated $(date '+%Y-%m-%d %H:%M:%S')_"
  print -r -- ""
  print -r -- "## Last batch"
  print -r -- "- merged:    ${MERGED[*]:-—}"
  print -r -- "- parked:    ${SKIPPED[*]:-—}"
  print -r -- "- conflicts: ${CONFLICTED[*]:-—}"
  print -r -- ""
  print -r -- "## Standing queue"
  print -r -- "- ready (will run next): $ready_n"
  print -r -- "- awaiting review (coding_done): $review_n"
  print -r -- "- blocked: $blocked_n   ·   open blocked notes: $open_blocks"
} > "$STATE_DIR/STATUS.md"

# Ping only on good news (work shipped); blocks/failures already self-notify.
if (( ${#MERGED} > 0 )); then
  notify "✅ $PROJECT_NAME shipped ${#MERGED}" "→ $MERGE_TARGET: ${MERGED[*]}  ·  $review_n awaiting review"
fi

# --- Detect NEW blocked files and ping with the one-line summary -------------
AFTER="$(ls -1 "$BLOCKED_DIR"/*.md 2>/dev/null | sort)"
NEW="$(comm -13 <(print -r -- "$BEFORE") <(print -r -- "$AFTER"))"
if [[ -n "$NEW" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    TID="$(basename "$f" .md)"
    SUMMARY="$(grep -A1 '## What.s blocked' "$f" 2>/dev/null | tail -1 | cut -c1-120)"
    log "BLOCKED — $TID :: $SUMMARY"
    notify "🚧 $PROJECT_NAME blocked: $TID" "${SUMMARY:-Click to open the blocked note}" "$(open_target "$f")"
  done <<< "$NEW"
fi

# Regenerate the repo-root BLOCKED.md (covers all repos; self-clears when empty)
"$SCRIPT_DIR/ab-blocked-write-root.sh" >/dev/null 2>&1

log "END"
exit 0
