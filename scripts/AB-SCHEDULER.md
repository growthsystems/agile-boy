# AB Scheduler

Unattended worker that drains a repo's `backlog/queue/` for you — every 30 minutes per
registered repo it picks the top approved tasks, builds them **in parallel** (each in its own git
worktree), and merges the green ones into **`develop`**. It pings you only when genuinely stuck.
**Multi-project, registry-driven, parallel fan-out.**

> **Scope (the hybrid):** this loop is for **CODE** projects. Content/brand work (PassiveFlow,
> Communities, Vasanth HQ) lives on **Paperclip**, the org-wide control plane. Don't route content here.

## What it does

```
launchd  (one job per repo, fires every 30 min, staggered across repos)
  ├─ :00 / :30  com.absched.cfw-social   →  ab-scheduler.sh /…/cfw-social
  └─ :15 / :45  com.absched.cfw-website   →  ab-scheduler.sh /…/cfw-website

each tick →  pick top AB_FANOUT (default 3) approved tasks
          →  fan out: one headless `claude -p "/ab-work-on-it <id>"` per task,
             each in its OWN worktree ~/.claude-worktrees/<repo>-<TASK-ID> on branch ab/<TASK-ID>
          →  agents ONLY implement + test + commit to their own branch (no merge, no switch)
          →  wrapper then SERIALLY merges each green branch → develop, pushes, archives the task
```

The registry of repos is **`~/.gsai/ab-scheduler/projects.conf`** (`name|absolute-dir|minute`),
managed by `register` / `unregister`. Each repo gets its own job + `backlog/{queue,blocked,.scheduler}`.

> **Parallel since 2026-06-18.** Old one-task-at-a-time worker is kept at
> `scripts/ab-scheduler.sh.serial-bak`. The merge target moved from `main` → **`develop`** so
> autonomous work no longer lands on the live site.

### How a single run works (the parallel batch)

1. **Select** the top `AB_FANOUT` `status: ready`, unblocked tasks (priority, then FIFO).
2. **Fan out** — each task gets a fresh worktree off the up-to-date `develop`, on branch
   `ab/<TASK-ID>`. `node_modules` + `.env*` are symlinked in (no triple `pnpm install`). Each
   agent runs headless with a 25-min watchdog (`AB_AGENT_TIMEOUT`), and is told (isolation
   contract) to **only implement + validate + commit to its own branch** — never merge/switch/push/archive.
3. **Serial integrate** — after all agents finish, the wrapper merges each branch into `develop`
   one at a time, in a dedicated merge worktree (`~/.claude-worktrees/<repo>-ab-develop`),
   refreshing from origin before each merge so later merges see earlier ones, then `git push`.
4. **Per-task outcome:**
   | Outcome | What happens |
   |---|---|
   | ✅ merged | task file set `status: complete`, moved to `backlog/archive/`, branch + worktree removed |
   | ⛔ hard block | agent wrote `blocked/<id>.md` → branch kept for resume, worktree removed |
   | ⏱ timeout | 25-min watchdog killed it → branch kept, you're notified |
   | ∅ empty | agent produced no commits → branch + worktree discarded |
   | ⚔️ conflict | built OK but conflicts with a branch already merged this batch → **blocked note written** with exact manual-merge commands, branch + worktree kept |
5. **Notify + BLOCKED.md** — any new blocker fires a notification and refreshes the aggregate
   `/Users/vasanth/Code/cfw/BLOCKED.md`.

### Add / remove a repo

```bash
scripts/ab-scheduler-ctl.sh register <name> <project-dir>
scripts/ab-scheduler-ctl.sh list
scripts/ab-scheduler-ctl.sh unregister <name>      # removes job; leaves backlog/ intact
```
`register` creates the backlog dirs, writes + loads a launchd job, and picks a free minute.
**Two prerequisites for the loop to actually do work in a repo:**
- The repo needs the `ab-*` command suite in `.claude/commands/` (`ab-work-on-it`,
  `ab-test-and-complete`, `ab-architect`) — without it the run SKIPs. `register` warns you.
- The **merge target branch must exist** (default `develop`). If the repo has no `develop`,
  either create it (`git branch develop`) or override per-repo (see knobs) — otherwise the run
  FATALs with "cannot create merge worktree on develop".
- ⚠️ `register` currently generates an **hourly** plist (single minute); the two CFW jobs were
  hand-upgraded to twice-hourly (`:00/:30`, `:15/:45`). Edit the new plist's
  `StartCalendarInterval` if you want 30-min cadence, then `ctl off && ctl on`.

### Approval gate

Only `status: ready` tasks run. Everything else in `queue/` is ignored (`backlog`, `blocked`,
`coding_done`, etc.). The batch takes the top `AB_FANOUT` by priority (high > normal > low),
oldest-first tie-break. No `ready` task ⇒ silent no-op (`SKIP`).

```bash
scripts/ab-scheduler-ctl.sh ready                # what's eligible, per repo
scripts/ab-scheduler-ctl.sh approve 05-PLANNAME  # flip to status: ready
```

### Evidence & honesty contract (every agent, every run)

