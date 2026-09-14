# Trace

Trace is a native, read-only macOS session viewer for Claude Code, Codex, and
Gemini CLI. It builds a disposable local SQLite/FTS5 index of the files those
agents already write, then lets you search and read the original transcripts.

Trace has no account, cloud service, updater, telemetry upload, or runtime
network feature. It is intentionally unsandboxed so it can read the default
agent data directories without folder-bookmark prompts.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 26.3 or later
- XcodeGen 2.46.0
- Git submodules initialized recursively

## Build

```sh
git submodule update --init --recursive
Scripts/configure-grdb.sh
xcodegen generate
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

The generated `Trace.xcodeproj` is committed. CI regenerates it and rejects
drift from `project.yml`.

## Local data

- Disposable search index: `~/Library/Caches/me.haroldmartin.Trace/index.sqlite`
- Optional pricing override: `~/Library/Application Support/Trace/pricing.json`
- Private 30-day diagnostics: `~/Library/Application Support/Trace/diagnostics.json`

Deleting the index is safe; Trace will rebuild it from the source files. Source
deletions are mirrored and no transcript archive is retained.

## Release

`Scripts/release.sh` builds an Apple-silicon archive, signs it with Developer
ID, creates a DMG, notarizes, staples, and verifies it. Configure a signing team
in `Config/Signing.xcconfig` and a `notarytool` keychain profile first.

## Search, transcript display, and development builds

The menu popover keeps search and index status visible while its session list scrolls. The main window searches the selected project; the Projects filter matches project names only. Drag the horizontal divider to resize the Projects and Sessions panes. Global search remains available in the popover and launcher.

Selecting a project clears the open transcript. Session views hide project search and the Transcript/Costs toggle; Back to project restores browsing. Sessions open at the top on their first visit, remember their viewport until Trace quits, and search results jump directly to the matching message.

Session names use available local Codex, Claude, and Gemini title metadata, falling back to the first actual user message. A Plan badge marks explicit generated plans, not task checklists or planning mode. Metadata backfills preserve existing message IDs and search checkpoints. Codex title sidecars are read only.

Transcript controls independently show or hide tools, system records, and reasoning. Comfortable is the default spacing; Compact reduces card padding and gaps. Copy Transcript omits hidden sections and includes reasoning only when its disclosure is expanded. Right-click a message or search result and choose Copy Message to copy its complete text, including collapsed tool and reasoning content. Hover over a session’s error icon for the provider, time, failure kind, and available source explanation.

Indexing runs through a single scheduler. Watcher events coalesce behind the active pass, complete JSONL records commit with their checkpoints, and each pass reads only its captured input boundary. Project/session summaries update during indexing. Click the status indicator for provider, project/file, byte progress, and indexed/unchanged/failed counts.

Debug and Release builds share the stable bundle identifier and `~/Library/Caches/me.haroldmartin.Trace/index.sqlite`, independent of DerivedData or the app’s location. The details migration preserves existing message IDs, FTS postings, and checkpoints. Ordinary launches reconcile changed files; only an explicit rebuild, scope change, or incompatible index format resets content. Quit the older build before launching another build against the same index.

UI tests automatically isolate their database, sources, preferences, and diagnostics. A fixed test directory can be supplied with `TRACE_TEST_DIRECTORY`; its `Sources` directory contains `Claude`, `Codex`, and `Gemini` roots. The test-only `--index-smoke` launch argument indexes that directory, prints a JSON summary, and exits. It requires an isolated test directory and does not operate on the production cache.
