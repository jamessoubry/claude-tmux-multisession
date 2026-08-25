#!/usr/bin/env bash
#
# specstory-sync.sh
#
# Syncs Claude Code session transcripts to a single output directory using
# SpecStory, then re-indexes them in qmd so `qmd query` stays current.
#
# Wire this into ~/.claude/settings.json on the SessionStart, PreCompact,
# and Stop hook events (all async). See README § "SpecStory + qmd wiring".
#
# Customise: add one sync_from call per project directory you want captured.
# The output directory is a flat collection — all projects land in one place
# so qmd searches across everything in a single query.
#
set -euo pipefail

OUTPUT_DIR="$HOME/.claude/History"  # qmd collection should point here

sync_from() {
    local dir="$1"
    [ -d "$dir" ] || return
    pushd "$dir" > /dev/null
    specstory sync claude --no-cloud-sync --output-dir "$OUTPUT_DIR" --silent 2>/dev/null
    popd > /dev/null
}

# Add one line per project directory that has Claude Code sessions:
sync_from "$HOME/projects/myapp"
# sync_from "$HOME/projects/otherapp"

# Re-index new transcripts into qmd so `qmd query` stays current.
# Runs in the background — does not block the hook from returning.
qmd embed --silent 2>/dev/null &
