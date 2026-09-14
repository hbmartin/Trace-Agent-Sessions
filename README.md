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
