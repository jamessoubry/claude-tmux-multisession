#!/usr/bin/env bats

load test_helper

setup() {
  setup_sandbox
  stub_tmux
  stub lcm
  stub specstory
  install_claude_sh
}

teardown() {
  teardown_sandbox
}

@test "defaults to the 'main' project and its ~/main directory" {
  mkdir -p "$FAKE_HOME/main"

  run bash "$CLAUDE_SH"

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"tmux new-session -d -s claude-main -c $FAKE_HOME/main "* ]]
}

@test "names the tmux session and directory after the project argument" {
  mkdir -p "$FAKE_HOME/myapp"

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"tmux new-session -d -s claude-myapp -c $FAKE_HOME/myapp "* ]]
}

@test "creates a missing project directory when confirmed" {
  run bash -c "printf 'y\n' | bash '$CLAUDE_SH' newthing"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Created $FAKE_HOME/newthing"* ]]
  [ -d "$FAKE_HOME/newthing" ]
  [[ "$(calls)" == *"tmux new-session -d -s claude-newthing"* ]]
}

@test "aborts without creating anything when the prompt is declined" {
  run bash -c "printf 'n\n' | bash '$CLAUDE_SH' newthing"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborted."* ]]
  [ ! -d "$FAKE_HOME/newthing" ]
  [[ "$(calls)" != *"tmux"* ]]
}

@test "treats empty confirmation input as a decline" {
  run bash -c "printf '\n' | bash '$CLAUDE_SH' newthing"

  [ "$status" -eq 1 ]
  [ ! -d "$FAKE_HOME/newthing" ]
}

@test "launches claude without --continue when there is no prior transcript" {
  mkdir -p "$FAKE_HOME/myapp"

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"claude  --dangerously-skip-permissions -n 'myapp'"* ]]
  [[ "$(calls)" != *"--continue"* ]]
}

@test "adds --continue when the project transcript is longer than 50 lines" {
  mkdir -p "$FAKE_HOME/myapp"
  seed_transcript "$FAKE_HOME/myapp" 51

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"claude --continue --dangerously-skip-permissions"* ]]
}

@test "does not add --continue for a transcript of exactly 50 lines" {
  mkdir -p "$FAKE_HOME/myapp"
  seed_transcript "$FAKE_HOME/myapp" 50

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" != *"--continue"* ]]
}

@test "passes the project name to claude's -n and --remote-control flags" {
  mkdir -p "$FAKE_HOME/myapp"

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"-n 'myapp' --remote-control 'myapp'"* ]]
}

@test "reuses a live session without restarting claude in it" {
  mkdir -p "$FAKE_HOME/myapp"
  export TMUX_HAS_SESSION_STATUS=0 TMUX_PANE_CMD=node

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" != *"new-session"* ]]
  [[ "$(calls)" != *"send-keys"* ]]
  [[ "$(calls)" == *"tmux attach -t claude-myapp"* ]]
}

@test "restarts claude in an existing session sitting at a shell prompt" {
  mkdir -p "$FAKE_HOME/myapp"
  export TMUX_HAS_SESSION_STATUS=0 TMUX_PANE_CMD=bash

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"tmux send-keys -t claude-myapp cd '$FAKE_HOME/myapp' && claude "* ]]
  [[ "$(calls)" == *"Enter"* ]]
}

@test "restarts claude when the pane command cannot be determined" {
  mkdir -p "$FAKE_HOME/myapp"
  export TMUX_HAS_SESSION_STATUS=0 TMUX_PANE_CMD=

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"tmux send-keys -t claude-myapp"* ]]
}

@test "warms up LCM and specstory before attaching" {
  mkdir -p "$FAKE_HOME/myapp"

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"lcm daemon start"* ]]
  [[ "$(calls)" == *"lcm import"* ]]
  [[ "$(calls)" == *"specstory sync claude --no-cloud-sync"* ]]
}

@test "still attaches when lcm and specstory are not installed" {
  mkdir -p "$FAKE_HOME/myapp"
  rm "$STUB_BIN/lcm" "$STUB_BIN/specstory"

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"tmux attach -t claude-myapp"* ]]
}

@test "attaches to the session as the final step" {
  mkdir -p "$FAKE_HOME/myapp"

  run bash "$CLAUDE_SH" myapp

  [ "$status" -eq 0 ]
  [ "$(calls | tail -n 1)" = "tmux attach -t claude-myapp" ]
}
