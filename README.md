# Trace

**A native, private search and reading interface for your local AI coding
sessions.**

Trace brings Claude Code, Codex, and Gemini CLI history into one macOS app. It
builds a disposable SQLite/FTS5 index from the session files already on your
Mac, then lets you browse projects, search across transcripts, and return to the
exact message you need.

Trace is deliberately local and read-only. It has no account, cloud service,
updater, telemetry upload, or runtime network feature.

## Highlights

- Search Claude Code, Codex, and Gemini CLI sessions from one interface.
- Browse by project and session, with provider, message count, timestamp, and
  generated-plan metadata.
- Jump from a search result directly to the matching message in its transcript.
- Show or hide tool calls, system records, and reasoning independently.
- Switch between comfortable and compact transcript layouts.
- Copy a full visible transcript or the complete content of one message.
- Follow new and changed session files with incremental, checkpointed indexing.
- Keep source transcripts untouched and rebuild the local index at any time.

## Showcase

These screenshots were captured from the real app using an isolated, generated
fixture. They contain no private session data. The UI test
`testCaptureReadmeShowcaseWithoutTestControls` regenerates all four JPEGs in the
UI runner’s temporary `trace-readme-showcase/` folder, with test controls and the
mouse cursor excluded. Its console output prints `TRACE_README_SHOWCASE_DIRECTORY`
with the full capture path.

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/project-browser.jpg" alt="Trace project and session browser">
      <br><strong>Browse projects and sessions</strong><br>
      Move between provider sessions while keeping project and session context
      visible in the resizable sidebar.
    </td>
    <td width="50%" valign="top">
      <img src="docs/screenshots/search-results.jpg" alt="Trace cross-project search results">
      <br><strong>Search across local history</strong><br>
      See relevant messages grouped by project and session, with provider and
      timestamp context.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/transcript-view.jpg" alt="Trace comfortable transcript view">
      <br><strong>Read the surrounding conversation</strong><br>
      Open a result at its matching message and continue through the complete
      transcript.
    </td>
    <td width="50%" valign="top">
      <img src="docs/screenshots/compact-transcript.jpg" alt="Trace compact transcript view">
      <br><strong>Fit more context on screen</strong><br>
      Compact display reduces message insets and spacing without hiding
      transcript controls or metadata.
    </td>
  </tr>
</table>

## Supported sources

| Provider | Default source | Supported session files |
| --- | --- | --- |
| Claude Code | `~/.claude/projects` | JSONL |
| Codex | `~/.codex/sessions` | `rollout-*.jsonl` |
| Gemini CLI | `~/.gemini/tmp` | JSON and JSONL |

Trace discovers these locations during onboarding. Missing providers are fine;
you can build an index from any combination of available sources.

## How Trace works

1. Trace discovers the selected local agent directories.
2. You choose whether search should include prose only, prose and tool
   invocations, or everything except reasoning. Reasoning is never added to the
   search index.
3. Trace parses session metadata and messages into a disposable local database
   with FTS5 search.
4. A file watcher schedules incremental passes as sessions are created or
   appended. Source files always remain read-only.
5. Search results retain enough project, session, and message context to open
   the original conversation at the relevant point.

Deleting the index is safe. The next build recreates it from the source files;
Trace does not maintain a separate transcript archive.

## Using Trace

### Browse and search

The Projects filter matches project names. Selecting a project narrows the
session list and clears any open transcript. Drag the horizontal divider to
resize the Projects and Sessions panes.

The main search field searches the selected project, while global search stays
available from the menu-bar popover and launcher. Results are grouped by
project and session. Selecting a result opens the transcript at its matching
message.

The menu-bar popover keeps search and index status visible while its session
list scrolls. Session names prefer local provider title metadata, then fall back
to the first actual user message and finally the adapter-provided title. A Plan
badge is reserved for explicit generated plans rather than ordinary task lists
or planning-mode sessions.

### Read transcripts

Session views replace project search with transcript controls. Use **Back to
project** to restore browsing. A session opens at the top on its first visit and
remembers its viewport until Trace quits.

Tools, system records, and reasoning can each be shown or hidden. Reasoning is
only included by **Copy Transcript** when its disclosure is expanded. Use
**Copy Message** from a message or search-result context menu to copy its full
content, including collapsed tool and reasoning text.

