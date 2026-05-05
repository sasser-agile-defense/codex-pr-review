#!/usr/bin/env bash
# Codex PR Review Installer
# Installs the Claude Code skill into ~/.claude/skills/

set -e

SKILL_NAME="codex-pr-review"
SKILL_DIR="$HOME/.claude/skills/$SKILL_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# v2 install opt-in (P0..P5). Default stays "1" through P4 baking; flips to
# "2" at the end of P5 per IMPLEMENTATION_PLAN.md §4.
INSTALL_VERSION="1"

# Parse args (single optional flag for now).
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            INSTALL_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: install.sh [--version 1|2]

  --version 1   v1 install (default during transition).
  --version 2   v2 install: also copies plan.js, ast-chunk.sh, grammars/,
                .codex-pr-review.toml.example; checks for node>=18 and claude.
EOF
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

case "$INSTALL_VERSION" in
    1|2) ;;
    *) echo "--version must be 1 or 2 (got: $INSTALL_VERSION)" >&2; exit 1 ;;
esac

echo "=========================================="
echo "Codex PR Review Installer (v${INSTALL_VERSION})"
echo "=========================================="
echo

# Check if Claude Code skills directory exists
if [ ! -d "$HOME/.claude/skills" ]; then
    echo "Creating Claude Code skills directory..."
    mkdir -p "$HOME/.claude/skills"
fi

# Check if skill already exists; preserve v1 review.sh as review-v1.sh before
# overwriting so a rollback can be done with a manual move.
if [ -d "$SKILL_DIR" ]; then
    echo "Skill already exists at $SKILL_DIR"
    if [ -t 0 ]; then
        read -p "Overwrite existing installation? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    else
        echo "Non-interactive shell detected; proceeding with overwrite."
    fi
    if [ -f "$SKILL_DIR/scripts/review.sh" ]; then
        cp "$SKILL_DIR/scripts/review.sh" "$SKILL_DIR/scripts/review-v1.sh.bak" 2>/dev/null || true
    fi
    echo "Removing existing installation..."
    rm -rf "$SKILL_DIR"
fi

# Copy skill files
echo "Installing skill files to $SKILL_DIR..."
mkdir -p "$SKILL_DIR/scripts"
cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/"
cp "$SCRIPT_DIR/scripts/review.sh" "$SKILL_DIR/scripts/"
# Save a v1 reference copy alongside the installed review.sh so a downgrade
# can restore it. We always copy v1's review.sh source (the current main
# branch) — when the installed version IS v1 these are the same file, and
# that's fine.
cp "$SCRIPT_DIR/scripts/review.sh" "$SKILL_DIR/scripts/review-v1.sh"
cp "$SCRIPT_DIR/scripts/codex-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-output-schema.json" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/chunk-diff.awk" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-chunk-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-synthesis-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-verification-prompt.md" "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-followup-context.md" "$SKILL_DIR/scripts/"

if [ "$INSTALL_VERSION" = "2" ]; then
    echo "Installing v2 helpers (plan.js, ast-chunk.sh, grammars/)..."
    cp "$SCRIPT_DIR/scripts/plan.js" "$SKILL_DIR/scripts/"
    cp "$SCRIPT_DIR/scripts/ast-chunk.sh" "$SKILL_DIR/scripts/"
    if [ -f "$SCRIPT_DIR/scripts/package.json" ]; then
        cp "$SCRIPT_DIR/scripts/package.json" "$SKILL_DIR/scripts/"
    fi
    if [ -d "$SCRIPT_DIR/scripts/grammars" ]; then
        cp -R "$SCRIPT_DIR/scripts/grammars" "$SKILL_DIR/scripts/"
    fi
    if [ -f "$SCRIPT_DIR/.codex-pr-review.toml.example" ]; then
        cp "$SCRIPT_DIR/.codex-pr-review.toml.example" "$SKILL_DIR/"
    fi
    chmod +x "$SKILL_DIR/scripts/ast-chunk.sh" 2>/dev/null || true
fi

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

# v2-specific soft prereqs.
if [ "$INSTALL_VERSION" = "2" ]; then
    echo
    echo "Checking v2 prerequisites..."
    if command -v node &>/dev/null; then
        NODE_MAJOR=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0)
        if [ "$NODE_MAJOR" -lt 18 ]; then
            echo "  Warning: node $(node --version) is below the recommended v18. plan.js may not work."
        else
            echo "  node $(node --version) OK."
        fi
    else
        echo "  Warning: node not found. plan.js (v2 AST chunker) will fall back to AWK."
    fi
    if command -v claude &>/dev/null; then
        echo "  claude CLI present."
    else
        echo "  Warning: claude CLI not found. v2 dual-family review (P2+) will not work."
        echo "    Install: https://docs.anthropic.com/en/docs/claude-code"
    fi

    # If node is present and we have a package.json, install dependencies into
    # the skill directory so plan.js can require tree-sitter at runtime.
    if command -v node &>/dev/null && [ -f "$SKILL_DIR/scripts/package.json" ]; then
        echo "  Installing tree-sitter native bindings (this may take a minute)..."
        if (cd "$SKILL_DIR/scripts" && npm install --no-audit --no-fund --legacy-peer-deps >/dev/null 2>&1); then
            echo "  tree-sitter installed."
        else
            echo "  Warning: npm install failed. plan.js will fall back to AWK chunker."
        fi
    fi
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
echo "The $SKILL_NAME skill is now installed (v${INSTALL_VERSION})."
echo "Restart Claude Code, then use it with:"
echo
echo "  /codex-pr-review                  # Auto-detect PR for current branch"
echo "  /codex-pr-review 123              # Review PR #123"
echo "  /codex-pr-review --threshold 0.6  # Lower confidence threshold"
echo
echo "Files installed to: $SKILL_DIR"
echo
