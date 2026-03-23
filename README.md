# Agile Boy

> Drop-in AI project management for Claude Code. From idea to shipped code with zero context switching.

---

## The Problem

You have an idea. You open Claude Code. You describe what you want. Claude builds something — but there's no structure. No estimation. No tests. No validation. No history of what was built or why.

**Agile Boy fixes this.** It drops a complete PM system into any project — backlog, estimation, architecture planning, TDD execution, and auto-validation — all orchestrated by AI agents.

---

## What Agile Boy Does

Install it in any project. Get four slash commands that automate the full development lifecycle:

```
/ab-create-task "Add user authentication"
    ↓ Oracle (Opus) asks clarifying questions, estimates story points, creates task
    ↓ Auto-triggers architecture planning for complex tasks (5+ points)
/ab-architect
    ↓ Oracle researches your codebase, creates detailed implementation plan
    ↓ Auto-triggers implementation
/ab-work-on-it
    ↓ Crafter (Sonnet) implements with TDD, runs quality gates, commits
    ↓ Auto-triggers validation
/ab-test-and-complete
    ↓ Validates acceptance criteria, runs browser tests, archives task
    ✅ Done.
```

**One command in. Shipped code out.** The full chain runs automatically.

---

## Why You Need This

- **Ideas become tasks instantly.** No Jira. No Linear. Just describe what you want.
- **Smart estimation.** Oracle uses the Fibonacci scale (1-13 story points) and asks clarifying questions first.
- **Architecture before code.** Complex tasks (5+ points) get detailed implementation plans before a single line is written.
- **TDD by default.** Crafter writes tests first, then implementation. Every time.
- **Quality gates block completion.** Build, test, lint must all pass. No silent failures.
- **Git worktrees for big tasks.** 8+ point tasks get isolated branches automatically.
- **Works with any language.** Configure your build/test/lint commands and go.

---

## Quick Start

### Install

```bash
git clone https://github.com/growthsystems/agile-boy.git
./agile-boy/install.sh /path/to/your/project "MyApp"
```

### Custom build commands

```bash
BUILD_CMD="cargo build" TEST_CMD="cargo test" LINT_CMD="cargo clippy" \
  ./agile-boy/install.sh /path/to/project "MyRustApp"
```

Defaults: `pnpm build`, `pnpm test`, `pnpm lint`

### What gets installed

```
your-project/
├── .claude/
│   ├── agents/
│   │   ├── oracle.md          # PM agent (Opus — plans and estimates)
│   │   └── crafter.md         # Dev agent (Sonnet — implements and tests)
│   └── commands/
│       ├── ab-create-task.md   # Turn ideas into tasks
│       ├── ab-architect.md     # Design implementation plans
│       ├── ab-work-on-it.md    # Execute with TDD + quality gates
│       └── ab-test-and-complete.md  # Validate and archive
└── backlog/
    ├── MASTER-TASK-LIST.md     # Single source of truth
    ├── raw/                    # Drop ideas here
    ├── queue/                  # Ready to work on
    ├── wip/                    # In progress
    ├── done/                   # Completed (monthly archives)
    ├── epics/                  # Large initiatives
    ├── attachments/            # Implementation plans
    └── templates/              # Task, bug, and epic templates
```

---

## Commands

### `/ab-create-task`

Turn an idea into a structured backlog task.

```bash
/ab-create-task "Add user authentication with OAuth"
/ab-create-task --bug "Login fails on mobile Safari"
```

**What Oracle does:**
1. Asks 2-3 clarifying questions (scope, edge cases, preferences)
2. Estimates story points (1-13 Fibonacci scale)
3. Creates task with acceptance criteria and definition of done
4. For 5+ point tasks, auto-continues to `/ab-architect`

### `/ab-architect`

Design a detailed implementation plan. Runs automatically for complex tasks.

```bash
/ab-architect 03-AUTH
```

**What Oracle does:**
1. Researches your existing codebase for patterns and conventions
2. Creates a phased implementation plan (Foundation → Core → Polish)
3. Lists every file to create or modify
4. Defines testing strategy and security considerations
5. Saves plan to `backlog/attachments/[TaskId]-name/implementation-plan.md`

