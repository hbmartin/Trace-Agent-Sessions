# Trace improvement ideas

_Compiled 2026-09-25 from a read-only review of the docs, `ROADMAP.md`, and the
`TraceCore` and `TraceApp` sources._

`ROADMAP.md` already covers in-session find, selective export, structured
search, sub-agents and analytics, so this focuses on what it doesn't cover or
what would make it easier to build. Timing numbers come from throwaway tests on
synthetic data with the same FTS5 configuration, not from a real session corpus.

## Bugs confirmed during review

_Status updated 2026-10-08. All nine confirmed bugs and the three additional
review concerns below have fixes and regression coverage._

1. **Fixed: Markdown whitespace.** The renderer now uses
   `.inlineOnlyPreservingWhitespace`. Paragraph breaks, list markers and code
   fences remain visible, with inline styling, native selection and copy.
   Full paragraph, heading, list and code-block styling is deferred.
2. **Fixed: punctuation terms emptying search.** Terms without Unicode letters
   or digits are discarded, including quoted punctuation. Discarding also
   clears the term buffer. Quoting, escaping, AND and prefix matching are
   preserved; punctuation-only input produces no search pattern.
3. **Fixed: undated records drifting into the future.** All four source formats
   carry forward the last valid timestamp, including timestamps on metadata
   and ignored records. Before that, they use one fixed file-mtime fallback.
   Missing or malformed dates do not advance the context. Both timestamps are
   committed atomically with byte checkpoints, restored after append/restart
   and reset after replacement. Direct offset reads recover preceding context.
4. **Fixed: the 500-session cap.** The sidebar loads 200-row keyset pages,
   displays the exact database total and offers Load more with loading and
   retry states. It retains an externally selected session outside loaded
   pages, rejects stale completions and refreshes the loaded page count after
   index changes. Cursor ordering includes session ID for tied activity dates.
5. **Fixed: main-search navigation losing results.** Back to results retains the
   original scope, query, filters, ordering, loaded pages and scroll anchor.
   Index updates mark retained results stale for explicit refresh. Rebuilds
   discard old IDs/cursors and rerun the retained criteria. Explicit project
   changes end the return context; global-search close preferences still apply.
6. **Fixed: session deletes scanning usage observations.** Schema v18 adds
   `idx_usage_session` on `usage_observation(session_id)`. The SQLite delete
   plan uses this index for the cascade lookup.
7. **Fixed: singular session labels.** Project rows show “1 session” and
   “0/2/… sessions.”
8. **Fixed: test controls and cursor in README images.** The four screenshots
   use generated fixtures and an isolated showcase capture mode that hides test
   controls. Window captures exclude the cursor and are visually inspected.
9. **Fixed: personal roadmap links.** [ROADMAP.md](ROADMAP.md) uses
   repository-relative documentation links, without personal attachment or
   skill citations.
10. **Fixed: Codex calls deduplicating their outputs away.** Source keys include
    response-item type, followed by `id`, `call_id` or byte offset. Calls and
    outputs sharing a call ID both persist and hydrate, while repeated logical
    records still deduplicate. Raw external IDs are retained.
11. **Fixed: Gemini diagnostic roles.** `user` maps to user; `gemini` and
    `assistant` to assistant; `info`, `warning` and `error` to system. Error
    records set the error flag. Unknown types are skipped under the documented
    adapter drift policy.
12. **Fixed: message-read failures opening alerts.** Each failed message shows
    its error and Retry alongside the available preview. Row appearances do
    not retry known failures. Explicit Retry, source-path changes and content
    generation changes invalidate failures; stale completions are rejected.

Schema v18 stores timestamp checkpoint context. Index format 7 uses the existing
automatic rebuild to repair previously stored timestamps, roles and missing
Codex outputs. Source transcripts remain read-only. An entirely undated source
keeps its first-index mtime through appends; a full rebuild may change that
fallback because the source contains no event date.

