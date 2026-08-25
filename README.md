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
| **[SpecStory](https://github.com/specstoryai/getspecstory)** | Converts Claude Code JSONL session logs into git-friendly markdown; hooked into SessionStart/PreCompact/Stop so transcripts stay current | specstoryai/getspecstory |
| **[RTK](https://github.com/rtk-ai/rtk)** | CLI proxy that compresses shell output before it reaches the model — 60–90% token savings on `git`/`cargo`/`docker`/etc | rtk-ai/rtk |
| **[sqz](https://github.com/ojuschugh1/sqz) (MCP proxy only)** | Wraps an MCP server (e.g. `github`) and compresses *its* JSON responses — a capability RTK doesn't have at all | ojuschugh1/sqz |
| **[clawband](https://github.com/jamessoubry/clawband)** | Rust PreToolUse hook — blocks/asks on destructive shell commands before Claude Code runs them | jamessoubry/clawband (mine) |
| **[compact-plus](https://github.com/u-ichi/compact-plus)** | Laptop-only alternative to LCM's SessionStart injection: PreCompact hook writes a 10-section state file, SessionStart(compact) re-injects it — no database, no daemon | u-ichi/compact-plus |
| **[starship-claude](https://github.com/martinemde/starship-claude)** | Parses Claude Code's status JSON and exports env vars (context%, model, cost) so Starship can render them in the status line | martinemde/starship-claude |
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

**Set up:** edit `YOUR_USER` in `scripts/claude.sh`, drop it somewhere on your `$PATH` (or alias it), install [tmux](https://github.com/tmux/tmux) if you don't have it.

## 2. Memory: three layers, different jobs

The mistake is treating "AI memory" as one problem. It's three:

- **LCM** — passive, automatic, cheap. Runs in the background, captures everything, decides later what's worth keeping via compact+promote. You never call it directly during normal work.
- **ICM** — active, deliberate, high-signal. Claude calls `icm store` when something durable happens: a bug root-caused, an architecture decision made, a user preference discovered. This is the layer with editorial judgement.
- **QMD** — not memory at all, it's search. Indexes your knowledge base and session history (specstory output) so either of the above — or a plain markdown wiki — becomes queryable.

See `docs/memory-architecture.md` for the full breakdown, including how they're wired into `CLAUDE.md`.

## 3. Token cost: RTK for the shell, sqz for MCP servers

[RTK](https://github.com/rtk-ai/rtk) sits between your shell and Claude via a PreToolUse-style rewrite: `git status` silently becomes `git status | rtk compress` (or similar), cutting typical dev-command output by 60–90% with no behaviour change from your side. Single Rust binary, no daemon, install once.

I evaluated [sqz](https://github.com/ojuschugh1/sqz) as a full RTK replacement (same PreToolUse-hook role) and it lost decisively on real tests: `grep` output 47KB→1.8KB with RTK (96%) vs 47KB→24.6KB with sqz (48%); a passing `cargo test` run 42.8KB→43 bytes with RTK (99.9%, collapses to a pass/fail summary) vs 42.8KB→42.7KB with sqz (10%). RTK's per-command formatters understand semantics (hide passing-test noise, cap grep match counts); sqz's `compress` is a generic text-compression pass with no command-specific awareness. Keep RTK for the shell hook.

Where sqz *does* win, and RTK has zero equivalent: `sqz-mcp proxy` wraps another MCP server and compresses its JSON responses. A real `list_issues` call through a plain `github` MCP server hit 66.5KB and **failed outright** — exceeded Claude Code's per-call token limit, had to be dumped to a file for manual chunked reading. The identical call through `sqz-mcp proxy -- npx -y @modelcontextprotocol/server-github` succeeded inline in one shot, using dictionary-substitution compression on the repeated JSON field names. That's not a percentage improvement, it's the difference between a call that works and one that doesn't. Config:

```json
{
  "mcpServers": {
    "github": {
      "command": "sqz-mcp",
      "args": ["proxy", "--", "npx", "-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "..." }
    }
  }
}
```

Net setup: RTK on the Bash `PreToolUse` hook, sqz only wrapping MCP servers likely to return large result sets (issue lists, PR search, commit history). Neither tool replaces the other — they solve different problems.

## 4. Safety: clawband

[clawband](https://github.com/jamessoubry/clawband) is a Rust PreToolUse hook I wrote — it inspects every shell command Claude Code is about to run and blocks or asks-for-confirmation on destructive patterns (`rm -rf`, force-pushes, `crontab` overwrites, etc.) before they execute. On this repo's own always-on box, Claude Code runs with `--dangerously-skip-permissions` ("yolo mode") for unattended/cron work, and clawband is what makes that survivable — it's the only safety net once Claude Code's own permission prompts are off.

**With normal permissions on (not yolo)** — the default for interactive work, e.g. a work laptop — clawband still earns its place, just for a different reason: it's a hard, pattern-matched DENY tier that Claude Code's own permission system doesn't have (a generic "allow this tool call?" prompt doesn't tell you it matched `rm -rf` specifically, and can be approved on autopilot), and it collapses the ASK tier to one clear reason instead of a wall of individual per-command prompts. Standalone binary, no daemon — applies identically on a laptop or a server.

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

## 7. Surviving reboots (server/always-on)

The pieces above run inside a live tmux session — they die on reboot unless something re-creates them. I use a system crontab entry that checks whether the tmux session exists and, if not, recreates it via `claude.sh` before injecting a scheduled prompt (`tmux send-keys`). See `docs/cron-injection-pattern.md` for the pattern (not included as a runnable script here since it's tightly coupled to what you're scheduling).

## 8. Laptop setup: no server, no daemon

Everything above assumes an always-on box (a home server, a cloud VM) where a background daemon like LCM makes sense — it just runs, forever, and catches up on its own. A laptop that's suspended and restarted constantly through the day is a different shape of problem, and running the same stack on it is the wrong move, not just a smaller version of the right one.

**The guiding principle:** durable files on disk are the source of truth; any running process — daemon, index, cache — is disposable and rebuildable from those files. (This is the same idea behind [walgit](https://github.com/tobi/walgit)'s object-storage-backed git server: the write-ahead log in durable storage is truth, every server instance is a disposable cache. Applied to a laptop, "durable storage" is just the local disk, and "disposable cache" is anything that needs a daemon running to stay current.)

**What changes vs. the server setup:**

- **No LCM.** Technically LCM *can* work fine on a laptop — Claude Code writes its own session transcripts to disk regardless of whether any daemon is running, so nothing is lost by the daemon being off; it just needs to catch up (`lcm import`) whenever a session starts. But if you're trying to avoid scattered state and secrets across machines, skip it — the pieces below cover the same ground with less moving infrastructure.
- **SpecStory is the recall mechanism, not just an archive.** On the server setup above, SpecStory output can be treated as pure audit trail. On the laptop, it's what you and Claude actually search when you need to recall something from a past session. Wire up the sync hook and index the output in QMD — see "SpecStory + qmd wiring" below.

  (Contrast: on an always-on box where LCM already owns recall, exclude SpecStory from QMD's default queries instead — `qmd collection exclude specstory` — so you're not paying to search the same history twice through two different tools. Which way round it goes depends entirely on what your recall layer actually is.)
- **compact-plus replaces LCM's SessionStart injection.** It's the one piece that doesn't have a laptop-friendly equivalent lying around already — LCM's "summarize before compaction, inject after" behavior needed a real replacement, not just a lighter version. compact-plus does exactly that and nothing else: no search, no recall, no database — a PreCompact hook writes a 10-section state file (active plan, decisions, blockers, failed attempts), a SessionStart(compact) hook re-injects it once. Pure files in `$TMPDIR`, no daemon.
  ```bash
  claude plugin marketplace add u-ichi/compact-plus --scope user
  claude plugin install compact-plus@compact-plus
  ```
  It calls out to an LLM to generate that state summary on every compaction (default `claude -p`), which is a real per-compaction cost — tune it down if that matters. Add this `env` block at the top level of `~/.claude/settings.json` (alongside `permissions`, `hooks`, etc.):
  ```json
  {
    "env": {
      "COMPACT_PLUS_PRIMARY_BACKEND": "claude -p --model claude-haiku-4-5-20251001 --effort low --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt \"$SYSTEM_PROMPT\""
    }
  }
  ```
- **RTK still applies, unchanged.** It's a single binary with no daemon — the laptop/server distinction that matters for LCM doesn't apply to it at all. Same install, same win.
- **If anything here ends up SQLite-backed** (QMD's own index does), keep its data directory *outside* whatever a cloud sync client (OneDrive, iCloud, Dropbox, Syncthing) watches. Sync tools don't understand SQLite's WAL/shm sidecar files and can upload a torn mid-write snapshot or fight the SQLite process for the file — a real, documented failure mode, not a theoretical one (see: reports of exactly this corrupting Logseq's DB-backed graphs over Syncthing).

### Surviving reboots on macOS

tmux sessions survive sleep/wake, so you only need this for actual reboots or first login of the day. On macOS use a **LaunchAgent** (not cron — launchd is the right tool for login-triggered work):

`~/Library/LaunchAgents/com.user.claude-session.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.claude-session</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/path/to/scripts/ensure-claude-session.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-session-launch.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-session-launch.log</string>
</dict>
</plist>
```

`scripts/ensure-claude-session.sh` (included in this repo) pre-creates the session silently — no interactive attach, no auto-injected prompt. You attach when you open your terminal as normal via `claude.sh`. The reason not to call `claude.sh` directly from the LaunchAgent: it attaches interactively, which hangs a non-TTY process.

Load it once:

```bash
launchctl load ~/Library/LaunchAgents/com.user.claude-session.plist
```

**Why not auto-inject a prompt on boot** (unlike the server pattern in Section 7): battery drain, no display context, and no user intent. The LaunchAgent just guarantees the session exists; it does no work itself.

Net laptop stack: SpecStory (capture + recall, via QMD) + QMD (search) + compact-plus (compaction continuity) + RTK (shell token cost) + clawband (safety). No daemon that needs to survive a reboot, no server, no secrets beyond what each tool already needs on its own.

## 9. SpecStory + qmd wiring

SpecStory converts Claude Code's JSONL session logs into readable markdown. QMD indexes those files so Claude can search across all past sessions in one `qmd query` call rather than reading whole transcripts.

**Install:**

```bash
npm install -g @tobilu/qmd        # or: bun install -g @tobilu/qmd
brew install sqlite               # macOS: required for qmd's SQLite extensions
npm install -g @specstoryai/specstory-cli
```

**One-time collection setup:**

```bash
qmd collection add ~/.claude/History --name specstory
qmd context add qmd://specstory "Claude Code session transcripts — past debugging sessions, architecture decisions, and investigations"

qmd collection add ~/.claude/Clippings --name clippings
qmd context add qmd://clippings "Investigation notes and findings — bug root causes, incident analyses, architecture decisions"

qmd embed
```

**Hook wiring** — `scripts/specstory-sync.sh` (included in this repo) runs SpecStory sync then kicks off `qmd embed` in the background. Wire it into `~/.claude/settings.json` on three events:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/specstory-sync.sh", "timeout": 60, "async": true }] }],
    "PreCompact":   [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/specstory-sync.sh", "timeout": 60, "async": true }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/specstory-sync.sh", "timeout": 60, "async": true }] }]
  }
}
```

Copy `scripts/specstory-sync.sh` to `~/.claude/hooks/specstory-sync.sh` and edit the `sync_from` lines to point at your project directories.

**Searching:**

```bash
qmd query 'question in plain English'   # hybrid BM25 + semantic + rerank
qmd search 'TICKET-1234'                # keyword only — exact strings, ticket numbers
```

Tell Claude about it in your `CLAUDE.md` so it reaches for `qmd query` automatically instead of reading whole History files:

```markdown
## Past session recall

Before reading History files or Clippings, search first: `qmd query 'topic'`
Collections: specstory (~/.claude/History), clippings (~/.claude/Clippings), and any wiki/notes directories you've added.
```

## 10. Status line

Claude Code exposes a `statusLine` hook — a command that runs after every turn and whose stdout becomes the status bar below the prompt. The most useful thing to show there: context window percentage, so you can see compaction approaching before it surprises you.

[starship-claude](https://github.com/martinemde/starship-claude) bridges Claude's status JSON to Starship. It parses the JSON piped to it, exports useful values as env vars, then calls Starship to render them:

```bash
curl -fsSL https://raw.githubusercontent.com/martinemde/starship-claude/main/starship-claude \
  -o ~/.local/bin/starship-claude
chmod +x ~/.local/bin/starship-claude
```

Wire it up in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "STARSHIP_CONFIG=~/.claude/starship.toml ~/.local/bin/starship-claude"
}
```

The `STARSHIP_CONFIG` override is intentional — Claude's status line runs in a subprocess without your normal shell env, so a dedicated config avoids conflicts with your regular prompt and lets you tune segments specifically for Claude sessions.

Key env vars the script exports:

| Variable             | What it is                                       |
|----------------------|--------------------------------------------------|
| `CLAUDE_CONTEXT`     | Context usage, left-padded (e.g. ` 47%`)         |
| `CLAUDE_PERCENT_RAW` | Raw integer for threshold comparisons            |
| `CLAUDE_MODEL_NERD`  | Model name with NerdFont icon (e.g. `󰚩 sonnet`)  |
| `CLAUDE_COST`        | Session cost formatted (e.g. `$0.71`)            |
| `CLAUDE_RATE_5H`     | 5-hour rate limit % + time to reset              |

Minimal `~/.claude/starship.toml` to show context% and model:

```toml
add_newline = false
format = "$time${custom.ctx}$directory$git_branch ${env_var.CLAUDE_MODEL_NERD} "

[time]
disabled = false
time_format = "%H:%M:%S"
format = "[ $time ](bg:214 fg:black)"

[custom.ctx]
command = "printf '%s' \"${CLAUDE_CONTEXT}\""
when = "test -n \"${CLAUDE_CONTEXT:-}\""
use_stdin = false
format = "[ $output ](fg:black bg:green)"
shell = ["bash", "--noprofile", "--norc", "-c"]

[env_var.CLAUDE_MODEL_NERD]
variable = "CLAUDE_MODEL_NERD"
format = "[$env_value](fg:white)"
```

Pairs naturally with compact-plus — you watch the context % climb toward 80%, compaction fires, compact-plus re-injects the state summary, and you resume without losing the thread.

## What's NOT in this repo

Deliberately excluded because it's either secrets or too personal-infra-specific to be a useful template: notification tokens, AWS account details, actual backlog contents, actual CLAUDE.md files. Use the pattern, bring your own config.

## License

MIT — copy anything here freely.
