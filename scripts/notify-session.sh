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
#
# Exits non-zero (with a message on stderr) on any delivery failure, so callers
# — cron jobs, other sessions — can tell a delivered message from a lost one.

set -euo pipefail

die() {
  echo "notify-session.sh: $*" >&2
  exit 1
}

SESSION=${1:-}
MSG=${2:-}

if [ -z "$SESSION" ] || [ -z "$MSG" ]; then
  echo "Usage: notify-session.sh <session-name> \"message\"" >&2
  exit 1
fi

command -v tmux >/dev/null 2>&1 || die "'tmux' not found on \$PATH — install it first."

TMUX_SESSION="claude-${SESSION}"
FROM="${CLAUDE_SESSION_NAME:-main}"
FULL_MSG="[from:${FROM}] ${MSG}"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  die "session $TMUX_SESSION not found — is it running?"
fi

# tmux doesn't reliably register Enter when sent in the same send-keys call
# as the text (known tmux quirk: https://github.com/tmux/tmux/issues/1778).
# Split into two calls with a short delay.
tmux send-keys -t "$TMUX_SESSION" -l "$FULL_MSG" \
  || die "failed to send message text to $TMUX_SESSION"
sleep 0.5
# If the session died between the two calls the text is already typed but
# unsubmitted — report that explicitly rather than claiming success.
tmux send-keys -t "$TMUX_SESSION" Enter \
  || die "message typed into $TMUX_SESSION but Enter failed — it was not submitted"
echo "Sent to $TMUX_SESSION: $FULL_MSG"