Regression coverage lives in [TraceCoreTests](Tests/TraceCoreTests/TraceCoreTests.swift),
[IndexingRegressionTests](Tests/TraceCoreTests/IndexingRegressionTests.swift) and
[TraceUITests](Tests/TraceUITests/TraceUITests.swift). Full block Markdown rendering
remains outside these fixes.

Initial checkout validation on 2026-10-08: all 174 core tests pass. Across the full UI suite and
focused reruns, 65 of 67 UI tests pass, including every new regression test.
The divider-drag assertion in `testCopyMessageIncludesCollapsedContentAndDividerPersists`
and visibility assertion in `testForcedVisibilityRestoreIgnoresHiddenSearchTarget`
also fail in an isolated copy of the pre-fix working tree. That checkout also
has pre-existing scheme formatting differences. The PR preserves the originating
workspace and applies only these fixes to current main, whose project drift and
signing checks pass. The TraceBench Release build, external-client API
typecheck, static/binary network checks and deny-network smoke test pass. All
four regenerated showcase images were visually inspected.

## Practical: search

- **Only prefix-match the last term.** Every bare term becomes `"term"*`. On a
  300k-message synthetic corpus, `"the"*` took about 30 ms versus 0.2 ms for an
  exact match, and relevance search took about 200 ms. The FTS budget is 20 ms
  and was only benchmarked at 12k messages.
- **Show snippets around the match, with highlighting.** The FTS table is
  contentless, so `snippet()` isn't available and results show the start of the
  message; the match may not be visible at all. After loading the text, put it
  in a temporary FTS5 table and run `snippet()`/`highlight()` with the same
  query.
- **Split `body` into `prose`, `tool_in` and `tool_out` columns.** This gives:
  - ranking that weights prose above tool output;
  - `tool:` filters for the roadmap's structured search;
  - index-scope changes that become a query-time filter instead of a full
    rebuild.
- **Add a trigram side index for code and CJK.** Today `Effect` doesn't find
  `useEffect`, and `修复` doesn't match in the middle of a run of characters.
- **Push date filters into FTS using rowid ranges.** The rowid already encodes
  the timestamp.
- **Keep relevance pages stable** with one `DatabaseSnapshot` per search.
  SQLite snapshots are already compiled in but unused.
- **Explain empty results.** With the default prose-only scope, searching a
  filename finds nothing and gives no reason. Say "tool calls aren't indexed"
  and offer to include them.
- **Index the values in tool-call JSON, not the keys.** Keys like `file_path`
  and `old_string` are noise in every result.
- **SQLite housekeeping:**
  - use `'delete-all'` instead of deleting rows one by one (measured 0.65 s →
    0.01 s for 200k rows);
  - run `optimize` after a cold build and `merge` when idle;
  - add `PRAGMA optimize` and `journal_size_limit`.
- **Shrink the rowid shift.** `ts<<20` made the FTS index about twice the size
  of dense rowids in a synthetic test; 8–10 bits is plenty.

## Practical: indexing

- **Parse each byte once.** Every indexed byte is decoded twice, once by the
  adapter and again by `SessionMetadataReader`.
- **Codex re-parses each file from the start on every append** to recover its
  context (`CodexSource.swift:41-45`). Save that context on the source row, as
  Gemini already does.
- **About 11 SQL statements per message.** Cache project and session IDs per
  batch, update each session once per batch, and use `cachedStatement`.
- **Cache `ProjectCanonicalizer` results per working directory.** It walks the
  filesystem for every record today.
- **Update usage rollups incrementally.** Today almost every pass rebuilds
  `usage_daily` in full.
- **Stop the UI from slowing indexing.** Progress is awaited twice per file and
  reloads summaries on the main thread; send the latest value without waiting.
- **Let reads run alongside writes.** `IndexDatabase` is an actor, so searches
  wait behind write batches even though WAL allows concurrent readers. Make
  reads `nonisolated`.
- **For cold builds, parse files in parallel and funnel writes through a single
  writer.**
- **Safer tailing:** append detection only hashes the first 4 KiB; also hash
  the bytes just before the checkpoint.
- **Rebuild without a blank app:** build into a separate database and swap it
  in when done. Use the unused `adapter_version` column so changing one adapter
  only reindexes its own files.
