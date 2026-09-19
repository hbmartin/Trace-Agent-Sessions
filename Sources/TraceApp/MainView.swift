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
                        if TraceTestHooks.isUITesting {
                            Button("Open search", systemImage: "magnifyingglass") {
                                NotificationCenter.default.post(name: .traceShowLauncher, object: nil)
                            }
                            .accessibilityIdentifier("testOpenLauncher")
                        }
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
            model.setMainSearchPanelVisible(section == .transcript)
        }
        .onChange(of: section) { _, newSection in
            model.setMainSearchPanelVisible(newSection == .transcript)
        }
        .onAppear { model.setMainSearchPanelVisible(section == .transcript) }
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

private struct SidebarRevealTaskID: Equatable {
    let token: UUID?
    let rowID: Int64?
}

private struct SessionSidebar: View {
    @ObservedObject var model: TraceModel
    @ObservedObject private var settings: AppSettings
    @State private var dragStart: CGFloat?
    @State private var transientPaneFraction: Double?
    @State private var handledProjectRevealToken: UUID?
    @State private var handledSessionRevealToken: UUID?

    init(model: TraceModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.height - 7)
            let minimum = min(180.0, available / 2)
            let paneFraction = transientPaneFraction ?? settings.projectPaneFraction
            let height = min(available - minimum, max(minimum, available * paneFraction))
            let filteredProjects = model.filteredProjects
            let sessions = model.sessions
            let selectedProjectID = model.sidebarSelectedProjectID
            let reveal = model.sidebarRevealRequest
            let projectRevealTaskID = SidebarRevealTaskID(
                token: reveal?.token,
                rowID: reveal.flatMap { request in
                    filteredProjects.first {
                        $0.canonicalKey == request.projectCanonicalKey
                    }?.id
                }
            )
            let sessionRevealTaskID = SidebarRevealTaskID(
                token: reveal?.token,
                rowID: reveal.flatMap { request in
                    sessions.contains(where: { $0.id == request.sessionID })
                        ? request.sessionID
                        : nil
                }
            )
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
                    ScrollViewReader { proxy in
                        List(selection: Binding(get: { selectedProjectID }, set: { model.selectProject($0) })) {
                            ForEach(filteredProjects) { project in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.displayName).lineLimit(1)
                                    Text("\(project.sessionCount.formatted()) sessions").font(.caption2).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("projectSidebarRow-\(project.id)")
                                .accessibilityAddTraits(
                                    selectedProjectID == project.id ? .isSelected : []
                                )
                                .id(project.id)
                                .tag(Optional(project.id))
                            }
                        }
                        .task(id: projectRevealTaskID) {
                            guard let reveal = model.sidebarRevealRequest,
                                  handledProjectRevealToken != reveal.token,
                                  let projectID = projectRevealTaskID.rowID else {
                                return
                            }
                            for _ in 0..<8 {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled,
                                      model.sidebarRevealRequest?.token == reveal.token else { return }
                                proxy.scrollTo(projectID, anchor: .center)
                            }
                            handledProjectRevealToken = reveal.token
                            if TraceTestHooks.isUITesting,
                               TraceTestHooks.environment["TRACE_TEST_SKIP_SIDEBAR_PROJECT_REVEAL_ACK"] != nil {
                                return
                            }
                            model.acknowledgeSidebarProjectReveal(token: reveal.token)
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
                        settings.projectPaneFraction = min(0.8, max(0.2, settings.projectPaneFraction + delta))
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sessionSidebar"))
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = height
                                transientPaneFraction = settings.projectPaneFraction
                            }
                            guard available > 0 else { return }
                            transientPaneFraction = min(
                                available - minimum,
                                max(minimum, (dragStart ?? height) + value.translation.height)
                            ) / available
                        }
                        .onEnded { _ in
                            if let transientPaneFraction {
                                settings.projectPaneFraction = transientPaneFraction
                            }
                            transientPaneFraction = nil
                            dragStart = nil
                        })
                VStack(spacing: 0) {
                    HStack {
                        Text("Sessions").font(.headline)
                        Spacer()
                        Text("\(sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(12)
                    ScrollViewReader { proxy in
                        List(selection: Binding(get: { model.selectedSessionID }, set: { id in
                            if let id { model.selectSession(id) }
                        })) {
                            ForEach(sessions) { session in
                                SessionRow(session: session) { await model.sessionErrorText(session) }
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("sessionSidebarRow-\(session.id)")
                                    .accessibilityAddTraits(
                                        model.selectedSessionID == session.id ? .isSelected : []
                                    )
                                    .id(session.id)
                                    .tag(Optional(session.id))
                            }
                        }
                        .accessibilityIdentifier("sessionSidebarList")
                        .task(id: sessionRevealTaskID) {
                            guard let reveal = model.sidebarRevealRequest,
                                  handledSessionRevealToken != reveal.token,
                                  let sessionID = sessionRevealTaskID.rowID else {
                                return
                            }
                            for _ in 0..<8 {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled,
                                      model.sidebarRevealRequest?.token == reveal.token else { return }
                                proxy.scrollTo(sessionID, anchor: .center)
                            }
                            handledSessionRevealToken = reveal.token
                            model.acknowledgeSidebarSessionReveal(token: reveal.token)
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
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var search: SessionSearchModel

    init(model: TraceModel) {
        self.model = model
        settings = model.settings
        search = model.mainSearch
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedSessionID == nil {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(
                        model.selectedProjectCanonicalKey == nil
                            ? "Search all sessions"
                            : "Search this project",
                        text: $search.query
                    )
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("mainSearch")
                        .onChange(of: search.query) { _, query in
                            if search.shouldSearchAfterQueryChange(to: query) {
                                model.searchMain()
                            }
                        }
                    if !search.query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { search.query = "" }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                }
                .padding(14)
                Divider()
            }
            if model.selectedSessionID == nil && !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultList(model: model, search: model.mainSearch, maximum: .max, isMainSearch: true, selectedResultID: .constant(nil))
                    .id(search.resultSetID)
            } else if let session = model.selectedSession, session.id == model.selectedSessionID {
                HStack(spacing: 12) {
                    HStack {
                        AgentBadge(agent: session.agent)
                        if session.hasPlan { PlanBadge() }
                        Text("\(session.messageCount.formatted()) messages")
                        Text(session.lastActivityMilliseconds.traceDate)
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal", systemImage: "folder") { model.revealSelectedSession() }
                    Button("Copy", systemImage: "doc.on.doc") { model.copyTranscript() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transcriptMetadataHeader")
                .padding(16)
                HStack(spacing: 14) {
                    Toggle("Tools", isOn: $settings.showTools)
                    Toggle("System", isOn: $settings.showSystem)
                    Toggle("Reasoning", isOn: $settings.showReasoning)
                    Spacer()
                    Picker("Display", selection: $settings.transcriptDensity) {
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
                TranscriptRenderer(
                    model: model,
                    sessionID: session.id,
                    visibility: settings.transcriptVisibility,
                    density: settings.transcriptDensity
                )
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

private struct TranscriptRowConfiguration: Equatable {
    let messageID: Int64
    let role: MessageRole
    let timestampMilliseconds: Int64
    let prefix: String
    let toolSummary: String?
    let characterCount: Int
    let hasError: Bool
    let sourcePath: String
    let sourceFormat: SourceFormat
    let locator: RecordLocator
    let sectionFlags: Int?
    let hydratedRole: MessageRole?
    let hydratedSections: MessageSections?
    let hydratedToolName: String?
    let hydratedHasError: Bool?
    let hydrationFailed: Bool
    let visibility: TranscriptVisibility

    init(
        message: MessageSummary, hydrated: HydratedMessage?, hydrationFailed: Bool,
        visibility: TranscriptVisibility
    ) {
        messageID = message.id
        role = message.role
        timestampMilliseconds = message.timestampMilliseconds
        prefix = message.prefix
        toolSummary = message.toolSummary
        characterCount = message.characterCount
        hasError = message.hasError
        sourcePath = message.sourcePath
        sourceFormat = message.sourceFormat
        locator = message.locator
        sectionFlags = message.sectionFlags
        hydratedRole = hydrated?.role
        hydratedSections = hydrated?.sections
        hydratedToolName = hydrated?.toolName
        hydratedHasError = hydrated?.hasError
        self.hydrationFailed = hydrationFailed
        self.visibility = visibility
    }
}

@MainActor
private final class TranscriptTableView: NSTableView {
    var onUserScrollInput: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onUserScrollInput?()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let scrollingKeys: Set<UInt16> = [49, 115, 116, 119, 121, 123, 124, 125, 126]
        if scrollingKeys.contains(event.keyCode) { onUserScrollInput?() }
        super.keyDown(with: event)
    }
}

@MainActor
private final class TranscriptScrollView: NSScrollView {
    var onUserScrollInput: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let performanceInterval = TracePerformance.begin("Transcript Scroll Event")
        defer { TracePerformance.end(performanceInterval) }
        onUserScrollInput?()
        super.scrollWheel(with: event)
    }
}

@MainActor
private final class TranscriptScroller: NSScroller {
    var onUserScrollInput: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onUserScrollInput?()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class TranscriptHostingView: NSHostingView<AnyView> {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class TranscriptExpansionState: ObservableObject {
    @Published var auxiliary = false { didSet { changed(from: oldValue, to: auxiliary) } }
    @Published var toolInvocation = false { didSet { changed(from: oldValue, to: toolInvocation) } }
    @Published var toolOutput = false { didSet { changed(from: oldValue, to: toolOutput) } }
    private let heightChanged: () -> Void

    init(heightChanged: @escaping () -> Void) {
        self.heightChanged = heightChanged
    }

    private func changed(from oldValue: Bool, to newValue: Bool) {
        if oldValue != newValue { heightChanged() }
    }
}

private final class NotificationObserverBag: @unchecked Sendable {
    private var values: [NSObjectProtocol] = []

    func replace(with values: [NSObjectProtocol]) {
        removeAll()
        self.values = values
    }

    func removeAll() {
        values.forEach(NotificationCenter.default.removeObserver)
        values.removeAll()
    }

    deinit { removeAll() }
}

private struct TranscriptRenderer: NSViewRepresentable {
    @ObservedObject var model: TraceModel
    let sessionID: Int64
    let visibility: TranscriptVisibility
    let density: TranscriptDensity

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TranscriptTableView()
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = true
        table.rowHeight = 96
        table.intercellSpacing = NSSize(width: 0, height: density == .compact ? 6 : 14)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityIdentifier("transcriptTable")

        let scrollView = TranscriptScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        let scroller = TranscriptScroller()
        scroller.setAccessibilityIdentifier("transcriptScroller")
        scrollView.verticalScroller = scroller
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = !TraceTestHooks.isUITesting
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("transcriptScroll")
        context.coordinator.attach(table: table, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            model: model, sessionID: sessionID, visibility: visibility, density: density,
            messageRevision: model.transcriptMessageRevision,
            contentRevision: model.transcriptContentRevision,
            scrollRequest: model.scrollRequest
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.savePosition()
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct Item {
            let summary: MessageSummary
            let sourceIndex: Int
        }

        private struct RestoreRequest {
            enum Reason {
                case passive
                case navigation
                case visibility
                case search(messageID: Int64)

                var priority: Int {
                    switch self {
                    case .passive: 0
                    case .navigation: 1
                    case .visibility: 2
                    case .search: 3
                    }
                }

                var reportsHooks: Bool {
                    if case .passive = self { return false }
                    return true
                }
            }

            let token = UUID()
            let bookmark: TranscriptBookmark
            let reason: Reason
            let refreshesRowHeights: Bool
            var attemptsRemaining: Int
            var stableChecks = 0
            var refreshedRowHeights = false
            var refreshedTargetRowHeight = false
            var revealedTargetRow = false
            var lastDocumentHeight: CGFloat?
            var postRestoreCorrectionsRemaining: Int
            var isPostRestoreCorrection = false

            init(
                bookmark: TranscriptBookmark, reason: Reason,
                refreshesRowHeights: Bool
            ) {
                self.bookmark = bookmark
                self.reason = reason
                self.refreshesRowHeights = refreshesRowHeights
                attemptsRemaining = 12
                switch reason {
                case .search: postRestoreCorrectionsRemaining = 12
                case .visibility, .navigation: postRestoreCorrectionsRemaining = 8
                case .passive: postRestoreCorrectionsRemaining = 4
                }
            }
        }

        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var model: TraceModel?
        private var items: [Item] = []
        private var sessionID: Int64 = 0
        private var visibility = TranscriptVisibility()
        private var density = TranscriptDensity.comfortable
        private var messageRevision = -1
        private var contentRevision = -1
        private var scrollRequest: UUID?
        private var hydratedIDs: Set<Int64> = []
        private var failedIDs: Set<Int64> = []
        private var expandedIDs: Set<Int64> = []
        private var expansionStates: [Int64: TranscriptExpansionState] = [:]
        private let observers = NotificationObserverBag()
        private var bookmarkWorkItem: DispatchWorkItem?
        private var bookmarkSnapshotWorkItem: DispatchWorkItem?
        private var restoreWorkItem: DispatchWorkItem?
        private var heightWorkItem: DispatchWorkItem?
        private var pendingHeightMessageIDs: Set<Int64> = []
        private var pendingRestore: RestoreRequest?
        private var deferredRestore: RestoreRequest?
        private var postRestoreCorrection: RestoreRequest?
        private var applyingProgrammaticScroll = false
        private var expectedProgrammaticOrigin: NSPoint?
        private var lastObservedOrigin: NSPoint?
        private var userScrolling = false

        deinit {
            observers.removeAll()
        }

        func attach(table: NSTableView, scrollView: NSScrollView) {
            self.table = table
            self.scrollView = scrollView
            (table as? TranscriptTableView)?.onUserScrollInput = { [weak self] in
                self?.beginUserScrolling()
            }
            (scrollView as? TranscriptScrollView)?.onUserScrollInput = { [weak self] in
                self?.beginUserScrolling()
            }
            (scrollView.verticalScroller as? TranscriptScroller)?.onUserScrollInput = {
                [weak self] in self?.beginUserScrolling()
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            lastObservedOrigin = scrollView.contentView.bounds.origin
            observers.replace(with: [
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.beginUserScrolling()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleBookmarkSave(reportStart: false)
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.boundsDidChange()
                    }
                },
            ])
        }

        func detach() {
            bookmarkWorkItem?.cancel()
            bookmarkWorkItem = nil
            bookmarkSnapshotWorkItem?.cancel()
            bookmarkSnapshotWorkItem = nil
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            heightWorkItem?.cancel()
            heightWorkItem = nil
            (table as? TranscriptTableView)?.onUserScrollInput = nil
            (scrollView as? TranscriptScrollView)?.onUserScrollInput = nil
            (scrollView?.verticalScroller as? TranscriptScroller)?.onUserScrollInput = nil
            pendingRestore = nil
            deferredRestore = nil
            postRestoreCorrection = nil
            expectedProgrammaticOrigin = nil
            lastObservedOrigin = nil
            userScrolling = false
            observers.removeAll()
        }

        func update(
            model: TraceModel, sessionID: Int64, visibility: TranscriptVisibility,
            density: TranscriptDensity, messageRevision: Int, contentRevision: Int,
            scrollRequest: UUID
        ) {
            let performanceInterval = TracePerformance.begin("Transcript Update")
            defer { TracePerformance.end(performanceInterval) }
            self.model = model
            let sessionChanged = self.sessionID != sessionID
            var refreshesRowHeights = false
            var visibilityChanged = false
            if sessionChanged {
                cancelPendingRestore(reportCancellation: false)
                deferredRestore = nil
                expansionStates.removeAll()
            }
            self.sessionID = sessionID
            var needsRequestedRestore = sessionChanged || self.scrollRequest != scrollRequest
            var preservedBookmark: TranscriptBookmark?
            if self.messageRevision != messageRevision || self.visibility != visibility {
                if self.messageRevision >= 0 { preservedBookmark = currentBookmark() }
                visibilityChanged = self.visibility != visibility
                self.visibility = visibility
                let replacement = model.messages.enumerated().compactMap { index, summary in
                    visibility.includes(summary) ? Item(summary: summary, sourceIndex: index) : nil
                }
                updateRows(with: replacement, sessionChanged: sessionChanged)
                self.messageRevision = messageRevision
            }
            if self.density != density {
                preservedBookmark = preservedBookmark ?? currentBookmark()
                self.density = density
                applyingProgrammaticScroll = true
                table?.intercellSpacing.height = density == .compact ? 6 : 14
                updateCellInsets(for: density)
                if let table, !items.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(items.indices))
                    table.layoutSubtreeIfNeeded()
                }
                rememberProgrammaticOrigin()
                applyingProgrammaticScroll = false
                refreshesRowHeights = true
            }
            if self.contentRevision != contentRevision {
                pendingRestore?.stableChecks = 0
                pendingRestore?.lastDocumentHeight = nil
                preservedBookmark = preservedBookmark ?? currentBookmark()
                let newHydrated = Set(model.hydratedMessages.keys)
                let changed = hydratedIDs.symmetricDifference(newHydrated)
                    .union(failedIDs.symmetricDifference(model.hydrationFailures))
                    .union(expandedIDs.symmetricDifference(model.expandedReasoningIDs))
                hydratedIDs = newHydrated
                failedIDs = model.hydrationFailures
                expandedIDs = model.expandedReasoningIDs
                self.contentRevision = contentRevision
                let rows = IndexSet(items.indices.filter { changed.contains(items[$0].summary.id) })
                if !rows.isEmpty {
                    reloadRows(rows)
                }
            }
            if self.scrollRequest != scrollRequest {
                self.scrollRequest = scrollRequest
                needsRequestedRestore = true
            }
            if needsRequestedRestore {
                restoreRequestedPosition()
            } else if visibilityChanged, let preservedBookmark {
                requestRestore(
                    preservedBookmark, reason: .visibility,
                    refreshesRowHeights: false
                )
            } else if let preservedBookmark, !userScrolling {
                requestRestore(
                    preservedBookmark, reason: .passive,
                    refreshesRowHeights: refreshesRowHeights
                )
            } else if let preservedBookmark, refreshesRowHeights {
                requestRestore(
                    preservedBookmark, reason: .passive,
                    refreshesRowHeights: true
                )
            }
        }

        private func updateRows(with replacement: [Item], sessionChanged: Bool) {
            guard let table else { items = replacement; return }
            let preservesUserBottom = userScrolling && isAtBottom
            let oldIDs = items.map { $0.summary.id }
            let newIDs = replacement.map { $0.summary.id }
            items = replacement
            let liveIDs = Set(newIDs)
            expansionStates = expansionStates.filter { liveIDs.contains($0.key) }

            applyingProgrammaticScroll = true
            if !sessionChanged, newIDs.count > oldIDs.count,
               Array(newIDs.prefix(oldIDs.count)) == oldIDs {
                table.beginUpdates()
                table.insertRows(
                    at: IndexSet(integersIn: oldIDs.count..<newIDs.count), withAnimation: []
                )
                table.endUpdates()
            } else if !sessionChanged, oldIDs == newIDs {
                reloadRows(IndexSet(integersIn: replacement.indices))
            } else {
                table.reloadData()
            }
            if preservesUserBottom {
                table.layoutSubtreeIfNeeded()
                scrollToBottom()
            }
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
        }

        private func reloadRows(_ rows: IndexSet) {
            guard let table, !rows.isEmpty else { return }
            let preservesUserBottom = userScrolling && isAtBottom
            applyingProgrammaticScroll = true
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            table.layoutSubtreeIfNeeded()
            if preservesUserBottom { scrollToBottom() }
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = NSTableRowView()
            if items.indices.contains(row) {
                rowView.setAccessibilityIdentifier(
                    "transcriptMessage-\(items[row].sourceIndex)"
                )
            }
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let model else { return nil }
            let item = items[row]
            let identifier = NSUserInterfaceItemIdentifier("messageCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptHostingCell)
                ?? TranscriptHostingCell(identifier: identifier)
            let message = item.summary
            let expansion = expansionState(for: message.id)
            let hydrated = model.hydratedMessages[message.id]
            let hydrationFailed = model.hydrationFailures.contains(message.id)
            let rowView = MessageRow(
                summary: message,
                hydrated: hydrated,
                hydrationFailed: hydrationFailed,
                reasoningExpanded: Binding(
                    get: { [weak model] in model?.expandedReasoningIDs.contains(message.id) == true },
                    set: { [weak model] expanded in
                        guard let model else { return }
                        if expanded { model.expandedReasoningIDs.insert(message.id) }
                        else { model.expandedReasoningIDs.remove(message.id) }
                    }
                ),
                expansion: expansion,
                visibility: visibility,
                hydrate: { [weak model] in model?.hydrate(message) },
                copyMessage: { [weak model] in model?.copyMessage(id: message.id) },
                heightChanged: { [weak self] in self?.invalidateHeight(messageID: message.id) }
            )
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcriptMessage-\(item.sourceIndex)")
            cell.setDensity(density)
            cell.set(
                rootView: AnyView(rowView.id(message.id)), messageID: message.id,
                configuration: TranscriptRowConfiguration(
                    message: message,
                    hydrated: hydrated,
                    hydrationFailed: hydrationFailed,
                    visibility: visibility
                ),
                copyMessage: { [weak model] in model?.copyMessage(id: message.id) }
            )
            return cell
        }

        private func updateCellInsets(for density: TranscriptDensity) {
            guard let table else { return }
            let rows = table.rows(in: table.visibleRect)
            guard rows.location != NSNotFound else { return }
            for row in rows.location..<NSMaxRange(rows) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? TranscriptHostingCell)?.setDensity(density)
            }
        }

        private func expansionState(for messageID: Int64) -> TranscriptExpansionState {
            if let state = expansionStates[messageID] { return state }
            let state = TranscriptExpansionState { [weak self] in
                self?.invalidateHeight(messageID: messageID)
            }
            expansionStates[messageID] = state
            return state
        }

        func savePosition() {
            guard !applyingProgrammaticScroll, pendingRestore == nil,
                  let bookmark = currentBookmark(), let model else { return }
            model.scrollPositions[sessionID] = bookmark
            TraceTestHooks.appendLine(
                "finished", pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"
            )
            if TraceTestHooks.isUITesting,
               let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] {
                try? Data("\(bookmark.index)".utf8).write(to: URL(fileURLWithPath: path))
            }
        }

        private func savePositionWhileScrolling() {
            guard !applyingProgrammaticScroll, pendingRestore == nil,
                  let bookmark = currentBookmark(), let model else { return }
            model.scrollPositions[sessionID] = bookmark
            if TraceTestHooks.isUITesting,
               let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] {
                try? Data("\(bookmark.index)".utf8).write(to: URL(fileURLWithPath: path))
            }
        }

        private func scheduleBookmarkSnapshot() {
            bookmarkSnapshotWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.bookmarkSnapshotWorkItem = nil
                    self.savePositionWhileScrolling()
                }
            }
            bookmarkSnapshotWorkItem = item
            DispatchQueue.main.async(execute: item)
        }

        private func scheduleBookmarkSave(reportStart: Bool) {
            guard !applyingProgrammaticScroll else { return }
            bookmarkWorkItem?.cancel()
            if reportStart {
                TraceTestHooks.appendLine(
                    "started", pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"
                )
            }
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.bookmarkWorkItem = nil
                    self.finishUserScrolling()
                }
            }
            bookmarkWorkItem = item
            let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"
            ) ?? 200
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delay), execute: item
            )
        }

        private func currentBookmark() -> TranscriptBookmark? {
            guard let table, let scrollView else { return nil }
            let visible = scrollView.documentVisibleRect
            var row = table.row(at: NSPoint(x: 1, y: visible.minY + 1))
            if row < 0 {
                let rows = table.rows(in: visible)
                guard rows.location != NSNotFound else { return nil }
                row = rows.location
            }
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            return .init(
                messageID: item.summary.id,
                offset: table.rect(ofRow: row).minY - visible.minY,
                index: item.sourceIndex
            )
        }

        private func restoreRequestedPosition() {
            guard let model else { return }
            if let target = model.requestedMessageID {
                if let item = items.first(where: { $0.summary.id == target }) {
                    requestRestore(
                        .init(messageID: target, offset: 0, index: item.sourceIndex),
                        reason: .search(messageID: target)
                    )
                    return
                } else if !model.messages.isEmpty {
                    // The session is loaded and the target is hidden by visibility or stale.
                    // Consume it so a later filter change or append cannot cause a surprise jump.
                    model.consumeRequestedMessageID(target)
                } else {
                    return
                }
            }
            guard !items.isEmpty else { return }
            requestRestore(
                model.scrollPositions[sessionID]
                    ?? .init(messageID: items[0].summary.id, offset: 0, index: 0),
                reason: .navigation
            )
        }

        private func requestRestore(
            _ bookmark: TranscriptBookmark, reason: RestoreRequest.Reason,
            refreshesRowHeights: Bool = false
        ) {
            if case .passive = reason,
               !userScrolling,
               beginPostRestoreCorrectionIfAvailable() {
                return
            }
            let request = RestoreRequest(
                bookmark: bookmark, reason: reason,
                refreshesRowHeights: refreshesRowHeights
            )
            if userScrolling {
                switch reason {
                case .navigation, .visibility, .search:
                    retainDeferredRestore(request)
                    TraceTestHooks.touch(
                        pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_DEFERRED_PATH"
                    )
                case .passive:
                    break
                }
                return
            }
            if let pendingRestore,
               pendingRestore.reason.priority > request.reason.priority { return }
            beginRestore(request)
        }

        private func beginRestore(_ request: RestoreRequest) {
            postRestoreCorrection = nil
            cancelPendingRestore(reportCancellation: false)
            pendingRestore = request
            if request.reason.reportsHooks && !request.isPostRestoreCorrection {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH")
            }
            let delay = request.reason.reportsHooks && !request.isPostRestoreCorrection
                ? TraceTestHooks.delayMilliseconds(for: "TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS") ?? 0
                : 0
            scheduleRestore(token: request.token, delayMilliseconds: delay)
        }

        private func scheduleRestore(token: UUID, delayMilliseconds: Int) {
            restoreWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.applyRestore(token: token) }
            }
            restoreWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delayMilliseconds), execute: work
            )
        }

        private func applyRestore(token: UUID) {
            guard var request = pendingRestore, request.token == token,
                  let table, let scrollView, !items.isEmpty, !userScrolling else { return }
            let performanceInterval = TracePerformance.begin("Transcript Restore")
            defer { TracePerformance.end(performanceInterval) }
            let bookmark = request.bookmark
            let exact = items.firstIndex { $0.summary.id == bookmark.messageID }
            let row = exact ?? items.indices.min {
                abs(items[$0].sourceIndex - bookmark.index) < abs(items[$1].sourceIndex - bookmark.index)
            } ?? 0
            applyingProgrammaticScroll = true
            if request.refreshesRowHeights, !request.refreshedRowHeights {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(items.indices))
                request.refreshedRowHeights = true
            }
            if !request.refreshedTargetRowHeight {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                request.refreshedTargetRowHeight = true
            }
            table.layoutSubtreeIfNeeded()
            if !request.revealedTargetRow {
                if case .passive = request.reason {
                    // The passive anchor is already at or near the viewport; directly
                    // correcting the clip origin avoids rematerializing the table.
                } else {
                    table.scrollRowToVisible(row)
                    table.layoutSubtreeIfNeeded()
                }
                request.revealedTargetRow = true
            }
            var rowRect = table.rect(ofRow: row)
            var origin = constrainedOrigin(
                for: rowRect.minY - bookmark.offset, table: table, scrollView: scrollView
            )
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            table.layoutSubtreeIfNeeded()
            rowRect = table.rect(ofRow: row)
            origin = constrainedOrigin(
                for: rowRect.minY - bookmark.offset, table: table, scrollView: scrollView
            )
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            expectedProgrammaticOrigin = scrollView.contentView.bounds.origin
            applyingProgrammaticScroll = false

            let visible = scrollView.documentVisibleRect
            let achievedOffset = rowRect.minY - visible.minY
            let offsetMatches = abs(achievedOffset - bookmark.offset) <= 1
            let constrainedAtEdge = abs(origin.y - (rowRect.minY - bookmark.offset)) > 1
                && visible.intersects(rowRect)
            let documentHeight = table.frame.height
            let heightIsStable = request.lastDocumentHeight.map {
                abs($0 - documentHeight) <= 1
            } ?? false
            let contentIsReady: Bool
            if case .search(let messageID) = request.reason {
                contentIsReady = model?.hydratedMessages[messageID] != nil
                    || model?.hydrationFailures.contains(messageID) == true
            } else {
                contentIsReady = true
            }
            request.lastDocumentHeight = documentHeight
            if (offsetMatches || constrainedAtEdge) && heightIsStable && contentIsReady {
                request.stableChecks += 1
            }
            else { request.stableChecks = 0 }
            request.attemptsRemaining -= 1
            if request.stableChecks < 5, request.attemptsRemaining > 0 {
                pendingRestore = request
                scheduleRestore(
                    token: token,
                    delayMilliseconds: request.refreshesRowHeights ? 50 : 75
                )
            } else {
                pendingRestore = nil
                restoreWorkItem = nil
                postRestoreCorrection = request.postRestoreCorrectionsRemaining > 0
                    ? request
                    : nil
                if case .search(let messageID) = request.reason,
                   visible.intersects(rowRect) {
                    model?.consumeRequestedMessageID(messageID)
                }
            }
        }

        private func constrainedOrigin(
            for desiredY: CGFloat, table: NSTableView, scrollView: NSScrollView
        ) -> NSPoint {
            let lastRowBottom = items.isEmpty ? 0 : table.rect(ofRow: items.count - 1).maxY
            let documentHeight = max(table.frame.height, table.bounds.height, lastRowBottom)
            let maximumY = max(0, documentHeight - scrollView.contentView.bounds.height)
            var origin = scrollView.contentView.bounds.origin
            origin.y = min(max(0, desiredY), maximumY)
            return origin
        }

        private func cancelPendingRestore(reportCancellation: Bool) {
            let reportsHooks = pendingRestore?.reason.reportsHooks == true
                && pendingRestore?.isPostRestoreCorrection == false
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            pendingRestore = nil
            if reportCancellation, reportsHooks {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH")
            }
        }

        private func beginUserScrolling() {
            guard !applyingProgrammaticScroll else { return }
            expectedProgrammaticOrigin = nil
            postRestoreCorrection = nil
            if let pendingRestore {
                switch pendingRestore.reason {
                case .navigation, .visibility, .search:
                    retainDeferredRestore(pendingRestore)
                case .passive:
                    break
                }
            }
            cancelPendingRestore(reportCancellation: true)
            let alreadyScrolling = userScrolling
            userScrolling = true
            scheduleBookmarkSnapshot()
            scheduleBookmarkSave(reportStart: !alreadyScrolling)
        }

        private func finishUserScrolling() {
            bookmarkWorkItem?.cancel()
            bookmarkWorkItem = nil
            userScrolling = false
            savePosition()
            if let deferredRestore {
                self.deferredRestore = nil
                beginRestore(deferredRestore)
            }
        }

        private func retainDeferredRestore(_ request: RestoreRequest) {
            guard deferredRestore?.reason.priority ?? -1 <= request.reason.priority else {
                return
            }
            deferredRestore = request
        }

        private func invalidateHeight(messageID: Int64) {
            pendingHeightMessageIDs.insert(messageID)
            guard heightWorkItem == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.flushHeightChanges() }
            }
            heightWorkItem = work
            DispatchQueue.main.async(execute: work)
        }

        private func flushHeightChanges() {
            heightWorkItem = nil
            guard let table else { return }
            let changed = pendingHeightMessageIDs
            pendingHeightMessageIDs.removeAll()
            let rows = IndexSet(items.indices.filter { changed.contains(items[$0].summary.id) })
            guard !rows.isEmpty else { return }
            let bookmark = pendingRestore == nil && !userScrolling ? currentBookmark() : nil
            let preservesUserBottom = userScrolling && isAtBottom
            applyingProgrammaticScroll = true
            table.noteHeightOfRows(withIndexesChanged: rows)
            table.layoutSubtreeIfNeeded()
            if preservesUserBottom { scrollToBottom() }
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
            if let bookmark { requestRestore(bookmark, reason: .passive) }
        }

        private var shouldIgnoreBoundsChange: Bool {
            guard let actual = scrollView?.contentView.bounds.origin else { return false }
            let previous = lastObservedOrigin
            lastObservedOrigin = actual
            if applyingProgrammaticScroll {
                return true
            }
            if let expected = expectedProgrammaticOrigin {
                expectedProgrammaticOrigin = nil
                let matches = originsMatch(expected, actual)
                if matches { return true }
            }
            return previous.map { originsMatch($0, actual) } ?? false
        }

        private func boundsDidChange() {
            guard !shouldIgnoreBoundsChange else { return }
            if pendingRestore != nil, !userScrolling { return }
            if !userScrolling, beginPostRestoreCorrectionIfAvailable() { return }
            beginUserScrolling()
        }

        private func beginPostRestoreCorrectionIfAvailable() -> Bool {
            guard var correction = postRestoreCorrection,
                  correction.postRestoreCorrectionsRemaining > 0 else { return false }
            postRestoreCorrection = nil
            correction.postRestoreCorrectionsRemaining -= 1
            correction.attemptsRemaining = 12
            correction.stableChecks = 0
            correction.lastDocumentHeight = nil
            correction.isPostRestoreCorrection = true
            beginRestore(correction)
            return true
        }

        private func rememberProgrammaticOrigin() {
            let origin = scrollView?.contentView.bounds.origin
            expectedProgrammaticOrigin = origin
            lastObservedOrigin = origin
        }

        private func originsMatch(_ lhs: NSPoint, _ rhs: NSPoint) -> Bool {
            abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
        }

        private var isAtBottom: Bool {
            guard let table, let scrollView, !items.isEmpty else { return false }
            let bottom = max(table.frame.height, table.rect(ofRow: items.count - 1).maxY)
            return bottom - scrollView.documentVisibleRect.maxY <= 2
        }

        private func scrollToBottom() {
            guard let table, let scrollView, !items.isEmpty else { return }
            let bottom = max(table.frame.height, table.rect(ofRow: items.count - 1).maxY)
            var origin = scrollView.contentView.bounds.origin
            origin.y = max(0, bottom - scrollView.contentView.bounds.height)
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

    }
}

