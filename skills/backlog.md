---
name: backlog
description: Process a backlog one item at a time — from a markdown file or a GitHub repo's issues. Implements each as a software feature using coder/tester/releaser subagents, then self-paces to the next item via ScheduleWakeup.
user_invocable: true
---

# /backlog

Work through a backlog one feature at a time. Each tick: pick the next item, implement it with subagents, mark it done, then schedule the next tick automatically.

## Arguments

Two modes:

**File mode** — markdown backlog file:
```
/backlog ~/main/backlog.md
/backlog ~/clawband/backlog.md
```

**GitHub issues mode** — repo's open issues labelled `backlog`, ordered by priority:
```
/backlog YOUR_GITHUB_USER/clawband
/backlog YOUR_GITHUB_USER/gavel
```

The argument is GitHub issues mode if it matches `owner/repo` (contains `/` but not a file path starting with `~` or `/`).

**No-argument mode** — if no argument is provided, look for a `.backlog.yml` in the current working directory. If found and it contains a `repo:` field, use that as the `owner/repo` argument automatically. If it contains a `file:` field instead, use that as the file path argument (file mode). If no `.backlog.yml`, no `repo:` field, and no `file:` field, print usage and stop.

## File mode — backlog.md format

```markdown
- [ ] [project] Feature description
- [ ] [gavel] Add rate limiting to the public API
- [ ] [myapp] Fix timeout in the job queue worker
- [x] [polybot] Already done — skipped
- [!] [gavel] Failed item — PR closed without merge / test failure / reason
- [~] [clawband] PR pending — PR #42 YOUR_GITHUB_USER/clawband
- [-] [shortlink] Parked item — not ready to implement yet
```

`[ ]` = pending · `[x]` = done · `[!]` = failed · `[~]` = PR open, awaiting merge · `[-]` = parked (skip forever until changed to `[ ]`)

`[~]` items are not re-implemented — on the next run `/backlog` checks if the PR merged and either deploys or reminds you.

`[-]` items are **permanently skipped** — the skill never processes them. Change to `[ ]` manually when ready to implement.

## GitHub issues mode — issue conventions

- Issues must have the `backlog` label to be queued
- Priority ordering: `P0` → `bug` → `P1` → `P2` → unlabelled (bugs always jump the queue without needing a P-label; only use P-labels for genuine escalations)
- State is tracked via labels and issue open/closed state:
  - Queued: open + `backlog` label only
  - In progress: open + `in-progress` label (`backlog` removed when checked out)
  - PR pending: open + `pr-pending` label (`backlog` and `in-progress` both removed)
  - Done: closed
  - Failed: open + `failed` label (stays open for manual retry/fix)
- The project is inferred from the repo name (e.g. `YOUR_GITHUB_USER/clawband` → `clawband`)

## Project config — `.backlog.yml`

Each project can define a `.backlog.yml` in its root directory. The skill reads this first; the project map below is a fallback for projects that don't have one.

```yaml
# <project_dir>/.backlog.yml
repo: YOUR_GITHUB_USER/clawband      # GitHub repo — use this OR file:, not both
file: ~/myproject/backlog.md    # backlog file path — use for file-mode projects with no GitHub repo
deploy: cargo build --release   # deploy command (overrides fallback map)
label: backlog                  # issue label to filter on (default: backlog)
priority: [P0, P1, P2]         # priority label order, high→low (default)
pr_required: false              # if true: push branch + open PR instead of pushing to main; poll for merge before deploying
pr_poll_interval: 300           # seconds between merge checks (default: 300)
pr_timeout: 86400               # seconds before giving up on a PR (default: 86400 = 24h)
notify: bash ~/main/scripts/notify-main.sh "{message}"  # notification command; {message} is substituted. Omit to skip notifications.
single_session_lock: false      # if true: use /tmp/backlog.lock to prevent concurrent runs (useful on memory-constrained hosts)
```

When reading project config, check `<project_dir>/.backlog.yml` first. If it exists, use those values. If it doesn't exist or a field is missing, fall back to the project map below.

