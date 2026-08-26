# Surviving reboots: cron injection into tmux

Claude Code's own scheduling tools (`ScheduleWakeup`, `CronCreate`) only fire while the process that scheduled them is alive. If the host reboots, or the tmux session dies, they're gone. For anything that has to survive a reboot — a daily briefing, a recurring digest — you need something outside Claude Code doing the scheduling: the system crontab.

**Read this before reaching for it though:** if the scheduled task doesn't need a *live* interactive session — most briefings and digests don't — skip this pattern entirely and run `claude --dangerously-skip-permissions -p "$PROMPT" < /dev/null` directly from cron instead (see `docs/direct-claude-p-pattern.md` — not written yet, but the shape is: one bash script, explicit `PATH` export, `-p` call, parse output, notify). That's simpler, and it sidesteps everything below. This pattern is for the genuine remainder: cross-session messaging (`notify-session.sh`) and anything that specifically needs to land inside an existing conversation's context.

## The pattern

A system cron entry fires a script that:

1. Checks whether the target tmux session (`claude-<project>`) exists and has Claude Code actually running in it (not just a bare shell)
2. If not, recreates it using the same launch logic as your `claude.sh` (start LCM daemon, `claude --continue --dangerously-skip-permissions`, wait for init)
3. Waits for the pane to be idle
4. Injects the scheduled prompt via `tmux send-keys`

Step 3 is the part that's easy to get wrong — see Gotchas below for why it's not optional.

```bash
#!/bin/bash
# cron-inject.sh — ensure a session exists, then inject a prompt into it
SESSION="claude-main"
DIR="$HOME/main"
PROMPT="$1"

# shellcheck source=/dev/null
. ./tmux-idle-wait.sh   # provides is_pane_busy / wait_for_idle / tmux_send

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$DIR" \
    "claude --continue --dangerously-skip-permissions -n main"
  sleep 30  # give Claude Code time to initialize before we type into it
else
  PANE_CMD=$(tmux display-message -t "$SESSION" -p '#{pane_current_command}' 2>/dev/null)
  if [ "$PANE_CMD" = "bash" ] || [ "$PANE_CMD" = "sh" ]; then
    tmux_send "$SESSION" "cd '$DIR' && claude --continue --dangerously-skip-permissions -n main"
    sleep 30
  fi
fi

tmux_send "$SESSION" "$PROMPT" 300  # wait up to 5 min for idle before injecting
```

`tmux-idle-wait.sh` (in `scripts/`):

```bash
# is_pane_busy <session> — true if Claude Code's elapsed-time spinner is
# visible, e.g. "✢ Crafting… (45s · thought for 12s)". Present only during
# an active turn, absent when idle.
is_pane_busy() {
  tmux capture-pane -t "$1" -p -S -20 2>/dev/null | grep -qE '\([0-9]+s( · thought for [0-9]+s)?\)'
}

# wait_for_idle <session> [max_wait=300] [poll_interval=5]
wait_for_idle() {
  local session="$1" max_wait="${2:-300}" interval="${3:-5}" elapsed=0
  while is_pane_busy "$session"; do
    [ "$elapsed" -ge "$max_wait" ] && return 1
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 0
}

# tmux_send <session> <text> [max_wait=300] — waits for idle, then sends
# text and Enter as two separate calls (see Gotchas), warning instead of
# silently dropping if the pane never goes idle.
tmux_send() {
  local session="$1" text="$2" max_wait="${3:-300}"
  wait_for_idle "$session" "$max_wait" || \
    echo "[tmux-idle-wait] WARNING: $session still busy after ${max_wait}s — injecting anyway, may be dropped" >&2
  tmux send-keys -t "$session" -l "$text"
  sleep 0.5
  tmux send-keys -t "$session" Enter
}
```

Crontab entries then just call this with the prompt as an argument:

```
7 8 * * *   bash cron-inject.sh "Run the morning briefing: bash ~/main/scripts/morning-briefing.sh"
30 8 * * *  bash cron-inject.sh "Run the security digest: bash ~/main/scripts/security-digest.sh"
```

## Gotchas

- **`aws`/other tools not found in cron's PATH.** Cron runs with a minimal environment — if a script calls `aws`, `node`, `claude`, or anything installed via nvm/cargo/pip user-local paths, export `PATH` explicitly at the top of the script rather than relying on your shell profile. This bit every briefing script that migrated to direct `claude -p` invocation — each one failed silently, every single day, until the exports were added. Don't assume; test under `env -i PATH=/usr/bin:/bin bash your-script.sh` before trusting a cron migration.
- **Silent stdin hang.** If a script invokes `claude -p "..."` non-interactively from cron, it can hang waiting on stdin. Redirect `< /dev/null` explicitly.
- **`tmux send-keys` while the pane is mid-turn can silently *drop* the message, not queue it.** This is the one that actually cost real data: a scheduled nightly-reflection prompt was injected while the target session was deep in an unrelated multi-hour task, and it never ran — no error anywhere, nothing queued, just gone. `tmux send-keys` doesn't interrupt a running Claude Code turn, and it doesn't reliably wait for the current one to finish either; the injected text can land in an input box that isn't accepting it and the Enter keystroke doesn't register. Splitting text and Enter into two separate `send-keys` calls (below) fixes a *different*, narrower race (tmux/tmux#1778) but does nothing for this — you need to actually poll for idle before injecting, which is what `wait_for_idle`/`tmux_send` above do. Don't trust a fixed `sleep` to be a substitute for checking real state.
- **Text and Enter in one `send-keys` call.** Separate bug from the above (tmux/tmux#1778): combining them in one call can fail to register the Enter at all, independent of pane state. Always split into two calls with a short delay between them, as shown above.
