import AppKit
import SwiftUI
import TraceCore

struct MainView: View {
    @ObservedObject var model: TraceModel
    @State private var section: MainSection = .transcript

    var body: some View {
        NavigationSplitView {
            SessionSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Picker("Section", selection: $section) {
                        Text("Transcript").tag(MainSection.transcript)
                        Text("Costs").tag(MainSection.costs)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Spacer()
                    IndexProgressLabel(progress: model.progress)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                switch section {
                case .transcript: TranscriptView(model: model)
                case .costs: CostsView(model: model)
                }
            }
        }
        .alert("Trace", isPresented: Binding(
            get: { model.startupError != nil },
            set: { if !$0 { model.startupError = nil } }
        )) {
            Button("OK") { model.startupError = nil }
        } message: {
            Text(model.startupError ?? "")
        }
    }

    private enum MainSection { case transcript, costs }
}

private struct SessionSidebar: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Text("\(model.projects.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            TextField("Filter projects", text: $model.projectFilter)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("projectFilter")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            List(selection: $model.selectedProjectID) {
                Text("All Projects")
                    .tag(Int64?.none)
                ForEach(model.filteredProjects) { project in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.displayName).lineLimit(1)
                        Text("\(project.sessionCount.formatted()) sessions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(project.id))
                }
            }
            .frame(minHeight: 170, idealHeight: 230)
            .onChange(of: model.selectedProjectID) { _, value in model.selectProject(value) }

            Divider()
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Text("\(model.sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            List(selection: $model.selectedSessionID) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session, model: model)
                        .tag(Optional(session.id))
                }
            }
            .onChange(of: model.selectedSessionID) { _, value in
                if let value { model.selectSession(value) }
            }
        }
        .background(.background.secondary)
    }
}