- **Cap line length** in `JSONLineCursor`; a huge base64 line is currently
  loaded whole.

## Practical: reader and app

- **Standard menu commands** (there are almost none):
  - ⌘F / ⌘K to search
  - ⌘[ to go back
  - ⇧⌘C to copy the transcript
  - ⌥⌘1–3 to toggle Tools, System and Reasoning
  - ⌘+ / ⌘− for text size
- **Onboarding that leads somewhere.** After Build Index nothing opens, and it
  never mentions the menu-bar icon or ⌘⇧Space. Also honor `CLAUDE_CONFIG_DIR`
  and `CODEX_HOME` instead of hard-coded paths.
- **Right-click menus on sidebar rows:** Reveal in Finder, Copy Session ID,
  Open Project in Terminal, and **Copy Resume Command** (`claude --resume
  <id>`). That gives most of "resume" while staying read-only.
- **Next/previous-match buttons** inside the transcript. Back to results is
  now implemented.
- **Long messages:** collapse them past N lines, and move to TextKit 2 so only
  visible text is laid out.
- **Easier to scan:**
  - user prompts styled differently from other messages;
  - day separators with time-only timestamps;
  - a jump list of prompts for long sessions;
  - a native toolbar in place of the stacked header rows (about 180 pt tall).
- **Costs:**
  - show cache-write and cache-read columns; they usually dominate Claude
    spend, so the visible columns don't add up to the total;
  - make columns sortable and add a chart;
  - make "7 days" mean the same thing in Costs and in search.
- **Menu-bar icon that shows state** (indexing, error), plus a Recent Sessions
  submenu.
- **Hotkey:** report when the shortcut can't be registered, and show key names
  for the user's actual keyboard layout (AZERTY and Dvorak users currently see
  the wrong letters).
- **Settings:** confirm before a scope change starts a full rebuild.
- **Remember UI state:** window size and position, the Transcript/Costs choice,
  and scroll positions across launches.
- **Accessibility:**
  - VoiceOver rotors for Prompts, Errors and Matches;
  - make the hover-only error indicator a real button;
  - support Increase Contrast;
  - adjustable text size.
- **Pinned sessions and notes**, kept in a small separate store rather than the
  disposable index.

## Practical: code health and tests

- **Build a small adapter interface before adding the four P3 providers.**
  Adding a provider currently touches at least 7 files, with about 21
  provider-specific branches in the indexing and database code. A descriptor
  holding formats, default roots, capabilities, version and a
  `parse(line, context)` function would let new providers be added mostly on
  their own.
- **Split the large files:**
  - `IndexDatabase`: 2,002 lines
  - `TraceModel`: 1,840 lines
  - `MainView`: 1,719 lines, about 900 of them scroll-restoration logic that
    could become a pure, testable struct
  - `IndexCoordinator.run`: about 455 lines
- **Move to `@Observable`.** Today every progress update and message load
  re-renders almost the whole UI.
- **Get test hooks out of production code.** There are 72 `TraceTestHooks`
  references in `Sources`.
- **Replace timing hacks with explicit "ready" signals.** In the app,
  `scrollTo` is called 8 times at 100 ms intervals; the UI tests have 13
  `Thread.sleep` calls.
- **Differential tests:**
  - indexing a file in random append-sized pieces should give the same result
    as indexing it whole;
  - an incremental index should match a cold rebuild.

  The recent run of recovery-hardening PRs suggests this is where regressions
  happen.
- **More test coverage:**
  - fuzz tests for the line and document scanners (CRLF, invalid UTF-8, giant
    lines);
  - a fixed set of search-quality test queries;
  - sanitized real fixtures for each CLI version.
- **Report parse failures.** `ParseDiagnostic` exists but is never produced;
  turn the swallowed `try?` decode failures into per-file counts in Source
  Health.
- **Performance baselines:** there are no saved Xcode baselines, and the perf
  corpus is much smaller than the documented 4,000-message budget.
