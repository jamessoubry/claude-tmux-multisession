#!/bin/bash
# notify-session.sh — send a message from one Claude Code session to another via tmux.
# Usage: notify-session.sh <session-name> "message"
# Example: bash notify-session.sh myproject "reload your CLAUDE.md"
# Sessions follow the claude-<name> tmux naming convention (see claude.sh).
#
# Delivers "[from:<sender>] message" into the target session's pane via
# tmux send-keys. This is push-style — it wakes an idle session up, unlike
# an MCP-style inter-agent message which only lands when the target session
# is already mid-turn. It also lands in tmux scrollback, so you get a free
# audit log of cross-session coordination.

set -euo pipefail

SESSION=${1:-}
MSG=${2:-}

if [ -z "$SESSION" ] || [ -z "$MSG" ]; then
  echo "Usage: notify-session.sh <session-name> \"message\""
  exit 1
fi

if ! [[ "$SESSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$SESSION" == *..* ]]; then
  echo "Invalid session name: $SESSION (allowed: letters, digits, '.', '_', '-')" >&2
  exit 1
fi

TMUX_SESSION="claude-${SESSION}"
FROM="${CLAUDE_SESSION_NAME:-main}"
FULL_MSG="[from:${FROM}] ${MSG}"

if ! tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
  echo "Session $TMUX_SESSION not found — is it running?"
  exit 1
fi

PANE_CMD=$(tmux display-message -t "=$TMUX_SESSION" -p '#{pane_current_command}' 2>/dev/null || true)
if [ "$PANE_CMD" != "claude" ]; then
  echo "Session $TMUX_SESSION is not running Claude Code — refusing to send"
  exit 1
fi

# tmux doesn't reliably register Enter when sent in the same send-keys call
# as the text (known tmux quirk: https://github.com/tmux/tmux/issues/1778).
# Split into two calls with a short delay.
tmux send-keys -t "=$TMUX_SESSION" -l "$FULL_MSG"
sleep 0.5
tmux send-keys -t "=$TMUX_SESSION" Enter
echo "Sent to $TMUX_SESSION: $FULL_MSG"
