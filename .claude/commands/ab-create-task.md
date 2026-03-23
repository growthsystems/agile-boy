# ab-create-task

Transform raw ideas into actionable backlog tasks.

**Invokes:** Oracle agent (`model: "opus"`)

## Usage

```
/ab-create-task                           # Process files in raw/
/ab-create-task "Add user authentication" # Create from conversation
/ab-create-task --bug "Login fails"       # Create bug report
/ab-create-task "feature" --no-continue   # Create only, don't auto-start
```

## Workflow

### Step 1: Invoke Oracle (Opus)

Spawn Oracle agent with:

```typescript
Task tool:
  subagent_type: "oracle"
  model: "opus"
  prompt: "Process this idea into a backlog task: $ARGUMENTS"
```

### Step 2: Generate TaskId (MANDATORY FIRST)

- Format: `MM-XXXX` (month + 2-4 char mnemonic)
- Example: `01-AUTH` for January Authentication task
- **ANNOUNCE THE TASK ID** before proceeding

### Step 3: Source Detection

**From Raw Files:**

1. Scan `backlog/raw/` for `.md` files
2. Extract requirements
3. Ask clarifying questions

**From Conversation:**

1. Extract requirements from `$ARGUMENTS`
2. Ask clarifying questions

### Step 4: Estimate Story Points

| Points | Complexity            | Worktree? |
| ------ | --------------------- | --------- |
| 1      | Trivial (< 1hr)       | No        |
| 2      | Simple (1-2hr)        | No        |
| 3      | Small (2-4hr)         | No        |
| 5      | Medium (4-8hr)        | No        |
| 8      | Large (1-2 days)      | Yes       |
| 13     | Very Large (2-5 days) | Yes       |

### Step 5: Register in Mission Control (PRIMARY — Source of Truth)

**MC is the single source of truth. The `description` field holds the full task spec (story + AC + technical notes + DoD as markdown).**

**Build the `description` field as markdown:**

```markdown
## Story

> As a [user type], I want [goal] so that [benefit].

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Technical Notes

- Affected areas: ...
- Pattern to follow: ...

## Definition of Done

- [ ] Code complete
- [ ] Tests passing
- [ ] Types/lint clean
- [ ] Build passes
```

**POST to Mission Control:**

```bash
MC_RESPONSE=$(curl -s -X POST http://localhost:4000/api/tasks \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MC_API_TOKEN:-}" \
  -d "{
    \"title\": \"[$TASK_ID] $TASK_NAME\",
    \"projectName\": \"{{PROJECT_SLUG}}\",
    \"status\": \"registered\",
    \"priority\": $PRIORITY_NUMBER,
    \"storyPoints\": $STORY_POINTS,
    \"summary\": \"$TASK_SUMMARY\",
    \"description\": \"$FULL_DESCRIPTION_MARKDOWN\",
    \"localTaskId\": \"$TASK_ID\",
    \"epic\": \"$EPIC\"
  }")
MC_TASK_ID=$(echo "$MC_RESPONSE" | jq -r '.data.id // .id // empty')
echo "📡 Registered in Mission Control (mcTaskId: $MC_TASK_ID)"
```

**Priority mapping:** high=2, normal=5, low=8

**The `description` field contains the full task spec as markdown** — story, acceptance criteria, technical notes, and definition of done. This is the canonical source; no local file needed.

**Fields sent later (via PATCH in ab-work-on-it):**
- `gitBranch`, `worktreePath`, `startedAt` — sent when work begins on 8+ point tasks

**Graceful degradation:** If MC is unreachable, fall back to creating a local .md file (Step 6).

### Step 6: Create Local Task File (OPTIONAL — backup only)

**Local .md files are optional backups, not the source of truth.**

**Location:** `backlog/queue/[TaskId] - YYYY-MM-DD - Task Name.md`

**Minimal frontmatter (just pointers to MC):**

```yaml
task-id: "01-AUTH"
mcTaskId: "$MC_TASK_ID"
status: backlog
priority: high|normal|low
story-points: 3
```

