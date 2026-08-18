#!/bin/bash
# claude.sh — launcher for multi-session Claude Code, one tmux session per project.
# Usage: claude.sh [project]   — defaults to "main"
# Project dir resolution: ~/project-name, or create on the fly if it doesn't exist yet.

PROJECT=${1:-main}

# Known aliases (override the default ~/project-name convention if needed)
case $PROJECT in
  main) DIR=/home/YOUR_USER/main ;;
  *)    DIR="/home/YOUR_USER/$PROJECT" ;;
esac

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

SESSION="claude-$PROJECT"

# Only use --continue if a real prior session exists (>50 lines = actual conversation).
# --continue exits silently in interactive mode when there's nothing to resume.
PROJECT_KEY=$(echo "$DIR" | sed 's|/|-|g')
MAX_LINES=$(cat ~/.claude/projects/"$PROJECT_KEY"/*.jsonl 2>/dev/null | wc -l)
CONTINUE_FLAG=$([ "$MAX_LINES" -gt 50 ] && echo "--continue" || echo "")

CLAUDE_CMD="claude $CONTINUE_FLAG --dangerously-skip-permissions -n '$PROJECT' --remote-control '$PROJECT'"

# Ensure LCM daemon is up and import any unprocessed transcripts before starting
lcm daemon start 2>/dev/null || true
lcm import 2>/dev/null || true
# Sync session history to readable markdown (async — ~3s even when nothing to do)
(cd "$DIR" && specstory sync claude --no-cloud-sync >/dev/null 2>&1) &

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$DIR" "$CLAUDE_CMD"
else
  # Session exists — check if claude is actually running in it
  PANE_CMD=$(tmux display-message -t "$SESSION" -p '#{pane_current_command}' 2>/dev/null)
  if [ "$PANE_CMD" = "bash" ] || [ "$PANE_CMD" = "sh" ] || [ -z "$PANE_CMD" ]; then
    tmux send-keys -t "$SESSION" "cd '$DIR' && $CLAUDE_CMD" Enter
  fi
fi

tmux attach -t "$SESSION"