Attachment-only records use a metadata-only placeholder; Trace does not store
or render their media. Hover over or click a session error indicator for the
provider, time, failure kind, and any available source explanation.

### Follow indexing progress

Indexing runs through a single scheduler. Watcher events coalesce behind the
active pass, JSONL batches commit a final checkpoint, and each pass reads only
the input boundary captured when it began. Small watcher passes update quietly;
longer work shows throttled progress.

Click the status indicator to see the current provider, project or file, byte
progress, and indexed/unchanged/failed counts. Project and session summaries
continue updating while indexing runs.

Metadata backfills preserve existing message IDs and search checkpoints.
Subsequent JSONL appends scan only the new metadata tail. Codex title sidecars
are read-only inputs, and SQLite WAL/SHM activity does not trigger index passes.
JSON metadata and SQLite database companions are opened nonblocking and checked
through their descriptors. A session index linked to `/dev/null` is an empty,
successful index; title databases can still supply complete metadata.

## Privacy and local data

Trace is intentionally unsandboxed so it can read the providers’ default data
directories without folder-bookmark prompts. The app does not write to those
directories.

| Data | Location |
| --- | --- |
| Disposable search index | `~/Library/Caches/me.haroldmartin.Trace/index.sqlite` |
| Optional pricing override | `~/Library/Application Support/Trace/pricing.json` |
| Private 30-day diagnostics | `~/Library/Application Support/Trace/diagnostics.json` |

Debug and Release builds share the stable bundle identifier and the same index,
independent of DerivedData or the app’s location. Ordinary launches reconcile
changed files. Only an explicit rebuild, a search-scope change, or an
incompatible index format resets indexed content. Quit an older build before
launching another build against the same database.

## Development

### Requirements

- macOS 15 or later on Apple silicon
- Xcode 26.3 or later
- XcodeGen 2.46.0
- Git submodules initialized recursively

### Build

```sh
git submodule update --init --recursive
Scripts/configure-grdb.sh
xcodegen generate
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

For a signed local build, copy `Config/Signing.xcconfig.example` to the ignored
`Config/Signing.xcconfig` and set `DEVELOPMENT_TEAM = MGPHJKUJSY`. Open the
generated project in Xcode, select the `Trace` scheme and **My Mac**, then Run.
Debug signing includes `get-task-allow` so Xcode can attach to Trace while the
hardened runtime stays enabled. `CODE_SIGNING_ALLOWED=NO` is useful for compile
checks but produces an app that cannot be debugged this way.

Local benchmark validation permits this ignored signing file with comments and
`DEVELOPMENT_TEAM` only, and records its SHA-256. Other signing-file build-setting
overrides and unknown build inputs are rejected.

The generated `Trace.xcodeproj` is committed. CI regenerates it and rejects
drift from `project.yml`; CI also checks the Debug and Release signing settings.

### Test

Run the core and headless app-model test suites with:

```sh
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme Trace \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TraceCoreTests \
  -only-testing:TraceAppTests \
  CODE_SIGNING_ALLOWED=NO
