# {{PROJECT_NAME}} Backlog

Agile task management powered by Claude AI agents.

---

## Quick Start

```bash
/ab-create-task "Your feature idea"    # Create task
/ab-work-on-it "01-AUTH"              # Start work
/ab-work-on-it --resume               # Resume last task
/ab-test-and-complete                  # Validate & complete
```

---

## Folder Structure

```
backlog/
├── MASTER-TASK-LIST.md    # Single source of truth
├── raw/                   # Drop ideas here
│   └── processed/         # After oracle processes
├── queue/                 # Ready tasks (priority in frontmatter)
├── wip/                   # Currently working on
├── done/                  # Completed
│   └── YYYY-MM/           # Monthly archives
├── epics/                 # Large initiatives
├── attachments/           # Implementation plans
└── templates/             # Task templates
```

---

## Task Lifecycle

```
raw/ ──→ queue/ ──→ wip/ ──→ done/
```

1. **Raw**: Unprocessed ideas
2. **Queue**: Refined, ready to work (priority in frontmatter)
3. **WIP**: Actively working on
4. **Done**: Completed and archived monthly

---

## Story Points

| Points | Complexity | Worktree? |
| ------ | ---------- | --------- |
| 1-3    | Small      | No        |
| 5      | Medium     | No        |
| 8-13   | Large      | Yes       |

---

## TaskId Format

`MM-XXXX` → Month + mnemonic

Examples: `01-AUTH`, `01-DASH`, `02-API`

---

## Agents

| Agent       | Model  | Role                                           |
| ----------- | ------ | ---------------------------------------------- |
| **Oracle**  | Opus   | Ideas → tasks, estimates, clarifying questions |
| **Crafter** | Sonnet | Execute tasks, TDD, quality gates              |

---

## Commands

| Command                 | Purpose               |
| ----------------------- | --------------------- |
| `/ab-create-task`       | Create task from idea |
| `/ab-architect`         | Design impl plan (5+ pts) |
| `/ab-work-on-it`        | Start/resume work     |
| `/ab-test-and-complete` | Validate & complete   |
