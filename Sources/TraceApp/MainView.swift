import AppKit
import SwiftUI
import TraceCore

private extension Notification.Name {
    static let traceTestTranscriptBenchmark = Notification.Name("traceTestTranscriptBenchmark")
    static let traceTestTranscriptScroll = Notification.Name("traceTestTranscriptScroll")
    static let traceTestTranscriptJumpBottom = Notification.Name("traceTestTranscriptJumpBottom")
    static let traceTestTranscriptProbe = Notification.Name("traceTestTranscriptProbe")
}

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
                            Button("Resize window", systemImage: "arrow.up.left.and.arrow.down.right") {
                                guard let window = NSApp.keyWindow else { return }
                                let frame = window.frame
                                window.setFrame(NSRect(
                                    x: frame.minX, y: frame.minY,
                                    width: frame.width - 120, height: frame.height - 80
                                ), display: true)
                            }
                            .accessibilityIdentifier("testResizeWindow")
                            Button("Simulate transcript scroll", systemImage: "arrow.up.and.down") {
                                NotificationCenter.default.post(
                                    name: .traceTestTranscriptScroll, object: nil
                                )
                            }
                            .accessibilityIdentifier("testSimulateTranscriptScroll")
                            Button("Jump transcript to bottom", systemImage: "arrow.down.to.line") {
                                NotificationCenter.default.post(
                                    name: .traceTestTranscriptJumpBottom, object: nil
                                )
                            }
                            .accessibilityIdentifier("testJumpTranscriptBottom")
                            Button("Probe transcript position", systemImage: "scope") {
                                NotificationCenter.default.post(
                                    name: .traceTestTranscriptProbe, object: nil
                                )
                            }
                            .accessibilityIdentifier("testProbeTranscriptPosition")
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

// SwiftUI's List proxy can leave the selected row outside the native clip view
// while its rows are being replaced. Confirm and reveal the actual AppKit row
// before acknowledging navigation.
private struct SidebarRowReveal: NSViewRepresentable {
    let token: UUID?
    let row: Int?
    let revealed: (UUID) -> Void
    let interrupted: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(view: view, token: token, row: row, revealed: revealed, interrupted: interrupted)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        var task: Task<Void, Never>?
        private var token: UUID?
        private var row: Int?
        private var inputMonitor: Any?
        func stop() {
            task?.cancel()
            task = nil
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
        }
        func update(view: NSView, token: UUID?, row: Int?, revealed: @escaping (UUID) -> Void,
                    interrupted: @escaping (UUID) -> Void) {
            let tokenChanged = self.token != token
            self.token = token
            self.row = row
            // An index change updates the live target without extending the deadline.
            guard tokenChanged else { return }
            stop()
            guard let token else { return }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
                [weak self, weak view] event in
                MainActor.assumeIsolated {
                    guard let self, self.token == token, let view, let window = view.window,
                          (event.window ?? NSApp.keyWindow) === window,
                          let scroll = view.enclosingScrollView else { return }
                    let column = scroll.convert(scroll.bounds, to: nil)
                    let relevant: Bool
                    if event.type == .keyDown {
                        relevant = (window.firstResponder as? NSView).map {
                            column.minX <= $0.convert($0.bounds, to: nil).midX
                                && $0.convert($0.bounds, to: nil).midX <= column.maxX
                        } ?? false
                    } else {
                        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                        relevant = column.minX <= point.x && point.x <= column.maxX
                    }
                    if relevant { self.stop(); interrupted(token) }
                }
                return event
            }
            task = Task { @MainActor [weak self, weak view] in
                var progress = SidebarRevealProgress()
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var attempt = 0
                while ContinuousClock.now < deadline {
                    defer { attempt += 1 }
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                    guard let self, let view, !Task.isCancelled, self.token == token else { return }
                    var ancestor = view.superview
                    while let candidate = ancestor, !(candidate is NSTableView) {
                        ancestor = candidate.superview
                    }
                    guard let table = ancestor as? NSTableView else { continue }
                    table.layoutSubtreeIfNeeded()
                    // A List background can retain a recycled view's geometry.
                    // Its model index remains the authoritative native row.
                    guard let row = self.row, row >= 0, row < table.numberOfRows else { continue }
                    let before = table.rect(ofRow: row)
                    if table.visibleRect.intersection(before).height < before.height - 1 {
                        table.scrollRowToVisible(row)
                    }
                    table.layoutSubtreeIfNeeded()
                    let rect = table.rect(ofRow: row)
                    let visible = table.visibleRect.intersection(rect)
                    TraceTestHooks.appendLine(
                        "attempt=\(attempt),row=\(row),rect=\(rect),visible=\(table.visibleRect),rowVisible=\(visible)",
                        pathKey: "TRACE_TEST_SIDEBAR_PROJECT_REVEAL_AUDIT_PATH"
                    )
                    if TraceTestHooks.isUITesting,
                       let gate = TraceTestHooks.environment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_RELEASE_PATH"],
                       !FileManager.default.fileExists(atPath: gate) { continue }
                    if progress.observe(row: row, rect: rect, viewport: table.visibleRect) {
                        self.stop()
                        revealed(token)
                        return
                    }
                }
            }
        }
    }
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
                        List(selection: Binding(get: { selectedProjectID }, set: {
                            if let token = model.sidebarRevealRequest?.token { model.cancelSidebarReveal(token: token) }
                            model.selectProject($0)
                        })) {
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
                                .background(SidebarRowReveal(
                                    token: projectRevealTaskID.rowID == project.id ? reveal?.token : nil,
                                    row: projectRevealTaskID.rowID == project.id
                                        ? filteredProjects.firstIndex(where: { $0.id == project.id }) : nil,
                                    revealed: { token in
                                    handledProjectRevealToken = token
                                    if TraceTestHooks.isUITesting,
                                       TraceTestHooks.environment["TRACE_TEST_SKIP_SIDEBAR_PROJECT_REVEAL_ACK"] != nil {
                                        return
                                    }
                                    model.acknowledgeSidebarProjectReveal(token: token)
                                }, interrupted: { token in
                                    model.cancelSidebarReveal(token: token)
                                }))
                            }
                        }
                        .task(id: projectRevealTaskID.token) {
                            guard let reveal = model.sidebarRevealRequest,
                                  handledProjectRevealToken != reveal.token,
                                  let projectID = projectRevealTaskID.rowID else {
                                return
                            }
                            guard model.claimSidebarProjectMaterialization(token: reveal.token) else { return }
                            proxy.scrollTo(projectID, anchor: .top)
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
                            if let token = model.sidebarRevealRequest?.token { model.cancelSidebarReveal(token: token) }
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
                    .accessibilityIdentifier("transcriptScroll")
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
    let reasoningExpanded: Bool

    init(
        message: MessageSummary, hydrated: HydratedMessage?, hydrationFailed: Bool,
        visibility: TranscriptVisibility, reasoningExpanded: Bool
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
        self.reasoningExpanded = reasoningExpanded
    }
}

@MainActor
private final class TranscriptTableView: NSTableView {
    var onUserScrollInput: (() -> Void)?

    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        TraceTestHooks.appendLine("table", pathKey: "TRACE_TEST_TRANSCRIPT_WHEEL_ROUTE_PATH")
        if let enclosingScrollView { enclosingScrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
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

    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        TraceTestHooks.appendLine("scroll", pathKey: "TRACE_TEST_TRANSCRIPT_WHEEL_ROUTE_PATH")
        onUserScrollInput?()
        super.scrollWheel(with: event)
    }
}

@MainActor
private final class TranscriptScroller: NSScroller {
    var onUserScrollInput: (() -> Void)?
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onUserScrollInput?()
        super.mouseDown(with: event)
        onTrackingEnded?()
    }
}

@MainActor
private final class TranscriptHostingView: NSHostingView<AnyView> {
    override func scrollWheel(with event: NSEvent) {
        TraceTestHooks.appendLine("host", pathKey: "TRACE_TEST_TRANSCRIPT_WHEEL_ROUTE_PATH")
        if let enclosingScrollView { enclosingScrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
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

private struct TranscriptDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content()
                    .padding(.leading, 16)
            }
        }
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

        private struct PositionSnapshot {
            let bookmark: TranscriptBookmark?
            let followsBottom: Bool
        }

        private struct RestoreRequest {
            enum Reason {
                case passive
                case navigation
                case visibility
                case search(messageID: Int64)
                case interaction

                var priority: Int {
                    switch self {
                    case .passive: 0
                    case .visibility: 1
                    case .interaction: 2
                    case .navigation: 3
                    case .search: 4
                    }
                }