## Project map (fallback)

| Tag | Directory | Deploy | GitHub repo |
|-----|-----------|--------|-------------|
| `main` | `~/YOUR_PROJECTS/main` | — | — |
| `gavel` | `~/YOUR_PROJECTS/gavel` | `./deploy.sh` | `YOUR_GITHUB_USER/gavel` |
| `replenish` | `~/YOUR_PROJECTS/replenish` | `./deploy.sh` | — |
| `filemover` | `~/YOUR_PROJECTS/filemover` | CodeBuild via `./build.sh` | — |
| `polybot` | `~/YOUR_PROJECTS/polybot` | `./deploy.sh --deploy` | — |
| `shortlink` | `~/YOUR_PROJECTS/shortlink` | `./deploy.sh` | — |
| `oneeye` | `~/YOUR_PROJECTS/oneeye` | CodeBuild via `./build.sh` | — |
| `clawband` | `~/YOUR_PROJECTS/clawband` | `cargo build --release` + install | `YOUR_GITHUB_USER/clawband` |

## Instructions

### Step 0 — Single-session lock (optional)

If `single_session_lock: true` is set in `.backlog.yml` (default: false), enforce a global lockfile to prevent two backlog runs competing for RAM:

```bash
LOCK=/tmp/backlog.lock
if [ -f "$LOCK" ]; then
  OWNER=$(cat "$LOCK") || OWNER="unknown (lockfile unreadable)"
  echo "Backlog already running: $OWNER — try again when it finishes" >&2
  STOP
fi
if ! echo "<project> — started $(date -u +%H:%M:%SZ)" > "$LOCK"; then
  echo "Could not write $LOCK — refusing to run unguarded" >&2
  STOP
fi
```

If the lockfile cannot be written, STOP rather than continuing without the lock —
the point of the lock is to prevent two runs competing, and an unguarded run
silently defeats it.

Release on every exit path (success, failure, PR pending, early stop):
```bash
rm -f /tmp/backlog.lock
```

If `single_session_lock` is absent or false, skip this step entirely.

### Step 1 — Find the next item

**File mode:**
Read the file. Check for `[~]` lines first (PR pending), then `[ ]` lines.

If a `[~]` line exists:
```bash
# Extract PR number and repo from the line, e.g. "PR #42 YOUR_GITHUB_USER/clawband"
unset GITHUB_TOKEN
STATE=$(gh pr view <PR_NUMBER> --repo <REPO> --json state --jq '.state') \
  || { echo "cannot read PR state (auth/network?) — leaving item as [~]" >&2; exit 1; }
```

If `gh` fails, STOP and leave the item as `[~]`. Never fall through to "not merged"
on an unknown state — a transient API failure would otherwise be recorded as a real
outcome.
- If `MERGED`: proceed to deploy (skip implement/test — jump straight to release/deploy step), then mark `[~]` → `[x]`
- If `OPEN`: schedule a wakeup (`ScheduleWakeup(delaySeconds: PR_POLL_INTERVAL, prompt: "/backlog <same argument>", reason: "polling for PR #N merge")`), then STOP (no notification — merge-check polling is silent). Read `PR_POLL_INTERVAL` from `.backlog.yml` `pr_poll_interval` field (default: 600).
- If `CLOSED`: mark `[~]` → `[!] — PR closed without merge` then continue to next item

If no `[~]` exists, find the **first** `[ ]` line. **Skip any `[-]` lines entirely — they are parked and must not be processed.**
If neither exists (only `[x]`, `[!]`, `[-]` lines remain): `bash ~/main/scripts/notify-main.sh "Backlog complete: all items in <filepath> processed"` then STOP — do NOT call ScheduleWakeup.

After finding the `[ ]` line, also capture any immediately following lines that are indented (start with 2+ spaces or a tab) — these are detail notes for the coder. Collect them as `FEATURE_DETAIL`. Stop collecting at the next blank line or next bullet (`- `).

**GitHub issues mode:**

