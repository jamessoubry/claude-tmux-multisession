#!/usr/bin/env bats

load test_helper

NOTIFY="$REPO_ROOT/scripts/notify-session.sh"

setup() {
  setup_sandbox
  stub_tmux
  export TMUX_HAS_SESSION_STATUS=0
}

teardown() {
  teardown_sandbox
}

@test "prints usage and fails when no arguments are given" {
  run bash "$NOTIFY"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: notify-session.sh <session-name>"* ]]
  [[ "$(calls)" != *"tmux"* ]]
}

@test "prints usage and fails when the message is missing" {
  run bash "$NOTIFY" myapp

  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "fails when the target session is not running" {
  export TMUX_HAS_SESSION_STATUS=1

  run bash "$NOTIFY" myapp "hello"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Session claude-myapp not found"* ]]
  [[ "$(calls)" != *"send-keys"* ]]
}

@test "targets the claude-<name> session" {
  run bash "$NOTIFY" myapp "hello"

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"tmux has-session -t claude-myapp"* ]]
  [[ "$(calls)" == *"tmux send-keys -t claude-myapp -l "* ]]
}

@test "prefixes the message with the sending session, defaulting to main" {
  run bash "$NOTIFY" myapp "reload your CLAUDE.md"

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"-l [from:main] reload your CLAUDE.md"* ]]
  [[ "$output" == *"Sent to claude-myapp: [from:main] reload your CLAUDE.md"* ]]
}

@test "uses CLAUDE_SESSION_NAME as the sender when set" {
  export CLAUDE_SESSION_NAME=overseer

  run bash "$NOTIFY" myapp "hello"

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"-l [from:overseer] hello"* ]]
}

@test "sends the text and the Enter keypress as two separate calls" {
  run bash "$NOTIFY" myapp "hello"

  [ "$status" -eq 0 ]
  [ "$(calls | grep -c 'send-keys')" -eq 2 ]
  [ "$(calls | grep 'send-keys' | tail -n 1)" = "tmux send-keys -t claude-myapp Enter" ]
}

@test "sends the message literally so it is not interpreted as keys" {
  run bash "$NOTIFY" myapp "C-c and \$HOME stay literal"

  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"-l [from:main] C-c and \$HOME stay literal"* ]]
}