Injected into every agent's system prompt: each acceptance criterion must be backed by a
**reproducible artifact** (`file:line` / a committed test / real command output) or be marked
**PARTIAL/UNMET** — prose is not evidence. Under-claim, never overstate; a placeholder reported as
"done" is the worst failure. Any criterion not MET ⇒ task stays `coding_done` (not complete) for
human review. (Added after an audit caught a task overstating completion.)

## When does it notify?

Only on a **new hard block / conflict** or an agent **timeout** — never on success or `SKIP`. No
blocks ⇒ no banners (expected). Install `terminal-notifier` (done) for clickable banners that open
the blocked note (Obsidian for cfw-vault repos, default app otherwise). Test: `ctl test-notify`.

Four surfaces: the banner; aggregate root `/Users/vasanth/Code/cfw/BLOCKED.md` (all repos,
self-clears); the SessionStart hook (prints blockers when you open the folder); the Stop hook
(injects a *new* mid-session block once). Hooks wired in `.claude/settings.local.json`.

## Unblocking — three ways, same result

A blocked (or conflicted) task leaves `ready` and waits. **No auto-watching of your answer — you trigger the resume:**

1. **Reply in chat** — Claude runs `unblock`.
2. **Command** — `scripts/ab-scheduler-ctl.sh unblock <TASK-ID> "<answer>"`.
3. **Edit the note** — fill its `answer:` field, then `scripts/ab-scheduler-ctl.sh watch` resumes it.

For **conflict** blockers the note contains the exact `cd <merge-worktree> && git merge … && git push`
commands — resolve by hand, then delete the note (or set `answer: resolved`). The task's `ab/<id>`
branch is preserved with all its work.

**Fully hands-off:** `/loop 5m scripts/ab-scheduler-ctl.sh watch` in an open session.

## Control

```bash
scripts/ab-scheduler-ctl.sh status                  # which jobs are loaded
scripts/ab-scheduler-ctl.sh list                    # which repos are registered
scripts/ab-scheduler-ctl.sh on | off                # enable / disable all jobs
scripts/ab-scheduler-ctl.sh ready                   # what runs next, per repo
scripts/ab-scheduler-ctl.sh approve <id>            # status: ready
scripts/ab-scheduler-ctl.sh unhold  <id>            # back to status: backlog
scripts/ab-scheduler-ctl.sh blockers                # open blockers, all repos
scripts/ab-scheduler-ctl.sh unblock <id> "<answer>" # clear a blocker + requeue
scripts/ab-scheduler-ctl.sh watch                   # auto-unblock filled answers (loop-safe)
scripts/ab-scheduler-ctl.sh register <name> <dir>   # add a code repo
scripts/ab-scheduler-ctl.sh unregister <name>       # remove a repo
scripts/ab-scheduler-ctl.sh run-now [name|all]      # trigger immediately (⚠️ real work)
scripts/ab-scheduler-ctl.sh logs    [name|all]      # tail run history
scripts/ab-scheduler-ctl.sh test-notify             # sample notification
```

## Files

| Path | Role |
|---|---|
| `~/.gsai/ab-scheduler/projects.conf` | the registry (`name\|dir\|minute`) |
| `scripts/ab-scheduler.sh` | parallel batch worker (launchd calls it) |
| `scripts/ab-scheduler.sh.serial-bak` | the previous one-task-at-a-time worker (backup) |
| `scripts/ab-scheduler-ctl.sh` | control panel — every verb above |
| `scripts/ab-blocked-{write-root,surface,stop-hook}.sh` | BLOCKED.md + the two hooks (registry-driven) |
| `~/Library/LaunchAgents/com.absched.<name>.plist` | one timer per repo (every 30 min) |
| `~/.claude-worktrees/<repo>-<TASK-ID>` | per-task agent worktree (transient) |
| `~/.claude-worktrees/<repo>-ab-develop` | the dedicated serial-merge worktree |
| `<repo>/backlog/{queue,blocked,archive,.scheduler}` | tasks / blockers / done / run state |

## Knobs

Set via env or per-repo `<repo>/backlog/.scheduler/config` (sourced as zsh):

| Knob | Default | Meaning |
|---|---|---|
| `AB_FANOUT` | `3` | tasks worked in parallel per tick |
| `AB_MERGE_TARGET` | `develop` | branch the wrapper merges into (set to the repo's default branch if it has no `develop`) |
| `AB_READY_STATUS` | `ready` | task status that counts as approved |
| `AB_AGENT_TIMEOUT` | `1500` | per-agent wall-clock cap, seconds (25 min) |

- **Cadence:** edit `StartCalendarInterval` in the plist, then `ctl off && ctl on`.
- **Autonomy:** agents run `--dangerously-skip-permissions` in isolated worktrees; the wrapper
  merges to `develop` only — review `develop → main` promotion yourself, never auto-promote.

## Safety

- **One batch at a time per repo** (lockfile) — no overlapping ticks.
- **Per-agent 25-min watchdog**; a hung agent is killed, its branch kept.
- **Agents never merge** — only the wrapper integrates, serially, so there are no index/HEAD races.
- **Conflicts never auto-resolve** — they become blocked notes for a human.
- **Blast radius is `develop`**, not the live site. (cfw/ is not a git repo; scripts live in
  `/Users/vasanth/Code/cfw/scripts/` — optional future relocation to `~/.gsai/ab-scheduler/`.)