Body can be minimal — canonical data lives in MC's `description` field.

### Step 6.5: Complex Tasks (8+ points)

Create implementation plan:

1. Folder: `backlog/attachments/[TaskId]-name/`
2. File: `implementation-plan.md`

### Step 7: Update MASTER-TASK-LIST.md (OPTIONAL)

Add to Queue table. This is a convenience view — MC is the source of truth.

### Step 7.5: Initialize Task Knowledge (if MC registered)

**Append initial knowledge context to the MC task so future agents have the creation story.**

```bash
if [ -n "$MC_TASK_ID" ]; then
  curl -s -X PATCH "http://localhost:4000/api/tasks/$MC_TASK_ID" \
    -H "Content-Type: application/json" \
    -d "{
      \"knowledge\": [{
        \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"type\": \"context\",
        \"content\": \"Task created from: $SOURCE_TYPE. Brief: $TASK_SUMMARY. Acceptance criteria: $CRITERIA_COUNT items. Story points: $STORY_POINTS.\",
        \"agent\": \"oracle\"
      }]
    }"
fi
```

**What to capture in the initial knowledge entry:**
- How the task was created (from raw file, conversation, bug report)
- The core brief/requirement in 1-2 sentences
- Number of acceptance criteria
- Story point estimate and rationale
- Any similar past tasks found (if `search_task_knowledge` was used)

### Step 8: Archive Raw File

```
backlog/raw/idea.md → backlog/raw/processed/idea.md
```

## Clarifying Questions

Always ask:

1. **User value**: What problem does this solve?
2. **Scope**: What's in/out of scope?
3. **Priority**: high/normal/low?
4. **Acceptance**: How will we know it's done?

### Step 9: AUTO-CONTINUE (DEFAULT)

**By default, automatically start work on the task:**

```
✅ Task Created: [TaskId] - Task Name
📊 Story Points: X
📁 Location: backlog/queue/

🔄 AUTO-CONTINUING: /ab-work-on-it "[TaskId]"
   └─> Will auto-call /ab-architect if 5+ points and no plan exists
   └─> Uses Claude Opus for architecture, Sonnet for implementation
```

**To STOP auto-continuation, use `--no-continue` flag:**

```bash
/ab-create-task "feature" --no-continue
```

**Then it will just report:**

```
✅ Task Created: [TaskId] - Task Name

Next steps:
- /ab-work-on-it [TaskId]  # Smart: auto-architects if needed
- /ab-work-on-it --auto    # Picks highest priority task
```

## Output

```
✅ Task Created: [TaskId] - Task Name
📁 Location: backlog/queue/
📊 Story Points: X
📋 MASTER-TASK-LIST.md updated

🎯 Next: /ab-architect [TaskId]  # For 5+ pts
   or: /ab-work-on-it [TaskId]   # For 1-4 pts
```

## Non-Negotiables

- ❌ NEVER create files before generating TaskId
- ❌ NEVER skip clarifying questions
- ✅ ALWAYS announce TaskId first
- ✅ ALWAYS POST to MC with full `description` (MC is the source of truth)
- ✅ ALWAYS include testable acceptance criteria in the `description` field
- ✅ Local .md file and MASTER-TASK-LIST.md are OPTIONAL backups

---

## Fully Automated Workflow

```
┌─────────────────────────────────────────────────────────────┐
│                    PRODUCT OWNER ACTIONS                    │
│                                                             │
│  /ab-create-task "description"                              │
│           │                                                 │
│           ▼                                                 │
│  (Task created → Auto-architects → Auto-implements)        │
│                                                             │
│  ════════════════════════════════════════════════════      │
│                                                             │
│  /ab-work-on-it --batch                                     │
│           │                                                 │
│           ▼                                                 │
│  (Processes ALL high+normal priority tasks automatically)  │
│  (Browser validates each → Commits → Archives → Next)      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Minimal human intervention required!**