Load `.backlog.yml` from the project dir (inferred from repo name) to get `BACKLOG_LABEL` and `PRIORITY_LABELS`.

**First: check for any in-flight PR issue** (two stages — review check before merge check):

**Stage A — review check** (`pr-review-pending` label): PR was just opened; reviews not yet fetched.

```bash
unset GITHUB_TOKEN
PR_REVIEW=$(gh issue list --repo "<owner/repo>" \
  --label "pr-review-pending" --state open --limit 1 \
  --json number,title --jq '.[0]') \
  || { echo "gh issue list failed — aborting tick" >&2; exit 1; }
```

If a `pr-review-pending` issue is found:
- Extract `ISSUE_NUMBER`, find the associated PR number (search recent open PRs whose body contains `#ISSUE_NUMBER`)
- Fetch review comments: `gh api repos/<owner/repo>/pulls/<PR_NUMBER>/comments --jq '[.[] | {user: .user.login, body: .body, path: .path, line: .line}]'`
- Also fetch review summaries: `gh pr view <PR_NUMBER> --repo <owner/repo> --json reviews --jq '[.reviews[] | {user: .user.login, state: .state, body: .body}]'`
- Surface any findings to the user (print a summary — reviewer, severity badge if present in body, first 200 chars of body, file+line if inline)
- Flip label: `gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "pr-pending" --remove-label "pr-review-pending"`
- Reset backoff counter: `echo 1 > /tmp/backlog-pr-${PR_NUMBER}.poll`
- Schedule wakeup at `pr_poll_interval` for merge check, then STOP

**Stage B — merge check** (`pr-pending` label): reviews already surfaced; now polling for merge.

```bash
unset GITHUB_TOKEN
PR_PENDING=$(gh issue list --repo "<owner/repo>" \
  --label "pr-pending" --state open --limit 1 \
  --json number,title --jq '.[0]') \
  || { echo "gh issue list failed — aborting tick" >&2; exit 1; }
```

If a `pr-pending` issue is found:
- Extract `ISSUE_NUMBER`, find associated PR
- Check PR state and handle:
  - **MERGED** → deploy + close issue + `rm -f /tmp/backlog-pr-${PR_NUMBER}.poll`
  - **OPEN** → exponential backoff poll (no notification — merge-check polling is silent):
    ```bash
    ATTEMPT=$(cat /tmp/backlog-pr-${PR_NUMBER}.poll 2>/dev/null || echo 1)
    echo $((ATTEMPT + 1)) > /tmp/backlog-pr-${PR_NUMBER}.poll
    NEXT_DELAY=$(python3 -c "print(min($PR_POLL_INTERVAL * 2**($ATTEMPT-1), 3600))") \
      || NEXT_DELAY=$PR_POLL_INTERVAL   # never schedule with an empty delay
    ```
    Call `ScheduleWakeup(delaySeconds: NEXT_DELAY, ...)`, then STOP.
    First poll fires at `pr_poll_interval`, subsequent polls double up to 3600s max.
  - **CLOSED** → `rm -f /tmp/backlog-pr-${PR_NUMBER}.poll` + remove `pr-pending` label + continue to queue

If no pr-pending issue: find the **next queued item**:

```bash
unset GITHUB_TOKEN
# BACKLOG_LABEL from .backlog.yml or default "backlog"
# PRIORITY_LABELS from .backlog.yml or default ["P0","P1","P2"]
ISSUE_JSON=$(gh issue list --repo "<owner/repo>" \
  --label "$BACKLOG_LABEL" --state open --limit 100 \
  --json number,title,labels \
  --jq --arg p0 "${PRIORITY_LABELS[0]}" --arg p1 "${PRIORITY_LABELS[1]}" --arg p2 "${PRIORITY_LABELS[2]}" '
    def priority:
      .labels | map(.name) |
      if contains([$p0]) then 0
      elif contains(["bug"]) then 1
      elif contains([$p1]) then 2
      elif contains([$p2]) then 3
      else 4 end;
    sort_by([priority, .number]) | .[0]
  ') || { echo "gh issue list failed — aborting tick" >&2; exit 1; }
```
If the command **fails**, abort the tick — an API error is not an empty backlog.
If it **succeeds** and the result is null/empty: `bash ~/main/scripts/notify-main.sh "Backlog complete: no open backlog issues in <repo>"` then STOP.

