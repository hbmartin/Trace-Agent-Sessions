import AppKit
import Clocks
import Combine
import CryptoKit
import Darwin
import Foundation
import GRDB
import os
import TraceCore

struct SidebarRevealRequest: Equatable, Sendable {
    let token = UUID()
    let projectCanonicalKey: String
    let sessionID: Int64
}

enum SourceReloadRecoveryState: Equatable, Sendable {
    case normal
    case failed(String)
    case retrying(String)

    var error: String? {
        switch self {
        case .normal: nil
        case .failed(let error), .retrying(let error): error
        }
    }

    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }
}

enum WatcherGroupingPolicy {
    case byVolume
    case byRoot

    func groupIdentifier(for root: URL, volumeIdentifier: String) -> String {
        switch self {
        case .byVolume:
            return volumeIdentifier
        case .byRoot:
            let key = TraceFileIO.canonicalPath(root.path).comparisonKey
            let digest = SHA256.hash(data: Data(key.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            return volumeIdentifier + ":root:" + digest
        }
    }
}

/// Backing state is committed before either notification. Reentrant changes queue
/// another delivery instead of allowing an older setter to overwrite them.
@MainActor
enum ModelPublicationBatch {
    private static var depth = 0
    private static var flushing = false
    private static var order: [ObjectIdentifier] = []
    private static var deliveries: [ObjectIdentifier: () -> Void] = [:]
    private static var notified: Set<ObjectIdentifier> = []

    static func perform<Result>(_ changes: () throws -> Result) rethrows -> Result {
        depth += 1
        defer { depth -= 1; flush() }
        return try changes()
    }

    static func enqueue(_ owner: AnyObject, delivery: @escaping () -> Void) {
        let key = ObjectIdentifier(owner)
        if deliveries[key] == nil { order.append(key) }
        deliveries[key] = delivery
        flush()
    }

    static func notify<Object: ObservableObject>(_ object: Object)
        where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
        if notified.insert(ObjectIdentifier(object)).inserted { object.objectWillChange.send() }
    }

    private static func flush() {
        guard depth == 0, !flushing else { return }
        flushing = true
        defer { flushing = false; notified.removeAll(keepingCapacity: true) }
        while !order.isEmpty {
            let key = order.removeFirst()
            deliveries.removeValue(forKey: key)?()
        }
    }
}

@MainActor
final class CommittedModelState<Value: Sendable> {
    private let storage: OSAllocatedUnfairLock<Value>
    private let changes = CurrentValueSubject<UInt64, Never>(0)
    var value: Value { storage.withLock { $0 } }
    func read<Member: Sendable>(_ keyPath: KeyPath<Value, Member> & Sendable) -> Member {
        storage.withLock { $0[keyPath: keyPath] }
    }
    private var revision: UInt64 = 0
    private var delivering = false
    private var pending = false
    var publisher: AnyPublisher<Value, Never> {
        let storage = storage
        return changes.map { @Sendable [storage] _ in
            storage.withLock { $0 }
        }.eraseToAnyPublisher()
    }

    init(_ value: Value) {
        storage = .init(initialState: value)
    }

    func stage(_ value: Value) {
        storage.withLock { $0 = value }
        revision &+= 1
        pending = true
    }

    func commit(_ value: Value, notify: @escaping () -> Void) {
        stage(value)
        publish(notify: notify)
    }

    func publish(notify: @escaping () -> Void) {
        ModelPublicationBatch.enqueue(self) { self.deliver(notify: notify) }
    }

    private func deliver(notify: () -> Void) {
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        while pending {
            pending = false
            let deliveredRevision = revision
            notify()
            guard revision == deliveredRevision else { continue }
            changes.send(deliveredRevision)
        }
    }
}

@MainActor
final class TraceModel: ObservableObject {
    enum GlobalSearchSurface: Hashable { case popover, launcher }
    private enum ProjectReconciliationMode: Equatable {
        case ongoing
        case completed
        case terminalRetaining

        var globalMissingProjectPolicy: SessionSearchModel.MissingProjectPolicy {
            switch self {
            case .ongoing: .keepResolving
            case .completed: .clear
            case .terminalRetaining: .retain
            }
        }

        var mainMissingProjectPolicy: SessionSearchModel.MissingProjectPolicy {
            switch self {
            case .ongoing: .keepResolving
            case .completed, .terminalRetaining: .retain
            }
        }
    }

    private struct IndexProgressDisposition {
        let passTerminal: Bool
        let workflowTerminal: Bool
        let supersededTerminal: Bool
        let projectReconciliation: ProjectReconciliationMode
    }

    private struct IndexWorkflowState {
        private struct Replacement {
            var displacedPassIDs: Set<UUID>
        }

        private(set) var activePassID: UUID?
        private(set) var terminalPhase: IndexProgress.Phase?
        private(set) var generation = UUID()
        private var replacement: Replacement?

        var isActive: Bool { activePassID != nil || replacement != nil }

        mutating func beginReplacement() {
            generation = UUID()
            terminalPhase = nil
            if replacement == nil {
                replacement = .init(displacedPassIDs: [])
            }
            if let activePassID { replacement?.displacedPassIDs.insert(activePassID) }
        }

        mutating func retireActivePass() { activePassID = nil }

        mutating func receive(_ update: IndexProgress) -> IndexProgressDisposition {
            let previousPassID = activePassID
            let passTerminal = [.complete, .failed, .cancelled].contains(update.phase)
            let supersededTerminal: Bool
            if passTerminal, let replacement {
                supersededTerminal = replacement.displacedPassIDs.contains(update.passID)
            } else {
                supersededTerminal = false
            }

            if passTerminal {
                if !supersededTerminal {
                    activePassID = nil
                }
                if supersededTerminal {
                    replacement?.displacedPassIDs.remove(update.passID)
                } else {
                    replacement = nil
                }
            } else {
                activePassID = update.passID
                if replacement?.displacedPassIDs.contains(update.passID) != true {
                    replacement = nil
                }
            }

            let workflowTerminal = passTerminal && !supersededTerminal
            if workflowTerminal || (!passTerminal && previousPassID != update.passID) { generation = UUID() }
            if workflowTerminal { terminalPhase = update.phase }
            else if !passTerminal { terminalPhase = nil }
            let projectReconciliation: ProjectReconciliationMode
            if !workflowTerminal {
                projectReconciliation = .ongoing
            } else if update.phase == .complete {
                projectReconciliation = .completed
            } else {
                projectReconciliation = .terminalRetaining
            }
            return .init(
                passTerminal: passTerminal,
                workflowTerminal: workflowTerminal,
                supersededTerminal: supersededTerminal,
                projectReconciliation: projectReconciliation
            )
        }
    }
    let settings: AppSettings
    let globalSearch: SessionSearchModel
    let mainSearch: SessionSearchModel
    private let clock: AnyClock<Duration>
    let diagnostics: DiagnosticsStore

    private let progressState = CommittedModelState(IndexProgress(phase: .waiting))
    private(set) var progress: IndexProgress {
        get { progressState.value }
        set {
            if newValue.rollupError == nil { rollupFailure = nil }
            else if let database,
                    rollupFailure?.database !== database || rollupFailure?.passID != newValue.passID {
                rollupFailure = .init(database: database, passID: newValue.passID)
            }
            progressState.commit(newValue) { ModelPublicationBatch.notify(self) }
        }
    }
    var progressChanges: AnyPublisher<IndexProgress, Never> { progressState.publisher }
    struct SidebarState: Sendable {
        var startupError: String?
        var scrollRequest: UUID = UUID()
        var monitoringWarnings: [String] = []
        var initialAttachmentFailure: String? = nil
        var rebuildAttachmentReady: Bool = false
        var sourceReloadRecovery: SourceReloadRecoveryState = .normal
        var projects: [ProjectSummary] = []
        var recentSessions: [SessionSummary] = []
        var sourceHealth: [SourceHealth] = []
        var statistics: IndexStatistics? = nil
        var selectedProjectID: Int64? = nil
        var selectedProjectCanonicalKey: String? = nil
        var selectedProjectDisplayName: String? = nil
        var sidebarRevealRequest: SidebarRevealRequest? = nil
        var hasSearchReturnContext: Bool = false
        var sidebarSummaryError: String? = nil
        var isRetryingSidebarSummary: Bool = false
        var preparingRebuild = false
    }
    private let sidebarState = CommittedModelState(SidebarState())
    var sidebarChanges: AnyPublisher<SidebarState, Never> { sidebarState.publisher }
    private func updateSidebar(_ update: (inout SidebarState) -> Void) {
        var next = sidebarState.value
        update(&next)
        sidebarState.commit(next) { ModelPublicationBatch.notify(self) }
    }
    private(set) var sourceReloadRecovery: SourceReloadRecoveryState {
        get { sidebarState.read(\.sourceReloadRecovery) }
        set { updateSidebar { $0.sourceReloadRecovery = newValue } }
    }
    private(set) var projects: [ProjectSummary] {
        get { sidebarState.read(\.projects) }
        set { updateSidebar { $0.projects = newValue } }
    }
    struct SessionPageState: Sendable {
        var sessions: [SessionSummary] = []
        var totalCount = 0
        var isLoading = false
        var error: String?
        fileprivate var projectKey: String?
        fileprivate var pageCount = 1
        fileprivate var requestedDepth = 1
        fileprivate var cursor: SessionCursor?
        fileprivate var retry: SessionListRetry?
        var hasMore: Bool { cursor != nil }
    }
    private let pageState = CommittedModelState(SessionPageState())
    var sessionPageChanges: AnyPublisher<SessionPageState, Never> { pageState.publisher }
    var sessions: [SessionSummary] { pageState.read(\.sessions) }
    var totalSessionCount: Int { pageState.read(\.totalCount) }
    var hasMoreSessions: Bool { pageState.read(\.hasMore) }
    private(set) var isLoadingSessions: Bool {
        get { pageState.read(\.isLoading) }
        set { updateSessionPage { $0.isLoading = newValue } }
    }
    var sessionListError: String? { pageState.read(\.error) }

    private func updateSessionPage(_ update: (inout SessionPageState) -> Void) {
        var next = pageState.value
        update(&next)
        #if DEBUG
        if next.isLoading != pageState.read(\.isLoading) {
            TraceTestHooks.appendLine(next.isLoading ? "loading" : "idle", pathKey: "TRACE_TEST_SESSION_LOADING_AUDIT_PATH")
        }
        #endif
        pageState.commit(next) { ModelPublicationBatch.notify(self) }
    }
    private(set) var sidebarSummaryError: String? {
        get { sidebarState.read(\.sidebarSummaryError) }
        set { updateSidebar { $0.sidebarSummaryError = newValue } }
    }
    private(set) var isRetryingSidebarSummary: Bool {
        get { sidebarState.read(\.isRetryingSidebarSummary) }
        set { updateSidebar { $0.isRetryingSidebarSummary = newValue } }
    }
    private(set) var hasSearchReturnContext: Bool {
        get { sidebarState.read(\.hasSearchReturnContext) }
        set { updateSidebar { $0.hasSearchReturnContext = newValue } }
    }
    var mainSearchReturnAnchor: SearchResultAnchor?
    private struct MainSearchReturnContext {
        let projectID: Int64?
        let canonicalKey: String?
        let displayName: String?
    }
    private var mainSearchReturnContext: MainSearchReturnContext?
    private var sessionListProjectKey: String? { pageState.read(\.projectKey) }
    private var loadedSessionPageCount: Int { pageState.read(\.pageCount) }
    private var nextSessionCursor: SessionCursor? { pageState.read(\.cursor) }
    private typealias LoadedSessionPages = SessionListSnapshot
    private var sessionListTask: Task<Void, Never>?
    fileprivate enum SessionListRetry: Sendable {
        case reload(pageCount: Int)
        case nextPage(pageCount: Int)
    }
    private struct SidebarSummaryFailure {
        let database: IndexDatabase
        let workflow: UUID
        let configuration: UInt64
        let reconciliation: ProjectReconciliationMode
        let startedAt: AnyClock<Duration>.Instant
    }
    private var sidebarSummaryFailure: SidebarSummaryFailure?
    private var sidebarSummaryRetryTask: Task<Void, Never>?
    private var sidebarSummaryRetryOwner: SummaryRefreshOwner?
    private var pendingSidebarSummaryRetry = false
    private var sessionListRetry: SessionListRetry? { pageState.read(\.retry) }
    private var backgroundSidebarRequest: UUID?
    private enum PendingSidebarAction { case loadMore, retry(SessionListRetry) }
    private var pendingSidebarAction: (project: String?, action: PendingSidebarAction)?
    private(set) var recentSessions: [SessionSummary] {
        get { sidebarState.read(\.recentSessions) }
        set { updateSidebar { $0.recentSessions = newValue } }
    }
    struct TranscriptState: Sendable {
        var sessionID: Int64?
        var session: SessionSummary?
        var messages: [MessageSummary] = []
        var hydrated: [Int64: HydratedMessage] = [:]
        var failures: [Int64: String] = [:]
        var expanded: Set<Int64> = []
        fileprivate var readError: String?
        fileprivate var absence: TranscriptAbsence?
        var messageRevision = 0
        var contentRevision = 0
    }
    private let transcriptState = CommittedModelState(TranscriptState())
    var transcriptChanges: AnyPublisher<TranscriptState, Never> { transcriptState.publisher }
    var transcriptSnapshot: TranscriptState { transcriptState.value }
    var messages: [MessageSummary] { transcriptState.read(\.messages) }
    private(set) var hydratedMessages: [Int64: HydratedMessage] {
        get { transcriptState.read(\.hydrated) }
        set { updateTranscript { $0.hydrated = newValue; $0.contentRevision &+= 1 } }
    }
    private(set) var hydrationFailures: [Int64: String] {
        get { transcriptState.read(\.failures) }
        set { updateTranscript { $0.failures = newValue; $0.contentRevision &+= 1 } }
    }
    private func updateTranscript(replacingRows: Bool = false, _ update: (inout TranscriptState) -> Void) {
        var next = transcriptState.value
        update(&next)
        if transcriptState.read(\.sessionID) != next.sessionID { missingSelectionAttempt = nil }
        if knownSelectionProject?.sessionID != next.sessionID { knownSelectionProject = nil }
        if replacingRows {
            messageIdentities = Dictionary(uniqueKeysWithValues: next.messages.map { ($0.id, MessageIdentity($0)) })
        }
        transcriptState.commit(next) { ModelPublicationBatch.notify(self) }
    }
    private func resetTranscriptValues(sessionID: Int64? = nil, session: SessionSummary? = nil) {
        hydrationOrder.removeAll(keepingCapacity: true)
        hydrationEpoch = UUID()
        hydratingMessageIDs.removeAll(keepingCapacity: true)
        updateTranscript(replacingRows: true) {
            $0.sessionID = sessionID
            $0.session = session
            $0.messages = []
            $0.hydrated = [:]
            $0.failures = [:]
            $0.expanded = []
            $0.readError = nil
            $0.absence = nil
            $0.messageRevision &+= 1
            $0.contentRevision &+= 3
        }
    }
    @Published var projectFilter = ""
    var selectedSession: SessionSummary? { transcriptState.read(\.session) }
    private(set) var sourceHealth: [SourceHealth] {
        get { sidebarState.read(\.sourceHealth) }
        set { updateSidebar { $0.sourceHealth = newValue } }
    }
    struct CostsState: Sendable {
        fileprivate var completed: [UsageRollup] = []
        var usage: [UsageRollup] = []
        var usagePublicationRevision: UInt64 = 0
        var error: String?
        var updating = false
        var canRetry = false
    }
    private let costsState = CommittedModelState(CostsState())
    var costsChanges: AnyPublisher<CostsState, Never> { costsState.publisher }
    var usage: [UsageRollup] { costsState.read(\.usage) }
    var costsTotalsUpdating: Bool { costsState.read(\.updating) }
    var canRetryCosts: Bool { costsState.read(\.canRetry) }
    private func costsPresentation(_ value: CostsState) -> CostsState {
        var next = value
        let currentWork = database.map { database in
            usageWork.worker?.database === database
                || (usageWork.pending?.database === database && !indexingPassActive && pendingAttachment == nil)
        } ?? false
        next.updating = !terminating && (indexingPassActive || currentWork)
        next.canRetry = next.error != nil && usageRetryEligible
        return next
    }
    private func updateCosts(_ update: (inout CostsState) -> Void, onCommit: () -> Void = {}) {
        var next = costsState.value
        update(&next)
        costsState.stage(costsPresentation(next))
        onCommit()
        costsState.publish { ModelPublicationBatch.notify(self) }
    }
    private(set) var statistics: IndexStatistics? {
        get { sidebarState.read(\.statistics) }
        set { updateSidebar { $0.statistics = newValue } }
    }
    @Published private(set) var diagnosticsSnapshot = DiagnosticsSnapshot()
    @Published private(set) var pricing: PricingCatalog?
    @Published private(set) var pricingError: String?
    private(set) var costsError: String? {
        get { costsState.read(\.error) }
        set { updateCosts { $0.error = newValue } }
    }
    private(set) var selectedProjectID: Int64? {
        get { sidebarState.read(\.selectedProjectID) }
        set { updateSidebar { $0.selectedProjectID = newValue } }
    }
    private(set) var selectedProjectCanonicalKey: String? {
        get { sidebarState.read(\.selectedProjectCanonicalKey) }
        set { updateSidebar { $0.selectedProjectCanonicalKey = newValue } }
    }
    private(set) var selectedProjectDisplayName: String? {
        get { sidebarState.read(\.selectedProjectDisplayName) }
        set { updateSidebar { $0.selectedProjectDisplayName = newValue } }
    }
    private(set) var sidebarRevealRequest: SidebarRevealRequest? {
        get { sidebarState.read(\.sidebarRevealRequest) }
        set { updateSidebar { $0.sidebarRevealRequest = newValue } }
    }
    private(set) var selectedSessionID: Int64? {
        get { transcriptState.read(\.sessionID) }
        set { updateTranscript { $0.sessionID = newValue } }
    }
    @Published var customCostStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @Published var customCostEnd = Date()
    var expandedReasoningIDs: Set<Int64> {
        get { transcriptState.read(\.expanded) }
        set { updateTranscript { $0.expanded = newValue; $0.contentRevision &+= 1 } }
    }
    var startupError: String? {
        get { sidebarState.read(\.startupError) }
        set {
            sourceReloadAlertError = nil
            updateSidebar { $0.startupError = newValue }
        }
    }
    private var sourceReloadAlertError: String?
    private(set) var monitoringWarnings: [String] {
        get { sidebarState.read(\.monitoringWarnings) }
        set { updateSidebar { $0.monitoringWarnings = newValue } }
    }
    private var metadataMonitoringWarnings: [String] = []
    private var sourceMonitoringWarnings: [String] = []
    var transcriptMessageRevision: Int { transcriptState.read(\.messageRevision) }
    var transcriptContentRevision: Int { transcriptState.read(\.contentRevision) }

    private var database: IndexDatabase?
    private var coordinator: IndexCoordinator?
    private var rebuildAttachmentReady: Bool {
        get { sidebarState.read(\.rebuildAttachmentReady) }
        set { updateSidebar { $0.rebuildAttachmentReady = newValue } }
    }
    private var initialAttachmentFailure: String? {
        get { sidebarState.read(\.initialAttachmentFailure) }
        set { updateSidebar { $0.initialAttachmentFailure = newValue } }
    }
    var canRebuildIndex: Bool { rebuildAttachmentReady && settings.onboardingComplete && !terminating }
    var rebuildUnavailableReason: String? {
        if !rebuildAttachmentReady {
            if initialAttachmentFailure != nil {
                return "Rebuild is unavailable because index startup failed. Resolve the startup error and restart Trace."
            }
            return "Rebuild is available after the index finishes opening."
        }
        if !settings.onboardingComplete { return "Complete onboarding to rebuild the index." }
        return nil
    }
    private var watchers: [FSEventsWatcher] = []
    private var metadataWatcher: CodexMetadataWatcher?
    private var watcherTeardownTask: Task<Void, Never>?
    private struct WatcherOwner: Equatable, Sendable {
        let database: IndexDatabase
        let attachment: UUID
        let revision: UInt64
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.database === rhs.database && lhs.attachment == rhs.attachment && lhs.revision == rhs.revision
        }
    }
    private struct WatcherReceipt: Equatable, Sendable {
        let owner: WatcherOwner
        let attempt: UUID
        let generation: UInt64
    }
    private enum WatcherStartOutcome: Sendable {
        case started(WatcherReceipt)
        case deferredByOnboarding(WatcherReceipt)
        case superseded
    }
    private final class WatcherStartup {
        enum Phase { case preparing, ready, deferred }
        let owner: WatcherOwner
        let attempt = UUID()
        let generation: UInt64
        var forceRootReconciliation: Bool
        var phase = Phase.preparing
        var hasTranscriptRoots = false
        var ready: Bool { phase == .ready }
        var receipt: WatcherReceipt { .init(owner: owner, attempt: attempt, generation: generation) }
        var task: Task<WatcherStartOutcome, Never>?
        init(owner: WatcherOwner, generation: UInt64, forceRootReconciliation: Bool) {
            self.owner = owner
            self.generation = generation
            self.forceRootReconciliation = forceRootReconciliation
        }
    }
    private var watcherStartup: WatcherStartup?
    private var sourceReloadActivation: WatcherOwner?
    private var scheduler: IndexScheduler?
    private var attachmentGeneration = UUID()
    private var schedulerTeardownTask: Task<Void, Never>?
    private enum AttachmentIntent { case installation, sourceReload }
    private struct PendingAttachment {
        let token = UUID()
        let database: IndexDatabase
        let configurationRevision: UInt64
        let intent: AttachmentIntent
        var rootRefresh: RootSummaryRefresh?
        let usageEvent: UInt64
    }
    private var pendingAttachment: PendingAttachment?
    private var pendingRebuild = false

    /// Closed before reset notification, opened only after scheduler cancellation
    /// has been admitted. Waiters never hold up the scheduler's request method.
    @MainActor
    private final class RebuildAdmission {
        let id = UUID()
        let database: IndexDatabase
        let attachment: UUID
        let configuration: UInt64
        let workflow: UUID
        var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        #if DEBUG
        var submissionGate: Task<Void, Never>?
        var waitingForSubmission = false
        #endif

        init(database: IndexDatabase, attachment: UUID, configuration: UInt64, workflow: UUID) {
            self.database = database; self.attachment = attachment
            self.configuration = configuration; self.workflow = workflow
        }
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    private var rebuildAdmission: RebuildAdmission?
    var isPreparingRebuild: Bool { sidebarState.read(\.preparingRebuild) }
    private func retireRebuildAdmission(_ expected: RebuildAdmission? = nil) {
        if let expected, rebuildAdmission !== expected { return }
        let previous = rebuildAdmission
        rebuildAdmission = nil
        previous?.release()
        if isPreparingRebuild { updateSidebar { $0.preparingRebuild = false } }
    }
    private func admitRebuild() -> RebuildAdmission? {
        guard let database, !terminating, pendingAttachment == nil else { return nil }
        if let rebuildAdmission { return rebuildAdmission }
        let receipt = RebuildAdmission(database: database, attachment: attachmentGeneration,
            configuration: sourceConfigurationRevision, workflow: indexWorkflow.generation)
        #if DEBUG
        receipt.submissionGate = rebuildSubmissionGateForTesting
        rebuildSubmissionGateForTesting = nil
        #endif
        rebuildAdmission = receipt
        updateSidebar { $0.preparingRebuild = true }
        return receipt
    }
    private func rebuildAdmissionIsCurrent(_ receipt: RebuildAdmission) -> Bool {
        !terminating && rebuildAdmission === receipt && database === receipt.database
            && attachmentGeneration == receipt.attachment && sourceConfigurationRevision == receipt.configuration
            && indexWorkflow.generation == receipt.workflow && pendingAttachment == nil
    }
    private func submitRebuild(_ receipt: RebuildAdmission, scheduler: IndexScheduler) async {
        #if DEBUG
        defer { completedRebuildSubmissionsForTesting.insert(receipt.id) }
        if let gate = receipt.submissionGate {
            receipt.waitingForSubmission = true
            await gate.value
            receipt.waitingForSubmission = false
        }
        #endif
        guard rebuildAdmissionIsCurrent(receipt) else { return }
        await scheduler.request(rebuild: true, scope: settings.indexScope)
        if rebuildAdmissionIsCurrent(receipt) { receipt.release() }
    }
    private var terminating = false
    private var bufferedSourceChanges = SourceChanges()
    private var watcherStartupPending = true
    private var startupReconciliationPaths: Set<String> = []
    private var startupActivity = IndexActivity.cachedLaunch
    private var pendingStartupRecovery = IndexRecoveryWork()
    private var watchedSourceRoots: [URL] = []
    private var watcherGeneration: UInt64 = 0
    // The first delivered watermark is a conservative replay point while the
    // scheduler is still committing its persisted checkpoint.
    private var liveWatcherReplayStarts: [String: UInt64] = [:]
    private var safetyVerificationTask: Task<Void, Never>?
    private var hydrationOrder: [Int64] = []
    private struct MessageIdentity: Equatable {
        let id: Int64
        let path: String
        let format: String
        let locator: RecordLocator

