# Privacy and networking

Trace has no runtime network feature, telemetry, cloud sync, updater, embedded web view, or source-file write path. The build is intentionally unsandboxed because it must directly read session roots owned by three independent command-line tools.

macOS only applies the outbound network client entitlement to sandboxed apps. Consequently, this architecture cannot express an OS-enforced deny-network entitlement while retaining direct source access. The release gate instead:

1. scans first-party Swift sources for networking APIs;
2. audits linked frameworks and binary imports;
3. exercises core flows under a deny-network test profile;
4. ships no runtime networking dependency.

Trace writes the disposable SQLite index to `~/Library/Caches/me.haroldmartin.Trace/index.sqlite`. Preferences, 30-day private diagnostics, and an optional launch-only `pricing.json` override live in user Library locations. Diagnostics contain aggregate latency buckets, counters, index size, and clean-launch markers—never search terms or transcript text.