Extract `ISSUE_NUMBER` and `ISSUE_TITLE` from the JSON.

### Step 2 — Schedule the next tick (crash recovery)

Only reached if an item was found in Step 1.

First, peek at the project config to check `pr_required`. Parse the `[tag]` from the item line to infer the project dir, then:
```bash
python3 -c "
import sys, yaml
path = '<project_dir>/.backlog.yml'
try:
    cfg = yaml.safe_load(open(path)) or {}
except FileNotFoundError:
    print(False)          # no config — documented default
except Exception as e:
    print('CONFIG_ERROR: %s: %s' % (path, e), file=sys.stderr)
    sys.exit(1)           # malformed config must not be read as pr_required: false
else:
    print(cfg.get('pr_required', False))
"
```

A missing `.backlog.yml` is a normal case (use the defaults). A *malformed* one is
not: silently defaulting to `pr_required: false` would push straight to main on a
project that requires PRs. If this command exits non-zero, report the config error
and STOP without touching the item.

**If `pr_required: true`**: skip ScheduleWakeup here (Step 2 is the implement-phase crash-recovery wakeup). The git state check in Step 6 handles mid-implement crashes. Wakeups for PR merge-polling are scheduled separately in Step 1 when an OPEN pr-pending PR is found.

**If `pr_required: false` (default)**: call ScheduleWakeup now:
- `delaySeconds: 270`
- `prompt: "/backlog <same argument as current invocation>"` — file path or `owner/repo`

This ensures recovery if the session exhausts the rolling window mid-tick.

### Step 3 — Parse the item

**File mode:** extract `project` from `[tag]` and `feature` from the description (bold title if present, otherwise the full line text after the checkbox). `FEATURE_DETAIL` = indented lines captured in Step 1 (empty string if none).

**GitHub issues mode:** `project` = repo name (last segment of `owner/repo`). `feature` = issue title. `ISSUE_NUMBER` already set in Step 1. `FEATURE_DETAIL` = issue body (fetch with `gh issue view $ISSUE_NUMBER --repo $REPO --json body --jq '.body'`).

### Step 4 — GitHub issue: set in-progress label

**File mode:** look up `REPO` from the project map. If `—`, skip. Otherwise find or create an issue as before (search by feature title, create if not found). Then add `in-progress` label.

**GitHub issues mode:** `REPO` and `ISSUE_NUMBER` already known from Step 1. Add `in-progress` and remove `backlog` together:
```bash
unset GITHUB_TOKEN
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "in-progress" --remove-label "backlog" \
  || { echo "could not check out $REPO#$ISSUE_NUMBER — aborting before any code changes" >&2; exit 1; }
```

Abort here if the label swap fails: without it the issue stays queued and a
concurrent or later tick would implement the same item twice.

Pass `ISSUE_NUMBER` and `REPO` into the workflow for coder and releaser.

### Step 5 — Load project config and context

First, read project config. Check for `<project_dir>/.backlog.yml`:
```bash
python3 -c "
import sys, yaml
path = '<project_dir>/.backlog.yml'
try:
    cfg = yaml.safe_load(open(path)) or {}
except FileNotFoundError:
    print('NOT_FOUND')
except Exception as e:
    print('CONFIG_ERROR: %s: %s' % (path, e), file=sys.stderr)
    sys.exit(1)
else:
    print(yaml.dump(cfg))
"
```
Use values from the YAML if present; fall back to the project map for any missing fields.
As in Step 2, treat `NOT_FOUND` (no config file) as "use the fallback map" but treat a
parse error as fatal — report it and STOP rather than running with silent defaults.
Key values to resolve: `REPO`, `DEPLOY_CMD`, `BACKLOG_LABEL` (default: `backlog`), `PRIORITY_LABELS` (default: `[P0, P1, P2]`).

