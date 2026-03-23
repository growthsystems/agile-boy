# ab-work-on-it

**FULLY AUTOMATED** task execution with browser validation and incremental commits.

**Invokes:** Crafter agent (`model: "sonnet"`)

## Usage

```
/ab-work-on-it "Task Name"       # Start by name
/ab-work-on-it "01-AUTH"         # Start by TaskId
/ab-work-on-it --resume          # Resume last WIP task
/ab-work-on-it --auto            # Auto-select highest priority (DEFAULT)
/ab-work-on-it --batch           # Process ALL high+normal priority tasks
/ab-work-on-it --skip-architect  # Force start without plan (not recommended)
```

## Invoke Crafter (Sonnet)

```typescript
Task tool:
  subagent_type: "crafter"
  model: "sonnet"
  prompt: "Execute task: $ARGUMENTS. Follow all phases in ab-work-on-it."
```

## Autonomous Mode (DEFAULT)

When running without flags or with `--auto`/`--batch`:

1. **NO human intervention required** until completion
2. Auto-selects highest priority unblocked task
3. Auto-commits every 20 files OR after each phase
4. Auto-validates with browser automation (if applicable)
5. Auto-calls `/ab-test-and-complete` after coding_done
6. Auto-chains to next task if `--batch`

---

## PHASE 0: Task Selection (MC-First)

**MC is the single source of truth for tasks. Use MCP tools first, local files as fallback.**

### Priority Order

```
1. --resume → MCP: list_tasks({ status: "in_progress", projectName: "{{PROJECT_SLUG}}" })
2. By name/ID → MCP: get_task({ taskId: ID }) or list_tasks({ search: "name" })
3. --auto → MCP: get_pending_tasks({ projectName: "{{PROJECT_SLUG}}" })
4. FALLBACK (MC unreachable) → Search local backlog/queue/
```

### Auto-Selection Criteria

- Priority: `high` > `normal` > `low`
- Unblocked (no items in `blocked-by`)
- Smallest story points if tie

---

## PHASE 0.5: Architecture Check (AUTO)

**BEFORE starting work, check if architecture exists:**

```bash
# Architecture required for 5+ points
if [ "$STORY_POINTS" -ge 5 ] && [ ! -f "$PLAN_PATH" ]; then
    echo "⚠️ Architecture required for ${STORY_POINTS}pt task"
    echo "🔄 AUTO-CALLING: /ab-architect \"$TASK_ID\""
    # Spawn architect agent with Opus model
    # After architecture completes, it will auto-continue back here
fi
```

**Model specification:**

- **Architect uses Claude Opus (model: "opus") for all subagents**
- After architecture completes, resumes work-on-it automatically

---

## PHASE 1: Pre-Flight Checks

### 1.1 Dev Server Health Check (if applicable)

Check that dev servers are running before attempting browser validation.

### 1.2 Git Status Check

```bash
# Must be clean to start (unless resuming)
if [ "$(git status --porcelain | wc -l)" -gt 0 ]; then
    echo "⚠️ Uncommitted changes detected"
    git stash push -m "auto-stash-before-task-$(date +%s)"
fi
```

### 1.3 Architecture Validation

- 5+ points: Implementation plan MUST exist (auto-created if missing)
- 1-4 points: Plan optional, lightweight pattern search
- 8+ points: Worktree required

---

## PHASE 2: Environment Setup

### 2.1 Worktree Creation (8+ points ONLY)

```bash
TASK_SLUG=$(echo "$TASK_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
WORKTREE_PATH="$HOME/.claude-worktrees/{{PROJECT_SLUG}}-$TASK_SLUG"

git checkout main && git pull origin main
git worktree add "$WORKTREE_PATH" -b "feature/$TASK_SLUG"

cd "$WORKTREE_PATH"
{{BUILD_CMD}}  # install dependencies
```

### 2.2 Update MC Status (PRIMARY)

**MC PATCH is the primary status update. Use MCP tools or API.**

```bash
# MCP (preferred): update_task({ taskId: "$MC_TASK_ID", status: "in_progress", assignedAgentName: "claude" })
# API fallback:
PATCH_PAYLOAD="{\"status\": \"in_progress\", \"assignedAgentName\": \"claude\", \"startedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

if [ "$STORY_POINTS" -ge 8 ]; then
  PATCH_PAYLOAD="$PATCH_PAYLOAD, \"gitBranch\": \"feature/$TASK_SLUG\", \"worktreePath\": \"$WORKTREE_PATH\""
fi

PATCH_PAYLOAD="$PATCH_PAYLOAD}"

curl -s -X PATCH "http://localhost:4000/api/tasks/$MC_TASK_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MC_API_TOKEN:-}" \
  -d "$PATCH_PAYLOAD"
echo "📡 MC updated: in_progress"
```

