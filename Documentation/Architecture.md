# Architecture

Trace is a native menu-bar app backed by a reusable `TraceCore` framework. Its only durable content store is a disposable SQLite/FTS5 index; source sessions remain authoritative.

## Targets

- `Trace`: AppKit lifecycle and SwiftUI presentation, including onboarding, menu popover, global launcher panel, main reader, Costs, and Preferences.
- `TraceCore`: source adapters, streaming scanners, project canonicalization, indexing, FSEvents, search, hydration, pricing, and local diagnostics.
- `TraceBench`: opt-in cold-index and repeated-search harness for the local corpus.
- `TraceCoreTests` and `TraceUITests`: sanitized format/regression coverage and onboarding accessibility smoke coverage.

## Indexing flow

1. Discover enabled roots and fingerprint candidate files with device, inode, size, nanosecond mtime, stable-head length, and stable-head SHA-256.
2. Detect renames by device/inode. Tail unchanged append-only JSONL from its last complete-line byte offset; rebuild a source on truncation, replacement, or stable-head change.
3. Parse messages into independent prose, tool invocation, tool output, and reasoning sections, plus a non-text-content marker for attachment-only rows. The selected index scope is applied only to normalized text, and reasoning is never indexed.
4. Canonicalize an existing Git repository through its common Git directory, collapsing linked worktrees while keeping independent clones distinct. Fall back to normalized `cwd` when the repository is gone.
5. Commit small transactional batches. Message row IDs encode `(timestampMilliseconds << 20) | collisionOrdinal`, preserving global recency for late historical discoveries.
6. Store only list metadata, a 160-character preview, collapsed tool summary, locators, and contentless FTS postings. Full bodies are decoded from their smallest source byte range when visible or expanded.
7. Reconcile every root on launch, then coalesce low-latency file-level FSEvents into incremental refreshes. Event paths use symlink-resolved, case-folded comparison keys so macOS path aliases cannot hide changes.

## Search

Ordinary terms become quoted FTS5 prefix terms joined by `AND`; quoted phrases remain phrases. Agent, project, date, and error predicates run in the same statement. Recency uses row-ID keysets. Relevance uses `(BM25 score, row ID)` keysets. Pages are capped at 200 results and superseded UI searches are cancelled.

## Costs

Raw observations are deduplicated by agent plus external response ID before daily aggregation by local date, canonical project, model, and sidechain state. Gemini thought tokens are billed separately at the configured additional-reasoning rate; Claude and Codex reasoning is already included in output. Bundled USD rates are static release data. A complete replacement file may be supplied at `~/Library/Application Support/Trace/pricing.json`; it is validated once at launch, and invalid data falls back to the bundle with an exact visible error.

Every dollar value is labeled **estimated equivalent API spend**. A known zero-billing rate is `unmetered`; an unknown or incomplete model rate is `rate unavailable`.
The bundled Gemini Pro entries use the standard tier for prompts up to 200K tokens. Claude cache creation uses the five-minute write rate because the source observations do not preserve cache TTL.

## Renderer boundary

The transcript starts with SwiftUI `ScrollView` plus `LazyVStack`. `TranscriptRenderer` is deliberately isolated from selection and hydration state. The 4,000-message ProMotion release benchmark decides whether it remains or is replaced by an `NSTableView` implementation.

### Serialized indexing and additive details migration

`IndexScheduler` coalesces app requests into one active operation plus pending paths/full-reconciliation intent. Explicit rebuilds cancel and await the current operation. `IndexCoordinator` also owns a pass-level permit because actor isolation alone does not prevent reentrant indexing during database awaits. Progress callbacks are awaited in run order and throttled after the first committed batch.

JSONL adapters use pull-driven finite readers; no detached producer can queue the rest of a large file. Parsers emit record checkpoints, but only the final checkpoint of each transactional batch is written. Cancellation leaves committed batches readable and resumable. Gemini snapshots stream by chunk and replace indexed contents only after a complete full-file checkpoint. FSEvents retains the paths of recovery/directory events so reconciliation is limited to affected source roots.

The `trace-v2-details` migration adds section-presence metadata and session failure details/locators. `trace-v4-source-generation` adds a generation incremented only for content replacement. Live appends retain hydrated rows, while replacements invalidate them. Derived session metadata is keyed by external session ID and carries an independent `2:<content-generation>:<byte-checkpoint>` revision, so JSONL appends scan only their new tail and older metadata is backfilled without replacing message rows. Display titles resolve generated title, first user message, adapter fallback, then “Untitled session.” Legacy failure events hydrate from source only for sessions carrying legacy rows. Index format 2 intentionally performs a one-time disposable-content rebuild for corrected usage and section classification.