### `/ab-work-on-it`

Execute a task with TDD and quality gates.

```bash
/ab-work-on-it 03-AUTH         # Specific task
/ab-work-on-it --auto          # Highest priority from queue
/ab-work-on-it --resume        # Resume last WIP task
/ab-work-on-it --batch         # Process ALL queued tasks
```

**What Crafter does:**
1. Creates git worktree for 8+ point tasks (isolated branch)
2. Writes tests first (TDD)
3. Implements to pass tests
4. Runs quality gates (build → test → lint)
5. Auto-commits every 20 files or after each phase
6. Auto-continues to `/ab-test-and-complete`

### `/ab-test-and-complete`

Validate and archive. Runs automatically after implementation.

**What happens:**
1. Validates every acceptance criterion
2. Runs browser tests if applicable
3. Merges worktree branch (for 8+ point tasks)
4. Archives task to `backlog/done/`
5. Updates master task list

---

## The Agents

### Oracle (claude-opus-4-6) — Your PM

- Asks before acting (clarifying questions)
- Estimates before building (story points)
- Plans before coding (architecture for 5+ point tasks)
- Never creates files before establishing a Task ID

### Crafter (claude-sonnet-4-6) — Your Developer

- Tests before implementing (TDD)
- Runs quality gates before marking done
- Uses worktrees for complex work (8+ points)
- Never marks a task done with failing tests

### Why Two Models?

| Agent | Model | Why |
|-------|-------|-----|
| Oracle | Opus (slower, smarter) | Planning and estimation need deep reasoning |
| Crafter | Sonnet (faster, focused) | Implementation needs speed and precision |
| Validation | Opus (thorough) | Final check needs comprehensive review |

---

## Story Points & Complexity

| Points | Complexity | Duration | Worktree? |
|--------|-----------|----------|-----------|
| 1 | Trivial | < 1 hour | No |
| 2 | Simple | 1-2 hours | No |
| 3 | Small | 2-4 hours | No |
| 5 | Medium | 4-8 hours | No |
| 8 | Large | 1-2 days | Yes |
| 13 | Very Large | 2-5 days | Yes |

Tasks scored 8+ automatically get isolated git worktrees at `~/.claude-worktrees/{project}-{feature}/`.

---

## Task ID Format

`MM-XXXX` — month + descriptive mnemonic.

Examples: `03-AUTH`, `03-DASH`, `03-API-V2`

---

## Quality Gates

Every task must pass all gates before completion:

```bash
pnpm build    # (or your BUILD_CMD)
pnpm test     # (or your TEST_CMD)
pnpm lint     # (or your LINT_CMD)
```

**No exceptions. No silent fallbacks.** If a gate fails, the task stays in WIP until it's fixed.

---

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Git repository
- Any package manager (pnpm, npm, yarn, cargo, pip, etc.)

---

## Philosophy

- **Right model for the job** — Opus plans, Sonnet ships
- **Auto-chain by default** — create → architect → implement → validate without interruption
- **Fail loud** — quality gates block completion, never silent fallbacks
- **Worktrees for complex work** — isolated branches for 8+ point tasks
- **Portable** — works with any language or framework

---

## Part of the Growth Systems Toolkit

Agile Boy is one piece of a larger AI-powered development toolkit:

| Tool | Purpose | Repo |
|------|---------|------|
| **Scout** | Per-project knowledge management | [growthsystems/scout](https://github.com/growthsystems/scout) |
| **Atlas** | Cross-project knowledge hub & service registry | [growthsystems/atlas](https://github.com/growthsystems/atlas) |
| **Agile Boy** | AI-powered project management for Claude Code | [growthsystems/agile-boy](https://github.com/growthsystems/agile-boy) |
| **Claude Journal** | Automated daily dev journal from sessions + git | [growthsystems/claude-journal](https://github.com/growthsystems/claude-journal) |

---

## License

MIT
