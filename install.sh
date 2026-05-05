#!/usr/bin/env bash
# Codex PR Review Installer
# Installs the Claude Code skill into ~/.claude/skills/

set -e

SKILL_NAME="codex-pr-review"
SKILL_DIR="$HOME/.claude/skills/$SKILL_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Codex PR Review Installer"
echo "=========================================="
echo

# Check if Claude Code skills directory exists
if [ ! -d "$HOME/.claude/skills" ]; then
    echo "Creating Claude Code skills directory..."
    mkdir -p "$HOME/.claude/skills"
fi

# Check if skill already exists
if [ -d "$SKILL_DIR" ]; then
    echo "Skill already exists at $SKILL_DIR"
    read -p "Overwrite existing installation? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    echo "Removing existing installation..."
    rm -rf "$SKILL_DIR"
fi

# Copy skill files
echo "Installing skill files to $SKILL_DIR..."
mkdir -p "$SKILL_DIR/scripts"
cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/"
cp "$SCRIPT_DIR/scripts/review.sh" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-output-schema.json" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/chunk-diff.awk" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-chunk-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-synthesis-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-verification-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-followup-context.md" "$SKILL_DIR/scripts/"

# Make scripts executable
chmod +x "$SKILL_DIR/scripts/review.sh"

# Check prerequisites
echo
echo "Checking prerequisites..."

MISSING=()

if ! command -v codex &>/dev/null; then
    MISSING+=("codex CLI")
fi

if ! command -v gh &>/dev/null; then
    MISSING+=("gh CLI")
fi

if ! command -v jq &>/dev/null; then
    MISSING+=("jq")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo
    echo "=========================================="
    echo "Missing prerequisites:"
    echo "=========================================="
    for m in "${MISSING[@]}"; do
        case "$m" in
            "codex CLI")
                echo "  - codex CLI: npm install -g @openai/codex"
                ;;
            "gh CLI")
                echo "  - gh CLI: brew install gh"
                ;;
            "jq")
                echo "  - jq: brew install jq"
                ;;
        esac
    done
    echo
else
    echo "  All prerequisites found."
fi

# Check codex OAuth
echo
echo "Checking Codex authentication..."
if command -v codex &>/dev/null; then
    if codex login status &>/dev/null 2>&1; then
        echo "  Codex OAuth is configured."
    else
        echo
        echo "=========================================="
        echo "Codex OAuth not configured"
        echo "=========================================="
        echo
        echo "codex exec (headless mode) requires OAuth, not an API key."
        echo "Run: codex login"
        echo
    fi
fi

# Success message
echo
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo
echo "The $SKILL_NAME skill is now installed."
echo "Restart Claude Code, then use it with:"
echo
echo "  /codex-pr-review                  # Auto-detect PR for current branch"
echo "  /codex-pr-review 123              # Review PR #123"
echo "  /codex-pr-review --threshold 0.6  # Lower confidence threshold"
echo
echo "Files installed to: $SKILL_DIR"
echo
