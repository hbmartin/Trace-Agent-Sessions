import AppKit
import SwiftUI
import TraceCore

struct PreferencesView: View {
    @ObservedObject var model: TraceModel
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = false

    init(model: TraceModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        TabView {
            GeneralPreferences(model: model, settings: settings, launchAtLogin: $launchAtLogin)
                .tabItem { Label("General", systemImage: "gear") }
            SourcesPreferences(model: model, settings: settings)
                .tabItem { Label("Sources", systemImage: "externaldrive") }
            DiagnosticsPreferences(model: model)
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            launchAtLogin = settings.launchAtLoginEnabled
            model.refreshDiagnostics()
        }
    }
}

private struct GeneralPreferences: View {
    @ObservedObject var model: TraceModel
    @ObservedObject var settings: AppSettings
    @Binding var launchAtLogin: Bool

    var body: some View {
        Form {
            Section("Search") {
                Picker("Index scope", selection: $settings.indexScope) {
                    ForEach(IndexScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .onChange(of: settings.indexScope) { _, _ in model.rebuildIndex() }
                Picker("Default ordering", selection: $settings.searchSort) {
                    Text("Most recent").tag(SearchSort.recency)
                    Text("BM25 relevance").tag(SearchSort.relevance)
                }
                Toggle("Clear global search when closing popover and launcher",
                       isOn: $settings.clearGlobalSearchOnClose)
                Toggle("Clear search filters on close", isOn: $settings.clearGlobalFiltersOnClose)
            }

            Section("Global hotkey") {
                HStack {
                    Text("Open search")
                    Spacer()
                    HotkeyRecorderView(settings: settings)
                        .frame(width: 150, height: 30)
                }
                Text("Click the shortcut, then type a key with at least one modifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open Trace when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do { try settings.setLaunchAtLogin(enabled) }
                        catch { model.startupError = "Could not update the login item: \(error.localizedDescription)" }
                    }
            }

            Section("Privacy") {
                Label("Trace reads local session files and writes only its disposable index, preferences, diagnostics, and optional pricing override.", systemImage: "lock.shield")
                Text("The app contains no networking dependency or runtime network feature. Because this direct-access build is unsandboxed, macOS cannot enforce an outbound-network deny entitlement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourcesPreferences: View {
    @ObservedObject var model: TraceModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Source health") {
                VStack(spacing: 0) {
                    if model.sourceHealth.isEmpty {
                        Text("Source details appear after the first indexing pass.").foregroundStyle(.secondary).padding()
                    }
                    ForEach(model.sourceHealth) { health in
                        HStack(alignment: .top) {
                            AgentBadge(agent: health.agent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(health.rootPath).font(.caption.monospaced()).lineLimit(1)
                                Text(healthDescription(health)).font(.caption2).foregroundStyle(.secondary)
                                if let error = health.error { Text(error).font(.caption2).foregroundStyle(.red) }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if health.id != model.sourceHealth.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }

            GroupBox("Additional Claude Code roots") {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.additionalClaudeRoots.isEmpty {
                        Text("No additional roots").foregroundStyle(.secondary)
                    }
                    ForEach(settings.additionalClaudeRoots, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") {
                                settings.additionalClaudeRoots.removeAll { $0 == path }
                                model.reloadSourcesAndRebuild()
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    Button("Add Folder…", systemImage: "plus") { addClaudeRoot() }
                }
                .padding(8)
            }

            Spacer()
            HStack {
                if let statistics = model.statistics {
                    Text("\(statistics.messageCount.formatted()) messages · \(ByteCountFormatter.string(fromByteCount: statistics.databaseBytes, countStyle: .file)) index")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rebuild Index…") { model.rebuildIndex() }
            }
        }
        .padding()
    }

    private func addClaudeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Root"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !settings.additionalClaudeRoots.contains(url.path) {
            settings.additionalClaudeRoots.append(url.path)
            model.reloadSourcesAndRebuild()
        }
    }

    private func healthDescription(_ health: SourceHealth) -> String {
        let earliest = health.earliestSessionMilliseconds?.traceDate ?? "No indexed sessions"
        return "\(health.fileCount.formatted()) files · earliest \(earliest) · \(cleanupHorizon(for: health.agent))"
    }

    private func cleanupHorizon(for agent: AgentKind) -> String {
        guard agent == .claudeCode else { return "no configured cleanup horizon detected" }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let days = (object["cleanupPeriodDays"] as? NSNumber)?.intValue,
           days > 0 {
            return "\(days)-day configured cleanup horizon"
        }
        return "30-day default cleanup horizon"
    }
}

private struct DiagnosticsPreferences: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trace retains 30 days of local operational counters and latency histograms. Search terms and transcript text are never recorded.")
                .foregroundStyle(.secondary)

            Table(model.diagnosticsSnapshot.days) {
                TableColumn("Date", value: \.day)
                TableColumn("Searches") { Text($0.searchCount.formatted()) }
                TableColumn("Opens") { Text($0.openCount.formatted()) }
                TableColumn("Index size") {
                    Text(ByteCountFormatter.string(fromByteCount: $0.indexSizeBytes, countStyle: .file))
                }
                TableColumn("Unclean starts") { Text($0.uncleanLaunchesDetected.formatted()) }
            }

            if let pricingError = model.pricingError {
                Label(pricingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let pricing = model.pricing {
                Text("Bundled/override pricing effective \(pricing.effectiveDate). Overrides are read only at launch from \(PricingCatalog.defaultOverrideURL().path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Export…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Trace Diagnostics.json"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    model.exportDiagnostics(to: url)
                }
                Spacer()
                Button("Reset Diagnostics", role: .destructive) { model.resetDiagnostics() }
            }
        }
        .padding()
    }
}