                var isExplicitNavigation: Bool {
                    switch self {
                    case .navigation, .search: true
                    case .passive, .visibility, .interaction: false
                    }
                }

                var reportsHooks: Bool {
                    switch self {
                    case .passive, .interaction: false
                    case .navigation, .visibility, .search: true
                    }
                }

                var isInteraction: Bool {
                    if case .interaction = self { return true }
                    return false
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

            init(
                bookmark: TranscriptBookmark, reason: Reason,
                refreshesRowHeights: Bool
            ) {
                self.bookmark = bookmark
                self.reason = reason
                self.refreshesRowHeights = refreshesRowHeights
                attemptsRemaining = 12
            }
        }

        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var model: TraceModel?
        private var items: [Item] = []
        private var rowByMessageID: [Int64: Int] = [:]
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
        private var restoreGateTask: Task<Void, Never>?
        private var heightWorkItem: DispatchWorkItem?
        private var pendingHeightMessageIDs: Set<Int64> = []
        private var deferredHeightMessageIDs: Set<Int64> = []
        private var userHeightMessageIDs: Set<Int64> = []
        private var pendingInteractionBookmark: TranscriptBookmark?
        private var bottomFollowWorkItem: DispatchWorkItem?
        private var benchmarkObserver: NSObjectProtocol?
        private var anchorSamplingObserver: CFRunLoopObserver?
        private var benchmarkSweepIndex = 0
        private var benchmarkSweepRunning = false
        private var lastUserScrollInput: ContinuousClock.Instant?
        private var lastUserScrollMotion: ContinuousClock.Instant?
        private var upwardScrollTravel: CGFloat = 0
        private var pendingRestore: RestoreRequest?
        private var inputMonitor: Any?
        private var applyingProgrammaticScroll = false
        private var expectedProgrammaticOrigin: NSPoint?
        private var lastObservedOrigin: NSPoint?
        private var lastObservedViewportSize: NSSize?
        private var lastObservedDocumentHeight: CGFloat?
        private struct ResizeTransaction {
            let initiallyFollowing: Bool
            let viewportDelta: CGFloat
            let expires: ContinuousClock.Instant
            let inputGeneration: UInt64
        }
        private var resizeTransaction: ResizeTransaction?
        private var userInputGeneration: UInt64 = 0
        private var pendingDocumentBottomShift: (origin: CGFloat, expires: ContinuousClock.Instant)?
        private var userScrolling = false
        private var liveScrolling = false
        private var scrollerTracking = false
        private var selectionTracking = false
        private var positionEstablished = false
        private var establishedBookmark: TranscriptBookmark?
        private var followsBottom = false
        private var pendingBottomFollow = false
        private var pendingAnchorRestore: TranscriptBookmark?
        private var pendingIdleSaveAfterRestore = false

        deinit {
            observers.removeAll()
        }

