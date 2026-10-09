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
                        Button(model.hasSearchReturnContext ? "Back to results" : "Back to project", systemImage: "chevron.left") { model.returnFromSession() }
                            .accessibilityIdentifier("backToProject")
                        if TraceTestHooks.showsTestControls {
                            Button("Open search", systemImage: "magnifyingglass") {
                                NotificationCenter.default.post(name: .traceShowLauncher, object: nil)
                            }
                            .accessibilityIdentifier("testOpenLauncher")
                            Button("Resize window", systemImage: "arrow.up.left.and.arrow.down.right") {
                                guard let window = NSApp.keyWindow else { return }
                                let frame = window.frame
                                window.setFrame(NSRect(
                                    x: frame.minX, y: frame.minY,
                                    width: frame.width + (Double(TraceTestHooks.environment["TRACE_TEST_WINDOW_WIDTH_DELTA"] ?? "-120") ?? -120),
                                    height: frame.height + (Double(TraceTestHooks.environment["TRACE_TEST_WINDOW_HEIGHT_DELTA"] ?? "-80") ?? -80)
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
                    IndexProgressLabel(progress: model.progress, monitoringWarnings: model.monitoringWarnings)
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
                        let navigationKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
                        relevant = navigationKeys.contains(event.keyCode) && ((window.firstResponder as? NSView).map {
                            $0 === scroll || $0.isDescendant(of: scroll)
                        } ?? false)
                    } else {
                        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                        relevant = column.contains(point)
                    }
                    if relevant { self.stop(); interrupted(token) }
                }
                return event
            }
            task = Task { @MainActor [weak self, weak view] in
                var progress = SidebarRevealProgress()
                let deadlineSeconds = 3.0
                var deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
                let testClockPath = TraceTestHooks.isUITesting
                    ? TraceTestHooks.environment["TRACE_TEST_SIDEBAR_REVEAL_CLOCK_PATH"] : nil
                let testClockStart = testClockPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.flatMap(Double.init)
                let testBackstop = ContinuousClock.now.advanced(by: .seconds(15))
                var previousCheck = ContinuousClock.now
                var attempt = 0
                while ContinuousClock.now < deadline {
                    defer { attempt += 1 }
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                    guard let self, let view, !Task.isCancelled, self.token == token else { return }
                    let now = ContinuousClock.now
                    if let clockPath = testClockPath, let testClockStart,
                       let raw = try? String(contentsOfFile: clockPath, encoding: .utf8),
                       let tick = Double(raw), tick - testClockStart >= deadlineSeconds {
                        TraceTestHooks.touch(pathKey: "TRACE_TEST_SIDEBAR_REVEAL_EXPIRED_PATH")
                        self.stop()
                        return
                    }
                    if TraceTestHooks.isUITesting,
                       let gate = TraceTestHooks.environment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_RELEASE_PATH"],
                       !FileManager.default.fileExists(atPath: gate) {
                        guard now < testBackstop else { return }
                        deadline = deadline.advanced(by: previousCheck.duration(to: now))
                    }
                    previousCheck = now
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
                                    Text("\(project.sessionCount.formatted()) \(project.sessionCount == 1 ? "session" : "sessions")").font(.caption2).foregroundStyle(.secondary)
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
                        .task(id: projectRevealTaskID) {
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
                        Text("\(model.totalSessionCount.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sessionTotalCount")
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
                            if model.isLoadingSessions {
                                ProgressView().controlSize(.small)
                            } else if let error = model.sessionListError {
                                VStack(alignment: .leading) {
                                    Text(error).font(.caption).foregroundStyle(.secondary)
                                    Button("Retry") { model.retrySessionLoad() }
                                        .accessibilityIdentifier("retrySessionPage")
                                }
                            } else if model.hasMoreSessions {
                                Button("Load more") { model.loadMoreSessions() }
                                    .accessibilityIdentifier("loadMoreSessions")
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
    let sourceGeneration: Int64?
    let locator: RecordLocator
    let sectionFlags: Int?
    let hydratedRole: MessageRole?
    let hydratedSections: MessageSections?
    let hydratedToolName: String?
    let hydratedHasError: Bool?
    let hydrationError: String?
    let visibility: TranscriptVisibility
    let reasoningExpanded: Bool

    init(
        message: MessageSummary, hydrated: HydratedMessage?, hydrationError: String?,
        visibility: TranscriptVisibility, reasoningExpanded: Bool, sourceGeneration: Int64?
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
        self.sourceGeneration = sourceGeneration
        locator = message.locator
        sectionFlags = message.sectionFlags
        hydratedRole = hydrated?.role
        hydratedSections = hydrated?.sections
        hydratedToolName = hydrated?.toolName
        hydratedHasError = hydrated?.hasError
        self.hydrationError = hydrationError
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
        if TraceTestHooks.isUITesting,
           TraceTestHooks.environment["TRACE_TEST_SNAPSHOT_APPEARANCE"] != nil {
            // Offscreen row estimates vary the thumb geometry. Scrolling has its
            // own UI coverage; omit this transient control from static snapshots.
            scroller.alphaValue = 0
        }
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
            var effectiveBookmark: TranscriptBookmark
            let reason: Reason
            var refreshesRowHeights: Bool
            var attemptsRemaining: Int
            var stableChecks = 0
            var refreshedRowHeights = false
            var refreshedTargetRowHeight = false
            var revealedTargetRow = false
            var lastDocumentHeight: CGFloat?
            var lastTargetHeight: CGFloat?

            mutating func resetRefinement() {
                attemptsRemaining = 12
                stableChecks = 0
                refreshedRowHeights = false
                refreshedTargetRowHeight = false
                lastDocumentHeight = nil
                lastTargetHeight = nil
            }
            var inputGeneration: UInt64 = 0
            var sessionID: Int64 = 0

            init(
                bookmark: TranscriptBookmark, reason: Reason,
                refreshesRowHeights: Bool
            ) {
                self.bookmark = bookmark
                effectiveBookmark = bookmark
                self.reason = reason
                self.refreshesRowHeights = refreshesRowHeights
                attemptsRemaining = 12
            }
        }

        private struct DeferredContentRestore {
            let token = UUID()
            let bookmark: TranscriptBookmark
            let reason: RestoreRequest.Reason
            let sessionID: Int64
            let inputGeneration: UInt64
        }

        private var deferredContentRestore: DeferredContentRestore?
        private var hydrationTimeoutWorkItem: DispatchWorkItem?

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
        private var failedMessages: [Int64: String] = [:]
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
        private var settledBottomInputGeneration: UInt64?
        private var injectedAppendAdjustmentForUITest = false
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
        private var pendingScrollIdleCycle: UUID?
        private var scrollIdleReadyToSave = false

        deinit {
            observers.removeAll()
        }

        func attach(table: NSTableView, scrollView: NSScrollView) {
            self.table = table
            self.scrollView = scrollView
            observeDocumentGeometry()
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
                    MainActor.assumeIsolated {
                        self?.observeDocumentGeometry()
                        self?.scheduleBottomFollow()
                    }
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
            cancelDeferredContentRestore()
            if let inputMonitor {
                NSEvent.removeMonitor(inputMonitor)
                self.inputMonitor = nil
            }
            expectedProgrammaticOrigin = nil
            lastObservedOrigin = nil
            lastObservedViewportSize = nil
            lastObservedDocumentHeight = nil
            resizeTransaction = nil
            settledBottomInputGeneration = nil
            pendingDocumentBottomShift = nil
            extentRefreshWorkItem?.cancel()
            extentRefreshWorkItem = nil
            pendingAnchorCorrection = false
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
            pendingScrollIdleCycle = nil
            scrollIdleReadyToSave = false
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
                invalidateDocumentExtent()
            }
            let sessionChanged = self.sessionID != sessionID
            let requestedMessageWasAvailable = model.requestedMessageID.map {
                rowByMessageID[$0] != nil
            } ?? false
            var refreshesRowHeights = false
            var visibilityChanged = false
            if sessionChanged {
                cachedTrailingDocumentPadding = nil
                settledBottomInputGeneration = nil
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
            if sessionChanged {
                pendingScrollIdleCycle = nil
                scrollIdleReadyToSave = false
            }
            self.sessionID = sessionID
            let refinementChanged = self.messageRevision != messageRevision
                || self.visibility != visibility || self.density != density
                || self.contentRevision != contentRevision
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
                positionBeforeMutation = positionBeforeMutation
                    ?? pendingInteractionBookmark.map {
                        PositionSnapshot(bookmark: $0, followsBottom: false)
                    }
                    ?? capturePosition()
                let newHydrated = Set(model.hydratedMessages.keys)
                let changedFailures = Set(failedMessages.keys).union(model.hydrationFailures.keys)
                    .filter { failedMessages[$0] != model.hydrationFailures[$0] }
                let changed = hydratedIDs.symmetricDifference(newHydrated)
                    .union(changedFailures)
                    .union(expandedIDs.symmetricDifference(model.expandedReasoningIDs))
                hydratedIDs = newHydrated
                failedMessages = model.hydrationFailures
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
            if refinementChanged, pendingRestore != nil {
                pendingRestore?.resetRefinement()
                if restoreGateTask == nil, let pendingRestore {
                    applyRestore(token: pendingRestore.token)
                }
            }
            refreshDeferredContentRestore()
            if !items.isEmpty, pendingRestore == nil { positionEstablished = true }
            if TraceTestHooks.isUITesting,
               TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] == "rubber-band-return",
               items.count == 71, !injectedAppendAdjustmentForUITest {
                injectedAppendAdjustmentForUITest = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let scrollView = self.scrollView,
                              let maximum = self.exactMaximumScrollY else { return }
                        // AppKit can restore the old bottom after the appended
                        // row changes the document extent, without new input.
                        var origin = scrollView.contentView.bounds.origin
                        origin.y = maximum
                        scrollView.contentView.setBoundsOrigin(origin)
                        origin.y = max(0, maximum - 86)
                        scrollView.contentView.setBoundsOrigin(origin)
                        TraceTestHooks.appendLine("post-append-native-motion",
                            pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                    }
                }
            }
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
            if TraceTestHooks.isUITesting { materializedMessageIDs.insert(item.summary.id) }
            let identifier = NSUserInterfaceItemIdentifier("messageCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptHostingCell)
                ?? TranscriptHostingCell(identifier: identifier)
            let message = item.summary
            let expansion = expansionState(for: message.id)
            let hydrated = model.hydratedMessages[message.id]
            let hydrationError = model.hydrationFailures[message.id]
            let rowView = MessageRow(
                summary: message,
                sourceGeneration: model.selectedSession?.sourceGeneration,
                hydrated: hydrated,
                hydrationError: hydrationError,
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
                retryHydration: { [weak model] in model?.retryHydration(message) },
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
                    hydrationError: hydrationError,
                    visibility: visibility,
                    reasoningExpanded: model.expandedReasoningIDs.contains(message.id),
                    sourceGeneration: model.selectedSession?.sourceGeneration
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
            let persisted = deferredContentRestore?.bookmark ?? bookmark
            model.scrollPositions[sessionID] = persisted
            TraceTestHooks.appendLine("\(persisted.index),\(persisted.offset)",
                pathKey: "TRACE_TEST_TRANSCRIPT_PERSISTED_BOOKMARK_PATH")
            if TraceTestHooks.isUITesting,
               let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] {
                try? Data("\(bookmark.index)".utf8).write(to: URL(fileURLWithPath: path))
            }
            completeScrollIdleCycleIfSaved()
        }

        private func completeScrollIdleCycleIfSaved() {
            guard let cycle = pendingScrollIdleCycle, scrollIdleReadyToSave, !isUserInteracting,
                  !pendingIdleSaveAfterRestore, pendingRestore == nil else { return }
            pendingScrollIdleCycle = nil
            scrollIdleReadyToSave = false
            TraceTestHooks.appendLine("finished,\(cycle)",
                pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH")
            TraceTestHooks.appendLine("finished", pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH")
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
                let cycle = UUID()
                pendingScrollIdleCycle = cycle
                scrollIdleReadyToSave = false
                TraceTestHooks.appendLine("started,\(cycle)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH")
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
            if TraceTestHooks.isUITesting,
               let raw = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_BOOKMARK_INDEX"],
               let index = Int(raw), model.messages.indices.contains(index) {
                model.scrollPositions[sessionID] = .init(messageID: model.messages[index].id,
                    offset: Double(TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_BOOKMARK_OFFSET"] ?? "0") ?? 0,
                    index: index)
            }
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
            let activePriority = max(pendingRestore?.reason.priority ?? -1,
                                     deferredContentRestore?.reason.priority ?? -1)
            if activePriority > reason.priority, !reason.isExplicitNavigation { return }
            if var active = pendingRestore, !reason.isExplicitNavigation,
               active.sessionID == sessionID, active.inputGeneration == userInputGeneration,
               active.effectiveBookmark.messageID == bookmark.messageID {
                if refreshesRowHeights {
                    active.refreshesRowHeights = true
                    active.resetRefinement()
                }
                pendingRestore = active
                return
            }
            beginRestore(request)
        }

        private func beginRestore(_ initialRequest: RestoreRequest) {
            var request = initialRequest
            request.inputGeneration = userInputGeneration
            request.sessionID = sessionID
            cancelPendingRestore(reportCancellation: false, preserveDeferred: !request.reason.isExplicitNavigation)
            pendingRestore = request
            if case .search = request.reason {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_STARTED_PATH")
            }
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

        private func cancelDeferredContentRestore() {
            hydrationTimeoutWorkItem?.cancel()
            hydrationTimeoutWorkItem = nil
            deferredContentRestore = nil
        }

        private func deferContentRestore(_ request: RestoreRequest) {
            guard deferredContentRestore == nil else { return }
            let deferred = DeferredContentRestore(bookmark: request.bookmark, reason: request.reason,
                sessionID: sessionID, inputGeneration: userInputGeneration)
            deferredContentRestore = deferred
            TraceTestHooks.appendLine("waiting,\(deferred.bookmark.index),\(deferred.bookmark.offset),12",
                pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_RESTORE_AUDIT_PATH")
            // This timer only synchronizes timeout regression tests. Restoration
            // itself wakes on content or layout changes, never on elapsed time.
            guard TraceTestHooks.isUITesting else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let current = self.deferredContentRestore,
                          current.token == deferred.token else { return }
                    self.hydrationTimeoutWorkItem = nil
                    TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_TIMEOUT_PATH")
                    TraceTestHooks.appendLine("timeout,\(current.bookmark.index),\(current.bookmark.offset),0,\(self.model?.scrollPositions[self.sessionID]?.offset ?? 0)",
                        pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_RESTORE_AUDIT_PATH")
                }
            }
            hydrationTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: work)
        }

        private func refreshDeferredContentRestore() {
            guard let deferred = deferredContentRestore else { return }
            guard deferred.sessionID == sessionID, deferred.inputGeneration == userInputGeneration,
                  !isUserInteracting else {
                cancelDeferredContentRestore()
                return
            }
            guard let row = rowByMessageID[deferred.bookmark.messageID] else {
                cancelDeferredContentRestore()
                if pendingRestore == nil { requestRestore(deferred.bookmark, reason: .passive) }
                return
            }
            let target = items[row].summary
            if model?.hydratedMessages[target.id] != nil {
                // Content revisions already restart active refinement in update().
                // An unrelated redraw must not spend another attempt, especially
                // after the geometry budget is exhausted.
                if pendingRestore == nil {
                    cancelDeferredContentRestore()
                    requestRestore(deferred.bookmark, reason: deferred.reason)
                }
            } else {
                model?.hydrate(target)
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

        // Reserve the placeholder's loading/error action area in both restore paths.
        private static let placeholderFooterAllowance: CGFloat = 63

        private func restorationContentReady(_ request: RestoreRequest, target: MessageSummary) -> Bool {
            let collapsed = TranscriptRowContent.isLazyAuxiliary(role: target.role, visibility: visibility)
                && !expansionState(for: target.id).auxiliary
            let initialTop = request.reason.priority == RestoreRequest.Reason.navigation.priority
                && model?.scrollPositions[sessionID] == nil && request.bookmark.index == 0 && request.bookmark.offset == 0
            return initialTop || collapsed || model?.hydratedMessages[target.id] != nil
        }

        private func restorationHeight(_ height: CGFloat, ready: Bool) -> CGFloat {
            ready ? height : max(1, height - Self.placeholderFooterAllowance)
        }

        private func applyRestore(token: UUID) {
            guard !items.isEmpty else {
                cancelPendingRestore(reportCancellation: true, cause: .lifecycle)
                return
            }
            guard var request = pendingRestore, request.token == token,
                  request.attemptsRemaining > 0,
                  let table, let scrollView, !userScrolling else { return }
            let performanceInterval = TracePerformance.begin("Transcript Restore")
            defer { TracePerformance.end(performanceInterval) }
            guard request.sessionID == sessionID, request.inputGeneration == userInputGeneration else {
                cancelPendingRestore(reportCancellation: true, cause: .userInteraction)
                return
            }
            var bookmark = deferredContentRestore?.bookmark ?? request.bookmark
            let exact = rowByMessageID[bookmark.messageID]
            let row = exact ?? items.indices.min {
                let left = abs(items[$0].sourceIndex - bookmark.index)
                let right = abs(items[$1].sourceIndex - bookmark.index)
                return left == right ? items[$0].sourceIndex < items[$1].sourceIndex : left < right
            } ?? 0
            if exact == nil {
                bookmark = .init(messageID: items[row].summary.id, offset: 0, index: items[row].sourceIndex)
                cancelDeferredContentRestore()
            }
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
            let target = items[row].summary
            let contentReady = restorationContentReady(request, target: target)
            if !contentReady {
                if exact != nil { deferContentRestore(request) }
                model?.hydrate(target)
            }
            // Remeasure the hosted target on every refinement pass. The saved
            // offset may be larger than a preview or an automatic-height estimate.
            if contentReady || !request.refreshedTargetRowHeight {
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
            // A placeholder is usable immediately, but never replaces intent.
            // Leave the placeholder footer visible so an inline Retry remains
            // usable without scrolling away from the retained restoration intent.
            let usableHeight = restorationHeight(rowRect.height, ready: contentReady)
            bookmark = .init(messageID: target.id,
                offset: TranscriptViewportPolicy.clampedRestoreOffset(bookmark.offset, rowHeight: usableHeight),
                index: items[row].sourceIndex)
            request.effectiveBookmark = bookmark
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
            positionEstablished = true
            establishedBookmark = .init(messageID: target.id, offset: achievedOffset, index: items[row].sourceIndex)
            if !contentReady {
                // Neither slow I/O nor a failed load spends geometry attempts.
                // Retry or another actual mutation resumes this exact intent.
                pendingRestore = request
                restoreWorkItem = nil
                return
            }
            if TraceTestHooks.isUITesting,
               let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_GEOMETRY_RELEASE_PATH"],
               !FileManager.default.fileExists(atPath: path) {
                pendingRestore = request
                restoreWorkItem = nil
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_GEOMETRY_ENTERED_PATH")
                if restoreGateTask == nil {
                    restoreGateTask = Task { [weak self] in
                        try? await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_TRANSCRIPT_GEOMETRY_RELEASE_PATH",
                                                                timeoutMilliseconds: 30_000)
                        guard !Task.isCancelled else { return }
                        self?.restoreGateTask = nil
                        self?.applyRestore(token: token)
                    }
                }
                return
            }
            TraceTestHooks.appendLine(String(request.bookmark.index),
                pathKey: "TRACE_TEST_TRANSCRIPT_GEOMETRY_PASSES_PATH")
            let heightIsStable = request.lastDocumentHeight.map {
                abs($0 - documentHeight) <= 1
            } ?? false
            let targetIsStable = request.lastTargetHeight.map {
                abs($0 - rowRect.height) <= 1
            } ?? false
            request.lastDocumentHeight = documentHeight
            request.lastTargetHeight = rowRect.height
            let stabilityRelease = TraceTestHooks.isUITesting
                ? TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_GEOMETRY_STABILITY_RELEASE_PATH"] : nil
            let geometryMaySettle = stabilityRelease.map { FileManager.default.fileExists(atPath: $0) } ?? true
            if (offsetMatches || constrainedAtEdge) && heightIsStable && targetIsStable && geometryMaySettle {
                request.stableChecks += 1
            } else { request.stableChecks = 0 }
            request.attemptsRemaining -= 1
            if request.stableChecks < 5 {
                pendingRestore = request
                restoreWorkItem = nil
                if request.attemptsRemaining > 0 {
                    scheduleRestore(token: token,
                        delayMilliseconds: request.refreshesRowHeights ? 50 : 75)
                } else {
                    TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_GEOMETRY_BUDGET_EXHAUSTED_PATH")
                }
                // Exhaustion waits for a meaningful change; provisional geometry
                // does not become a normalized saved bookmark or bottom-follow.
            } else {
                pendingRestore = nil
                restoreWorkItem = nil
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_COMPLETED_PATH")
                TraceTestHooks.appendLine("completed,\(request.bookmark.index),\(request.bookmark.offset),\(request.reason.isExplicitNavigation),\(request.inputGeneration)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_RESTORE_AUDIT_PATH")
                positionEstablished = true
                pendingAnchorCorrection = !pendingHeightMessageIDs.isEmpty || extentNeedsRefresh
                establishedBookmark = .init(messageID: items[row].summary.id, offset: achievedOffset, index: items[row].sourceIndex)
                if contentReady { cancelDeferredContentRestore() }
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
                    TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_COMPLETED_PATH")
                    model?.consumeRequestedMessageID(messageID)
                }
                pendingIdleSaveAfterRestore = false
                savePosition()
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
                                          cause: RestoreCancellationCause = .replacement,
                                          preserveDeferred: Bool = false) {
            if cause == .userInteraction,
               case .search(let messageID) = (pendingRestore?.reason ?? deferredContentRestore?.reason),
               model?.selectedSessionID == sessionID {
                model?.consumeRequestedMessageID(messageID)
            }
            let reportsHooks = pendingRestore?.reason.reportsHooks == true
                || deferredContentRestore?.reason.reportsHooks == true
            restoreGateTask?.cancel()
            restoreGateTask = nil
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            pendingRestore = nil
            if !preserveDeferred { cancelDeferredContentRestore() }
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
            settledBottomInputGeneration = nil
            resizeTransaction = nil
            pendingDocumentBottomShift = nil
            establishedBookmark = nil
            pendingAnchorCorrection = false
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
            scrollIdleReadyToSave = true
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
            // Offscreen content changes stay deferred until their native row
            // height changes; they do not invalidate the current document extent.
            pendingHeightMessageIDs.insert(messageID)
            if positionEstablished, !isUserInteracting, !followsBottom,
               establishedBookmark != nil { pendingAnchorCorrection = true }
            if userInitiated {
                userInputGeneration &+= 1
                settledBottomInputGeneration = nil
                resizeTransaction = nil
                pendingDocumentBottomShift = nil
                establishedBookmark = nil
                pendingAnchorCorrection = false
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
            invalidateDocumentExtent()
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
            observeDocumentGeometry()
            lastObservedViewportSize = viewportSize
            lastObservedDocumentHeight = documentHeight
            let viewportResized = previousViewportSize.map {
                abs($0.width - viewportSize.width) > 0.5
                    || abs($0.height - viewportSize.height) > 0.5
            } ?? false
            if viewportResized, !isUserInteracting, let previousViewportSize {
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
                // A synchronous native resize can deliver its padding adjustment
                // before our coalesced row-extent refresh runs. Preserve the last
                // measured trailing padding, rather than using a stale row bottom.
                let bottom = cachedTrailingDocumentPadding.map { max(0, table.frame.height - $0) }
                    ?? cachedRowExtent
                if let bottom {
                    pendingDocumentBottomShift = (max(0, bottom - viewportSize.height),
                        .now.advanced(by: .milliseconds(500)))
                    TraceTestHooks.appendLine("document-shift=\(max(0, bottom - viewportSize.height)),padding=\(cachedTrailingDocumentPadding ?? -1)",
                        pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
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
                // Every new wheel/key input clears this pending adjustment. The
                // idle debounce can still be active while layout finishes. AppKit
                // may clamp to the newly measured row extent before its estimated
                // document frame catches up; unrelated origins remain reader motion.
                let measuredBottom = table.flatMap { table -> CGFloat? in
                    guard !items.isEmpty else { return nil }
                    return max(0, table.rect(ofRow: items.count - 1).maxY - viewportSize.height)
                }
                if followsBottom, !scrollerTracking, !selectionTracking, ContinuousClock.now < pending.expires,
                   abs(actual.y - pending.origin) <= 1
                    || measuredBottom.map({ abs(actual.y - $0) <= 1 }) == true {
                    passiveLayoutMotion = true
                } else {
                    pendingDocumentBottomShift = nil
                }
                TraceTestHooks.appendLine("document-origin=\(actual.y),expected=\(pending.origin),measured=\(measuredBottom ?? -1),native=\(passiveLayoutMotion)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
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
            if viewport.atBottom {
                upwardScrollTravel = 0
                settledBottomInputGeneration = userInputGeneration
            } else {
                settledBottomInputGeneration = nil
            }
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
            if let intended = deferredContentRestore?.bookmark ?? pendingRestore?.bookmark ?? model?.scrollPositions[sessionID] {
                TraceTestHooks.appendLine("\(intended.index),\(intended.offset)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_INTENDED_BOOKMARK_PROBE_PATH")
            }
            if let bookmark = currentBookmark() {
                TraceTestHooks.appendLine("\(bookmark.index),\(bookmark.offset)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_READER_PROBE_PATH")
            }
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
                    "probe=\(index),rowHeight=\(rect.height),established=\(positionEstablished),restore=\(pendingRestore != nil),heights=\(pendingHeightMessageIDs.count),extent=\(extentNeedsRefresh),correction=\(pendingAnchorCorrection),interacting=\(isUserInteracting)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_ROW_LAYOUT_AUDIT_PATH"
                )
                TraceTestHooks.appendLine(
                    "\(index),\(rect.minY - viewport.minY),\(rect.intersects(viewport)),\(positionEstablished && pendingRestore == nil && deferredContentRestore == nil && pendingHeightMessageIDs.isEmpty && !extentNeedsRefresh && !pendingAnchorCorrection),\(sessionID)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_ANCHOR_POSITION_PATH"
                )
            }
        }

        private func correctEstablishedAnchor() {
            guard pendingAnchorCorrection else { return }
            if var request = pendingRestore, request.revealedTargetRow,
               request.sessionID == sessionID, request.inputGeneration == userInputGeneration,
               positionEstablished, !applyingProgrammaticScroll, !isUserInteracting,
               let row = rowByMessageID[request.effectiveBookmark.messageID],
               let table, let scrollView {
                // Native hosted-size changes can arrive after update(). Correct
                // the retained intent before drawing that frame, without polling
                // hydration or spending a full-content geometry attempt. A gate
                // on refinement must not suppress this already-established anchor.
                let rect = table.rect(ofRow: row)
                let target = items[row].summary
                let ready = restorationContentReady(request, target: target)
                let height = restorationHeight(rect.height, ready: ready)
                let offset = TranscriptViewportPolicy.clampedRestoreOffset(request.bookmark.offset, rowHeight: height)
                request.effectiveBookmark = .init(messageID: target.id, offset: offset, index: items[row].sourceIndex)
                pendingRestore = request
                applyingProgrammaticScroll = true
                let origin = constrainedOrigin(for: rect.minY - offset, table: table, scrollView: scrollView)
                scrollView.contentView.setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                rememberProgrammaticOrigin()
                applyingProgrammaticScroll = false
                if pendingHeightMessageIDs.isEmpty && !extentNeedsRefresh { pendingAnchorCorrection = false }
                return
            }
            guard positionEstablished, !applyingProgrammaticScroll, !isUserInteracting,
                  !followsBottom, restoreGateTask == nil,
                  pendingRestore?.reason.isExplicitNavigation != true,
                  let bookmark = pendingRestore?.effectiveBookmark ?? establishedBookmark,
                  let row = rowByMessageID[bookmark.messageID], let table, let scrollView else { return }
            let desired = table.rect(ofRow: row).minY - bookmark.offset
            guard abs(desired - scrollView.contentView.bounds.origin.y) > 1 else {
                if pendingRestore == nil, pendingHeightMessageIDs.isEmpty, !extentNeedsRefresh {
                    pendingAnchorCorrection = false
                }
                return
            }
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
            let waiting = deferredContentRestore != nil && model?.hydratedMessages[items[row].summary.id] == nil
            let phase = waiting ? "waiting" : pendingRestore != nil ? "refining" : "established"
            TraceTestHooks.appendLine("\(index),\(rect.minY - viewport.minY),\(rect.intersects(viewport)),\(sessionID),\(phase),\(rect.height),\(rect.minY),\(table.frame.height),\(viewport.height)",
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
                let row = items.count - 1
                table.scrollRowToVisible(row)
                (table.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? TranscriptHostingCell)?.refreshHostedSize()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                table.layoutSubtreeIfNeeded()
                invalidateDocumentExtent()
                _ = scrollToBottom()
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
            case "multi-stage-document", "interrupted-document":
                guard let table else { return }
                let origin = scrollView.contentView.bounds.origin
                let oldHeight = table.frame.height
                let oldSize = scrollView.contentView.bounds.size
                beginUserScrolling()
                recordUserViewportMotion(from: NSPoint(x: origin.x, y: origin.y - 1), to: origin)
                scrollView.contentView.postsBoundsChangedNotifications = false
                table.setFrameSize(NSSize(width: table.frame.width, height: oldHeight + 264))
                lastObservedOrigin = origin
                lastObservedViewportSize = oldSize
                lastObservedDocumentHeight = oldHeight
                expectedProgrammaticOrigin = nil
                scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y + 264))
                boundsDidChange()
                if simulation == "interrupted-document" { beginUserScrolling() }
                let measuredBottom = max(0, table.rect(ofRow: items.count - 1).maxY
                    - scrollView.contentView.bounds.height)
                scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: measuredBottom))
                boundsDidChange()
                scrollView.contentView.postsBoundsChangedNotifications = true
                TraceTestHooks.appendLine("simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "expired-resize", "interrupted-resize":
                resizeTransaction = ResizeTransaction(initiallyFollowing: true, viewportDelta: -80,
                    expires: .now.advanced(by: .milliseconds(simulation == "expired-resize" ? -1 : 500)),
                    inputGeneration: userInputGeneration)
                if simulation == "interrupted-resize" {
                    beginUserScrolling()
                    // A queued resize callback after physical input must not
                    // rearm the transaction and suppress the next upward move.
                    let size = scrollView.contentView.bounds.size
                    lastObservedViewportSize = NSSize(width: size.width, height: size.height + 80)
                    lastObservedOrigin = scrollView.contentView.bounds.origin
                    expectedProgrammaticOrigin = nil
                    boundsDidChange()
                    TraceTestHooks.appendLine("resize-rearmed-after-input=\(resizeTransaction != nil)",
                        pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                }
                expectedProgrammaticOrigin = nil
                lastObservedOrigin = scrollView.contentView.bounds.origin
                var origin = scrollView.contentView.bounds.origin
                origin.y -= 24
                scrollView.contentView.setBoundsOrigin(origin)
                boundsDidChange()
                TraceTestHooks.appendLine("simulation-classified-bottom=\(followsBottom)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "cached-extent":
                guard let table else { return }
                _ = prepareDocumentExtent()
                let queries = extentQueryCount
                let generation = extentGeneration
                let original = scrollView.contentView.bounds.origin
                applyingProgrammaticScroll = true
                for step in 0..<100 {
                    // Exercise real bounds notifications with unchanged sizes.
                    scrollView.contentView.setBoundsOrigin(NSPoint(x: original.x,
                        y: original.y - CGFloat(step % 2)))
                    for _ in 0..<100 { _ = viewportStatus }
                }
                table.setFrameOrigin(NSPoint(x: table.frame.origin.x, y: table.frame.origin.y + 1))
                table.setFrameOrigin(NSPoint(x: table.frame.origin.x, y: table.frame.origin.y - 1))
                scrollView.contentView.setBoundsOrigin(original)
                rememberProgrammaticOrigin()
                applyingProgrammaticScroll = false
                let scrollQueries = extentQueryCount
                let scrollGeneration = extentGeneration
                invalidateDocumentExtent()
                invalidateDocumentExtent()
                let beforeFlush = extentQueryCount
                _ = exactMaximumScrollY
                TraceTestHooks.appendLine("cache=\(queries),\(scrollQueries),\(generation),\(scrollGeneration),\(materializedMessageIDs.count),\(items.count),\(beforeFlush),\(extentQueryCount)",
                    pathKey: "TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH")
                TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH")
            case "row-extent":
                guard let table else { return }
                applyingProgrammaticScroll = true
                let bottom = table.rect(ofRow: items.count - 1).maxY
                table.setFrameSize(NSSize(width: table.frame.width, height: max(0, bottom - 100)))
                invalidateDocumentExtent()
                let maximum = exactMaximumScrollY ?? -1
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
                && pendingRestore == nil && deferredContentRestore == nil
                && !userScrolling && !liveScrolling && isAtSettledBottom
            let pinned = followsBottom
            return .init(
                bookmark: deferredContentRestore?.bookmark ?? pendingRestore?.bookmark ?? (isUserInteracting ? nil : establishedBookmark) ?? currentBookmark(),
                followsBottom: pinned || implicitBottom
            )
        }

        private func reconcilePosition(
            _ snapshot: PositionSnapshot, reason: RestoreRequest.Reason,
            refreshesRowHeights: Bool = false
        ) {
            guard !items.isEmpty else { return }
            let activePriority = max(pendingRestore?.reason.priority ?? -1,
                                     deferredContentRestore?.reason.priority ?? -1)
            if activePriority > reason.priority { return }
            if snapshot.followsBottom {
                if case .passive = reason,
                   !isUserInteracting || settledBottomInputGeneration == userInputGeneration {
                    // Known app mutations can trigger a later native origin-only
                    // adjustment. During the idle debounce, a settled bottom
                    // proves that no input since snap-back has moved us away.
                    if resizeTransaction?.initiallyFollowing != true
                        || resizeTransaction?.inputGeneration != userInputGeneration
                        || resizeTransaction.map({ ContinuousClock.now >= $0.expires }) != false {
                        resizeTransaction = ResizeTransaction(initiallyFollowing: true,
                            viewportDelta: 0, expires: .now.advanced(by: .milliseconds(500)),
                            inputGeneration: userInputGeneration)
                    }
                }
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
            // Origins change during scrolling without changing any row's extent.
            let frameSize: NSSize
            let boundsSize: NSSize
            let spacing: NSSize
            let rows: Int
        }
        private var extentGeometry: ExtentGeometry?
        private var extentGeneration: UInt64 = 0
        private var extentNeedsRefresh = true
        private var refreshingExtent = false
        private var extendingDocumentFrame = false
        private var extentRefreshWorkItem: DispatchWorkItem?
        private var cachedRowExtent: CGFloat?
        private var cachedDocumentHeight: CGFloat = 0
        private var cachedTrailingDocumentPadding: CGFloat?
        private var pendingAnchorCorrection = false
        private var extentQueryCount = 0
        private var materializedMessageIDs: Set<Int64> = []

        private func observeDocumentGeometry() {
            guard let table else { return }
            let geometry = ExtentGeometry(frameSize: table.frame.size, boundsSize: table.bounds.size,
                                          spacing: table.intercellSpacing, rows: items.count)
            cachedDocumentHeight = geometry.frameSize.height
            guard geometry != extentGeometry else { return }
            extentGeometry = geometry
            if !extendingDocumentFrame { invalidateDocumentExtent() }
        }

        private func invalidateDocumentExtent() {
            extentGeneration &+= 1
            extentNeedsRefresh = true
            if positionEstablished, !isUserInteracting, !followsBottom,
               establishedBookmark != nil { pendingAnchorCorrection = true }
            guard extentRefreshWorkItem == nil, table != nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.extentRefreshWorkItem = nil
                    self.refreshDocumentExtent()
                    self.scheduleBottomFollow()
                }
            }
            extentRefreshWorkItem = work
            // rect(ofRow:) may cause AppKit to tile its table. Never call it from
            // a bounds notification or while a hosted row is being configured.
            DispatchQueue.main.async(execute: work)
        }

        private func refreshDocumentExtent() {
            observeDocumentGeometry()
            guard extentNeedsRefresh, !refreshingExtent, let table else { return }
            extentRefreshWorkItem?.cancel()
            extentRefreshWorkItem = nil
            refreshingExtent = true
            let generation = extentGeneration
            extentQueryCount += 1
            cachedRowExtent = items.isEmpty ? 0 : table.rect(ofRow: items.count - 1).maxY
            cachedDocumentHeight = table.frame.height
            if !items.isEmpty, let bottom = cachedRowExtent, cachedDocumentHeight >= bottom {
                cachedTrailingDocumentPadding = cachedDocumentHeight - bottom
            }
            extentGeometry = ExtentGeometry(frameSize: table.frame.size, boundsSize: table.bounds.size,
                                            spacing: table.intercellSpacing, rows: items.count)
            extentNeedsRefresh = generation != extentGeneration
            refreshingExtent = false
            if !extentNeedsRefresh {
                extentRefreshWorkItem?.cancel()
                extentRefreshWorkItem = nil
            }
        }

        private var maximumScrollY: CGFloat? {
            guard table != nil, let scrollView else { return nil }
            return TranscriptViewportPolicy.maximumOrigin(frameHeight: cachedDocumentHeight,
                lastRowBottom: cachedRowExtent ?? 0, viewportHeight: scrollView.contentView.bounds.height)
        }

        private var exactMaximumScrollY: CGFloat? {
            refreshDocumentExtent()
            return maximumScrollY
        }

        private func prepareDocumentExtent() -> CGFloat? {
            refreshDocumentExtent()
            if let table, let bottom = cachedRowExtent, bottom > table.frame.height {
                // Extending the frame to an already measured row does not change
                // row geometry and must not trigger another last-row query.
                extendingDocumentFrame = true
                table.setFrameSize(NSSize(width: table.frame.width, height: bottom))
                extendingDocumentFrame = false
                cachedDocumentHeight = table.frame.height
                extentGeometry = ExtentGeometry(frameSize: table.frame.size, boundsSize: table.bounds.size,
                                                spacing: table.intercellSpacing, rows: items.count)
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
    let sourceGeneration: Int64?
    let hydrated: HydratedMessage?
    let hydrationError: String?
    private var hydrationFailed: Bool { hydrationError != nil }
    @Binding var reasoningExpanded: Bool
    @ObservedObject var expansion: TranscriptExpansionState
    let visibility: TranscriptVisibility
    let hydrate: () -> Void
    let retryHydration: () -> Void
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
                    if let hydrationError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unable to read this message: \(hydrationError)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Retry", action: retryHydration)
                                .accessibilityIdentifier("retryMessage-\(summary.id)")
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
            .task(id: HydrationTaskID(
                messageID: summary.id, visibility: visibility, sourcePath: summary.sourcePath,
                sourceGeneration: sourceGeneration, sourceFormat: summary.sourceFormat, locator: summary.locator,
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
        TranscriptRowContent.isLazyAuxiliary(role: summary.role, visibility: visibility)
    }

    private struct HydrationTaskID: Hashable {
        let messageID: Int64
        let visibility: TranscriptVisibility
        let sourcePath: String
        let sourceGeneration: Int64?
        let sourceFormat: SourceFormat
        let locator: RecordLocator
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

private enum TranscriptRowContent {
    static func isLazyAuxiliary(role: MessageRole, visibility: TranscriptVisibility) -> Bool {
        visibility.includes(role: role) && [.toolResult, .toolUse, .system, .reasoning].contains(role)
    }
}
