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
3. Parse messages into independent prose, tool invocation, tool output, and reasoning sections. The selected index scope is applied only to those normalized sections, and reasoning is never indexed.
4. Canonicalize an existing Git repository through its common Git directory, collapsing linked worktrees while keeping independent clones distinct. Fall back to normalized `cwd` when the repository is gone.
5. Commit small transactional batches. Message row IDs encode `(timestampMilliseconds << 20) | collisionOrdinal`, preserving global recency for late historical discoveries.
6. Store only list metadata, a 160-character preview, collapsed tool summary, locators, and contentless FTS postings. Full bodies are decoded from their smallest source byte range when visible or expanded.
7. Reconcile every root on launch, then coalesce low-latency file-level FSEvents into incremental refreshes.

## Search

Ordinary terms become quoted FTS5 prefix terms joined by `AND`; quoted phrases remain phrases. Agent, project, date, and error predicates run in the same statement. Recency uses row-ID keysets. Relevance uses `(BM25 score, row ID)` keysets. Pages are capped at 200 results and superseded UI searches are cancelled.

## Costs

Raw observations are deduplicated by agent plus external response ID before daily aggregation by local date, canonical project, model, and sidechain state. Bundled USD rates are static release data. A complete replacement file may be supplied at `~/Library/Application Support/Trace/pricing.json`; it is validated once at launch, and invalid data falls back to the bundle with an exact visible error.

Every dollar value is labeled **estimated equivalent API spend**. A known zero-billing rate is `unmetered`; an unknown or incomplete model rate is `rate unavailable`.

## Renderer boundary

The transcript starts with SwiftUI `ScrollView` plus `LazyVStack`. `TranscriptRenderer` is deliberately isolated from selection and hydration state. The 4,000-message ProMotion release benchmark decides whether it remains or is replaced by an `NSTableView` implementation.
