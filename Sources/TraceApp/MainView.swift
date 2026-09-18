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
                            try? await Task.sleep(for: .milliseconds(50))
                            guard !Task.isCancelled,
                                  model.sidebarRevealRequest?.token == reveal.token else { return }
                            proxy.scrollTo(projectID, anchor: .center)
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
                            try? await Task.sleep(for: .milliseconds(50))
                            guard !Task.isCancelled,
                                  model.sidebarRevealRequest?.token == reveal.token else { return }
                            proxy.scrollTo(sessionID, anchor: .center)
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

private struct TranscriptRenderer: NSViewRepresentable {
    @ObservedObject var model: TraceModel
    let sessionID: Int64
    let visibility: TranscriptVisibility
    let density: TranscriptDensity

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
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

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
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
        private var observers: [NSObjectProtocol] = []
        private var bookmarkWorkItem: DispatchWorkItem?
        private var restoring = false

        func attach(table: NSTableView, scrollView: NSScrollView) {
            self.table = table
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.restoring else { return }
                        self.restoring = false
                        TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH")
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.bookmarkWorkItem?.cancel()
                        self?.bookmarkWorkItem = nil
                        self?.savePosition()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleBookmarkSave() }
                },
            ]
        }

        func detach() {
            bookmarkWorkItem?.cancel()
            bookmarkWorkItem = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        func update(
            model: TraceModel, sessionID: Int64, visibility: TranscriptVisibility,
            density: TranscriptDensity, messageRevision: Int, contentRevision: Int,
            scrollRequest: UUID
        ) {
            self.model = model
            let sessionChanged = self.sessionID != sessionID
            self.sessionID = sessionID
            var needsRestore = sessionChanged || self.scrollRequest != scrollRequest
            if self.messageRevision != messageRevision || self.visibility != visibility {
                if self.messageRevision >= 0 { savePosition() }
                self.visibility = visibility
                items = model.messages.enumerated().compactMap { index, summary in
                    visibility.includes(summary) ? Item(summary: summary, sourceIndex: index) : nil
                }
                self.messageRevision = messageRevision
                table?.reloadData()
                needsRestore = true
            }
            if self.density != density {
                self.density = density
                table?.intercellSpacing.height = density == .compact ? 6 : 14
                table?.reloadData()
                needsRestore = true
            }
            if self.contentRevision != contentRevision {
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
                    let bookmark = currentBookmark()
                    table?.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
                    if let bookmark { restore(bookmark) }
                }
            }
            if self.scrollRequest != scrollRequest {
                self.scrollRequest = scrollRequest
                needsRestore = true
            }
            if needsRestore { restoreRequestedPosition() }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let model else { return nil }
            let item = items[row]
            let identifier = NSUserInterfaceItemIdentifier("messageCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptHostingCell)
                ?? TranscriptHostingCell(identifier: identifier)
            let message = item.summary
            let rowView = MessageRow(
                summary: message,
                hydrated: model.hydratedMessages[message.id],
                hydrationFailed: model.hydrationFailures.contains(message.id),
                reasoningExpanded: Binding(
                    get: { [weak model] in model?.expandedReasoningIDs.contains(message.id) == true },
                    set: { [weak model] expanded in
                        guard let model else { return }
                        if expanded { model.expandedReasoningIDs.insert(message.id) }
                        else { model.expandedReasoningIDs.remove(message.id) }
                    }
                ),
                visibility: visibility,
                compact: density == .compact,
                hydrate: { [weak model] in model?.hydrate(message) }
            )
            .padding(.horizontal, density == .compact ? 12 : 20)
            .padding(.vertical, (density == .compact ? 6 : 10) / 2)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            cell.set(rootView: AnyView(rowView.id(message.id)), messageID: message.id)
            return cell
        }

        func savePosition() {
            guard !restoring, let bookmark = currentBookmark(), let model else { return }
            model.scrollPositions[sessionID] = bookmark
            TraceTestHooks.appendLine(
                "finished", pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"
            )
            if TraceTestHooks.isUITesting,
               let path = TraceTestHooks.environment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] {
                try? Data("\(bookmark.index)".utf8).write(to: URL(fileURLWithPath: path))
            }
        }

        private func scheduleBookmarkSave() {
            guard !restoring else { return }
            bookmarkWorkItem?.cancel()
            TraceTestHooks.appendLine(
                "started", pathKey: "TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"
            )
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.bookmarkWorkItem = nil
                    self.savePosition()
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
            guard let table, let clip = scrollView?.contentView as NSClipView? else { return nil }
            let visible = clip.bounds
            var row = table.row(at: NSPoint(x: 1, y: visible.minY + 1))
            if row < 0 { row = table.rows(in: visible).location }
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            return .init(
                messageID: item.summary.id,
                offset: table.rect(ofRow: row).minY - visible.minY,
                index: item.sourceIndex
            )
        }

        private func restoreRequestedPosition() {
            guard let model, !items.isEmpty else { return }
            var bookmark = model.scrollPositions[sessionID]
            if let target = model.requestedMessageID,
               let item = items.first(where: { $0.summary.id == target }) {
                bookmark = .init(messageID: target, offset: 0, index: item.sourceIndex)
                model.consumeRequestedMessageID(target)
            }
            restore(bookmark ?? .init(messageID: items[0].summary.id, offset: 0, index: 0))
        }

        private func restore(_ bookmark: TranscriptBookmark) {
            guard let table, let scrollView, !items.isEmpty else { return }
            let exact = items.firstIndex { $0.summary.id == bookmark.messageID }
            let row = exact ?? items.indices.min {
                abs(items[$0].sourceIndex - bookmark.index) < abs(items[$1].sourceIndex - bookmark.index)
            } ?? 0
            restoring = true
            table.layoutSubtreeIfNeeded()
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            var origin = scrollView.contentView.bounds.origin
            origin.y = max(0, table.rect(ofRow: row).minY - bookmark.offset)
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            restoring = false
        }
    }
}