        func attach(table: NSTableView, scrollView: NSScrollView) {
            self.table = table
            self.scrollView = scrollView
            do {
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) {
                    [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.correctEstablishedAnchor()
                        self?.sampleEstablishedAnchorForUITest()
                    }
                }
                anchorSamplingObserver = observer
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            (table as? TranscriptTableView)?.onUserScrollInput = { [weak self] in
                self?.beginUserScrolling()
            }
            (scrollView as? TranscriptScrollView)?.onUserScrollInput = { [weak self] in
                self?.beginUserScrolling()
            }
            (scrollView.verticalScroller as? TranscriptScroller)?.onUserScrollInput = {
                [weak self] in
                self?.scrollerTracking = true
                self?.beginUserScrolling()
            }
            (scrollView.verticalScroller as? TranscriptScroller)?.onTrackingEnded = {
                [weak self] in
                self?.scrollerTracking = false
                self?.scheduleBookmarkSave(reportStart: false)
            }
            // AppKit sends physical wheel input through the transcript's view tree.
            // XCTest can synthesize windowless wheel events that bypass it, so keep
            // that routing fallback confined to UI tests.
            let monitoredEvents: NSEvent.EventTypeMask = TraceTestHooks.isUITesting
                ? [.scrollWheel, .keyDown] : [.keyDown]
            inputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: monitoredEvents
            ) { [weak self, weak scrollView] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let scrollView, let transcriptWindow = scrollView.window else {
                        return false
                    }
                    let eventWindow = event.window ?? NSApp.keyWindow
                    guard eventWindow === transcriptWindow else { return false }
                    if event.type == .scrollWheel {
                        // Only UI tests monitor wheel events; windowed input uses AppKit.
                        guard event.window == nil else { return false }
                        guard let parent = scrollView.superview else { return false }
                        // A windowless mouse event carries screen coordinates. Its
                        // location can differ from the current pointer for synthetic input.
                        let windowPoint = transcriptWindow.convertPoint(fromScreen: event.locationInWindow)
                        let point = parent.convert(windowPoint, from: nil)
                        guard let hit = scrollView.hitTest(point) else { return false }
                        hit.scrollWheel(with: event)
                        return true
                    }
                    let scrollingKeys: Set<UInt16> = [49, 115, 116, 119, 121, 123, 124, 125, 126]
                    let responder = transcriptWindow.firstResponder
                    let transcriptOwnsKeyboard = responder === self.table
                        || responder === scrollView
                        || responder === scrollView.contentView
                        || responder === scrollView.verticalScroller
                        || ((responder as? MessageTextView)?.isDescendant(of: scrollView) == true)
                    TraceTestHooks.appendLine(
                        "\(event.keyCode),\(transcriptOwnsKeyboard)",
                        pathKey: "TRACE_TEST_TRANSCRIPT_KEY_ROUTE_PATH"
                    )
                    let textScrollKeys: Set<UInt16> = [115, 116, 119, 121, 125, 126]
                    let routedKeys = responder is MessageTextView ? textScrollKeys : scrollingKeys
                    if transcriptOwnsKeyboard && routedKeys.contains(event.keyCode) {
                        self.beginUserScrolling()
                    }
                    return false
                }
                return handled ? nil : event
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            lastObservedOrigin = scrollView.contentView.bounds.origin
            lastObservedViewportSize = scrollView.contentView.bounds.size
            lastObservedDocumentHeight = table.frame.height
            observers.replace(with: [
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.liveScrolling = true
                        self?.beginUserScrolling()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if TraceTestHooks.isUITesting && TraceTestHooks.environment[
                            "TRACE_TEST_TRANSCRIPT_DROP_LIVE_SCROLL_END"
                        ] == "1" { return }
                        self?.liveScrolling = false
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
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: table, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleBottomFollow() }
                },
                NotificationCenter.default.addObserver(
                    forName: .traceTestTranscriptScroll,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.simulateTranscriptScrollForUITest() }
                },
                NotificationCenter.default.addObserver(
                    forName: .traceTestTranscriptJumpBottom,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.jumpToBottomForUITest() }
                },
                NotificationCenter.default.addObserver(
                    forName: .traceTestTranscriptProbe,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.probeTranscriptPositionForUITest() }
                },
            ])
            table.postsFrameChangedNotifications = true
            attachBenchmarkObserverForUITest()
        }

        func detach() {
            if let observer = anchorSamplingObserver {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                anchorSamplingObserver = nil
            }
            bookmarkWorkItem?.cancel()
            bookmarkWorkItem = nil
            bookmarkSnapshotWorkItem?.cancel()
            bookmarkSnapshotWorkItem = nil
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            restoreGateTask?.cancel()
            restoreGateTask = nil
            heightWorkItem?.cancel()
            heightWorkItem = nil
            cancelBottomFollowWork()
            (table as? TranscriptTableView)?.onUserScrollInput = nil
            (scrollView as? TranscriptScrollView)?.onUserScrollInput = nil
            (scrollView?.verticalScroller as? TranscriptScroller)?.onUserScrollInput = nil
            (scrollView?.verticalScroller as? TranscriptScroller)?.onTrackingEnded = nil
            pendingRestore = nil
            if let inputMonitor {
                NSEvent.removeMonitor(inputMonitor)
                self.inputMonitor = nil
            }
            expectedProgrammaticOrigin = nil
            lastObservedOrigin = nil
            lastObservedViewportSize = nil
            lastObservedDocumentHeight = nil
            resizeTransaction = nil
            pendingDocumentBottomShift = nil
            lastUserScrollInput = nil
            lastUserScrollMotion = nil
            upwardScrollTravel = 0
            userScrolling = false
            liveScrolling = false
            scrollerTracking = false
            selectionTracking = false
            positionEstablished = false
            followsBottom = false
            pendingBottomFollow = false
            pendingAnchorRestore = nil
            rowByMessageID.removeAll()
            pendingHeightMessageIDs.removeAll()
            deferredHeightMessageIDs.removeAll()
            userHeightMessageIDs.removeAll()
            pendingInteractionBookmark = nil
            pendingIdleSaveAfterRestore = false
            observers.removeAll()
            if let benchmarkObserver {
                DistributedNotificationCenter.default().removeObserver(benchmarkObserver)
                self.benchmarkObserver = nil
            }
            benchmarkSweepRunning = false
            benchmarkSweepIndex = 0
        }

        func update(
            model: TraceModel, sessionID: Int64, visibility: TranscriptVisibility,
            density: TranscriptDensity, messageRevision: Int, contentRevision: Int,
            scrollRequest: UUID
        ) {
            let performanceInterval = TracePerformance.begin("Transcript Update")
            defer { TracePerformance.end(performanceInterval) }
            self.model = model
            if self.sessionID != sessionID || self.visibility != visibility || self.density != density
                || self.messageRevision != messageRevision || self.contentRevision != contentRevision {
                cachedRowExtent = nil
            }
            let sessionChanged = self.sessionID != sessionID
            let requestedMessageWasAvailable = model.requestedMessageID.map {
                rowByMessageID[$0] != nil
            } ?? false
            var refreshesRowHeights = false
            var visibilityChanged = false
            if sessionChanged {
                cancelPendingRestore(reportCancellation: false)
                expansionStates.removeAll()
                pendingHeightMessageIDs.removeAll()
                deferredHeightMessageIDs.removeAll()
                userHeightMessageIDs.removeAll()
                pendingInteractionBookmark = nil
                cancelBottomFollowWork()
                positionEstablished = false
                establishedBookmark = nil
                followsBottom = false
                pendingBottomFollow = false
                pendingAnchorRestore = nil
                pendingIdleSaveAfterRestore = false
            }
            self.sessionID = sessionID
            var needsRequestedRestore = sessionChanged || self.scrollRequest != scrollRequest
            var positionBeforeMutation: PositionSnapshot?
            if self.messageRevision != messageRevision || self.visibility != visibility {
                visibilityChanged = self.visibility != visibility
                self.visibility = visibility
                let replacement = model.messages.enumerated().compactMap { index, summary in
                    visibility.includes(summary) ? Item(summary: summary, sourceIndex: index) : nil
                }
                if !sessionChanged, self.messageRevision >= 0 {
                    let oldIDs = items.map { $0.summary.id }
                    let appended = !visibilityChanged && replacement.count > oldIDs.count
                        && !oldIDs.isEmpty
                        && Array(replacement.prefix(oldIDs.count).map { $0.summary.id }) == oldIDs
                    if visibilityChanged {
                        positionBeforeMutation = capturePosition()
                    } else {
                        positionBeforeMutation = capturePosition(allowImplicitBottom: appended)
                    }
                }
                updateRows(
                    with: replacement, sessionChanged: sessionChanged,
                    reloadExisting: visibilityChanged
                )
                if let requested = model.requestedMessageID,
                   !requestedMessageWasAvailable,
                   replacement.contains(where: { $0.summary.id == requested }) {
                    needsRequestedRestore = true
                }
                self.messageRevision = messageRevision
            }
            if self.density != density {
                positionBeforeMutation = positionBeforeMutation
                    ?? pendingInteractionBookmark.map {
                        PositionSnapshot(bookmark: $0, followsBottom: false)
                    }
                    ?? capturePosition()
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
                positionBeforeMutation = positionBeforeMutation
                    ?? pendingInteractionBookmark.map {
                        PositionSnapshot(bookmark: $0, followsBottom: false)
                    }
                    ?? capturePosition()
                let newHydrated = Set(model.hydratedMessages.keys)
                let changed = hydratedIDs.symmetricDifference(newHydrated)
                    .union(failedIDs.symmetricDifference(model.hydrationFailures))
                    .union(expandedIDs.symmetricDifference(model.expandedReasoningIDs))
                hydratedIDs = newHydrated
                failedIDs = model.hydrationFailures
                expandedIDs = model.expandedReasoningIDs
                self.contentRevision = contentRevision
                let rows = IndexSet(changed.compactMap { rowByMessageID[$0] })
                if !rows.isEmpty {
                    reloadRows(rows)
                }
            }
            if self.scrollRequest != scrollRequest {
                self.scrollRequest = scrollRequest
                needsRequestedRestore = true
            }
            if needsRequestedRestore {
                pendingBottomFollow = false
                pendingAnchorRestore = nil
                pendingIdleSaveAfterRestore = false
                followsBottom = false
                restoreRequestedPosition()
            } else if let positionBeforeMutation {
                reconcilePosition(
                    positionBeforeMutation,
                    reason: visibilityChanged ? .visibility
                        : pendingInteractionBookmark != nil ? .interaction : .passive,
                    refreshesRowHeights: refreshesRowHeights
                )
            }
            if !items.isEmpty, pendingRestore == nil { positionEstablished = true }
        }

        private func updateRows(
            with replacement: [Item], sessionChanged: Bool, reloadExisting: Bool
        ) {
            let oldIDs = items.map { $0.summary.id }
            let newIDs = replacement.map { $0.summary.id }
            let appendsExistingRows = !sessionChanged && newIDs.count > oldIDs.count
                && newIDs.starts(with: oldIDs)
            items = replacement
            if appendsExistingRows {
                for row in oldIDs.count..<newIDs.count {
                    rowByMessageID[newIDs[row]] = row
                }
            } else if sessionChanged || oldIDs != newIDs {
                rowByMessageID = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map {
                    ($0.element, $0.offset)
                })
            }
            guard let table else { return }
            if items.isEmpty {
                cancelPendingRestore(reportCancellation: true, cause: .lifecycle)
                pendingInteractionBookmark = nil
                pendingAnchorRestore = nil
                pendingIdleSaveAfterRestore = false
                pendingHeightMessageIDs.removeAll()
                deferredHeightMessageIDs.removeAll()
                userHeightMessageIDs.removeAll()
                if sessionChanged {
                    followsBottom = false
                    pendingBottomFollow = false
                }
                cancelBottomFollowWork()
            }
            let liveIDs = Set(newIDs)
            expansionStates = expansionStates.filter { liveIDs.contains($0.key) }
            deferredHeightMessageIDs.formIntersection(liveIDs)

            applyingProgrammaticScroll = true
            if appendsExistingRows {
                table.beginUpdates()
                table.insertRows(
                    at: IndexSet(integersIn: oldIDs.count..<newIDs.count), withAnimation: []
                )
                table.endUpdates()
                if reloadExisting, !oldIDs.isEmpty {
                    table.reloadData(
                        forRowIndexes: IndexSet(integersIn: 0..<oldIDs.count),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            } else if !sessionChanged, oldIDs == newIDs {
                reloadRows(IndexSet(integersIn: replacement.indices))
            } else {
                table.reloadData()
            }
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
        }

        private func reloadRows(_ rows: IndexSet) {
            guard let table, !rows.isEmpty else { return }
            applyingProgrammaticScroll = true
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            table.layoutSubtreeIfNeeded()
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
                    set: { [weak self, weak model] expanded in
                        guard let model else { return }
                        self?.invalidateHeight(messageID: message.id, userInitiated: true)
                        if expanded { model.expandedReasoningIDs.insert(message.id) }
                        else { model.expandedReasoningIDs.remove(message.id) }
                    }
                ),
                expansion: expansion,
                visibility: visibility,
                hydrate: { [weak model] in model?.hydrate(message) },
                copyMessage: { [weak model] in model?.copyMessage(id: message.id) },
                heightChanged: { [weak self] in self?.invalidateHeight(messageID: message.id) },
                selectionTrackingChanged: { [weak self] tracking in
                    guard let self else { return }
                    self.selectionTracking = tracking
                    if tracking { self.beginUserScrolling() }
                    else { self.scheduleBookmarkSave(reportStart: false) }
                }
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
                    visibility: visibility,
                    reasoningExpanded: model.expandedReasoningIDs.contains(message.id)
                ),
                copyMessage: { [weak model] in model?.copyMessage(id: message.id) }
            )
            if deferredHeightMessageIDs.remove(message.id) != nil {
                invalidateHeight(messageID: message.id)
            }
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
                self?.invalidateHeight(messageID: messageID, userInitiated: true)
            }
            expansionStates[messageID] = state
            return state
        }

        func savePosition() {
            guard !applyingProgrammaticScroll, pendingRestore == nil,
                  let bookmark = (followsBottom ? nil : establishedBookmark) ?? currentBookmark(), let model else { return }
            establishedBookmark = bookmark
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
            return bookmark(forRow: row)
        }

        private func bookmark(forRow row: Int) -> TranscriptBookmark? {
            guard items.indices.contains(row), let table, let scrollView else { return nil }
            let item = items[row]
            return .init(
                messageID: item.summary.id,
                offset: table.rect(ofRow: row).minY - scrollView.documentVisibleRect.minY,
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
            let request = RestoreRequest(
                bookmark: bookmark, reason: reason,
                refreshesRowHeights: refreshesRowHeights
            )
            if userScrolling {
                switch reason {
                case .navigation, .search, .interaction:
                    userScrolling = false
                case .visibility, .passive:
                    return
                }
            }
            if let pendingRestore,
               pendingRestore.reason.priority > request.reason.priority,
               !reason.isExplicitNavigation { return }
            beginRestore(request)
        }

        private func beginRestore(_ request: RestoreRequest) {
            cancelPendingRestore(reportCancellation: false)
            pendingRestore = request
            if request.reason.reportsHooks {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH")
            }
            if case .interaction = request.reason {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_INTERACTION_STARTED_PATH")
            }
            let delay: Int
            if case .interaction = request.reason {
                delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_TRANSCRIPT_INTERACTION_RESTORE_DELAY_MS"
                ) ?? 0
            } else {
                delay = request.reason.reportsHooks
                    ? TraceTestHooks.delayMilliseconds(for: "TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS") ?? 0
                    : 0
            }
            let releaseKey: String?
            switch request.reason {
            case .navigation, .visibility:
                releaseKey = "TRACE_TEST_TRANSCRIPT_RESTORE_RELEASE_PATH"
            case .search:
                releaseKey = "TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_RELEASE_PATH"
            case .interaction:
                releaseKey = "TRACE_TEST_TRANSCRIPT_INTERACTION_RESTORE_RELEASE_PATH"
            case .passive:
                releaseKey = nil
            }
            if TraceTestHooks.isUITesting, let releaseKey,
               TraceTestHooks.environment[releaseKey] != nil {
                restoreGateTask = Task { [weak self] in
                    do {
                        try await TraceTestHooks.waitForRelease(
                            pathKey: releaseKey, timeoutMilliseconds: 30_000
                        )
                        guard !Task.isCancelled else { return }
                        self?.restoreGateTask = nil
                        self?.applyRestore(token: request.token)
                    } catch {
                        guard !Task.isCancelled else { return }
                        TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_GATE_ERROR_PATH")
                        self?.cancelPendingRestore(reportCancellation: false)
                    }
                }
            } else if delay == 0 {
                applyRestore(token: request.token)
            } else {
                scheduleRestore(token: request.token, delayMilliseconds: delay)
            }
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
            guard !items.isEmpty else {
                cancelPendingRestore(reportCancellation: true, cause: .lifecycle)
                return
            }
            guard var request = pendingRestore, request.token == token,
                  let table, let scrollView, !userScrolling else { return }
            let performanceInterval = TracePerformance.begin("Transcript Restore")
            defer { TracePerformance.end(performanceInterval) }
            let bookmark = request.bookmark
            let exact = rowByMessageID[bookmark.messageID]
            let row = exact ?? items.indices.min {
                abs(items[$0].sourceIndex - bookmark.index) < abs(items[$1].sourceIndex - bookmark.index)
            } ?? 0
            applyingProgrammaticScroll = true
            if request.refreshesRowHeights, !request.refreshedRowHeights {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(items.indices))
                request.refreshedRowHeights = true
            }
            table.layoutSubtreeIfNeeded()
            if !request.revealedTargetRow {
                switch request.reason {
                case .passive, .interaction:
                    // The in-view anchor is already at or near the viewport; directly
                    // correcting the clip origin avoids rematerializing the table.
                    break
                case .navigation, .visibility, .search:
                    table.scrollRowToVisible(row)
                    table.layoutSubtreeIfNeeded()
                }
                request.revealedTargetRow = true
            }
            // Invalidating automatic heights can replace the anchor's measured
            // height with an estimate. Materialize and lay out just this row before
            // restoring a negative offset, which may exceed that estimate.
            // Disclosure content can settle over several layout passes, so refresh
            // its anchor on interaction retries without invalidating passive restores.
            if table.rect(ofRow: row).height + bookmark.offset <= 0 {
                // An offscreen cell can keep its automatic-height estimate even
                // after makeIfNecessary. Reveal it so AppKit attaches and measures
                // the hosted content before restoring the partially clipped row.
                table.scrollRowToVisible(row)
                table.layoutSubtreeIfNeeded()
            }
            if !request.refreshedTargetRowHeight
                || request.reason.isInteraction
                || table.rect(ofRow: row).height + bookmark.offset <= 0 {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? TranscriptHostingCell {
                    cell.refreshHostedSize()
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                    table.layoutSubtreeIfNeeded()
                }
                request.refreshedTargetRowHeight = true
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
            TraceTestHooks.appendLine(
                "row=\(row),rect=\(rowRect),cell=\((table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptHostingCell)?.layoutDescription ?? "unmaterialized")",
                pathKey: "TRACE_TEST_TRANSCRIPT_ROW_LAYOUT_AUDIT_PATH"
            )
            TraceTestHooks.appendLine(
                "\(bookmark.index),\(bookmark.offset),\(achievedOffset),\(origin.y),\(documentHeight)",
                pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_AUDIT_PATH"
            )
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
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_COMPLETED_PATH")
                positionEstablished = true
                establishedBookmark = .init(messageID: items[row].summary.id, offset: achievedOffset, index: items[row].sourceIndex)
                switch request.reason {
                case .navigation:
                    followsBottom = model?.scrollPositions[sessionID] != nil
                        && (maximumScrollY ?? 0) > 2 && isAtSettledBottom
                case .search:
                    followsBottom = (maximumScrollY ?? 0) > 2 && isAtSettledBottom
                case .visibility, .passive, .interaction:
                    break
                }
                if case .search(let messageID) = request.reason,
                   visible.intersects(rowRect) {
                    model?.consumeRequestedMessageID(messageID)
                }
                if pendingIdleSaveAfterRestore {
                    pendingIdleSaveAfterRestore = false
                    savePosition()
                }
            }
        }

        private func constrainedOrigin(
            for desiredY: CGFloat, table: NSTableView, scrollView: NSScrollView
        ) -> NSPoint {
            let maximumY = prepareDocumentExtent() ?? 0
            var origin = scrollView.contentView.bounds.origin
            origin.y = min(max(0, desiredY), maximumY)
            return origin
        }

        private enum RestoreCancellationCause { case replacement, lifecycle, userInteraction }

        private func cancelPendingRestore(reportCancellation: Bool,
                                          cause: RestoreCancellationCause = .replacement) {
            if cause == .userInteraction,
               case .search(let messageID) = pendingRestore?.reason,
               model?.selectedSessionID == sessionID {
                model?.consumeRequestedMessageID(messageID)
            }
            let reportsHooks = pendingRestore?.reason.reportsHooks == true
            restoreGateTask?.cancel()
            restoreGateTask = nil
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            pendingRestore = nil
            if reportCancellation, reportsHooks {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH")
            }
        }

        private func beginUserScrolling() {
            guard !applyingProgrammaticScroll else { return }
            if TraceTestHooks.isUITesting,
               TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_FORCE_LIVE_SCROLL"] == "1" {
                liveScrolling = true
            }
            let alreadyScrolling = userScrolling
            if !alreadyScrolling {
                lastUserScrollMotion = nil
                upwardScrollTravel = 0
            }
            lastUserScrollInput = .now
            userInputGeneration &+= 1
            resizeTransaction = nil
            pendingDocumentBottomShift = nil
            establishedBookmark = nil
            cancelBottomFollowWork()
            expectedProgrammaticOrigin = nil
            pendingAnchorRestore = nil
            pendingIdleSaveAfterRestore = false
            cancelPendingRestore(reportCancellation: true, cause: .userInteraction)
            userScrolling = true
            scheduleBookmarkSnapshot()
            scheduleBookmarkSave(reportStart: !alreadyScrolling)
        }

        private func finishUserScrolling() {
            bookmarkWorkItem?.cancel()
            bookmarkWorkItem = nil
            let lastActivity = [lastUserScrollInput, lastUserScrollMotion]
                .compactMap { $0 }.max()
            let idleDelay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"
            ) ?? 200
            if let lastActivity,
               lastActivity.duration(to: .now) < .milliseconds(idleDelay) {
                scheduleBookmarkSave(reportStart: false)
                return
            }
            if liveScrolling,
               let lastActivity,
               lastActivity.duration(to: .now) >= .milliseconds(600) {
                liveScrolling = false
            }
            guard !liveScrolling, !scrollerTracking, !selectionTracking else {
                scheduleBookmarkSave(reportStart: false)
                return
            }
            let viewport = viewportStatus
            guard viewport.withinBounds else {
                scheduleBookmarkSave(reportStart: false)
                return
            }
            userScrolling = false
            if viewport.atBottom {
                followsBottom = true
                pendingBottomFollow = false
                pendingAnchorRestore = nil
            } else if pendingBottomFollow {
                pendingBottomFollow = false
                pendingAnchorRestore = nil
                applyBottomPosition()
                scheduleBottomFollow()
            } else if let pendingAnchorRestore {
                self.pendingAnchorRestore = nil
                followsBottom = false
                pendingIdleSaveAfterRestore = true
                requestRestore(pendingAnchorRestore, reason: .passive)
            } else if followsBottom {
                applyBottomPosition()
                scheduleBottomFollow()
            } else {
                followsBottom = viewport.atBottom
            }
            upwardScrollTravel = 0
            positionEstablished = true
            if !pendingIdleSaveAfterRestore { savePosition() }
        }

        private func invalidateHeight(messageID: Int64, userInitiated: Bool = false) {
            cachedRowExtent = nil
            pendingHeightMessageIDs.insert(messageID)
            if userInitiated {
                establishedBookmark = nil
                userHeightMessageIDs.insert(messageID)
                if pendingInteractionBookmark == nil,
                   let row = rowByMessageID[messageID] {
                    pendingInteractionBookmark = bookmark(forRow: row)
                }
                followsBottom = false
                pendingBottomFollow = false
                pendingAnchorRestore = nil
                cancelBottomFollowWork()
                cancelPendingRestore(reportCancellation: true, cause: .userInteraction)
            }
            if userInitiated {
                heightWorkItem?.cancel()
                heightWorkItem = nil
            }
            guard heightWorkItem == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.flushHeightChanges() }
            }
            heightWorkItem = work
            if userInitiated {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
            }
        }

        private func flushHeightChanges() {
            heightWorkItem = nil
            guard let table else { return }
            let changed = pendingHeightMessageIDs
            pendingHeightMessageIDs.removeAll()
            let userChanged = userHeightMessageIDs
            userHeightMessageIDs.removeAll()
            let savedInteractionBookmark = pendingInteractionBookmark
            pendingInteractionBookmark = nil
            let visible = table.rows(in: table.visibleRect)
            let visibleRows = visible.location == NSNotFound
                ? IndexSet() : IndexSet(integersIn: visible.location..<NSMaxRange(visible))
            // Automatic row-height invalidation can measure every row between a changed
            // offscreen row and the viewport. Recalculate it when it becomes visible.
            let rows = IndexSet(changed.compactMap { messageID -> Int? in
                guard let row = rowByMessageID[messageID] else { return nil }
                if userChanged.contains(messageID) || visibleRows.contains(row) {
                    deferredHeightMessageIDs.remove(messageID)
                    return row
                }
                deferredHeightMessageIDs.insert(messageID)
                return nil
            })
            guard !rows.isEmpty else { return }
            let interactionRow = userChanged.compactMap { rowByMessageID[$0] }.min()
            let interactionBookmark = savedInteractionBookmark
                ?? interactionRow.flatMap(bookmark(forRow:))
            let positionBeforeMutation = interactionBookmark.map {
                PositionSnapshot(bookmark: $0, followsBottom: false)
            } ?? capturePosition()
            if interactionBookmark != nil {
                followsBottom = false
                pendingBottomFollow = false
                pendingAnchorRestore = nil
                cancelPendingRestore(reportCancellation: true, cause: .userInteraction)
            }
            applyingProgrammaticScroll = true
            cachedRowExtent = nil
            table.noteHeightOfRows(withIndexesChanged: rows)
            table.layoutSubtreeIfNeeded()
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
            reconcilePosition(
                positionBeforeMutation,
                reason: interactionBookmark == nil ? .passive : .interaction
            )
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
            return previous.map { $0 == actual } ?? false
        }

        private func boundsDidChange() {
            let previous = lastObservedOrigin
            let previousViewportSize = lastObservedViewportSize
            let previousDocumentHeight = lastObservedDocumentHeight
            let ignored = shouldIgnoreBoundsChange
            guard let scrollView else { return }
            let actual = scrollView.contentView.bounds.origin
            let viewportSize = scrollView.contentView.bounds.size
            let documentHeight = table?.frame.height
            lastObservedViewportSize = viewportSize
            lastObservedDocumentHeight = documentHeight
            let viewportResized = previousViewportSize.map {
                abs($0.width - viewportSize.width) > 0.5
                    || abs($0.height - viewportSize.height) > 0.5
            } ?? false
            if viewportResized, let previousViewportSize {
                resizeTransaction = ResizeTransaction(
                    initiallyFollowing: followsBottom,
                    viewportDelta: viewportSize.height - previousViewportSize.height,
                    expires: .now.advanced(by: .milliseconds(500)),
                    inputGeneration: userInputGeneration
                )
            }
            let documentResized = previousDocumentHeight.flatMap { before in
                documentHeight.map { abs(before - $0) > 0.5 }
            } ?? false
            if documentResized, followsBottom, let table, !items.isEmpty {
                _ = maximumScrollY
                if let bottom = cachedRowExtent?.bottom {
                    // AppKit can anchor to the last row before applying trailing
                    // document padding in a later origin-only update.
                    pendingDocumentBottomShift = (max(0, bottom - viewportSize.height),
                        .now.advanced(by: .milliseconds(500)))
                }
            }
            let layoutChanged = viewportResized || documentResized || scrollView.inLiveResize
            let originDelta = actual.y - (previous?.y ?? actual.y)
            let documentDelta = (documentHeight ?? 0) - (previousDocumentHeight ?? 0)
            let originTravel = abs(originDelta)
            let documentTravel = abs(documentDelta)
            var passiveLayoutMotion = viewportResized || scrollView.inLiveResize
                || (documentResized && originTravel <= documentTravel + 2
                    && originDelta * documentDelta >= 0)
            if let transaction = resizeTransaction {
                if ContinuousClock.now >= transaction.expires
                    || transaction.inputGeneration != userInputGeneration {
                    resizeTransaction = nil
                } else if transaction.initiallyFollowing, !scrollerTracking, !selectionTracking {
                    // A resize can change estimated row heights and then deliver
                    // multiple origin-only adjustments, including another upward
                    // adjustment. Physical input invalidates this transaction
                    // before AppKit moves the viewport.
                    let oppositeShift = previous.map {
                        TranscriptViewportPolicy.matchesResizeShift(actual: actual.y, previous: $0.y,
                            viewportDelta: transaction.viewportDelta)
                    } ?? false
                    passiveLayoutMotion = true
                    TraceTestHooks.appendLine(oppositeShift ? "resize-motion=opposite" : "resize-motion=native",
                        pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                }
            }
            if !ignored, !viewportResized, !documentResized,
               let pending = pendingDocumentBottomShift {
                pendingDocumentBottomShift = nil
                // Every new wheel/key input clears this pending adjustment. The
                // idle debounce can still be active while layout finishes.
                if followsBottom, !scrollerTracking, !selectionTracking, ContinuousClock.now < pending.expires,
                   abs(actual.y - pending.origin) <= 1 {
                    passiveLayoutMotion = true
                }
            }
            TraceTestHooks.appendLine(
                "previous=\(previous?.y ?? -1),actual=\(actual.y),ignored=\(ignored),layout=\(layoutChanged),passiveLayout=\(passiveLayoutMotion),viewHeight=\(viewportSize.height),oldViewHeight=\(previousViewportSize?.height ?? -1),docHeight=\(documentHeight ?? -1),oldDocHeight=\(previousDocumentHeight ?? -1),user=\(userScrolling),restore=\(pendingRestore != nil),interacting=\(isUserInteracting),bottom=\(followsBottom)",
                pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"
            )
            TraceTestHooks.appendLine(
                String(Double(actual.y)), pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_OFFSET_PATH"
            )
            recordVisibleGapForUITest()
            awakenDeferredHeightsInViewport()
            guard !ignored else {
                if layoutChanged { scheduleBottomFollow() }
                return
            }
            if previous == actual && !layoutChanged { return }
            if userScrolling {
                if passiveLayoutMotion { scheduleBottomFollow(); return }
                recordUserViewportMotion(from: previous, to: actual)
                return
            }
            if pendingRestore != nil || isUserInteracting { return }
            if followsBottom && isAtSettledBottom {
                scheduleBottomFollow()
                return
            }
            if passiveLayoutMotion { scheduleBottomFollow(); return }
            beginUserScrolling()
            recordUserViewportMotion(from: previous, to: actual)
        }

        private func awakenDeferredHeightsInViewport() {
            guard !deferredHeightMessageIDs.isEmpty, let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<NSMaxRange(visible) where items.indices.contains(row) {
                let messageID = items[row].summary.id
                if deferredHeightMessageIDs.remove(messageID) != nil {
                    invalidateHeight(messageID: messageID)
                }
            }
        }

        private func recordUserViewportMotion(from previous: NSPoint?, to actual: NSPoint) {
            guard let previous else { return }
            let delta = actual.y - previous.y
            guard delta != 0 else { return }
            lastUserScrollMotion = .now
            pendingAnchorRestore = nil
            if bookmarkWorkItem == nil { scheduleBookmarkSave(reportStart: false) }
            if delta < 0 { upwardScrollTravel -= delta }
            else { upwardScrollTravel = max(0, upwardScrollTravel - delta) }
            let viewport = viewportStatus
            followsBottom = TranscriptViewportPolicy.followsBottom(atBottom: viewport.atBottom,
                withinBounds: viewport.withinBounds, upwardTravel: upwardScrollTravel, previouslyFollowing: followsBottom)
            if viewport.atBottom { upwardScrollTravel = 0 }
            if viewport.atBottom || (upwardScrollTravel > 0.5 && viewport.withinBounds) {
                pendingBottomFollow = false
                if !followsBottom { cancelBottomFollowWork() }
            }
        }

        private var isUserInteracting: Bool {
            userScrolling || liveScrolling || scrollerTracking || selectionTracking
        }

        private func jumpToBottomForUITest() {
            guard TraceTestHooks.isUITesting else { return }
            cancelPendingRestore(reportCancellation: false)
            cancelBottomFollowWork()
            pendingAnchorRestore = nil
            for step in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(step * 100)) {
                    [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let table = self.table else { return }
                        self.applyingProgrammaticScroll = true
                        table.layoutSubtreeIfNeeded()
                        self.scrollToBottom()
                        self.rememberProgrammaticOrigin()
                        self.applyingProgrammaticScroll = false
                        self.followsBottom = true
                        self.pendingBottomFollow = false
                        self.positionEstablished = true
                        if step == 2 {
                            self.probeTranscriptPositionForUITest()
                            TraceTestHooks.touch(
                                pathKey: "TRACE_TEST_TRANSCRIPT_JUMP_DONE_PATH"
                            )
                        }
                    }
                }
            }
        }

        private func probeTranscriptPositionForUITest() {
            guard TraceTestHooks.isUITesting, let scrollView else { return }
            // The anchor probe reads the first settled native geometry without
            // causing another automatic-height mutation while taking the sample.
            if TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_ANCHOR_INDEX_PATH"] == nil {
                table?.layoutSubtreeIfNeeded()
            }
            guard let maximumScrollY = exactMaximumScrollY else { return }
            recordVisibleGapForUITest()
            TraceTestHooks.appendLine(
                "\(Double(scrollView.contentView.bounds.origin.y)),\(Double(maximumScrollY)),\(followsBottom)",
                pathKey: "TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"
            )
            if let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_ANCHOR_INDEX_PATH"],
               let text = try? String(contentsOfFile: path, encoding: .utf8),
               let index = Int(text), let table,
               let row = items.firstIndex(where: { $0.sourceIndex == index }) {
                let rect = table.rect(ofRow: row)
                let viewport = scrollView.documentVisibleRect
                TraceTestHooks.appendLine(
                    "\(index),\(rect.minY - viewport.minY),\(rect.intersects(viewport)),\(positionEstablished && pendingRestore?.reason.reportsHooks != true),\(sessionID)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_ANCHOR_POSITION_PATH"
                )
            }
        }

        private func correctEstablishedAnchor() {
            guard positionEstablished, !applyingProgrammaticScroll, !isUserInteracting,
                  !followsBottom, restoreGateTask == nil,
                  pendingRestore?.reason.isExplicitNavigation != true,
                  let bookmark = pendingRestore?.bookmark ?? establishedBookmark,
                  let row = rowByMessageID[bookmark.messageID], let table, let scrollView else { return }
            let desired = table.rect(ofRow: row).minY - bookmark.offset
            guard abs(desired - scrollView.contentView.bounds.origin.y) > 1 else { return }
            // Coalesced automatic-height changes must settle before the next
            // main-loop turn, even while the height-invalidation batch is pending.
            applyingProgrammaticScroll = true
            let origin = constrainedOrigin(for: desired, table: table, scrollView: scrollView)
            guard !originsMatch(origin, scrollView.contentView.bounds.origin) else {
                applyingProgrammaticScroll = false
                return
            }
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
        }

        private func sampleEstablishedAnchorForUITest() {
            guard TraceTestHooks.isUITesting,
                  TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_ANCHOR_SAMPLES_PATH"] != nil,
                  positionEstablished, let table, let scrollView,
                  let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_ANCHOR_INDEX_PATH"],
                  let text = try? String(contentsOfFile: path, encoding: .utf8), let index = Int(text),
                  let row = items.firstIndex(where: { $0.sourceIndex == index }) else { return }
            let rect = table.rect(ofRow: row)
            let viewport = scrollView.documentVisibleRect
            TraceTestHooks.appendLine("\(index),\(rect.minY - viewport.minY),\(rect.intersects(viewport)),\(sessionID)",
                pathKey: "TRACE_TEST_TRANSCRIPT_ANCHOR_SAMPLES_PATH")
        }

        private func simulateTranscriptScrollForUITest() {
            TraceTestHooks.appendLine(
                "simulation-received,items=\(items.count),scroll=\(scrollView != nil)",
                pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"
            )
            guard TraceTestHooks.isUITesting, let scrollView, let maximumScrollY else { return }
            let simulation = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"]
            switch simulation {
            case "external-midpoint":
                TraceTestHooks.appendLine(
                    "simulate-before=\(scrollView.contentView.bounds.origin.y),max=\(maximumScrollY)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"
                )
                var origin = scrollView.contentView.bounds.origin
                origin.y = maximumScrollY / 2
                scrollView.contentView.setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                TraceTestHooks.appendLine(
                    "simulate-after=\(scrollView.contentView.bounds.origin.y)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"
                )
            case "disclosure-position":
                guard let table, !items.isEmpty else { return }
                applyingProgrammaticScroll = true
                table.scrollRowToVisible(items.count - 1)
                table.layoutSubtreeIfNeeded()
                rememberProgrammaticOrigin()
                applyingProgrammaticScroll = false
            case "focus-text":
                func selectableText(in view: NSView) -> MessageTextView? {
                    if let text = view as? MessageTextView { return text }
                    for child in view.subviews {
                        if let text = selectableText(in: child) { return text }
                    }
                    return nil
                }
                if let table, let text = selectableText(in: table) {
                    scrollView.window?.makeFirstResponder(text)
                }
            case "delayed-resize":
                guard let window = scrollView.window else { return }
                let origin = scrollView.contentView.bounds.origin
                let size = scrollView.contentView.bounds.size
                scrollView.contentView.postsBoundsChangedNotifications = false
                let originalFrame = window.frame
                var frame = originalFrame
                frame.origin.y -= 20
                frame.size.height += 20
                window.setFrame(frame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                let resized = scrollView.contentView.bounds.size
                let delta = resized.height - size.height
                // The size phase has already been observed. Deliver the origin
                // phase separately, with a real changed viewport extent.
                lastObservedViewportSize = resized
                lastObservedDocumentHeight = table?.frame.height
                resizeTransaction = ResizeTransaction(initiallyFollowing: followsBottom, viewportDelta: delta,
                    expires: .now.advanced(by: .milliseconds(500)), inputGeneration: userInputGeneration)
                expectedProgrammaticOrigin = nil
                lastObservedOrigin = origin
                scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y - delta))
                // Deliver within the existing expiry; the test controls notification
                // timing instead of depending on the automation runner's load.
                boundsDidChange()
                scrollView.contentView.postsBoundsChangedNotifications = true
                TraceTestHooks.appendLine("simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                window.setFrame(originalFrame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "multi-stage-resize":
                guard let window = scrollView.window, let table else { return }
                let origin = scrollView.contentView.bounds.origin
                let oldSize = scrollView.contentView.bounds.size
                let oldHeight = table.frame.height
                scrollView.contentView.postsBoundsChangedNotifications = false
                var frame = window.frame
                frame.size.height -= 80
                window.setFrame(frame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                table.setFrameSize(NSSize(width: table.frame.width, height: max(0, oldHeight - 264)))
                lastObservedOrigin = origin
                lastObservedViewportSize = oldSize
                lastObservedDocumentHeight = oldHeight
                expectedProgrammaticOrigin = nil
                let viewportDelta = scrollView.contentView.bounds.height - oldSize.height
                scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y - 264 - viewportDelta))
                boundsDidChange()
                let intermediate = scrollView.contentView.bounds.origin
                scrollView.contentView.setBoundsOrigin(NSPoint(x: intermediate.x, y: intermediate.y + viewportDelta))
                boundsDidChange()
                scrollView.contentView.postsBoundsChangedNotifications = true
                TraceTestHooks.appendLine("simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "expired-resize", "interrupted-resize":
                resizeTransaction = ResizeTransaction(initiallyFollowing: true, viewportDelta: -80,
                    expires: .now.advanced(by: .milliseconds(simulation == "expired-resize" ? -1 : 500)),
                    inputGeneration: userInputGeneration)
                if simulation == "interrupted-resize" { beginUserScrolling() }
                expectedProgrammaticOrigin = nil
                lastObservedOrigin = scrollView.contentView.bounds.origin
                var origin = scrollView.contentView.bounds.origin
                origin.y -= 24
                scrollView.contentView.setBoundsOrigin(origin)
                boundsDidChange()
                TraceTestHooks.appendLine("simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "row-extent":
                guard let table else { return }
                applyingProgrammaticScroll = true
                let bottom = table.rect(ofRow: items.count - 1).maxY
                table.setFrameSize(NSSize(width: table.frame.width, height: max(0, bottom - 100)))
                cachedRowExtent = nil
                let maximum = self.maximumScrollY ?? -1
                TraceTestHooks.appendLine("extent=\(maximum),expected=\(max(0, bottom - scrollView.contentView.bounds.height))",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                scrollToBottom()
                rememberProgrammaticOrigin()
                applyingProgrammaticScroll = false
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "rubber-band-return":
                beginUserScrolling()
                liveScrolling = true
                upwardScrollTravel = 24
                scrollView.contentView.postsBoundsChangedNotifications = false
                let actual = NSPoint(x: scrollView.contentView.bounds.origin.x, y: maximumScrollY)
                scrollView.contentView.setBoundsOrigin(actual)
                recordUserViewportMotion(from: NSPoint(x: actual.x, y: maximumScrollY + 24), to: actual)
                scrollView.contentView.postsBoundsChangedNotifications = true
                TraceTestHooks.appendLine("simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                liveScrolling = false
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "growing-up":
                guard let table else { return }
                beginUserScrolling()
                // Coalesce document growth and reader movement into one bounds
                // notification, as can happen during a streaming layout pass.
                let origin = scrollView.contentView.bounds.origin
                scrollView.contentView.postsBoundsChangedNotifications = false
                table.setFrameSize(NSSize(width: table.frame.width, height: table.frame.height + 100))
                scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y - 4))
                scrollView.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.post(
                    name: NSView.boundsDidChangeNotification, object: scrollView.contentView
                )
                TraceTestHooks.appendLine(
                    "simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "slow-up":
                beginUserScrolling()
                liveScrolling = true
                for step in 1...12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(step * 100)) {
                        [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, let scrollView = self.scrollView else { return }
                            var origin = scrollView.contentView.bounds.origin
                            origin.y = max(0, origin.y - 0.5)
                            scrollView.contentView.setBoundsOrigin(origin)
                            scrollView.reflectScrolledClipView(scrollView.contentView)
                            if step == 12 {
                                TraceTestHooks.touch(
                                    pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH"
                                )
                            }
                        }
                    }
                }
            default:
                break
            }
        }

        private func attachBenchmarkObserverForUITest() {
            guard TraceTestHooks.isUITesting else { return }
            benchmarkObserver = DistributedNotificationCenter.default().addObserver(
                forName: .traceTestTranscriptBenchmark, object: nil, queue: .main
            ) { [weak self] notification in
                let requested = notification.userInfo?["sweep"] as? Int
                MainActor.assumeIsolated {
                    guard let self, !self.benchmarkSweepRunning,
                          let requested,
                          requested > self.benchmarkSweepIndex else { return }
                    self.startBenchmarkScrollSweep(requested)
                }
            }
        }

        private func startBenchmarkScrollSweep(_ sweep: Int) {
            guard let table, let scrollView, !items.isEmpty else { return }
            benchmarkSweepRunning = true
            benchmarkSweepIndex = sweep
            beginUserScrolling()
            table.layoutSubtreeIfNeeded()
            let distance = min(5_000, max(0,
                table.frame.height - scrollView.contentView.bounds.height))
            benchmarkScrollStep(0, sweep: sweep, distance: distance)
        }

        private func benchmarkScrollStep(_ step: Int, sweep: Int, distance: CGFloat) {
            guard let table, let scrollView else { benchmarkSweepRunning = false; return }
            let progress = step <= 20 ? step : 40 - step
            var origin = scrollView.contentView.bounds.origin
            origin.y = distance * CGFloat(progress) / 20
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            table.layoutSubtreeIfNeeded()
            if step < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.benchmarkScrollStep(step + 1, sweep: sweep, distance: distance)
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.finishUserScrolling()
                        self.benchmarkSweepRunning = false
                        if let prefix = TraceTestHooks.environment[
                            "TRACE_TEST_TRANSCRIPT_SCROLL_SWEEP_DONE_PREFIX"
                        ] {
                            try? String(Double(distance)).write(
                                to: URL(fileURLWithPath: "\(prefix)-\(sweep)"),
                                atomically: true, encoding: .utf8
                            )
                        }
                    }
                }
            }
        }

        private func recordVisibleGapForUITest() {
            guard TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_GAP_OFFSET_PATH"] != nil,
                  let table, let scrollView, items.count > 1 else { return }
            let visible = scrollView.documentVisibleRect
            let gapHeight = table.intercellSpacing.height
            guard gapHeight >= 4 else { return }
            for row in 1..<items.count {
                let middle = table.rect(ofRow: row).minY - gapHeight / 2
                if middle > visible.minY + 16, middle < visible.maxY - 16 {
                    TraceTestHooks.appendLine(
                        String(Double(middle - visible.minY)),
                        pathKey: "TRACE_TEST_TRANSCRIPT_GAP_OFFSET_PATH"
                    )
                    return
                }
            }
        }

        private func rememberProgrammaticOrigin() {
            let origin = scrollView?.contentView.bounds.origin
            expectedProgrammaticOrigin = origin
            lastObservedOrigin = origin
            lastObservedViewportSize = scrollView?.contentView.bounds.size
            lastObservedDocumentHeight = table?.frame.height
        }

        private func originsMatch(_ lhs: NSPoint, _ rhs: NSPoint) -> Bool {
            abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
        }

        private func capturePosition(allowImplicitBottom: Bool = false) -> PositionSnapshot {
            let implicitBottom = allowImplicitBottom && positionEstablished
                && !userScrolling && !liveScrolling && isAtSettledBottom
            let pinned = followsBottom
            return .init(
                bookmark: pendingRestore?.bookmark ?? (isUserInteracting ? nil : establishedBookmark) ?? currentBookmark(),
                followsBottom: pinned || implicitBottom
            )
        }

        private func reconcilePosition(
            _ snapshot: PositionSnapshot, reason: RestoreRequest.Reason,
            refreshesRowHeights: Bool = false
        ) {
            guard !items.isEmpty else { return }
            if let pendingRestore, pendingRestore.reason.priority > reason.priority { return }
            if snapshot.followsBottom {
                cancelPendingRestore(reportCancellation: false)
                followsBottom = true
                pendingAnchorRestore = nil
                if userScrolling || liveScrolling || !isViewportWithinBounds {
                    pendingBottomFollow = true
                    if !userScrolling { scheduleBookmarkSave(reportStart: false) }
                } else {
                    pendingBottomFollow = false
                    applyBottomPosition()
                    scheduleBottomFollow()
                }
            } else if let bookmark = snapshot.bookmark {
                followsBottom = false
                if !userScrolling && !liveScrolling && isViewportWithinBounds {
                    pendingAnchorRestore = nil
                    requestRestore(
                        bookmark, reason: reason,
                        refreshesRowHeights: refreshesRowHeights
                    )
                } else if case .passive = reason {
                    pendingAnchorRestore = bookmark
                } else {
                    pendingAnchorRestore = nil
                }
            }
        }

        private struct ExtentGeometry: Equatable {
            let frame: NSRect
            let bounds: NSRect
            let spacing: NSSize
            let rows: Int
        }
        private var cachedRowExtent: (geometry: ExtentGeometry, bottom: CGFloat)?

        private var maximumScrollY: CGFloat? {
            guard let table, let scrollView else { return nil }
            let geometry = ExtentGeometry(frame: table.frame, bounds: table.bounds,
                                          spacing: table.intercellSpacing, rows: items.count)
            if cachedRowExtent?.geometry != geometry {
                cachedRowExtent = (geometry, items.isEmpty ? 0 : table.rect(ofRow: items.count - 1).maxY)
            }
            return TranscriptViewportPolicy.maximumOrigin(frameHeight: table.frame.height,
                lastRowBottom: cachedRowExtent?.bottom ?? 0, viewportHeight: scrollView.contentView.bounds.height)
        }

        private var exactMaximumScrollY: CGFloat? { maximumScrollY }

        private func prepareDocumentExtent() -> CGFloat? {
            _ = maximumScrollY
            if let table, let bottom = cachedRowExtent?.bottom, bottom > table.frame.height {
                // NSClipView constrains origins to the document frame. Include an
                // already measured row extending beyond it before applying an origin.
                table.setFrameSize(NSSize(width: table.frame.width, height: bottom))
                cachedRowExtent = nil
            }
            return maximumScrollY
        }

        private var viewportStatus: (withinBounds: Bool, atBottom: Bool) {
            guard let scrollView, let maximumScrollY else { return (false, false) }
            let y = scrollView.contentView.bounds.origin.y
            let withinBounds = y >= -0.5 && y <= maximumScrollY + 0.5
            return (withinBounds, !items.isEmpty && withinBounds && maximumScrollY - y <= 2)
        }

        private var isViewportWithinBounds: Bool { viewportStatus.withinBounds }

        private var isAtSettledBottom: Bool {
            viewportStatus.atBottom
        }

        private func applyBottomPosition() {
            establishedBookmark = nil
            guard !items.isEmpty, !isUserInteracting, isViewportWithinBounds else { return }
            applyingProgrammaticScroll = true
            TraceTestHooks.appendLine("layout", pathKey: "TRACE_TEST_TRANSCRIPT_LAYOUT_AUDIT_PATH")
            table?.layoutSubtreeIfNeeded()
            let finalMaximumY = scrollToBottom()
            rememberProgrammaticOrigin()
            applyingProgrammaticScroll = false
            followsBottom = true
            if let scrollView, let finalMaximumY {
                TraceTestHooks.appendLine(
                    "\(Double(scrollView.contentView.bounds.origin.y)),\(Double(finalMaximumY))",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOTTOM_AUDIT_PATH"
                )
            }
            if TraceTestHooks.isUITesting,
               let prefix = TraceTestHooks.environment[
                   "TRACE_TEST_TRANSCRIPT_FOLLOW_MARKER_PREFIX"
               ] {
                try? Data().write(to: URL(fileURLWithPath: "\(prefix)-\(items.count)"))
            }
        }

        private func cancelBottomFollowWork() {
            bottomFollowWorkItem?.cancel()
            bottomFollowWorkItem = nil
        }

        private func scheduleBottomFollow() {
            guard followsBottom, !items.isEmpty, table != nil, bottomFollowWorkItem == nil,
                  !isAtSettledBottom else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.applyScheduledBottomFollow() }
            }
            bottomFollowWorkItem = work
            DispatchQueue.main.async(execute: work)
        }

        private func applyScheduledBottomFollow() {
            bottomFollowWorkItem = nil
            guard followsBottom, table != nil else { return }
            if isUserInteracting {
                pendingBottomFollow = true
                return
            }
            TraceTestHooks.appendLine("follow", pathKey: "TRACE_TEST_TRANSCRIPT_FOLLOW_AUDIT_PATH")
            applyBottomPosition()
        }

        @discardableResult
        private func scrollToBottom() -> CGFloat? {
            guard let scrollView, !items.isEmpty, let maximumScrollY = prepareDocumentExtent() else { return nil }
            var origin = scrollView.contentView.bounds.origin
            origin.y = maximumScrollY
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return maximumScrollY
        }

    }
}