**Fields sent on work start:**
- `startedAt`: ISO timestamp of when work began (always sent)
- `gitBranch`: Feature branch name (8+ point tasks only)
- `worktreePath`: Absolute path to the worktree (8+ point tasks only)

### 2.3 Move Local File to WIP (OPTIONAL — if local file exists)

```bash
if [ -f "backlog/queue/$TASK_FILE" ]; then
  mv "backlog/queue/$TASK_FILE" "backlog/wip/$TASK_FILE"
fi
```

### 2.4 Update MASTER-TASK-LIST.md (OPTIONAL)

Move task from Queue -> In Progress table (convenience view only).

---

## PHASE 2.6: Query Past Task Knowledge (RECOMMENDED)

**Before starting implementation, search MC for similar past tasks to learn from their knowledge trails.**

```bash
# Search for similar tasks using MCP tool or API
# MCP: search_task_knowledge({ query: "$TASK_KEYWORDS", projectName: "{{PROJECT_SLUG}}" })
# API: GET http://localhost:4000/api/tasks/knowledge/search?q=$KEYWORDS&projectId=$PROJECT_ID

# If results found, append what you learned to current task:
# MCP: append_task_knowledge({
#   taskId: "$MC_TASK_ID",
#   entries: [{ type: "context", content: "Learned from past tasks: ...", agent: "crafter" }]
# })
```

**What to look for:**
- Gotchas from similar past tasks (avoid repeating mistakes)
- Patterns that worked well (reuse approaches)
- Decisions and their rationale (stay consistent)

---

## PHASE 3: Implementation Loop (AUTOMATED)

**MODEL SPECIFICATIONS BY AGENT TYPE:**

| Agent Type     | Model    | Rationale                                               |
| -------------- | -------- | ------------------------------------------------------- |
| **Explore**    | `sonnet` | Pattern research, codebase exploration (cost-effective) |
| **sherlock**   | `sonnet` | Documentation research, API lookups (cost-effective)    |
| **artisan**    | `sonnet` | Code implementation (balanced quality/cost)             |
| **bugsy**      | `opus`   | Bug fixing, debugging (needs best reasoning)            |
| **validation** | `sonnet` | Code validation checks (balanced)                       |

**When spawning agents:**

```typescript
// For exploration/research
Task: { subagent_type: "Explore", model: "sonnet", prompt: "..." }

// For implementation
Task: { subagent_type: "artisan", model: "sonnet", prompt: "..." }

// For bug fixes (use Opus!)
Task: { subagent_type: "bugsy", model: "opus", prompt: "..." }
```

### 3.1 Read Task Spec & Implementation Plan

**Read the task spec from MC first (source of truth):**

```
1. MCP: get_task({ taskId: "$MC_TASK_ID" })
2. Parse spec from the `description` field (markdown)
3. Extract AC from the `## Acceptance Criteria` section
4. FALLBACK: If `description` is empty (backward compat for old tasks),
   read from local file at `filePath`
```

```
If implementation plan exists:
  → Parse phases from implementation-plan.md
  → Create TodoWrite checklist from phases
  → Track progress per phase

If no plan (small tasks):
  → Parse acceptance criteria from MC description field
  → Create TodoWrite from criteria
```

### 3.2 Development Cycle (Per Phase)

```
FOR EACH phase in implementation_plan:

  1. Mark phase as in_progress (TodoWrite)

  2. Read relevant files:
     - Pattern search for similar code
     - Understand existing conventions

  3. Implement:
     - Create/modify files per plan
     - Follow plan's component/module structure

  4. After EACH component:
     - Run quality gates: {{BUILD_CMD}} && {{LINT_CMD}}
     - If FAIL: Fix immediately, retry
     - If PASS: Continue

  5. Incremental Commit Check:
     UNCOMMITTED=$(git status --porcelain | wc -l)
     if [ $UNCOMMITTED -ge 20 ]; then
         git add -A
         git commit -m "wip($TASK_ID): Phase N progress - $UNCOMMITTED files"
     fi

  6. Update task file:
     - progress: {percentage}%
     - Last Activity: {timestamp} - Completed Phase N

  7. Mark phase as completed (TodoWrite)

  8. PATCH Task Knowledge to MC (MANDATORY per phase):
     # MCP: append_task_knowledge({
     #   taskId: "$MC_TASK_ID",
     #   entries: [
     #     { type: "iteration", content: "Phase N complete: {what was done, key decisions}", agent: "crafter" },
     #     { type: "gotcha", content: "{any surprises or issues hit}", agent: "crafter" },  // if applicable
     #     { type: "decision", content: "{why X was chosen over Y}", agent: "crafter" },      // if applicable
     #   ]
     # })
     # API fallback:
     curl -s -X PATCH "http://localhost:4000/api/tasks/$MC_TASK_ID" \
       -H "Content-Type: application/json" \
       -d "{\"knowledge\": [{\"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"type\": \"iteration\", \"content\": \"Phase N: {summary}\", \"agent\": \"crafter\"}]}"

