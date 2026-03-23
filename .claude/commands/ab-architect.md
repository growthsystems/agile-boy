# ab-architect

Design detailed implementation plans like a software architect.

**Invokes:** Oracle agent (`model: "opus"`)

## Usage

```
/ab-architect "Task Name"        # Architect by name
/ab-architect "01-AUTH"          # Architect by TaskId
/ab-architect --auto             # Auto-select highest priority
```

## When to Use

**Use this command when:**

- Task has 5+ story points (medium to complex)
- Requirements are clear but implementation approach needs design
- Need to understand existing patterns before coding
- Want to create detailed technical plan before execution

**Skip for trivial tasks:**

- 1-2 story points (just use `/ab-work-on-it`)
- Simple bug fixes

## Workflow

### Step 1: Invoke Oracle (Opus)

```typescript
Task tool:
  subagent_type: "oracle"
  model: "opus"
  prompt: "Design implementation plan for task: $ARGUMENTS"
```

### Step 2: Find Task (MC-First)

**MC is the single source of truth. Use MCP tools first, local files as fallback.**

**Priority order:**

1. By name/ID: MCP `get_task({ taskId: ID })` or `list_tasks({ search: "name" })`
2. `--auto`: MCP `get_pending_tasks({ projectName: "{{PROJECT_SLUG}}" })`
3. FALLBACK (MC unreachable): Search local `backlog/queue/`

**Auto-selection criteria:**

- Priority: high > normal > low
- Unblocked (no items in `blocked-by`)
- Lower story points if tie

### Step 3: Pre-Architecture Checks

1. Read the task spec from MC `description` field (fallback: local file at `filePath`)
2. Verify task has clear acceptance criteria
3. Check dependencies exist
4. Ensure git is clean: `git status`

### Step 4: Move to WIP

```
backlog/queue/[TaskId] - Name.md → backlog/wip/[TaskId] - Name.md
```

### Step 5: Update Frontmatter (MANDATORY)

```yaml
status: architecture
started: 2026-01-07T12:00:00Z
assignee: claude-architect
progress: 0%
```

### Step 6: Update Last Activity

```markdown
**Last Activity** (timestamp): Starting architectural design. Researching existing patterns.
```

### Step 7: Codebase Research (CRITICAL)

**Use Explore agent with Claude Opus (model: "opus") to understand:**

1. Existing similar features
2. Code patterns and conventions
3. API design patterns
4. Component architecture
5. Database schema patterns
6. Test patterns

**IMPORTANT: When spawning the Explore agent, use:**

```typescript
Task tool with:
  subagent_type: "Explore"
  model: "opus"
  prompt: "Research codebase patterns for [task]..."
```

**Document findings in task file:**

```markdown
## Architecture Research

### Existing Patterns Found

- Similar feature: [file:line]
- API pattern: [file:line]
- Component structure: [file:line]

### Conventions to Follow

- [Convention 1]
- [Convention 2]
```

### Step 8: Create Implementation Plan

**Location:** `backlog/attachments/[TaskId]-name/implementation-plan.md`

**Structure:**

````markdown
# Implementation Plan: [TaskId] - Task Name

## Architecture Overview

High-level design approach and key decisions.

## Component Breakdown

### 1. [Component/Module Name]

**Purpose:** What it does
**Location:** Where it goes (file path)
**Dependencies:** What it needs
**Exports:** What it provides

## Database Changes (if applicable)

### Schema Changes

```sql
-- New tables or columns
```

### Migrations

- Migration file needed: Yes/No
- Rollback strategy: [strategy]

## API Design (if applicable)

### New Endpoints

```
POST   /api/resource        - Create
GET    /api/resource/:id    - Read
PATCH  /api/resource/:id    - Update
DELETE /api/resource/:id    - Delete
```

## Testing Strategy

### Unit Tests

- [ ] Core logic tests
- [ ] API handler tests
- [ ] Utility tests

### Integration Tests

- [ ] End-to-end API tests
- [ ] Database operations

## Security Considerations

- [ ] Authentication required: Yes/No
- [ ] Authorization rules: [describe]
- [ ] Input validation: [describe]