@MainActor
private final class TranscriptHostingCell: NSTableCellView, NSGestureRecognizerDelegate {
    private let host = TranscriptHostingView(rootView: AnyView(EmptyView()))
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private(set) var messageID: Int64?
    private var configuration: TranscriptRowConfiguration?
    private var copyMessage: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.onMouseDown = { [weak self] in
            guard let table = self?.enclosingScrollView?.documentView as? NSTableView else { return }
            table.window?.makeFirstResponder(table)
        }
        let focusGesture = NSClickGestureRecognizer(
            target: self, action: #selector(focusEnclosingTable)
        )
        focusGesture.delegate = self
        host.addGestureRecognizer(focusGesture)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        leadingConstraint = host.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingConstraint = host.trailingAnchor.constraint(equalTo: trailingAnchor)
        topConstraint = host.topAnchor.constraint(equalTo: topAnchor)
        bottomConstraint = host.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            leadingConstraint, trailingConstraint, topConstraint, bottomConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {}

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }

    func setDensity(_ density: TranscriptDensity) {
        let horizontal: CGFloat = density == .compact ? 12 : 20
        let vertical: CGFloat = density == .compact ? 3 : 5
        leadingConstraint.constant = horizontal
        trailingConstraint.constant = -horizontal
        topConstraint.constant = vertical
        bottomConstraint.constant = -vertical
    }

    func set(
        rootView: AnyView, messageID: Int64,
        configuration: TranscriptRowConfiguration,
        copyMessage: @escaping () -> Void
    ) {
        self.messageID = messageID
        self.copyMessage = copyMessage
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        host.rootView = rootView
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard copyMessage != nil else { return super.menu(for: event) }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Copy Message", action: #selector(copyWholeMessage), keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func focusEnclosingTable() {
        guard let table = enclosingScrollView?.documentView as? NSTableView else { return }
        table.window?.makeFirstResponder(table)
    }

    @objc private func copyWholeMessage() { copyMessage?() }
}

