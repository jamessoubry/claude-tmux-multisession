# Surviving reboots: cron injection into tmux

Claude Code's own scheduling tools (`ScheduleWakeup`, `CronCreate`) only fire while the process that scheduled them is alive. If the host reboots, or the tmux session dies, they're gone. For anything that has to survive a reboot — a daily briefing, a recurring digest — you need something outside Claude Code doing the scheduling: the system crontab.

## The pattern

A system cron entry fires a script that:

1. Checks whether the target tmux session (`claude-<project>`) exists and has Claude Code actually running in it (not just a bare shell)
2. If not, recreates it using the same launch logic as your `claude.sh` (start LCM daemon, `claude --continue --dangerously-skip-permissions`, wait for init)
3. Injects the scheduled prompt via `tmux send-keys`

```bash
#!/bin/bash
# cron-inject.sh — ensure a session exists, then inject a prompt into it
set -euo pipefail

PROJECT=main
if ! [[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$PROJECT" == *..* ]]; then
  echo "Invalid project name: $PROJECT" >&2
  exit 1
fi

SESSION="claude-$PROJECT"
DIR="$HOME/$PROJECT"
PROMPT=${1:-}

if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$DIR" \
    claude --continue --dangerously-skip-permissions -n "$PROJECT"
  sleep 30  # give Claude Code time to initialize before we type into it
else
  PANE_CMD=$(tmux display-message -t "=$SESSION" -p '#{pane_current_command}' 2>/dev/null || true)
  if [ "$PANE_CMD" = "bash" ] || [ "$PANE_CMD" = "sh" ] || [ -z "$PANE_CMD" ]; then
    tmux send-keys -t "=$SESSION" \
      "cd $(printf '%q' "$DIR") && claude --continue --dangerously-skip-permissions -n $(printf '%q' "$PROJECT")" Enter
    sleep 30
  fi
fi

PANE_CMD=$(tmux display-message -t "=$SESSION" -p '#{pane_current_command}' 2>/dev/null || true)
if [ "$PANE_CMD" != "claude" ]; then
  echo "Session $SESSION is not running Claude Code — refusing to send"
  exit 1
fi

tmux send-keys -t "=$SESSION" -l "$PROMPT"
tmux send-keys -t "=$SESSION" Enter
```

Crontab entries then just call this with the prompt as an argument:

```
7 8 * * *   bash cron-inject.sh "Run the morning briefing: bash ~/main/scripts/morning-briefing.sh"
30 8 * * *  bash cron-inject.sh "Run the security digest: bash ~/main/scripts/security-digest.sh"
```

## Gotchas

- **`aws`/other tools not found in cron's PATH.** Cron runs with a minimal environment — if a script calls `aws`, `node`, or anything installed via nvm/cargo/pip user-local paths, export `PATH` explicitly at the top of the script rather than relying on your shell profile.
- **Silent stdin hang.** If a script invokes `claude -p "..."` non-interactively from cron, it can hang waiting on stdin. Redirect `< /dev/null` explicitly.
- **`tmux send-keys` while the pane is mid-tool-call.** The typed text queues and gets submitted once Claude finishes the current turn — it doesn't interrupt. Usually fine for briefings; worth knowing if timing matters.
- **Dangerous permissions.** The prompt lands in a pane running with `--dangerously-skip-permissions`, so only trusted cron entries should call this script.