## Implementation Order

### Phase 1: Foundation

1. [ ] Database schema/migrations
2. [ ] Shared types and schemas
3. [ ] Core logic

### Phase 2: Core Features

4. [ ] Business logic implementation
5. [ ] Input validation
6. [ ] Error handling

### Phase 3: Polish

7. [ ] Tests
8. [ ] Error states
9. [ ] Documentation

## Files to Create/Modify

### New Files

- `src/feature.ts`

### Modified Files

- `src/index.ts` (add route)

## Estimated Breakdown (Story Points)

- Core logic: X points
- Tests: Y points
- Total: Z points ✓ (matches task estimate)
````

### Step 9: Update Task File Progress

Update progress in task file:

```yaml
progress: 100%
status: ready
```

```markdown
**Last Activity** (timestamp): Architecture complete. Implementation plan finalized.
```

### Step 10: Move Back to Queue

```
backlog/wip/[TaskId] - Name.md → backlog/queue/[TaskId] - Name.md
```

Update frontmatter:

```yaml
status: backlog
assignee: ""
```

### Step 11: Update MASTER-TASK-LIST.md

Move from In Progress back to Queue.

Add note: `📐 Architecture ready`

### Step 12: AUTO-CONTINUE to Implementation

**In autonomous mode (default), immediately chain to work-on-it:**

```
✅ Architecture Complete: [TaskId] - Task Name
📐 Implementation plan: backlog/attachments/[TaskId]-name/implementation-plan.md
📊 Story Points: X

🔄 AUTO-CONTINUING: /ab-work-on-it "[TaskId]"
```

**Only pause for user confirmation if:**

- Story points >= 13 (very large task)
- Open questions remain unresolved
- `--pause` flag was passed

## Output

```
🏗️ Architecture Started: [TaskId] - Task Name
📊 Story Points: X
🔍 Researching codebase patterns...

[Research findings...]

📐 Creating implementation plan...
✅ Plan created: backlog/attachments/[TaskId]-name/implementation-plan.md

🎯 Ready for: /ab-work-on-it [TaskId]
```

## Non-Negotiables

- ❌ NEVER skip codebase research
- ❌ NEVER create plan without understanding existing patterns
- ❌ NEVER leave open questions unresolved
- ❌ NEVER skip updating Last Activity
- ✅ ALWAYS use Explore agent for research
- ✅ ALWAYS create implementation plan file
- ✅ ALWAYS update MASTER-TASK-LIST.md
- ✅ ALWAYS move back to queue when done
- ✅ ALWAYS validate story point breakdown matches estimate

## Integration with Other Commands

**FULLY AUTOMATED Workflow:**

```
┌─────────────────────────────────────────────────────────────┐
│                    PRODUCT OWNER                            │
│                                                             │
│  /ab-create-task "feature description"                      │
│           │                                                 │
│           ▼                                                 │
│  (Task created in backlog/queue/)                          │
│           │                                                 │
│  /ab-architect [TaskId]  ←── YOU ARE HERE                  │
└───────────┬─────────────────────────────────────────────────┘
            │
            ▼ (AUTO-CONTINUES)
┌─────────────────────────────────────────────────────────────┐
│                    AUTONOMOUS EXECUTION                     │
│                                                             │
│  /ab-work-on-it [TaskId]                                    │
│     ├─ Phase 0-2: Setup (worktree for 8+ pts)               │
│     ├─ Phase 3: Implementation loop                          │
│     │     └─ Auto-commit every 20 files                     │
│     ├─ Phase 4: Quality gates                               │
│     ├─ Phase 5: Browser validation                          │
│     └─ Phase 6: Mark coding_done                            │
│           │                                                 │
│           ▼ (AUTO-TRIGGERED)                               │
│                                                             │
│  /ab-test-and-complete [TaskId]                             │
│     ├─ Phase 1: Quality gates                               │
│     ├─ Phase 2: Criteria validation                         │
│     ├─ Phase 3: Browser validation                          │
│     ├─ Phase 4: Merge (8+ pts)                              │
│     ├─ Phase 5: Cleanup worktree                            │
│     └─ Phase 6: Archive to done/                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```
