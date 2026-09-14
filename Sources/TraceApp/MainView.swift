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
                    if model.selectedSessionID != nil {
                        Button("Back to project", systemImage: "chevron.left") { model.clearSession() }
                            .accessibilityIdentifier("backToProject")
                    } else {
                        Picker("Section", selection: $section) {
                            Text("Transcript").tag(MainSection.transcript)
                            Text("Costs").tag(MainSection.costs)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    Spacer()
                    IndexProgressLabel(progress: model.progress)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                if model.selectedSessionID != nil {
                    TranscriptView(model: model)
                } else {
                    switch section {
                    case .transcript: TranscriptView(model: model)
                    case .costs: CostsView(model: model)
                    }
                }
            }
        }
        .onChange(of: model.selectedSessionID) { _, id in
            if id != nil { section = .transcript }
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
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.height - 7)
            let minimum = min(180.0, available / 2)
            let height = min(available - minimum, max(minimum, available * model.settings.projectPaneFraction))
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Projects").font(.headline)
                        Spacer()
                        Text("\(model.projects.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(12)
                    TextField("Filter projects", text: $model.projectFilter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("projectFilter")
                        .padding(.horizontal, 12).padding(.bottom, 8)
                    List(selection: Binding(get: { model.selectedProjectID }, set: { model.selectProject($0) })) {
                        ForEach(model.filteredProjects) { project in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.displayName).lineLimit(1)
                                Text("\(project.sessionCount.formatted()) sessions").font(.caption2).foregroundStyle(.secondary)
                            }.tag(Optional(project.id))
                        }
                    }
                }.frame(height: height)
                Rectangle().fill(.separator).frame(height: 7)
                    .overlay(Capsule().fill(.secondary).frame(width: 28, height: 2))
                    .contentShape(Rectangle())
                    .accessibilityLabel("Projects and sessions divider")
                    .accessibilityIdentifier("projectSessionDivider")
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.05 : -0.05
                        model.settings.projectPaneFraction = min(0.8, max(0.2, model.settings.projectPaneFraction + delta))
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sessionSidebar"))
                        .onChanged { value in
                            if dragStart == nil { dragStart = height }
                            guard available > 0 else { return }
                            model.settings.projectPaneFraction = min(available - minimum, max(minimum, (dragStart ?? height) + value.translation.height)) / available
                        }
                        .onEnded { _ in dragStart = nil })
                VStack(spacing: 0) {
                    HStack {
                        Text("Sessions").font(.headline)
                        Spacer()
                        Text("\(model.sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(12)
                    List(selection: Binding(get: { model.selectedSessionID }, set: { id in
                        if let id { model.selectSession(id) }
                    })) {
                        ForEach(model.sessions) { session in
                            SessionRow(session: session, model: model).tag(Optional(session.id))
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: "sessionSidebar")
        .background(.background.secondary)
    }
}

struct TranscriptView: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedSessionID == nil {
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
            }
            if model.selectedSessionID == nil && !model.mainSearch.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultList(model: model, search: model.mainSearch, maximum: .max, isMainSearch: true, selectedResultID: .constant(nil))
            } else if let session = model.selectedSession, session.id == model.selectedSessionID {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.title3.weight(.semibold)).lineLimit(1)
                        HStack {
                            AgentBadge(agent: session.agent)
                            if session.hasPlan { PlanBadge() }
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
                TranscriptRenderer(model: model, sessionID: session.id)
                    .id(session.id)
            } else {
                ContentUnavailableView("Search your agent history", systemImage: "text.magnifyingglass",
                    description: Text("Search above or select a session in the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TranscriptBookmark {
    let messageID: Int64
    let offset: CGFloat
    let index: Int
}

private struct MessageFrames: PreferenceKey {
    static let defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TranscriptRenderer: View {
    @ObservedObject var model: TraceModel
    let sessionID: Int64
    @State private var position = ScrollPosition(edge: .top)
    @State private var contentOffset: CGFloat = 0
    @State private var frames: [Int64: CGRect] = [:]
    @State private var pending: TranscriptBookmark?
    @State private var restoring = true
    @State private var userScrolling = false
    @State private var lastRequest: UUID?

    private var visibleMessages: [MessageSummary] {
        model.messages.filter { model.settings.transcriptVisibility.includes($0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: model.settings.transcriptDensity == .compact ? 6 : 14) {
                ForEach(visibleMessages) { message in
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
                        hydrate: { model.hydrate(message) },
                        copyMessage: { model.copyMessage(id: message.id) }
                    )
                    .contextMenu { Button("Copy Message") { model.copyMessage(id: message.id) } }
                    .id(message.id)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MessageFrames.self, value: [message.id: geometry.frame(in: .named("transcriptContent"))])
                    })
                }
            }
            .scrollTargetLayout()
            .padding(model.settings.transcriptDensity == .compact ? 12 : 20)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .coordinateSpace(name: "transcriptContent")
        }
        .accessibilityIdentifier("transcriptScroll")
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
            contentOffset = offset
            if userScrolling { savePosition() }
        }
        .onScrollPhaseChange { oldPhase, phase in
            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if userScrolling { restoring = false; pending = nil }
            if phase == .idle && (oldPhase == .interacting || oldPhase == .decelerating) { savePosition() }
        }
        .onPreferenceChange(MessageFrames.self) { newFrames in
            frames = newFrames
            if let pending, let frame = frames[pending.messageID] {
                position.scrollTo(y: max(0, frame.minY - pending.offset))
                self.pending = nil
                restoring = false
            } else if !userScrolling, !restoring,
                      let bookmark = model.scrollPositions[sessionID], let frame = frames[bookmark.messageID] {
                // Hydration changes row heights above the viewport. Hold the same visible anchor.
                let target = max(0, frame.minY - bookmark.offset)
                if abs(target - contentOffset) > 1 { position.scrollTo(y: target) }
            } else if !userScrolling, !restoring, let bookmark = model.scrollPositions[sessionID],
                      visibleMessages.contains(where: { $0.id == bookmark.messageID }) {
                pending = bookmark
                restoring = true
                position.scrollTo(id: bookmark.messageID, anchor: .top)
            }
        }
        .onAppear { restore() }
        .onChange(of: model.scrollRequest) { _, _ in restore() }
        .onChange(of: visibleMessages.map(\.id)) { _, ids in
            if let bookmark = model.scrollPositions[sessionID], !ids.contains(bookmark.messageID) {
                restore(force: true)
            }
        }
    }

    private func restore(force: Bool = false) {
        guard force || lastRequest != model.scrollRequest else { return }
        lastRequest = model.scrollRequest
        let ids = visibleMessages.map(\.id)
        guard !ids.isEmpty else { restoring = false; return }
        var bookmark = model.scrollPositions[sessionID]
        if let target = model.requestedMessageID, ids.contains(target), !force {
            bookmark = .init(messageID: target, offset: 0, index: model.messages.firstIndex(where: { $0.id == target }) ?? 0)
        }
        guard let saved = bookmark else {
            position.scrollTo(edge: .top)
            restoring = false
            return
        }
        let visibleIDs = Set(ids)
        let nearest = model.messages.enumerated().filter { visibleIDs.contains($0.element.id) }
            .min { abs($0.offset - saved.index) < abs($1.offset - saved.index) }?.element.id
        let target = ids.contains(saved.messageID) ? saved.messageID : (nearest ?? ids[0])
        pending = .init(messageID: target, offset: saved.offset, index: model.messages.firstIndex(where: { $0.id == target }) ?? 0)
        model.scrollPositions[sessionID] = pending
        restoring = true
        position.scrollTo(id: target, anchor: .top)
        if let frame = frames[target] {
            position.scrollTo(y: max(0, frame.minY - saved.offset))
            pending = nil
            restoring = false
        }
    }

    private func savePosition() {
        guard !restoring, pending == nil,
              let first = frames.filter({ $0.value.maxY > contentOffset + 1 }).min(by: { $0.value.minY < $1.value.minY }),
              let index = model.messages.firstIndex(where: { $0.id == first.key }) else { return }
        model.scrollPositions[sessionID] = .init(messageID: first.key, offset: first.value.minY - contentOffset, index: index)
    }
}

private struct MessageRow: View {
    let summary: MessageSummary
    let hydrated: HydratedMessage?
    @Binding var reasoningExpanded: Bool
    let visibility: TranscriptVisibility
    let compact: Bool
    let hydrate: () -> Void
    let copyMessage: () -> Void
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
        if !message.sections.prose.isEmpty { MarkdownText(source: message.sections.prose, copyMessage: copyMessage) }
        if visibility.tools && !message.sections.toolInvocation.isEmpty {
            DisclosureGroup("Tool invocation") {
                SelectableMessageText(text: AttributedString(message.sections.toolInvocation), monospaced: true, copyMessage: copyMessage)
            }
        }
        if visibility.tools && !message.sections.toolOutput.isEmpty {
            DisclosureGroup("Tool output") {
                SelectableMessageText(text: AttributedString(message.sections.toolOutput), monospaced: true, copyMessage: copyMessage)
            }
        }
        if visibility.reasoning && !message.sections.reasoning.isEmpty {
            DisclosureGroup(isExpanded: $reasoningExpanded) {
                SelectableMessageText(text: AttributedString(message.sections.reasoning), secondary: true, copyMessage: copyMessage)
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