END FOR
```

### 3.3 Phase Completion Commit

```bash
git add -A
git commit -m "feat($TASK_ID): Complete Phase N - {phase_name}

- {list key changes}
- Progress: {X}%

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## PHASE 4: Quality Gates (AUTO)

### 4.1 Run All Checks

```bash
{{BUILD_CMD}} || { echo "❌ Build failed"; exit 1; }
{{TEST_CMD}}  || { echo "❌ Tests failed"; exit 1; }
{{LINT_CMD}}  || { echo "❌ Lint failed"; exit 1; }
```

### 4.2 Gate Results

```
IF any gate fails:
  → Fix immediately
  → Re-run gates
  → Loop until pass

IF all gates pass:
  → Continue to Completion
```

---

## PHASE 5: Browser Validation (if applicable)

### 5.1 Browser Automation Validation

**Use Claude-in-Chrome MCP tools to validate each acceptance criterion if UI exists:**

```typescript
// For EACH acceptance criterion in task file:
1. tabs_context_mcp → Get or create tab
2. navigate → Go to relevant page
3. computer(screenshot) → Capture current state
4. read_page → Verify elements exist
5. find → Locate specific UI elements
6. Verify against expected behavior
```

### 5.2 Validation Decision

```
IF any browser check fails:
  → status: needs_fixes
  → Document what failed
  → Fix and retry Phase 5

IF all browser checks pass:
  → Continue to Completion
```

---

## PHASE 6: Task Completion (AUTO)

### 6.1 Update Status

```yaml
status: coding_done
progress: 100%
```

### 6.2 Final Commit

```bash
git add -A
git commit -m "feat($TASK_ID): Complete implementation

✅ All acceptance criteria met
✅ All quality gates passed

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

### 6.3 AUTO-TRIGGER: /ab-test-and-complete

```
🔄 AUTO-EXECUTING: /ab-test-and-complete "$TASK_ID"

This will:
1. Re-validate all acceptance criteria
2. Run quality gates again
3. Merge feature branch (if 8+ points)
4. Archive task to done/
5. Update MASTER-TASK-LIST.md
```

---

## PHASE 7: Worktree Cleanup (8+ points only)

### 7.1 Merge to Main

```bash
cd "$WORKTREE_PATH"
git fetch origin main
git rebase origin/main

# Switch to main repo and merge
git checkout main && git pull origin main
git merge --no-ff "feature/$TASK_SLUG" -m "Merge $TASK_ID: $TASK_NAME"
```

### 7.2 Cleanup Worktree

```bash
git worktree remove "$WORKTREE_PATH"
git branch -d "feature/$TASK_SLUG"
```

---

## PHASE 8: Chain to Next Task (Batch Mode)

```
IF --batch flag was set:
  → Check backlog/queue/ for remaining high/normal tasks
  → IF tasks remain:
      → AUTO-START next highest priority task
  → IF no tasks:
      → Report batch completion summary
```

---

## Incremental Commit Rules

| Trigger               | Action                         |
| --------------------- | ------------------------------ |
| 20+ uncommitted files | Auto-commit with WIP message   |
| Phase complete        | Commit with phase summary      |
| Quality gates pass    | Commit before next phase       |
| Task complete         | Final commit with full summary |

---

## Non-Negotiables

### NEVER

- ❌ Skip architecture for 5+ point tasks
- ❌ Leave 20+ uncommitted files
- ❌ Mark done without all criteria met
- ❌ Merge without quality gates passing
- ❌ Skip worktree for 8+ point tasks

### ALWAYS

- ✅ Auto-commit at 20 file threshold
- ✅ Commit after each phase
- ✅ Auto-trigger /ab-test-and-complete
- ✅ Use worktree for 8+ point tasks
- ✅ Update progress in real-time
- ✅ Notify MC on major status changes (in_progress, coding_done)
- ✅ PATCH task knowledge to MC after EVERY phase (iterations, gotchas, decisions)
- ✅ Query past task knowledge before starting implementation

---

## Error Recovery

### Build/Lint Failure

```
1. Identify error location
2. Fix immediately
3. Re-run quality gates
4. Continue if pass
```

### Worktree Conflict

```
1. git fetch origin main
2. git rebase origin/main
3. Resolve conflicts
4. Continue rebase
5. Re-run quality gates
```
