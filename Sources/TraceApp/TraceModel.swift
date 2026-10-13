import AppKit
import Clocks
import CryptoKit
import Darwin
import Foundation
import TraceCore

struct SidebarRevealRequest: Equatable {
    let token = UUID()
    let projectCanonicalKey: String
    let sessionID: Int64
}

enum SourceReloadRecoveryState: Equatable {
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
                    || (update.phase == .cancelled
                        && activePassID == nil)
            } else {
                supersededTerminal = false
            }

            if passTerminal {
                if activePassID == update.passID { activePassID = nil }
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

    @Published private(set) var progress = IndexProgress(phase: .waiting)
    @Published private(set) var sourceReloadRecovery: SourceReloadRecoveryState = .normal
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var totalSessionCount = 0
    @Published private(set) var hasMoreSessions = false
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var sessionListError: String?
    @Published private(set) var hasSearchReturnContext = false
    var mainSearchReturnAnchor: SearchResultAnchor?
    private struct MainSearchReturnContext {
        let projectID: Int64?
        let canonicalKey: String?
        let displayName: String?
    }
    private var mainSearchReturnContext: MainSearchReturnContext?
    private var sessionListProjectKey: String?
    private var loadedSessionPageCount = 1
    private var nextSessionCursor: SessionCursor?
    private typealias LoadedSessionPages = SessionListSnapshot
    private var sessionListTask: Task<Void, Never>?
    private enum SessionListRetry {
        case reload
        case nextPage
    }
    private var sessionListRetry: SessionListRetry?
    private var backgroundSidebarRequest: UUID?
    private enum PendingSidebarAction { case loadMore, retry(SessionListRetry) }
    private var pendingSidebarAction: (project: String?, action: PendingSidebarAction)?
    @Published private(set) var recentSessions: [SessionSummary] = []
    @Published private(set) var messages: [MessageSummary] = [] {
        didSet {
            transcriptMessageRevision &+= 1
            messageIdentities = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, MessageIdentity($0)) })
        }
    }
    @Published private(set) var hydratedMessages: [Int64: HydratedMessage] = [:] {
        didSet { transcriptContentRevision &+= 1 }
    }
    @Published private(set) var hydrationFailures: [Int64: String] = [:] {
        didSet { transcriptContentRevision &+= 1 }
    }
    @Published var projectFilter = ""
    @Published private(set) var selectedSession: SessionSummary?
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var usage: [UsageRollup] = []
    @Published private(set) var costsTotalsUpdating = false
    @Published private(set) var statistics: IndexStatistics?
    @Published private(set) var diagnosticsSnapshot = DiagnosticsSnapshot()
    @Published private(set) var pricing: PricingCatalog?
    @Published private(set) var pricingError: String?
    @Published private(set) var costsError: String?
    @Published private(set) var selectedProjectID: Int64?
    @Published private(set) var selectedProjectCanonicalKey: String?
    @Published private(set) var selectedProjectDisplayName: String?
    @Published private(set) var sidebarRevealRequest: SidebarRevealRequest?
    @Published var selectedSessionID: Int64?
    @Published var customCostStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @Published var customCostEnd = Date()
    @Published var expandedReasoningIDs: Set<Int64> = [] {
        didSet { transcriptContentRevision &+= 1 }
    }
    @Published var startupError: String? {
        didSet { sourceReloadAlertError = nil }
    }
    private var sourceReloadAlertError: String?
    @Published private(set) var monitoringWarnings: [String] = []
    private var metadataMonitoringWarnings: [String] = []
    private var sourceMonitoringWarnings: [String] = []
    private(set) var transcriptMessageRevision = 0
    private(set) var transcriptContentRevision = 0

    private var database: IndexDatabase?
    private var coordinator: IndexCoordinator?
    @Published private var rebuildAttachmentReady = false
    @Published private var initialAttachmentFailure: String?
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
    }
    private var pendingAttachment: PendingAttachment?
    private var pendingRebuild = false
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
    private var completedUsage: [UsageRollup] = []
    private var completedUsageRevision = 0
    private var usageSnapshotRequestID = UUID()
    private var usageRefreshPending = false
    private var usageRepairPending = false
    private var deferredUsageRepairTask: Task<Void, Never>?
    private var indexWorkflow = IndexWorkflowState()
    private var indexingPassActive: Bool { indexWorkflow.isActive }
    private var lastAutomaticSearchRefresh: AnyClock<Duration>.Instant?
    private var lastObservedPassID: UUID?
    private var lastObservedMutationRevision = 0
    private var lastSearchedPassID: UUID?
    private var lastSearchedMutationRevision = 0
    private var timeZoneObserver: NSObjectProtocol?
    private var sessionRequestID = UUID()
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
    private struct TranscriptAbsence {
        let database: IndexDatabase
        let sessionID: Int64
        let requestID: UUID
        var paused = false
    }
    @Published private var transientTranscriptAbsence: TranscriptAbsence?
    // Selection preservation outlives the visible absence banner when recovery fails.
    private var pausedTranscriptPreservation: TranscriptAbsence?
    @Published private var transcriptReadError: String?
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
    var transcriptFeedback: TranscriptFeedback? { transcriptBanner?.feedback }
    var transcriptIsTemporarilyUnavailable: Bool {
        transcriptFeedback == .updating
    }
    var transcriptLoadError: String? { transcriptBanner?.details }
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
    }
    private struct TerminalSummaryReceipt {
        let id = UUID()
        let database: IndexDatabase
        let attachment: UUID
        let configuration: UInt64
        let workflow: UUID
        let reconciliation: ProjectReconciliationMode
    }
    private var pendingFullSummaryRefresh: TerminalSummaryReceipt?
    private var terminalSummaryTaskID: UUID?
    private var terminalSummaryTask: Task<Void, Never>?
    // Includes current reads awaiting row recovery or selection reconciliation.
    private var highestObservedTranscriptReadRevision: UInt64 = 0
    private var lastAppliedTranscriptReadRevision: UInt64 = 0
    private var projectRequestID = UUID()
    private var summaryRequestID = UUID()
    var scrollPositions: [Int64: TranscriptBookmark] = [:]
    @Published private(set) var scrollRequest = UUID()
    private(set) var requestedMessageID: Int64?
    private var mayRestoreSession = true
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
                              projectReconciliation: terminalProjectReconciliation ? .terminalRetaining : .ongoing)
    }

    func queueMainSearchRefreshForTesting() { mainSearchNeedsRefresh = true }
    var selectionTranscriptReadGateForTesting: Task<Void, Never>?
    var selectionTranscriptGateForTesting: Task<Void, Never>?
    var summaryTranscriptGateForTesting: Task<Void, Never>?
    var summaryTranscriptFailureGateForTesting: Task<Void, Never>?
    private(set) var summaryTranscriptFailureWaitingForTesting = false
    var summaryRestorationGateForTesting: Task<Void, Never>?
    private(set) var summaryRestorationWaitingForTesting = false
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
                let database = try await Task.detached(priority: .userInitiated) {
                    if isolatedURL != nil,
                       let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_INDEX_OPEN_DELAY_MS", cappedAt: 5_000
                       ) {
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                    let url = try isolatedURL ?? IndexDatabase.defaultURL()
                    return try IndexDatabase(url: url)
                }.value
                installDatabase(database)
                if database.contentWasResetOnOpen { prepareForIndexReset() }
                var sources: [any SessionSource] = []
                var configuredRevision = sourceConfigurationRevision
                while true {
                    let revision = sourceConfigurationRevision
                    let latestSources = await makeSources()
                    guard revision == sourceConfigurationRevision else { continue }
                    _ = try await database.synchronizeConfiguredRoots(
                        latestSources.flatMap(\.roots)
                    )
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
                        startupError = "Could not load pending index recovery; a safe root scan was queued: \(recoveryLoadError.localizedDescription)"
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
                        if self.indexingPassActive {
                            self.usageRepairPending = true
                            self.usageRefreshPending = true
                            self.updateCostsTotalsUpdating()
                            return
                        }
                        await self.refreshCompletedUsage(repairIfDirty: true)
                    }
                }
                loadPricing()
                await reloadSummaries(loadCosts: false)
                await loadCachedUsageAtStartup()
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_STARTUP_FINALIZATION_DELAY_MS", cappedAt: 30_000,
                    marker: .touch(pathKey: "TRACE_TEST_STARTUP_FINALIZATION_PATH")
                ) {
                    try await TraceTestHooks.waitForRelease(
                        pathKey: "TRACE_TEST_STARTUP_FINALIZATION_RELEASE_PATH",
                        timeoutMilliseconds: delay
                    )
                }
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
                            await self.refreshCompletedUsage(repairIfDirty: true)
                        }
                    }
                }
            } catch {
                guard !terminating, coordinator == nil else { return }
                initialAttachmentFailure = error.localizedDescription
                startupError = error.localizedDescription
                progress = .init(phase: .failed, error: error.localizedDescription)
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
        guard attachmentIsCurrent(database: database, generation: generation) else { return }
        #if DEBUG
        if let gate = schedulerProgressGateForTesting {
            schedulerProgressWaitingForTesting = true
            await gate.value
            schedulerProgressWaitingForTesting = false
        }
        #endif
        guard attachmentIsCurrent(database: database, generation: generation) else { return }
        await receiveProgress(update)
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
        guard attachmentIsCurrent(database: database, generation: generation) else { return }
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
        invalidateTranscriptSettlement()
        invalidateTerminalSummaryRefresh()
        let alreadyRetiring = pendingAttachment != nil
        let pending = PendingAttachment(database: database, configurationRevision: sourceConfigurationRevision,
                                        intent: intent)
        pendingAttachment = pending
        if case .failed(let error) = sourceReloadRecovery { sourceReloadRecovery = .retrying(error) }
        // Fence producers immediately, but keep the installed read dependencies usable.
        attachmentGeneration = UUID()
        incrementalProgressTask?.cancel()
        incrementalProgressTask = nil
        pendingIncrementalProgress = nil
        incrementalProgressVisible = false
        summaryRequestID = UUID()
        usageSnapshotRequestID = UUID()
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
        return pending
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
        updateCostsTotalsUpdating()
        settleTranscriptFeedback()
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
                failAttachment(pending, error: "Could not load source failures: \(error.localizedDescription)")
                return false
            }
        }
        guard pendingAttachmentIsCurrent(pending), !Task.isCancelled else {
            if Task.isCancelled { failAttachment(pending, phase: .cancelled) }
            return false
        }
        // No suspension during the commit: all readers switch databases together.
        installDatabase(database)
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
        updateCostsTotalsUpdating()
        initialAttachmentFailure = nil
        if !rebuildAttachmentReady { rebuildAttachmentReady = true }
        if pending.intent == .installation, pendingRebuild { rebuildIndex() }
        settleTranscriptFeedback()
        return true
    }

    private func installDatabase(_ database: IndexDatabase) {
        guard self.database !== database else { return }
        // A first installation must retain the saved session for startup restoration.
        if self.database != nil { prepareForIndexReset() }
        highestObservedTranscriptReadRevision = 0
        lastAppliedTranscriptReadRevision = 0
        self.database = database
    }

    func receiveProgress(_ update: IndexProgress) async {
        let attachment = attachmentGeneration, configuration = sourceConfigurationRevision
        let workflow = indexWorkflow.generation
        let disposition = indexWorkflow.receive(update)
        let receivedWorkflow = indexWorkflow.generation
        if workflow != indexWorkflow.generation { invalidateTranscriptSettlement() }
        if !disposition.passTerminal { resumePausedTranscriptFeedback() }
        if !disposition.passTerminal { usageSnapshotRequestID = UUID() }
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
                        guard let self, let pending = self.pendingIncrementalProgress else { return }
                        self.publishProgress(pending)
                        self.incrementalProgressVisible = true
                        self.incrementalProgressTask = nil
                    }
                }
            }
        } else if !disposition.supersededTerminal {
            publishProgress(update)
        }

        if disposition.passTerminal {
            handleTerminalUsageProgress(update, finalize: disposition.workflowTerminal)
        }
        else {
            if usageRepairPending, deferredUsageRepairTask != nil {
                deferredUsageRepairTask?.cancel()
                deferredUsageRepairTask = nil
            }
            updateCostsTotalsUpdating()
        }
        observeSearchMutation(update, terminal: disposition.workflowTerminal)

        let shouldRefresh = disposition.passTerminal
            || ((!update.incremental || incrementalProgressVisible)
                && lastSummaryRefresh.duration(to: clock.now) >= .milliseconds(250))
        if shouldRefresh {
            guard !terminating, attachment == attachmentGeneration,
                  configuration == sourceConfigurationRevision, receivedWorkflow == indexWorkflow.generation else { return }
            lastSummaryRefresh = clock.now
            if disposition.workflowTerminal {
                await refreshTerminalSummaries(disposition.projectReconciliation)?.value
            } else {
                await reloadSummaries(lightweight: true, projectReconciliation: disposition.projectReconciliation)
            }
        }
    }

    private func publishProgress(_ update: IndexProgress) {
        let generation = attachmentGeneration
        let activation = sourceReloadActivation
        progress = update
        guard !terminating, generation == attachmentGeneration else { return }
        guard let activation, activation == sourceReloadActivation,
              watcherOwnerIsCurrent(activation), let startup = watcherStartup,
              startup.owner == activation, startup.ready, watcherStartupIsCurrent(startup) else { return }
        sourceReloadActivation = nil
        if sourceReloadRecovery.isRetrying { sourceReloadRecovery = .normal }
    }

    private func handleTerminalUsageProgress(_ update: IndexProgress, finalize: Bool) {
        if let rollupError = update.rollupError {
            costsError = rollupError
            usageRepairPending = true
            usageRefreshPending = true
        }
        if update.phase != .complete && (update.indexChanged || update.rollupsChanged) {
            usageRepairPending = true
            usageRefreshPending = true
        }
        guard finalize else {
            updateCostsTotalsUpdating()
            return
        }
        if usageRepairPending {
            scheduleDeferredUsageRepair()
        } else if usageRefreshPending {
            scheduleCompletedUsageRefresh(repairIfDirty: false)
        } else if update.phase == .complete,
                  update.indexChanged || update.rollupsChanged {
            scheduleCompletedUsageRefresh(repairIfDirty: false)
        }
        updateCostsTotalsUpdating()
    }

    private func observeSearchMutation(_ update: IndexProgress, terminal: Bool) {
        if lastObservedPassID != update.passID {
            lastObservedPassID = update.passID
            lastObservedMutationRevision = 0
        }
        if update.mutationRevision > lastObservedMutationRevision {
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
            scheduleAutomaticSearch()
        }
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
            let requestedActivity: IndexActivity = rebuild ? .rebuild : activity
            #if DEBUG
            self.startupSubmissionCountForTesting += 1
            #endif
            self.startupActivityObserver(requestedActivity)
            await scheduler.request(
                paths: buffered.paths.union(recovery.filePaths),
                reconciliationPaths: self.startupReconciliationPaths
                    .union(buffered.reconciliationPaths)
                    .union(recovery.reconciliationPaths),
                rebuild: rebuild,
                scope: self.settings.indexScope,
                activity: requestedActivity,
                satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
                watermarks: buffered.watermarks,
                streamRoots: buffered.streamRoots
            )
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
        beginIndexReplacement()
        let generation = attachmentGeneration, revision = sourceConfigurationRevision
        Task {
            guard takePendingRebuild(generation: generation, revision: revision) else { return }
            await scheduler.request(rebuild: true, scope: settings.indexScope)
        }
    }

    /// Consume at handoff, before reset or suspension. Progress cannot acknowledge
    /// an outstanding request because another submission may already be queued.
    private func takePendingRebuild(generation: UUID, revision: UInt64) -> Bool {
        guard !terminating, pendingAttachment == nil, pendingRebuild,
              generation == attachmentGeneration, revision == sourceConfigurationRevision else { return false }
        pendingRebuild = false
        prepareForIndexReset()
        #if DEBUG
        rebuildSubmissionCountForTesting += 1
        #endif
        return true
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
        sourceReloadRecovery = .normal
        updateCostsTotalsUpdating()
        settleTranscriptFeedback()
    }

    func retrySourceConfiguration() {
        guard !terminating, settings.onboardingComplete, pendingAttachment == nil,
              case .failed(let error) = sourceReloadRecovery else { return }
        sourceReloadRecovery = .retrying(error)
        reloadSourcesAndRebuild()
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
                let rootsChanged = try await database.synchronizeConfiguredRoots(sources.flatMap(\.roots))
                guard !Task.isCancelled, pendingAttachmentIsCurrent(pending) else { return }
                if rootsChanged, self.database === database {
                    await reloadSummaries(
                        loadCosts: false, projectReconciliation: .completed
                    )
                }
            } catch {
                failAttachment(pending, error: "Could not update source folders: \(error.localizedDescription)")
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
        clearSession()
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

    func clearSession() {
        invalidateTranscriptSettlement()
        pausedTranscriptPreservation = nil
        pendingSelectionCompletion = nil
        mainSearchReturnContext = nil
        hasSearchReturnContext = false
        mainSearchReturnAnchor = nil
        mayRestoreSession = false
        invalidateSidebarRevealRequest()
        transientTranscriptAbsence = nil
        cancelTranscriptRecovery()
        cancelPendingSelectionTranscriptRead()
        sessionRequestID = UUID()
        selectedSessionID = nil
        selectedSession = nil
        settings.lastSessionID = nil
        messages = []
        hydratedMessages.removeAll()
        hydrationFailures.removeAll()
        hydrationOrder.removeAll()
        hydrationEpoch = UUID()
        hydratingMessageIDs.removeAll()
        expandedReasoningIDs.removeAll()
        requestedMessageID = nil
    }

    func consumeRequestedMessageID(_ messageID: Int64) {
        if requestedMessageID == messageID { requestedMessageID = nil }
    }

    private func prepareForIndexReset() {
        invalidateTranscriptSettlement()
        invalidateTerminalSummaryRefresh()
        pausedTranscriptPreservation = nil
        pendingSelectionCompletion = nil
        if let context = mainSearchReturnContext {
            selectedProjectCanonicalKey = context.canonicalKey
            selectedProjectDisplayName = context.displayName
        }
        mainSearchReturnContext = nil
        hasSearchReturnContext = false
        mainSearchReturnAnchor = nil
        resetSessionPagination()
        sessionListProjectKey = selectedProjectCanonicalKey
        cancelAutomaticSearch()
        deferredUsageRepairTask?.cancel()
        deferredUsageRepairTask = nil
        completedUsageRevision += 1
        usageSnapshotRequestID = UUID()
        usageRefreshPending = false
        usageRepairPending = false
        updateCostsTotalsUpdating()
        globalSearchNeedsRefresh = false
        mainSearchNeedsRefresh = false
        lastObservedPassID = nil
        lastSearchedPassID = nil
        lastObservedMutationRevision = 0
        lastSearchedMutationRevision = 0
        mayRestoreSession = false
        transientTranscriptAbsence = nil
        cancelTranscriptRecovery()
        cancelPendingSelectionTranscriptRead()
        sessionRequestID = UUID()
        projectRequestID = UUID()
        summaryRequestID = UUID()
        self.selectedProjectID = nil
        selectedSessionID = nil
        selectedSession = nil
        invalidateSidebarRevealRequest()
        settings.lastSessionID = nil
        projects = []
        sessions = []
        recentSessions = []
        messages = []
        hydratedMessages = [:]
        hydrationFailures = [:]
        hydrationOrder = []
        hydrationEpoch = UUID()
        hydratingMessageIDs = [:]
        expandedReasoningIDs = []
        scrollPositions = [:]
        requestedMessageID = nil
        sourceHealth = []
        statistics = nil
        globalSearch.resetForIndexReset(awaitsProjectResolution: true)
        mainSearch.resetForIndexReset(awaitsProjectResolution: true)
    }

    private func beginIndexReplacement() {
        invalidateTranscriptSettlement()
        indexWorkflow.beginReplacement()
        resumePausedTranscriptFeedback()
        usageSnapshotRequestID = UUID()
        deferredUsageRepairTask?.cancel()
        deferredUsageRepairTask = nil
        updateCostsTotalsUpdating()
    }

    func selectProject(_ projectID: Int64?) {
        if let projectID {
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            guard selectedProjectID != project.id
                    || selectedProjectCanonicalKey != project.canonicalKey else { return }
            clearSession()
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
        clearSession()
        self.selectedProjectID = nil
        selectedProjectCanonicalKey = nil
        selectedProjectDisplayName = nil
        searchMain()
        loadProjectSessions()
    }

    private func loadProjectSessions(ensuring ensuringSessionID: Int64? = nil) {
        if sessionListProjectKey != selectedProjectCanonicalKey { resetSessionPagination() }
        sessionListProjectKey = selectedProjectCanonicalKey
        let request = UUID()
        projectRequestID = request
        sessionListTask?.cancel()
        let key = selectedProjectCanonicalKey
        let pageCount = loadedSessionPageCount
        isLoadingSessions = true
        sessionListError = nil
        sessionListRetry = nil
        guard let database else { isLoadingSessions = false; sessionListTask = nil; return }
        sessionListTask = Task {
            defer { finishSessionListRequest(request) }
            do {
                let page = try await database.sessionListSnapshot(
                    projectCanonicalKey: key, pageCount: pageCount, ensuringSessionID: ensuringSessionID
                )
                guard projectRequestID == request, selectedProjectCanonicalKey == key else { return }
                applySessionPages(page)
            } catch is CancellationError { }
            catch {
                guard projectRequestID == request else { return }
                sessionListError = error.localizedDescription
                sessionListRetry = .reload
            }
        }
    }

    private func finishSessionListRequest(_ request: UUID) {
        guard projectRequestID == request else { return }
        isLoadingSessions = false
        sessionListTask = nil
        drainPendingSidebarAction()
    }

    private func finishBackgroundSidebarRequest(_ request: UUID) {
        guard backgroundSidebarRequest == request else { return }
        backgroundSidebarRequest = nil
        drainPendingSidebarAction()
    }

    private func drainPendingSidebarAction() {
        guard backgroundSidebarRequest == nil, !isLoadingSessions else { return }
        guard let pending = pendingSidebarAction else { return }
        pendingSidebarAction = nil
        guard pending.project == selectedProjectCanonicalKey else { return }
        switch pending.action {
        case .loadMore: loadMoreSessions()
        case .retry(.reload):
            // A successful background or explicit reload already satisfies this
            // intent. A failed read retains the current retry operation.
            if let retry = sessionListRetry { performSidebarRetry(retry) }
        case .retry(.nextPage): loadMoreSessions()
        }
    }

    private func resetSessionPagination() {
        backgroundSidebarRequest = nil
        pendingSidebarAction = nil
        sessionListTask?.cancel()
        sessionListTask = nil
        sessions = []
        totalSessionCount = 0
        nextSessionCursor = nil
        hasMoreSessions = false
        loadedSessionPageCount = 1
        sessionListError = nil
        sessionListRetry = nil
        isLoadingSessions = false
    }

    private func applySessionPages(_ page: LoadedSessionPages) {
        sessions = page.sessions
        totalSessionCount = page.totalCount
        nextSessionCursor = page.nextCursor
        hasMoreSessions = page.nextCursor != nil
        loadedSessionPageCount = page.pageCount
        sessionListError = nil
        sessionListRetry = nil
    }

    func retrySessionLoad() {
        guard let retry = sessionListRetry else { return }
        if backgroundSidebarRequest != nil {
            pendingSidebarAction = (selectedProjectCanonicalKey, .retry(retry))
            return
        }
        guard !isLoadingSessions else { return }
        performSidebarRetry(retry)
    }

    private func performSidebarRetry(_ retry: SessionListRetry) {
        switch retry {
        case .reload: loadProjectSessions(ensuring: selectedSessionID)
        case .nextPage: loadMoreSessions()
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
        projectRequestID = request
        isLoadingSessions = true
        sessionListError = nil
        sessionListRetry = nil
        sessionListTask = Task {
            defer { finishSessionListRequest(request) }
            do {
                let page = try await database.sessionsPage(projectCanonicalKey: key, cursor: cursor)
                #if DEBUG
                if let gate = sessionPageReadGateForTesting { await gate.value }
                #endif
                try Task.checkCancellation()
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_SESSION_PAGE_DELAY_MS", cappedAt: 5_000,
                    marker: .touch(pathKey: "TRACE_TEST_SESSION_PAGE_STARTED_PATH")
                ) {
                    try await Task.sleep(for: .milliseconds(delay))
                }
                guard projectRequestID == request, selectedProjectCanonicalKey == key else { return }
                let existing = Set(sessions.map(\.id))
                sessions.append(contentsOf: page.sessions.filter { !existing.contains($0.id) })
                sessions.sort { ($0.lastActivityMilliseconds, $0.id) > ($1.lastActivityMilliseconds, $1.id) }
                totalSessionCount = page.totalCount
                nextSessionCursor = page.nextCursor
                hasMoreSessions = page.nextCursor != nil
                loadedSessionPageCount += 1
            } catch is CancellationError {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_SESSION_PAGE_CANCELLED_PATH")
            }
            catch {
                guard projectRequestID == request else { return }
                sessionListError = error.localizedDescription
                sessionListRetry = .nextPage
            }
        }
    }

    func selectSession(_ sessionID: Int64, showWindow: Bool = false, messageID: Int64? = nil, preservingMainSearch: Bool = false) {
        if selectedSessionID == sessionID, selectedSession != nil, messageID == nil {
            if pendingSelectionCompletion != nil {
                if showWindow { pendingSelectionCompletion?.showWindow = true }
                if transcriptLoadError != nil { showPendingSelectionWindow() }
            } else if showWindow {
                NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
            }
            return
        }
        invalidateTranscriptSettlement()
        pausedTranscriptPreservation = nil
        transientTranscriptAbsence = nil
        cancelTranscriptRecovery()
        cancelPendingSelectionTranscriptRead()
        if !preservingMainSearch { mainSearchReturnContext = nil; hasSearchReturnContext = false; mainSearchReturnAnchor = nil }
        pendingSelectionCompletion = nil
        mayRestoreSession = false
        if sidebarRevealRequest?.sessionID != sessionID {
            invalidateSidebarRevealRequest()
        }
        selectedSessionID = sessionID
        settings.lastSessionID = sessionID
        selectedSession = (sessions + recentSessions).first { $0.id == sessionID }
        if let selectedSession,
           adoptProjectIdentity(from: selectedSession) {
            loadProjectSessions(ensuring: sessionID)
        }
        let request = UUID()
        sessionRequestID = request
        lastAppliedTranscriptReadRevision = 0
        requestedMessageID = messageID
        messages = []
        hydratedMessages.removeAll(keepingCapacity: true)
        hydrationFailures.removeAll(keepingCapacity: true)
        hydrationOrder.removeAll(keepingCapacity: true)
        hydrationEpoch = UUID()
        hydratingMessageIDs.removeAll(keepingCapacity: true)
        expandedReasoningIDs.removeAll()
        if !preservingMainSearch { deferMainSearchForSessionNavigation() }
        guard let database else { return }
        // Summaries can await the database result independently of the UI callback.
        pendingSelectionCompletion = .init(database: database, sessionID: sessionID, requestID: request,
                                           showWindow: showWindow, preservingMainSearch: preservingMainSearch)
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

    private func cancelTranscriptRecovery() {
        transcriptRecoveryEpisode = nil
        transcriptRecoveryTask?.cancel()
        transcriptRecoveryTask = nil
        transcriptReadError = nil
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
        let preservingPausedSelection = pausedTranscriptPreservation.map {
            transcriptRequestIsCurrent(database: $0.database, sessionID: $0.sessionID, request: $0.requestID)
        } == true && indexWorkflow.terminalPhase == nil
        if snapshot.session == nil, indexWorkflow.isActive || preservingPausedSelection,
           let database, let sessionID = selectedSessionID {
            // All publishers share this policy. Accept the revision, preserve the
            // cached view, and end an older read-error episode without applying absence.
            cancelTranscriptRecovery()
            transientTranscriptAbsence = .init(database: database, sessionID: sessionID, requestID: sessionRequestID,
                                               paused: !indexWorkflow.isActive)
            if !indexWorkflow.isActive { TraceTestHooks.touch(pathKey: "TRACE_TEST_TRANSCRIPT_PAUSED_PATH") }
            showPendingSelectionWindow()
            return
        }
        cancelTranscriptRecovery()
        transientTranscriptAbsence = nil
        pausedTranscriptPreservation = nil
        if snapshot.session == nil, deletionIsConfirmed || pendingSelectionCompletion != nil {
            // Deletion is a terminal navigation outcome, even when no transcript
            // was available to complete the original selection.
            let showWindow = pendingSelectionCompletion?.showWindow == true
            returnFromSession()
            if showWindow { NotificationCenter.default.post(name: .traceShowMainWindow, object: nil) }
            return
        }
        lastAppliedTranscriptReadRevision = snapshot.readRevision
        let changed = selectedSession?.transcriptIdentity != snapshot.session?.transcriptIdentity
        if changed {
            hydrationEpoch = UUID()
            hydratingMessageIDs.removeAll(keepingCapacity: true)
            hydratedMessages.removeAll(keepingCapacity: true)
            hydrationFailures.removeAll(keepingCapacity: true)
            hydrationOrder.removeAll(keepingCapacity: true)
        }
        if let rows = snapshot.messages, !changed {
            let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, MessageIdentity($0)) })
            let stale = Set(messageIdentities.keys.filter { messageIdentities[$0] != identities[$0] })
            for id in stale {
                hydratedMessages.removeValue(forKey: id)
                hydrationFailures.removeValue(forKey: id)
                hydratingMessageIDs.removeValue(forKey: id)
            }
            hydrationOrder.removeAll { stale.contains($0) }
        }
        selectedSession = snapshot.session
        if let rows = snapshot.messages { messages = rows }
        // Evaluate background navigation at publication, after any read/retry
        // suspension. Explicit selections reconcile regardless of a running pass.
        let completingSelection = pendingSelectionCompletion != nil
        if completingSelection || !indexingPassActive { reconcileSidebarReveal(with: snapshot) }
        // Ordinary summaries update the transcript without changing the project
        // being browsed. Selection completion and recovery retain their navigation.
        if completingSelection || reconcilingProject,
           let session = snapshot.session, adoptProjectIdentity(from: session) {
            let preservingSearch = pendingSelectionCompletion?.preservingMainSearch ?? hasSearchReturnContext
            if !preservingSearch { deferMainSearchForSessionNavigation() }
            loadProjectSessions(ensuring: session.id)
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

    func reloadCosts() {
        let dates = costDateBounds()
        usage = completedUsage.filter { row in
            (dates.from.map { row.day >= $0 } ?? true)
                && (dates.through.map { row.day <= $0 } ?? true)
                && (settings.includeSidechains || !row.isSidechain)
        }
    }

    private func loadCachedUsageAtStartup() async {
        guard let database else { return }
        let revision = completedUsageRevision
        do {
            let snapshot = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
            guard completedUsageRevision == revision else { return }
            completedUsage = snapshot
            reloadCosts()
        } catch {
            if completedUsageRevision == revision {
                costsError = "Could not load cached token totals: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleCompletedUsageRefresh(repairIfDirty: Bool) {
        usageRefreshPending = true
        if repairIfDirty { usageRepairPending = true }
        updateCostsTotalsUpdating()
        Task { [weak self] in
            await self?.refreshCompletedUsage(repairIfDirty: repairIfDirty)
        }
    }

    private func scheduleDeferredUsageRepair() {
        usageRepairPending = true
        usageRefreshPending = true
        updateCostsTotalsUpdating()
        guard deferredUsageRepairTask == nil else { return }
        deferredUsageRepairTask = Task { [weak self] in
            guard let self else { return }
            await self.scheduler?.waitUntilIdle()
            guard !Task.isCancelled else { return }
            if self.indexingPassActive {
                self.deferredUsageRepairTask = nil
                return
            }
            TraceTestHooks.touch(
                pathKey: "TRACE_TEST_USAGE_REPAIR_QUIET_PERIOD_STARTED_PATH"
            )
            let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_USAGE_REPAIR_QUIET_DELAY_MS", cappedAt: 5_000
            ) ?? 1_000
            do { try await self.clock.sleep(for: .milliseconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self.scheduler?.waitUntilIdle()
            guard !Task.isCancelled else { return }
            if self.indexingPassActive {
                self.deferredUsageRepairTask = nil
                return
            }
            self.deferredUsageRepairTask = nil
            if self.usageRepairPending {
                await self.refreshCompletedUsage(repairIfDirty: true)
            }
        }
    }

    private func refreshCompletedUsage(repairIfDirty: Bool) async {
        usageRefreshPending = true
        if repairIfDirty { usageRepairPending = true }
        updateCostsTotalsUpdating()
        guard let database else {
            usageRefreshPending = false
            if repairIfDirty { usageRepairPending = false }
            updateCostsTotalsUpdating()
            return
        }
        if repairIfDirty && indexingPassActive {
            usageRepairPending = true
            return
        }
        let request = UUID()
        usageSnapshotRequestID = request
        do {
            if let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_USAGE_SNAPSHOT_DELAY_MS",
                cappedAt: 5_000,
                marker: .line("started", pathKey: "TRACE_TEST_USAGE_SNAPSHOT_STARTED_PATH")
            ) {
                try await Task.sleep(for: .milliseconds(delay))
            }
            guard usageSnapshotRequestID == request else { return }
            if repairIfDirty { try await database.rebuildUsageRollupsIfDirty() }
            let snapshot = try await database.usage(
                fromDay: nil, throughDay: nil, includeSidechains: true
            )
            guard usageSnapshotRequestID == request else { return }
            if indexingPassActive {
                usageRepairPending = usageRepairPending || repairIfDirty
                return
            }
            completedUsage = snapshot
            completedUsageRevision += 1
            if repairIfDirty { usageRepairPending = false }
            usageRefreshPending = usageRepairPending
            costsError = nil
            updateCostsTotalsUpdating()
            reloadCosts()
        } catch is CancellationError {
            guard usageSnapshotRequestID == request else { return }
            usageRepairPending = usageRepairPending || repairIfDirty
            usageRefreshPending = usageRepairPending
            updateCostsTotalsUpdating()
        } catch {
            guard usageSnapshotRequestID == request else { return }
            costsError = "Could not update token totals: \(error.localizedDescription)"
            if repairIfDirty { usageRepairPending = false }
            usageRefreshPending = usageRepairPending
            updateCostsTotalsUpdating()
        }
    }

    private func updateCostsTotalsUpdating() {
        let updating = indexingPassActive || usageRefreshPending
        if costsTotalsUpdating != updating { costsTotalsUpdating = updating }
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
        invalidateTranscriptSettlement()
        invalidateTerminalSummaryRefresh()
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
        deferredUsageRepairTask?.cancel()
        deferredUsageRepairTask = nil
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
    private func refreshTerminalSummaries(_ reconciliation: ProjectReconciliationMode) -> Task<Void, Never>? {
        guard !terminating, let database else { return nil }
        let receipt = TerminalSummaryReceipt(database: database, attachment: attachmentGeneration,
            configuration: sourceConfigurationRevision, workflow: indexWorkflow.generation, reconciliation: reconciliation)
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
        terminal: TerminalSummaryReceipt? = nil
    ) async {
        guard let database else { return }
        let owner = owner ?? SummaryRefreshOwner(database: database, attachment: attachmentGeneration,
                                                 configuration: sourceConfigurationRevision)
        if terminal == nil { summaryRequestID = owner.id }
        let refresh = owner.id
        let fullReceipt = pendingFullSummaryRefresh
        let fullRefresh = !lightweight || fullReceipt != nil
        func isCurrent() -> Bool {
            !Task.isCancelled && summaryRefreshIsCurrent(owner)
        }
        func transcriptIsCurrent() -> Bool {
            isCurrent() && terminalSummaryTranscriptIsCurrent(terminal)
        }
        func currentReconciliation() -> ProjectReconciliationMode {
            guard let receipt = terminal ?? fullReceipt else { return projectReconciliation }
            return receipt.workflow == indexWorkflow.generation && !indexWorkflow.isActive
                ? receipt.reconciliation : .ongoing
        }
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
        let selectedSessionRequest = sessionRequestID
        let pageCount = sessionListProjectKey == projectCanonicalKey ? loadedSessionPageCount : 1
        let sidebar = try? await database.sidebarSnapshot(
            projectCanonicalKey: projectCanonicalKey, pageCount: pageCount, ensuringSessionID: ensuredSessionID
        )
        let loadedProjects = sidebar?.projects
        let loadedRecent = sidebar?.recentSessions ?? recentSessions
        let loadedSessions = sidebar?.sessionList
        guard isCurrent() else { return }
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
            sessionListProjectKey = projectCanonicalKey
            applySessionPages(loadedSessions)
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
        if let gate = summaryTailGateForTesting {
            summaryTailWaitingForTesting = true
            await gate.value
            summaryTailWaitingForTesting = false
        }
        #endif
        guard isCurrent() else { return }
        let loadedSourceHealth = try? await database.sourceHealth()
        let loadedStatistics = try? await database.statistics()
        guard isCurrent() else { return }
        sourceHealth = loadedSourceHealth ?? []
        guard isCurrent() else { return }
        statistics = loadedStatistics
        guard isCurrent() else { return }
        if let bytes = statistics?.databaseBytes { try? await diagnostics.recordIndexSize(bytes: bytes) }
        guard isCurrent() else { return }
        func restorationIsTerminal() -> Bool {
            !indexWorkflow.isActive
                && (indexWorkflow.terminalPhase != nil || [.complete, .failed].contains(progress.phase))
        }
        if mayRestoreSession {
            if let stored = settings.lastSessionID {
                let restored: Result<SessionSummary?, Error>
                do { restored = .success(try await database.session(id: stored)) }
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
                        selectSession(stored)
                    case .success(.none):
                        if restorationIsTerminal() { mayRestoreSession = false }
                    case .failure:
                        // A failed lookup cannot confirm deletion. Keep restoration
                        // eligible for the next ordinary full summary refresh.
                        break
                    }
                }
            } else if restorationIsTerminal() {
                mayRestoreSession = false
            }
        }
        guard isCurrent() else { return }
        if loadCosts || fullReceipt != nil { reloadCosts() }
        guard isCurrent() else { return }
        refreshDiagnostics()
        if let fullReceipt, pendingFullSummaryRefresh?.id == fullReceipt.id { pendingFullSummaryRefresh = nil }
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
