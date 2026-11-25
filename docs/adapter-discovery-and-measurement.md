# Adapter discovery and reconciliation measurements

`SessionSource.supportsFileScopedDiscovery` defaults to `false`. Existing external
adapters receive containing-directory discovery requests for changed files. Trace
accepts only files and coverage within the original request. Returning an empty
successful directory discovery is authoritative classification; thrown errors and
reported discovery failures withhold coverage. Built-in sources opt into exact-file
requests, including deleted paths. An external adapter can opt in under the same
contract without changing its existing discovery/read methods.

Returned files must belong to the requested provider and a compatible configured
root. Canonical aliases and overlapping configured roots share the actual read
outcome. Incompatible identities produce discovery failure rather than successful
coverage. Direct built-in discovery follows full enumeration's hidden/package
policy; an explicitly configured hidden/package root remains eligible.

## Reproducing the optimized reconciliation harness

The decoded-row counter is measurement instrumentation, not a normal TraceCore API.
Apply the committed preparer to an isolated source export for **both** revisions:

```sh
python3 Scripts/prepare-reconciliation-benchmark.py --source-root /absolute/export --layout count-cache
xcodebuild build -project /absolute/export/Trace.xcodeproj -scheme Trace \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /absolute/products \
  'OTHER_SWIFT_FLAGS=$(inherited) -DTRACE_CHECKPOINT_BENCHMARK'
xcrun swiftc -O -parse-as-library -DTRACE_CHECKPOINT_BENCHMARK \
  -target arm64-apple-macos15.0 \
  -F /absolute/products/Build/Products/Release \
  -I /absolute/products/Build/Products/Release -framework TraceCore -framework GRDB \
  -Xlinker -rpath -Xlinker /absolute/products/Build/Products/Release \
  Scripts/benchmark-incremental-reconciliation.swift -o /absolute/incremental
/absolute/incremental 1000 candidate ascii
```

Create the export from the pinned Git revision, populate its configured recursive
vendor snapshot, and keep dependency Git metadata local to that snapshot so SQLite
overlay validation can read its pinned originals. Include the package frameworks
embedded in the built app in `DYLD_FRAMEWORK_PATH` when executing a standalone
binary. Record source, dependency, preparer, harness, toolchain and product hashes.
The preparer rejects Git checkouts, missing/duplicate anchors and conflicting
instrumentation; identical second preparation is a no-op. Do not edit the primary
checkout or silently reuse an instrumented framework from another revision.

Use `query-insensitive` and `query-unicode` to isolate a single stored-path query
over up to 1,000 scopes after corpus setup; `ascii` and `unicode` retain the
100-append end-to-end refresh workload. Query mode reports the exact scope count.

The counter counts materialized `IndexedSourcePath` values, not SQLite rows visited
or physical I/O. Predicate-count assertions run separately from accepted timings.
Reservation timing includes per-call latency sampling; validation and retirement
are separate phases. Correctness failures, including on a baseline, invalidate
performance samples. All workload exits unwind fixture cleanup before exiting.

Prepared UI provenance now uses format 2 with product-relative manifest names and
streaming hashes. An old receipt must be prepared again; reuse never rebuilds it.
The existing complete Debug inventory and before/after-case checks remain in place.

Use `--layout pr106` for the pinned #106 export and `--layout count-cache` for
the follow-up; missing or incompatible layouts fail before writing. Both layouts
use the same metric definitions. `query-sensitive-ascii` and
`query-sensitive-mixed` separate the first cold query from 100 warm queries.
Actual captured filesystem policies and forced SQL policies are reported
separately; forced queries do not establish physical mixed-volume coverage.

The follow-up's ASCII-sensitive fast path caches a count per provider/root, not
source-path copies. It classifies inside the same writer read snapshot as its
query and qualifies that count by connection identity and SQLite data_version.
Committed membership changes adjust known counts; content appends do not.
Other-writer commits invalidate qualification, and reset/root retirement removes
entries. Unicode-bearing roots retain fallback matching; this does not make
normalization-sensitive filesystems equivalent to APFS. No filesystem policy or
normalization semantics change is implied by the optimization.
