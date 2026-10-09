# Review fixes and clocks integration

The candidate is on `codex/review-comments-with-clocks`, based on main
`afd8b071bbdadd16948ee505ffd64d5a1cba5e86`. Original commits `880be1f` and
`195728a` were integrated as `d1be3c1` and `c09286d`. The original checkout and
its working-tree changes were preserved. No commits were pushed.

## Behavior and focused coverage

| Comment | Result and regression coverage |
| --- | --- |
| 1 | Background sidebar reads keep the footer available; explicit sidebar operations own visible loading. Headless tests verify availability during summary and transcript tails. |
| 2 | Same-criteria sidebar navigation retains three search pages and their identity. An uncommitted initial debounce restarts on return. |
| 3 | Production cancellation is retained. The UI delay hook emits a separate cancellation marker, and the corresponding UI test waits for cancellation. Headless tests reject publication after a project switch. |
| 4 | Session hydration, fingerprints, legacy Gemini reads, and coordinator append checks use nonblocking, close-on-exec, no-controlling-terminal descriptor opens with `fstat` validation. FIFO/device/directory rejection and descriptor cleanup run in bounded children; symlink target identity and retargeting are covered. The metadata-only actual `/dev/null` exception remains. |
| 5 | Appending messages reconfigures old rows when generation or hydration identity changes. A native table spy verifies pure append avoids old-row reloads and changed generation/locator reloads the affected rows. |
| 6 | Interrupted manual and automatic refreshes retain committed results, snippets, cursors, loaded pages, identity, and return anchors; retained results become stale. Successful explicit Refresh replaces the result identity and resets pagination. |
| 7 | Regular-file and terminal protections share one context-bearing SQLite overlay. Legacy insertion-only bytes are archived for exact recognition, never reversed from a live combined source. |
| 8 | Preparation accepts only reconstructed pristine, legacy, current, and interrupted per-file states from pinned SQLite source. Completed validation requires canonical bytes. Real-source tests cover upgrades, idempotence, unrelated edits, atomic cache publication, and interruption evidence. |
| 9 | Valid top-level fences are scanned first; their contents cannot trigger the expensive block parser. Ambiguous quote/list/indent contexts use Foundation source ranges as authority. Regressions cover quoted code, mixed spaces/tabs, nested lists, line endings, and four-space-indented fences. |
| 10 | SQLite terminal acquisition is inspected on the opened descriptor before closure. An isolated negative control removes `O_NOCTTY` and acquires the terminal. Metadata watcher opens also include `O_NOCTTY`. |
| 11 | Missing-project reconciliation preserves saved search state while reading a result, including terminal reconciliation, and leaves Refresh usable. |
| 12 | Background sidebar reads coalesce footer actions, prioritize Retry, and drop queued work on project changes. Retry resolves its ensured session from the current selection. Tests verify coalescing/priority and selection changes. |
| 13 | CLI cancellation handlers remain owned through cleanup and evidence finalization. Final blocked drains preserve the first signal, invalidate host/acceptance reports, and return `128 + signal`. Isolated tests exercise SIGINT/SIGTERM at cleanup, publication, unblock, and former handoff boundaries. |
| 14 | A replacement fixture retains session ID and message count while changing generation and locators. It verifies the existing generation guard forces transcript refetch. |
| 15 | Ordinary recency matches stay in indexed FTS row-ID order. Only matching exceptional rows use timestamp ordering; bounded candidates merge in canonical recency order. Live-row probes replace the sticky overflow flag. Tests cover unrelated/matching/deleted overflow rows, ties, clamped dates, deleted cursors, page ordering, and ordinary query plans. Relevance ordering is unchanged. |

Clock coverage uses `TestClock` at 99/100 ms debounce, 249/250 ms summary and
coordinator throttling, 299/300 ms progress visibility, one-second automatic
refresh, five-second scheduler retry/sidebar fallback, and 30-second metadata
cache expiry. Completion gates distinguish database completion from advancing
virtual time. Teardown cancels delayed work and checks for remaining suspensions.
App-model tests use isolated preferences, diagnostics, and fixture databases,
without normal startup or watchers. Representative structural comparisons use
`expectNoDifference` and test-only projections.

## Local headless verification — 2026-10-09