@MainActor
private final class TranscriptHostingCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var messageID: Int64?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(rootView: AnyView, messageID: Int64) {
        self.messageID = messageID
        host.rootView = rootView
    }
}

private struct MessageRow: View {
    let summary: MessageSummary
    let hydrated: HydratedMessage?
    let hydrationFailed: Bool
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
        if summary.hasError { return true }
        guard let hydrated else { return true }
        let sections = hydrated.sections
        return hasVisibleContent(in: sections)
    }

    @ViewBuilder private var content: some View {
        if let hydrated {
            if isLazyAuxiliary {
                DisclosureGroup(isExpanded: $auxiliaryExpanded) {
                    sectionContents(hydrated)
                } label: {
                    Text(safePreview ?? neutralPlaceholder)
                        .font(.callout.monospaced())
                        .lineLimit(auxiliaryExpanded ? nil : 2)
                }
                .onChange(of: auxiliaryExpanded) { _, expanded in if expanded { hydrate() } }
            } else {
                sectionContents(hydrated)
            }
        } else if isLazyAuxiliary {
            DisclosureGroup(isExpanded: $auxiliaryExpanded) {
                if hydrationFailed { Text("Unable to load visible content.").foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            } label: {
                Text(safePreview ?? neutralPlaceholder)
                    .font(.callout.monospaced())
                    .lineLimit(2)
            }
            .onChange(of: auxiliaryExpanded) { _, expanded in if expanded { hydrate() } }
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
            MarkdownText(source: message.sections.prose)
        }
        if visibility.includes(role: summary.role), visibility.tools && !message.sections.toolInvocation.isEmpty {
            DisclosureGroup("Tool invocation") {
                SelectableMessageText(text: AttributedString(message.sections.toolInvocation), monospaced: true)
            }
        }
        if visibility.includes(role: summary.role), visibility.tools && !message.sections.toolOutput.isEmpty {
            DisclosureGroup("Tool output") {
                SelectableMessageText(text: AttributedString(message.sections.toolOutput), monospaced: true)
            }
        }
        if visibility.includes(role: summary.role), visibility.reasoning && !message.sections.reasoning.isEmpty {
            DisclosureGroup(isExpanded: $reasoningExpanded) {
                SelectableMessageText(text: AttributedString(message.sections.reasoning), secondary: true)
            } label: {
                Label("Reasoning", systemImage: "brain")
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
