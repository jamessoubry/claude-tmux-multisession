# tmux-idle-wait.sh — sourceable helper: wait for a Claude Code tmux pane to
# be idle before injecting text, instead of firing blind.
#
# Background: tmux send-keys doesn't reliably register Enter when combined
# with text in one call (tmux/tmux#1778) -- splitting into two calls with a
# short delay fixes THAT race, but does nothing if the target pane is
# genuinely mid-turn for tens of seconds or minutes. Injected text still
# lands in a busy input box and the Enter still doesn't submit, silently
# dropping the message (confirmed root cause of the missed Aug 25 nightly
# reflection). This adds a real idle check: Claude Code's busy indicator is
# a spinner line with an elapsed-time counter, e.g.
#   "✢ Crafting… (45s · thought for 12s)"
# which is present only while a turn is actively running and absent once
# idle. Poll for its absence before injecting, instead of trusting a fixed
# delay to have been long enough.

# is_pane_busy <tmux-session>
# Returns 0 (true) if the busy-timer pattern is present in the pane.
is_pane_busy() {
  tmux capture-pane -t "$1" -p -S -20 2>/dev/null | grep -qE '\([0-9]+s( · thought for [0-9]+s)?\)'
}

# wait_for_idle <tmux-session> [max_wait_seconds] [poll_interval_seconds]
# Polls until the pane is idle or max_wait elapses. Returns 0 if idle was
# reached, 1 if it timed out still busy (caller decides whether to inject
# anyway or bail).
wait_for_idle() {
  local session="$1"
  local max_wait="${2:-300}"
  local interval="${3:-5}"
  local elapsed=0

  while is_pane_busy "$session"; do
    if [ "$elapsed" -ge "$max_wait" ]; then
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 0
}

# tmux_send <tmux-session> <text>
# Send text + Enter as separate calls (tmux#1778 workaround), after
# confirming the pane is idle. Logs a warning and injects anyway if the
# pane never went idle within the timeout, rather than silently dropping.
tmux_send() {
  local session="$1"
  local text="$2"
  local max_wait="${3:-300}"

  if wait_for_idle "$session" "$max_wait"; then
    :
  else
    echo "[tmux-idle-wait] WARNING: $session still busy after ${max_wait}s wait — injecting anyway, may be dropped" >&2
  fi

  tmux send-keys -t "$session" -l "$text"
  sleep 0.5
  tmux send-keys -t "$session" Enter
}
