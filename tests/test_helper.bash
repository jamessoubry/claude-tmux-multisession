#!/usr/bin/env bash
# Shared helpers for the bats suites.
#
# The scripts under test shell out to tmux, lcm and specstory and read from
# ~/.claude. Every test therefore runs against a throwaway HOME plus a
# throwaway bin directory holding recording stubs, so nothing touches the
# real machine and every external call can be asserted on.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  FAKE_HOME="$SANDBOX/home"
  STUB_BIN="$SANDBOX/bin"
  STUB_LOG="$SANDBOX/calls.log"
  mkdir -p "$FAKE_HOME" "$STUB_BIN"
  : >"$STUB_LOG"
  export HOME="$FAKE_HOME"
  export STUB_LOG
  export PATH="$STUB_BIN:$PATH"
}

teardown_sandbox() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# Write a stub that records its invocation and exits with the given status.
stub() {
  local name=$1 status=${2:-0}
  cat >"$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
{ printf '%s' '$name'; printf ' %s' "\$@"; printf '\n'; } >>"\$STUB_LOG"
exit $status
EOF
  chmod +x "$STUB_BIN/$name"
}

# tmux stub with per-subcommand behaviour driven by the environment:
#   TMUX_HAS_SESSION_STATUS  exit status of `tmux has-session` (default 1 = absent)
#   TMUX_PANE_CMD            value printed by `tmux display-message -p`
stub_tmux() {
  cat >"$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
{ printf 'tmux'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
case "$1" in
  has-session) exit "${TMUX_HAS_SESSION_STATUS:-1}" ;;
  display-message) printf '%s\n' "${TMUX_PANE_CMD-}" ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/tmux"
}

# Render claude.sh the way the README tells users to install it: with the
# YOUR_USER placeholder pointing at a real (here: sandboxed) home directory.
install_claude_sh() {
  CLAUDE_SH="$SANDBOX/claude.sh"
  sed "s|/home/YOUR_USER|$FAKE_HOME|g" "$REPO_ROOT/scripts/claude.sh" >"$CLAUDE_SH"
  chmod +x "$CLAUDE_SH"
}

# Seed ~/.claude/projects/<key>/session.jsonl with N transcript lines, where
# <key> is the project directory with slashes turned into dashes.
seed_transcript() {
  local dir=$1 lines=$2 key
  key=$(printf '%s' "$dir" | sed 's|/|-|g')
  mkdir -p "$FAKE_HOME/.claude/projects/$key"
  if [ "$lines" -gt 0 ]; then
    seq "$lines" >"$FAKE_HOME/.claude/projects/$key/session.jsonl"
  fi
}

calls() {
  cat "$STUB_LOG"
}
