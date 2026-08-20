#!/bin/bash
# claude.sh — launcher for multi-session Claude Code, one tmux session per project.
# Usage: claude.sh [project]   — defaults to "main"
# Project dir resolution: ~/project-name, or create on the fly if it doesn't exist yet.

set -euo pipefail

PROJECT=${1:-main}

# The project name ends up in a tmux session name, a filesystem path and a
# command line, so restrict it to a safe character set instead of trusting it.
if ! [[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$PROJECT" == *..* ]]; then
  echo "Invalid project name: $PROJECT (allowed: letters, digits, '.', '_', '-')" >&2
  exit 1
fi

BASE=${CLAUDE_PROJECTS_DIR:-$HOME}

# Known aliases (override the default <base>/project-name convention if needed)
case $PROJECT in
  main) DIR="$BASE/main" ;;
  *)    DIR="$BASE/$PROJECT" ;;
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
MAX_LINES=$(cat ~/.claude/projects/"$PROJECT_KEY"/*.jsonl 2>/dev/null | wc -l || true)
CLAUDE_ARGV=(claude)
if [ "${MAX_LINES:-0}" -gt 50 ]; then
  CLAUDE_ARGV+=(--continue)
fi
CLAUDE_ARGV+=(--dangerously-skip-permissions -n "$PROJECT" --remote-control "$PROJECT")

# Ensure LCM daemon is up and import any unprocessed transcripts before starting
lcm daemon start 2>/dev/null || true
lcm import 2>/dev/null || true
# Sync session history to readable markdown (async — ~3s even when nothing to do)
(cd "$DIR" && specstory sync claude --no-cloud-sync >/dev/null 2>&1) &

if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
  # Multiple args: tmux execs argv directly, no shell parsing of the project name.
  tmux new-session -d -s "$SESSION" -c "$DIR" "${CLAUDE_ARGV[@]}"
else
  # Session exists — check if claude is actually running in it
  PANE_CMD=$(tmux display-message -t "=$SESSION" -p '#{pane_current_command}' 2>/dev/null || true)
  if [ "$PANE_CMD" = "bash" ] || [ "$PANE_CMD" = "sh" ] || [ -z "$PANE_CMD" ]; then
    # send-keys types into a live shell, so shell-quote every interpolated value.
    tmux send-keys -t "=$SESSION" \
      "cd $(printf '%q' "$DIR") && $(printf '%q ' "${CLAUDE_ARGV[@]}")" Enter
  fi
fi

tmux attach -t "=$SESSION"
