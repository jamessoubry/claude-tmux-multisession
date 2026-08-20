#!/bin/bash
# claude.sh — launcher for multi-session Claude Code, one tmux session per project.
# Usage: claude.sh [project]   — defaults to "main"
# Project dir resolution: ~/project-name, or create on the fly if it doesn't exist yet.

set -euo pipefail

# Edit this to your username (or export CLAUDE_HOME_USER to override).
YOUR_USER=${CLAUDE_HOME_USER:-YOUR_USER}

die() {
  echo "claude.sh: $*" >&2
  exit 1
}

warn() {
  echo "claude.sh: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found on \$PATH — install it first."
}

# Run an optional side-effect command. Missing binary is fine (feature is opt-in),
# but a binary that exists and fails is reported with its output instead of hidden.
try_optional() {
  local label=$1
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  local output status
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    warn "$label failed (exit $status): ${output:-no output}"
  fi
  return 0
}

require_cmd tmux
require_cmd claude

PROJECT=${1:-main}

if [ "$YOUR_USER" = "YOUR_USER" ]; then
  die "YOUR_USER is still the placeholder — edit it in this script or set CLAUDE_HOME_USER."
fi

# Known aliases (override the default ~/project-name convention if needed)
case $PROJECT in
  main) DIR="/home/$YOUR_USER/main" ;;
  *)    DIR="/home/$YOUR_USER/$PROJECT" ;;
esac

if [ ! -d "$DIR" ]; then
  [ -t 0 ] || die "Directory $DIR doesn't exist and stdin is not a terminal — create it first."
  echo "Directory $DIR doesn't exist. Create it? [y/N]"
  read -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    mkdir -p "$DIR" || die "could not create $DIR"
    echo "Created $DIR"
  else
    die "Aborted."
  fi
fi

SESSION="claude-$PROJECT"

# Only use --continue if a real prior session exists (>50 lines = actual conversation).
# --continue exits silently in interactive mode when there's nothing to resume.
PROJECT_KEY=$(echo "$DIR" | sed 's|/|-|g')
TRANSCRIPTS_DIR="$HOME/.claude/projects/$PROJECT_KEY"
MAX_LINES=0
if [ -d "$TRANSCRIPTS_DIR" ]; then
  # A read failure here means the count can't be trusted, so fall back to no
  # --continue rather than silently treating it as "no prior session".
  if ! MAX_LINES=$(find "$TRANSCRIPTS_DIR" -maxdepth 1 -name '*.jsonl' -exec cat {} + | wc -l); then
    warn "could not read transcripts in $TRANSCRIPTS_DIR — starting without --continue"
    MAX_LINES=0
  fi
fi
CONTINUE_FLAG=""
if [ "$MAX_LINES" -gt 50 ]; then
  CONTINUE_FLAG="--continue"
fi

CLAUDE_CMD="claude $CONTINUE_FLAG --dangerously-skip-permissions -n '$PROJECT' --remote-control '$PROJECT'"

# Ensure LCM daemon is up and import any unprocessed transcripts before starting.
# These are optional niceties — a failure warns but does not block the session.
try_optional "lcm daemon start" lcm daemon start
try_optional "lcm import" lcm import

# Sync session history to readable markdown (async — ~3s even when nothing to do,
# so it must not block attaching). Output and exit status go to a log, and a
# failure recorded by the previous run is surfaced here instead of vanishing.
SPECSTORY_LOG="${TMPDIR:-/tmp}/specstory-sync-$PROJECT.log"
if [ -f "$SPECSTORY_LOG" ] && grep -q '^specstory sync FAILED' "$SPECSTORY_LOG"; then
  warn "previous specstory sync failed — see $SPECSTORY_LOG"
fi
if command -v specstory >/dev/null 2>&1; then
  (
    if ! (cd "$DIR" && specstory sync claude --no-cloud-sync); then
      echo "specstory sync FAILED (see output above)"
    fi
  ) >"$SPECSTORY_LOG" 2>&1 &
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$DIR" "$CLAUDE_CMD" \
    || die "failed to create tmux session $SESSION"
  # A session whose command exits immediately dies right away; catch that here
  # rather than letting `tmux attach` fail with an opaque "no such session".
  sleep 1
  tmux has-session -t "$SESSION" 2>/dev/null \
    || die "session $SESSION exited immediately — check that '$CLAUDE_CMD' runs in $DIR"
else
  # Session exists — check if claude is actually running in it
  if ! PANE_CMD=$(tmux display-message -t "$SESSION" -p '#{pane_current_command}' 2>&1); then
    die "could not inspect tmux session $SESSION: $PANE_CMD"
  fi
  if [ "$PANE_CMD" = "bash" ] || [ "$PANE_CMD" = "sh" ] || [ -z "$PANE_CMD" ]; then
    tmux send-keys -t "$SESSION" "cd '$DIR' && $CLAUDE_CMD" Enter \
      || die "failed to start claude in existing session $SESSION"
  fi
fi

exec tmux attach -t "$SESSION"
