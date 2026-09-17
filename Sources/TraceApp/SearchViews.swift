import SwiftUI
import TraceCore

struct RecentPopoverView: View {
    @ObservedObject var model: TraceModel
    @ObservedObject private var search: SessionSearchModel
    @FocusState private var searchFocused: Bool

    init(model: TraceModel) {
        self.model = model
        search = model.globalSearch
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all sessions", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { NotificationCenter.default.post(name: .traceShowLauncher, object: nil) }
                    .onChange(of: search.query) { _, _ in model.search() }
            }
            .padding(12)
            .background(.quaternary.opacity(0.45))

            if search.hasActiveFilters {
                HStack {
                    Text("Search filters active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { model.clearGlobalSearchFilters() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }

            Group {
                if !search.query.isEmpty {
                    SearchResultList(model: model, search: model.globalSearch, maximum: 10, usesNativeScrolling: true, selectedResultID: .constant(nil))
                        .id(search.resultSetID)
                } else {
                    NativeScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RECENT SESSIONS")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                            if model.recentSessions.isEmpty {
                                ContentUnavailableView("No sessions indexed", systemImage: "clock.arrow.circlepath")
                            } else {
                                ForEach(model.recentSessions.prefix(10)) { session in
                                    Button { model.selectSession(session.id, showWindow: true) } label: {
                                        SessionRow(session: session) { await model.sessionErrorText(session) }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(-1)

            Divider()
            HStack {
                IndexProgressLabel(progress: model.progress)
                Spacer()
                Button("Open Trace") {
                    NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .traceFocusPopover)) { _ in searchFocused = true }
    }
}

struct LauncherView: View {
    @ObservedObject var model: TraceModel
    @ObservedObject private var search: SessionSearchModel
    @ObservedObject private var settings: AppSettings
    @FocusState private var searchFocused: Bool
    @State private var selectedResultID: Int64?

    init(model: TraceModel) {
        self.model = model
        search = model.globalSearch
        settings = model.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Search Claude Code, Codex, and Gemini", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onChange(of: search.query) { _, _ in model.search() }
                    .onSubmit { openSelectedResult() }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
            }
            .padding(18)

            Divider()

            HStack(spacing: 8) {
                ForEach(AgentKind.allCases) { agent in
                    FilterChip(
                        title: agent.displayName,
                        selected: search.filters.agents.contains(agent)
                    ) {
                        if search.filters.agents.contains(agent) {
                            search.filters.agents.remove(agent)
                        } else {
                            search.filters.agents.insert(agent)
                        }
                        model.search()
                    }
                }
                FilterChip(title: "Errors", selected: search.filters.errorsOnly) {
                    search.filters.errorsOnly.toggle()
                    model.search()
                }
                Menu {
                    Button("All projects") { selectProject(nil) }
                    Divider()
                    ForEach(model.projects) { project in
                        Button(project.displayName) { selectProject(project) }
                    }
                } label: {
                    Label(selectedProjectName, systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(SearchDatePreset.allCases) { preset in
                        Button(preset.title) { selectDate(preset) }
                    }
                } label: {
                    Label(search.datePreset.title, systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Picker("Sort", selection: $settings.searchSort) {
                    Text("Recent").tag(SearchSort.recency)
                    Text("Relevant").tag(SearchSort.relevance)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
                .onChange(of: settings.searchSort) { _, _ in model.search() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            if search.query.isEmpty {
                ContentUnavailableView(
                    "Search your agent history",
                    systemImage: "text.magnifyingglass",
                    description: Text("Words are prefix-matched together. Put phrases in quotes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SearchResultList(model: model, search: model.globalSearch, maximum: .max, selectedResultID: $selectedResultID)
                    .id(search.resultSetID)
            }
            Divider()
            HStack {
                IndexProgressLabel(progress: model.progress)
                Spacer()
                if TraceTestHooks.isUITesting {
                    Button("Rebuild Index") { model.rebuildIndex() }
                        .accessibilityIdentifier("testRebuildIndex")
                }
                Text("↩ Open  ·  esc Close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 30, y: 12)
        .onAppear { searchFocused = true }
        .onChange(of: search.results.map(\.id)) { _, ids in
            if let selectedResultID, ids.contains(selectedResultID) { return }
            selectedResultID = ids.first
        }
        .onExitCommand { NotificationCenter.default.post(name: .traceHideLauncher, object: nil) }
    }

    private var selectedProjectName: String {
        if let name = search.projectFilterDisplayName { return name }
        guard let key = search.projectFilterCanonicalKey else { return "All projects" }
        return model.projects.first(where: { $0.canonicalKey == key })?.displayName
            ?? "Selected project"
    }

    private func selectProject(_ project: ProjectSummary?) {
        search.selectProject(project)
        model.search()
    }

    private func selectDate(_ preset: SearchDatePreset) {
        search.datePreset = preset
        model.search()
    }

    private func moveSelection(by delta: Int) {
        let results = search.results
        guard !results.isEmpty else { return }
        let current = selectedResultID.flatMap { selected in results.firstIndex(where: { $0.id == selected }) } ?? -1
        let next = min(results.count - 1, max(0, current + delta))
        selectedResultID = results[next].id
    }

    private func openSelectedResult() {
        guard let selectedResultID,
              let result = search.results.first(where: { $0.id == selectedResultID }) else { return }
        model.openSearchResult(result)
    }
}

enum SearchDatePreset: String, CaseIterable, Identifiable {
    case anyTime
    case sevenDays
    case thirtyDays
    case yearToDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .yearToDate: "Year to date"
        }
    }

    func bounds(now: Date) -> (from: Int64?, to: Int64?) {
        let calendar = Calendar.current
        let start: Date?
        switch self {
        case .anyTime:
            return (nil, nil)
        case .sevenDays:
            start = calendar.date(byAdding: .day, value: -7, to: now)
        case .thirtyDays:
            start = calendar.date(byAdding: .day, value: -30, to: now)
        case .yearToDate:
            start = calendar.date(from: calendar.dateComponents([.year], from: now))
        }
        return (
            start.map { Int64($0.timeIntervalSince1970 * 1_000) },
            Int64(now.timeIntervalSince1970 * 1_000)
        )
    }
}

private struct SnippetHydrationKey: Hashable {
    let id: Int64
    let sourcePath: String
    let prefix: String
    let timestampMilliseconds: Int64

    init(_ result: SearchResult) {
        id = result.id
        sourcePath = result.sourcePath
        prefix = result.prefix
        timestampMilliseconds = result.timestampMilliseconds
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selected ? TraceTheme.accent.opacity(0.2) : .clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? TraceTheme.accent : .secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}

struct SearchResultList: View {
    @ObservedObject var model: TraceModel
    @ObservedObject var search: SessionSearchModel
    let maximum: Int
    var isMainSearch = false
    var usesNativeScrolling = false
    @Binding var selectedResultID: Int64?
    @State private var searchPosition = ScrollPosition(edge: .top)
    @State private var contentOffset: CGFloat = 0
    @State private var resultFrames: [Int64: CGRect] = [:]
    @State private var savedAnchor: SearchResultAnchor?
    @State private var pendingAnchor: SearchResultAnchor?
    @State private var pendingAnchorToken = UUID()
    @State private var nativeScrollCommand: NativeScrollCommand?

    var body: some View {
        if search.isResolvingProjectFilter && search.results.isEmpty {
            ProgressView("Updating project…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("projectFilterResolving")
        } else if search.isSearching && search.results.isEmpty {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = search.error {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if search.results.isEmpty {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try another word or project."))
        } else {
            VStack(spacing: 0) {
                if TraceTestHooks.isUITesting,
                   TraceTestHooks.environment["TRACE_TEST_PAGINATION_LIVE_QUERY"] != nil {
                    Button("Test pagination criteria") {
                        search.mutateLiveCriteriaAndLoadMoreForTesting()
                    }
                    .accessibilityIdentifier("testPaginationCriteria")
                }
                if search.isResolvingProjectFilter {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating project…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("projectFilterResolving")
                } else if search.resultsMayBeStale {
                    HStack {
                        Text("Results may be out of date.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            if isMainSearch { model.searchMain() }
                            else { model.search() }
                        }
                        .accessibilityIdentifier("refreshSearchResults")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                ScrollViewReader { proxy in
                    Group {
                        if usesNativeScrolling {
                            NativeScrollView(
                                onScroll: { contentOffset = $0 },
                                onUserScroll: { cancelCapturedAnchorForUser() },
                                scrollCommand: nativeScrollCommand,
                                resultSetID: search.resultSetID
                            ) {
                                rowsContent.onPreferenceChange(RowFramesPreference.self) {
                                    receiveFrames($0)
                                }
                            }
                        } else {
                            ScrollView { rowsContent }
                                .scrollPosition($searchPosition)
                                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y }
                                    action: { _, offset in
                                        contentOffset = offset
                                    }
                                .onScrollPhaseChange { _, phase in
                                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                                        cancelCapturedAnchorForUser()
                                    }
                                }
                                .onPreferenceChange(RowFramesPreference.self) { receiveFrames($0) }
                        }
                    }
                    .accessibilityIdentifier("searchResultsScroll")
                    .onChange(of: search.automaticRefreshToken) { _, _ in captureAnchor() }
                    .onChange(of: search.automaticResultRevision) { _, _ in
                        restoreAnchor(using: proxy)
                    }
                    .task(id: pendingAnchorToken) {
                        guard pendingAnchor != nil else { return }
                        let token = pendingAnchorToken
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, pendingAnchorToken == token else { return }
                        applyPendingAnchor(clear: false)
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, pendingAnchorToken == token else { return }
                        applyPendingAnchor(clear: true)
                        cancelPendingAnchor()
                    }
                    .onChange(of: selectedResultID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var rowsContent: some View {
        Group {
            if usesNativeScrolling {
                VStack(alignment: .leading, spacing: 5) { resultRows }
            } else {
                LazyVStack(alignment: .leading, spacing: 5) { resultRows }
            }
        }
        .padding(.vertical, 5)
        .coordinateSpace(name: "searchResultContent")
    }

    private func captureAnchor() {
        let first = RowFrameGeometry.firstVisible(in: resultFrames, offset: contentOffset)
        savedAnchor = .init(
            id: first?.id,
            offset: first.map { $0.frame.minY - contentOffset } ?? 0,
            oldOrder: search.results.map(\.id)
        )
    }

    private func restoreAnchor(using proxy: ScrollViewProxy) {
        guard let savedAnchor else { return }
        self.savedAnchor = nil
        let surviving = Set(search.results.map(\.id))
        let target: Int64?
        if let id = savedAnchor.id, surviving.contains(id) {
            target = id
        } else if let id = savedAnchor.id,
                  let oldIndex = savedAnchor.oldOrder.firstIndex(of: id) {
            target = savedAnchor.oldOrder.dropFirst(oldIndex + 1).first(where: surviving.contains)
                ?? savedAnchor.oldOrder.prefix(oldIndex).reversed().first(where: surviving.contains)
        } else { target = nil }
        guard let target else {
            cancelPendingAnchor()
            if usesNativeScrolling {
                nativeScrollCommand = .init(id: UUID(), resultSetID: search.resultSetID, y: 0)
            } else { searchPosition.scrollTo(edge: .top) }
            return
        }
        pendingAnchor = .init(id: target, offset: savedAnchor.offset, oldOrder: [])
        pendingAnchorToken = UUID()
        if resultFrames[target] != nil { applyPendingAnchor(clear: false) }
        else if !usesNativeScrolling { proxy.scrollTo(target, anchor: .top) }
    }

    private func receiveFrames(_ frames: [Int64: CGRect]) {
        resultFrames = frames
        applyPendingAnchor(clear: true)
    }

    private func applyPendingAnchor(clear: Bool) {
        guard let pendingAnchor, let id = pendingAnchor.id,
              let frame = resultFrames[id] else { return }
        let y = max(0, frame.minY - pendingAnchor.offset)
        if usesNativeScrolling {
            nativeScrollCommand = .init(id: UUID(), resultSetID: search.resultSetID, y: y)
        }
        else { searchPosition.scrollTo(y: y) }
        if clear { cancelPendingAnchor() }
    }

    private func cancelPendingAnchor() {
        guard pendingAnchor != nil else { return }
        pendingAnchor = nil
        pendingAnchorToken = UUID()
    }

    private func cancelCapturedAnchorForUser() {
        savedAnchor = nil
        cancelPendingAnchor()
    }

    @ViewBuilder private var resultRows: some View {
        ForEach(groups) { project in
            Text(project.name.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            ForEach(project.sessions) { session in
                HStack(spacing: 7) {
                    AgentBadge(agent: session.agent)
                    if session.hasPlan { PlanBadge() }
                    Text(session.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 3)
                ForEach(session.results) { result in
                    Button {
                        if isMainSearch { search.query = ""; search.search() }
                        model.openSearchResult(result)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(result.role.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                            Text(search.snippets[result.id] ?? result.prefix)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(result.timestampMilliseconds.traceDate)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedResultID == result.id ? TraceTheme.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contextMenu { Button("Copy Message") { model.copyMessage(id: result.id) } }
                    .id(result.id)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: RowFramesPreference.self,
                            value: [result.id: geometry.frame(in: .named("searchResultContent"))]
                        )
                    })
                    .task(id: SnippetHydrationKey(result)) { await search.hydrate(result) }
                    .onAppear {
                        if !search.isResolvingProjectFilter,
                           result.id == search.results.last?.id {
                            search.search(reset: false)
                        }
                    }
                }
            }
        }
    }

    private var groups: [SearchProjectGroup] {
        var projects: [SearchProjectGroup] = []
        for result in search.results.prefix(maximum) {
            if let projectIndex = projects.firstIndex(where: {
                $0.id == result.projectCanonicalKey
            }) {
                projects[projectIndex].append(result)
            } else {
                projects.append(.init(result: result))
            }
        }
        return projects
    }
}

private struct SearchProjectGroup: Identifiable {
    let id: String
    let name: String
    var sessions: [SearchSessionGroup]

    init(result: SearchResult) {
        id = result.projectCanonicalKey
        name = result.projectName
        sessions = [.init(result: result)]
    }

    mutating func append(_ result: SearchResult) {
        if let sessionIndex = sessions.firstIndex(where: { $0.id == result.sessionID }) {
            sessions[sessionIndex].results.append(result)
        } else {
            sessions.append(.init(result: result))
        }
    }
}

private struct SearchSessionGroup: Identifiable {
    let id: Int64
    let title: String
    let hasPlan: Bool
    let agent: AgentKind
    var results: [SearchResult]

    init(result: SearchResult) {
        id = result.sessionID
        title = result.sessionTitle
        hasPlan = result.sessionHasPlan
        agent = result.agent
        results = [result]
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let loadError: @MainActor () async -> String

    var body: some View {
        HStack(spacing: 9) {
            if session.hadError {
                SessionErrorIcon(
                    errorRevision: session.errorRevision,
                    sourceGeneration: session.sourceGeneration,
                    loadError: loadError
                )
            }
            else { Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.title).lineLimit(1).truncationMode(.tail)
                    if session.hasPlan { PlanBadge() }
                }
                HStack(spacing: 6) {
                    Text(session.agent.displayName)
                    Text("·")
                    Text("\(session.messageCount.formatted()) messages")
                    Text("·")
                    Text(session.lastActivityMilliseconds.traceDate)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct SessionErrorIcon: View {
    let errorRevision: Int64
    let sourceGeneration: Int64
    let loadError: @MainActor () async -> String
    @State private var showing = false
    @State private var detail: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadRequestID: UUID?

    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel("Session error")
            .accessibilityValue(detail ?? "Hover for error details")
            .onHover { hovering in
                if hovering { showing = true; beginLoading() }
            }
            .onTapGesture { showing = true; beginLoading() }
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                ScrollView {
                    Text(detail ?? "Loading error details…")
                        .font(.callout)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(width: 420, height: 220)
            }
            .onDisappear { cancelLoading() }
            .onChange(of: "\(sourceGeneration):\(errorRevision)") { _, _ in
                cancelLoading()
                detail = nil
                if showing { beginLoading() }
            }
    }

    private func cancelLoading() {
        let task = loadTask
        loadRequestID = nil
        loadTask = nil
        task?.cancel()
    }

    private func beginLoading() {
        guard detail == nil, loadTask == nil else { return }
        let requestID = UUID()
        loadRequestID = requestID
        loadTask = Task {
            defer {
                if loadRequestID == requestID {
                    loadTask = nil
                    loadRequestID = nil
                }
            }
            let loaded = await loadError()
            guard !Task.isCancelled, loadRequestID == requestID else { return }
            detail = loaded
        }
    }
}

extension Notification.Name {
    static let traceFocusPopover = Notification.Name("traceFocusPopover")
}

private struct SearchResultAnchor {
    let id: Int64?
    let offset: CGFloat
    let oldOrder: [Int64]
}