        init(_ message: MessageSummary) {
            id = message.id
            path = message.sourcePath
            format = message.sourceFormat.rawValue
            locator = message.locator
        }
    }
    private var messageIdentities: [Int64: MessageIdentity] = [:]
    private var hydrationEpoch = UUID()
    private struct HydrationRequest {
        let token = UUID()
        let epoch: UUID
        let identity: MessageIdentity
    }
    private var hydratingMessageIDs: [Int64: HydrationRequest] = [:]
    private let hydrationCacheLimit = 512
    private var sourceChangeTask: Task<Void, Never>?
    private var sourceConfigurationRevision: UInt64 = 0
    private var startupSetupComplete = false
    private var lastSummaryRefresh: AnyClock<Duration>.Instant
    private var incrementalProgressTask: Task<Void, Never>?
    private var pendingIncrementalProgress: IndexProgress?
    private var incrementalProgressVisible = false
    private var automaticSearchTask: Task<Void, Never>?
    private var searchVisibilityTask: Task<Void, Never>?
    private var automaticSearchTaskID: UUID?
    private var globalSearchNeedsRefresh = false
    private var mainSearchNeedsRefresh = false
    private var globalSearchSurfaces: Set<GlobalSearchSurface> = []
    private var mainWindowVisible = false
    private var mainSearchPanelVisible = false
    private var completedUsage: [UsageRollup] { costsState.read(\.completed) }
    private var completedUsageRevision = 0
    private enum UsageUrgency { case automatic, immediate }
    private struct UsageRefreshRequest {
        #if DEBUG
        let id = UUID()
        #endif
        let database: IndexDatabase
        let revision: UInt64
        let repair: Bool
        var urgency: UsageUrgency
    }
    private struct UsageRefreshWorker {
        enum Phase {
            case waiting(UsageUrgency)
            case running(UsageRefreshRequest, epoch: UUID)
        }
        let id = UUID()
        let database: IndexDatabase
        var phase: Phase
        var isWaiting: Bool { if case .waiting = phase { true } else { false } }
        var runningRequest: UsageRefreshRequest? {
            if case .running(let request, _) = phase { request } else { nil }
        }
        var acceptanceEpoch: UUID? {
            if case .running(_, let epoch) = phase { epoch } else { nil }
        }
        var urgency: UsageUrgency {
            switch phase {
            case .waiting(let urgency): urgency
            case .running(let request, _): request.urgency
            }
        }
    }
    private struct UsageWorkState {
        var revision: UInt64 = 0
        var epoch = UUID()
        var owed = false
        var repair = false
        var consumedEvent: UInt64 = 0
        var pending: UsageRefreshRequest?
        var worker: UsageRefreshWorker?
        var task: Task<Void, Never>?
    }
    private var usageWork = UsageWorkState()
    private struct RollupFailureReceipt {
        let id = UUID()
        let database: IndexDatabase
        let passID: UUID
    }
    private var rollupFailure: RollupFailureReceipt?
    // Enrollment survives same-database resets and includes failed repair attempts.
    private var startupUsageRepairEnrolled = false
    private var usageRecoverySequence: UInt64 = 0
    private var installedUsageEvent: UInt64?
    #if DEBUG
    private var usageDatabaseGeneration = UUID()
    #endif

    private func newUsageRecoveryEvent() -> UInt64 {
        usageRecoverySequence &+= 1
        return usageRecoverySequence
    }
    private var indexWorkflow = IndexWorkflowState()
    private var indexingPassActive: Bool { indexWorkflow.isActive }
    private var lastAutomaticSearchRefresh: AnyClock<Duration>.Instant?
    private var lastObservedPassID: UUID?
    private var lastObservedMutationRevision = 0
    private var lastSearchedPassID: UUID?
    private var lastSearchedMutationRevision = 0
    private var timeZoneObserver: NSObjectProtocol?
    private var sessionRequestID = UUID()
    private struct KnownSelectionProject {
        let database: IndexDatabase
        let sessionID: Int64
        let canonicalKey: String
    }
    private struct MissingSelectionAttempt {
        let database: IndexDatabase
        let session: Int64
        let request: UUID
        let project: String?
        let configuration: UInt64
        let dataGeneration: UUID
    }
    private var sidebarDataGeneration = UUID()
    private var missingSelectionAttempt: MissingSelectionAttempt?

    private func alreadyEnsuredMissingSelection(_ id: Int64) -> Bool {
        guard let attempt = missingSelectionAttempt else { return false }
        return attempt.database === database && attempt.session == id && attempt.request == sessionRequestID
            && attempt.project == selectedProjectCanonicalKey && attempt.configuration == sourceConfigurationRevision
            && attempt.dataGeneration == sidebarDataGeneration
    }

    private var knownSelectionProject: KnownSelectionProject?
    // During synchronous page notification, a selection can refer to a row
    // removed by this commit. Retain its already-known project until delivery ends.
    private var publishingPageSelectionMetadata: (database: IndexDatabase, sessions: [SessionSummary])?

    private func knownProject(for sessionID: Int64) -> String? {
        if let knownSelectionProject, knownSelectionProject.database === database,
           knownSelectionProject.sessionID == sessionID { return knownSelectionProject.canonicalKey }
        if let session = selectedSession, session.id == sessionID { return session.projectCanonicalKey }
        if let session = sessions.first(where: { $0.id == sessionID })
            ?? recentSessions.first(where: { $0.id == sessionID }) {
            return session.projectCanonicalKey
        }
        if let metadata = publishingPageSelectionMetadata, metadata.database === database,
           let session = metadata.sessions.first(where: { $0.id == sessionID }) { return session.projectCanonicalKey }
        if let reveal = sidebarRevealRequest, reveal.sessionID == sessionID { return reveal.projectCanonicalKey }
        return nil
    }

    private func rememberSelectionProject(_ canonicalKey: String?, sessionID: Int64) {
        knownSelectionProject = database.flatMap { database in
            canonicalKey.map { .init(database: database, sessionID: sessionID, canonicalKey: $0) }
        }
    }
    private enum TranscriptReadOutcome {
        case snapshot(SessionTranscriptSnapshot)
        case failed(String)
        case superseded
    }
    private struct PendingSelectionTranscriptRead {
        let requestID: UUID
        let task: Task<TranscriptReadOutcome, Never>
    }
    private var pendingSelectionTranscriptRead: PendingSelectionTranscriptRead?
    private struct SelectionCompletion {
        let database: IndexDatabase
        let sessionID: Int64
        let requestID: UUID
        var showWindow: Bool
        let preservingMainSearch: Bool
    }
    private var pendingSelectionCompletion: SelectionCompletion?
    private var transcriptRecoveryTask: Task<Void, Never>?
    private struct TranscriptRecoveryEpisode {
        enum Phase {
            case running
            case exhausted(String)
        }
        let id = UUID()
        let database: IndexDatabase
        let sessionID: Int64
        let requestID: UUID
        var phase: Phase = .running
    }
    private var transcriptRecoveryEpisode: TranscriptRecoveryEpisode?
    fileprivate struct TranscriptAbsence: Sendable {
        let database: IndexDatabase
        let sessionID: Int64
        let requestID: UUID
        var paused = false
    }
    private var transientTranscriptAbsence: TranscriptAbsence? {
        get { transcriptState.value.absence }
        set { updateTranscript { $0.absence = newValue } }
    }
    // Selection preservation outlives the visible absence banner when recovery fails.
    private var pausedTranscriptPreservation: TranscriptAbsence?
    private var transcriptReadError: String? {
        get { transcriptState.value.readError }
        set { updateTranscript { $0.readError = newValue } }
    }
    enum TranscriptFeedback: Equatable {
        case updating, paused, readError

        var message: String {
            switch self {
            case .updating: "This session is temporarily unavailable while the index updates. Retry now or wait for indexing to finish."
            case .paused: "This session is unavailable because index updates are paused. Retry now or resume indexing to check again."
            case .readError: "Could not refresh this session. Try again."
            }
        }
    }
    struct TranscriptBannerPresentation: Equatable {
        let feedback: TranscriptFeedback
        let details: String

        var message: String { feedback.message }
    }
    var transcriptBanner: TranscriptBannerPresentation? {
        let error = transcriptReadError
        if let absence = transientTranscriptAbsence,
           transcriptRequestIsCurrent(database: absence.database, sessionID: absence.sessionID, request: absence.requestID) {
            let feedback: TranscriptFeedback = absence.paused ? .paused : .updating
            return .init(feedback: feedback, details: error.map { feedback.message + "\n" + $0 } ?? feedback.message)
        }
        guard let error else { return nil }
        return .init(feedback: .readError, details: error)
    }
    private struct TranscriptSettlement {
        let id = UUID()
        let database: IndexDatabase
        let attachment: UUID
        let configuration: UInt64
        let workflow: UUID
        let sessionID: Int64?
        let requestID: UUID
        let summaryID: UUID
        let revalidateAbsence: Bool
    }
    private var transcriptSettlement: TranscriptSettlement?
    private var transcriptSettlementTask: Task<Void, Never>?
    private struct SummaryRefreshOwner {
        let id = UUID()
        let database: IndexDatabase
        let attachment: UUID
        let configuration: UInt64
        #if DEBUG
        var holdsSidebarForUITesting = false
        var sidebarGateForTesting: Task<Void, Never>?
        var failsSidebarForTesting = false
        #endif
    }
    private struct TerminalSummaryReceipt {
        let id = UUID()
        let database: IndexDatabase
        let attachment: UUID
        let configuration: UInt64
        let workflow: UUID
        let reconciliation: ProjectReconciliationMode
        let usageEvent: UInt64
    }
    private struct ConfiguredRootIdentity: Hashable {
        let agent: AgentKind
        let path: String
    }
    private struct RootSummaryRefresh {
        let id = UUID()
        let database: IndexDatabase
        var projects = true
        var sessions = true
        var statistics = true
        var usage = true
        var metadataPending: Bool { projects || sessions || statistics }
    }
    private var pendingRootSummaryRefresh: RootSummaryRefresh?
    private var rootSynchronizationTask: Task<Bool, Error>?
    private var rootSynchronizationID: UUID?
    private enum SidebarReadContext { case ordinary, startup }
    private var pendingFullSummaryRefresh: TerminalSummaryReceipt?
    private var terminalSummaryTaskID: UUID?
    private var terminalSummaryTask: Task<Void, Never>?
    // Includes current reads awaiting row recovery or selection reconciliation.
    private var highestObservedTranscriptReadRevision: UInt64 = 0
    private var lastAppliedTranscriptReadRevision: UInt64 = 0
    private var projectRequestID = UUID()
    private var summaryRequestID = UUID()
    var scrollPositions: [Int64: TranscriptBookmark] = [:]
    private(set) var scrollRequest: UUID {
        get { sidebarState.read(\.scrollRequest) }
        set { updateSidebar { $0.scrollRequest = newValue } }
    }
    private(set) var requestedMessageID: Int64?
    private var mayRestoreSession = true
    enum SummaryReadOperation: String, Hashable { case sidebar, restoration, sourceHealth, statistics, sessionList, sessionPage, indexStatus, sourceReload }
    private struct DatabaseFailureDiagnostic: Hashable {
        let primary: Int32?
        let extended: Int32?
        let message: String

        init(_ error: Error) {
            let sqlite = error as? DatabaseError
            primary = sqlite?.resultCode.rawValue
            extended = sqlite?.extendedResultCode.rawValue
            // Descriptions may include SQL and arguments. Even the underlying
            // message is private; it is never part of visible recovery state.
            message = sqlite.map { $0.message ?? "SQLite operation failed" } ?? error.localizedDescription
        }

        func log(to logger: Logger, operation: String) {
            logger.error("\(operation, privacy: .public) failed; SQLite primary=\(primary.map(String.init) ?? "n/a", privacy: .public) extended=\(extended.map(String.init) ?? "n/a", privacy: .public); \(message, privacy: .private)")
        }
    }
    private var summaryReadFailures: [SummaryReadOperation: Set<DatabaseFailureDiagnostic>] = [:]
    private static let summaryReadLog = Logger(subsystem: "me.haroldmartin.Trace", category: "Summary reads")
    enum CostsFailureOperation: String, Hashable { case cachedUsage, usageRefresh }
    private var costsFailures: [CostsFailureOperation: Set<DatabaseFailureDiagnostic>] = [:]
    private static let costsLog = Logger(subsystem: "me.haroldmartin.Trace", category: "Costs")
    private var started = false
    private var initialIndexRequested = false
    private var sidebarProjectRevealAcknowledged = false
    private var sidebarProjectMaterializedToken: UUID?
    private var sidebarSessionRevealAcknowledged = false
    private var sidebarRevealFallbackTask: Task<Void, Never>?
    private let watcherGroupingPolicy: WatcherGroupingPolicy
    private let startupActivityObserver: (IndexActivity) -> Void

    init(
        settings: AppSettings = AppSettings(),
        clock: any Clock<Duration> = ContinuousClock(),
        diagnostics: DiagnosticsStore? = nil,
        watcherGroupingPolicy: WatcherGroupingPolicy = .byVolume,
        startupActivityObserver: @escaping (IndexActivity) -> Void = { _ in },
        diagnosticsURL: URL? = nil
    ) {
        self.settings = settings
        let clock = AnyClock(clock)
        self.clock = clock
        lastSummaryRefresh = clock.now
        globalSearch = SessionSearchModel(clock: clock)
        mainSearch = SessionSearchModel(clock: clock)
        self.watcherGroupingPolicy = watcherGroupingPolicy
        self.startupActivityObserver = startupActivityObserver
        self.diagnostics = diagnostics ?? DiagnosticsStore(url: diagnosticsURL ?? TraceRuntime.testDirectory?.appendingPathComponent("diagnostics.json") ?? DiagnosticsStore.defaultURL())
    }

    #if DEBUG
    func attachForTesting(database: IndexDatabase, sources: [any SessionSource]) async {
        let coordinator = IndexCoordinator(database: database, sources: sources, clock: clock)
        await attach(database: database, coordinator: coordinator)
    }

    // This flag controls project reconciliation, not the indexing workflow.
    // Tests of terminal passes must deliver terminal progress through receiveProgress.
    func refreshSummariesForTesting(terminalProjectReconciliation: Bool = true, lightweight: Bool = true) async {
        await reloadSummaries(lightweight: lightweight,
                              projectReconciliation: terminalProjectReconciliation ? .terminalRetaining : .ongoing,
                              usageEvent: lightweight ? nil : newUsageRecoveryEvent())
    }

    func setUnresolvedSelectionForTesting(_ id: Int64) {
        updateTranscript { $0.sessionID = id; $0.session = nil; $0.messages = [] }
    }
    func queueMainSearchRefreshForTesting() { mainSearchNeedsRefresh = true }
    var selectionTranscriptReadGateForTesting: Task<Void, Never>?
    var selectionTranscriptGateForTesting: Task<Void, Never>?
    var summaryTranscriptGateForTesting: Task<Void, Never>?
    var summaryTranscriptFailureGateForTesting: Task<Void, Never>?
    private(set) var summaryTranscriptFailureWaitingForTesting = false
    var summaryRestorationGateForTesting: Task<Void, Never>?
    private(set) var summaryRestorationWaitingForTesting = false
    var usageSnapshotGateForTesting: Task<Void, Never>?
    private(set) var usageSnapshotWaitingForTesting = false
    var usageFailureGateForTesting: Task<Void, Never>?
    private(set) var usageFailureWaitingForTesting = false
    var cachedUsageFailureGateForTesting: Task<Void, Never>?
    private(set) var cachedUsageFailureWaitingForTesting = false
    struct SummaryReadFailure: Equatable {
        let operation: SummaryReadOperation
        let primaryCode: Int32?
        let extendedCode: Int32?
    }
    var summaryReadFailureForTesting: ((SummaryReadFailure) -> Void)?
    private(set) var sidebarTestControlFailuresForTesting: [UUID] = []
    var sidebarMarkerPathForTesting: String?
    var summaryMetadataGateForTesting: Task<Void, Never>?
    private(set) var summaryMetadataWaitingForTesting = false
    struct FullSummaryCompletion: Codable {
        let summaryID: UUID
        let terminalWorkflowID: UUID?
        let storedSessionID: Int64?
        let mayRestoreSession: Bool
        let selectedSessionID: Int64?
        let selectedProjectCanonicalKey: String?
        let loadedSessionPageCount: Int
    }
    private(set) var fullSummaryCompletionForTesting: FullSummaryCompletion?
    var launchRestorationEligibleForTesting: Bool { mayRestoreSession }
    var terminationStartedForTesting: Bool { terminating }
    var rootSummaryRefreshPendingForTesting: Bool { pendingRootSummaryRefresh != nil }
    var rootSessionRefreshPendingForTesting: Bool { pendingRootSummaryRefresh?.sessions == true }
    var rootMetadataRefreshPendingForTesting: Bool { pendingRootSummaryRefresh?.metadataPending == true }
    var pendingAttachmentRootRefreshForTesting: Bool { pendingAttachment?.rootRefresh != nil }
    var sessionPageDepthForTesting: Int { pageState.read(\.pageCount) }
    var requestedPageDepthForTesting: Int { pageState.read(\.requestedDepth) }
    var sessionCursorIDForTesting: Int64? { pageState.read(\.cursor)?.sessionID }
    var usageRefreshWaitingForTesting: Bool { usageWork.worker?.isWaiting == true }
    var usageRefreshRunningForTesting: Bool { usageWork.worker?.runningRequest != nil }
    var usageDemandOwedForTesting: Bool { usageWork.owed }
    var startupUsageRepairEnrolledForTesting: Bool { database != nil && startupUsageRepairEnrolled }
    var usagePendingForTesting: Bool { usageWork.pending != nil }
    var usageDemandRevisionForTesting: UInt64 { usageWork.revision }
    func publishProgressForTesting(_ update: IndexProgress) { progress = update }
    func loadCachedUsageForTesting() async { await loadCachedUsageAtStartup() }
    func finalizeStartupUsageForTesting() async { await refreshStartupUsage() }
    struct CostsFailure: Equatable {
        let operation: CostsFailureOperation
        let primaryCode: Int32?
        let extendedCode: Int32?
    }
    var costsFailureForTesting: ((CostsFailure) -> Void)?
    struct UsageAttemptReceipt: Codable, Equatable {
        enum Outcome: String, Codable { case success, failure }
        let databaseGeneration: UUID
        let workerID: UUID
        let requestID: UUID
        let outcome: Outcome
    }
    private var usageHoldRequestForUITesting: UUID?
    private var usageHoldWasConsumedForUITesting = false
    var usageControlErrorForTesting: Error?
    private(set) var usageControlFailuresForTesting: [UUID] = []
    private(set) var usageAttemptReceiptsForTesting: [UsageAttemptReceipt] = []
    func requestUsageRefreshForTesting(repair: Bool, immediately: Bool) {
        registerUsageDemand(repair: repair, urgency: immediately ? .immediate : .automatic)
        reconcileUsageWork()
    }
    func synchronizeRootsForTesting(_ roots: [SourceRoot], database: IndexDatabase) async throws {
        _ = try await synchronizeConfiguredRoots(roots, database: database, configuration: sourceConfigurationRevision)
    }
    func failSidebarSummaryForUITesting() {
        failSidebarReadForUITesting = true
        Task {
            await reloadSummaries()
        }
    }
    private var failListReadForUITesting = false
    private var failPageReadForUITesting = false
    func failNextSessionReadForUITesting(pagination: Bool) {
        if pagination { failPageReadForUITesting = true }
        else { failListReadForUITesting = true }
    }
    @discardableResult
    func refreshSidebarForUITesting(launchGate: Task<Void, Never>? = nil) -> Task<Void, Never>? {
        guard let database else { return nil }
        var owner = SummaryRefreshOwner(database: database, attachment: attachmentGeneration,
                                        configuration: sourceConfigurationRevision)
        owner.holdsSidebarForUITesting = true
        summaryRequestID = owner.id
        TraceTestHooks.appendLine(owner.id.uuidString, pathKey: "TRACE_TEST_SUMMARY_PAGE_REQUESTED_PATH")
        return Task { [weak self] in
            await launchGate?.value
            guard let self, !Task.isCancelled, summaryRefreshIsCurrent(owner) else { return }
            await reloadSummaries(owner: owner)
        }
    }
    private(set) var heldSidebarSummaryIDsForTesting: [UUID] = []
    func refreshHeldSummaryForTesting(gate: Task<Void, Never>, failRead: Bool = false) async {
        guard let database else { return }
        var owner = SummaryRefreshOwner(database: database, attachment: attachmentGeneration,
                                        configuration: sourceConfigurationRevision)
        owner.sidebarGateForTesting = gate
        owner.failsSidebarForTesting = failRead
        await reloadSummaries(owner: owner)
    }
    private func checkSessionReadFailureForUITesting(pagination: Bool) throws {
        guard pagination ? failPageReadForUITesting : failListReadForUITesting else { return }
        if pagination { failPageReadForUITesting = false }
        else { failListReadForUITesting = false }
        throw DatabaseError(resultCode: .SQLITE_BUSY, message: "private-page-message",
            sql: "SELECT 'private-page-sql'", arguments: ["private-page-argument"], publicStatementArguments: true)
    }
    private var failSidebarReadForUITesting = false
    var rootSynchronizationBookkeepingGateForTesting: Task<Void, Never>?
    private(set) var rootSynchronizationBookkeepingWaitingForTesting = false
    var summarySidebarGateForTesting: Task<Void, Never>?
    private(set) var summarySidebarWaitingForTesting = false
    var sidebarSummaryRetryPendingForTesting: Bool { sidebarSummaryRetryOwner != nil || pendingSidebarSummaryRetry }
    var configuredRootsPublicationGateForTesting: Task<Void, Never>?
    private(set) var configuredRootsPublicationWaitingForTesting = false
    var transcriptRecoveryReadGateForTesting: Task<Void, Never>?
    var transcriptRecoveryPublicationGateForTesting: Task<Void, Never>?
    var transcriptSettlementGateForTesting: Task<Void, Never>?
    private(set) var transcriptSettlementWaitingForTesting = false
    var transcriptSettlementPendingForTesting: Bool { transcriptSettlementTask != nil }
    var fullSummaryRefreshPendingForTesting: Bool { pendingFullSummaryRefresh != nil }
    var terminalSummaryPendingForTesting: Bool { terminalSummaryTask != nil }
    var hydrationPublicationGateForTesting: Task<Void, Never>?
    var summaryTailGateForTesting: Task<Void, Never>?
    var schedulerProgressGateForTesting: Task<Void, Never>?
    var schedulerCompletionGateForTesting: Task<Void, Never>?
    var sourceChangeAttachmentGateForTesting: Task<Void, Never>?
    var watcherPreparationGateForTesting: Task<Void, Never>?
    var watcherReadinessGateForTesting: Task<Void, Never>?
    var watcherOutcomeGateForTesting: Task<Void, Never>?
    private(set) var watcherOutcomeWaitingForTesting = false
    var failsWatcherStartForTesting = false
    var initialIndexOpenErrorForTesting: String?
    var initialDatabaseForTesting: IndexDatabase?
    var recoveryLoadErrorForTesting: Error?
    @discardableResult
    func resetIndexForTesting() -> Bool { prepareForIndexReset() }
    func beginTerminationForTesting() { terminating = true; retireRebuildAdmission() }
    var rebuildSubmissionGateForTesting: Task<Void, Never>?
    var rebuildAdmissionIDForTesting: UUID? { rebuildAdmission?.id }
    private(set) var completedRebuildSubmissionsForTesting: Set<UUID> = []
    var rebuildSubmissionWaitingForTesting: Bool { rebuildAdmission?.waitingForSubmission == true }
    private(set) var admissionWaitingPassesForTesting: Set<UUID> = []
    private var ownedSchedulerProgressGateForTesting: (pass: UUID, gate: Task<Void, Never>)?
    private(set) var ownedSchedulerProgressWaitingForTesting = false
    private(set) var schedulerProgressPassForTesting: UUID?
    func gateSchedulerProgressForTesting(pass: UUID, gate: Task<Void, Never>?) {
        ownedSchedulerProgressGateForTesting = gate.map { (pass, $0) }
    }
    func receiveProgress(_ update: IndexProgress) async {
        guard let database else { return }
        await acceptSchedulerProgress(update, database: database, generation: attachmentGeneration)
    }
    var sidebarDataGenerationForTesting: UUID { sidebarDataGeneration }

    var workflowGenerationForTesting: UUID { indexWorkflow.generation }
    var usageRecoveryEventForTesting: UInt64 { usageRecoverySequence }
    var activeWatcherCountForTesting: Int { watchers.count }
    var metadataWatcherAttachedForTesting: Bool { metadataWatcher != nil }
    var safetyVerificationActiveForTesting: Bool { safetyVerificationTask != nil }
    private(set) var watcherPreparationWaitingForTesting = false
    private(set) var watcherReadinessWaitingForTesting = false
    private(set) var watcherStartCountForTesting = 0
    private(set) var startupSubmissionCountForTesting = 0
    var watcherReadyForTesting: Bool { watcherStartup?.ready == true }
    var watcherRequiresRootReconciliationForTesting: Bool { watcherStartup?.forceRootReconciliation == true }
    var watcherGenerationForTesting: UInt64 { watcherGeneration }
    var startupReconciliationPathsForTesting: Set<String> { startupReconciliationPaths }
    func startWatchingForTesting(_ sources: [any SessionSource], force: Bool = false) async -> Bool {
        switch await startWatching(sources, forceRootReconciliation: force) {
        case .started(let receipt): return watcherReadyIsCurrent(receipt)
        case .deferredByOnboarding(let receipt): settleDeferredSourceReload(receipt: receipt); return false
        case .superseded: return false
        }
    }
    private(set) var schedulerProgressWaitingForTesting = false
    private(set) var schedulerCompletionWaitingForTesting = false
    private(set) var sourceChangeAttachmentWaitingForTesting = false
    var schedulerForTesting: IndexScheduler? { scheduler }
    var coordinatorForTesting: IndexCoordinator? { coordinator }
    var databaseForTesting: IndexDatabase? { database }
    var pendingDatabaseForTesting: IndexDatabase? { pendingAttachment?.database }
    var pendingAttachmentTokenForTesting: UUID? { pendingAttachment?.token }
    var indexingPassActiveForTesting: Bool { indexingPassActive }
    var activeIndexPassIDForTesting: UUID? { indexWorkflow.activePassID }
    var pendingRebuildForTesting: Bool { pendingRebuild }
    private(set) var rebuildSubmissionCountForTesting = 0
    var sourceReloadSourcesForTesting: [any SessionSource]?
    var failSourceConfigurationForTesting = false
    var transcriptCopyForTesting: ((String) -> Void)?
    var isTerminatingForTesting: Bool { terminating }
    var transcriptRecoveryPendingForTesting: Bool { transcriptRecoveryTask != nil }
    func failSelectedTranscriptForTesting(_ error: String) {
        guard let database, let sessionID = selectedSessionID else { return }
        scheduleTranscriptRecovery(error: error, database: database, sessionID: sessionID, request: sessionRequestID)
    }
    func setPublishedProgressForTesting(_ update: IndexProgress) { publishProgress(update) }
    private(set) var selectionTranscriptReadWaitingForTesting = false
    private(set) var selectionTranscriptWaitingForTesting = false
    private(set) var summaryTranscriptWaitingForTesting = false
    private(set) var missingSummarySelectionReadWaitingForTesting = false
    private(set) var transcriptRecoveryReadWaitingForTesting = false
    private(set) var transcriptRecoveryPublicationWaitingForTesting = false
    private(set) var hydrationPublicationWaitingForTesting = false
    private(set) var summaryTailWaitingForTesting = false
    private var sessionPageReadGateForTesting: Task<Void, Never>?
    func gateSessionPagesForTesting(_ gate: Task<Void, Never>?) { sessionPageReadGateForTesting = gate }
    #endif

