# Trace 1.0 ROADMAP.md

## Summary

Trace 1.0 will be the fastest private macOS reader and search tool for large,
multi-agent local histories.

All listed priorities are release requirements. Priority indicates
implementation order, not optionality. Effort is expressed as S/M/L/XL, with
no calendar estimates.

## Prioritized Roadmap

### P0 — Transcript search and selective export

#### In-session find — L

- Provide a full `Cmd+F` bar with occurrence count, highlighting,
  next/previous controls, Enter/Shift-Enter navigation, and case-insensitive
  substring matching.
- Search only sections enabled by transcript filters; search reasoning only
  when it is visible.
- Search collapsed enabled sections and temporarily reveal the active match.
- Include expanded inline sub-agent transcripts, but not collapsed
  descendants.
- Preserve existing cross-session search performance and privacy guarantees.

#### Selective export — L

- Add an explicit Select mode with individual selection and Shift-range
  selection across visible rows.
- Keep selection transient and clear it when leaving the transcript.
- Allow expanded child transcripts to be selected only as whole transcripts.
- In readable mode, save or copy Markdown containing complete selected
  messages, including hidden sections and metadata-only attachment
  placeholders.
- In exact mode, create an atomic folder package containing byte-exact file
  fragments or exact SQLite field bytes plus `manifest.json`.
- Define manifest version 1 to record provider, session/message identifiers,
  ordering, source-relative location, byte range or SQLite table/key/column
  provenance, and SHA-256 hashes.
- Fail exact export without leaving a final package if any selected source
  changed or became unreadable.
- Remember the last export format and destination; show no privacy warning or
  automatic redaction.

#### Structured global search — M

- Add `agent:`, `project:`, `after:`, `before:`, and `error:` operators.
- Synchronize operators bidirectionally with existing chips and controls.
- Permit operator-only searches and quoted project names.
- Show inline errors for unknown, malformed, or conflicting operators.
- Retain current prefix FTS, quoted phrases, filters, recency, and BM25
  ranking.

### P1 — Reader navigation and structure

#### Tool-block clarity — M

- Preserve message boundaries while adding tool names, semantic icons, and
  raw/formatted toggles.
- Defer syntax highlighting and specialized diff rendering.

#### Configurable keyboard layer — L

- Cover find, match/message/prompt/session movement, selection, export,
  density cycling, and shortcut help.
- Ship Trace, Vim, and AgentsView presets.
- Allow complete remapping using single keys or modified chords.
- Reject duplicate and reserved shortcuts and suppress unmodified navigation
  keys while editing text.

#### Inline sub-agent relationships — XL

- Record relationships only when providers emit explicit parent/child
  identifiers.
- Anchor children at known spawn records; place unanchored explicit children
  in a related-sub-agents section.
- Keep children collapsed by default and allow recursive expansion at every
  depth.
- Never infer relationships from timestamps, project names, or transcript
  text.
- Support independent and rolled-up analytics; default to including child
  work and rolling it into top-level parents.

### P2 — Shared provider and analytics foundations

- Replace Claude-specific custom-root settings with per-provider default
  enablement and custom roots while preserving existing configuration.
- Add disposable-index support for explicit session relationships, provider
  capability reporting, per-session analytics facts, and exact-export
  locators.
- Use an index-format bump and rebuild rather than migrating transcript
  content.
- Introduce persisted shared analytics filters for date, project, provider,
  child work, and attribution mode.
- Expand Source Health to report partial parsing, unsupported capabilities,
  malformed records, and source-format drift without adding transcript
  badges.

### P3 — Required provider and analytics expansion

#### Providers

- OpenCode: support current stable storage only, including SQLite-backed
  messages.
- Copilot CLI: support current stable session JSONL and available local usage
  data.
- Grok CLI: support the current `~/.grok/sessions` hierarchy, including
  summary-only sessions when full history is unavailable.
- Amp: automatically discover and live-index the last known local thread-JSON
  layout, explicitly labeled as legacy-format support.
- Use best-effort field coverage without guessing missing metadata, usage,
  errors, or costs.
- Pin each supported format/version in fixtures and
  `Documentation/SourceFormats.md`.

#### Unified Analytics area

- Replace Costs with Activity, Tools, Costs, and Health views sharing
  persisted filters.
- Activity: session-count heatmap and hour-of-week grid with message totals in
  detail popovers.
- Tools: normalized Read/Edit/Write/Shell/Search/Web/Task/Other categories
  with raw provider-name details.
- Costs: per-session estimates, cache efficiency, and top sessions by spend;
  keep costs out of transcript headers.
- Keep pricing manual and local; add an explicit Reload Pricing action with
  validation.
- Use conservative `Healthy`, `Needs Review`, and `Failed` health states:
  - `Failed`: explicit terminal provider failure or abort.
  - `Needs Review`: observed non-terminal errors, repeated identical failed
    tool calls, or repeated same-file edits associated with failure.
  - `Healthy`: no supported negative signal was observed; it does not claim
    task completion.
- Show aggregate detail popovers from charts without navigating into filtered
  session lists.

### P4 — Release hardening

- Extend fixture, regression, UI, accessibility, and performance coverage for
  every new workflow.
- Preserve existing benchmark budgets for global search, first paint,
  hydration, scrolling, idle CPU, and memory.
- Add a 4,000-message find benchmark targeting cold first results within 500
  ms and cached query updates within 100 ms.
- Verify exact exports by re-reading fragments and comparing hashes and bytes.
- Run network-surface, deny-network, project-drift, core, UI, and performance
  checks.
- Confirm Trace never writes provider source files and introduces no runtime
  networking dependency.

## Explicitly Not in 1.0

Defer semantic/hybrid search, regex and additional query fields, find overview
rails, export-by-search-match, persistent selections, HTML/PDF export, syntax
highlighting, specialized diff views, focused mode, live status/follow-latest,
local MCP, web-chat imports, publishing, sync/team features, session
rename/trash/resume, localization, and cross-platform support.

## Assumptions and Inputs

- Trace 1.0 remains macOS 15+, Apple silicon, local-only, read-only toward
  provider data, and zero-network.
- Existing Claude Code, Codex, and Gemini support remains intact.
- Partial-provider limitations appear only in Source Health.
- The roadmap is grounded in the
  [comparison report](</Users/haroldmartin/.codex/attachments/56f2fc76-f268-4870-9931-7532680023ea/Pasted text.txt>),
  [architecture](/Users/haroldmartin/Downloads/Trace-Agent-Sessions/Documentation/Architecture.md),
  [performance budgets](/Users/haroldmartin/Downloads/Trace-Agent-Sessions/Documentation/Benchmarks.md),
  [privacy contract](/Users/haroldmartin/Downloads/Trace-Agent-Sessions/Documentation/PrivacyAndNetworking.md),
  [source-format notes](/Users/haroldmartin/Downloads/Trace-Agent-Sessions/Documentation/SourceFormats.md),
  and current
  [AgentsView format references](https://github.com/kenn-io/agentsview/blob/main/docs/internal/session-format-sources.md).
- Progress coordination followed the
  [long-task-voice-progress skill](/Users/haroldmartin/.codex/skills/long-task-voice-progress/SKILL.md).
