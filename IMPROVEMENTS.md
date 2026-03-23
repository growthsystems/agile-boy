# Agile Boy - Improvement Recommendations

Based on installing Agile Boy across 13 projects of varying types (TypeScript apps, Python automation, video production workspaces, marketing brands, content brands), the following improvements would make the system more versatile and robust.

---

## 1. Project Type Detection and Profiles

**Problem:** Every non-code project requires manual `BUILD_CMD="echo 'no build'"` overrides. The install script assumes all projects are code projects with build/test/lint pipelines.

**Recommendation:**
- Add a `--type` flag to install.sh: `--type=code|production|marketing|content`
- Auto-detect project type by checking for package.json, pyproject.toml, Cargo.toml, etc.
- Define profiles that set sensible defaults per type:
  - `code-node`: BUILD=`npm run build`, TEST=`npm test`, LINT=`npm run lint`
  - `code-pnpm`: BUILD=`pnpm build`, TEST=`pnpm test`, LINT=`pnpm lint`
  - `code-python`: BUILD=`echo 'no build'`, TEST=`python -m pytest`, LINT=`ruff check .`
  - `production`: All gates disabled, task templates for video orders/deliverables
  - `marketing`: All gates disabled, task templates for content briefs/campaigns
  - `content`: All gates disabled, task templates for articles/social posts

```bash
# Current (verbose, error-prone)
BUILD_CMD="echo 'no build'" TEST_CMD="echo 'no tests'" LINT_CMD="echo 'no lint'" ./install.sh /path "Name"

# Proposed (clean)
./install.sh /path "Name" --type=marketing
./install.sh /path "Name"  # auto-detects from package.json/pyproject.toml
```

---

## 2. Skip Quality Gates for Non-Code Projects

**Problem:** ab-test-and-complete.md and ab-work-on-it.md run build/test/lint gates even when they are `echo 'no build'`. This is noisy and confusing for non-code projects.

**Recommendation:**
- Add a `SKIP_QUALITY_GATES` flag or detect when commands are echo stubs
- In templates, wrap quality gate sections in conditionals:
  ```
  {{#if QUALITY_GATES_ENABLED}}
  Run quality gates: {{BUILD_CMD}} && {{TEST_CMD}} && {{LINT_CMD}}
  {{/if}}
  ```
- Alternatively, generate different template variants per project type

---

## 3. Template Variations for Different Task Types

**Problem:** The task template (task-template.md) is code-centric with fields like "Files to Modify", "Quality Gates", etc. This does not map well to:
- Video production orders (deliverables, timelines, talent, locations)
- Marketing campaigns (audience, channels, budget, KPIs)
- Content briefs (topic, word count, target keywords, publication date)

**Recommendation:**
- Add template variants in `backlog/templates/`:
  - `task-template.md` (code - current default)
  - `order-template.md` (production - deliverables, deadlines, assets)
  - `brief-template.md` (content/marketing - audience, goals, channels)
  - `bug-template.md` (code - current, keep as-is)
- The install script selects which templates to copy based on project type
- ab-create-task.md should reference the appropriate template for the project type

---

## 4. Python Project Support

**Problem:** No first-class support for Python projects. During this rollout, outbound needed manual `python -m pytest` configuration.

**Recommendation:**
- Detect `pyproject.toml`, `setup.py`, or `requirements.txt` during install
- Default Python profile:
  - BUILD: `echo 'no build'` (or `pip install -e .` for packages)
  - TEST: `python -m pytest`
  - LINT: `ruff check .` or `black --check .` or `flake8`
- Detect which linter is configured (ruff in pyproject.toml, .flake8, etc.)

---

## 5. MC Task Registration Should Be Configurable

**Problem:** The command templates contain hardcoded `curl` calls to `http://localhost:4000/api/tasks` for MC (Mission Control) integration. Projects not using MC get errors or confusing output.

**Recommendation:**
- Add a `MC_ENABLED` placeholder (true/false) or `MC_BASE_URL` placeholder
- Wrap MC integration in conditionals so it is opt-in
- Support configuration via:
  - Environment variable: `MC_URL=http://localhost:4000`
  - Config file: `.claude/agile-boy.config` or `backlog/config.yml`
  - Install flag: `--mc-url=http://localhost:4000` or `--no-mc`

