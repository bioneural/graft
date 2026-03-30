#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${1:-$HOME/hyperagent}"

# --- TCC directory check (macOS) ---
check_tcc_safe() {
    if [ "$(uname)" != "Darwin" ]; then return 0; fi
    local resolved
    resolved=$(cd "$1" 2>/dev/null && pwd -P || echo "$1")
    case "$resolved" in
        "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
            echo "ERROR: $1 is under a macOS TCC-protected directory."
            echo "LaunchAgents cannot access ~/Desktop, ~/Documents, or ~/Downloads."
            echo "Use a path outside these directories, e.g. ~/hyperagent"
            exit 1
            ;;
    esac
}
check_tcc_safe "$INSTALL_DIR"

echo "=== Graft: bootstrapping your hyperagent ==="
echo ""
echo "Install directory: $INSTALL_DIR"
echo ""

# --- Prerequisites ---

for cmd in git gh jq claude; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found. Install it and try again."; exit 1; }
done

gh auth status >/dev/null 2>&1 || { echo "ERROR: not authenticated with gh. Run 'gh auth login' first."; exit 1; }

CLAUDE_PATH=$(command -v claude)
echo "Claude binary: $CLAUDE_PATH"
echo "Claude version: $(claude --version 2>&1 || echo 'unknown')"

echo "Verifying Claude Code auth..."
CLAUDE_OUTPUT=$(claude -p "say ok" --dangerously-skip-permissions --max-turns 1 2>&1) || { echo "ERROR: Claude Code check failed:"; echo "$CLAUDE_OUTPUT"; exit 1; }
echo "Claude Code: ok"

GH_USER=$(gh api user --jq '.login')
echo "GitHub user: $GH_USER"

# Check if repo already exists
if gh repo view "$GH_USER/hyperagent" >/dev/null 2>&1; then
    echo "ERROR: $GH_USER/hyperagent already exists. Delete it first or clone it directly."
    exit 1
fi

if [ -d "$INSTALL_DIR" ]; then
    echo "ERROR: $INSTALL_DIR already exists. Remove it first or choose a different path."
    exit 1
fi

# --- Download spec and instructions ---

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

API_URL="https://api.github.com/repos/bioneural/graft/contents"
RAW_HEADER="Accept: application/vnd.github.raw"

echo "Downloading spec..."
curl -sL -H "$RAW_HEADER" "$API_URL/hyperagent-spec.md" -o "$WORK_DIR/hyperagent-spec.md"
echo "Downloading implementation instructions..."
curl -sL -H "$RAW_HEADER" "$API_URL/implement-hyperagent.md" -o "$WORK_DIR/implement-hyperagent.md"

# Verify downloads
for f in hyperagent-spec.md implement-hyperagent.md; do
    [ -s "$WORK_DIR/$f" ] || { echo "ERROR: failed to download $f"; exit 1; }
done

# --- Invoke Claude Code ---

echo ""
echo "Handing off to Claude Code. This will:"
echo "  1. Create $INSTALL_DIR with all files from the spec"
echo "  2. Create a private repo at github.com/$GH_USER/hyperagent"
echo "  3. Push everything"
echo ""
echo "This takes a few minutes."
echo ""

cd "$WORK_DIR"

claude -p "Read implement-hyperagent.md and hyperagent-spec.md in the current directory. Follow the implementation instructions exactly. The GitHub username is $GH_USER. The install directory is $INSTALL_DIR (use this instead of ~/hyperagent everywhere)." \
    --dangerously-skip-permissions \
    --allowedTools "Read,Write,Edit,Bash,Glob,Grep" \
    --max-turns 50 \
    --verbose \
    2>&1 || { echo "ERROR: Claude Code exited with status $?. See output above."; exit 1; }

echo ""
echo ""
echo "========================================"
echo ""
echo "  Hyperagent built successfully."
echo ""
echo "  Next steps:"
echo ""
echo "    1. $INSTALL_DIR/install.sh"
echo "    2. Restart Claude Code"
echo ""
echo "========================================"