private struct MessageRow: View {
    let summary: MessageSummary
    let hydrated: HydratedMessage?
    let hydrationFailed: Bool
    @Binding var reasoningExpanded: Bool
    @ObservedObject var expansion: TranscriptExpansionState
    let visibility: TranscriptVisibility
    let hydrate: () -> Void
    let copyMessage: () -> Void
    let heightChanged: () -> Void

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
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
            .task(id: visibility) {
                if !isLazyAuxiliary { hydrate() }
            }
        }
    }

    private var hasVisibleContent: Bool {
        if summary.hasError { return true }
        guard let hydrated else { return true }
        let sections = hydrated.sections
        return hasVisibleContent(in: sections)
    }

    @ViewBuilder private var content: some View {
        if let hydrated {
            if isLazyAuxiliary {
                DisclosureGroup(isExpanded: $expansion.auxiliary) {
                    sectionContents(hydrated)
                } label: {
                    Text(safePreview ?? neutralPlaceholder)
                        .font(.callout.monospaced())
                        .lineLimit(expansion.auxiliary ? nil : 2)
                }
                .onChange(of: expansion.auxiliary) { _, expanded in if expanded { hydrate() } }
            } else {
                sectionContents(hydrated)
            }
        } else if isLazyAuxiliary {
            DisclosureGroup(isExpanded: $expansion.auxiliary) {
                if hydrationFailed { Text("Unable to load visible content.").foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            } label: {
                Text(safePreview ?? neutralPlaceholder)
                    .font(.callout.monospaced())
                    .lineLimit(2)
            }
            .onChange(of: expansion.auxiliary) { _, expanded in if expanded { hydrate() } }
        } else if let safePreview, !safePreview.isEmpty {
            Text(safePreview).foregroundStyle(.secondary)
        } else if summary.sectionFlags.map({ $0 & 8 != 0 }) == true {
            Label("Image or attachment", systemImage: "paperclip").foregroundStyle(.secondary)
        } else if summary.hasError {
            Text("Error recorded.").foregroundStyle(.secondary)
        } else if hydrationFailed {
            Text("Unable to load visible content.").foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func sectionContents(_ message: HydratedMessage) -> some View {
        if visibility.includes(role: summary.role), !message.sections.prose.isEmpty {
            MarkdownText(
                source: message.sections.prose,
                copyMessage: copyMessage,
                heightChanged: heightChanged
            )
        }
        if visibility.includes(role: summary.role), visibility.tools && !message.sections.toolInvocation.isEmpty {
            DisclosureGroup(isExpanded: $expansion.toolInvocation) {
                SelectableMessageText(
                    text: AttributedString(message.sections.toolInvocation),
                    monospaced: true, copyMessage: copyMessage
                )
            } label: {
                Text("Tool invocation")
            }
        }
        if visibility.includes(role: summary.role), visibility.tools && !message.sections.toolOutput.isEmpty {
            DisclosureGroup(isExpanded: $expansion.toolOutput) {
                SelectableMessageText(
                    text: AttributedString(message.sections.toolOutput),
                    monospaced: true, copyMessage: copyMessage
                )
            } label: {
                Text("Tool output")
            }
        }
        if visibility.includes(role: summary.role), visibility.reasoning && !message.sections.reasoning.isEmpty {
            DisclosureGroup(isExpanded: $reasoningExpanded) {
                SelectableMessageText(
                    text: AttributedString(message.sections.reasoning),
                    secondary: true, copyMessage: copyMessage
                )
            } label: {
                Label("Reasoning", systemImage: "brain")
            }
            .onChange(of: reasoningExpanded) { _, _ in heightChanged() }
        }
        if visibility.includes(role: summary.role), message.sections.hasNonTextContent {
            Label("Image or attachment", systemImage: "paperclip")
                .foregroundStyle(.secondary)
        } else if summary.hasError
                    && !hasVisibleContent(in: message.sections) {
            Text(hasAnyContent(in: message.sections)
                 ? "Error details hidden by current toggles."
                 : "Error recorded without text details.")
                .foregroundStyle(.secondary)
        }
    }

    private var safePreview: String? {
        guard visibility.includes(role: summary.role) else { return nil }
        guard let flags = summary.sectionFlags else {
            return visibility.tools && visibility.reasoning ? summary.prefix : nil
        }
        if flags & 1 != 0 { return summary.prefix }
        if flags & 2 != 0 { return visibility.tools ? (summary.toolSummary ?? summary.prefix) : nil }
        if flags & 4 != 0 { return visibility.reasoning ? summary.prefix : nil }
        return nil
    }

    private var neutralPlaceholder: String {
        if summary.sectionFlags.map({ $0 & 8 != 0 }) == true { return "Image or attachment" }
        if summary.hasError { return "Error recorded." }
        return hydrationFailed ? "Unable to load visible content." : "Loading visible content…"
    }

    private var isLazyAuxiliary: Bool {
        visibility.includes(role: summary.role)
            && [.toolResult, .toolUse, .system, .reasoning].contains(summary.role)
    }

    private func hasVisibleContent(in sections: MessageSections) -> Bool {
        visibility.includes(role: summary.role)
            && (!sections.prose.isEmpty || sections.hasNonTextContent
                || (visibility.tools && (!sections.toolInvocation.isEmpty || !sections.toolOutput.isEmpty))
                || (visibility.reasoning && !sections.reasoning.isEmpty))
    }

    private func hasAnyContent(in sections: MessageSections) -> Bool {
        !sections.prose.isEmpty || !sections.toolInvocation.isEmpty
            || !sections.toolOutput.isEmpty || !sections.reasoning.isEmpty
            || sections.hasNonTextContent
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
