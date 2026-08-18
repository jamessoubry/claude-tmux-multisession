# Memory architecture: LCM + ICM + QMD + wiki

Four layers, each solving a different problem. None of them replace the others.

| Layer | Type | Trigger | Repo |
|---|---|---|---|
| LCM | passive session capture | automatic (background daemon) | [lossless-claude/lcm](https://github.com/lossless-claude/lcm) |
| ICM | active curated memory | manual, on specific events | [rtk-ai/icm](https://github.com/rtk-ai/icm) |
| Wiki | long-form reference | manual, when something's worth writing up | plain markdown, your own repo |
| QMD | search index | none — it's the retrieval layer over the wiki + session history | [tobi/qmd](https://github.com/tobi/qmd) |

## LCM — session continuity

Stores every message in SQLite, compacts sessions into a DAG of summaries, and promotes durable findings into cross-session memory. You don't call it during normal work — it runs as a daemon and gets swept via `lcm compact && lcm promote` (typically on a nightly cron).

Retrieval is via MCP tools in-session: `lcm_search` (broad recall), `lcm_grep` (exact term), `lcm_expand` (decompress a summary node).

**What it's for:** "what did we decide about X three sessions ago" without you having to remember to write it down.

## ICM — curated decisions

A manual store with mandatory-trigger discipline written into `CLAUDE.md`:

```markdown
You MUST call `icm store` when ANY of the following happens:
1. Error resolved → icm store -t errors-resolved -c "..." -i high -k "keywords"
2. Architecture/design decision → icm store -t decisions-{project} -c "..." -i high
3. User preference discovered → icm store -t preferences -c "..." -i critical
4. Significant task completed → icm store -t context-{project} -c "..." -i high
```

The discipline matters more than the tool — ICM without the trigger rules in your CLAUDE.md just becomes another place things silently don't get written down.

**What it's for:** the stuff LCM *would* eventually surface, but you want guaranteed, immediately, tagged, and searchable — not dependent on a compaction cycle noticing it was important.

## Wiki — long-form reference

Just markdown files in a directory (Karpathy's "LLM-maintained wiki" pattern — Claude reads and writes it directly, no special tooling required beyond an `index.md` catalogue). Used for anything that deserves a proper writeup: a tool comparison, an infra runbook, a project's full architecture.

**What it's for:** content, not memory. The difference matters — LCM/ICM answer "what happened," the wiki answers "how does X work" or "what's the current state of Y."

## QMD — the retrieval layer

QMD doesn't store anything new — it indexes what already exists: your wiki, SpecStory-generated session history markdown, and any other workspace docs. Hybrid search (BM25 + vector + LLM rerank), fully local.

```bash
qmd search "topic" -c knowledge -n 3   # search the wiki collection
qmd search "topic" -c workspace -n 5   # search everything indexed
```

**What it's for:** finding the right document fast, across a wiki + session-history corpus that's grown too large to scan manually.

## How they compose

A typical flow: LCM silently captures a debugging session → the root cause gets explicitly `icm store`d because it's a mandatory trigger → if it's substantial enough to be worth a full writeup (not just a one-liner), it also gets written to the wiki as a proper page → QMD indexes that page so future sessions can find it by search instead of by memory recall alone.

If you're only going to adopt one piece: start with ICM + a `CLAUDE.md` trigger list. It's the cheapest to set up (no daemon) and gives the highest signal-to-noise ratio.
