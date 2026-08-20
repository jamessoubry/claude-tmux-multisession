#!/bin/bash
# claude-session.sh — shared helpers for the tmux/Claude Code session scripts.
# Source it, don't execute it:
#   source "$(dirname "$0")/lib/claude-session.sh"
#
# Conventions this library owns:
#   - tmux session naming: claude-<project>
#   - project directory: $CLAUDE_PROJECT_ROOT/<project> (defaults to $HOME)
#   - how a Claude Code session is (re)started in a pane
#   - how text is typed into a pane so tmux registers the Enter

CLAUDE_PROJECT_ROOT=${CLAUDE_PROJECT_ROOT:-$HOME}

# Seconds to wait for Claude Code to initialize before typing into a fresh pane.
CLAUDE_INIT_WAIT=${CLAUDE_INIT_WAIT:-30}

session_name() {
  echo "claude-$1"
}

project_dir() {
  echo "$CLAUDE_PROJECT_ROOT/$1"
}

session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

# claude_cmd <project> [extra-flags...]
claude_cmd() {
  local project=$1
  shift
  echo "claude $* --dangerously-skip-permissions -n '$project'"
}

# --continue exits silently in interactive mode when there's nothing to resume,
# so only pass it when a real prior session exists (>50 lines = actual conversation).
continue_flag() {
  local dir=$1 project_key lines
  project_key=${dir//\//-}
  lines=$(cat ~/.claude/projects/"$project_key"/*.jsonl 2>/dev/null | wc -l)
  [ "$lines" -gt 50 ] && echo "--continue"
}

# True when the pane is sitting at a bare shell (or unreadable), i.e. Claude
# Code is not running in it.
pane_is_idle_shell() {
  local pane_cmd
  pane_cmd=$(tmux display-message -t "$1" -p '#{pane_current_command}' 2>/dev/null)
  [ "$pane_cmd" = "bash" ] || [ "$pane_cmd" = "sh" ] || [ -z "$pane_cmd" ]
}

# ensure_session <session> <dir> <command> [wait-seconds]
# Creates the session if missing, or restarts the command in it if the pane
# dropped back to a shell. Waits <wait-seconds> afterwards so callers that
# immediately type into the pane don't race Claude Code's startup.
ensure_session() {
  local session=$1 dir=$2 cmd=$3 wait=${4:-0}

  if ! session_exists "$session"; then
    tmux new-session -d -s "$session" -c "$dir" "$cmd"
  elif pane_is_idle_shell "$session"; then
    tmux send-keys -t "$session" "cd '$dir' && $cmd" Enter
  else
    return 0
  fi

  [ "$wait" -gt 0 ] && sleep "$wait"
  return 0
}

# send_to_session <session> <text>
# tmux doesn't reliably register Enter when sent in the same send-keys call as
# the text (known tmux quirk: https://github.com/tmux/tmux/issues/1778), so
# split it into two calls with a short delay.
send_to_session() {
  tmux send-keys -t "$1" -l "$2"
  sleep 0.5
  tmux send-keys -t "$1" Enter
}

# Start the background memory/history tooling for a project directory.
warm_memory_tooling() {
  local dir=$1
  lcm daemon start 2>/dev/null || true
  lcm import 2>/dev/null || true
  # async — ~3s even when nothing to do
  (cd "$dir" && specstory sync claude --no-cloud-sync >/dev/null 2>&1) &
}
