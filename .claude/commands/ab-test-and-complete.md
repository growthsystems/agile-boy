# ab-test-and-complete

**AUTOMATED** task validation, merge, and archive with browser verification.

**Invokes:** Validation agent (`model: "opus"`)

## Usage

```
/ab-test-and-complete                  # Validate current WIP task (AUTO from ab-work-on-it)
/ab-test-and-complete "01-AUTH"        # Validate specific task
/ab-test-and-complete --skip-browser   # Skip browser validation (not recommended)
```

## AUTO-TRIGGERED FROM /ab-work-on-it

This command is automatically called after `/ab-work-on-it` completes Phase 6.
No manual invocation needed in the normal workflow.

**MODEL SPECIFICATION:**

- **All validation work uses Claude Opus (model: "opus")**
- Final validation requires highest quality reasoning
- When spawning validation agents, specify `model: "opus"`

```typescript
Task tool:
  subagent_type: "validation"
  model: "opus"
  prompt: "Validate task completion: $ARGUMENTS"
```

---

## PHASE 0: Pre-Validation Check

### 0.1 Find Task (MC-First)

```bash
# PRIMARY: Get task from MC via MCP
# MCP: get_task({ taskId: "$MC_TASK_ID" })
# Parse spec and AC from the `description` field

# FALLBACK: Local file (if MC unreachable or description empty)
TASK_FILE=$(ls backlog/wip/*.md | grep -i "$TASK_ID" | head -1)
```

### 0.2 Incremental Commit Check (MANDATORY)

```bash
UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')

if [ "$UNCOMMITTED" -gt 0 ]; then
    git add -A
    git commit -m "chore($TASK_ID): Pre-validation commit

- $UNCOMMITTED files staged for validation
- Auto-commit from /ab-test-and-complete

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
fi
```

---

## PHASE 1: Quality Gates (MANDATORY)

### 1.1 Run All Checks

```bash
echo "🔍 Running quality gates..."

{{BUILD_CMD}} || { echo "❌ Build FAILED"; GATE_FAILED=true; }
{{TEST_CMD}}  || { echo "❌ Tests FAILED"; GATE_FAILED=true; }
{{LINT_CMD}}  || { echo "❌ Lint FAILED"; GATE_FAILED=true; }

if [ "$GATE_FAILED" = true ]; then
    echo "🚫 Quality gates failed - cannot proceed"
    exit 1
fi

echo "✅ All quality gates passed"
```

### 1.2 Gate Failure Recovery

```
IF any gate fails:
  1. Document exact error
  2. Update status: needs_fixes
  3. Fix the issue immediately
  4. Re-run quality gates
  5. Loop until all pass
```

---

## PHASE 2: Acceptance Criteria Validation

### 2.1 Parse Acceptance Criteria (MC-First)

**Read from MC `description` field (source of truth):**

```bash
# MCP: get_task({ taskId: "$MC_TASK_ID" })
# Parse the `## Acceptance Criteria` section from the `description` markdown field
# FALLBACK: If description is empty (old tasks), read from local task file
```

```markdown
## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3
```

### 2.2 Code Evidence Check

For EACH criterion, find code evidence:

```markdown
| Criterion           | Status | Evidence              |
| ------------------- | ------ | --------------------- |
| Feature works       | ✅     | `src/feature.ts:78`  |
| Error handled       | ✅     | `src/feature.ts:142`  |
| Tests pass          | ✅     | `__tests__/feature.test.ts:45` |
```

### 2.3 Criteria Validation Decision

```
IF any criterion not met:
  → status: needs_fixes
  → Document missing items
  → Return to /ab-work-on-it to fix
  → Re-validate after fix

IF all criteria have evidence:
  → Continue to Browser Validation (if applicable)
```

---

## PHASE 3: Browser Validation (if applicable)

### 3.1 Browser Automation Validation

**Use Claude-in-Chrome MCP to verify each criterion visually (for UI tasks):**

```typescript
// Step 1: Get browser context
await mcp__claude-in-chrome__tabs_context_mcp({ createIfEmpty: true });

// Step 2: For EACH acceptance criterion with a UI:
for (const criterion of acceptanceCriteria) {
    await mcp__claude-in-chrome__navigate({
        tabId: tab.id,
        url: criterion.testUrl
    });

    await mcp__claude-in-chrome__computer({ action: "screenshot", tabId: tab.id });

    // Verify result
    const page = await mcp__claude-in-chrome__read_page({ tabId: tab.id });

    if (page.includes(criterion.expectedText)) {
        criterion.status = "✅ PASSED";
    } else {
        criterion.status = "❌ FAILED";
    }
}
```

### 3.2 Validation Decision

```
IF any browser test fails:
  → status: needs_fixes
  → Document failure
  → Return to fix
  → Re-validate

IF all browser tests pass (or no UI):
  → Continue to Completion
```

---

## PHASE 4: Merge (8+ points with worktree)

### 4.1 Rebase on Main

```bash
cd "$WORKTREE_PATH"
git fetch origin main
git rebase origin/main
```

### 4.2 Post-Rebase Verification

```bash
{{BUILD_CMD}} && {{TEST_CMD}} && {{LINT_CMD}}
```

### 4.3 Merge to Main

```bash
git checkout main && git pull origin main
git merge --no-ff "feature/$TASK_SLUG" -m "Merge $TASK_ID: $TASK_NAME

✅ All acceptance criteria met
✅ All quality gates passed

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## PHASE 5: Worktree Cleanup (8+ points only)

```bash
git worktree remove "$WORKTREE_PATH" --force
git branch -d "feature/$TASK_SLUG"
echo "✅ Worktree cleaned up"
```