struct TranscriptView: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.selectedProjectID == nil ? "Search all sessions" : "Search this project", text: $model.mainSearch.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("mainSearch")
                    .onChange(of: model.mainSearch.query) { _, _ in model.searchMain() }
                if !model.mainSearch.query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { model.mainSearch.query = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
            }
            .padding(14)
            Divider()
            if !model.mainSearch.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultList(model: model, search: model.mainSearch, maximum: .max, isMainSearch: true, selectedResultID: .constant(nil))
            } else if let session = model.selectedSession, session.id == model.selectedSessionID {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.title3.weight(.semibold)).lineLimit(1)
                        HStack {
                            AgentBadge(agent: session.agent)
                            Text("\(session.messageCount.formatted()) messages")
                            Text(session.lastActivityMilliseconds.traceDate)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal", systemImage: "folder") { model.revealSelectedSession() }
                    Button("Copy", systemImage: "doc.on.doc") { model.copyTranscript() }
                }
                .padding(16)
                HStack(spacing: 14) {
                    Toggle("Tools", isOn: $model.settings.showTools)
                    Toggle("System", isOn: $model.settings.showSystem)
                    Toggle("Reasoning", isOn: $model.settings.showReasoning)
                    Spacer()
                    Picker("Display", selection: $model.settings.transcriptDensity) {
                        ForEach(TranscriptDensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                Divider()
                TranscriptRenderer(model: model)
            } else {
                ContentUnavailableView("Search your agent history", systemImage: "text.magnifyingglass",
                    description: Text("Search above or select a session in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// Renderer boundary: this view can be replaced with an NSTableView implementation
// without changing the transcript or hydration models if ProMotion benchmarks require it.
private struct TranscriptRenderer: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: model.settings.transcriptDensity == .compact ? 6 : 14) {
                    ForEach(model.messages.filter { model.settings.transcriptVisibility.includes($0) }) { message in
                        MessageRow(
                            summary: message,
                            hydrated: model.hydratedMessages[message.id],
                            reasoningExpanded: Binding(
                                get: { model.expandedReasoningIDs.contains(message.id) },
                                set: { expanded in
                                    if expanded { model.expandedReasoningIDs.insert(message.id) }
                                    else { model.expandedReasoningIDs.remove(message.id) }
                                }
                            ),
                            visibility: model.settings.transcriptVisibility,
                            compact: model.settings.transcriptDensity == .compact,
                            hydrate: { model.hydrate(message) }
                        )
                        .id(message.id)
                        .onAppear { model.settings.lastScrollMessageID = message.id }
                    }
                }
                .padding(model.settings.transcriptDensity == .compact ? 12 : 20)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.map(\.id)) { _, _ in
                guard let target = model.settings.lastScrollMessageID,
                      model.messages.contains(where: { $0.id == target }) else { return }
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}

private struct MessageRow: View {
    let summary: MessageSummary
    let hydrated: HydratedMessage?
    @Binding var reasoningExpanded: Bool
    let visibility: TranscriptVisibility
    let compact: Bool
    let hydrate: () -> Void
    @State private var auxiliaryExpanded = false

    var body: some View {
        if hasVisibleContent {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24, height: 24)
                    .background(roleColor.opacity(0.14), in: Circle())
                    .foregroundStyle(roleColor)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(roleTitle).font(.caption.weight(.semibold))
                        if summary.hasError {
                            Label("Error", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Text(summary.timestampMilliseconds.traceDate)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    content
                }
            }
            .padding(compact ? 8 : 14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
            .task(id: visibility) {
                if !isLazyAuxiliary { hydrate() }
            }
        }
    }

    private var hasVisibleContent: Bool {
        guard let hydrated else { return true }
        let sections = hydrated.sections
        return !sections.prose.isEmpty
            || (visibility.tools && (!sections.toolInvocation.isEmpty || !sections.toolOutput.isEmpty))
            || (visibility.reasoning && !sections.reasoning.isEmpty)
    }

    @ViewBuilder private var content: some View {
        if let hydrated {
            if isLazyAuxiliary {
                DisclosureGroup(isExpanded: $auxiliaryExpanded) {
                    sectionContents(hydrated)
                } label: {
                    Text(summary.toolSummary ?? summary.prefix)
                        .font(.callout.monospaced())
                        .lineLimit(auxiliaryExpanded ? nil : 2)
                }
                .onChange(of: auxiliaryExpanded) { _, expanded in if expanded { hydrate() } }
            } else {
                sectionContents(hydrated)
            }
        } else if isLazyAuxiliary {
            DisclosureGroup(isExpanded: $auxiliaryExpanded) {
                ProgressView().controlSize(.small)
            } label: {
                Text(summary.toolSummary ?? summary.prefix)
                    .font(.callout.monospaced())
                    .lineLimit(2)
            }
            .onChange(of: auxiliaryExpanded) { _, expanded in if expanded { hydrate() } }
        } else if summary.sectionFlags == nil && (!visibility.tools || !visibility.reasoning) {
            // Legacy previews may contain a now-hidden section. Wait for hydration to classify it.
            ProgressView().controlSize(.small)
        } else {
            Text(summary.prefix).foregroundStyle(.secondary)
                .redacted(reason: summary.prefix.isEmpty ? .placeholder : [])
        }
    }

    @ViewBuilder private func sectionContents(_ message: HydratedMessage) -> some View {
        if !message.sections.prose.isEmpty { MarkdownText(source: message.sections.prose) }
        if visibility.tools && !message.sections.toolInvocation.isEmpty {
            DisclosureGroup("Tool invocation") {
                Text(message.sections.toolInvocation).font(.callout.monospaced()).textSelection(.enabled)
            }
        }
        if visibility.tools && !message.sections.toolOutput.isEmpty {
            DisclosureGroup("Tool output") {
                Text(message.sections.toolOutput).font(.callout.monospaced()).textSelection(.enabled)
            }
        }
        if visibility.reasoning && !message.sections.reasoning.isEmpty {
            DisclosureGroup(isExpanded: $reasoningExpanded) {
                Text(message.sections.reasoning).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Reasoning", systemImage: "brain")
            }
        }
    }

    private var isLazyAuxiliary: Bool {
        ([.toolResult, .toolUse].contains(summary.role) && visibility.tools)
            || [.system, .reasoning].contains(summary.role)
    }
    private var roleTitle: String { summary.role.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
    private var icon: String {
        switch summary.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .toolUse: "hammer.fill"
        case .toolResult: "terminal.fill"
        case .system: "gearshape.fill"
        case .reasoning: "brain.fill"
        }
    }
    private var roleColor: Color {
        switch summary.role {
        case .user: .blue
        case .assistant: TraceTheme.accent
        case .toolUse, .toolResult: .orange
        case .system: .secondary
        case .reasoning: .purple
        }
    }
}