Then read `<project_dir>/CLAUDE.md` to understand architecture, build commands, test commands, and deploy pipeline before dispatching agents.

### Step 6 — Run the feature pipeline

**Before spawning any agents, check git state to detect a prior partial run** (e.g. from a session that was compacted mid-workflow). This makes recovery idempotent:

```bash
cd "<project_dir>" || exit 1

# Has the coder already committed for this feature?
# grep exiting 1 means "no match"; git itself failing means the state is unknown.
CODER_DONE=$(git log --oneline -5 | grep -i "\[backlog\]") || CODER_DONE=""

# Has the coder committed but the releaser not yet pushed?
# git log fails here when origin/main is absent (never fetched, renamed default
# branch). An empty UNPUSHED means "already pushed", so a swallowed failure would
# skip the release phase entirely — fetch first and abort if the ref is missing.
git fetch origin main --quiet || { echo "cannot reach origin — aborting tick" >&2; exit 1; }
git rev-parse --verify origin/main >/dev/null 2>&1 \
  || { echo "origin/main not found — resolve the base branch before running" >&2; exit 1; }
UNPUSHED=$(git log origin/main..HEAD --oneline | grep -i "\[backlog\]") || UNPUSHED=""
```

- If `UNPUSHED` is non-empty: **coder and tester already ran** — skip straight to Phase 3 (Release) only
- If `CODER_DONE` is non-empty but `UNPUSHED` is empty: push already happened, something else failed — proceed to Step 7 as SUCCESS
- If neither: normal first run — run all three phases

Run the three phases as sequential Agent tool calls (NOT the Workflow tool — agents consistently struggle to write Workflow scripts inline and fall back to Agent calls anyway; just use Agent directly).