- **Check `FSEventsWatcher` with Thread Sanitizer.** It passes an unretained
  `self` to a C callback and changes `stream` outside its lock.
- **Merge schema migrations v1–v12 into one baseline.** The index is disposable
  anyway.

## Practical: tooling and release

- CI runs twice per PR (on `push` and `pull_request`). Add
  `concurrency: cancel-in-progress`, a regular Thread Sanitizer run, and saved
  TraceBench numbers so trends are visible.
- Add SwiftFormat or SwiftLint.
- Add an `AGENTS.md`/`CLAUDE.md` with the build commands and the project's
  rules (source files read-only, no network, disposable index). The history is
  heavily agent-driven, and each agent currently rediscovers these.
- Tag releases and keep a CHANGELOG; the version is still 0.1.0. A **Homebrew
  cask** would give users updates while the app stays network-free.
- Add a String Catalog for plurals, a light/dark accent color, an Icon Composer
  icon and a custom menu-bar glyph.

## Imaginative

1. **Blame → conversation.** Point at a line of code and Trace shows the
   session that wrote it, by matching Edit/Write tool calls to the file path and
   git history.
2. **File-centric history.** Pull file paths out of tool calls to answer "every
   session that touched `src/auth.ts`", and show which files agents keep
   re-reading.
3. **Trace as agent memory.** A `trace` command-line tool plus an MCP server
   over stdio, so Claude or Codex can ask "how did we fix this last time?"
   Stdio keeps the no-network promise. The roadmap defers local MCP, but it may
   be the most valuable thing to build after 1.0.
4. **CLAUDE.md suggestions.** Spot corrections repeated across sessions ("use
   pnpm", "stop mocking the DB") and suggest them as project rules, copied to
   the clipboard.
5. **Transcripts that show branches.** Claude sessions are trees linked by
   `parentUuid`, which isn't parsed today, so rewinds and edited prompts show up
   mixed together. Show the forks, and offer an "active path only" view.
6. **Mission control.** A live view of every running agent session: which is
   working, which is waiting on you, and which is stuck retrying the same
   failing command, with notifications.
7. **Session replay.** Scrub through a session on a timeline: prompts, tool
   calls, files touched, token usage and context compaction.
8. **Context-window graph.** Plot tokens per turn with compaction points
   (`isCompactSummary`, also not parsed today).
9. **On-device summaries** with Apple's Foundation Models framework (macOS
   26+): a short summary per session, better titles and a weekly digest, all
   without network.
10. **Local semantic search** with `NLContextualEmbedding`, for when you don't
    remember the exact words.
11. **Secret-exposure scanner.** Flag API keys that appeared in tool output
    (for example an agent running `cat .env`), per session.
12. **Agent head-to-head.** Compare cost, turns and error rate for Claude,
    Codex and Gemini on the same repo, or put two sessions side by side.
13. **Link sessions to commits and PRs.** Use `gitBranch`, Codex's
    `session_meta.git`, and `git commit` / `gh pr create` tool calls, shown as
    links with nothing fetched.
14. **Get into Trace from outside the app:**
    - a Quick Look extension for `.jsonl` session files;
    - Spotlight results for session titles;
    - Shortcuts actions;
    - `trace://` deep links, which Raycast and Alfred could use.
15. **Early warning for format changes.** Record the CLI `version` on each
    record and count unknown record types, so Source Health can say "Claude
    Code 2.3 added record types Trace ignores."
16. **Providers defined in JSON.** A mapping of paths and fields so simple
    providers need no Swift code.
17. **A prompt library, a menu-bar activity indicator, and shareable session
    "receipt" images.**

## Suggested order

1. Completed: the twelve reviewed bugs above. Full block Markdown styling
   remains deferred.
2. Snippets around the match plus prefix-matching only the last term, which are
   the biggest visible search improvements.
3. The adapter interface and multi-column FTS before the roadmap's new
   providers and structured search, since both get cheaper to build on top of
   them.
4. The "incremental equals cold rebuild" test.
5. Then one bigger bet: Trace as agent memory (Imaginative #3) or blame →
   conversation (Imaginative #1).
