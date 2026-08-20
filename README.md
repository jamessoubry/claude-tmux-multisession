# claude-tmux-multisession

A multi-project Claude Code setup: one tmux session per project, shared memory that persists across sessions and reboots, workspace-wide semantic search, token-cost reduction on shell output, a Rust safety hook that guards destructive commands, and a self-pacing backlog runner for autonomous feature work.

This isn't a framework or a package — it's a documented pattern plus a handful of small scripts. Copy what's useful.

## Why

Running one Claude Code session per project (instead of one giant session, or restarting from scratch each time) means each project keeps its own conversation history and context — but you lose continuity *between* sessions, and you're paying full token price for every `git status` and `cargo test` output. This setup fixes both without changing how Claude Code itself works.

## The pieces

| Piece | What it does | Repo |
|---|---|---|
| **tmux + `claude.sh`** | One tmux session per project (`claude-<project>`), auto-created on demand | this repo |
| **[LCM](https://github.com/lossless-claude/lcm)** | Auto-captures every session, compacts to a DAG, promotes durable findings to cross-session memory | lossless-claude/lcm |
| **[ICM](https://github.com/rtk-ai/icm)** | Manual, tagged, high-signal memory store — decisions, resolved errors, preferences | rtk-ai/icm |
| **[QMD](https://github.com/tobi/qmd)** | Local hybrid search (BM25 + vector + LLM rerank) over your whole workspace/knowledge base | tobi/qmd |
| **[SpecStory](https://github.com/specstoryai/getspecstory)** | Converts Claude Code JSONL session logs into git-friendly markdown per project | specstoryai/getspecstory |
| **[RTK](https://github.com/rtk-ai/rtk)** | CLI proxy that compresses shell output before it reaches the model — 60–90% token savings on `git`/`cargo`/`docker`/etc | rtk-ai/rtk |
| **[clawband](https://github.com/jamessoubry/clawband)** | Rust PreToolUse hook — blocks/asks on destructive shell commands before Claude Code runs them | jamessoubry/clawband (mine) |
| **`/backlog` skill** | Self-pacing agent that works a markdown or GitHub-issues backlog one item at a time, with crash recovery via `ScheduleWakeup` | this repo (`skills/backlog.md`) |
| **`notify-session.sh`** | Cross-session messaging via `tmux send-keys` — one session can wake/notify another, logged in scrollback | this repo |

None of these depend on each other — pick the ones that solve a problem you actually have.

## 1. Multi-session via tmux

`scripts/claude.sh` is the launcher. Each project gets its own tmux session named `claude-<project>`:

```bash
bash claude.sh          # defaults to "main" — your overseer/ops session
bash claude.sh myapp    # opens (or creates) ~/myapp in tmux session claude-myapp
bash claude.sh newthing # prompts to create ~/newthing if it doesn't exist yet
```

Why tmux and not just multiple terminal tabs: sessions survive SSH disconnects, reboots (with a bit of extra plumbing — see below), and you can attach from any device via Tailscale/SSH. It also gives every session a stable name other tooling (cron, notify-session.sh) can target.

The script also starts the LCM daemon and kicks off a SpecStory sync in the background before attaching — so memory and history capture are always warm.

**Set up:** edit `YOUR_USER` in `scripts/claude.sh` (or export `CLAUDE_HOME_USER` — the script refuses to run while the placeholder is unset), drop it somewhere on your `$PATH` (or alias it), install [tmux](https://github.com/tmux/tmux) if you don't have it.

## 2. Memory: three layers, different jobs

The mistake is treating "AI memory" as one problem. It's three:

- **LCM** — passive, automatic, cheap. Runs in the background, captures everything, decides later what's worth keeping via compact+promote. You never call it directly during normal work.
- **ICM** — active, deliberate, high-signal. Claude calls `icm store` when something durable happens: a bug root-caused, an architecture decision made, a user preference discovered. This is the layer with editorial judgement.
- **QMD** — not memory at all, it's search. Indexes your knowledge base and session history (specstory output) so either of the above — or a plain markdown wiki — becomes queryable.

See `docs/memory-architecture.md` for the full breakdown, including how they're wired into `CLAUDE.md`.

## 3. Token cost: RTK

[RTK](https://github.com/rtk-ai/rtk) sits between your shell and Claude via a PreToolUse-style rewrite: `git status` silently becomes `git status | rtk compress` (or similar), cutting typical dev-command output by 60–90% with no behaviour change from your side. Single Rust binary, no daemon, install once.

## 4. Safety: clawband

[clawband](https://github.com/jamessoubry/clawband) is a Rust PreToolUse hook I wrote — it inspects every shell command Claude Code is about to run and blocks or asks-for-confirmation on destructive patterns (`rm -rf`, force-pushes, `crontab` overwrites, etc.) before they execute. Runs alongside `--dangerously-skip-permissions` mode so you get autonomy without giving up a safety net. Fully open, PRs welcome for new patterns.

## 5. Autonomous backlog work: `/backlog`

`skills/backlog.md` is a Claude Code skill (drop it in `~/.claude/commands/`) that works through a markdown checklist or a GitHub repo's labelled issues, one item per invocation:

```
/backlog ~/myproject/backlog.md
/backlog YOUR_GITHUB_USER/myproject
```

Each tick: pick the next item → implement (coder agent) → test (tester agent) → release (releaser agent, push + deploy) → update state → notify. It calls `ScheduleWakeup` at the *start* of every tick (not the end), so if the session gets killed mid-work, the next wakeup finds the item still unchecked and retries. Supports both direct-push and PR-required workflows, with exponential-backoff polling for PR merges.

This is the piece that turns "I have a list of things Claude should get around to" into something that actually runs unattended over hours/days.

## 6. Cross-session messaging

`scripts/notify-session.sh` sends a message from one Claude Code session into another's tmux pane:

```bash
bash notify-session.sh myapp "reload your CLAUDE.md"
# → delivers "[from:main] reload your CLAUDE.md" into the claude-myapp pane
```

I compared this against Claude Code's built-in `SendMessage`/`ListAgents` cross-session tools (shipped Aug 2026) and kept tmux instead: `SendMessage` only lands when the target session is already mid-turn, so it can't wake an idle session. `tmux send-keys` actively wakes it, and you get a free audit trail in scrollback — useful when you're coordinating several autonomous sessions and want to know later what one told another.

## 7. Surviving reboots

The pieces above run inside a live tmux session — they die on reboot unless something re-creates them. I use a system crontab entry that checks whether the tmux session exists and, if not, recreates it via `claude.sh` before injecting a scheduled prompt (`tmux send-keys`). See `docs/cron-injection-pattern.md` for the pattern (not included as a runnable script here since it's tightly coupled to what you're scheduling).

## Error handling conventions

These scripts run unattended (cron, background sessions), so a swallowed error means
a job that silently never ran. The convention across `scripts/`, `docs/`, and the
`/backlog` skill:

- `set -euo pipefail` in every script; diagnostics go to stderr, exit codes are non-zero on failure.
- Optional integrations (`lcm`, `specstory`) are skipped when not installed, but a tool that *is* installed and fails prints its output as a warning instead of being discarded.
- Async work logs to a file (`$TMPDIR/specstory-sync-<project>.log`) and its failure is reported on the next run rather than lost.
- `tmux` calls (`new-session`, `send-keys`, `display-message`) are checked — including a post-create check that the session didn't die immediately.
- In `/backlog`, an API/config failure is never treated as a state answer: a failed `gh issue list` aborts the tick instead of reading as "backlog complete", and a malformed `.backlog.yml` is fatal instead of defaulting to `pr_required: false`.

## What's NOT in this repo

Deliberately excluded because it's either secrets or too personal-infra-specific to be a useful template: notification tokens, AWS account details, actual backlog contents, actual CLAUDE.md files. Use the pattern, bring your own config.

## License

MIT — copy anything here freely.