**Cost tiering** (borrowed from the [Ringer](https://github.com/NateBJones-Projects/ringer) swarm-orchestrator pattern — expensive model plans/reviews, cheap workers implement): Phase 1 (Implement) and Phase 2 (Test) are mechanical, well-specified work off a clear brief — spawn them with `model: "haiku"`. Phase 3 (Release) is the last gate before something ships (git push to main, deploy commands) — keep it on the default/calling model, no override. If a Haiku-implemented feature is genuinely complex or the FEATURE_DETAIL signals real ambiguity, drop the override and let it run on the calling session's default model instead — don't force Haiku on tasks it's likely to get wrong, the point is cost savings on the routine cases, not blind downgrading.

**Phase 1 — Implement**

Spawn an Agent (`model: "haiku"` — see cost tiering above) with this brief:
- Read the project CLAUDE.md and relevant source files, then implement the feature
- Feature: `<feature>` (plain English title/description from the backlog line)
- If `FEATURE_DETAIL` is set, pass it verbatim as additional context (file paths, constraints, acceptance criteria)
- Make targeted changes — no scope creep
- Write or update tests alongside the feature
- Commit with message prefixed `[backlog]` — e.g. `[backlog] Add rate limiting to the API` — this prefix is used to detect prior runs after compaction
- If `ISSUE_NUMBER` is set, append `Closes <REPO>#<ISSUE_NUMBER>` as a footer line in the commit message
- Do NOT push
- Return "DONE: <one-line summary>" or "FAILED: <reason>"

**Phase 2 — Test**

Only run if Phase 1 returned DONE. Spawn an Agent (`model: "haiku"`) with this brief:
- Run the project's full test suite
- Verify the new tests pass and no regressions are introduced
- Return "PASSED" or "FAILED: <details>"

**Phase 3 — Release**

Only run if Phase 2 returned PASSED. Behaviour depends on `pr_required` from `.backlog.yml`:

**`pr_required: false` (default):** Spawn an Agent with this brief:
- `unset GITHUB_TOKEN && git push` direct to main
- Run the deploy command: `<DEPLOY_CMD>`
- Return "SUCCESS: deployed" or "FAILURE: <reason>"

**`pr_required: true`:** Spawn an Agent with this brief:
- Push to a feature branch: `git checkout -b backlog/<slug> && git push -u origin backlog/<slug>`
- Open a PR: `unset GITHUB_TOKEN && gh pr create --repo "$REPO" --title "<feature>" --body "Closes #$ISSUE_NUMBER\n\nAutomated via /backlog" --base main`
- Return "PR_PENDING: <pr_number>"

### Step 7 — Update state

On **SUCCESS** (pr_required false, all phases passed):
```bash
# File mode: mark done
- [ ] [project] feature  →  - [x] [project] feature

# GitHub (both modes)
unset GITHUB_TOKEN
gh issue close "$ISSUE_NUMBER" --repo "$REPO" --comment "✓ Released" \
  || echo "WARN: could not close $REPO#$ISSUE_NUMBER — close it manually" >&2
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
  --remove-label "in-progress" --remove-label "backlog" \
  || echo "WARN: could not clear labels on $REPO#$ISSUE_NUMBER — it will look in-progress" >&2
```

Don't hide these failures: the deploy already happened, so an unreported label or
close failure leaves the issue stuck `in-progress` and the next tick sees stale
state. Include any warning in the Step 8 notification.

On **PR_PENDING** (pr_required true, PR opened successfully):
```bash
# File mode: mark as [~] with PR reference
- [ ] [project] feature  →  - [~] [project] feature — PR #<pr_number> <REPO>

# GitHub issues mode: swap in-progress for pr-review-pending (review check fires first)
unset GITHUB_TOKEN
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "pr-review-pending" --remove-label "in-progress"
```

Auto-polling (two-stage): a ScheduleWakeup fires at `pr_poll_interval` seconds. First wakeup finds `pr-review-pending` → fetches and surfaces review findings → flips to `pr-pending` → schedules next wakeup. Subsequent wakeups find `pr-pending` → check for merge → deploy when merged. You can also run `/backlog` manually at any time to check immediately.

On **FAILURE** (any phase failed):
```bash
# File mode: mark failed
- [ ] [project] feature  →  - [!] [project] feature — <one-line reason>

# GitHub (both modes) — backlog already removed in Step 4; just swap in-progress for failed
unset GITHUB_TOKEN
gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "✗ Failed: <reason>" \
  || echo "WARN: could not comment on $REPO#$ISSUE_NUMBER" >&2
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
  --add-label "failed" --remove-label "in-progress" \
  || echo "WARN: could not mark $REPO#$ISSUE_NUMBER failed — it stays in-progress" >&2
```

A failure to record the failure is itself reportable — surface it in the Step 8
notification so the item doesn't sit `in-progress` forever unnoticed.

### Step 8 — Notify

Read `NOTIFY_CMD` from `.backlog.yml`. If absent, skip notification.

Otherwise substitute `{message}` in `NOTIFY_CMD` with the notification text and run it:

```bash
# On success:
MSG="Backlog [project]: <feature> — ✓ released"
# On failure:
MSG="Backlog [project]: <feature> — ✗ failed: <reason>"

# Substitute and run:
CMD="${NOTIFY_CMD//\{message\}/$MSG}"
eval "$CMD" || echo "WARN: notification command failed: $CMD" >&2
```

If the notify command fails, print the warning *and* the message it was carrying to
stdout — an unnotified outcome is otherwise indistinguishable from no outcome at all.
Include any Step 7 state-update warnings in `MSG`.

## Rate limit recovery

ScheduleWakeup is called at the very start (Step 2), before any work begins. If the session is killed mid-tick, the wakeup fires and retries. The pipeline is idempotent:
- File mode: item still `[ ]` → retry; `[x]`/`[!]` → skip
- GitHub issues mode: issue still open with `backlog` label → retry; `pr-pending` issues are caught by the dedicated first query in Step 1 and checked immediately; closed or `failed` issues are absent from both queries and skipped naturally

## Constraints

- One item per tick — never process multiple items in one invocation
- Never deploy without passing tests — mark `[!]`/`failed` and move on if tests fail
- Always notify on every outcome (success or failure)
- One commit per feature item, never squash