---

## PHASE 6: Task Completion

### 6.1 Complete Task in MC (PRIMARY)

**MC `complete_task()` is the primary completion action.**

```bash
# MCP (preferred): complete_task({ taskId: "$MC_TASK_ID" })
# Or via API:
curl -s -X PATCH "http://localhost:4000/api/tasks/$MC_TASK_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MC_API_TOKEN:-}" \
  -d "{
    \"status\": \"completed\",
    \"summary\": \"All acceptance criteria met. All quality gates passed.\",
    \"progress\": 100
  }"
echo "📡 MC updated: completed"
```

### 6.2 Final Commit (if any uncommitted)

```bash
UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')

if [ "$UNCOMMITTED" -gt 0 ]; then
    git add -A
    git commit -m "docs($TASK_ID): Task completion documentation

✅ Task marked complete

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
fi
```

### 6.3 Archive Local Task File (OPTIONAL)

```bash
# Only if local file exists
if [ -f "backlog/wip/$TASK_FILE" ]; then
  MONTH=$(date +%Y-%m)
  mkdir -p "backlog/done/$MONTH/"
  mv "backlog/wip/$TASK_FILE" "backlog/done/$MONTH/$TASK_FILE"
  echo "📁 Archived to: backlog/done/$MONTH/$TASK_FILE"
fi
```

### 6.4 Update MASTER-TASK-LIST.md (OPTIONAL)

```markdown
# Move from In Progress to Done (convenience view — MC is source of truth):
- Remove from In Progress table
- Add to Done table with completion timestamp
```

### 6.5 PATCH Final Knowledge to MC (MANDATORY)

**Before marking complete, record completion knowledge — what worked, what was learned, patterns discovered.**

```bash
if [ -n "$MC_TASK_ID" ]; then
  # MCP: append_task_knowledge({
  #   taskId: "$MC_TASK_ID",
  #   entries: [
  #     { type: "completion", content: "Completed: {summary of what was built}. Key patterns: {patterns}. Gotchas: {gotchas}.", agent: "validation" },
  #     { type: "pattern", content: "{any reusable pattern discovered}", agent: "validation" },  // if applicable
  #   ]
  # })
  curl -s -X PATCH "http://localhost:4000/api/tasks/$MC_TASK_ID" \
    -H "Content-Type: application/json" \
    -d "{\"knowledge\": [{
      \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"type\": \"completion\",
      \"content\": \"Task validated and complete. Criteria: $CRITERIA_PASSED/$CRITERIA_TOTAL passed. Gates: all passed. Key learnings: {summary}.\",
      \"agent\": \"validation\"
    }]}"
fi
```

**What to capture in completion knowledge:**
- Final summary of what was built/fixed
- Which acceptance criteria required iteration
- Any gotchas future similar tasks should know
- Patterns worth reusing
- Total time/effort vs estimate accuracy

### 6.6 (Removed — MC completion is now handled in Step 6.1 as primary action)

---

## PHASE 7: Chain to Next Task (if --batch)

```
IF batch mode active (from /ab-work-on-it --batch):

  1. Check backlog/queue/ for remaining tasks

  2. IF task found:
     → Report: "🔄 Chaining to next task: [TaskId]"
     → Execute: /ab-work-on-it "[TaskId]"

  3. IF no tasks:
     → Report batch completion summary
     → Exit batch mode
```

---

## Output Formats

### Validation Success

```
✅ TASK VALIDATED: [TaskId] - Task Name

📋 Acceptance Criteria: 5/5 passed
🔍 Quality Gates: All passed
🌐 Browser Tests: 5/5 passed (if applicable)

📁 Archived: backlog/done/YYYY-MM/[TaskId]*.md
📊 MASTER-TASK-LIST.md updated
```

### Validation Failed

```
❌ VALIDATION FAILED: [TaskId]

📋 Criteria: 4/5 passed
  - [ ] ❌ Feature not working

🔍 Gates: 1 failed
  - ❌ Lint: 2 errors

📝 Status updated to: needs_fixes
🔄 Fix and re-run: /ab-test-and-complete [TaskId]
```

---

## Non-Negotiables

### NEVER

- ❌ Mark complete if any criterion unmet
- ❌ Mark complete if any gate fails
- ❌ Archive with uncommitted changes
- ❌ Leave worktree after merge

### ALWAYS

- ✅ Run all quality gates
- ✅ Validate each criterion with evidence (parsed from MC `description` field)
- ✅ Commit before archiving
- ✅ Complete task in MC via `complete_task()` (PRIMARY — source of truth)
- ✅ PATCH completion knowledge to MC before marking complete (learnings, patterns, gotchas)
- ✅ Clean up worktree for 8+ point tasks
- ✅ Local file archive and MASTER-TASK-LIST.md are OPTIONAL

---

## Integration Flow

```
┌─────────────────────┐
│ /ab-work-on-it      │ ← Completes implementation
│   status: coding_done│
└─────────┬───────────┘
          │
          ▼ (AUTO-TRIGGERED)
┌─────────────────────┐
│ /ab-test-and-complete│ ← THIS COMMAND
│   Phase 0: Commit   │
│   Phase 1: Gates    │
│   Phase 2: Criteria │
│   Phase 3: Browser  │
│   Phase 4: Merge    │
│   Phase 5: Cleanup  │
│   Phase 6: Archive  │
└─────────┬───────────┘
          │
          ▼ (if --batch)
┌─────────────────────┐
│ /ab-work-on-it      │ ← Next task (auto-chain)
└─────────────────────┘
```
