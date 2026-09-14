import ServiceManagement
import SwiftUI
import TraceCore

struct OnboardingView: View {
    @ObservedObject var model: TraceModel
    let completion: @MainActor () -> Void
    @State private var enableLoginItem = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(TraceTheme.accent)
                    .frame(width: 72, height: 72)
                    .background(TraceTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Find any agent session.")
                        .font(.largeTitle.weight(.bold))
                    Text("Trace builds a disposable, private search index from files already on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Detected sources").font(.headline)
                ForEach(detectedSources, id: \.agent) { source in
                    HStack {
                        AgentBadge(agent: source.agent)
                        Text(source.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: source.detected ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(source.detected ? .green : .secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("What should be searchable?").font(.headline)
                Picker("Index scope", selection: $model.settings.indexScope) {
                    ForEach(IndexScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .pickerStyle(.radioGroup)
                Text("Reasoning is never added to the search index. Source files remain read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Open Trace automatically when I log in", isOn: $enableLoginItem)

            Spacer()
            HStack {
                Label("No cloud, telemetry, updater, or network runtime", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Build Index") {
                    model.completeOnboarding(enableLoginItem: enableLoginItem)
                    completion()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(minWidth: 680, minHeight: 520)
    }

    private var detectedSources: [(agent: AgentKind, path: String, detected: Bool)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let entries: [(AgentKind, URL)] = [
            (.claudeCode, home.appendingPathComponent(".claude/projects")),
            (.codex, home.appendingPathComponent(".codex/sessions")),
            (.gemini, home.appendingPathComponent(".gemini/tmp")),
        ]
        return entries.map { ($0.0, $0.1.path, FileManager.default.fileExists(atPath: $0.1.path)) }
    }
}
