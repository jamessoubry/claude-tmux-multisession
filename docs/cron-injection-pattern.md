# Surviving reboots: cron injection into tmux

Claude Code's own scheduling tools (`ScheduleWakeup`, `CronCreate`) only fire while the process that scheduled them is alive. If the host reboots, or the tmux session dies, they're gone. For anything that has to survive a reboot — a daily briefing, a recurring digest — you need something outside Claude Code doing the scheduling: the system crontab.

## The pattern

A system cron entry fires a script that:

1. Checks whether the target tmux session (`claude-<project>`) exists and has Claude Code actually running in it (not just a bare shell)
2. If not, recreates it using the same launch logic as your `claude.sh` (start LCM daemon, `claude --continue --dangerously-skip-permissions`, wait for init)
3. Injects the scheduled prompt via `tmux send-keys`

The session-name convention, the "is Claude actually running in this pane" check, the relaunch and the send-keys quirk all live in `scripts/lib/claude-session.sh`, so the cron script is just a few calls into it:

```bash
#!/bin/bash
# cron-inject.sh — ensure a session exists, then inject a prompt into it
source ~/scripts/lib/claude-session.sh   # wherever you dropped the scripts

PROJECT=main
PROMPT="$1"

SESSION=$(session_name "$PROJECT")
DIR=$(project_dir "$PROJECT")

# $CLAUDE_INIT_WAIT (default 30s) gives Claude Code time to initialize before we type
ensure_session "$SESSION" "$DIR" "$(claude_cmd "$PROJECT" --continue)" "$CLAUDE_INIT_WAIT"
send_to_session "$SESSION" "$PROMPT"
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
