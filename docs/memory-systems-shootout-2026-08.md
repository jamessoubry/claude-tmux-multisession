# We tried three more memory systems this week. Here's what happened.

*2026-08-27*

The [memory architecture doc](memory-architecture.md) in this repo describes the stack I settled on: LCM for passive session capture, ICM for curated decisions, a plain-markdown wiki for long-form reference, QMD tying it together with search. That doc reads like a settled conclusion. It wasn't reached by reading blog posts and picking one — it was reached by installing things, watching what actually happened on a real host, and removing the things that didn't earn their keep. This week added three more data points: **memsearch**, **claude-mem**, and **MemPalace**. Two got installed and removed the same week; one got researched and passed on without installing. Here's the actual evidence for each call.

## Round 1: memsearch (Zilliz)

[memsearch](https://github.com/zilliztech/memsearch) is a markdown-first memory layer from the Milvus team — 2.5k stars, MIT. The pitch: memories live in plain `.memsearch/memory/*.md` files (git-friendly, human-editable), with a Milvus Lite vector index as a rebuildable "shadow" cache, not the source of truth. Hybrid search (dense vector + BM25 + reranking).

**Installed it.** CLI v0.4.19, Claude Code plugin, switched the embedding backend from the OpenAI default to local ONNX (no API cost, runs on-device). Confirmed it worked — indexed markdown content, semantic search returned correct results with good relevance scores.

**Then asked the obvious question: what does this replace?** Walking through it out loud surfaced the actual answer: nothing.

- Full-fidelity, lossless recall — already LCM's job, and specstory's.
- Curated, high-signal knowledge — already the wiki's job, and the wiki's value *is* the curation. memsearch's notes are auto-generated with none.
- Search over docs — already QMD's job, and QMD already does hybrid BM25+vector+rerank, not just keyword.

memsearch sits in the gap between "full capture" and "curated knowledge" — but that gap doesn't need filling, because the wiki already deliberately occupies it, just with a human in the loop instead of an LLM guessing what mattered. Running it meant a fourth thing auto-capturing every session (LCM, claude-mem, ICM's triggers, now memsearch) for a capability none of the other three lacked.

**Removed same day.** `claude plugin uninstall memsearch@memsearch-plugins`, stripped the marketplace entry from `settings.json`, deleted `~/main/.memsearch/`.

## Round 2: claude-mem (thedotmack)

This one had actually been sitting installed and enabled for a while from an earlier review — 91k GitHub stars, the most mainstream option in this space. This week was the first time it got tested head-to-head against LCM rather than just read about.

**What it does well, confirmed by testing, not marketing copy:** its `session_start_context` and `search` MCP tools returned genuinely well-structured output — dated, typed (bugfix/decision/discovery icons), stable IDs for progressive `get_observations()` expansion. It correctly tracked an entire install→evaluate→remove arc (memsearch's, as it happens) within minutes of it actually happening, accurately, no fabrication. This is a real, working product.

**What killed it: it duplicates LCM, and duplication has a real cost, not just a redundant one.**

The blog post that launched Zilliz's own memsearch plugin makes a sharp argument against claude-mem specifically: claude-mem's three-tier recall requires Claude to *decide* to call an MCP tool, versus a hook that injects context automatically for free. Good argument — except it doesn't apply here. Checking what was actually firing in *this* session's transcript: claude-mem's `SessionStart` hook was auto-injecting a context block automatically, same mechanism as LCM, same trigger point. Both were firing, unprompted, every session start. The "automatic beats tool-gated" argument was never actually a reason to prefer claude-mem over LCM — LCM already does the automatic part.

So the real comparison came down to infrastructure cost, and here the numbers were concrete, not hypothetical:

- Each Claude Code session spawns its own claude-mem Node MCP server **plus a separate ChromaDB process** (`chroma-mcp` via `uvx`, pulling in ONNX + protobuf).
- Checking live processes turned up **two orphaned pairs from four days earlier** — a dead session's MCP server and ChromaDB worker, never cleaned up, one of them having burned **9 minutes 44 seconds of CPU time** doing nothing useful in the background.
- Across six active tmux sessions, this meant up to twelve extra processes (six MCP servers, six ChromaDB workers) just to duplicate what LCM's single lightweight daemon already provides.

Nicer formatting isn't worth a second heavyweight process pair per session with a demonstrated failure mode (the orphan leak wasn't theoretical — it had already happened by the time anyone checked).

**Removed.** Plugin uninstalled, all six live claude-mem/chroma-mcp process pairs killed (the two current-session ones plus the two four-day-old orphans), `enabledPlugins` auto-cleaned by the uninstall.

## Round 3: MemPalace — researched, not installed

[MemPalace](https://github.com/mempalace/mempalace) is the one that didn't get an install-and-remove cycle, because the research alone answered the question. Launched April 2026 by Milla Jovovich and Ben Sigman, 40k stars in the first week, **58.7k stars and 7.5k forks** by the time I checked in August, with real ongoing engineering — eight releases since launch, the latest (v3.8.0) shipped four days before I looked, external contributors landing PRs daily.

The technical pitch is genuinely different from LCM, not just repackaged: verbatim storage (no AI summarization step at all) plus a real hybrid search — ChromaDB vector embeddings (pluggable models, hardware-accelerated) combined with SQLite FTS5 keyword match. That's a capability LCM actually doesn't have. Checked LCM's own dependency list to be sure rather than assume: no ONNX, no vector DB, nothing ML-related — its `search`/`grep` tools are FTS5 keyword ranking plus a DAG of summary nodes you drill into. It genuinely can't do "find the thing that means this" the way MemPalace can.

So why not install it? Because it wouldn't sit on top of LCM's existing data and add semantic search to it — it has its own independent capture pipeline, own hooks, own SQLite+ChromaDB store. Running it would mean a third system capturing the same conversations in parallel, the identical overlap problem that just got claude-mem and memsearch removed, just with better underlying tech. It would also mean giving up LCM's proven, load-bearing PreCompact hook integration (it saved this exact investigation from being lost mid-`/compact`) for a stack that hasn't been tested against this host's actual Claude Code hook surface at all.

**The one real gap it points at, left open rather than closed:** nothing here currently does semantic search over LCM's *own* session-capture data specifically. QMD's hybrid search covers the wiki and workspace docs; LCM's own store is keyword-only. If that ever becomes a real problem — "I know we discussed something like this but can't remember the words we used" — the smaller, more targeted fix is a thin embeddings layer over LCM's existing SQLite DAG, not installing a second full memory system next to it.

## What actually decided each case

Not vibes, not star counts, not marketing copy. Three concrete tests, applied every time:

1. **Does it replace something, or just duplicate it?** memsearch and claude-mem both duplicated a capability something else already had (full capture: LCM/specstory; curation: the wiki; search: QMD). MemPalace would have too, architecturally, even with better tech underneath.
2. **What does it actually cost to run, measured, not assumed?** claude-mem's real cost — a second heavyweight process pair per session, with an orphan-leak incident already on record — was found by checking `ps aux`, not by reading its docs.
3. **What's the switching cost against something already proven?** LCM's PreCompact hook has already saved a session mid-compaction, live, in production. That's a higher bar to clear than a benchmark number from someone else's palace.

None of this means the door's closed on any of these tools forever — MemPalace in particular is the most actively engineered thing in this space right now and is worth another look if the semantic-search gap ever actually bites. But "worth watching" and "worth running two of the same thing at once" are different conclusions, and this week kept them separate.

See [`memory-architecture.md`](memory-architecture.md) for the stack this converged back to.
