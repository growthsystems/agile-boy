#!/usr/bin/env bash
# agile-boy installer
# Usage: ./install.sh /path/to/project "ProjectName"
# Example: ./install.sh ~/Code/myapp "MyApp"

set -e

AGILE_BOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Args ---
TARGET_DIR="${1:-}"
PROJECT_NAME="${2:-}"

if [ -z "$TARGET_DIR" ] || [ -z "$PROJECT_NAME" ]; then
    echo "Usage: ./install.sh /path/to/project \"ProjectName\""
    echo "Example: ./install.sh ~/Code/myapp \"MyApp\""
    exit 1
fi

# Resolve absolute path
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")"

# Derive slug: lowercase, spaces→hyphens, strip special chars
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')

# Default quality gate commands (configurable)
BUILD_CMD="${BUILD_CMD:-pnpm build}"
TEST_CMD="${TEST_CMD:-pnpm test}"
LINT_CMD="${LINT_CMD:-pnpm lint}"

echo "🚀 Installing agile-boy into: $TARGET_DIR"
echo "   Project: $PROJECT_NAME"
echo "   Slug:    $PROJECT_SLUG"
echo "   Build:   $BUILD_CMD"
echo "   Test:    $TEST_CMD"
echo "   Lint:    $LINT_CMD"
echo ""

# --- Create directory structure ---
echo "📁 Creating directories..."

mkdir -p "$TARGET_DIR/.claude/agents"
mkdir -p "$TARGET_DIR/.claude/commands"
mkdir -p "$TARGET_DIR/backlog/raw/processed"
mkdir -p "$TARGET_DIR/backlog/queue"
mkdir -p "$TARGET_DIR/backlog/wip"
mkdir -p "$TARGET_DIR/backlog/done"
mkdir -p "$TARGET_DIR/backlog/epics"
mkdir -p "$TARGET_DIR/backlog/attachments"
mkdir -p "$TARGET_DIR/backlog/templates"

# Create .gitkeep files for empty dirs
touch "$TARGET_DIR/backlog/raw/processed/.gitkeep"
touch "$TARGET_DIR/backlog/queue/.gitkeep"
touch "$TARGET_DIR/backlog/wip/.gitkeep"
touch "$TARGET_DIR/backlog/done/.gitkeep"
touch "$TARGET_DIR/backlog/epics/.gitkeep"
touch "$TARGET_DIR/backlog/attachments/.gitkeep"

# --- Copy agent files ---
echo "🤖 Installing agents..."

cp "$AGILE_BOY_DIR/.claude/agents/oracle.md"  "$TARGET_DIR/.claude/agents/oracle.md"
cp "$AGILE_BOY_DIR/.claude/agents/crafter.md" "$TARGET_DIR/.claude/agents/crafter.md"

# --- Copy command files ---
echo "⚡ Installing commands..."

cp "$AGILE_BOY_DIR/.claude/commands/ab-create-task.md"       "$TARGET_DIR/.claude/commands/ab-create-task.md"
cp "$AGILE_BOY_DIR/.claude/commands/ab-architect.md"         "$TARGET_DIR/.claude/commands/ab-architect.md"
cp "$AGILE_BOY_DIR/.claude/commands/ab-work-on-it.md"        "$TARGET_DIR/.claude/commands/ab-work-on-it.md"
cp "$AGILE_BOY_DIR/.claude/commands/ab-test-and-complete.md" "$TARGET_DIR/.claude/commands/ab-test-and-complete.md"

# --- Copy backlog files ---
echo "📋 Installing backlog..."

cp "$AGILE_BOY_DIR/backlog/README.md"            "$TARGET_DIR/backlog/README.md"
cp "$AGILE_BOY_DIR/backlog/MASTER-TASK-LIST.md"  "$TARGET_DIR/backlog/MASTER-TASK-LIST.md"
cp "$AGILE_BOY_DIR/backlog/templates/task-template.md"  "$TARGET_DIR/backlog/templates/task-template.md"
cp "$AGILE_BOY_DIR/backlog/templates/bug-template.md"   "$TARGET_DIR/backlog/templates/bug-template.md"
cp "$AGILE_BOY_DIR/backlog/templates/epic-template.md"  "$TARGET_DIR/backlog/templates/epic-template.md"

# --- Substitute placeholders ---
echo "🔧 Configuring for $PROJECT_NAME..."

# Files to process
FILES=(
    "$TARGET_DIR/.claude/agents/oracle.md"
    "$TARGET_DIR/.claude/agents/crafter.md"
    "$TARGET_DIR/.claude/commands/ab-create-task.md"
    "$TARGET_DIR/.claude/commands/ab-architect.md"
    "$TARGET_DIR/.claude/commands/ab-work-on-it.md"
    "$TARGET_DIR/.claude/commands/ab-test-and-complete.md"
    "$TARGET_DIR/backlog/README.md"
    "$TARGET_DIR/backlog/MASTER-TASK-LIST.md"
    "$TARGET_DIR/backlog/templates/task-template.md"
    "$TARGET_DIR/backlog/templates/bug-template.md"
    "$TARGET_DIR/backlog/templates/epic-template.md"
)

for FILE in "${FILES[@]}"; do
    sed -i.bak \
        -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" \
        -e "s/{{PROJECT_SLUG}}/$PROJECT_SLUG/g" \
        -e "s|{{BUILD_CMD}}|$BUILD_CMD|g" \
        -e "s|{{TEST_CMD}}|$TEST_CMD|g" \
        -e "s|{{LINT_CMD}}|$LINT_CMD|g" \
        "$FILE"
    rm "${FILE}.bak"
done

# --- Done ---
echo ""
echo "✅ agile-boy installed successfully!"
echo ""
echo "📂 Structure:"
echo "   $TARGET_DIR/.claude/agents/oracle.md"
echo "   $TARGET_DIR/.claude/agents/crafter.md"
echo "   $TARGET_DIR/.claude/commands/ab-create-task.md"
echo "   $TARGET_DIR/.claude/commands/ab-architect.md"
echo "   $TARGET_DIR/.claude/commands/ab-work-on-it.md"
echo "   $TARGET_DIR/.claude/commands/ab-test-and-complete.md"
echo "   $TARGET_DIR/backlog/"
echo ""
echo "🚀 Next steps:"
echo "   1. Open $TARGET_DIR in Claude Code"
echo "   2. Ensure Mission Control is running (http://localhost:4000)"
echo "   3. Run: /ab-create-task \"Your first feature\""
echo "   4. Claude will guide you through the rest!"
echo ""
echo "📡 MC-First: Mission Control is the single source of truth for tasks."
echo "   Task specs live in MC's \`description\` field. Local .md files are optional backups."
echo ""
echo "📖 Quick reference:"
echo "   /ab-create-task \"idea\"  → Create task in MC (Oracle/Opus)"
echo "   /ab-architect [TaskId]  → Plan complex tasks (Oracle/Opus)"
echo "   /ab-work-on-it [TaskId] → Execute task (Crafter/Sonnet)"
echo "   /ab-test-and-complete   → Validate & archive (auto-triggered)"