    func start() {
        guard !started else { return }
        started = true
        if TraceTestHooks.isUITesting, let error = TraceTestHooks.environment["TRACE_TEST_SEED_STARTUP_ERROR"] {
            startupError = error
        }
        Task {
            do {
                try await diagnostics.markLaunchStarted()
                #if DEBUG
                if let error = initialIndexOpenErrorForTesting { throw SessionSourceError.unreadableFile(error) }
                #endif
                if TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_INDEX_OPEN_ONCE") {
                    throw SessionSourceError.unreadableFile("Synthetic index startup failure")
                }
                let isolatedURL = TraceRuntime.testDirectory?.appendingPathComponent("index.sqlite")
                #if DEBUG
                let injectedDatabase = initialDatabaseForTesting
                #else
                let injectedDatabase: IndexDatabase? = nil
                #endif
                let database = try await Task.detached(priority: .userInitiated) {
                    if let injectedDatabase { return injectedDatabase }
                    if isolatedURL != nil,
                       let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_INDEX_OPEN_DELAY_MS", cappedAt: 5_000
                       ) {
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                    let url = try isolatedURL ?? IndexDatabase.defaultURL()
                    return try IndexDatabase(url: url)
                }.value
                guard installDatabase(database) else { return }
                if database.contentWasResetOnOpen { prepareForIndexReset() }
                var sources: [any SessionSource] = []
                var configuredRevision = sourceConfigurationRevision
                while true {
                    let revision = sourceConfigurationRevision
                    let latestSources = await makeSources()
                    guard revision == sourceConfigurationRevision else { continue }
                    _ = try await synchronizeConfiguredRoots(latestSources.flatMap(\.roots),
                        database: database, configuration: revision)
                    guard revision == sourceConfigurationRevision else { continue }
                    var recovery = IndexRecoveryWork()
                    var recoveryLoadError: Error?
                    do {
                        if let delay = TraceTestHooks.delayMilliseconds(
                            for: "TRACE_TEST_RECOVERY_LOAD_DELAY_MS", cappedAt: 5_000
                        ) {
                            TraceTestHooks.touch(pathKey: "TRACE_TEST_RECOVERY_LOAD_STARTED_PATH")
                            try await Task.sleep(for: .milliseconds(delay))
                        }
                        if TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_RECOVERY_LOAD_ONCE") {
                            throw SessionSourceError.unreadableFile("synthetic recovery metadata")
                        }
                        #if DEBUG
                        if let error = recoveryLoadErrorForTesting { recoveryLoadErrorForTesting = nil; throw error }
                        #endif
                        recovery = try await database.unresolvedRecoveryWork()
                        if let delay = TraceTestHooks.delayMilliseconds(
                            for: "TRACE_TEST_RECOVERY_LOADED_DELAY_MS", cappedAt: 10_000,
                            marker: .touch(pathKey: "TRACE_TEST_RECOVERY_LOADED_PATH")
                        ) {
                            try await Task.sleep(for: .milliseconds(delay))
                        }
                    } catch {
                        recoveryLoadError = error
                    }
                    guard revision == sourceConfigurationRevision else { continue }
                    if let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_FAILURE_COUNTS_HOLD_MS", cappedAt: 30_000,
                        marker: .touch(pathKey: "TRACE_TEST_FAILURE_COUNTS_STARTED_PATH")
                    ) {
                        try await TraceTestHooks.waitForRelease(
                            pathKey: "TRACE_TEST_FAILURE_COUNTS_RELEASE_PATH",
                            timeoutMilliseconds: delay
                        )
                    }
                    let counts = try? await database.unresolvedSourceFailureCounts()
                    guard revision == sourceConfigurationRevision else { continue }
                    sources = latestSources
                    configuredRevision = revision
                    if let counts {
                        progress.unresolvedFailedFiles = counts.fileFailures
                        progress.unresolvedDiscoveryFailures = counts.discoveryFailures
                    }
                    if let recoveryLoadError {
                        startupError = "Could not load pending index recovery; a safe root scan was queued. " + indexErrorMessage(recoveryLoadError)
                        pendingStartupRecovery = .init(
                            reconciliationPaths: Set(
                                sources.flatMap(\.roots).map { $0.scanURL.path }
                            )
                        )
                    } else {
                        pendingStartupRecovery = recovery
                    }
                    break
                }
                let coordinator = IndexCoordinator(database: database, sources: sources, clock: clock)
                guard await attach(database: database, coordinator: coordinator,
                                   configurationRevision: configuredRevision) else { return }
                timeZoneObserver = NotificationCenter.default.addObserver(
                    forName: Notification.Name.NSSystemTimeZoneDidChange,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    tzset()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.refreshCompletedUsage(repairIfDirty: true)
                    }
                }
                loadPricing()
                await reloadSummaries(loadCosts: false, sidebarReadContext: .startup)
                await loadCachedUsageAtStartup()
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_STARTUP_FINALIZATION_DELAY_MS", cappedAt: 120_000,
                    marker: .touch(pathKey: "TRACE_TEST_STARTUP_FINALIZATION_PATH")
                ) {
                    try await TraceTestHooks.waitForRelease(
                        pathKey: "TRACE_TEST_STARTUP_FINALIZATION_RELEASE_PATH",
                        timeoutMilliseconds: delay
                    )
                }
                #if DEBUG
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_STARTUP_POST_RELEASE_HOLD_MS", cappedAt: 30_000,
                    marker: .touch(pathKey: "TRACE_TEST_STARTUP_POST_RELEASE_STARTED_PATH")) {
                    try await TraceTestHooks.waitForRelease(
                        pathKey: "TRACE_TEST_STARTUP_POST_RELEASE_RELEASE_PATH", timeoutMilliseconds: delay)
                }
                #endif
                guard configuredRevision == sourceConfigurationRevision else { return }
                startupSetupComplete = true
                if settings.onboardingComplete {
                    guard case .started(let owner) = await startWatching(sources),
                          watcherReadyIsCurrent(owner) else { return }
                    guard configuredRevision == sourceConfigurationRevision else { return }
                    if ProcessInfo.processInfo.arguments.contains("--index-smoke"), TraceRuntime.testDirectory != nil {
                        await scheduler?.request(reconcile: true, scope: settings.indexScope)
                        await scheduler?.waitUntilIdle()
                        let snapshot = try await database.statistics()
                        let report: [String: Any] = ["messages": snapshot.messageCount, "sessions": snapshot.sessionCount,
                            "indexedFiles": progress.indexedFiles, "unchangedFiles": progress.unchangedFiles,
                            "failedFiles": progress.failedFiles, "phase": progress.phase.rawValue, "pricingLoaded": pricing != nil]
                        let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
                        FileHandle.standardOutput.write(data + Data("\n".utf8))
                        await prepareToTerminate()
                        exit(progress.phase == .complete && progress.failedFiles == 0 ? 0 : 1)
                    } else {
                        Task { [weak self] in
                            guard let self else { return }
                            self.startIndexing(sources: sources, configurationRevision: configuredRevision)
                        }
                    }
                } else {
                    Task { [weak self] in
                        guard let self else { return }
                        if !self.settings.onboardingComplete {
                            await self.refreshStartupUsage()
                        }
                    }
                }
            } catch {
                guard !terminating, coordinator == nil else { return }
                let message = indexErrorMessage(error)
                initialAttachmentFailure = message
                startupError = message
                progress = .init(phase: .failed, error: message)
            }
        }
    }

    func completeOnboarding(enableLoginItem: Bool) {
        do {
            if TraceRuntime.testDirectory == nil { try settings.setLaunchAtLogin(enableLoginItem) }
        } catch {
            startupError = "Could not update the login item: \(error.localizedDescription)"
        }
        settings.onboardingComplete = true
        if startupSetupComplete, coordinator != nil {
            Task { [weak self] in
                guard let self else { return }
                let revision = self.sourceConfigurationRevision
                let sources = await self.makeSources()
                guard revision == self.sourceConfigurationRevision else { return }
                guard case .started(let owner) = await self.startWatching(sources),
                      self.watcherReadyIsCurrent(owner) else { return }
                guard revision == self.sourceConfigurationRevision else { return }
                self.startIndexing(sources: sources, configurationRevision: revision)
            }
        }
    }

    private func makeScheduler(_ coordinator: IndexCoordinator, database: IndexDatabase,
                               generation: UUID) -> IndexScheduler {
        IndexScheduler(
            coordinator: coordinator, scope: settings.indexScope,
            progress: { [weak self] update in
                await self?.receiveSchedulerProgress(update, database: database, generation: generation)
            },
            clock: clock,
            didComplete: { [weak self] _, watermarks in
                await self?.completeSchedulerCheckpoint(watermarks, database: database, generation: generation)
            },
            didSatisfySafetyReconciliation: { [weak self] in
                guard await self?.attachmentIsCurrent(database: database, generation: generation) == true else { return }
                try? await database.markSafetyReconciliationComplete()
            }
        )
    }

    private func attachmentIsCurrent(database: IndexDatabase, generation: UUID) -> Bool {
        !terminating && self.database === database && attachmentGeneration == generation
    }

    private func receiveSchedulerProgress(_ update: IndexProgress, database: IndexDatabase,
                                          generation: UUID) async {
        guard !Task.isCancelled, attachmentIsCurrent(database: database, generation: generation) else { return }
        #if DEBUG
        schedulerProgressPassForTesting = update.passID
        if let owned = ownedSchedulerProgressGateForTesting, owned.pass == update.passID {
            ownedSchedulerProgressWaitingForTesting = true
            await owned.gate.value
            ownedSchedulerProgressWaitingForTesting = false
        }
        if let gate = schedulerProgressGateForTesting {
            schedulerProgressWaitingForTesting = true
            await gate.value
            schedulerProgressWaitingForTesting = false
        }
        if update.activity == .rebuild, update.phase == .discovering,
           let delay = TraceTestHooks.delayMilliseconds(
               for: "TRACE_TEST_REBUILD_PROGRESS_HOLD_MS", cappedAt: 120_000,
               marker: .touch(pathKey: "TRACE_TEST_REBUILD_PROGRESS_STARTED_PATH")) {
            try? await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_REBUILD_PROGRESS_RELEASE_PATH",
                                                  timeoutMilliseconds: delay)
        }
        #endif
        guard !Task.isCancelled, attachmentIsCurrent(database: database, generation: generation) else { return }
        await acceptSchedulerProgress(update, database: database, generation: generation)
    }

    private func acceptSchedulerProgress(_ update: IndexProgress, database: IndexDatabase, generation: UUID) async {
        while let receipt = rebuildAdmission, !receipt.open {
            guard !Task.isCancelled, attachmentIsCurrent(database: database, generation: generation) else { return }
            #if DEBUG
            admissionWaitingPassesForTesting.insert(update.passID)
            #endif
            await receipt.wait()
            #if DEBUG
            admissionWaitingPassesForTesting.remove(update.passID)
            #endif
        }
        guard !Task.isCancelled, attachmentIsCurrent(database: database, generation: generation) else { return }
        await receiveAdmittedProgress(update)
    }

    private func completeSchedulerCheckpoint(_ watermarks: [String: UInt64], database: IndexDatabase,
                                             generation: UUID) async {
        #if DEBUG
        if let gate = schedulerCompletionGateForTesting {
            schedulerCompletionWaitingForTesting = true
            await gate.value
            schedulerCompletionWaitingForTesting = false
        }
        #endif
        guard !Task.isCancelled, attachmentIsCurrent(database: database, generation: generation) else { return }
        try? await database.saveEventCheckpoints(watermarks)
    }

    /// Installs an already-open index after retiring displaced producers.
    @discardableResult
    func attach(database: IndexDatabase, coordinator: IndexCoordinator,
                configurationRevision: UInt64? = nil) async -> Bool {
        guard !terminating, !Task.isCancelled,
              configurationRevision == nil || configurationRevision == sourceConfigurationRevision else { return false }
        if pendingAttachment == nil, self.database === database, self.coordinator === coordinator,
           scheduler != nil { return true }
        if configurationRevision == nil, self.coordinator != nil || pendingAttachment != nil {
            sourceConfigurationRevision &+= 1
            sourceChangeTask?.cancel()
            sourceChangeTask = nil
        }
        let pending = beginAttachment(database: database, intent: .installation)
        return await finishAttachment(pending, coordinator: coordinator)
    }

    private func beginAttachment(database: IndexDatabase, intent: AttachmentIntent) -> PendingAttachment {
        ModelPublicationBatch.perform {
            invalidateTranscriptSettlement()
            invalidateTerminalSummaryRefresh()
            retireRebuildAdmission()
            let alreadyRetiring = pendingAttachment != nil
            let inheritedRootRefresh = pendingAttachment.flatMap { $0.database === database ? $0.rootRefresh : nil }
            let pending = PendingAttachment(database: database, configurationRevision: sourceConfigurationRevision,
                                            intent: intent, rootRefresh: inheritedRootRefresh,
                                            usageEvent: newUsageRecoveryEvent())
            pendingAttachment = pending
            resetSidebarSummaryRecovery(clearFailure: false)
            if case .failed(let error) = sourceReloadRecovery { sourceReloadRecovery = .retrying(error) }
            // Fence producers immediately, but keep the installed read dependencies usable.
            attachmentGeneration = UUID()
            incrementalProgressTask?.cancel()
            incrementalProgressTask = nil
            pendingIncrementalProgress = nil
            incrementalProgressVisible = false
            summaryRequestID = UUID()
            invalidateUsageSnapshot()
            if !alreadyRetiring, coordinator != nil { invalidateWatchers() }
            if let previousScheduler = scheduler {
                scheduler = nil
                let previousTeardown = schedulerTeardownTask
                schedulerTeardownTask = Task {
                    await previousTeardown?.value
                    await previousScheduler.stop()
                }
            }
            sourceReloadActivation = intent == .sourceReload
                ? WatcherOwner(database: database, attachment: pending.token, revision: pending.configurationRevision) : nil
            reconcileUsageWork()
            return pending
        }
    }

    private func pendingAttachmentIsCurrent(_ pending: PendingAttachment) -> Bool {
        !terminating && pendingAttachment?.token == pending.token
            && pending.configurationRevision == sourceConfigurationRevision
    }

    private func waitForAttachmentRetirement(_ pending: PendingAttachment) async -> Bool {
        await schedulerTeardownTask?.value
        guard pendingAttachmentIsCurrent(pending) else { return false }
        guard !Task.isCancelled else {
            failAttachment(pending, phase: .cancelled)
            return false
        }
        return true
    }

    private func failAttachment(_ pending: PendingAttachment, phase: IndexProgress.Phase = .failed,
                                error: String? = nil) {
        guard pendingAttachmentIsCurrent(pending) else { return }
        let error = error.map { message in
            pending.intent == .sourceReload && pendingRebuild
                ? message + "\nThe queued index rebuild was cancelled. Retry resumes updates without rebuilding. Choose Rebuild Index again to rebuild."
                : message
        }
        ModelPublicationBatch.perform {
            retireRebuildAdmission()
            sourceReloadActivation = nil
            if coordinator == nil, phase == .failed, let error { initialAttachmentFailure = error }
            if pending.intent == .sourceReload, let error {
                sourceReloadRecovery = .failed(error)
            } else if let previousError = sourceReloadRecovery.error {
                sourceReloadRecovery = .failed(previousError)
            }
            pendingAttachment = nil
            pendingRebuild = false
            indexWorkflow = .init()
            progress.phase = phase
            progress.error = error
            if let error {
                startupError = error
                if pending.intent == .sourceReload { sourceReloadAlertError = error }
            }
            reconcileUsageWork(event: pending.usageEvent)
            settleTranscriptFeedback()
        }
    }

    private func finishAttachment(_ pending: PendingAttachment, coordinator: IndexCoordinator) async -> Bool {
        guard await waitForAttachmentRetirement(pending) else { return false }
        let database = pending.database
        let sameDatabase = self.database === database
        var counts = SourceFailureCounts(fileFailures: progress.unresolvedFailedFiles,
                                         discoveryFailures: progress.unresolvedDiscoveryFailures)
        if !sameDatabase {
            do { counts = try await database.unresolvedSourceFailureCounts() }
            catch {
                failAttachment(pending, error: indexErrorMessage(error, sourceReload: pending.intent == .sourceReload,
                                                                prefix: "Could not load source failures: "))
                return false
            }
        }
        guard pendingAttachmentIsCurrent(pending), !Task.isCancelled else {
            if Task.isCancelled { failAttachment(pending, phase: .cancelled) }
            return false
        }
        let installed = ModelPublicationBatch.perform { () -> Bool in
            // No suspension during the commit: all readers switch databases together.
            let rootRefresh = pendingAttachment?.rootRefresh
            guard installDatabase(database) else {
                failAttachment(pending, phase: .cancelled)
                return false
            }
            if let rootRefresh {
                pendingRootSummaryRefresh = rootRefresh
                if rootRefresh.usage { registerUsageDemand(repair: true, urgency: .immediate) }
            }
            if sameDatabase, pending.intent == .sourceReload {
                indexWorkflow.retireActivePass()
            } else {
                indexWorkflow = .init()
                progress = .init(phase: .waiting)
                progress.unresolvedFailedFiles = counts.fileFailures
                progress.unresolvedDiscoveryFailures = counts.discoveryFailures
            }
            attachmentGeneration = pending.token
            schedulerTeardownTask = nil
            self.coordinator = coordinator
            globalSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
            mainSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
            scheduler = makeScheduler(coordinator, database: database, generation: pending.token)
            pendingAttachment = nil
            if pending.intent == .installation { sourceReloadRecovery = .normal }
            if let ownedError = sourceReloadAlertError, startupError == ownedError {
                startupError = nil
            }
            installedUsageEvent = pending.usageEvent
            if pending.intent == .sourceReload { summaryReadFailures[.sourceReload] = nil }
            if !sameDatabase, costsError != nil { costsError = nil }
            reconcileUsageWork(event: pending.usageEvent)
            initialAttachmentFailure = nil
            if !rebuildAttachmentReady { rebuildAttachmentReady = true }
            if pending.intent == .installation, pendingRebuild { rebuildIndex() }
            settleTranscriptFeedback()
            return true
        }
        return installed && !terminating && self.database === database && self.coordinator === coordinator
            && attachmentGeneration == pending.token && pendingAttachment == nil
    }

    private func installDatabase(_ database: IndexDatabase) -> Bool {
        guard !terminating else { return false }
        guard self.database !== database else { return true }
        ModelPublicationBatch.perform {
            // A first installation must retain the saved session for startup restoration.
            if self.database != nil {
                _ = prepareForIndexReset(clearSidebarFailure: true)
            } else { resetSidebarSummaryRecovery(clearFailure: true) }
            resetUsageRefreshWork()
            rollupFailure = nil
            if pendingRootSummaryRefresh?.database !== database { pendingRootSummaryRefresh = nil }
            startupUsageRepairEnrolled = false
            #if DEBUG
            usageDatabaseGeneration = UUID()
            #endif
            costsFailures = [:]
            summaryReadFailures = [:]
            highestObservedTranscriptReadRevision = 0
            lastAppliedTranscriptReadRevision = 0
            knownSelectionProject = nil
            sidebarDataGeneration = UUID()
            missingSelectionAttempt = nil
            self.database = database
        }
        return !terminating && self.database === database
    }

    private func receiveAdmittedProgress(_ update: IndexProgress) async {
        let attachment = attachmentGeneration, configuration = sourceConfigurationRevision
        let workflow = indexWorkflow.generation
        let disposition = indexWorkflow.receive(update)
        let receivedWorkflow = indexWorkflow.generation
        func isCurrent() -> Bool {
            !terminating && attachment == attachmentGeneration && configuration == sourceConfigurationRevision
                && receivedWorkflow == indexWorkflow.generation
        }
        var mutationAdvanced = false
        ModelPublicationBatch.perform {
            mutationAdvanced = recordSearchMutation(update)
            retireRebuildAdmission()
            if workflow != indexWorkflow.generation { invalidateTranscriptSettlement() }
            if !disposition.passTerminal { resumePausedTranscriptFeedback() }
            if !disposition.passTerminal { invalidateUsageSnapshot() }
            if disposition.passTerminal {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_INDEX_PASS_COMPLETED_PATH")
                TraceTestHooks.appendLine(
                    update.activity.rawValue,
                    pathKey: "TRACE_TEST_INDEX_ACTIVITY_AUDIT_PATH"
                )
            }
            if update.incremental {
                if disposition.passTerminal {
                    incrementalProgressTask?.cancel()
                    incrementalProgressTask = nil
                    pendingIncrementalProgress = nil
                    if !disposition.supersededTerminal,
                       IndexProgress.shouldPublishIncrementalTerminal(
                        update, after: progress, wasVisible: incrementalProgressVisible
                       ) {
                        publishProgress(update)
                    }
                    incrementalProgressVisible = false
                } else {
                    pendingIncrementalProgress = update
                    if incrementalProgressTask == nil {
                        let clock = clock
                        incrementalProgressTask = Task { [weak self] in
                            do { try await clock.sleep(for: .milliseconds(300)) }
                            catch { return }
                            guard let self, !Task.isCancelled, let pending = self.pendingIncrementalProgress else { return }
                            self.publishProgress(pending)
                            guard !Task.isCancelled else { return }
                            self.incrementalProgressVisible = true
                            self.incrementalProgressTask = nil
                        }
                    }
                }
            } else if !disposition.supersededTerminal {
                publishProgress(update)
            }
        }

        guard isCurrent() else { return }
        let usageEvent = disposition.workflowTerminal ? newUsageRecoveryEvent() : nil
        if disposition.passTerminal {
            handleTerminalUsageProgress(update, event: usageEvent)
        }
        else { reconcileUsageWork() }
        guard isCurrent() else { return }
        observeSearchMutation(update, terminal: disposition.workflowTerminal, mutationAdvanced: mutationAdvanced)

        let shouldRefresh = disposition.passTerminal
            || ((!update.incremental || incrementalProgressVisible)
                && lastSummaryRefresh.duration(to: clock.now) >= .milliseconds(250))
        if shouldRefresh {
            guard isCurrent() else { return }
            lastSummaryRefresh = clock.now
            if let usageEvent {
                await refreshTerminalSummaries(disposition.projectReconciliation, usageEvent: usageEvent)?.value
            } else {
                await reloadSummaries(lightweight: true, projectReconciliation: disposition.projectReconciliation)
            }
        }
    }

    private func publishProgress(_ update: IndexProgress) {
        let generation = attachmentGeneration
        let activation = sourceReloadActivation
        if update.phase == .complete, update.error == nil { summaryReadFailures[.indexStatus] = nil }
        progress = update
        guard !terminating, generation == attachmentGeneration else { return }
        guard let activation, activation == sourceReloadActivation,
              watcherOwnerIsCurrent(activation), let startup = watcherStartup,
              startup.owner == activation, startup.ready, watcherStartupIsCurrent(startup) else { return }
        sourceReloadActivation = nil
        if sourceReloadRecovery.isRetrying { sourceReloadRecovery = .normal }
    }

    private func handleTerminalUsageProgress(_ update: IndexProgress, event: UInt64?) {
        let database = database
        let workflow = indexWorkflow.generation
        func isCurrent() -> Bool {
            !terminating && self.database === database && workflow == indexWorkflow.generation
        }
        if update.rollupError != nil || update.indexChanged || update.rollupsChanged {
            let repair = usageWork.repair || update.rollupError != nil
                || (update.phase != .complete && (update.indexChanged || update.rollupsChanged))
            registerUsageDemand(repair: repair, urgency: .automatic)
        }
        if update.rollupError != nil {
            costsError = "Could not update token totals."
            guard isCurrent() else { return }
        }
        reconcileUsageWork(event: event, urgency: .automatic)
    }

    private func recordSearchMutation(_ update: IndexProgress) -> Bool {
        if lastObservedPassID != update.passID {
            lastObservedPassID = update.passID
            lastObservedMutationRevision = 0
        }
        if update.mutationRevision > lastObservedMutationRevision {
            sidebarDataGeneration = UUID()
            lastObservedMutationRevision = update.mutationRevision
            if !globalSearch.query.isEmpty {
                if globalSearch.protectsPagination { globalSearch.markResultsStale() }
                else { globalSearchNeedsRefresh = true }
            }
            if !mainSearch.query.isEmpty {
                if hasSearchReturnContext { mainSearch.markResultsStale() }
                else if mainSearch.protectsPagination { mainSearch.markResultsStale() }
                else { mainSearchNeedsRefresh = true }
            }
            return true
        }
        return false
    }

    private func observeSearchMutation(_ update: IndexProgress, terminal: Bool, mutationAdvanced: Bool) {
        if mutationAdvanced { scheduleAutomaticSearch() }
        if terminal && update.indexChanged
            && (lastSearchedPassID != update.passID
                || lastSearchedMutationRevision < update.mutationRevision) {
            cancelAutomaticSearch()
            performAutomaticSearch()
        }
    }

    private var mainSearchIsVisible: Bool {
        mainWindowVisible && mainSearchPanelVisible && selectedSessionID == nil
    }

    private var hasVisibleAutomaticSearch: Bool {
        (globalSearchNeedsRefresh && !globalSearchSurfaces.isEmpty
            && !globalSearch.query.isEmpty && !globalSearch.protectsPagination
            && !globalSearch.isResolvingProjectFilter)
        || (mainSearchNeedsRefresh && mainSearchIsVisible
            && !mainSearch.query.isEmpty && !mainSearch.protectsPagination
            && !mainSearch.isResolvingProjectFilter)
    }

    func setGlobalSearchSurface(_ surface: GlobalSearchSurface, visible: Bool) {
        guard globalSearchSurfaces.contains(surface) != visible else { return }
        if visible { globalSearchSurfaces.insert(surface) }
        else { globalSearchSurfaces.remove(surface) }
        if !visible && globalSearchSurfaces.isEmpty {
            var changed = false
            if settings.clearGlobalSearchOnClose && !globalSearch.query.isEmpty {
                globalSearch.query = ""
                changed = true
            }
            if settings.clearGlobalFiltersOnClose {
                changed = changed || globalSearch.hasActiveFilters
                globalSearch.clearFilters()
            }
            if changed {
                globalSearch.search(sort: settings.searchSort)
                globalSearchNeedsRefresh = false
            }
        }
        searchVisibilityChanged()
    }

    func clearGlobalSearchFilters() {
        guard globalSearch.hasActiveFilters else { return }
        globalSearch.clearFilters()
        globalSearchNeedsRefresh = false
        globalSearch.search(sort: settings.searchSort)
    }

    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        searchVisibilityChanged()
    }

    func setMainSearchPanelVisible(_ visible: Bool) {
        mainSearchPanelVisible = visible
        searchVisibilityChanged()
    }

    private func searchVisibilityChanged() {
        searchVisibilityTask?.cancel()
        searchVisibilityTask = nil
        if !hasVisibleAutomaticSearch {
            cancelAutomaticSearch()
            return
        }
        let clock = clock
        searchVisibilityTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(for: .milliseconds(20)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.searchVisibilityTask = nil
            self.scheduleAutomaticSearch()
        }
    }

    private func cancelAutomaticSearch() {
        automaticSearchTaskID = nil
        automaticSearchTask?.cancel()
        automaticSearchTask = nil
    }

    private func scheduleAutomaticSearch() {
        guard hasVisibleAutomaticSearch else { return }
        guard automaticSearchTask == nil else { return }
        let elapsed = lastAutomaticSearchRefresh?.duration(to: clock.now) ?? .seconds(1)
        if elapsed >= .seconds(1) { performAutomaticSearch(); return }
        let id = UUID()
        automaticSearchTaskID = id
        let clock = clock
        automaticSearchTask = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(1) - elapsed) }
            catch { return }
            guard let self, !Task.isCancelled, self.automaticSearchTaskID == id else { return }
            self.automaticSearchTaskID = nil
            self.automaticSearchTask = nil
            self.performAutomaticSearch()
        }
    }

    private func performAutomaticSearch() {
        guard hasVisibleAutomaticSearch else { return }
        lastAutomaticSearchRefresh = clock.now
        lastSearchedPassID = lastObservedPassID
        lastSearchedMutationRevision = lastObservedMutationRevision
        if globalSearchNeedsRefresh, !globalSearchSurfaces.isEmpty,
           !globalSearch.query.isEmpty, !globalSearch.protectsPagination,
           !globalSearch.isResolvingProjectFilter {
            globalSearchNeedsRefresh = false
            globalSearch.search(sort: settings.searchSort, trigger: .automatic)
        }
        if mainSearchNeedsRefresh, mainSearchIsVisible,
           !mainSearch.query.isEmpty, !mainSearch.protectsPagination,
           !mainSearch.isResolvingProjectFilter {
            mainSearchNeedsRefresh = false
            syncMainSearchProjectFilter()
            mainSearch.search(sort: settings.searchSort, trigger: .automatic)
        }
    }

    func startIndexing(sources: [any SessionSource], configurationRevision: UInt64? = nil) {
        let revision = configurationRevision ?? sourceConfigurationRevision
        guard revision == sourceConfigurationRevision, settings.onboardingComplete,
              !initialIndexRequested, let scheduler else { return }
        let generation = watcherGeneration
        let attachment = attachmentGeneration
        initialIndexRequested = true
        Task { [weak self] in
            guard let self, !Task.isCancelled, revision == self.sourceConfigurationRevision,
                  generation == self.watcherGeneration, attachment == self.attachmentGeneration else { return }
            let buffered = self.bufferedSourceChanges
            self.bufferedSourceChanges = SourceChanges()
            let recovery = self.pendingStartupRecovery
            let recoveryActivity = recovery.isEmpty ? nil : Self.recoveryActivity(
                for: recovery, sources: sources
            )
            self.pendingStartupRecovery = .init()
            let baseActivity = self.startupReconciliationPaths.isEmpty
                ? (buffered.paths.isEmpty && buffered.reconciliationPaths.isEmpty
                    ? self.startupActivity : self.activity(for: buffered))
                : self.startupActivity
            let activity = recoveryActivity.map {
                IndexActivity.moreSignificant(baseActivity, $0)
            } ?? baseActivity
            let satisfiesSafetyReconciliation = baseActivity.satisfiesSafetyReconciliation
                || (recoveryActivity?.satisfiesSafetyReconciliation ?? false)
            let rebuild = self.takePendingRebuild(generation: attachment, revision: revision)
            let requestedActivity: IndexActivity = rebuild != nil ? .rebuild : activity
            #if DEBUG
            self.startupSubmissionCountForTesting += 1
            #endif
            self.startupActivityObserver(requestedActivity)
            #if DEBUG
            if let rebuild, let gate = rebuild.submissionGate {
                rebuild.waitingForSubmission = true
                await gate.value
                rebuild.waitingForSubmission = false
                guard self.rebuildAdmissionIsCurrent(rebuild) else { return }
            }
            #endif
            await scheduler.request(
                paths: buffered.paths.union(recovery.filePaths),
                reconciliationPaths: self.startupReconciliationPaths
                    .union(buffered.reconciliationPaths)
                    .union(recovery.reconciliationPaths),
                rebuild: rebuild != nil,
                scope: self.settings.indexScope,
                activity: requestedActivity,
                satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
                watermarks: buffered.watermarks,
                streamRoots: buffered.streamRoots
            )
            if let rebuild, self.rebuildAdmissionIsCurrent(rebuild) { rebuild.release() }
            guard !Task.isCancelled, revision == self.sourceConfigurationRevision,
                  generation == self.watcherGeneration else { return }
            self.watcherStartupPending = false
            let arrivedDuringSubmission = self.bufferedSourceChanges
            self.bufferedSourceChanges = SourceChanges()
            if !arrivedDuringSubmission.paths.isEmpty
                || arrivedDuringSubmission.requiresReconciliation
                || !arrivedDuringSubmission.watermarks.isEmpty {
                await self.submitSourceChanges(arrivedDuringSubmission)
            }
            guard !Task.isCancelled, revision == self.sourceConfigurationRevision,
                  generation == self.watcherGeneration else { return }
            self.startSafetyVerificationLoop()
        }
    }

    func rebuildIndex() {
        // Startup's first pass already uses the latest scope. Do not reset its
        // saved navigation before the first coordinator is installed.
        guard !terminating, settings.onboardingComplete, coordinator != nil else { return }
        pendingRebuild = true
        if pendingAttachment != nil {
            beginIndexReplacement()
            return
        }
        guard let scheduler else {
            // A manual rebuild also retries a failed source configuration.
            reloadSourcesAndRebuild()
            return
        }
        guard let receipt = beginIndexReplacement(preparingRebuild: true) else { return }
        Task {
            guard rebuildAdmissionIsCurrent(receipt),
                  takePendingRebuild(generation: receipt.attachment, revision: receipt.configuration) === receipt else { return }
            await submitRebuild(receipt, scheduler: scheduler)
        }
    }

    /// Consume at handoff, before reset or suspension. Progress cannot acknowledge
    /// an outstanding request because another submission may already be queued.
    private func takePendingRebuild(generation: UUID, revision: UInt64) -> RebuildAdmission? {
        guard !terminating, pendingAttachment == nil, pendingRebuild,
              generation == attachmentGeneration, revision == sourceConfigurationRevision else { return nil }
        var receipt: RebuildAdmission?
        ModelPublicationBatch.perform {
            receipt = admitRebuild()
            pendingRebuild = false
            _ = prepareForIndexReset()
        }
        guard let receipt else { return nil }
        let workflow = receipt.workflow
        // Navigation during reset owns its newer transcript. The global rebuild
        // still runs unless its attachment/configuration/workflow was replaced.
        guard !terminating, generation == attachmentGeneration, revision == sourceConfigurationRevision,
              workflow == indexWorkflow.generation, rebuildAdmission === receipt else {
            retireRebuildAdmission(receipt)
            return nil
        }
        #if DEBUG
        rebuildSubmissionCountForTesting += 1
        #endif
        return receipt
    }

    private func settleDeferredSourceReload(receipt: WatcherReceipt) {
        guard watcherDeferralIsCurrent(receipt) else { return }
        // A deliberately deferred startup cannot erase an independently running pass.
        if indexWorkflow.activePassID == nil {
            indexWorkflow = .init()
            let counts = (progress.unresolvedFailedFiles, progress.unresolvedDiscoveryFailures)
            progress = .init(phase: .waiting)
            progress.unresolvedFailedFiles = counts.0
            progress.unresolvedDiscoveryFailures = counts.1
        }
        // Keep the root scan requirement until onboarding eventually submits it.
        retireRebuildAdmission()
        sourceReloadRecovery = .normal
        reconcileUsageWork()
        settleTranscriptFeedback()
    }

    func retrySourceConfiguration() {
        guard !terminating, settings.onboardingComplete, pendingAttachment == nil,
              case .failed(let error) = sourceReloadRecovery else { return }
        sourceReloadRecovery = .retrying(error)
        reloadSourcesAndRebuild()
    }

    private func synchronizeConfiguredRoots(_ roots: [SourceRoot], database: IndexDatabase,
                                            configuration: UInt64) async throws -> Bool {
        let previous = rootSynchronizationTask
        let id = UUID()
        let task = Task { @MainActor [weak self] () throws -> Bool in
            _ = try? await previous?.value
            guard let self, !terminating, !Task.isCancelled,
                  sourceConfigurationRevision == configuration,
                  self.database === database || pendingAttachment?.database === database else { return false }
            let changed = try await database.synchronizeConfiguredRoots(roots)
            #if DEBUG
            if let gate = rootSynchronizationBookkeepingGateForTesting {
                rootSynchronizationBookkeepingWaitingForTesting = true
                await gate.value
                rootSynchronizationBookkeepingWaitingForTesting = false
            }
            #endif
            // The write can finish after its caller loses ownership. Register the
            // debt before a successor is allowed to observe unchanged roots.
            if changed, !terminating,
               self.database === database || pendingAttachment?.database === database {
                if self.database === database { sidebarDataGeneration = UUID() }
                let refresh = RootSummaryRefresh(database: database)
                if self.database === database {
                    pendingRootSummaryRefresh = refresh
                    completedUsageRevision += 1
                    registerUsageDemand(repair: true, urgency: .immediate)
                } else {
                    pendingAttachment?.rootRefresh = refresh
                }
            }
            return changed
        }
        rootSynchronizationTask = task
        rootSynchronizationID = id
        defer {
            if rootSynchronizationID == id {
                rootSynchronizationTask = nil
                rootSynchronizationID = nil
            }
        }
        return try await task.value
    }

    private func acknowledgeRootSummary(_ receipt: RootSummaryRefresh?, projects: Bool = false, sessions: Bool = false,
                                        statistics: Bool = false, usage: Bool = false) {
        guard let receipt, pendingRootSummaryRefresh?.id == receipt.id else { return }
        if projects { pendingRootSummaryRefresh?.projects = false }
        if sessions { pendingRootSummaryRefresh?.sessions = false }
        if statistics { pendingRootSummaryRefresh?.statistics = false }
        if usage { pendingRootSummaryRefresh?.usage = false }
        if pendingRootSummaryRefresh?.projects == false, pendingRootSummaryRefresh?.sessions == false,
           pendingRootSummaryRefresh?.statistics == false,
           pendingRootSummaryRefresh?.usage == false {
            pendingRootSummaryRefresh = nil
        }
    }

    func reloadSourcesAndRebuild() {
        guard !terminating else { return }
        sourceConfigurationRevision &+= 1
        let revision = sourceConfigurationRevision
        // During initial setup the startup loop owns source configuration.
        guard coordinator != nil || pendingAttachment != nil,
              let database = pendingAttachment?.database ?? database else { return }
        sourceChangeTask?.cancel()
        beginIndexReplacement()
        let pending = beginAttachment(database: database, intent: .sourceReload)
        guard pendingAttachmentIsCurrent(pending) else { return }
        sourceChangeTask = Task {
            guard await waitForAttachmentRetirement(pending) else { return }
            if let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_SOURCE_RELOAD_PREPARATION_HOLD_MS", cappedAt: 30_000,
                marker: .touch(pathKey: "TRACE_TEST_SOURCE_RELOAD_PREPARATION_ENTERED_PATH")
            ) {
                try? await TraceTestHooks.waitForRelease(
                    pathKey: "TRACE_TEST_SOURCE_RELOAD_PREPARATION_RELEASE_PATH", timeoutMilliseconds: delay)
            }
            guard !Task.isCancelled, pendingAttachmentIsCurrent(pending) else { return }
            let sources = await makeSources()
            guard !Task.isCancelled, pendingAttachmentIsCurrent(pending) else { return }
            do {
                if TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_SOURCE_RELOAD_ONCE") {
                    throw SessionSourceError.unreadableFile("Synthetic source configuration failure")
                }
                #if DEBUG
                if failSourceConfigurationForTesting {
                    throw SessionSourceError.unreadableFile("Synthetic source configuration failure")
                }
                #endif
                let roots = sources.flatMap(\.roots)
                _ = try await synchronizeConfiguredRoots(roots, database: database, configuration: revision)
                #if DEBUG
                if let gate = configuredRootsPublicationGateForTesting {
                    configuredRootsPublicationWaitingForTesting = true
                    await gate.value
                    configuredRootsPublicationWaitingForTesting = false
                }
                #endif
                guard !Task.isCancelled, pendingAttachmentIsCurrent(pending) else { return }
                if self.database === database {
                    let configured = Set(roots.map { ConfiguredRootIdentity(agent: $0.agent, path: $0.url.path) })
                    let retained = sourceHealth.filter { configured.contains(.init(agent: $0.agent, path: $0.rootPath)) }
                    if retained.count != sourceHealth.count { sourceHealth = retained }
                }
                guard !Task.isCancelled, pendingAttachmentIsCurrent(pending) else { return }
                if pendingRootSummaryRefresh?.database === database,
                   pendingRootSummaryRefresh?.metadataPending == true, self.database === database {
                    await reloadSummaries(
                        loadCosts: false, projectReconciliation: .completed
                    )
                }
            } catch {
                failAttachment(pending, error: indexErrorMessage(error, sourceReload: true,
                                                                prefix: "Could not update source folders: "))
                return
            }
            guard !Task.isCancelled, pendingAttachmentIsCurrent(pending) else { return }
            let coordinator = IndexCoordinator(database: database, sources: sources, clock: clock)
            #if DEBUG
            if let gate = sourceChangeAttachmentGateForTesting {
                sourceChangeAttachmentWaitingForTesting = true
                await gate.value
                sourceChangeAttachmentWaitingForTesting = false
            }
            #endif
            guard await finishAttachment(pending, coordinator: coordinator) else { return }
            initialIndexRequested = false
            startupSetupComplete = true
            switch await startWatching(sources, forceRootReconciliation: true) {
            case .deferredByOnboarding(let owner):
                settleDeferredSourceReload(receipt: owner)
                guard watcherDeferralIsCurrent(owner) else { return }
                #if DEBUG
                TraceTestHooks.touch(pathKey: "TRACE_TEST_SOURCE_RELOAD_DEFERRED_PATH")
                #endif
                return
            case .superseded:
                return
            case .started(let owner):
                guard watcherReadyIsCurrent(owner) else { return }
            }
            guard !Task.isCancelled, revision == sourceConfigurationRevision else { return }
            // Root changes reconcile existing files; unchanged sources retain their index.
            startIndexing(sources: sources, configurationRevision: revision)
        }
    }

    func search(reset: Bool = true) {
        if reset { globalSearchNeedsRefresh = false }
        globalSearch.search(sort: settings.searchSort, reset: reset)
    }

    // Only explicit UI intent ends launch restoration. Background search and
    // reconciliation may use the same search methods without taking navigation.
    func cancelLaunchRestorationForUserIntent() {
        mayRestoreSession = false
    }
    func searchMain() {
        guard !hasSearchReturnContext else { mainSearch.markResultsStale(); return }
        mainSearchNeedsRefresh = false
        syncMainSearchProjectFilter()
        mainSearch.search(sort: settings.searchSort)
    }

    private func deferMainSearchForSessionNavigation() {
        mainSearch.suspendForNavigation()
        syncMainSearchProjectFilter()
        mainSearch.markResultsStale()
        mainSearchNeedsRefresh = true
    }

    private func syncMainSearchProjectFilter() {
        guard !hasSearchReturnContext else { return }
        mainSearch.setProjectFilter(
            canonicalKey: selectedProjectCanonicalKey,
            displayName: selectedProjectDisplayName
        )
    }
    var filteredProjects: [ProjectSummary] {
        if TraceTestHooks.isUITesting, let reveal = sidebarRevealRequest,
           let gate = TraceTestHooks.environment["TRACE_TEST_PROJECT_AVAILABILITY_RELEASE_PATH"],
           !FileManager.default.fileExists(atPath: gate) {
            return projects.filter { $0.canonicalKey != reveal.projectCanonicalKey }
        }
        let query = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? projects : projects.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }
    var sidebarSelectedProjectID: Int64? {
        guard let selectedProjectID, let selectedProjectCanonicalKey,
              projects.contains(where: {
                  $0.id == selectedProjectID && $0.canonicalKey == selectedProjectCanonicalKey
              }) else { return nil }
        return selectedProjectID
    }

    func sessionErrorText(_ session: SessionSummary) async -> String {
        if TraceRuntime.testDirectory != nil,
           let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_ERROR_LOAD_DELAY_MS", cappedAt: 5_000
           ) {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        guard let coordinator else {
            return "Error details are unavailable while the index is starting."
        }
        do {
            let failures = try await coordinator.failures(for: session)
            try Task.checkCancellation()
            return failures.isEmpty
                ? "\(session.agent.displayName) recorded an error without a detailed explanation."
                : failures.map { failure in
                    let header = [session.agent.displayName, failure.kind.capitalized,
                        failure.timestampMilliseconds.traceDate, failure.toolName].compactMap { $0 }.joined(separator: " · ")
                    return header + "\n" + (failure.detail.isEmpty
                        ? "The source did not provide an error message."
                        : String(failure.detail.prefix(4_000)))
                }.joined(separator: "\n\n")
        } catch is CancellationError {
            return "Loading error details was cancelled."
        } catch {
            return "Could not read error details from \(session.sourcePath): \(error.localizedDescription)"
        }
    }

    var detailTitle: String {
        if let selectedSession, selectedSession.id == selectedSessionID { return selectedSession.title }
        return selectedProjectDisplayName ?? "Trace"
    }

    func returnFromSession() {
        let context = mainSearchReturnContext
        let anchor = mainSearchReturnAnchor
        guard clearSession() else { return }
        if let context {
            mainSearchReturnAnchor = anchor
            let project = projects.first { $0.canonicalKey == context.canonicalKey }
            selectedProjectID = project?.id ?? context.projectID
            selectedProjectCanonicalKey = context.canonicalKey
            selectedProjectDisplayName = project?.displayName ?? context.displayName
            if mainSearchNeedsRefresh { mainSearch.markResultsStale() }
            mainSearchNeedsRefresh = false
            loadProjectSessions()
        } else if mainSearchNeedsRefresh {
            if mainSearch.protectsPagination,
               mainSearch.matchesCurrentCriteria(sort: settings.searchSort) {
                mainSearch.markResultsStale()
                mainSearchNeedsRefresh = false
            } else { searchMain() }
        }
    }

    @discardableResult
    func clearSession() -> Bool {
        let request = UUID(), ownerDatabase = database
        sessionRequestID = request
        func isCurrent() -> Bool { !terminating && database === ownerDatabase && sessionRequestID == request }
        knownSelectionProject = nil
        invalidateTranscriptSettlement()
        pausedTranscriptPreservation = nil
        pendingSelectionCompletion = nil
        mainSearchReturnContext = nil
        mainSearchReturnAnchor = nil
        mayRestoreSession = false
        cancelTranscriptRecovery(clearPresentation: false)
        cancelPendingSelectionTranscriptRead()
        settings.lastSessionID = nil
        requestedMessageID = nil
        resetTranscriptValues()
        guard isCurrent() else { return false }
        hasSearchReturnContext = false
        guard isCurrent() else { return false }
        invalidateSidebarRevealRequest()
        return isCurrent()
    }

    func consumeRequestedMessageID(_ messageID: Int64) {
        if requestedMessageID == messageID { requestedMessageID = nil }
    }

    @discardableResult
    private func prepareForIndexReset(clearSidebarFailure: Bool = false) -> Bool {
        guard !terminating else { return false }
        let ownerDatabase = database, attachment = attachmentGeneration
        let configuration = sourceConfigurationRevision, workflow = indexWorkflow.generation
        ModelPublicationBatch.perform {
            sessionRequestID = UUID()
            projectRequestID = UUID()
            summaryRequestID = UUID()
            let context = mainSearchReturnContext
            sidebarDataGeneration = UUID()
            missingSelectionAttempt = nil
            knownSelectionProject = nil
            invalidateTranscriptSettlement()
            invalidateTerminalSummaryRefresh()
            pausedTranscriptPreservation = nil
            pendingSelectionCompletion = nil
            mainSearchReturnContext = nil
            mainSearchReturnAnchor = nil
            cancelAutomaticSearch()
            retireUsageRefreshWorker()
            completedUsageRevision += 1
            invalidateUsageSnapshot()
            globalSearchNeedsRefresh = false
            mainSearchNeedsRefresh = false
            lastObservedPassID = nil
            lastSearchedPassID = nil
            lastObservedMutationRevision = 0
            lastSearchedMutationRevision = 0
            mayRestoreSession = false
            cancelTranscriptRecovery(clearPresentation: false)
            cancelPendingSelectionTranscriptRead()
            settings.lastSessionID = nil
            scrollPositions = [:]
            requestedMessageID = nil
            resetTranscriptValues()
            if let context {
                selectedProjectCanonicalKey = context.canonicalKey
                selectedProjectDisplayName = context.displayName
            }
            hasSearchReturnContext = false
            resetSessionPagination()
            resetSidebarSummaryRecovery(clearFailure: clearSidebarFailure)
            updateCostsTotalsUpdating()
            selectedProjectID = nil
            invalidateSidebarRevealRequest()
            projects = []
            recentSessions = []
            sourceHealth = []
            statistics = nil
            globalSearch.resetForIndexReset(awaitsProjectResolution: true)
            mainSearch.resetForIndexReset(awaitsProjectResolution: true)
        }
        return !terminating && database === ownerDatabase && attachmentGeneration == attachment
            && sourceConfigurationRevision == configuration && indexWorkflow.generation == workflow
    }

    @discardableResult
    private func beginIndexReplacement(preparingRebuild: Bool = false) -> RebuildAdmission? {
        ModelPublicationBatch.perform {
            retireRebuildAdmission()
            invalidateTranscriptSettlement()
            indexWorkflow.beginReplacement()
            incrementalProgressTask?.cancel()
            incrementalProgressTask = nil
            pendingIncrementalProgress = nil
            incrementalProgressVisible = false
            let receipt = preparingRebuild ? admitRebuild() : nil
            resetSidebarSummaryRecovery(clearFailure: false)
            resumePausedTranscriptFeedback()
            invalidateUsageSnapshot()
            reconcileUsageWork()
            return receipt
        }
    }

    func selectProject(_ projectID: Int64?) {
        if let projectID {
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            guard selectedProjectID != project.id
                    || selectedProjectCanonicalKey != project.canonicalKey else { return }
            guard clearSession() else { return }
            selectedProjectID = project.id
            selectedProjectCanonicalKey = project.canonicalKey
            selectedProjectDisplayName = project.displayName
            searchMain()
            loadProjectSessions()
            return
        }
        // SwiftUI writes nil when a selected row temporarily disappears. Treat nil as
        // deliberate only while the selected row is still visible.
        guard let selectedProjectID, let selectedCanonicalKey = selectedProjectCanonicalKey,
              filteredProjects.contains(where: {
                  $0.id == selectedProjectID
                      && $0.canonicalKey == selectedCanonicalKey
              }) else { return }
        guard clearSession() else { return }
        self.selectedProjectID = nil
        selectedProjectCanonicalKey = nil
        selectedProjectDisplayName = nil
        searchMain()
        loadProjectSessions()
    }

    private var currentSidebarSummaryFailure: SidebarSummaryFailure? {
        guard let failure = sidebarSummaryFailure, database === failure.database else { return nil }
        return failure
    }

    private func sidebarRecoveryReconciliation() -> ProjectReconciliationMode {
        indexWorkflow.isActive ? .ongoing : savedSidebarReconciliation() ?? .terminalRetaining
    }

    private func savedSidebarReconciliation() -> ProjectReconciliationMode? {
        guard !indexWorkflow.isActive else { return nil }
        if let failure = currentSidebarSummaryFailure,
           failure.workflow == indexWorkflow.generation,
           failure.configuration == sourceConfigurationRevision,
           failure.reconciliation != .ongoing { return failure.reconciliation }
        return nil
    }

    private func clearSidebarSummaryFailure() {
        sidebarSummaryFailure = nil
        summaryReadFailures[.sidebar] = nil
        if sidebarSummaryError != nil { sidebarSummaryError = nil }
    }

    private func resetSidebarSummaryRecovery(clearFailure: Bool) {
        sidebarSummaryRetryTask?.cancel()
        sidebarSummaryRetryTask = nil
        sidebarSummaryRetryOwner = nil
        pendingSidebarSummaryRetry = false
        if isRetryingSidebarSummary { isRetryingSidebarSummary = false }
        if clearFailure { clearSidebarSummaryFailure() }
    }

    func retrySidebarSummary() {
        guard !terminating, let database, currentSidebarSummaryFailure != nil else { return }
        if let owner = sidebarSummaryRetryOwner, summaryRefreshIsCurrent(owner) { return }
        if backgroundSidebarRequest != nil || isLoadingSessions {
            pendingSidebarSummaryRetry = true
            isRetryingSidebarSummary = true
            return
        }
        let owner = SummaryRefreshOwner(database: database, attachment: attachmentGeneration,
                                        configuration: sourceConfigurationRevision)
        summaryRequestID = owner.id
        sidebarSummaryRetryTask?.cancel()
        sidebarSummaryRetryOwner = owner
        let usageEvent = newUsageRecoveryEvent()
        sidebarSummaryRetryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if sidebarSummaryRetryOwner?.id == owner.id {
                    sidebarSummaryRetryOwner = nil
                    sidebarSummaryRetryTask = nil
                    isRetryingSidebarSummary = pendingSidebarSummaryRetry
                }
            }
            guard !Task.isCancelled, summaryRefreshIsCurrent(owner) else { return }
            await reloadSummaries(projectReconciliation: sidebarRecoveryReconciliation(), owner: owner, usageEvent: usageEvent)
        }
        isRetryingSidebarSummary = true
    }

    private func loadProjectSessions(ensuring ensuringSessionID: Int64? = nil, requestedPageCount: Int? = nil) {
        if sessionListProjectKey != selectedProjectCanonicalKey { resetSessionPagination() }
        let request = UUID()
        projectRequestID = request
        sessionListTask?.cancel()
        let key = selectedProjectCanonicalKey
        let pageCount = max(requestedPageCount ?? loadedSessionPageCount, pageState.read(\.requestedDepth))
        guard let database else { isLoadingSessions = false; sessionListTask = nil; return }
        let configuration = sourceConfigurationRevision
        let rootReceipt = rootReceipt(for: database)
        let dataGeneration = sidebarDataGeneration
        func isCurrent() -> Bool {
            !terminating && !Task.isCancelled && self.database === database
                && sourceConfigurationRevision == configuration
                && projectRequestID == request && selectedProjectCanonicalKey == key
        }
        sessionListTask = Task {
            defer {
                finishSessionListRequest(request, database: database, project: key,
                                         configuration: configuration, pageCount: pageCount)
            }
            do {
                #if DEBUG
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_PROJECT_PAGE_HOLD_MS", cappedAt: 30_000,
                    marker: .touch(pathKey: "TRACE_TEST_PROJECT_PAGE_STARTED_PATH")) {
                    try await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_PROJECT_PAGE_RELEASE_PATH",
                                                          timeoutMilliseconds: delay)
                }
                try checkSessionReadFailureForUITesting(pagination: false)
                #endif
                let page = try await database.sessionListSnapshot(
                    projectCanonicalKey: key, pageCount: pageCount, ensuringSessionID: ensuringSessionID)
                guard isCurrent() else { return }
                acceptSessionPages(page, attempted: ensuringSessionID, depth: pageCount,
                                   rootReceipt: rootReceipt, dataGeneration: dataGeneration, isCurrent: isCurrent)
            } catch is CancellationError { }
            catch {
                guard isCurrent() else { return }
                recordSummaryReadFailure(error, operation: .sessionList)
                guard isCurrent() else { return }
                updateSessionPage {
                    $0.error = "Could not load sessions. Try again."
                    $0.retry = .reload(pageCount: pageCount)
                }
            }
        }
        updateSessionPage {
            $0.projectKey = key
            $0.requestedDepth = pageCount
            $0.isLoading = true
            $0.error = nil
            $0.retry = nil
        }
    }

    private func finishSessionListRequest(_ request: UUID, database: IndexDatabase,
                                          project: String?, configuration: UInt64, pageCount: Int) {
        guard projectRequestID == request else { return }
        sessionListTask = nil
        if !terminating, !Task.isCancelled, self.database === database,
           selectedProjectCanonicalKey == project, sourceConfigurationRevision != configuration {
            loadProjectSessions(ensuring: selectedSessionID, requestedPageCount: pageCount)
            return
        }
        isLoadingSessions = false
        guard projectRequestID == request else { return }
        drainPendingSidebarAction()
    }

    private func finishBackgroundSidebarRequest(_ request: UUID) {
        guard backgroundSidebarRequest == request else { return }
        backgroundSidebarRequest = nil
        drainPendingSidebarAction()
    }

    private func drainPendingSidebarAction() {
        guard backgroundSidebarRequest == nil, !isLoadingSessions else { return }
        if pendingSidebarSummaryRetry {
            pendingSidebarSummaryRetry = false
            if currentSidebarSummaryFailure != nil { retrySidebarSummary() }
            else if sidebarSummaryRetryOwner == nil { isRetryingSidebarSummary = false }
        }
        guard let pending = pendingSidebarAction else { return }
        pendingSidebarAction = nil
        guard pending.project == selectedProjectCanonicalKey else { return }
        switch pending.action {
        case .loadMore: loadMoreSessions()
        case .retry(.reload(let pageCount)):
            // A successful background read satisfies the Retry only when it
            // accepted the requested depth, including a reissued extra page.
            if let retry = sessionListRetry { performSidebarRetry(retry) }
            else if !pageCoverageSatisfies(pageCount) {
                loadProjectSessions(ensuring: selectedSessionID, requestedPageCount: pageCount)
            }
        case .retry(.nextPage(let pageCount)):
            if let retry = sessionListRetry { performSidebarRetry(retry) }
            else if !pageCoverageSatisfies(pageCount) { loadMoreSessions() }
        }
    }

    private func resetSessionPagination() {
        projectRequestID = UUID()
        backgroundSidebarRequest = nil
        pendingSidebarAction = nil
        sessionListTask?.cancel()
        sessionListTask = nil
        updateSessionPage {
            $0 = .init()
            $0.projectKey = selectedProjectCanonicalKey
        }
    }

    private func pageCoverageSatisfies(_ requestedDepth: Int) -> Bool {
        loadedSessionPageCount >= requestedDepth || !hasMoreSessions
    }

    /// A selection made while the read or its synchronous publications were in
    /// flight gets one replacement attempt. Missing ensured IDs cannot loop.
    private func replacePageForLatestSelection(_ page: LoadedSessionPages, attempted: Int64?, depth: Int,
                                              isCurrent: () -> Bool) -> Bool {
        guard isCurrent(), let selectedSessionID, selectedSessionID != attempted,
              !alreadyEnsuredMissingSelection(selectedSessionID),
              !page.sessions.contains(where: { $0.id == selectedSessionID }) else { return false }
        // An unresolved selection may still belong to another project. Its
        // existing transcript read establishes ownership without a speculative page.
        if let project = selectedProjectCanonicalKey, knownProject(for: selectedSessionID) != project { return false }
        loadProjectSessions(ensuring: selectedSessionID,
                            requestedPageCount: max(depth, pageState.read(\.requestedDepth)))
        return true
    }

    private func acceptSessionPages(_ page: LoadedSessionPages, attempted: Int64?, depth: Int,
                                    rootReceipt: RootSummaryRefresh?, dataGeneration: UUID, isCurrent: () -> Bool) {
        if replacePageForLatestSelection(page, attempted: attempted, depth: depth, isCurrent: isCurrent) { return }
        applySessionPages(page, attempted: attempted, rootReceipt: rootReceipt, dataGeneration: dataGeneration, isCurrent: isCurrent)
        guard isCurrent() else { return }
        _ = replacePageForLatestSelection(page, attempted: attempted, depth: depth, isCurrent: isCurrent)
    }

    private func applySessionPages(_ page: LoadedSessionPages, attempted: Int64?, rootReceipt: RootSummaryRefresh?,
                                   dataGeneration: UUID, isCurrent: () -> Bool) {
        guard isCurrent(), let database else { return }
        if let attempted, attempted == selectedSessionID, dataGeneration == sidebarDataGeneration,
           !page.sessions.contains(where: { $0.id == attempted }) {
            missingSelectionAttempt = .init(database: database, session: attempted, request: sessionRequestID,
                project: selectedProjectCanonicalKey, configuration: sourceConfigurationRevision,
                dataGeneration: dataGeneration)
        }
        let previous = publishingPageSelectionMetadata
        publishingPageSelectionMetadata = (database, sessions)
        defer { publishingPageSelectionMetadata = previous }
        let fulfilled = page.pageCount >= pageState.read(\.requestedDepth) || page.nextCursor == nil
        acknowledgeRootSummary(rootReceipt, sessions: true)
        summaryReadFailures[.sessionList] = nil
        if fulfilled { summaryReadFailures[.sessionPage] = nil }
        updateSessionPage {
            $0.sessions = page.sessions
            $0.totalCount = page.totalCount
            $0.cursor = page.nextCursor
            $0.pageCount = page.pageCount
            if fulfilled {
                $0.requestedDepth = page.pageCount
                $0.error = nil
                $0.retry = nil
            }
        }
    }

    func retrySessionLoad() {
        guard !terminating, let retry = sessionListRetry else { return }
        if backgroundSidebarRequest != nil {
            pendingSidebarAction = (selectedProjectCanonicalKey, .retry(retry))
            return
        }
        guard !isLoadingSessions else { return }
        performSidebarRetry(retry)
    }

    private func performSidebarRetry(_ retry: SessionListRetry) {
        switch retry {
        case .reload(let pageCount):
            loadProjectSessions(ensuring: selectedSessionID, requestedPageCount: pageCount)
        case .nextPage(let pageCount):
            if !pageCoverageSatisfies(pageCount) { loadMoreSessions() }
        }
    }

    func loadMoreSessions() {
        if backgroundSidebarRequest != nil {
            if pendingSidebarAction == nil {
                pendingSidebarAction = (selectedProjectCanonicalKey, .loadMore)
            }
            return
        }
        guard !isLoadingSessions, let cursor = nextSessionCursor, let database else { return }
        let key = selectedProjectCanonicalKey
        let request = UUID()
        let configuration = sourceConfigurationRevision
        let pageCount = loadedSessionPageCount + 1
        func isCurrent() -> Bool {
            !terminating && !Task.isCancelled && self.database === database
                && sourceConfigurationRevision == configuration
                && projectRequestID == request && selectedProjectCanonicalKey == key
        }
        projectRequestID = request
        sessionListTask = Task {
            defer {
                finishSessionListRequest(request, database: database, project: key,
                                         configuration: configuration, pageCount: pageCount)
            }
            do {
                #if DEBUG
                try checkSessionReadFailureForUITesting(pagination: true)
                #endif
                let page = try await database.sessionsPage(projectCanonicalKey: key, cursor: cursor)
                #if DEBUG
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_NEXT_PAGE_HOLD_MS", cappedAt: 30_000,
                    marker: .touch(pathKey: "TRACE_TEST_NEXT_PAGE_STARTED_PATH")) {
                    try await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_NEXT_PAGE_RELEASE_PATH",
                                                          timeoutMilliseconds: delay)
                }
                if let gate = sessionPageReadGateForTesting { await gate.value }
                #endif
                try Task.checkCancellation()
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_SESSION_PAGE_DELAY_MS", cappedAt: 5_000,
                    marker: .touch(pathKey: "TRACE_TEST_SESSION_PAGE_STARTED_PATH")
                ) {
                    try await Task.sleep(for: .milliseconds(delay))
                }
                guard isCurrent() else { return }
                summaryReadFailures[.sessionPage] = nil
                updateSessionPage {
                    let existing = Set($0.sessions.map(\.id))
                    $0.sessions.append(contentsOf: page.sessions.filter { !existing.contains($0.id) })
                    $0.sessions.sort { ($0.lastActivityMilliseconds, $0.id) > ($1.lastActivityMilliseconds, $1.id) }
                    $0.totalCount = page.totalCount
                    $0.cursor = page.nextCursor
                    $0.pageCount = pageCount
                    $0.requestedDepth = pageCount
                    $0.error = nil
                    $0.retry = nil
                }
                guard isCurrent() else { return }
                if let selectedSessionID, !alreadyEnsuredMissingSelection(selectedSessionID),
                   !sessions.contains(where: { $0.id == selectedSessionID }),
                   key == nil || knownProject(for: selectedSessionID) == key {
                    loadProjectSessions(ensuring: selectedSessionID, requestedPageCount: pageCount)
                }
            } catch is CancellationError {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_SESSION_PAGE_CANCELLED_PATH")
            }
            catch {
                guard isCurrent() else { return }
                recordSummaryReadFailure(error, operation: .sessionPage)
                guard isCurrent() else { return }
                updateSessionPage {
                    $0.error = "Could not load more sessions. Try again."
                    $0.retry = .nextPage(pageCount: pageCount)
                }
            }
        }
        updateSessionPage {
            $0.isLoading = true
            $0.requestedDepth = max($0.requestedDepth, pageCount)
            $0.error = nil
            $0.retry = nil
        }
    }

    func selectSession(_ sessionID: Int64, showWindow: Bool = false, messageID: Int64? = nil, preservingMainSearch: Bool = false) {
        if selectedSessionID == sessionID, selectedSession != nil, messageID == nil {
            if pendingSelectionCompletion != nil {
                if showWindow { pendingSelectionCompletion?.showWindow = true }
                if transcriptBanner != nil { showPendingSelectionWindow() }
            } else if showWindow {
                NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
            }
            return
        }
        let request = UUID(), ownerDatabase = database
        sessionRequestID = request
        func isCurrent() -> Bool {
            !terminating && database === ownerDatabase && sessionRequestID == request
        }
        let cachedSession = sessions.first { $0.id == sessionID } ?? recentSessions.first { $0.id == sessionID }
        rememberSelectionProject(knownProject(for: sessionID), sessionID: sessionID)
        invalidateTranscriptSettlement()
        pausedTranscriptPreservation = nil
        cancelTranscriptRecovery(clearPresentation: false)
        cancelPendingSelectionTranscriptRead()
        if !preservingMainSearch { mainSearchReturnContext = nil; mainSearchReturnAnchor = nil }
        pendingSelectionCompletion = nil
        mayRestoreSession = false
        settings.lastSessionID = sessionID
        lastAppliedTranscriptReadRevision = 0
        requestedMessageID = messageID
        if let database {
            pendingSelectionCompletion = .init(database: database, sessionID: sessionID, requestID: request,
                                               showWindow: showWindow, preservingMainSearch: preservingMainSearch)
        }
        resetTranscriptValues(sessionID: sessionID, session: cachedSession)
        guard isCurrent() else { return }
        if !preservingMainSearch {
            hasSearchReturnContext = false
            guard isCurrent() else { return }
        }
        if sidebarRevealRequest?.sessionID != sessionID {
            invalidateSidebarRevealRequest()
            guard isCurrent() else { return }
        }
        if let cachedSession {
            let changedProject = adoptProjectIdentity(from: cachedSession)
            guard isCurrent() else { return }
            if changedProject { loadProjectSessions(ensuring: sessionID) }
            guard isCurrent() else { return }
        }
        if !preservingMainSearch { deferMainSearchForSessionNavigation() }
        guard isCurrent(), let database else { return }
        // Summaries can await the database result independently of the UI callback.
        let readTask = Task { () -> TranscriptReadOutcome in
            guard !Task.isCancelled,
                  transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request) else { return .superseded }
            if let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_SELECTION_READ_HOLD_MS", cappedAt: 30_000,
                marker: .touch(pathKey: "TRACE_TEST_SELECTION_READ_ENTERED_PATH")
            ) {
                do {
                    try await TraceTestHooks.waitForRelease(
                        pathKey: "TRACE_TEST_SELECTION_READ_RELEASE_PATH", timeoutMilliseconds: delay
                    )
                } catch { return .superseded }
                guard !Task.isCancelled,
                      transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request) else { return .superseded }
            }
            #if DEBUG
            if let gate = selectionTranscriptReadGateForTesting {
                selectionTranscriptReadWaitingForTesting = true
                await gate.value
                selectionTranscriptReadWaitingForTesting = false
            }
            guard !Task.isCancelled,
                  transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request) else { return .superseded }
            #endif
            return await readTranscript(database: database, sessionID: sessionID, request: request)
        }
        pendingSelectionTranscriptRead = .init(requestID: request, task: readTask)
        Task {
            defer {
                if pendingSelectionTranscriptRead?.requestID == request { pendingSelectionTranscriptRead = nil }
            }
            let outcome = await readTask.value
            #if DEBUG
            if case .snapshot = outcome, let gate = selectionTranscriptGateForTesting {
                selectionTranscriptWaitingForTesting = true
                await gate.value
                selectionTranscriptWaitingForTesting = false
            }
            #endif
            guard transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request) else { return }
            guard let snapshot = recoverableSnapshot(outcome, database: database, sessionID: sessionID, request: request) else { return }
            let acceptance = acceptTranscript(snapshot)
            assert(acceptance != .requiresRows, "Selection reads always contain complete rows")
            if acceptance == .accepted {
                applyTranscript(snapshot, deletionIsConfirmed: false)
            }
        }
    }

    func openSession(_ session: SessionSummary) {
        prepareExternalSessionSelection(
            projectID: session.projectID,
            projectCanonicalKey: session.projectCanonicalKey,
            projectDisplayName: nil,
            sessionID: session.id
        )
        selectSession(session.id, showWindow: true)
    }

    func openSearchResult(_ result: SearchResult, fromMainSearch: Bool = false, anchor: SearchResultAnchor? = nil) {
        if fromMainSearch {
            cancelAutomaticSearch()
            if mainSearchNeedsRefresh { mainSearch.markResultsStale() }
            mainSearch.suspendForNavigation()
            mainSearchReturnContext = .init(projectID: selectedProjectID,
                                           canonicalKey: selectedProjectCanonicalKey,
                                           displayName: selectedProjectDisplayName)
            hasSearchReturnContext = true
            mainSearchReturnAnchor = anchor
        }
        prepareExternalSessionSelection(
            projectID: result.projectID,
            projectCanonicalKey: result.projectCanonicalKey,
            projectDisplayName: result.projectName,
            sessionID: result.sessionID
        )
        selectSession(result.sessionID, showWindow: true, messageID: result.id, preservingMainSearch: fromMainSearch)
    }

    private func prepareExternalSessionSelection(
        projectID: Int64,
        projectCanonicalKey: String,
        projectDisplayName: String?,
        sessionID: Int64
    ) {
        rememberSelectionProject(projectCanonicalKey, sessionID: sessionID)
        let project = projects.first { $0.canonicalKey == projectCanonicalKey }
        let resolvedDisplayName = project?.displayName ?? projectDisplayName
        selectedProjectID = project?.id ?? projectID
        selectedProjectCanonicalKey = projectCanonicalKey
        selectedProjectDisplayName = resolvedDisplayName

        let filter = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty,
           resolvedDisplayName?.localizedCaseInsensitiveContains(filter) != true {
            projectFilter = ""
        }
        setSidebarRevealRequest(
            .init(projectCanonicalKey: projectCanonicalKey, sessionID: sessionID)
        )
        loadProjectSessions(ensuring: sessionID)
    }

    @discardableResult
    private func adoptProjectIdentity(from session: SessionSummary) -> Bool {
        let previousCanonicalKey = selectedProjectCanonicalKey
        let previousDisplayName = selectedProjectDisplayName
        let project = projects.first { $0.canonicalKey == session.projectCanonicalKey }
        selectedProjectCanonicalKey = session.projectCanonicalKey
        selectedProjectID = project?.id ?? session.projectID
        selectedProjectDisplayName = project?.displayName ?? (
            previousCanonicalKey == session.projectCanonicalKey
                ? previousDisplayName
                : nil
        )
        return previousCanonicalKey != session.projectCanonicalKey
    }

    private func setSidebarRevealRequest(_ request: SidebarRevealRequest) {
        sidebarRevealFallbackTask?.cancel()
        sidebarProjectRevealAcknowledged = false
        sidebarSessionRevealAcknowledged = false
        sidebarRevealRequest = request
        let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SIDEBAR_REVEAL_FALLBACK_DELAY_MS", cappedAt: 5_000
        ) ?? 5_000
        let clock = clock
        if TraceTestHooks.isUITesting, TraceTestHooks.environment["TRACE_TEST_PROJECT_AVAILABILITY_RELEASE_PATH"] != nil {
            TraceTestHooks.touch(pathKey: "TRACE_TEST_PROJECT_AVAILABILITY_ENTERED_PATH")
            Task { @MainActor [weak self] in
                try? await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_PROJECT_AVAILABILITY_RELEASE_PATH", timeoutMilliseconds: 15_000)
                guard let self, self.sidebarRevealRequest?.token == request.token else { return }
                self.objectWillChange.send()
            }
        }
        sidebarRevealFallbackTask = Task { [weak self] in
            do {
                if TraceTestHooks.isUITesting {
                    for key in ["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_RELEASE_PATH", "TRACE_TEST_PROJECT_AVAILABILITY_RELEASE_PATH"]
                        where TraceTestHooks.environment[key] != nil {
                        try await TraceTestHooks.waitForRelease(pathKey: key, timeoutMilliseconds: 15_000)
                    }
                }
                try await clock.sleep(for: .milliseconds(delay))
            }
            catch { return }
            guard let self, self.sidebarRevealRequest?.token == request.token else { return }
            TraceTestHooks.touch(pathKey: "TRACE_TEST_SIDEBAR_REVEAL_FALLBACK_PATH")
            self.invalidateSidebarRevealRequest(token: request.token)
        }
    }

    private func invalidateSidebarRevealRequest(token: UUID? = nil) {
        if let token, sidebarRevealRequest?.token != token { return }
        sidebarRevealFallbackTask?.cancel()
        sidebarRevealFallbackTask = nil
        sidebarRevealRequest = nil
        sidebarProjectRevealAcknowledged = false
        sidebarProjectMaterializedToken = nil
        sidebarSessionRevealAcknowledged = false
    }

    func claimSidebarProjectMaterialization(token: UUID) -> Bool {
        guard sidebarRevealRequest?.token == token, sidebarProjectMaterializedToken != token else { return false }
        sidebarProjectMaterializedToken = token
        return true
    }

    func acknowledgeSidebarProjectReveal(token: UUID) {
        guard sidebarRevealRequest?.token == token else { return }
        sidebarProjectRevealAcknowledged = true
        TraceTestHooks.touch(pathKey: "TRACE_TEST_SIDEBAR_PROJECT_REVEAL_ACK_PATH")
        finishSidebarRevealIfAcknowledged()
    }

    func cancelSidebarReveal(token: UUID) {
        guard sidebarRevealRequest?.token == token else { return }
        TraceTestHooks.touch(pathKey: "TRACE_TEST_SIDEBAR_REVEAL_CANCELLED_PATH")
        invalidateSidebarRevealRequest(token: token)
    }

    func acknowledgeSidebarSessionReveal(token: UUID) {
        guard sidebarRevealRequest?.token == token else { return }
        sidebarSessionRevealAcknowledged = true
        finishSidebarRevealIfAcknowledged()
    }

    private func finishSidebarRevealIfAcknowledged() {
        guard sidebarProjectRevealAcknowledged,
              sidebarSessionRevealAcknowledged else { return }
        invalidateSidebarRevealRequest()
    }

    func copyMessage(id: Int64) {
        guard let coordinator else { return }
        Task {
            do {
                let message = try await coordinator.hydrate(messageID: id)
                let sections = message.sections
                let text = [sections.prose, sections.toolInvocation, sections.toolOutput, sections.reasoning]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                startupError = "Could not copy message: \(error.localizedDescription)"
            }
        }
    }

    func hydrate(_ message: MessageSummary) {
        let identity = MessageIdentity(message)
        guard messageIdentities[message.id] == identity else { return }
        if hydratedMessages[message.id] != nil {
            hydrationOrder.removeAll { $0 == message.id }
            hydrationOrder.append(message.id)
            return
        }
        guard hydrationFailures[message.id] == nil, let coordinator else { return }
        if let active = hydratingMessageIDs[message.id],
           active.epoch == hydrationEpoch, active.identity == identity { return }
        let active = HydrationRequest(epoch: hydrationEpoch, identity: identity)
        hydratingMessageIDs[message.id] = active
        Task {
            defer {
                if hydratingMessageIDs[message.id]?.token == active.token {
                    hydratingMessageIDs.removeValue(forKey: message.id)
                }
            }
            let start = ContinuousClock.now
            do {
                TraceTestHooks.appendLine(String(message.id), pathKey: "TRACE_TEST_HYDRATION_REQUESTS_PATH")
                let failureIndex = TraceTestHooks.environment["TRACE_TEST_FAIL_HYDRATION_MESSAGE_INDEX"].flatMap(Int.init)
                if (failureIndex == nil || messages.firstIndex(where: { $0.id == message.id }) == failureIndex),
                   TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_HYDRATION_ONCE") {
                    throw SessionSourceError.unreadableFile("Synthetic read failure")
                }
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_TRANSCRIPT_HYDRATION_DELAY_MS",
                    marker: .line(String(message.id), pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_STARTED_PATH")
                ) {
                    try await TraceTestHooks.waitForRelease(
                        pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_RELEASE_PATH", timeoutMilliseconds: delay
                    )
                }
                let hydrated = try await coordinator.hydrate(message)
                #if DEBUG
                if let gate = hydrationPublicationGateForTesting {
                    hydrationPublicationWaitingForTesting = true
                    await gate.value
                    hydrationPublicationWaitingForTesting = false
                }
                #endif
                if TraceTestHooks.isUITesting,
                   TraceTestHooks.environment["TRACE_TEST_HYDRATION_RESULT_RELEASE_PATH"] != nil {
                    TraceTestHooks.appendLine(String(message.id), pathKey: "TRACE_TEST_HYDRATION_RESULT_ENTERED_PATH")
                    try await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_HYDRATION_RESULT_RELEASE_PATH",
                                                           timeoutMilliseconds: 30_000)
                }
                guard hydrationIsCurrent(active) else { return }
                TraceTestHooks.appendLine(String(message.id), pathKey: "TRACE_TEST_TRANSCRIPT_HYDRATION_COMPLETED_PATH")
                var cache = hydratedMessages
                cache[message.id] = hydrated
                hydrationOrder.removeAll { $0 == message.id }
                hydrationOrder.append(message.id)
                if hydrationOrder.count > hydrationCacheLimit {
                    let evicted = hydrationOrder.removeFirst()
                    cache.removeValue(forKey: evicted)
                }
                hydratedMessages = cache
                guard hydrationIsCurrent(active) else { return }
                let elapsed = start.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                try? await diagnostics.recordOpen(hydrationMilliseconds: milliseconds)
            } catch {
                guard hydrationIsCurrent(active) else { return }
                hydrationFailures[message.id] = error.localizedDescription
            }
        }
    }

    private func hydrationIsCurrent(_ request: HydrationRequest) -> Bool {
        hydrationEpoch == request.epoch
            && messageIdentities[request.identity.id] == request.identity
            && hydratingMessageIDs[request.identity.id]?.token == request.token
    }

    private enum TranscriptAcceptanceResult: Equatable {
        case accepted
        case stale
        case requiresRows
    }

    private func transcriptRequestIsCurrent(
        database: IndexDatabase, sessionID: Int64, request: UUID, summary: UUID? = nil
    ) -> Bool {
        self.database === database && selectedSessionID == sessionID
            && sessionRequestID == request && (summary == nil || summaryRequestID == summary)
    }

    private func cancelPendingSelectionTranscriptRead() {
        let read = pendingSelectionTranscriptRead
        pendingSelectionTranscriptRead = nil
        read?.task.cancel()
    }

    private func readTranscript(database: IndexDatabase, sessionID: Int64, request: UUID,
                                summary: UUID? = nil, terminal: TerminalSummaryReceipt? = nil) async -> TranscriptReadOutcome {
        let outcome: TranscriptReadOutcome
        do { outcome = .snapshot(try await database.transcriptSnapshot(sessionID: sessionID)) }
        catch is CancellationError { return .superseded }
        catch { outcome = .failed(error.localizedDescription) }
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return .superseded }
        return outcome
    }

    private func completeTranscriptRead(
        database: IndexDatabase, sessionID: Int64, request: UUID, summary: UUID? = nil,
        terminal: TerminalSummaryReceipt? = nil
    ) async -> TranscriptReadOutcome {
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return .superseded }
        #if DEBUG
        if let gate = transcriptRecoveryReadGateForTesting {
            transcriptRecoveryReadWaitingForTesting = true
            await gate.value
            transcriptRecoveryReadWaitingForTesting = false
        }
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return .superseded }
        #endif
        let outcome = await readTranscript(database: database, sessionID: sessionID, request: request, summary: summary, terminal: terminal)
        #if DEBUG
        if let gate = transcriptRecoveryPublicationGateForTesting {
            transcriptRecoveryPublicationWaitingForTesting = true
            await gate.value
            transcriptRecoveryPublicationWaitingForTesting = false
        }
        #endif
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return .superseded }
        return outcome
    }

    private func cancelTranscriptRecovery(clearPresentation: Bool = true) {
        transcriptRecoveryEpisode = nil
        transcriptRecoveryTask?.cancel()
        transcriptRecoveryTask = nil
        if clearPresentation { transcriptReadError = nil }
    }

    func retrySelectedTranscript() {
        guard let database, let sessionID = selectedSessionID, !terminating else { return }
        cancelTranscriptRecovery()
        scheduleTranscriptRecovery(error: "Could not read the selected session.", database: database,
                                   sessionID: sessionID, request: sessionRequestID, immediately: true)
    }

    private func transcriptRecoveryIsCurrent(_ episode: TranscriptRecoveryEpisode, summary: UUID? = nil) -> Bool {
        !terminating && transcriptRecoveryEpisode?.id == episode.id
            && transcriptRequestIsCurrent(database: episode.database, sessionID: episode.sessionID,
                                          request: episode.requestID, summary: summary)
    }

    private func publishExhaustedTranscriptReadError(_ episode: TranscriptRecoveryEpisode, summary: UUID? = nil) {
        guard let current = transcriptRecoveryEpisode, case .exhausted(let error) = current.phase,
              transcriptRecoveryIsCurrent(episode, summary: summary) else { return }
        transcriptReadError = error
        // Publications can synchronously replace the selection or start another workflow.
        guard transcriptRecoveryIsCurrent(episode, summary: summary) else { return }
        if !indexWorkflow.isActive, let absence = transientTranscriptAbsence,
           absence.database === episode.database, absence.sessionID == episode.sessionID,
           absence.requestID == episode.requestID {
            transientTranscriptAbsence = nil
        }
        guard transcriptRecoveryIsCurrent(episode, summary: summary) else { return }
        TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_RECOVERY_EXHAUSTED_PATH")
        showPendingSelectionWindow()
    }

    private func invalidateTranscriptSettlement() {
        transcriptSettlement = nil
        transcriptSettlementTask?.cancel()
        transcriptSettlementTask = nil
    }

    private func transcriptSettlementIsCurrent(_ owner: TranscriptSettlement) -> Bool {
        guard let current = transcriptSettlement, current.id == owner.id else { return false }
        return !terminating && database === owner.database
            && attachmentGeneration == owner.attachment && sourceConfigurationRevision == owner.configuration
            && indexWorkflow.generation == owner.workflow && !indexWorkflow.isActive && pendingAttachment == nil
            && selectedSessionID == owner.sessionID && sessionRequestID == owner.requestID
            && summaryRequestID == owner.summaryID
    }

    private func resumePausedTranscriptFeedback() {
        guard indexWorkflow.isActive, let absence = pausedTranscriptPreservation,
              transcriptRequestIsCurrent(database: absence.database, sessionID: absence.sessionID, request: absence.requestID) else { return }
        if transientTranscriptAbsence == nil || transientTranscriptAbsence?.paused == true {
            var updating = absence
            updating.paused = false
            transientTranscriptAbsence = updating
        }
    }

    @discardableResult
    private func settleTranscriptFeedback() -> Task<Void, Never>? {
        // This is workflow-owned work; the delivery task may already be cancelled.
        guard !terminating, !indexWorkflow.isActive, pendingAttachment == nil, let database else { return nil }
        guard transientTranscriptAbsence != nil || pausedTranscriptPreservation != nil || transcriptRecoveryEpisode != nil else { return nil }
        if let current = transcriptSettlement,
           current.database === database, current.attachment == attachmentGeneration,
           current.configuration == sourceConfigurationRevision, current.workflow == indexWorkflow.generation,
           current.sessionID == selectedSessionID, current.requestID == sessionRequestID,
           current.summaryID == summaryRequestID { return transcriptSettlementTask }
        invalidateTranscriptSettlement()
        let owner = TranscriptSettlement(database: database, attachment: attachmentGeneration,
            configuration: sourceConfigurationRevision, workflow: indexWorkflow.generation,
            sessionID: selectedSessionID, requestID: sessionRequestID, summaryID: summaryRequestID,
            revalidateAbsence: transcriptRecoveryEpisode == nil)
        transcriptSettlement = owner
        if let absence = transientTranscriptAbsence,
           transcriptRequestIsCurrent(database: absence.database, sessionID: absence.sessionID, request: absence.requestID) {
            var paused = absence
            paused.paused = true
            pausedTranscriptPreservation = paused
            // Keep selection protection without an intermediate paused banner
            // when the current episode already has exhausted read-error feedback.
            let exhausted: Bool
            if let episode = transcriptRecoveryEpisode, transcriptRecoveryIsCurrent(episode),
               case .exhausted = episode.phase { exhausted = true }
            else { exhausted = false }
            if !absence.paused && !exhausted { transientTranscriptAbsence = paused }
        }
        guard transcriptSettlementIsCurrent(owner) else { return nil }
        transcriptSettlementTask = Task { [weak self] in
            guard let self else { return }
            defer { if transcriptSettlement?.id == owner.id { transcriptSettlementTask = nil } }
            #if DEBUG
            if let gate = transcriptSettlementGateForTesting {
                transcriptSettlementWaitingForTesting = true
                await gate.value
                transcriptSettlementWaitingForTesting = false
            }
            #endif
            guard !Task.isCancelled, transcriptSettlementIsCurrent(owner) else { return }
            if let episode = transcriptRecoveryEpisode, transcriptRecoveryIsCurrent(episode) {
                if case .exhausted = episode.phase { publishExhaustedTranscriptReadError(episode) }
                return // Running recovery owns its existing bounded budget.
            }
            // A recovery that finished while settlement waited has already
            // revalidated the absence; its completion must not admit another read.
            guard owner.revalidateAbsence, let sessionID = owner.sessionID, let absence = pausedTranscriptPreservation,
                  absence.database === database, absence.sessionID == sessionID, absence.requestID == owner.requestID else { return }
            let outcome = await completeTranscriptRead(database: database, sessionID: sessionID, request: owner.requestID,
                                                      summary: owner.summaryID)
            guard !Task.isCancelled, transcriptSettlementIsCurrent(owner) else { return }
            guard let snapshot = recoverableSnapshot(outcome, database: database, sessionID: sessionID,
                                                     request: owner.requestID, summary: owner.summaryID),
                  acceptTranscript(snapshot) == .accepted else { return }
            applyTranscript(snapshot, reconcilingProject: true)
        }
        return transcriptSettlementTask
    }

    private func scheduleTranscriptRecovery(error: String, database: IndexDatabase, sessionID: Int64,
                                            request: UUID, immediately: Bool = false, summary: UUID? = nil) {
        guard !terminating, !Task.isCancelled,
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return }
        if var episode = transcriptRecoveryEpisode {
            guard transcriptRecoveryIsCurrent(episode, summary: summary) else { return }
            if case .exhausted = episode.phase {
                episode.phase = .exhausted(error)
                transcriptRecoveryEpisode = episode
                publishExhaustedTranscriptReadError(episode, summary: summary)
            }
            return
        }
        let episode = TranscriptRecoveryEpisode(database: database, sessionID: sessionID, requestID: request)
        transcriptRecoveryEpisode = episode
        transcriptRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if transcriptRecoveryEpisode?.id == episode.id { transcriptRecoveryTask = nil }
            }
            var lastError = error
            let delays: [Duration] = immediately ? [.zero, .milliseconds(250), .seconds(1), .seconds(4)]
                                                 : [.milliseconds(250), .seconds(1), .seconds(4)]
            for delay in delays {
                do { try await clock.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, transcriptRecoveryIsCurrent(episode) else { return }
                let outcome = await completeTranscriptRead(database: database, sessionID: sessionID, request: request)
                guard !Task.isCancelled, transcriptRecoveryIsCurrent(episode) else { return }
                switch outcome {
                case .superseded: return
                case .failed(let error): lastError = error
                case .snapshot(let snapshot):
                    guard acceptTranscript(snapshot) == .accepted else { continue }
                    applyTranscript(snapshot, reconcilingProject: true)
                    return
                }
            }
            guard !Task.isCancelled, transcriptRecoveryIsCurrent(episode) else { return }
            var exhausted = episode
            exhausted.phase = .exhausted(lastError)
            transcriptRecoveryEpisode = exhausted
            publishExhaustedTranscriptReadError(exhausted)
        }
    }

    private func recoverableSnapshot(_ outcome: TranscriptReadOutcome, database: IndexDatabase,
                                     sessionID: Int64, request: UUID, summary: UUID? = nil,
                                     terminal: TerminalSummaryReceipt? = nil) -> SessionTranscriptSnapshot? {
        guard terminalSummaryTranscriptIsCurrent(terminal) else { return nil }
        switch outcome {
        case .snapshot(let snapshot): return snapshot
        case .failed(let error):
            scheduleTranscriptRecovery(error: error, database: database, sessionID: sessionID, request: request, summary: summary)
            return nil
        case .superseded: return nil
        }
    }

    private func reconcileMissingTranscript(
        _ snapshot: SessionTranscriptSnapshot, database: IndexDatabase,
        sessionID: Int64, request: UUID, summary: UUID, terminal: TerminalSummaryReceipt? = nil
    ) async -> SessionTranscriptSnapshot? {
        guard snapshot.readRevision > highestObservedTranscriptReadRevision else { return nil }
        guard let pending = pendingSelectionTranscriptRead,
              pending.requestID == request else { return snapshot }
        // Observe deletion without invalidating a newer selection awaiting publication.
        highestObservedTranscriptReadRevision = snapshot.readRevision
        #if DEBUG
        missingSummarySelectionReadWaitingForTesting = true
        #endif
        let selectionOutcome = await pending.task.value
        #if DEBUG
        missingSummarySelectionReadWaitingForTesting = false
        #endif
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary),
              let selectionSnapshot = recoverableSnapshot(selectionOutcome, database: database,
                                                           sessionID: sessionID, request: request, summary: summary, terminal: terminal) else { return nil }
        if selectionSnapshot.readRevision > snapshot.readRevision {
            return selectionSnapshot.session == nil ? selectionSnapshot : nil
        }
        let outcome = await completeTranscriptRead(database: database, sessionID: sessionID, request: request, summary: summary, terminal: terminal)
        return recoverableSnapshot(outcome, database: database, sessionID: sessionID, request: request, summary: summary, terminal: terminal)
    }

    private func finishPreviouslyAppliedMissingTranscript(_ snapshot: SessionTranscriptSnapshot) -> Bool {
        guard snapshot.session == nil, selectedSession == nil,
              lastAppliedTranscriptReadRevision >= snapshot.readRevision,
              lastAppliedTranscriptReadRevision == highestObservedTranscriptReadRevision else { return false }
        returnFromSession()
        return true
    }

    private func reconcileSidebarReveal(with snapshot: SessionTranscriptSnapshot) {
        guard let session = snapshot.session, let reveal = sidebarRevealRequest,
              reveal.sessionID == session.id, reveal.projectCanonicalKey != session.projectCanonicalKey else { return }
        invalidateSidebarRevealRequest(token: reveal.token)
    }

    private func refreshSelectedTranscript(
        _ loaded: SessionTranscriptSnapshot, database: IndexDatabase,
        sessionID: Int64, request: UUID, summary: UUID, terminal: TerminalSummaryReceipt? = nil
    ) async {
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return }
        if finishPreviouslyAppliedMissingTranscript(loaded) { return }
        var snapshot = loaded
        if snapshot.session == nil {
            guard let reconciled = await reconcileMissingTranscript(snapshot, database: database,
                                                                   sessionID: sessionID, request: request, summary: summary, terminal: terminal) else { return }
            snapshot = reconciled
        }
        guard !Task.isCancelled, terminalSummaryTranscriptIsCurrent(terminal),
              transcriptRequestIsCurrent(database: database, sessionID: sessionID, request: request, summary: summary) else { return }
        if finishPreviouslyAppliedMissingTranscript(snapshot) { return }
        var acceptance = acceptTranscript(snapshot)
        if acceptance == .requiresRows {
            let outcome = await completeTranscriptRead(database: database, sessionID: sessionID, request: request, summary: summary, terminal: terminal)
            guard let recovered = recoverableSnapshot(outcome, database: database, sessionID: sessionID, request: request, summary: summary, terminal: terminal) else { return }
            snapshot = recovered
            acceptance = acceptTranscript(recovered)
        }
        guard acceptance == .accepted else { return }
        applyTranscript(snapshot)
    }

    /// After acceptance, apply the snapshot or navigate back without suspension.
    private func acceptTranscript(_ snapshot: SessionTranscriptSnapshot) -> TranscriptAcceptanceResult {
        guard snapshot.readRevision > highestObservedTranscriptReadRevision else { return .stale }
        // Even an unusable omission establishes that older reads are obsolete.
        // The caller recovers with a newer snapshot containing complete rows.
        highestObservedTranscriptReadRevision = snapshot.readRevision
        // Omitted rows may only reuse a transcript matching the state the
        // database read actually described, even if another read published first.
        if snapshot.messages == nil {
            guard let session = snapshot.session,
                  selectedSession?.transcriptIdentity == session.transcriptIdentity,
                  messages.count == session.messageCount else { return .requiresRows }
        }
        return .accepted
    }

    /// Called on the main actor without suspension: no hydration request can
    /// observe new source metadata paired with the old locator rows.
    private func applyTranscript(_ snapshot: SessionTranscriptSnapshot, deletionIsConfirmed: Bool = true,
                                 reconcilingProject: Bool = false) {
        let ownerDatabase = database, ownerSessionID = selectedSessionID, ownerRequest = sessionRequestID
        func isCurrent() -> Bool {
            !terminating && database === ownerDatabase && selectedSessionID == ownerSessionID && sessionRequestID == ownerRequest
        }
        let preservingPausedSelection = pausedTranscriptPreservation.map {
            transcriptRequestIsCurrent(database: $0.database, sessionID: $0.sessionID, request: $0.requestID)
        } == true && indexWorkflow.terminalPhase == nil
        if snapshot.session == nil, indexWorkflow.isActive || preservingPausedSelection,
           let database, let sessionID = selectedSessionID {
            // All publishers share this policy. Accept the revision, preserve the
            // cached view, and end an older read-error episode without applying absence.
            cancelTranscriptRecovery(clearPresentation: false)
            let absence = TranscriptAbsence(database: database, sessionID: sessionID, requestID: sessionRequestID,
                                            paused: !indexWorkflow.isActive)
            updateTranscript { $0.readError = nil; $0.absence = absence }
            guard isCurrent() else { return }
            if !indexWorkflow.isActive { TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_PAUSED_PATH") }
            showPendingSelectionWindow()
            return
        }
        cancelTranscriptRecovery(clearPresentation: false)
        pausedTranscriptPreservation = nil
        if snapshot.session == nil, deletionIsConfirmed || pendingSelectionCompletion != nil {
            let showWindow = pendingSelectionCompletion?.showWindow == true
            returnFromSession()
            if showWindow, selectedSessionID == nil { NotificationCenter.default.post(name: .traceShowMainWindow, object: nil) }
            return
        }
        lastAppliedTranscriptReadRevision = snapshot.readRevision
        let changed = selectedSession?.transcriptIdentity != snapshot.session?.transcriptIdentity
        let identities = changed ? nil : snapshot.messages.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, MessageIdentity($0)) }) }
        let stale = identities.map { next in Set(messageIdentities.keys.filter { messageIdentities[$0] != next[$0] }) } ?? []
        if changed {
            hydrationEpoch = UUID()
            hydratingMessageIDs.removeAll(keepingCapacity: true)
            hydrationOrder.removeAll(keepingCapacity: true)
        } else {
            for id in stale { hydratingMessageIDs.removeValue(forKey: id) }
            hydrationOrder.removeAll { stale.contains($0) }
        }
        let resolvedUnknownProject = snapshot.session.map { knownProject(for: $0.id) == nil } ?? false
        if let session = snapshot.session, missingSelectionAttempt?.session == session.id { missingSelectionAttempt = nil }
        if let session = snapshot.session { rememberSelectionProject(session.projectCanonicalKey, sessionID: session.id) }
        updateTranscript(replacingRows: snapshot.messages != nil) {
            $0.session = snapshot.session
            $0.readError = nil
            $0.absence = nil
            if changed {
                $0.hydrated.removeAll(keepingCapacity: true)
                $0.failures.removeAll(keepingCapacity: true)
                $0.contentRevision &+= 2
            } else {
                for id in stale {
                    $0.hydrated.removeValue(forKey: id)
                    $0.failures.removeValue(forKey: id)
                    $0.contentRevision &+= 2
                }
            }
            if let rows = snapshot.messages { $0.messages = rows; $0.messageRevision &+= 1 }
        }
        guard isCurrent() else { return }
        // Evaluate background navigation at publication, after any read/retry
        // suspension. Explicit selections reconcile regardless of a running pass.
        let completingSelection = pendingSelectionCompletion != nil
        if completingSelection || !indexingPassActive { reconcileSidebarReveal(with: snapshot) }
        guard isCurrent() else { return }
        // Ordinary summaries update the transcript without changing the project
        // being browsed. Selection completion and recovery retain their navigation.
        if completingSelection || reconcilingProject, let session = snapshot.session {
            let changedProject = adoptProjectIdentity(from: session)
            guard isCurrent() else { return }
            let needsSelectedRow = completingSelection && resolvedUnknownProject && sessionListError == nil
                && !isLoadingSessions && backgroundSidebarRequest == nil
                && !sessions.contains(where: { $0.id == session.id })
            if changedProject {
                let preservingSearch = pendingSelectionCompletion?.preservingMainSearch ?? hasSearchReturnContext
                if !preservingSearch { deferMainSearchForSessionNavigation() }
                guard isCurrent() else { return }
            }
            if changedProject || needsSelectedRow { loadProjectSessions(ensuring: session.id) }
            guard isCurrent() else { return }
        }
        completeSelectionIfPending(snapshot)
    }

    private func showPendingSelectionWindow() {
        guard let completion = pendingSelectionCompletion, completion.showWindow,
              transcriptRequestIsCurrent(database: completion.database, sessionID: completion.sessionID,
                                         request: completion.requestID) else { return }
        // Consume only window visibility; a later successful read still completes
        // scrolling and diagnostics exactly once.
        pendingSelectionCompletion?.showWindow = false
        NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
    }

    private func completeSelectionIfPending(_ snapshot: SessionTranscriptSnapshot) {
        guard let completion = pendingSelectionCompletion,
              transcriptRequestIsCurrent(database: completion.database, sessionID: completion.sessionID,
                                         request: completion.requestID),
              let session = snapshot.session, session.id == completion.sessionID else { return }
        // Consume before publishing actions, including notifications that can reenter the model.
        pendingSelectionCompletion = nil
        scrollRequest = UUID()
        guard transcriptRequestIsCurrent(database: completion.database, sessionID: completion.sessionID,
                                         request: completion.requestID) else { return }
        if completion.showWindow { NotificationCenter.default.post(name: .traceShowMainWindow, object: nil) }
        Task { [diagnostics] in try? await diagnostics.recordOpen() }
    }

    func retryHydration(_ message: MessageSummary) {
        guard messageIdentities[message.id] == MessageIdentity(message) else { return }
        hydrationFailures.removeValue(forKey: message.id)
        hydrate(message)
    }

    func revealSelectedSession() {
        guard let session = (sessions + recentSessions).first(where: { $0.id == selectedSessionID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.sourcePath)])
    }

    func copyTranscript() {
        guard let coordinator else { return }
        let summaries = messages
        let expanded = expandedReasoningIDs
        let visibility = settings.transcriptVisibility
        Task {
            var blocks: [String] = []
            for summary in summaries where visibility.includes(summary) {
                guard let hydrated = try? await coordinator.hydrate(summary) else { continue }
                let body = visibility.text(hydrated, expandedReasoning: expanded.contains(summary.id))
                if !body.isEmpty { blocks.append("## \(hydrated.role.rawValue)\n\n\(body)") }
            }
            let transcript = blocks.joined(separator: "\n\n")
            #if DEBUG
            if let transcriptCopyForTesting { transcriptCopyForTesting(transcript); return }
            #endif
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
        }
    }

    private func filteredUsage(_ completed: [UsageRollup]) -> [UsageRollup] {
        let dates = costDateBounds()
        return completed.filter { row in
            (dates.from.map { row.day >= $0 } ?? true)
                && (dates.through.map { row.day <= $0 } ?? true)
                && (settings.includeSidechains || !row.isSidechain)
        }
    }

    func reloadCosts() {
        publishCosts(.filterOnly)
    }

    private var usageRetryEligible: Bool {
        !terminating && database != nil && usageWork.owed && !indexingPassActive
            && pendingAttachment == nil && usageWork.pending == nil && usageWork.worker == nil
    }

    func retryCosts() {
        // Inspect ownership directly: a synchronous observer can invoke Retry
        // before the disabled presentation has reached every subscriber.
        guard costsError != nil, usageRetryEligible else { return }
        ModelPublicationBatch.perform {
            reconcileUsageWork(event: newUsageRecoveryEvent(), urgency: .immediate)
            #if DEBUG
            if !usageHoldWasConsumedForUITesting,
               TraceTestHooks.delayMilliseconds(for: "TRACE_TEST_USAGE_ATTEMPT_HOLD_MS", cappedAt: 30_000) != nil,
               let path = TraceTestHooks.environment["TRACE_TEST_USAGE_ATTEMPT_RELEASE_PATH"],
               !FileManager.default.fileExists(atPath: path) {
                usageHoldRequestForUITesting = usageWork.pending?.id
                usageHoldWasConsumedForUITesting = usageHoldRequestForUITesting != nil
            }
            #endif
        }
    }

    private enum CostsPublication {
        case filterOnly
        case cachedRead([UsageRollup])
        case acceptedRefresh([UsageRollup])
    }

    private func publishCosts(_ publication: CostsPublication, recovering receipt: RollupFailureReceipt? = nil,
                              onCommit: () -> Void = {}) {
        let completed: [UsageRollup]
        let clearsError: Bool
        switch publication {
        case .filterOnly: completed = completedUsage; clearsError = false
        case .cachedRead(let snapshot): completed = snapshot; clearsError = false
        case .acceptedRefresh(let snapshot): completed = snapshot; clearsError = true
        }
        let filtered = filteredUsage(completed)
        var stagedProgress = false
        updateCosts({
            $0.completed = completed
            $0.usage = filtered
            $0.usagePublicationRevision &+= 1
            if clearsError { $0.error = nil }
        }, onCommit: {
            if let receipt, receipt.id == rollupFailure?.id, receipt.database === database,
               receipt.passID == progress.passID {
                rollupFailure = nil
                var recovered = progress
                recovered.rollupError = nil
                progressState.stage(recovered)
                stagedProgress = true
            }
            onCommit()
        })
        if stagedProgress { progressState.publish { ModelPublicationBatch.notify(self) } }
    }

    private func loadCachedUsageAtStartup() async {
        guard let database else { return }
        let revision = completedUsageRevision
        do {
            #if DEBUG
            if TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_CACHED_USAGE_ONCE") {
                throw DatabaseError(resultCode: .SQLITE_BUSY, message: "private-cost-message",
                    sql: "SELECT 'private-cost-sql'", arguments: ["private-cost-argument"], publicStatementArguments: true)
            }
            #endif
            let snapshot = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
            guard !terminating, self.database === database, completedUsageRevision == revision else { return }
            costsFailures[.cachedUsage] = nil
            publishCosts(.cachedRead(snapshot))
        } catch {
            #if DEBUG
            if let gate = cachedUsageFailureGateForTesting {
                cachedUsageFailureWaitingForTesting = true
                await gate.value
                cachedUsageFailureWaitingForTesting = false
            }
            #endif
            guard !terminating, self.database === database, completedUsageRevision == revision,
                  !(error is CancellationError) else { return }
            // Record debt without enrolling another attempt. An already enrolled
            // repair covers this read, including its current acceptance fences.
            if !usageWork.owed {
                usageWork.revision &+= 1
                usageWork.owed = true
                usageWork.repair = rootUsageOwed
            }
            recordCostsFailure(error, operation: .cachedUsage)
            guard !terminating, self.database === database, completedUsageRevision == revision else { return }
            costsError = "Could not load cached token totals."
        }
    }

    private func rootReceipt(for database: IndexDatabase) -> RootSummaryRefresh? {
        pendingRootSummaryRefresh.flatMap { $0.database === database ? $0 : nil }
    }

    private var rootUsageOwed: Bool {
        database.flatMap { rootReceipt(for: $0) }?.usage == true
    }

    private func registerUsageDemand(repair: Bool, urgency: UsageUrgency) {
        guard !terminating, database != nil else { return }
        let wasImmediate = usageWork.pending?.urgency == .immediate
        usageWork.revision &+= 1
        usageWork.owed = true
        usageWork.repair = repair || usageWork.repair || rootUsageOwed
        if usageWork.repair { startupUsageRepairEnrolled = true }
        queueCurrentUsageDemand(urgency: wasImmediate ? .immediate : urgency)
    }

    private func queueCurrentUsageDemand(urgency: UsageUrgency) {
        guard let database, usageWork.owed else { return }
        usageWork.pending = .init(database: database, revision: usageWork.revision,
                                  repair: usageWork.repair || rootUsageOwed, urgency: urgency)
    }

    private func invalidateUsageSnapshot() {
        usageWork.epoch = UUID()
        pauseUsageRefreshWaiting()
        if usageWork.owed, usageWork.pending == nil,
           let running = usageWork.worker?.runningRequest {
            queueCurrentUsageDemand(urgency: running.urgency)
        }
    }

    /// Lifecycle events resume pending demand. Recovery events may enroll unpaid
    /// debt once, and observing debt never invents a newer demand revision.
    private func reconcileUsageWork(event: UInt64? = nil, urgency: UsageUrgency = .immediate) {
        guard !terminating else { return }
        let freshEvent = event.map { $0 > usageWork.consumedEvent } ?? false
        if let event { usageWork.consumedEvent = max(usageWork.consumedEvent, event) }
        if freshEvent, usageWork.owed {
            let covered = usageWork.worker?.runningRequest?.revision == usageWork.revision
                && usageWork.worker?.acceptanceEpoch == usageWork.epoch
            if usageWork.pending == nil, !covered { queueCurrentUsageDemand(urgency: urgency) }
            else if urgency == .immediate, usageWork.pending != nil { usageWork.pending?.urgency = .immediate }
        }
        if usageWork.pending?.urgency == .immediate, usageWork.worker?.isWaiting == true,
           usageWork.worker?.urgency == .automatic {
            pauseUsageRefreshWaiting()
        }
        startUsageRefreshWorker()
        updateCostsTotalsUpdating()
    }

    private func pauseUsageRefreshWaiting() {
        guard usageWork.worker?.isWaiting == true else { return }
        usageWork.task?.cancel()
        usageWork.task = nil
        usageWork.worker = nil
    }

    private func resetUsageRefreshWork() {
        usageWork.task?.cancel()
        usageWork = .init()
    }

    private func retireUsageRefreshWorker() {
        // Preserve intent already covering unfinished work, but never rearm
        // dormant failure debt without a new recovery event.
        if usageWork.owed, usageWork.pending == nil, let request = usageWork.worker?.runningRequest {
            queueCurrentUsageDemand(urgency: request.urgency)
        }
        usageWork.task?.cancel()
        usageWork.task = nil
        usageWork.worker = nil
        usageWork.epoch = UUID()
    }

    private func startUsageRefreshWorker() {
        guard !terminating, !indexingPassActive, pendingAttachment == nil,
              usageWork.worker == nil, let request = usageWork.pending,
              database === request.database else { return }
        let worker = UsageRefreshWorker(database: request.database, phase: .waiting(request.urgency))
        usageWork.worker = worker
        usageWork.task = Task { [weak self] in
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !terminating && database === worker.database
                    && usageWork.worker?.id == worker.id
            }
            defer {
                if usageWork.worker?.id == worker.id {
                    usageWork.worker = nil
                    usageWork.task = nil
                    reconcileUsageWork()
                }
            }
            var waitedForRepairQuietPeriod = false
            while isCurrent() {
                await scheduler?.waitUntilIdle()
                guard isCurrent(), !indexingPassActive, pendingAttachment == nil,
                      let request = usageWork.pending, request.database === worker.database else { return }
                if request.repair, request.urgency == .automatic, !waitedForRepairQuietPeriod {
                    TraceTestHooks.touch(pathKey: "TRACE_TEST_USAGE_REPAIR_QUIET_PERIOD_STARTED_PATH")
                    let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_USAGE_REPAIR_QUIET_DELAY_MS", cappedAt: 5_000) ?? 1_000
                    do { try await clock.sleep(for: .milliseconds(delay)) }
                    catch { return }
                    waitedForRepairQuietPeriod = true
                    continue
                }
                usageWork.pending = nil
                let epoch = usageWork.epoch
                usageWork.worker?.phase = .running(request, epoch: epoch)
                #if DEBUG
                if TraceTestHooks.isUITesting {
                    let identity = ["databaseGeneration": usageDatabaseGeneration.uuidString,
                        "workerID": worker.id.uuidString, "requestID": request.id.uuidString]
                    if let data = try? JSONSerialization.data(withJSONObject: identity),
                       let line = String(data: data, encoding: .utf8) {
                        TraceTestHooks.appendLine(line, pathKey: "TRACE_TEST_USAGE_ATTEMPT_STARTED_PATH")
                    }
                }
                #endif
                await performUsageRefresh(request, worker: worker.id, epoch: epoch)
                return
            }
        }
    }

    private func refreshCompletedUsage(repairIfDirty: Bool) async {
        guard let database else { return }
        registerUsageDemand(repair: repairIfDirty, urgency: .immediate)
        reconcileUsageWork()
        await waitForUsageRefresh(database: database)
    }

    private func refreshStartupUsage() async {
        guard let database, !terminating else { return }
        if !startupUsageRepairEnrolled {
            registerUsageDemand(repair: true, urgency: .immediate)
        }
        reconcileUsageWork(event: installedUsageEvent)
        await waitForUsageRefresh(database: database)
    }

    private func waitForUsageRefresh(database: IndexDatabase) async {
        while let task = usageWork.task {
            await task.value
            guard !terminating, self.database === database, !indexingPassActive else { return }
        }
    }

    private func performUsageRefresh(_ request: UsageRefreshRequest, worker: UUID, epoch: UUID) async {
        let database = request.database
        #if DEBUG
        let databaseGeneration = usageDatabaseGeneration
        #endif
        let rootReceipt = rootReceipt(for: database)
        let repairedFailure = request.repair ? rollupFailure : nil
        var readingSnapshot = false
        func isCurrent() -> Bool {
            !Task.isCancelled && !terminating && self.database === database
                && usageWork.worker?.id == worker && usageWork.epoch == epoch
                && usageWork.revision == request.revision && !indexingPassActive
                && pendingAttachment == nil && usageWork.pending == nil
        }
        #if DEBUG
        do {
            if let error = usageControlErrorForTesting { usageControlErrorForTesting = nil; throw error }
            if usageHoldRequestForUITesting == request.id,
               let delay = TraceTestHooks.delayMilliseconds(for: "TRACE_TEST_USAGE_ATTEMPT_HOLD_MS", cappedAt: 30_000) {
                usageHoldRequestForUITesting = nil
                try await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_USAGE_ATTEMPT_RELEASE_PATH",
                                                       timeoutMilliseconds: delay)
            }
        } catch is CancellationError { return }
        catch {
            guard isCurrent() else { return }
            usageControlFailuresForTesting.append(request.id)
            let identity = ["databaseGeneration": databaseGeneration.uuidString,
                "workerID": worker.uuidString, "requestID": request.id.uuidString]
            if let data = try? JSONSerialization.data(withJSONObject: identity),
               let line = String(data: data, encoding: .utf8) {
                TraceTestHooks.appendLine(line, pathKey: "TRACE_TEST_USAGE_CONTROL_FAILURE_PATH")
            }
            return
        }
        #endif
        do {
            if let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_USAGE_SNAPSHOT_DELAY_MS", cappedAt: 5_000,
                marker: .line("started", pathKey: "TRACE_TEST_USAGE_SNAPSHOT_STARTED_PATH")) {
                try await Task.sleep(for: .milliseconds(delay))
            }
            guard isCurrent() else { return }
            if request.repair { try await database.rebuildUsageRollupsIfDirty() }
            readingSnapshot = true
            let snapshot = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
            #if DEBUG
            if let gate = usageSnapshotGateForTesting {
                usageSnapshotWaitingForTesting = true
                await gate.value
                usageSnapshotWaitingForTesting = false
            }
            #endif
            guard isCurrent() else { return }
            completedUsageRevision += 1
            acknowledgeRootSummary(rootReceipt, usage: true)
            usageWork.repair = false
            usageWork.owed = false
            costsFailures = [:]
            publishCosts(.acceptedRefresh(snapshot), recovering: repairedFailure, onCommit: {
                #if DEBUG
                recordUsageAttempt(.init(databaseGeneration: databaseGeneration, workerID: worker,
                    requestID: request.id, outcome: .success))
                #endif
            })
        } catch is CancellationError {
            // Unaccepted debt remains; only pending demand or a new event resumes it.
        } catch {
            #if DEBUG
            if let gate = usageFailureGateForTesting {
                usageFailureWaitingForTesting = true
                await gate.value
                usageFailureWaitingForTesting = false
            }
            #endif
            guard isCurrent() else { return }
            // The database owns repair diagnostics; this layer owns snapshot reads.
            if readingSnapshot { recordCostsFailure(error, operation: .usageRefresh) }
            guard isCurrent() else { return }
            updateCosts({ $0.error = "Could not update token totals." }, onCommit: {
                #if DEBUG
                recordUsageAttempt(.init(databaseGeneration: databaseGeneration, workerID: worker,
                    requestID: request.id, outcome: .failure))
                #endif
            })
        }
    }

    #if DEBUG
    private func recordUsageAttempt(_ receipt: UsageAttemptReceipt) {
        usageAttemptReceiptsForTesting.append(receipt)
        if TraceTestHooks.isUITesting,
           let data = try? JSONEncoder().encode(receipt), let line = String(data: data, encoding: .utf8) {
            TraceTestHooks.appendLine(line, pathKey: "TRACE_TEST_ACCEPTED_USAGE_ATTEMPTS_PATH")
        }
    }
    #endif

    private func updateCostsTotalsUpdating() {
        let next = costsPresentation(costsState.value)
        if costsTotalsUpdating != next.updating || canRetryCosts != next.canRetry {
            updateCosts { _ in }
        }
    }

    func refreshDiagnostics() {
        Task { diagnosticsSnapshot = await diagnostics.value() }
    }

    func resetDiagnostics() {
        Task {
            try? await diagnostics.reset()
            diagnosticsSnapshot = await diagnostics.value()
        }
    }

    func exportDiagnostics(to url: URL) {
        Task { try? await diagnostics.export(to: url) }
    }

    func prepareToTerminate() async {
        terminating = true
        retireRebuildAdmission()
        updateCostsTotalsUpdating()
        knownSelectionProject = nil
        rollupFailure = nil
        invalidateTranscriptSettlement()
        invalidateTerminalSummaryRefresh()
        pendingRootSummaryRefresh = nil
        rootSynchronizationTask?.cancel()
        resetSidebarSummaryRecovery(clearFailure: true)
        summaryReadFailures = [:]
        costsFailures = [:]
        startupUsageRepairEnrolled = false
        pausedTranscriptPreservation = nil
        rebuildAttachmentReady = false
        sourceReloadAlertError = nil
        sourceReloadRecovery = .normal
        pendingAttachment = nil
        pendingSelectionCompletion = nil
        attachmentGeneration = UUID()
        transientTranscriptAbsence = nil
        cancelTranscriptRecovery()
        cancelPendingSelectionTranscriptRead()
        sessionRequestID = UUID()
        summaryRequestID = UUID()
        invalidateWatchers()
        sourceChangeTask?.cancel()
        sessionListTask?.cancel()
        sessionListTask = nil
        backgroundSidebarRequest = nil
        pendingSidebarAction = nil
        searchVisibilityTask?.cancel()
        searchVisibilityTask = nil
        incrementalProgressTask?.cancel()
        incrementalProgressTask = nil
        pendingIncrementalProgress = nil
        resetUsageRefreshWork()
        globalSearchSurfaces.removeAll()
        mainWindowVisible = false
        mainSearchPanelVisible = false
        globalSearch.suspendForNavigation()
        mainSearch.suspendForNavigation()
        cancelAutomaticSearch()
        invalidateSidebarRevealRequest()
        if let timeZoneObserver {
            NotificationCenter.default.removeObserver(timeZoneObserver)
            self.timeZoneObserver = nil
        }
        _ = try? await rootSynchronizationTask?.value
        rootSynchronizationTask = nil
        rootSynchronizationID = nil
        await watcherTeardownTask?.value
        await schedulerTeardownTask?.value
        schedulerTeardownTask = nil
        await scheduler?.stop()
        try? await diagnostics.markCleanShutdown()
    }

    private func makeSources() async -> [any SessionSource] {
        #if DEBUG
        if let sources = sourceReloadSourcesForTesting { return sources }
        #endif
        let testDirectory = TraceRuntime.testDirectory
        let additionalClaudeRoots = settings.additionalClaudeRoots
        let useConfiguredTestRoots = ProcessInfo.processInfo.environment[
            "TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"
        ] == "1"
        return await Task.detached(priority: .userInitiated) { () -> [any SessionSource] in
            if let directory = testDirectory {
                let roots = directory.appendingPathComponent("Sources")
                let claudeRoots = [roots.appendingPathComponent("Claude")]
                    + (useConfiguredTestRoots
                        ? additionalClaudeRoots.map { URL(fileURLWithPath: $0) } : [])
                return [ClaudeCodeSource(roots: claudeRoots),
                        CodexSource(root: roots.appendingPathComponent("Codex")),
                        GeminiSource(root: roots.appendingPathComponent("Gemini"))]
            }
            let defaultClaude = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
            let custom = additionalClaudeRoots.map { URL(fileURLWithPath: $0) }
            return [ClaudeCodeSource(roots: [defaultClaude] + custom),
                    CodexSource(), GeminiSource()]
        }.value
    }

    private func watcherOwnerIsCurrent(_ owner: WatcherOwner) -> Bool {
        attachmentIsCurrent(database: owner.database, generation: owner.attachment)
            && owner.revision == sourceConfigurationRevision && pendingAttachment == nil
    }

    private func watcherStartupIsCurrent(_ startup: WatcherStartup) -> Bool {
        watcherStartup === startup && startup.generation == watcherGeneration
            && watcherOwnerIsCurrent(startup.owner)
    }

    private func watcherReadyIsCurrent(_ receipt: WatcherReceipt) -> Bool {
        guard let startup = watcherStartup, startup.receipt == receipt, startup.ready else { return false }
        return watcherStartupIsCurrent(startup)
    }

    private func watcherDeferralIsCurrent(_ receipt: WatcherReceipt) -> Bool {
        guard !settings.onboardingComplete, let startup = watcherStartup,
              startup.receipt == receipt, startup.phase == .deferred else { return false }
        return watcherStartupIsCurrent(startup)
    }

    private func deferWatcherStartup(_ startup: WatcherStartup) -> WatcherStartOutcome {
        guard watcherStartupIsCurrent(startup), !settings.onboardingComplete else { return .superseded }
        let generation = beginWatcherConfiguration()
        guard watcherOwnerIsCurrent(startup.owner), generation == watcherGeneration,
              !settings.onboardingComplete else { return .superseded }
        let deferred = WatcherStartup(owner: startup.owner, generation: generation, forceRootReconciliation: true)
        deferred.phase = .deferred
        watcherStartup = deferred
        initialIndexRequested = false
        bufferedSourceChanges = SourceChanges()
        watcherStartupPending = true
        TraceTestHooks.touch(pathKey: "TRACE_TEST_WATCHER_DEFERRED_PATH")
        return .deferredByOnboarding(deferred.receipt)
    }

    private func checkedWatcherOutcome(_ outcome: WatcherStartOutcome) async -> WatcherStartOutcome {
        #if DEBUG
        if let gate = watcherOutcomeGateForTesting {
            watcherOutcomeWaitingForTesting = true
            await gate.value
            watcherOutcomeWaitingForTesting = false
        }
        #endif
        guard !Task.isCancelled else { return .superseded }
        switch outcome {
        case .started(let receipt):
            guard watcherReadyIsCurrent(receipt) else { return .superseded }
            if !settings.onboardingComplete, let startup = watcherStartup { return deferWatcherStartup(startup) }
        case .deferredByOnboarding(let receipt):
            guard watcherDeferralIsCurrent(receipt) else { return .superseded }
        case .superseded: break
        }
        return outcome
    }

    private func startWatching(
        _ sources: [any SessionSource], forceRootReconciliation: Bool = false
    ) async -> WatcherStartOutcome {
        guard !terminating, !Task.isCancelled, let database else { return .superseded }
        let owner = WatcherOwner(database: database, attachment: attachmentGeneration,
                                 revision: sourceConfigurationRevision)
        guard watcherOwnerIsCurrent(owner) else { return .superseded }
        let current = watcherStartup.flatMap { watcherStartupIsCurrent($0) ? $0 : nil }
        guard settings.onboardingComplete else {
            if let current {
                if current.phase == .deferred { return .deferredByOnboarding(current.receipt) }
                return deferWatcherStartup(current)
            }
            let deferred = WatcherStartup(owner: owner, generation: watcherGeneration, forceRootReconciliation: true)
            deferred.phase = .deferred
            watcherStartup = deferred
            return .deferredByOnboarding(deferred.receipt)
        }
        let retryFailedMonitoring = current.map { $0.ready && $0.hasTranscriptRoots && watchers.isEmpty } ?? false
        let force = forceRootReconciliation || sourceReloadActivation == owner
            || retryFailedMonitoring || current?.phase == .deferred
        if let startup = current {
            if startup.ready, !retryFailedMonitoring, !force || startup.forceRootReconciliation {
                return .started(startup.receipt)
            }
            if startup.phase == .preparing, let task = startup.task {
                startup.forceRootReconciliation = startup.forceRootReconciliation || force
                return await checkedWatcherOutcome(await task.value)
            }
        }
        liveWatcherReplayStarts = [:]
        let startup = WatcherStartup(owner: owner, generation: beginWatcherConfiguration(),
                                     forceRootReconciliation: force)
        guard watcherOwnerIsCurrent(owner), startup.generation == watcherGeneration else { return .superseded }
        if retryFailedMonitoring || current?.phase == .deferred { initialIndexRequested = false }
        watcherStartup = startup
        let task = Task { [weak self] in
            defer { startup.task = nil }
            guard let self else { return WatcherStartOutcome.superseded }
            return await self.configureWatchers(sources, startup: startup)
        }
        startup.task = task
        return await checkedWatcherOutcome(await task.value)
    }

    private func configureWatchers(_ sources: [any SessionSource], startup: WatcherStartup) async -> WatcherStartOutcome {
        let database = startup.owner.database
        let generation = startup.generation
        #if DEBUG
        watcherStartCountForTesting += 1
        if let gate = watcherPreparationGateForTesting {
            watcherPreparationWaitingForTesting = true
            await gate.value
            watcherPreparationWaitingForTesting = false
        }
        #endif
        await watcherTeardownTask?.value
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        let roots = sources.flatMap(\.roots).map(\.scanURL)
        startup.hasTranscriptRoots = !roots.isEmpty
        let metadataRoots = sources.filter { $0.agent == .codex }
            .flatMap(\.roots).map { $0.url.deletingLastPathComponent() }
        let (sidecarMapping, canonicalRoots) = await Task.detached(priority: .utility) {
            (CodexMetadataSidecarMapping(metadataDirectories: metadataRoots),
             roots.map { TraceFileIO.canonicalPath($0.path) })
        }.value
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        var reconciliationPaths = startup.forceRootReconciliation
            ? Set(canonicalRoots.map(\.path))
            : []

        let statistics = try? await database.statistics()
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        let hasCachedIndex = (statistics?.sourceFileCount ?? 0) > 0
        var grouped: [String: [URL]] = [:]
        for root in roots {
            let volumeID = Self.volumeIdentifier(for: root)
            let groupingID = watcherGroupingPolicy.groupIdentifier(
                for: root, volumeIdentifier: volumeID
            )
            grouped[groupingID, default: []].append(root)
        }
        var configurations: [(id: String, roots: [URL], checkpoint: UInt64?)] = []
        for (groupingID, groupRoots) in grouped.sorted(by: { $0.key < $1.key }) {
            let persistedCheckpoint = try? await database.eventCheckpoint(volumeID: groupingID)
            let checkpoint = persistedCheckpoint ?? liveWatcherReplayStarts[groupingID]
            guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
            if checkpoint == nil {
                let sourcePaths = groupRoots.map { TraceFileIO.canonicalPath($0.path) }
                    .filter { candidate in canonicalRoots.contains { $0.comparisonKey == candidate.comparisonKey } }
                    .map(\.path)
                reconciliationPaths.formUnion(sourcePaths)
            }
            TraceTestHooks.appendLine(
                "\(groupingID),persisted=\(String(describing: persistedCheckpoint)),replay=\(String(describing: checkpoint)),reconcile=\(reconciliationPaths.sorted())",
                pathKey: "TRACE_TEST_WATCHER_RECONFIG_AUDIT_PATH"
            )
            configurations.append((groupingID, groupRoots, checkpoint))
        }

        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        watchedSourceRoots = canonicalRoots.map { URL(fileURLWithPath: $0.path) }
        watcherStartupPending = true
        bufferedSourceChanges = SourceChanges()
        startupReconciliationPaths = reconciliationPaths
        let replacements = configurations.map { configuration in
            (configuration, FSEventsWatcher(
                roots: configuration.roots, identifier: configuration.id,
                sinceWhen: configuration.checkpoint
            ) { [weak self] changes in
                Task { @MainActor [weak self] in
                    guard let self, self.settings.onboardingComplete,
                          self.watcherGeneration == generation else { return }
                    for (identifier, eventID) in changes.watermarks
                        where self.liveWatcherReplayStarts[identifier] == nil {
                        self.liveWatcherReplayStarts[identifier] = eventID
                    }
                    var relevant = changes
                    // These streams cover transcript roots only. Metadata callbacks
                    // already arrive filtered and mapped from their utility queue.
                    relevant.paths = Set(changes.paths.filter { path in
                        let canonical = TraceFileIO.canonicalPath(path)
                        return canonicalRoots.contains { $0.contains(canonical) }
                    })
                    relevant.reconciliationPaths = []
                    for path in changes.reconciliationPaths {
                        let changed = TraceFileIO.canonicalPath(path)
                        for root in canonicalRoots where root.intersects(changed) {
                            relevant.reconciliationPaths.insert(changed.contains(root) ? root.path : changed.path)
                        }
                    }
                    guard !relevant.paths.isEmpty || relevant.requiresReconciliation
                        || !relevant.watermarks.isEmpty else { return }
                    if self.watcherStartupPending { self.bufferedSourceChanges.merge(relevant) }
                    else { await self.submitSourceChanges(relevant) }
                }
            })
        }
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        var started: [FSEventsWatcher] = []
        var failedRoots: [URL] = []
        for (configuration, watcher) in replacements {
            #if DEBUG
            let didStart = !failsWatcherStartForTesting && watcher.start()
            #else
            let didStart = watcher.start()
            #endif
            if didStart { started.append(watcher) }
            else { failedRoots += configuration.roots }
        }
        watchers = started
        let metadataWatcher = CodexMetadataWatcher(metadataDirectories: metadataRoots, mapping: sidecarMapping) {
            [weak self] changes, diagnostics in
            Task { @MainActor [weak self] in
                guard let self, self.watcherGeneration == generation else { return }
                self.metadataMonitoringWarnings = diagnostics
                self.updateMonitoringWarnings()
                if self.watcherStartupPending { self.bufferedSourceChanges.merge(changes) }
                else if changes.hasIndexWork { await self.submitSourceChanges(changes) }
            }
        }
        self.metadataWatcher = metadataWatcher
        TraceTestHooks.appendLine("enter,generation=\(generation),revision=\(sourceConfigurationRevision)", pathKey: "TRACE_TEST_METADATA_START_AUDIT_PATH")
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        await metadataWatcher.start()
        #if DEBUG
        if let gate = watcherReadinessGateForTesting {
            watcherReadinessWaitingForTesting = true
            await gate.value
            watcherReadinessWaitingForTesting = false
        }
        #endif
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        guard settings.onboardingComplete else { return deferWatcherStartup(startup) }
        // A coalesced caller may strengthen reconciliation while preparation is suspended.
        if startup.forceRootReconciliation {
            startupReconciliationPaths.formUnion(canonicalRoots.map(\.path))
        }
        TraceTestHooks.appendLine("started,generation=\(generation),revision=\(sourceConfigurationRevision)", pathKey: "TRACE_TEST_METADATA_START_AUDIT_PATH")
        if !failedRoots.isEmpty {
            let failedCanonical = failedRoots.map { TraceFileIO.canonicalPath($0.path) }
            startupReconciliationPaths.formUnion(canonicalRoots.compactMap { root in
                failedCanonical.contains(where: { $0.intersects(root) }) ? root.path : nil
            })
            sourceMonitoringWarnings = ["Some source folders could not be monitored; periodic reconciliation remains active."]
            updateMonitoringWarnings()
        }
        guard watcherStartupIsCurrent(startup), !Task.isCancelled else { return .superseded }
        guard settings.onboardingComplete else { return deferWatcherStartup(startup) }
        startupActivity = Self.startupActivity(
            hasCachedIndex: hasCachedIndex, forceRootReconciliation: startup.forceRootReconciliation,
            reconciliationPaths: startupReconciliationPaths)
        startup.phase = .ready
        return .started(startup.receipt)
    }

    private static func startupActivity(
        hasCachedIndex: Bool, forceRootReconciliation: Bool,
        reconciliationPaths: Set<String>
    ) -> IndexActivity {
        guard !reconciliationPaths.isEmpty else { return .cachedLaunch }
        guard hasCachedIndex else { return .initialBuild }
        return forceRootReconciliation ? .rootRecovery : .launchReconciliation
    }

    private static func recoveryActivity(
        for recovery: IndexRecoveryWork, sources: [any SessionSource]
    ) -> IndexActivity {
        let rootKeys = Set(sources.flatMap(\.roots).map {
            TraceFileIO.canonicalPath($0.scanURL.path).comparisonKey
        })
        let includesRoot = recovery.reconciliationPaths.contains {
            rootKeys.contains(TraceFileIO.canonicalPath($0).comparisonKey)
        }
        return includesRoot ? .rootRecovery : .subtreeRecovery
    }

    private func submitSourceChanges(_ changes: SourceChanges) async {
        guard let scheduler else { return }
        TraceTestHooks.appendLine(
            "paths=\(changes.paths.sorted()),reconcile=\(changes.reconciliationPaths.sorted()),reasons=\(changes.recoveryReasons.map(\.rawValue).sorted())",
            pathKey: "TRACE_TEST_WATCHER_RECONFIG_AUDIT_PATH"
        )
        await scheduler.request(
            paths: changes.paths,
            reconciliationPaths: changes.reconciliationPaths,
            scope: settings.indexScope,
            activity: changes.hasIndexWork ? activity(for: changes) : .fileChanges,
            watermarks: changes.watermarks,
            streamRoots: changes.streamRoots
        )
        TraceTestHooks.appendLine(
            changes.paths.sorted().joined(separator: "\n"),
            pathKey: "TRACE_TEST_SOURCE_CHANGES_AUDIT_PATH"
        )
    }

    private func activity(for changes: SourceChanges) -> IndexActivity {
        guard changes.requiresReconciliation else {
            return changes.historyDone ? .launchCatchUp : .fileChanges
        }
        if changes.recoveryReasons.contains(.eventsDropped)
            || changes.recoveryReasons.contains(.eventIDsWrapped) { return .eventStreamRecovery }
        if changes.recoveryReasons.contains(.rootChanged) { return .rootRecovery }
        if changes.requiresReconciliation { return .subtreeRecovery }
        return changes.historyDone ? .launchCatchUp : .fileChanges
    }

    private func beginWatcherConfiguration() -> UInt64 {
        watcherStartup?.task?.cancel()
        watcherStartup = nil
        watcherGeneration &+= 1
        let retiring = watchers
        let retiringMetadata = metadataWatcher
        let previousTeardown = watcherTeardownTask
        watchers = []
        metadataWatcher = nil
        monitoringWarnings = []
        metadataMonitoringWarnings = []
        sourceMonitoringWarnings = []
        watcherTeardownTask = Task.detached(priority: .utility) {
            await previousTeardown?.value
            retiring.forEach { $0.stop() }
            retiringMetadata?.stop()
        }
        safetyVerificationTask?.cancel()
        safetyVerificationTask = nil
        return watcherGeneration
    }

    private func updateMonitoringWarnings() {
        let warnings = Array(Set(metadataMonitoringWarnings + sourceMonitoringWarnings)).sorted()
        if monitoringWarnings != warnings { monitoringWarnings = warnings }
    }

    private func invalidateWatchers() {
        sourceReloadActivation = nil
        _ = beginWatcherConfiguration()
        watchedSourceRoots = []
        liveWatcherReplayStarts = [:]
        watcherStartupPending = true
        bufferedSourceChanges = SourceChanges()
    }

    private func startSafetyVerificationLoop() {
        guard safetyVerificationTask == nil, database != nil, scheduler != nil else { return }
        let generation = watcherGeneration
        safetyVerificationTask = Task { [weak self] in
            guard let self else { return }
            await self.runSafetyVerificationLoop(generation: generation)
            if self.watcherGeneration == generation {
                self.safetyVerificationTask = nil
            }
        }
    }

    private func runSafetyVerificationLoop(generation: UInt64) async {
        let day = Int64(TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SAFETY_INTERVAL_MS"
        ) ?? 24 * 60 * 60 * 1_000)
        let startupDelay = Int64(TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SAFETY_START_DELAY_MS"
        ) ?? 3_000)
        let retryDelay = Int64(TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SAFETY_RETRY_DELAY_MS"
        ) ?? 15 * 60 * 1_000)
        var firstDueCheck = true
        var retryNotBefore: Int64?

        while !Task.isCancelled, generation == watcherGeneration {
            guard let database, let scheduler else { return }
            let lastSuccess = try? await database.lastSafetyReconciliationMilliseconds()
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            var dueAt = lastSuccess.map { $0 + day } ?? now
            if let retryNotBefore { dueAt = max(dueAt, retryNotBefore) }
            var delay = max(0, dueAt - now)
            if firstDueCheck, delay == 0 { delay = startupDelay }
            firstDueCheck = false
            if delay > 0 {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
            }
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            await scheduler.waitUntilIdle()
            guard !Task.isCancelled, generation == watcherGeneration else { return }

            let refreshedLast = try? await database.lastSafetyReconciliationMilliseconds()
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            let refreshedNow = Int64(Date().timeIntervalSince1970 * 1_000)
            if let refreshedLast, refreshedNow - refreshedLast < day {
                retryNotBefore = nil
                continue
            }

            let before = refreshedLast
            await scheduler.request(
                reconciliationPaths: Set(watchedSourceRoots.map {
                    TraceFileIO.canonicalPath($0.path).path
                }),
                scope: settings.indexScope,
                activity: .safetyVerification
            )
            await scheduler.waitUntilIdle()
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            let after = try? await database.lastSafetyReconciliationMilliseconds()
            if after == before {
                retryNotBefore = Int64(Date().timeIntervalSince1970 * 1_000) + retryDelay
            } else {
                retryNotBefore = nil
            }
        }
    }

    private static func volumeIdentifier(for url: URL) -> String {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        if let identifier = try? candidate.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString { return identifier }
        var info = stat()
        if stat(candidate.path, &info) == 0 { return "device-\(TraceFileIO.unsignedDevice(info.st_dev))" }
        return "volume-unknown"
    }

    private func invalidateTerminalSummaryRefresh() {
        pendingFullSummaryRefresh = nil
        terminalSummaryTaskID = nil
        terminalSummaryTask?.cancel()
        terminalSummaryTask = nil
    }

    private func summaryRefreshIsCurrent(_ owner: SummaryRefreshOwner) -> Bool {
        !terminating && database === owner.database && attachmentGeneration == owner.attachment
            && sourceConfigurationRevision == owner.configuration && summaryRequestID == owner.id
    }

    private func terminalSummaryTranscriptIsCurrent(_ receipt: TerminalSummaryReceipt?) -> Bool {
        guard let receipt else { return !terminating }
        return !terminating && database === receipt.database && attachmentGeneration == receipt.attachment
            && sourceConfigurationRevision == receipt.configuration
            && indexWorkflow.generation == receipt.workflow && !indexWorkflow.isActive
    }

    @discardableResult
    private func refreshTerminalSummaries(_ reconciliation: ProjectReconciliationMode, usageEvent: UInt64) -> Task<Void, Never>? {
        guard !terminating, let database else { return nil }
        let receipt = TerminalSummaryReceipt(database: database, attachment: attachmentGeneration,
            configuration: sourceConfigurationRevision, workflow: indexWorkflow.generation, reconciliation: reconciliation, usageEvent: usageEvent)
        pendingFullSummaryRefresh = receipt
        let owner = SummaryRefreshOwner(database: database, attachment: attachmentGeneration,
                                        configuration: sourceConfigurationRevision)
        // Reserve the request before spawning work, so a newer summary can inherit
        // the full tail without an older queued task superseding it on startup.
        summaryRequestID = owner.id
        terminalSummaryTask?.cancel()
        terminalSummaryTaskID = owner.id
        terminalSummaryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if terminalSummaryTaskID == owner.id {
                    terminalSummaryTaskID = nil
                    terminalSummaryTask = nil
                }
            }
            guard !Task.isCancelled, summaryRefreshIsCurrent(owner) else { return }
            await reloadSummaries(owner: owner, terminal: receipt)
        }
        return terminalSummaryTask
    }

    private func reloadSummaries(
        lightweight: Bool = false,
        loadCosts: Bool = true,
        projectReconciliation: ProjectReconciliationMode = .ongoing,
        owner: SummaryRefreshOwner? = nil,
        terminal: TerminalSummaryReceipt? = nil,
        sidebarReadContext: SidebarReadContext = .ordinary,
        usageEvent suppliedUsageEvent: UInt64? = nil
    ) async {
        guard let database else { return }
        let owner = owner ?? SummaryRefreshOwner(database: database, attachment: attachmentGeneration,
                                                 configuration: sourceConfigurationRevision)
        if terminal == nil { summaryRequestID = owner.id }
        let refresh = owner.id
        let fullReceipt = pendingFullSummaryRefresh
        let rootReceipt = rootReceipt(for: database)
        let fullRefresh = !lightweight || fullReceipt != nil
        let usageEvent = suppliedUsageEvent ?? terminal?.usageEvent ?? fullReceipt?.usageEvent
            ?? (sidebarReadContext == .startup ? installedUsageEvent : pendingAttachment?.usageEvent)
            ?? (fullRefresh ? newUsageRecoveryEvent() : nil)
        func isCurrent() -> Bool {
            !Task.isCancelled && summaryRefreshIsCurrent(owner)
        }
        func transcriptIsCurrent() -> Bool {
            isCurrent() && terminalSummaryTranscriptIsCurrent(terminal)
        }
        func currentReconciliation() -> ProjectReconciliationMode {
            if let receipt = terminal ?? fullReceipt {
                return receipt.workflow == indexWorkflow.generation && !indexWorkflow.isActive
                    ? receipt.reconciliation : .ongoing
            }
            if let saved = savedSidebarReconciliation() { return saved }
            return projectReconciliation
        }
        guard isCurrent() else { return }
        if fullRefresh { reconcileUsageWork(event: usageEvent) }
        guard isCurrent() else { return }
        while let sessionListTask {
            await sessionListTask.value
            guard isCurrent() else { return }
        }
        guard isCurrent() else { return }
        let projectCanonicalKey = selectedProjectCanonicalKey
        let projectRequest = UUID()
        projectRequestID = projectRequest
        backgroundSidebarRequest = projectRequest
        defer { finishBackgroundSidebarRequest(projectRequest) }
        let ensuredSessionID = selectedSessionID
        let dataGeneration = sidebarDataGeneration
        let selectedSessionRequest = sessionRequestID
        let pageCount = sessionListProjectKey == projectCanonicalKey
            ? max(loadedSessionPageCount, pageState.read(\.requestedDepth)) : 1
        let sidebar: SidebarSnapshot?
        let sidebarError: Error?
        do {
            #if DEBUG
            if owner.failsSidebarForTesting {
                throw DatabaseError(resultCode: .SQLITE_BUSY, message: "Synthetic owned sidebar failure")
            }
            if failSidebarReadForUITesting {
                failSidebarReadForUITesting = false
                throw DatabaseError(resultCode: .SQLITE_BUSY, message: "Synthetic sidebar failure")
            }
            if sidebarReadContext == .startup,
               TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_STARTUP_SIDEBAR_LOAD_ONCE") {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_STARTUP_SIDEBAR_FAILURE_CONSUMED_PATH")
                throw DatabaseError(resultCode: .SQLITE_BUSY, message: "Synthetic startup sidebar load failure")
            }
            #endif
            let snapshot = try await database.sidebarSnapshot(
                projectCanonicalKey: projectCanonicalKey, pageCount: pageCount, ensuringSessionID: ensuredSessionID)
            #if DEBUG
            guard isCurrent() else { return }
            if let gate = owner.sidebarGateForTesting {
                heldSidebarSummaryIDsForTesting.append(owner.id)
                await gate.value
            }
            if owner.holdsSidebarForUITesting {
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_SUMMARY_PAGE_HOLD_MS", cappedAt: 30_000) {
                    if writeSidebarMarker(owner.id, path: TraceTestHooks.environment["TRACE_TEST_SUMMARY_PAGE_STARTED_PATH"]) {
                        try await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_SUMMARY_PAGE_RELEASE_PATH",
                                                               timeoutMilliseconds: delay)
                    }
                }
            }
            if let path = sidebarMarkerPathForTesting { _ = writeSidebarMarker(owner.id, path: path) }
            #endif
            sidebar = snapshot
            sidebarError = nil
        } catch {
            sidebar = nil
            sidebarError = error
        }
        #if DEBUG
        if let gate = summarySidebarGateForTesting {
            summarySidebarWaitingForTesting = true
            await gate.value
            summarySidebarWaitingForTesting = false
        }
        #endif
        let loadedProjects = sidebar?.projects
        let loadedRecent = sidebar?.recentSessions ?? recentSessions
        let loadedSessions = sidebar?.sessionList
        guard isCurrent() else { return }
        if let sidebarError, !(sidebarError is CancellationError) {
            let reconciliation = currentReconciliation()
            let startedAt = currentSidebarSummaryFailure?.startedAt ?? clock.now
            sidebarSummaryFailure = .init(database: database,
                workflow: indexWorkflow.generation, configuration: sourceConfigurationRevision,
                reconciliation: reconciliation, startedAt: startedAt)
            if fullRefresh || startedAt.duration(to: clock.now) >= .seconds(1) {
                let message = "Could not refresh projects. Try again."
                if sidebarSummaryError != message {
                    sidebarSummaryError = message
                }
            }
            guard isCurrent() else { return }
            recordSummaryReadFailure(sidebarError, operation: .sidebar)
            guard isCurrent() else { return }
        }
        let reconciliation = currentReconciliation()
        let globalProjectFilterReconciliation: SessionSearchModel.ProjectFilterReconciliation
        let mainProjectFilterReconciliation: SessionSearchModel.ProjectFilterReconciliation
        if let loadedProjects {
            globalProjectFilterReconciliation = globalSearch.resolveProjectFilter(
                in: loadedProjects,
                missingProject: currentReconciliation().globalMissingProjectPolicy
            )
            guard isCurrent() else { return }
            mainProjectFilterReconciliation = mainSearch.resolveProjectFilter(
                in: loadedProjects,
                missingProject: currentReconciliation().mainMissingProjectPolicy,
                preservingResults: hasSearchReturnContext && !mainSearch.results.isEmpty
            )
            guard isCurrent() else { return }
            projects = loadedProjects
            guard isCurrent() else { return }
            reconcileSelectedProject(in: loadedProjects)
        } else {
            switch reconciliation {
            case .ongoing:
                globalProjectFilterReconciliation = .unchanged
                mainProjectFilterReconciliation = .unchanged
            case .completed, .terminalRetaining:
                // A failed summary read cannot establish that a canonical project was
                // deleted. Retain both filters, but do not leave either search blocked.
                globalProjectFilterReconciliation = globalSearch.resolveProjectFilter(
                    in: projects, missingProject: .retain
                )
                guard isCurrent() else { return }
                if currentReconciliation() == .ongoing {
                    mainProjectFilterReconciliation = .unchanged
                } else {
                    mainProjectFilterReconciliation = mainSearch.resolveProjectFilter(
                        in: projects, missingProject: .retain,
                        preservingResults: hasSearchReturnContext && !mainSearch.results.isEmpty
                    )
                }
            }
        }
        guard isCurrent() else { return }
        recentSessions = loadedRecent
        guard isCurrent() else { return }
        if loadedProjects != nil { acknowledgeRootSummary(rootReceipt, projects: true) }
        if globalProjectFilterReconciliation.requiresSearchRefresh,
           !globalSearch.query.isEmpty {
            globalSearchNeedsRefresh = true
            scheduleAutomaticSearch()
        }
        if mainProjectFilterReconciliation.requiresSearchRefresh,
           !mainSearch.query.isEmpty {
            if hasSearchReturnContext { mainSearch.markResultsStale() }
            else { mainSearchNeedsRefresh = true; scheduleAutomaticSearch() }
        }
        if selectedProjectCanonicalKey == projectCanonicalKey,
           projectRequestID == projectRequest,
           let loadedSessions {
            func pageIsCurrent() -> Bool {
                isCurrent() && projectRequestID == projectRequest && selectedProjectCanonicalKey == projectCanonicalKey
            }
            acceptSessionPages(loadedSessions, attempted: ensuredSessionID, depth: pageCount,
                               rootReceipt: rootReceipt, dataGeneration: dataGeneration, isCurrent: pageIsCurrent)
            guard isCurrent() else { return }
        }
        if loadedProjects != nil {
            pendingSidebarSummaryRetry = false
            if sidebarSummaryRetryOwner == nil, isRetryingSidebarSummary { isRetryingSidebarSummary = false }
            guard isCurrent() else { return }
            clearSidebarSummaryFailure()
            guard isCurrent() else { return }
        }
        finishBackgroundSidebarRequest(projectRequest)
        let loadedTranscript: SessionTranscriptSnapshot?
        if let ensuredSessionID, transcriptIsCurrent(),
           transcriptRequestIsCurrent(database: database, sessionID: ensuredSessionID, request: selectedSessionRequest, summary: refresh) {
            do {
                loadedTranscript = try await database.transcriptSnapshot(
                    sessionID: ensuredSessionID, knownSession: selectedSession, knownMessageCount: messages.count
                )
            } catch {
                loadedTranscript = nil
                #if DEBUG
                if let gate = summaryTranscriptFailureGateForTesting {
                    summaryTranscriptFailureWaitingForTesting = true
                    await gate.value
                    summaryTranscriptFailureWaitingForTesting = false
                }
                #endif
                if transcriptIsCurrent(), !(error is CancellationError),
                   transcriptRequestIsCurrent(database: database, sessionID: ensuredSessionID,
                                              request: selectedSessionRequest, summary: refresh) {
                    scheduleTranscriptRecovery(error: error.localizedDescription, database: database,
                                               sessionID: ensuredSessionID, request: selectedSessionRequest, summary: refresh)
                }
            }
        } else {
            loadedTranscript = nil
        }
        #if DEBUG
        if loadedTranscript != nil, let gate = summaryTranscriptGateForTesting {
            summaryTranscriptWaitingForTesting = true
            await gate.value
            summaryTranscriptWaitingForTesting = false
        }
        #endif
        if currentReconciliation() != .ongoing,
           let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_PROJECT_RECONCILIATION_DELAY_MS",
            cappedAt: 5_000,
            marker: .touch(pathKey: "TRACE_TEST_PROJECT_RECONCILIATION_STARTED_PATH")
           ) {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        guard isCurrent() else { return }
        if transcriptIsCurrent(), let sessionID = ensuredSessionID,
           let loadedTranscript,
           transcriptRequestIsCurrent(database: database, sessionID: sessionID,
                                      request: selectedSessionRequest, summary: refresh) {
            await refreshSelectedTranscript(loadedTranscript, database: database,
                                            sessionID: sessionID, request: selectedSessionRequest,
                                            summary: refresh, terminal: terminal)
        }
        if !fullRefresh || !isCurrent() { return }
        #if DEBUG
        if sidebarSummaryRetryOwner?.id == owner.id,
           let delay = TraceTestHooks.delayMilliseconds(
               for: "TRACE_TEST_SIDEBAR_RETRY_TAIL_HOLD_MS", cappedAt: 30_000,
               marker: .touch(pathKey: "TRACE_TEST_SIDEBAR_RETRY_TAIL_STARTED_PATH")) {
            try? await TraceTestHooks.waitForRelease(
                pathKey: "TRACE_TEST_SIDEBAR_RETRY_TAIL_RELEASE_PATH", timeoutMilliseconds: delay)
        }
        if let gate = summaryTailGateForTesting {
            summaryTailWaitingForTesting = true
            await gate.value
            summaryTailWaitingForTesting = false
        }
        #endif
        guard isCurrent() else { return }
        let loadedSourceHealth: Result<[SourceHealth], Error>
        do { loadedSourceHealth = .success(try await database.sourceHealth()) }
        catch { loadedSourceHealth = .failure(error) }
        guard isCurrent() else { return }
        let loadedStatistics: Result<IndexStatistics, Error>
        do { loadedStatistics = .success(try await database.statistics()) }
        catch { loadedStatistics = .failure(error) }
        #if DEBUG
        if let gate = summaryMetadataGateForTesting {
            summaryMetadataWaitingForTesting = true
            await gate.value
            summaryMetadataWaitingForTesting = false
        }
        #endif
        guard isCurrent() else { return }
        switch loadedSourceHealth {
        case .success(let health):
            summaryReadFailures[.sourceHealth] = nil
            sourceHealth = health
        case .failure(let error): recordSummaryReadFailure(error, operation: .sourceHealth)
        }
        guard isCurrent() else { return }
        switch loadedStatistics {
        case .success(let snapshot):
            summaryReadFailures[.statistics] = nil
            statistics = snapshot
        case .failure(let error): recordSummaryReadFailure(error, operation: .statistics)
        }
        guard isCurrent() else { return }
        if case .success = loadedStatistics { acknowledgeRootSummary(rootReceipt, statistics: true) }
        if case .success(let snapshot) = loadedStatistics {
            try? await diagnostics.recordIndexSize(bytes: snapshot.databaseBytes)
        }
        guard isCurrent() else { return }
        func restorationIsTerminal() -> Bool {
            !indexWorkflow.isActive
                && (indexWorkflow.terminalPhase != nil || [.complete, .failed].contains(progress.phase))
        }
        if mayRestoreSession {
            if let stored = settings.lastSessionID {
                let restored: Result<SessionSummary?, Error>
                do {
                    #if DEBUG
                    if TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_SESSION_RESTORATION_ONCE") {
                        TraceTestHooks.touch(pathKey: "TRACE_TEST_SESSION_RESTORATION_FAILED_PATH")
                        throw DatabaseError(resultCode: .SQLITE_BUSY, message: "Synthetic restoration failure")
                    }
                    #endif
                    restored = .success(try await database.session(id: stored))
                }
                catch { restored = .failure(error) }
                #if DEBUG
                if let gate = summaryRestorationGateForTesting {
                    summaryRestorationWaitingForTesting = true
                    await gate.value
                    summaryRestorationWaitingForTesting = false
                }
                #endif
                guard isCurrent() else { return }
                if mayRestoreSession, settings.lastSessionID == stored, selectedSessionID == nil {
                    switch restored {
                    case .success(.some):
                        summaryReadFailures[.restoration] = nil
                        selectSession(stored)
                    case .success(.none):
                        summaryReadFailures[.restoration] = nil
                        if restorationIsTerminal() { mayRestoreSession = false }
                    case .failure(let error):
                        // A failed lookup cannot confirm deletion. Keep restoration
                        // eligible for the next ordinary full summary refresh.
                        recordSummaryReadFailure(error, operation: .restoration)
                    }
                }
            } else if restorationIsTerminal() {
                mayRestoreSession = false
            }
        }
        guard isCurrent() else { return }
        if loadCosts { reloadCosts() }
        guard isCurrent() else { return }
        reconcileUsageWork(event: usageEvent)
        guard isCurrent() else { return }
        refreshDiagnostics()
        if let fullReceipt, pendingFullSummaryRefresh?.id == fullReceipt.id { pendingFullSummaryRefresh = nil }
        #if DEBUG
        guard isCurrent() else { return }
        let terminalReceipt = terminal ?? fullReceipt
        let terminalWorkflowID = terminalReceipt.flatMap {
            $0.workflow == indexWorkflow.generation && !indexWorkflow.isActive ? $0.workflow : nil
        }
        let completion = FullSummaryCompletion(summaryID: refresh, terminalWorkflowID: terminalWorkflowID,
            storedSessionID: settings.lastSessionID,
            mayRestoreSession: mayRestoreSession,
            selectedSessionID: selectedSessionID, selectedProjectCanonicalKey: selectedProjectCanonicalKey,
            loadedSessionPageCount: loadedSessionPageCount)
        fullSummaryCompletionForTesting = completion
        if TraceTestHooks.isUITesting,
           let path = TraceTestHooks.environment["TRACE_TEST_FULL_SUMMARY_COMPLETED_PATH"],
           let data = try? JSONEncoder().encode(completion) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
    }

    private func recordSummaryReadFailure(_ error: Error, operation: SummaryReadOperation) {
        guard !(error is CancellationError) else { return }
        let failure = DatabaseFailureDiagnostic(error)
        guard summaryReadFailures[operation, default: []].insert(failure).inserted else { return }
        failure.log(to: Self.summaryReadLog, operation: operation.rawValue)
        #if DEBUG
        summaryReadFailureForTesting?(.init(operation: operation, primaryCode: failure.primary, extendedCode: failure.extended))
        #endif
    }

    private func indexErrorMessage(_ error: Error, sourceReload: Bool = false, prefix: String = "") -> String {
        guard error is DatabaseError else { return prefix + error.localizedDescription }
        recordSummaryReadFailure(error, operation: sourceReload ? .sourceReload : .indexStatus)
        return sourceReload ? "Could not apply source settings. Try again." : "Could not update the index. Try again."
    }

    #if DEBUG
    @discardableResult
    private func writeSidebarMarker(_ summary: UUID, path: String?) -> Bool {
        guard let path else { return true }
        do {
            try Data(summary.uuidString.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            sidebarTestControlFailuresForTesting.append(summary)
            TraceTestHooks.appendLine(summary.uuidString + "|marker-write-failed", pathKey: "TRACE_TEST_SUMMARY_CONTROL_FAILURE_PATH")
            return false
        }
    }
    #endif

    private func recordCostsFailure(_ error: Error, operation: CostsFailureOperation) {
        guard !(error is CancellationError) else { return }
        recordCostsFailure(DatabaseFailureDiagnostic(error), operation: operation)
    }

    private func recordCostsFailure(_ failure: DatabaseFailureDiagnostic, operation: CostsFailureOperation) {
        guard costsFailures[operation, default: []].insert(failure).inserted else { return }
        failure.log(to: Self.costsLog, operation: operation.rawValue)
        #if DEBUG
        costsFailureForTesting?(.init(operation: operation, primaryCode: failure.primary, extendedCode: failure.extended))
        #endif
    }

    private func reconcileSelectedProject(in loadedProjects: [ProjectSummary]) {
        guard let selectedProjectCanonicalKey else {
            if selectedProjectID != nil { selectedProjectID = nil }
            if selectedProjectDisplayName != nil { selectedProjectDisplayName = nil }
            return
        }
        guard let project = loadedProjects.first(where: {
            $0.canonicalKey == selectedProjectCanonicalKey
        }) else {
            return
        }
        if selectedProjectID != project.id { selectedProjectID = project.id }
        if selectedProjectDisplayName != project.displayName {
            selectedProjectDisplayName = project.displayName
        }
    }

    private func loadPricing() {
        let candidates = [
            Bundle.main.url(forResource: "default-pricing", withExtension: "json", subdirectory: "Pricing"),
            Bundle.main.url(forResource: "default-pricing", withExtension: "json"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            pricingError = "Bundled pricing data is missing."
            return
        }
        do {
            let loaded = try PricingCatalog.load(bundledURL: url, overrideURL: TraceRuntime.testDirectory?.appendingPathComponent("pricing.json") ?? PricingCatalog.defaultOverrideURL())
            pricing = loaded.catalog
            pricingError = loaded.overrideError
        } catch {
            pricingError = error.localizedDescription
        }
    }

    private func costDateBounds() -> (from: String?, through: String?) {
        let calendar = Calendar.current
        let now = Date()
        let start: Date?
        switch settings.costRange {
        case .sevenDays: start = calendar.date(byAdding: .day, value: -6, to: now)
        case .thirtyDays: start = calendar.date(byAdding: .day, value: -29, to: now)
        case .yearToDate: start = calendar.date(from: calendar.dateComponents([.year], from: now))
        case .allTime: start = nil
        case .custom: start = customCostStart
        }
        let end = settings.costRange == .custom ? customCostEnd : now
        return (start.map(Self.dayFormatter.string), Self.dayFormatter.string(from: end))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
final class TraceEnvironment {
    static let shared = TraceEnvironment()
    let settings: AppSettings
    lazy var model = TraceModel(
        settings: settings,
        watcherGroupingPolicy: TraceTestHooks.isUITesting
            && TraceTestHooks.environment["TRACE_TEST_SPLIT_WATCHERS_BY_ROOT"] == "1"
            ? .byRoot
            : .byVolume,
        startupActivityObserver: { activity in
            TraceTestHooks.appendLine(
                activity.rawValue, pathKey: "TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"
            )
        }
    )
    private init() {
        let settings = AppSettings()
        if TraceTestHooks.isUITesting {
            let environment = TraceTestHooks.environment
            if environment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] == "1" {
                settings.onboardingComplete = true
            }
            if settings.additionalClaudeRoots.isEmpty,
               let encodedRoots = environment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"],
               let data = encodedRoots.data(using: .utf8),
               let roots = try? JSONDecoder().decode([String].self, from: data) {
                settings.additionalClaudeRoots = roots
            }
        }
        self.settings = settings
    }
}
