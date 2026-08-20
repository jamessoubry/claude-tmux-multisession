#!/bin/bash
# claude.sh — launcher for multi-session Claude Code, one tmux session per project.
# Usage: claude.sh [project]   — defaults to "main"
# Project dir resolution: $CLAUDE_PROJECT_ROOT/project-name (default root: $HOME),
# or create on the fly if it doesn't exist yet.

source "$(dirname "${BASH_SOURCE[0]}")/lib/claude-session.sh"

PROJECT=${1:-main}
DIR=$(project_dir "$PROJECT")

if [ ! -d "$DIR" ]; then
  echo "Directory $DIR doesn't exist. Create it? [y/N]"
  read -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    mkdir -p "$DIR"
    echo "Created $DIR"
  else
    echo "Aborted."
    exit 1
  fi
fi

SESSION=$(session_name "$PROJECT")
CLAUDE_CMD="$(claude_cmd "$PROJECT" "$(continue_flag "$DIR")") --remote-control '$PROJECT'"

warm_memory_tooling "$DIR"
ensure_session "$SESSION" "$DIR" "$CLAUDE_CMD"

tmux attach -t "$SESSION"