```bash
# With MC
./install.sh /path "Name" --mc-url=http://localhost:4000

# Without MC
./install.sh /path "Name" --no-mc
```

---

## 6. Custom Task ID Formats Per Project

**Problem:** All projects use the same task ID format. Some projects may want prefixes (e.g., `VID-001` for video, `MKT-001` for marketing, `BUG-001` for bugs).

**Recommendation:**
- Add a `TASK_PREFIX` placeholder: `{{TASK_PREFIX}}-001`
- Configure during install: `--task-prefix=VID`
- Store in a config file so ab-create-task can read it at runtime

---

## 7. Package Manager Detection for Node.js Projects

**Problem:** The default is `pnpm` but some projects use `npm`. During this rollout, pocket-agent and others needed manual `npm run build` overrides.

**Recommendation:**
- Auto-detect package manager by checking for lock files:
  - `pnpm-lock.yaml` -> pnpm
  - `package-lock.json` -> npm
  - `yarn.lock` -> yarn
  - `bun.lockb` -> bun
- Fall back to `pnpm` if none found (current behavior)

---

## 8. Idempotent Installation (Re-run Safety)

**Problem:** Running install.sh on a project that already has Agile Boy overwrites existing files including MASTER-TASK-LIST.md which may contain real task data.

**Recommendation:**
- Check for existing installation and prompt before overwriting
- Add a `--force` flag to skip the prompt
- Never overwrite MASTER-TASK-LIST.md if it has content beyond the template
- Add an `--update-commands-only` flag for upgrading command files without touching backlog

```bash
# Safe upgrade - only updates commands and agents, preserves backlog
./install.sh /path "Name" --update-commands-only

# Full reinstall (destructive)
./install.sh /path "Name" --force
```

---

## 9. Uninstall / Cleanup Command

**Problem:** No way to remove Agile Boy from a project cleanly.

**Recommendation:**
- Add `./uninstall.sh /path/to/project` that removes:
  - `.claude/commands/ab-*.md`
  - `.claude/agents/oracle.md` and `crafter.md` (only if unchanged from template)
  - Optionally `backlog/` (with confirmation, since it contains data)

---

## 10. Version Tracking

**Problem:** No way to know which version of Agile Boy is installed in a project, making upgrades difficult.

**Recommendation:**
- Write a `.claude/agile-boy-version` file during install with the version/date
- The install script can check this to know if an upgrade is needed
- Commands can display the version for debugging

---

## Summary of Projects Installed (2026-03-01)

### Fresh Installations (8)
| Project | Path | Type | Build/Test/Lint |
|---------|------|------|-----------------|
| Creative Studio | /Users/vasanth/MarketingMr/creative-studio | Production | echo stubs |
| Pocket Agent | /Users/vasanth/Code/command-center/pocket-agent | Node.js | npm |
| Pocket Agent CLI | /Users/vasanth/Code/command-center/pocket-agent-cli | Node.js | npm |
| Floe | /Users/vasanth/Code/video-hub/floe | Node.js | npm |
| Client Collab | /Users/vasanth/Code/client-collab | Node.js | npm |
| Action Builder | /Users/vasanth/Code/cfw/action-builder | TypeScript | echo stubs |
| Heritage House | /Users/vasanth/MarketingMr/passiveincome/heritage-house-a | Marketing | echo stubs |
| Mr Growth Guide | /Users/vasanth/MarketingMr/passiveincome/velocity-labs-a/Mr Growth Guide | Content | echo stubs |

### Partial Fixes (5) - Commands Added
| Project | Path | Type | Build/Test/Lint |
|---------|------|------|-----------------|
| cfw-social | /Users/vasanth/Code/cfw/cfw-social | Node.js | pnpm |
| cfw-website | /Users/vasanth/Code/cfw/cfw-website | Node.js | pnpm |
| learnloop | /Users/vasanth/Code/learnloop | Node.js | pnpm |
| cfw-ghl | /Users/vasanth/Code/cfw/cfw-ghl | Node.js | pnpm |
| outbound | /Users/vasanth/MarketingMr/outbound | Python | pytest |