Host: arm64, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Deployment remains macOS 15; CI remains Xcode 26.3. The exact dependency pins
are Clocks 1.1.0, SnapshotTesting 1.19.6, CustomDump 1.7.0,
ConcurrencyExtras 1.4.1, and XCTestDynamicOverlay 1.11.0. The resolved graph also
contains SwiftSyntax 604.0.0 (manifest tools version 5.9).

- Core and app-model suites: **287 passed**, zero failures or skips.
- Script suites: **50 passed**.
- Generation sensitivity: removing the generation comparison caused the
  same-ID/count replacement test to fail because locators were not refetched.
- Terminal sensitivity: removing SQLite's `O_NOCTTY` addition caused the
  before-close probe to detect a controlling terminal and fail. Both mutations
  were reverted and the complete headless suites passed with guards restored.
- Package resolution, generated-project consistency, signing configuration,
  and source network audit passed.

- Release builds passed for `Trace`, `TraceBench`, `CodexRefreshBenchmark`, and
  `TraceExternalClientFixture`; the external-client Debug build also passed.
  Headless builds used `CODE_SIGNING_ALLOWED=NO`; Developer ID export/notarization
  was not performed. Debug/Release signing configuration checks passed.
- `TraceSnapshots` passed `build-for-testing` without executing its UI tests.
- The Release app binary passed the networking framework/symbol audit.

The 300,000 ordinary-match fixture passed canonical ordering and uniqueness for
three 200-result pages in each absent, unrelated, matching, and deleted overflow
state. Ordinary FTS plans used row-ID order without a temporary sort; exceptional
plans sorted only their restricted range. Clamped-date presence used two ranges
of the timestamp index. The obsolete metadata flag was removed in every state.

Timing samples were collected while unrelated builds were active, so they are
**contaminated diagnostics**, not valid timing acceptance evidence. The raw
reports explicitly record `timingValid: false` and competing processes. Clean
headless timing validation remains pending with the quiet-Mac acceptance work.

| Overflow state | Diagnostic median search, ms (100 iterations, 10 warm-ups) |
| --- | ---: |
| absent | 9.852 |
| unrelated | 16.996 |
| matching | 16.554 |
| deleted | 9.498 |

Cold Markdown probes used `swiftc -O`, 4,000 code rows, and ten fresh processes
per renderer per input, alternating baseline/candidate order. The baseline was
main `afd8b07`; all samples and source hashes are retained. Quoted-code output
changes intentionally preserve literal punctuation that the baseline rendered
as inline Markdown, so its timing is not a comparison of identical outputs.

| Input | Diagnostic main median, ms | Diagnostic candidate median, ms |
| --- | ---: | ---: |
| fenced | 75.104 | 51.530 |
| quoted | 226.117 | 131.583 |
| indented | 72.337 | 73.728 |


These headless probes are diagnostics, with no performance thresholds in CI.
They do not establish the repository's desktop Release acceptance. Detailed
local logs, result bundles, fixture databases, and timing samples are retained
under `build/verification/` in this worktree.

## Pending desktop acceptance

Run these serially on a quiet Mac; interrupted or contaminated runs cannot
establish acceptance:

1. Full UI suite and focused navigation, cancellation, and hydration regressions.
2. Review all eight integrated light/dark snapshot images. Explicitly record
   intentional changes, pass three consecutive strict comparisons, and prove a
   temporary visible change fails comparison with diff artifacts before reverting.
   Snapshot references currently retain their original macOS 27.0.1/Xcode 27.0,
   arm64, 2× environment. Snapshot execution remains outside the normal scheme
   and CI; comparison defaults to `.never`.
3. Freeze the candidate commit and run three Release pairs against `61c00de`,
   baseline-first, candidate-first, baseline-first, using the repository's local
   10% acceptance policy, `en_US`, and synchronized instrumentation. Preserve all
   samples, hashes, invalid attempts, and interruption evidence.
4. Validate with Xcode 26.3 when available. Local Xcode 27 results do not substitute
   for that toolchain check or runtime testing on macOS 15.

Native scroll/layout scheduling, SwiftUI restoration waits, and the daily safety
loop remain outside the clock migration. Calendar dates, persisted timestamps,
and performance clocks continue to use real time.
