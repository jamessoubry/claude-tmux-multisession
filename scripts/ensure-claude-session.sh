#!/usr/bin/env bash
#
# ensure-claude-session.sh
#
# Pre-creates the main Claude tmux session on login via a LaunchAgent.
# Does NOT attach and does NOT send a prompt — this runs non-interactively.
# Run `claude.sh` from your terminal to attach as normal.
#
# Usage: see README § "Surviving reboots on macOS"
#
set -euo pipefail

SESSION="claude-main"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION"
fi