@MainActor
private final class TranscriptHostingCell: NSTableCellView {
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
        host.translatesAutoresizingMaskIntoConstraints = false
        // Each row owns its padding and the table owns viewport clipping. Window
        // safe-area insets must not resize or shift a partially visible row.
        host.safeAreaRegions = []
        host.sizingOptions = .intrinsicContentSize
        host.setContentCompressionResistancePriority(.required, for: .vertical)
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
        host.invalidateIntrinsicContentSize()
    }

    func refreshHostedSize() {
        // A disclosure can update SwiftUI's ideal height before its hosting
        // constraints have caught up. Refresh those before AppKit fits the row.
        host.invalidateIntrinsicContentSize()
        host.needsUpdateConstraints = true
        host.updateConstraintsForSubtreeIfNeeded()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    var layoutDescription: String {
        "\(frame),host=\(host.frame),ideal=\(host.intrinsicContentSize),fitting=\(fittingSize),safeArea=\(host.safeAreaInsets)"
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
    let selectionTrackingChanged: (Bool) -> Void

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
            .task(id: HydrationTaskID(
                visibility: visibility, sourcePath: summary.sourcePath,
                needsHydration: hydrated == nil,
                lazyExpanded: expansion.auxiliary
            )) {
                if hydrated == nil && (!isLazyAuxiliary || expansion.auxiliary) { hydrate() }
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
                TranscriptDisclosure(isExpanded: $expansion.auxiliary) {
                    Text(safePreview ?? neutralPlaceholder)
                        .font(.callout.monospaced())
                        .lineLimit(expansion.auxiliary ? nil : 2)
                } content: {
                    sectionContents(hydrated)
                }
                .onChange(of: expansion.auxiliary) { _, expanded in if expanded { hydrate() } }
            } else {
                sectionContents(hydrated)
            }
        } else if isLazyAuxiliary {
            TranscriptDisclosure(isExpanded: $expansion.auxiliary) {
                Text(safePreview ?? neutralPlaceholder)
                    .font(.callout.monospaced())
                    .lineLimit(2)
            } content: {
                if hydrationFailed { Text("Unable to load visible content.").foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
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
                heightChanged: heightChanged,
                selectionTrackingChanged: selectionTrackingChanged
            )
        }
        if visibility.includes(role: summary.role), visibility.tools && !message.sections.toolInvocation.isEmpty {
            TranscriptDisclosure(isExpanded: $expansion.toolInvocation) {
                Text("Tool invocation")
            } content: {
                SelectableMessageText(
                    text: AttributedString(message.sections.toolInvocation),
                    monospaced: true, copyMessage: copyMessage,
                    selectionTrackingChanged: selectionTrackingChanged
                )
            }
        }
        if visibility.includes(role: summary.role), visibility.tools && !message.sections.toolOutput.isEmpty {
            TranscriptDisclosure(isExpanded: $expansion.toolOutput) {
                Text("Tool output")
            } content: {
                SelectableMessageText(
                    text: AttributedString(message.sections.toolOutput),
                    monospaced: true, copyMessage: copyMessage,
                    selectionTrackingChanged: selectionTrackingChanged
                )
            }
        }
        if visibility.includes(role: summary.role), visibility.reasoning && !message.sections.reasoning.isEmpty {
            TranscriptDisclosure(isExpanded: $reasoningExpanded) {
                Label("Reasoning", systemImage: "brain")
            } content: {
                SelectableMessageText(
                    text: AttributedString(message.sections.reasoning),
                    secondary: true, copyMessage: copyMessage,
                    selectionTrackingChanged: selectionTrackingChanged
                )
            }
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

    private struct HydrationTaskID: Hashable {
        let visibility: TranscriptVisibility
        let sourcePath: String
        let needsHydration: Bool
        let lazyExpanded: Bool
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