```

UI tests automatically isolate their database, sources, preferences, and
diagnostics. Set `TRACE_TEST_DIRECTORY` to use a fixed test directory whose
`Sources` folder contains `Claude`, `Codex`, and `Gemini` roots. The test-only
`--index-smoke` argument indexes that directory, prints a JSON summary, and
exits; it requires an isolated test directory and cannot use the production
cache.

Timing tests inject `TestClock` into the indexing and app models. Advance the
clock to release debounce, retry, and refresh delays, then await the separate
database or published-state completion. App-model tests compile without the
application entry point and use disposable databases, settings, and diagnostics.

Visual comparisons are local opt-in tests, separate from the normal Trace scheme
and CI. The generated showcase corpus covers project browsing, search, and both
transcript densities in light and dark mode:

```sh
Scripts/run-snapshot-tests.sh
# Explicitly replace references after an intentional visual/environment change:
Scripts/run-snapshot-tests.sh --record
```

Review all eight PNGs under `Tests/TraceSnapshotTests/__Snapshots__`, then run
comparison again. Comparisons never record missing or changed references. The
recorded environment includes macOS/Xcode versions, architecture, backing scale,
and window size; a mismatch requires reviewing and re-recording the full set.
Failure images and pixel diffs are attached to the `.xcresult` under
`build/snapshots/`. Keep the Trace window unobscured while captures run, and run
desktop test jobs serially because they share keyboard and mouse input. The
README JPEG capture remains a separate workflow.

Snapshot setup hydrates the complete fixture transcript before returning to the
initial viewport. Its native scrollbar is hidden while retaining its layout
space; scrolling behavior remains covered by the existing UI suite.

### Performance development

Run the repeatable performance suite with:

```sh
Scripts/run-performance-tests.sh
```

The script creates an isolated 10,000-message corpus, records cold-index and
recency/relevance search percentiles with `TraceBench`, and runs dedicated
search and transcript-scroll XCTest measurements for wall time, CPU, and
memory. Results are written below `build/performance/<timestamp>/`, including
an `.xcresult` bundle suitable for comparisons in Xcode.

For focused transcript scrolling and live follow work, run
`Scripts/measure-transcript-scroll.sh` on both revisions with the same Mac and
test corpus. It writes a Release `.xcresult`, `metrics.json`, and the build log
under `build/transcript-scroll/<timestamp>/`. Compare the exported app CPU and
clock measurements with
`Scripts/compare-transcript-scroll-metrics.py baseline/metrics.json candidate/metrics.json`.
The CPU metric targets `Trace.app`. The scroll benchmark drives the same
5,000-point viewport sweep on every iteration through a test-only app trigger,
so XCTest's accessibility hierarchy snapshots are outside the measured block.
The streaming measurement excludes audit file reads, but includes completion-marker
polling sleeps and XCTest's message-count wait. Inspect
the individual samples alongside the median. The measurements for this scroll
change are in [docs/transcript-scroll-performance.md](docs/transcript-scroll-performance.md).

Trace also emits privacy-safe Points of Interest signposts named `Database
Search`, `Interactive Search`, `Search Results Scroll Event`, `Transcript
Update`, `Transcript Restore`, and `Transcript Scroll Event`. Use the
Instruments Points of Interest or Time Profiler templates against a development
build to correlate slow interactions without recording queries, paths, or
transcript text.

### Release

`Scripts/release.sh` builds an Apple-silicon archive, exports a Developer ID
signed app, creates a DMG, notarizes, staples, and verifies it. Configure team
`MGPHJKUJSY` in `Config/Signing.xcconfig`, install its Developer ID Application
certificate, and create a `notarytool` keychain profile first.

### Local performance acceptance safeguards

Freeze the candidate commit, then run `python3 Scripts/run-local-benchmark-comparisons.py`.
It runs three Release pairs against `61c00de`, in baseline-first, candidate-first,
baseline-first order, and applies the local 10% tolerance described in `AGENTS.md`.
CI remains report-only for performance differences.

Each measured revision and pair has before/after input records covering the
captured commit, production sources, build configuration, initialized dependencies,
and synchronized harness. Acceptance requires matching records, including after
the third pair. Builds stay in the existing candidate checkout: these checks
cannot detect an edit fully reverted between observations. Do not edit the
candidate during measurements. A subsequent code change requires a new frozen
candidate and three fresh pairs.

Attempts retain raw samples, signed memory growth, hashes, logs, and failed-run
evidence. Both entry points validate candidate drift before applying the recognized
GRDB configuration and freezing inputs. Finder metadata does not change those inputs;
unexpected build settings and sources still fail validation.

New or incomplete baseline caches are prepared in a sibling staging directory under
a cache-specific advisory lock. The cache is published only after dependency checkout,
harness synchronization, configuration, and validation succeed. Interrupted staging
trees and their external preparation records are preserved; the next attempt prepares
a fresh tree. Missing and clone-without-checkout dependencies can recover this way;
wrong revisions and modified initialized dependencies remain errors.

Interrupted attempts stop their owned process group and detached app/test executables
under that attempt's derived-data directory, with bounded SIGINT, SIGTERM, and SIGKILL
escalation. Cancellation is deferred through cleanup and invalid host-record writing,
then propagated with its original signal exit code. Unrelated processes and artifacts
are preserved.

The defaults are three attempts per pair, a five-minute quiet-desktop timeout,
and a one-hour attempt timeout. Positive CLI overrides are `--max-attempts`,
`--quiet-timeout-seconds`, and `--attempt-timeout-seconds`. Build failures stop
immediately. Protected dialogs and foreign-window interruptions stop with a
diagnostic so the interruption can be resolved before restarting. Other host
contamination may retry within the configured attempt limit.
