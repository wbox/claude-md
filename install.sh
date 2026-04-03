#!/bin/bash
# install.sh - Install Claude Code hooks + CLAUDE.md into a project
# Usage: ./install.sh /path/to/project
#    or: curl -sL https://raw.githubusercontent.com/iamfakeguru/claude-md/main/install.sh | bash -s /path/to/project

set -e

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Target directory does not exist: $TARGET"
  exit 1
fi

# Resolve the source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If running from curl pipe, BASH_SOURCE won't work - download files
if [ ! -f "$SCRIPT_DIR/settings.json" ] && [ ! -f "$SCRIPT_DIR/.claude/settings.json" ]; then
  TMP=$(mktemp -d)
  echo "Downloading hooks package..."
  curl -sL https://github.com/iamfakeguru/claude-md/archive/main.tar.gz | tar -xz -C "$TMP"
  SCRIPT_DIR="$TMP/claude-md-main"
fi

# Determine where source files are (flat repo root or .claude/ subdirectory)
if [ -f "$SCRIPT_DIR/.claude/settings.json" ]; then
  HOOKS_SRC="$SCRIPT_DIR/.claude/hooks"
  SETTINGS_SRC="$SCRIPT_DIR/.claude/settings.json"
elif [ -f "$SCRIPT_DIR/settings.json" ]; then
  HOOKS_SRC="$SCRIPT_DIR"
  SETTINGS_SRC="$SCRIPT_DIR/settings.json"
else
  echo "Error: Cannot find settings.json in $SCRIPT_DIR"
  exit 1
fi

# Create target directories
echo "Installing hooks to $TARGET/.claude/"
mkdir -p "$TARGET/.claude/hooks"

# Copy settings - backup if exists
if [ -f "$TARGET/.claude/settings.json" ]; then
  echo "WARNING: $TARGET/.claude/settings.json already exists."
  echo "Backing up to $TARGET/.claude/settings.json.bak"
  cp "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.json.bak"
fi

cp "$SETTINGS_SRC" "$TARGET/.claude/settings.json"

# Copy hook scripts
for HOOK in post-edit-verify.sh stop-verify.sh truncation-check.sh block-destructive.sh; do
  if [ -f "$HOOKS_SRC/$HOOK" ]; then
    cp "$HOOKS_SRC/$HOOK" "$TARGET/.claude/hooks/$HOOK"
  fi
done
chmod +x "$TARGET/.claude/hooks/"*.sh

# Copy CLAUDE.md - don't overwrite without warning
if [ -f "$SCRIPT_DIR/CLAUDE.md" ]; then
  if [ -f "$TARGET/CLAUDE.md" ]; then
    echo "WARNING: $TARGET/CLAUDE.md already exists."
    echo "New version saved as $TARGET/CLAUDE.md.v3"
    cp "$SCRIPT_DIR/CLAUDE.md" "$TARGET/CLAUDE.md.v3"
  else
    cp "$SCRIPT_DIR/CLAUDE.md" "$TARGET/CLAUDE.md"
  fi
fi

echo ""
echo "Installed:"
echo "  $TARGET/.claude/settings.json    (hook configuration)"
echo "  $TARGET/.claude/hooks/           (4 hook scripts)"
[ -f "$TARGET/CLAUDE.md" ] || [ -f "$TARGET/CLAUDE.md.v3" ] && echo "  $TARGET/CLAUDE.md                (agent directives)"
echo ""
echo "Hooks will activate on next Claude Code session in this project."
