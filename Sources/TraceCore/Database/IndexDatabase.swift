import Foundation
import GRDB

public enum IndexDatabaseError: LocalizedError {
    case timestampCollisionLimit

    public var errorDescription: String? {
        switch self {
        case .timestampCollisionLimit:
            "More than 1,048,576 messages share one millisecond timestamp."
        }
    }
}

struct IndexedSourceState: Sendable {
    let id: Int64
    let agent: AgentKind
    let format: SourceFormat
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationNanoseconds: Int64
    let scannedBytes: Int64
    let headHash: Data
    let headLength: Int
    let contentGeneration: Int64
    let contentSessionID: String?
    let metadataSessionID: String?
    let isPlaceholder: Bool
    let lastError: String?
    let hadRecordedError: Bool
}

public actor IndexDatabase {
    public static let schemaVersion = 11
    public static let indexFormatVersion = 4
    private static let sourceStateSelection = """
        sf.*,
        (sf.last_error IS NOT NULL OR EXISTS (
            SELECT 1 FROM adapter_health ah
            WHERE ah.source_file_id=sf.id AND ah.last_error IS NOT NULL
        )) AS had_recorded_error
        """
    public nonisolated let contentWasResetOnOpen: Bool
    private let pool: DatabasePool
    private let url: URL

    public static func defaultURL() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("me.haroldmartin.Trace", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("index.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrate(pool)
        try pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO trace_meta(key, value) VALUES ('usage_rollups_dirty', '1')")
        }
        contentWasResetOnOpen = try Self.rebuildContentIfNeeded(pool)
    }

    private static func markRollupsDirty(_ db: Database) throws {
        try db.execute(sql: "UPDATE trace_meta SET value='1' WHERE key='usage_rollups_dirty'")
    }

    private static func migrate(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("trace-v1") { db in
            try db.execute(sql: """
                CREATE TABLE trace_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE source_root (
                    id INTEGER PRIMARY KEY,
                    agent TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    is_default INTEGER NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    last_scan_ms INTEGER,
                    last_error TEXT
                );

                CREATE TABLE source_file (
                    id INTEGER PRIMARY KEY,
                    root_id INTEGER NOT NULL REFERENCES source_root(id) ON DELETE CASCADE,
                    agent TEXT NOT NULL,
                    format TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    dev INTEGER NOT NULL,
                    inode INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    mtime_ns INTEGER NOT NULL,
                    scanned_bytes INTEGER NOT NULL DEFAULT 0,
                    head_hash BLOB NOT NULL,
                    head_length INTEGER NOT NULL,
                    adapter_version INTEGER NOT NULL DEFAULT 1,
                    last_error TEXT
                );

                CREATE TABLE adapter_health (
                    source_file_id INTEGER PRIMARY KEY REFERENCES source_file(id) ON DELETE CASCADE,
                    last_success_ms INTEGER,
                    last_error TEXT,
                    error_count INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE project (
                    id INTEGER PRIMARY KEY,
                    canonical_key TEXT NOT NULL UNIQUE,
                    root_path TEXT NOT NULL,
                    display_name TEXT NOT NULL
                );

                CREATE TABLE session (
                    id INTEGER PRIMARY KEY,
                    project_id INTEGER NOT NULL REFERENCES project(id),
                    source_file_id INTEGER NOT NULL REFERENCES source_file(id) ON DELETE CASCADE,
                    agent TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    last_activity_at INTEGER NOT NULL,
                    message_count INTEGER NOT NULL DEFAULT 0,
                    title TEXT,
                    had_error INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(source_file_id, external_id)
                );

                CREATE TABLE message (
                    id INTEGER PRIMARY KEY,
                    source_file_id INTEGER NOT NULL REFERENCES source_file(id) ON DELETE CASCADE,
                    session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    source_key TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    external_uuid TEXT,
                    role TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    loc_kind TEXT NOT NULL,
                    loc_offset INTEGER,
                    loc_length INTEGER,
                    loc_key TEXT,
                    char_count INTEGER NOT NULL,
                    prefix TEXT NOT NULL,
                    tool_summary TEXT,
                    tool_name TEXT,
                    is_sidechain INTEGER NOT NULL DEFAULT 0,
                    has_error INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(source_file_id, source_key)
                );

                CREATE VIRTUAL TABLE message_fts USING fts5(
                    body,
                    content='',
                    contentless_delete=1,
                    tokenize='unicode61 remove_diacritics 2'
                );

                CREATE TABLE usage_observation (
                    id INTEGER PRIMARY KEY,
                    source_file_id INTEGER NOT NULL REFERENCES source_file(id) ON DELETE CASCADE,
                    session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    source_key TEXT NOT NULL,
                    agent TEXT NOT NULL,
                    dedupe_key TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    cache_write_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    reasoning_tokens INTEGER,
                    is_sidechain INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(source_file_id, source_key)
                );

                CREATE TABLE usage_daily (
                    day TEXT NOT NULL,
                    project_id INTEGER NOT NULL REFERENCES project(id),
                    model TEXT NOT NULL,
                    is_sidechain INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    reasoning_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day, project_id, model, is_sidechain)
                );

                CREATE INDEX idx_source_inode ON source_file(dev, inode);
                CREATE INDEX idx_session_recent ON session(last_activity_at DESC);
                CREATE INDEX idx_session_project ON session(project_id, last_activity_at DESC);
                CREATE INDEX idx_message_session ON message(session_id, seq);
                CREATE INDEX idx_message_ts ON message(ts DESC);
                CREATE INDEX idx_usage_dedupe ON usage_observation(agent, dedupe_key);
                """)
            try db.execute(
                sql: "INSERT INTO trace_meta(key, value) VALUES ('schema_version', ?), ('index_format_version', ?), ('index_scope', ?)",
                arguments: ["1", String(indexFormatVersion), String(IndexScope.proseOnly.rawValue)]
            )
        }
        migrator.registerMigration("trace-v2-details") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN section_flags INTEGER")
            try db.execute(sql: "UPDATE trace_meta SET value='2' WHERE key='schema_version'")
            try db.execute(sql: """
                CREATE TABLE session_failure (
                    session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    source_key TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    tool_name TEXT,
                    detail TEXT NOT NULL,
                    locator BLOB,
                    PRIMARY KEY(session_id, source_key)
                );
                """)
        }
        migrator.registerMigration("trace-v3-session-metadata") { db in
            try db.execute(sql: "ALTER TABLE session ADD COLUMN first_user_message TEXT")
            try db.execute(sql: "ALTER TABLE session ADD COLUMN generated_title TEXT")
            try db.execute(sql: "ALTER TABLE session ADD COLUMN has_plan INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE source_file ADD COLUMN metadata_revision TEXT")
            try db.execute(sql: "UPDATE session SET first_user_message=title")
            try db.execute(sql: "UPDATE trace_meta SET value='3' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v4-source-generation") { db in
            try db.execute(sql: "ALTER TABLE source_file ADD COLUMN content_generation INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE trace_meta SET value='4' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v5-usage-project") { db in
            try db.execute(sql: "ALTER TABLE usage_observation ADD COLUMN project_id INTEGER REFERENCES project(id)")
            try db.execute(sql: "UPDATE usage_observation SET project_id=(SELECT project_id FROM session WHERE session.id=usage_observation.session_id)")
            try db.execute(sql: "UPDATE trace_meta SET value='5' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v6-checkpoint-context") { db in
            try db.execute(sql: "ALTER TABLE source_file ADD COLUMN content_session_id TEXT")
            try db.execute(sql: "ALTER TABLE source_file ADD COLUMN metadata_session_id TEXT")
            try db.execute(sql: "ALTER TABLE session ADD COLUMN error_revision INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE session SET error_revision=(SELECT count(*) FROM session_failure WHERE session_id=session.id)")
            try db.execute(sql: "CREATE INDEX idx_usage_project ON usage_observation(project_id)")
            try db.execute(sql: "CREATE INDEX idx_source_error ON source_file(id) WHERE last_error IS NOT NULL")
            try db.execute(sql: "UPDATE trace_meta SET value='6' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v7-source-placeholders") { db in
            try db.execute(sql: "ALTER TABLE source_file ADD COLUMN is_placeholder INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                UPDATE source_file SET is_placeholder=1
                WHERE dev=0 AND inode=0 AND size=0 AND mtime_ns=0
                    AND scanned_bytes=0 AND head_length=0 AND length(head_hash)=0
                """)
            try db.execute(sql: "UPDATE trace_meta SET value='7' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v8-fsevents-checkpoints") { db in
            try db.execute(sql: """
                CREATE TABLE fsevents_checkpoint (
                    volume_id TEXT PRIMARY KEY,
                    event_id TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
            try db.execute(sql: "UPDATE trace_meta SET value='8' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v9-reset-fsevents-checkpoints") { db in
            // v8 could retain a watermark after the indexed content was reset. Force one
            // reconciliation on upgrade so no installation can preserve that stale state.
            try db.execute(sql: "DELETE FROM fsevents_checkpoint")
            try db.execute(sql: "UPDATE trace_meta SET value='9' WHERE key='schema_version'")
        }
        migrator.registerMigration("trace-v10-scoped-discovery-errors") { db in
            try db.execute(sql: """
                CREATE TABLE source_scan_error (
                    id INTEGER PRIMARY KEY,
                    root_id INTEGER NOT NULL REFERENCES source_root(id) ON DELETE CASCADE,
                    scope_path TEXT NOT NULL,
                    error TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    UNIQUE(root_id, scope_path)
                );
                INSERT INTO source_scan_error(root_id, scope_path, error, updated_at_ms)
                SELECT id, path, last_error, coalesce(last_scan_ms, 0)
                FROM source_root WHERE last_error IS NOT NULL;
                UPDATE source_root SET last_error=NULL;
                UPDATE trace_meta SET value='10' WHERE key='schema_version';
                """)
        }
        migrator.registerMigration("trace-v11-remove-redundant-scan-error-index") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_source_scan_error_root")
            try db.execute(sql: "UPDATE trace_meta SET value='11' WHERE key='schema_version'")
        }
        try migrator.migrate(pool)
    }

    private static func rebuildContentIfNeeded(_ pool: DatabasePool) throws -> Bool {
        try pool.writeWithoutTransaction { db -> Bool in
            let stored = try String.fetchOne(
                db,
                sql: "SELECT value FROM trace_meta WHERE key='index_format_version'"
            )
            guard stored != String(indexFormatVersion) else { return false }
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM message_fts")
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM source_file")
                try db.execute(sql: "DELETE FROM source_root")
                try db.execute(sql: "DELETE FROM project")
                try db.execute(sql: "DELETE FROM fsevents_checkpoint")
                try markRollupsDirty(db)
                try db.execute(
                    sql: "INSERT INTO trace_meta(key, value) VALUES ('index_format_version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [String(indexFormatVersion)]
                )
                return .commit
            }
            return true
        }
    }

    public func storedIndexScope() throws -> IndexScope {
        try pool.read { db in
            let raw = try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='index_scope'")
            return IndexScope(rawValue: Int(raw ?? "0") ?? 0) ?? .proseOnly
        }
    }

    public func setIndexScope(_ scope: IndexScope) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO trace_meta(key, value) VALUES ('index_scope', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                arguments: [String(scope.rawValue)]
            )
        }
    }

    public func eventCheckpoint(volumeID: String) throws -> UInt64? {
        try pool.read { db in
            let value = try String.fetchOne(
                db, sql: "SELECT event_id FROM fsevents_checkpoint WHERE volume_id=?",
                arguments: [volumeID]
            )
            return value.flatMap(UInt64.init)
        }
    }

    public func saveEventCheckpoints(_ checkpoints: [String: UInt64]) throws {
        guard !checkpoints.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try pool.write { db in
            for (volumeID, eventID) in checkpoints {
                try db.execute(sql: """
                    INSERT INTO fsevents_checkpoint(volume_id, event_id, updated_at_ms)
                    VALUES (?, ?, ?)
                    ON CONFLICT(volume_id) DO UPDATE SET
                        event_id=excluded.event_id, updated_at_ms=excluded.updated_at_ms
                    """, arguments: [volumeID, String(eventID), now])
            }
        }
    }

    public func lastSafetyReconciliationMilliseconds() throws -> Int64? {
        try pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM trace_meta WHERE key='last_safety_reconciliation_ms'"
            ).flatMap(Int64.init)
        }
    }

    public func markSafetyReconciliationComplete() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO trace_meta(key, value) VALUES ('last_safety_reconciliation_ms', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [String(now)])
        }
    }

    public func clearIndex(keepingRoots: Bool = true) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM message_fts")
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM source_file")
                try db.execute(sql: "DELETE FROM source_scan_error")
                try db.execute(sql: "DELETE FROM project")
                try db.execute(sql: "DELETE FROM fsevents_checkpoint")
                try Self.markRollupsDirty(db)
                if !keepingRoots { try db.execute(sql: "DELETE FROM source_root") }
                return .commit
            }
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Removes indexed content for roots that are no longer configured. This runs before
    /// summaries or replacement watchers are exposed, so removed sessions cannot survive
    /// an interrupted source-folder change. A configured root absent from the database
    /// invalidates event checkpoints so it receives a fresh reconciliation after relaunch.
    @discardableResult
    public func synchronizeConfiguredRoots(_ roots: [SourceRoot]) throws -> Bool {
        let configured = Set(roots.map { $0.url.path })
        return try pool.writeWithoutTransaction { db in
            let stored = try Row.fetchAll(db, sql: "SELECT id, path FROM source_root")
            let storedPaths = Set(stored.map { (row: Row) -> String in row["path"] })
            let removed = stored.compactMap { row -> Int64? in
                let path: String = row["path"]
                return configured.contains(path) ? nil : row["id"]
            }
            let hasUnregisteredRoots = !configured.subtracting(storedPaths).isEmpty
            guard !removed.isEmpty || hasUnregisteredRoots else { return false }
            try db.inTransaction {
                for rootID in removed {
                    try db.execute(sql: """
                        DELETE FROM message_fts WHERE rowid IN (
                            SELECT m.id FROM message m
                            JOIN source_file sf ON sf.id=m.source_file_id
                            WHERE sf.root_id=?
                        )
                        """, arguments: [rootID])
                    try db.execute(sql: "DELETE FROM source_root WHERE id=?", arguments: [rootID])
                }
                if !removed.isEmpty {
                    try db.execute(sql: "DELETE FROM usage_daily")
                    try Self.markRollupsDirty(db)
                    try deleteOrphanedProjects(db: db)
                }
                if hasUnregisteredRoots {
                    try db.execute(sql: "DELETE FROM fsevents_checkpoint")
                }
                return .commit
            }
            return true
        }
    }

    public func statistics() throws -> IndexStatistics {
        let counts = try pool.read { db -> (Int, Int, Int, Int) in
            let files = try Int.fetchOne(db, sql: "SELECT count(*) FROM source_file") ?? 0
            let projects = try Int.fetchOne(db, sql: "SELECT count(*) FROM project") ?? 0
            let sessions = try Int.fetchOne(db, sql: "SELECT count(*) FROM session") ?? 0
            let messages = try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? 0
            return (files, projects, sessions, messages)
        }
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        let bytes = paths.reduce(Int64.zero) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return .init(
            sourceFileCount: counts.0,
            projectCount: counts.1,
            sessionCount: counts.2,
            messageCount: counts.3,
            databaseBytes: bytes
        )
    }

    func register(root: SourceRoot) throws -> Int64 {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_root(agent, path, is_default, enabled)
                    VALUES (?, ?, ?, 1)
                    ON CONFLICT(path) DO UPDATE SET agent=excluded.agent, is_default=excluded.is_default, enabled=1
                    """,
                arguments: [root.agent.rawValue, root.url.path, root.isDefault]
            )
            return try Int64.fetchOne(db, sql: "SELECT id FROM source_root WHERE path=?", arguments: [root.url.path])!
        }
    }

    func rootHasBeenScanned(rootID: Int64) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT last_scan_ms IS NOT NULL FROM source_root WHERE id=?",
                arguments: [rootID]
            ) ?? false
        }
    }

    func sourceState(path: String) throws -> IndexedSourceState? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT \(Self.sourceStateSelection)
                FROM source_file sf
                WHERE sf.path=?
                """, arguments: [path]) else {
                return nil
            }
            return sourceState(from: row)
        }
    }

    func movableSourceState(device: UInt64, inode: UInt64, agent: AgentKind,
                            format: SourceFormat, targetPath: String) throws -> IndexedSourceState? {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.sourceStateSelection)
                    FROM source_file sf
                    WHERE sf.dev=? AND sf.inode=? AND sf.agent=? AND sf.format=?
                        AND sf.is_placeholder=0
                    ORDER BY sf.id
                    """,
                arguments: [Int64(bitPattern: device), Int64(bitPattern: inode),
                            agent.rawValue, format.rawValue]
            )
            let target = TraceFileIO.canonicalPath(targetPath)
            return rows.map(sourceState(from:)).first {
                !FileManager.default.fileExists(atPath: $0.path)
                    || (!target.isCaseSensitive && $0.path != targetPath
                        && TraceFileIO.canonicalPath($0.path).comparisonKey == target.comparisonKey)
            }
        }
    }

    private func sourceState(from row: Row) -> IndexedSourceState {
        IndexedSourceState(
            id: row["id"],
            agent: AgentKind(rawValue: row["agent"])!,
            format: SourceFormat(rawValue: row["format"])!,
            path: row["path"],
            device: UInt64(bitPattern: row["dev"] as Int64),
            inode: UInt64(bitPattern: row["inode"] as Int64),
            size: row["size"],
            modificationNanoseconds: row["mtime_ns"],
            scannedBytes: row["scanned_bytes"],
            headHash: row["head_hash"],
            headLength: row["head_length"],
            contentGeneration: row["content_generation"],
            contentSessionID: row["content_session_id"],
            metadataSessionID: row["metadata_session_id"],
            isPlaceholder: row["is_placeholder"],
            lastError: row["last_error"],
            hadRecordedError: row["had_recorded_error"]
        )
    }

    func createSource(
        rootID: Int64,
        file: DiscoveredSourceFile,
        fingerprint: SourceFingerprint
    ) throws -> Int64 {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_file(root_id, agent, format, path, dev, inode, size, mtime_ns, scanned_bytes, head_hash, head_length)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    rootID, file.agent.rawValue, file.format.rawValue, file.url.path,
                    Int64(bitPattern: fingerprint.device), Int64(bitPattern: fingerprint.inode),
                    fingerprint.size, fingerprint.modificationNanoseconds,
                    fingerprint.headHash, fingerprint.headLength,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    func moveSource(id: Int64, rootID: Int64, path: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE source_file SET root_id=?, path=? WHERE id=?",
                arguments: [rootID, path, id]
            )
        }
    }

    func replacePlaceholderWithMovedSource(placeholderID: Int64, movedID: Int64,
                                           rootID: Int64, path: String) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM source_file WHERE id=? AND is_placeholder=1",
                               arguments: [placeholderID])
                guard db.changesCount == 1 else { throw SessionSourceError.malformedRecord("source placeholder changed") }
                try db.execute(sql: "UPDATE source_file SET root_id=?, path=? WHERE id=?",
                               arguments: [rootID, path, movedID])
                return .commit
            }
        }
    }

    func promotePlaceholder(id: Int64, rootID: Int64, file: DiscoveredSourceFile,
                            fingerprint: SourceFingerprint) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE source_file SET root_id=?, agent=?, format=?, is_placeholder=0,
                    dev=?, inode=?, size=?, mtime_ns=?, scanned_bytes=0, head_hash=?, head_length=?
                WHERE id=? AND is_placeholder=1
                """, arguments: [
                    rootID, file.agent.rawValue, file.format.rawValue,
                    Int64(bitPattern: fingerprint.device), Int64(bitPattern: fingerprint.inode),
                    fingerprint.size, fingerprint.modificationNanoseconds,
                    fingerprint.headHash, fingerprint.headLength, id,
                ])
            guard db.changesCount == 1 else { throw SessionSourceError.malformedRecord("source placeholder changed") }
        }
    }

    func deleteSource(id: Int64) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(
                    sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE source_file_id=?)",
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM source_file WHERE id=?", arguments: [id])
                try Self.markRollupsDirty(db)
                try deleteOrphanedProjects(db: db)
                return .commit
            }
        }
    }

    func deleteSource(path: String) throws {
        if let state = try sourceState(path: path) { try deleteSource(id: state.id) }
    }

    func replaceSourceContents(id: Int64) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(
                    sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE source_file_id=?)",
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM session WHERE source_file_id=?", arguments: [id])
                try Self.markRollupsDirty(db)
                try deleteOrphanedProjects(db: db)
                try db.execute(
                    sql: "UPDATE source_file SET scanned_bytes=0, metadata_revision=NULL, content_session_id=NULL, metadata_session_id=NULL, content_generation=content_generation+1 WHERE id=?",
                    arguments: [id]
                )
                return .commit
            }
        }
    }

    func insert(record: ParsedRecord, sourceFileID: Int64, scope: IndexScope) throws {
        try insert(records: [record], sourceFileID: sourceFileID, scope: scope)
    }

    func insert(
        records: [ParsedRecord], sourceFileID: Int64, scope: IndexScope,
        checkpoint: Int64? = nil, contentSessionID: String? = nil
    ) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try insert(records: records, sourceFileID: sourceFileID, scope: scope, db: db)
                if let checkpoint {
                    try db.execute(
                        sql: "UPDATE source_file SET scanned_bytes=?, content_session_id=? WHERE id=?",
                        arguments: [checkpoint, contentSessionID, sourceFileID]
                    )
                }
                return .commit
            }
        }
    }

    func replaceSnapshotContents(
        id: Int64,
        records: [ParsedRecord],
        scope: IndexScope,
        fingerprint: SourceFingerprint,
        scannedBytes: Int64
    ) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(
                    sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE source_file_id=?)",
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM session WHERE source_file_id=?", arguments: [id])
                try Self.markRollupsDirty(db)
                try deleteOrphanedProjects(db: db)
                try insert(records: records, sourceFileID: id, scope: scope, db: db)
                try db.execute(
                    sql: "UPDATE source_file SET metadata_revision=NULL, content_session_id=NULL, metadata_session_id=NULL, content_generation=content_generation+1 WHERE id=?",
                    arguments: [id]
                )
                try updateSource(
                    id: id,
                    fingerprint: fingerprint,
                    scannedBytes: scannedBytes,
                    error: nil,
                    db: db
                )
                return .commit
            }
        }
    }

    private func insert(
        records: [ParsedRecord],
        sourceFileID: Int64,
        scope: IndexScope,
        db: Database
    ) throws {
        let agent = sourceAgent(sourceFileID, db: db)
        for record in records {
            try Task.checkCancellation()
            switch record {
            case .message(let message):
                try insert(message: message, sourceFileID: sourceFileID, scope: scope, db: db)
            case .usage(let parsed):
                let session = try upsertSession(
                    externalID: parsed.sessionExternalID,
                    cwd: parsed.cwd,
                    timestamp: parsed.timestampMilliseconds,
                    agent: agent,
                    sourceFileID: sourceFileID,
                    db: db
                )
                try insertUsage(
                    parsed.usage,
                    sourceKey: parsed.sourceKey,
                    timestamp: parsed.timestampMilliseconds,
                    sidechain: parsed.isSidechain,
                    sessionID: session.id,
                    projectID: session.projectID,
                    sourceFileID: sourceFileID,
                    agent: agent,
                    db: db
                )
            case .event(let event):
                let session = try upsertSession(
                    externalID: event.sessionExternalID,
                    cwd: event.cwd,
                    timestamp: event.timestampMilliseconds,
                    agent: agent,
                    sourceFileID: sourceFileID,
                    db: db
                )
                try db.execute(sql: "UPDATE session SET had_error=1 WHERE id=?", arguments: [session.id])
                try storeFailure(
                    sessionID: session.id, sourceKey: event.sourceKey, timestamp: event.timestampMilliseconds,
                    kind: event.kind.rawValue, toolName: nil,
                    detail: event.detail ?? "The source recorded a \(event.kind.rawValue) turn without an explanation.",
                    locator: event.locator, db: db
                )
            case .sessionContext:
                break
            case .checkpoint(let offset):
                try db.execute(sql: "UPDATE source_file SET scanned_bytes=? WHERE id=?", arguments: [offset, sourceFileID])
            }
        }
    }

    private func sourceAgent(_ sourceFileID: Int64, db: Database) -> AgentKind {
        let raw = (try? String.fetchOne(db, sql: "SELECT agent FROM source_file WHERE id=?", arguments: [sourceFileID])) ?? nil
        return AgentKind(rawValue: raw ?? "") ?? .claudeCode
    }

    private func insert(
        message: ParsedMessage,
        sourceFileID: Int64,
        scope: IndexScope,
        db: Database
    ) throws {
        if try Int64.fetchOne(
            db,
            sql: "SELECT id FROM message WHERE source_file_id=? AND source_key=?",
            arguments: [sourceFileID, message.sourceKey]
        ) != nil { return }

        let agent = sourceAgent(sourceFileID, db: db)
        let session = try upsertSession(
            externalID: message.sessionExternalID,
            cwd: message.cwd,
            timestamp: message.timestampMilliseconds,
            agent: agent,
            sourceFileID: sourceFileID,
            db: db
        )
        let nextSequence = (try Int.fetchOne(
            db,
            sql: "SELECT max(seq) + 1 FROM message WHERE session_id=?",
            arguments: [session.id]
        )) ?? 0
        let messageID = try nextMessageID(timestamp: message.timestampMilliseconds, db: db)
        let preview = JSONHelpers.normalizedPreview(message.sections.preferredPreview)
        let toolSummary = message.sections.toolInvocation.isEmpty
            ? nil
            : JSONHelpers.normalizedPreview(message.sections.toolInvocation)

        try db.execute(
            sql: """
                INSERT INTO message(
                    id, source_file_id, session_id, source_key, seq, external_uuid, role, ts,
                    loc_kind, loc_offset, loc_length, loc_key, char_count, prefix, tool_summary,
                    tool_name, is_sidechain, has_error, section_flags
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                messageID, sourceFileID, session.id, message.sourceKey, nextSequence,
                message.externalID, message.role.rawValue, message.timestampMilliseconds,
                message.locator.kind.rawValue, message.locator.offset, message.locator.length,
                message.locator.key, message.sections.preferredPreview.count, preview, toolSummary,
                message.toolName, message.isSidechain, message.hasError, message.sections.flags,
            ]
        )

        let indexedText = message.sections.indexedText(for: scope)
        if !indexedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try db.execute(
                sql: "INSERT INTO message_fts(rowid, body) VALUES (?, ?)",
                arguments: [messageID, indexedText]
            )
        }

        try db.execute(
            sql: """
                UPDATE session
                SET started_at=min(started_at, ?),
                    last_activity_at=max(last_activity_at, ?),
                    message_count=message_count+1,
                    title=CASE WHEN title IS NULL AND ?='user' AND ?<>'' THEN ? ELSE title END,
                    had_error=max(had_error, ?)
                WHERE id=?
                """,
            arguments: [
                message.timestampMilliseconds, message.timestampMilliseconds,
                message.role.rawValue, preview, preview, message.hasError, session.id,
            ]
        )

        if message.hasError {
            try storeFailure(
                sessionID: session.id, sourceKey: message.sourceKey, timestamp: message.timestampMilliseconds,
                kind: message.toolName == nil && message.sections.toolOutput.isEmpty ? "failed message" : "failed tool",
                toolName: message.toolName,
                detail: message.sections.toolOutput.isEmpty ? message.sections.prose : message.sections.toolOutput,
                locator: message.locator, db: db
            )
        }
        if let usage = message.usage {
            try insertUsage(
                usage,
                sourceKey: "message:\(message.sourceKey)",
                timestamp: message.timestampMilliseconds,
                sidechain: message.isSidechain,
                sessionID: session.id,
                projectID: session.projectID,
                sourceFileID: sourceFileID,
                agent: agent,
                db: db
            )
        }
    }

    private func storeFailure(
        sessionID: Int64, sourceKey: String, timestamp: Int64, kind: String,
        toolName: String?, detail: String, locator: RecordLocator?, db: Database
    ) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO session_failure(session_id, source_key, ts, kind, tool_name, detail, locator)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [sessionID, sourceKey, timestamp, kind, toolName,
                String(detail.prefix(4_000)), try locator.map { try JSONEncoder().encode($0) }])
        try db.execute(sql: "UPDATE session SET error_revision=error_revision+1 WHERE id=?", arguments: [sessionID])
    }

    public func failures(sessionID: Int64) throws -> [SessionFailure] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM session_failure WHERE session_id=? ORDER BY ts DESC", arguments: [sessionID]).map { row in
                let data: Data? = row["locator"]
                return SessionFailure(timestampMilliseconds: row["ts"], kind: row["kind"],
                    toolName: row["tool_name"], detail: row["detail"],
                    locator: data.flatMap { try? JSONDecoder().decode(RecordLocator.self, from: $0) })
            }
        }
    }

    public func needsLegacyFailureScan(sessionID: Int64) throws -> Bool {
        try pool.read { db in
            let hasLegacyMessages = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM message WHERE session_id=? AND section_flags IS NULL
                )
                """, arguments: [sessionID]) ?? false
            if hasLegacyMessages { return true }
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM session s
                    WHERE s.id=? AND s.had_error=1
                      AND NOT EXISTS(SELECT 1 FROM message WHERE session_id=s.id)
                      AND NOT EXISTS(SELECT 1 FROM session_failure WHERE session_id=s.id)
                )
                """, arguments: [sessionID]) ?? false
        }
    }

    private func upsertSession(
        externalID: String,
        cwd: String,
        timestamp: Int64,
        agent: AgentKind,
        sourceFileID: Int64,
        db: Database
    ) throws -> (id: Int64, projectID: Int64) {
        let project = ProjectCanonicalizer.canonicalProject(for: cwd)
        try db.execute(
            sql: """
                INSERT INTO project(canonical_key, root_path, display_name)
                VALUES (?, ?, ?)
                ON CONFLICT(canonical_key) DO UPDATE SET root_path=excluded.root_path, display_name=excluded.display_name
                """,
            arguments: [project.key, project.path, project.name]
        )
        let projectID = try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE canonical_key=?", arguments: [project.key])!
        try db.execute(
            sql: """
                INSERT INTO session(project_id, source_file_id, agent, external_id, started_at, last_activity_at, message_count)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(source_file_id, external_id) DO UPDATE SET
                    project_id=excluded.project_id,
                    started_at=min(session.started_at, excluded.started_at),
                    last_activity_at=max(session.last_activity_at, excluded.last_activity_at)
                """,
            arguments: [projectID, sourceFileID, agent.rawValue, externalID, timestamp, timestamp]
        )
        let sessionID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM session WHERE source_file_id=? AND external_id=?",
            arguments: [sourceFileID, externalID]
        )!
        return (sessionID, projectID)
    }

    private func insertUsage(
        _ usage: UsageObservation,
        sourceKey: String,
        timestamp: Int64,
        sidechain: Bool,
        sessionID: Int64,
        projectID: Int64,
        sourceFileID: Int64,
        agent: AgentKind,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO usage_observation(
                    source_file_id, session_id, project_id, source_key, agent, dedupe_key, ts, model,
                    input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
                    reasoning_tokens, is_sidechain
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sourceFileID, sessionID, projectID, sourceKey, agent.rawValue, usage.dedupeKey,
                timestamp, usage.model, usage.inputTokens, usage.outputTokens,
                usage.cacheWriteTokens, usage.cacheReadTokens, usage.reasoningTokens, sidechain,
            ]
        )
        if db.changesCount > 0 { try Self.markRollupsDirty(db) }
    }

    private func nextMessageID(timestamp: Int64, db: Database) throws -> Int64 {
        let maximumTimestamp = Int64.max >> 20
        let safeTimestamp = max(0, min(timestamp, maximumTimestamp))
        let base = safeTimestamp << 20
        let upper = base | ((1 << 20) - 1)
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT max(id) FROM message WHERE id BETWEEN ? AND ?",
            arguments: [base, upper]
        )
        guard let current else { return base }
        guard current < upper else { throw IndexDatabaseError.timestampCollisionLimit }
        return current + 1
    }

    func finishSource(id: Int64, fingerprint: SourceFingerprint, scannedBytes: Int64, error: String? = nil) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try updateSource(id: id, fingerprint: fingerprint, scannedBytes: scannedBytes, error: error, db: db)
                return .commit
            }
        }
    }

    private func updateSource(
        id: Int64,
        fingerprint: SourceFingerprint,
        scannedBytes: Int64,
        error: String?,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE source_file
                SET dev=?, inode=?, size=?, mtime_ns=?, scanned_bytes=?, head_hash=?, head_length=?, last_error=coalesce(?, last_error)
                WHERE id=?
                """,
            arguments: [
                Int64(bitPattern: fingerprint.device), Int64(bitPattern: fingerprint.inode),
                fingerprint.size, fingerprint.modificationNanoseconds, scannedBytes,
                fingerprint.headHash, fingerprint.headLength, error, id,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO adapter_health(source_file_id, last_success_ms, last_error, error_count)
                VALUES (?, ?, ?, CASE WHEN ? IS NULL THEN 0 ELSE 1 END)
                ON CONFLICT(source_file_id) DO UPDATE SET
                    last_success_ms=excluded.last_success_ms,
                    last_error=coalesce(excluded.last_error, adapter_health.last_error),
                    error_count=CASE WHEN excluded.last_error IS NULL THEN adapter_health.error_count ELSE adapter_health.error_count + 1 END
                """,
            arguments: [id, Int64(Date().timeIntervalSince1970 * 1_000), error, error]
        )
    }

    private func deleteOrphanedProjects(db: Database) throws {
        try db.execute(sql: "DELETE FROM project WHERE NOT EXISTS (SELECT 1 FROM session WHERE session.project_id=project.id) AND NOT EXISTS (SELECT 1 FROM usage_observation WHERE usage_observation.project_id=project.id)")
    }

    func recordSourceError(file: DiscoveredSourceFile, rootID: Int64, error: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO source_file(
                    root_id, agent, format, path, dev, inode, size, mtime_ns,
                    scanned_bytes, head_hash, head_length, is_placeholder
                ) VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, ?, 0, 1)
                """, arguments: [rootID, file.agent.rawValue, file.format.rawValue,
                                 file.url.path, Data()])
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM source_file WHERE path=?",
                                        arguments: [file.url.path])!
            try db.execute(sql: "UPDATE source_file SET last_error=? WHERE id=?", arguments: [error, id])
            try db.execute(
                sql: """
                    INSERT INTO adapter_health(source_file_id, last_error, error_count)
                    VALUES (?, ?, 1)
                    ON CONFLICT(source_file_id) DO UPDATE SET last_error=excluded.last_error, error_count=adapter_health.error_count+1
                    """,
                arguments: [id, error]
            )
        }
    }

    func clearSourceError(path: String) throws -> Bool {
        try pool.write { db in
            guard let id = try Int64.fetchOne(db, sql: """
                SELECT sf.id FROM source_file sf
                LEFT JOIN adapter_health ah ON ah.source_file_id=sf.id
                WHERE sf.path=? AND (sf.last_error IS NOT NULL OR ah.last_error IS NOT NULL)
                """, arguments: [path]) else { return false }
            try db.execute(sql: "UPDATE source_file SET last_error=NULL WHERE id=?", arguments: [id])
            try db.execute(sql: "UPDATE adapter_health SET last_error=NULL WHERE source_file_id=?", arguments: [id])
            return true
        }
    }

    public func unresolvedSourceFailureCounts() throws -> SourceFailureCounts {
        try pool.read { db in
            let files = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM source_file WHERE last_error IS NOT NULL"
            ) ?? 0
            let discovery = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM source_scan_error"
            ) ?? 0
            return .init(fileFailures: files, discoveryFailures: discovery)
        }
    }

    /// Retained for source compatibility; this now counts actual failed files only.
    @available(*, deprecated, message: "Use unresolvedSourceFailureCounts()")
    public func unresolvedSourceFailureCount() throws -> Int {
        try unresolvedSourceFailureCounts().fileFailures
    }

    public func unresolvedRecoveryWork() throws -> IndexRecoveryWork {
        try pool.read { db in
            let files = try Set(String.fetchAll(
                db, sql: "SELECT path FROM source_file WHERE last_error IS NOT NULL"
            ))
            let roots = try Set(String.fetchAll(
                db, sql: "SELECT scope_path FROM source_scan_error"
            ))
            return .init(filePaths: files, reconciliationPaths: roots)
        }
    }

    func replaceDiscoveryErrors(
        _ replacements: [(rootID: Int64, scannedScope: String, failures: [DiscoveryFailure])]
    ) throws {
        guard !replacements.isEmpty else { return }
        try pool.write { db in
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            for replacement in replacements {
                let scanned = TraceFileIO.canonicalPath(replacement.scannedScope)
                let existing = try Row.fetchAll(
                    db, sql: "SELECT id, scope_path FROM source_scan_error WHERE root_id=?",
                    arguments: [replacement.rootID]
                )
                for row in existing {
                    let scopePath: String = row["scope_path"]
                    let errorID: Int64 = row["id"]
                    let errorScope = TraceFileIO.canonicalPath(scopePath)
                    if scanned.contains(errorScope) {
                        try db.execute(
                            sql: "DELETE FROM source_scan_error WHERE id=?",
                            arguments: [errorID]
                        )
                    }
                }
                for failure in replacement.failures {
                    try db.execute(sql: """
                        INSERT INTO source_scan_error(root_id, scope_path, error, updated_at_ms)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(root_id, scope_path) DO UPDATE SET
                            error=excluded.error, updated_at_ms=excluded.updated_at_ms
                        """, arguments: [replacement.rootID, failure.path, failure.message, now])
                }
                try db.execute(
                    sql: "UPDATE source_root SET last_scan_ms=?, last_error=NULL WHERE id=?",
                    arguments: [now, replacement.rootID]
                )
            }
        }
    }

    func paths(agent: AgentKind) throws -> [(id: Int64, path: String)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM source_file WHERE agent=?", arguments: [agent.rawValue])
                .map { ($0["id"], $0["path"]) }
        }
    }

    public func rebuildUsageRollups(
        timeZoneID: String = TimeZone.autoupdatingCurrent.identifier
    ) async throws {
        try await delayUsageRollupRebuildForTesting()
        try Task.checkCancellation()
        try await pool.writeWithoutTransaction { db in
            _ = try Self.rebuildUsageRollups(
                in: db, timeZoneID: timeZoneID, onlyIfDirty: false
            )
        }
        TraceTestHooks.appendLine("rebuilt", pathKey: "TRACE_TEST_ROLLUP_REBUILD_AUDIT_PATH")
    }

    private func delayUsageRollupRebuildForTesting() async throws {
        if let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_ROLLUP_REBUILD_DELAY_MS",
            cappedAt: 5_000,
            marker: .line("started", pathKey: "TRACE_TEST_ROLLUP_REBUILD_STARTED_PATH")
        ) {
            try await Task.sleep(for: .milliseconds(delay))
        }
    }

    @discardableResult
    public func rebuildUsageRollupsIfDirty(
        timeZoneID: String = TimeZone.autoupdatingCurrent.identifier
    ) async throws -> Bool {
        let mightBeDirty = try await pool.read {
            try Self.usageRollupsAreDirty(in: $0, timeZoneID: timeZoneID)
        }
        guard mightBeDirty else { return false }
        try await delayUsageRollupRebuildForTesting()
        try Task.checkCancellation()
        let rebuilt = try await pool.writeWithoutTransaction { db in
            try Self.rebuildUsageRollups(
                in: db, timeZoneID: timeZoneID, onlyIfDirty: true
            )
        }
        if rebuilt {
            TraceTestHooks.appendLine("rebuilt", pathKey: "TRACE_TEST_ROLLUP_REBUILD_AUDIT_PATH")
        }
        return rebuilt
    }

    private static func usageRollupsAreDirty(
        in db: Database, timeZoneID: String
    ) throws -> Bool {
        let flag = try String.fetchOne(
            db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_dirty'"
        )
        let storedZone = try String.fetchOne(
            db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_timezone'"
        )
        return flag != "0" || storedZone != timeZoneID
    }

    private static func rebuildUsageRollups(
        in db: Database, timeZoneID: String, onlyIfDirty: Bool
    ) throws -> Bool {
        var rebuilt = false
        try db.inTransaction {
            if onlyIfDirty {
                let dirty = try usageRollupsAreDirty(in: db, timeZoneID: timeZoneID)
                if !dirty { return .commit }
            }
            try db.execute(sql: "DELETE FROM usage_daily")
            try db.execute(sql: """
                INSERT INTO usage_daily(
                    day, project_id, model, is_sidechain, input_tokens, output_tokens,
                    cache_write_tokens, cache_read_tokens, reasoning_tokens
                )
                WITH canonical AS (
                    SELECT u.*,
                           row_number() OVER (
                               PARTITION BY u.agent, u.dedupe_key
                               ORDER BY coalesce(u.output_tokens, -1) DESC, u.id DESC
                           ) AS occurrence,
                           max(u.input_tokens) OVER response AS total_input,
                           max(u.output_tokens) OVER response AS total_output,
                           max(u.cache_write_tokens) OVER response AS total_cache_write,
                           max(u.cache_read_tokens) OVER response AS total_cache_read,
                           max(u.reasoning_tokens) OVER response AS total_reasoning
                    FROM usage_observation u
                    WINDOW response AS (PARTITION BY u.agent, u.dedupe_key)
                )
                SELECT strftime('%Y-%m-%d', c.ts / 1000, 'unixepoch', 'localtime'),
                       coalesce(c.project_id, s.project_id), c.model, c.is_sidechain,
                       sum(coalesce(c.total_input, 0)),
                       sum(coalesce(c.total_output, 0)),
                       sum(coalesce(c.total_cache_write, 0)),
                       sum(coalesce(c.total_cache_read, 0)),
                       sum(coalesce(c.total_reasoning, 0))
                FROM canonical c
                JOIN session s ON s.id = c.session_id
                WHERE c.occurrence = 1
                GROUP BY 1, 2, 3, 4
                """)
            try db.execute(sql: "UPDATE trace_meta SET value='0' WHERE key='usage_rollups_dirty'")
            try db.execute(
                sql: "INSERT INTO trace_meta(key, value) VALUES ('usage_rollups_timezone', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                arguments: [timeZoneID]
            )
            rebuilt = true
            return .commit
        }
        return rebuilt
    }

    public func search(
        query: String,
        filters: SearchFilters = .init(),
        sort: SearchSort = .recency,
        cursor: SearchCursor? = nil,
        limit: Int = 200
    ) throws -> SearchPage {
        let performanceInterval = TracePerformance.begin("Database Search")
        defer { TracePerformance.end(performanceInterval) }
        guard let pattern = FTSQueryParser.parse(query) else { return .init(results: [], nextCursor: nil) }
        return try pool.read { db in
            var filterArguments = StatementArguments()
            var predicates: [String] = []

            if !filters.agents.isEmpty {
                let values = filters.agents.sorted { $0.rawValue < $1.rawValue }
                predicates.append("s.agent IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
                for value in values { filterArguments += [value.rawValue] }
            }
            if let projectCanonicalKey = filters.projectCanonicalKey {
                predicates.append("p.canonical_key = ?")
                filterArguments += [projectCanonicalKey]
            }
            if let from = filters.fromMilliseconds {
                predicates.append("m.ts >= ?")
                filterArguments += [from]
            }
            if let to = filters.toMilliseconds {
                predicates.append("m.ts <= ?")
                filterArguments += [to]
            }
            if filters.errorsOnly { predicates.append("(m.has_error = 1 OR s.had_error = 1)") }

            let filterSQL = predicates.isEmpty ? "" : " AND " + predicates.joined(separator: " AND ")
            let sql: String
            var arguments: StatementArguments = [pattern]
            if sort == .recency {
                var cursorSQL = ""
                if let cursor {
                    cursorSQL = " AND message_fts.rowid < ?"
                    arguments += [cursor.rowID]
                }
                arguments += filterArguments
                arguments += [limit + 1]
                sql = """
                    SELECT m.id, m.session_id, s.project_id,
                           p.canonical_key AS project_canonical_key,
                           p.display_name AS project_name,
                           coalesce(s.generated_title, s.first_user_message, s.title, 'Untitled session') AS session_title,
                           s.agent, s.has_plan,
                           m.role, m.ts, m.prefix, sf.path AS source_path, NULL AS score
                    FROM message_fts
                    JOIN message m ON m.id = message_fts.rowid
                    JOIN session s ON s.id = m.session_id
                    JOIN project p ON p.id = s.project_id
                    JOIN source_file sf ON sf.id = m.source_file_id
                    WHERE message_fts MATCH ?\(cursorSQL)\(filterSQL)
                    ORDER BY message_fts.rowid DESC
                    LIMIT ?
                    """
            } else {
                var cursorSQL = ""
                if let cursor, let rank = cursor.rank {
                    cursorSQL = " AND (r.score > ? OR (r.score = ? AND r.rowid < ?))"
                    arguments += [rank, rank, cursor.rowID]
                }
                arguments += filterArguments
                arguments += [limit + 1]
                sql = """
                    WITH ranked AS (
                        SELECT rowid, bm25(message_fts) AS score
                        FROM message_fts
                        WHERE message_fts MATCH ?
                    )
                    SELECT m.id, m.session_id, s.project_id,
                           p.canonical_key AS project_canonical_key,
                           p.display_name AS project_name,
                           coalesce(s.generated_title, s.first_user_message, s.title, 'Untitled session') AS session_title,
                           s.agent, s.has_plan,
                           m.role, m.ts, m.prefix, sf.path AS source_path, r.score
                    FROM ranked r
                    JOIN message m ON m.id = r.rowid
                    JOIN session s ON s.id = m.session_id
                    JOIN project p ON p.id = s.project_id
                    JOIN source_file sf ON sf.id = m.source_file_id
                    WHERE 1=1\(cursorSQL)\(filterSQL)
                    ORDER BY r.score ASC, r.rowid DESC
                    LIMIT ?
                    """
            }

            var rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let hasMore = rows.count > limit
            if hasMore { rows.removeLast(rows.count - limit) }
            let results = rows.compactMap(searchResult(from:))
            let next = hasMore ? results.last.map { SearchCursor(rowID: $0.id, rank: $0.rank) } : nil
            return SearchPage(results: results, nextCursor: next)
        }
    }

    func metadataRevision(sourceID: Int64) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT metadata_revision FROM source_file WHERE id=?",
                arguments: [sourceID]
            )
        }
    }

    /// Seeds a tail-only metadata scan with the session used by the latest
    /// display record before its checkpoint. The fallback covers sources that
    /// have produced usage or events but no displayable message yet.
    func metadataSessionContext(sourceID: Int64, before checkpoint: Int64) throws -> String? {
        try pool.read { db in
            if let externalID = try String.fetchOne(db, sql: """
                SELECT s.external_id
                FROM message m
                JOIN session s ON s.id=m.session_id
                WHERE m.source_file_id=? AND m.loc_kind=? AND m.loc_offset < ?
                ORDER BY m.loc_offset DESC, m.id DESC
                LIMIT 1
                """, arguments: [sourceID, LocatorKind.byteRange.rawValue, checkpoint]) {
                return externalID
            }
            return try String.fetchOne(db, sql: """
                SELECT external_id
                FROM session
                WHERE source_file_id=?
                ORDER BY last_activity_at DESC, id DESC
                LIMIT 1
                """, arguments: [sourceID])
        }
    }

    func updateMetadata(
        sourceID: Int64,
        revision: String,
        scan: SessionMetadataScan,
        mode: MetadataUpdateMode
    ) throws -> Bool {
        try pool.write { db in
            var changed = false
            for (externalID, metadata) in scan.sessions {
                let before = try Row.fetchOne(db, sql: "SELECT first_user_message, generated_title, has_plan FROM session WHERE source_file_id=? AND external_id=?",
                                              arguments: [sourceID, externalID])
                switch mode {
                case .replace:
                    try db.execute(sql: """
                        UPDATE session SET
                            first_user_message=?,
                            generated_title=CASE WHEN agent=? THEN generated_title ELSE ? END,
                            has_plan=?
                        WHERE source_file_id=? AND external_id=?
                        """, arguments: [
                            metadata.firstUserMessage,
                            AgentKind.codex.rawValue,
                            metadata.title,
                            metadata.hasPlan,
                            sourceID,
                            externalID,
                        ])
                case .merge:
                    try db.execute(sql: """
                        UPDATE session SET
                            first_user_message=coalesce(first_user_message, ?),
                            generated_title=CASE WHEN ? THEN ? ELSE coalesce(generated_title, ?) END,
                            has_plan=CASE WHEN has_plan=1 OR ? THEN 1 ELSE 0 END
                        WHERE source_file_id=? AND external_id=?
                        """, arguments: [
                            metadata.firstUserMessage,
                            metadata.titleIsExplicit,
                            metadata.title,
                            metadata.title,
                            metadata.hasPlan,
                            sourceID,
                            externalID,
                        ])
                }
                let after = try Row.fetchOne(db, sql: "SELECT first_user_message, generated_title, has_plan FROM session WHERE source_file_id=? AND external_id=?",
                                             arguments: [sourceID, externalID])
                let oldFirst: String? = before?["first_user_message"]
                let newFirst: String? = after?["first_user_message"]
                let oldTitle: String? = before?["generated_title"]
                let newTitle: String? = after?["generated_title"]
                let oldPlan: Bool? = before?["has_plan"]
                let newPlan: Bool? = after?["has_plan"]
                if oldFirst != newFirst || oldTitle != newTitle || oldPlan != newPlan {
                    changed = true
                }
            }
            try db.execute(sql: "UPDATE source_file SET metadata_revision=?, metadata_session_id=? WHERE id=?",
                           arguments: [revision, scan.finalSessionID, sourceID])
            return changed
        }
    }

    func hasUntitledCodexSessions(sourceID: Int64) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM session WHERE source_file_id=? AND agent=? AND generated_title IS NULL)",
                              arguments: [sourceID, AgentKind.codex.rawValue]) ?? false
        }
    }

    func updateCodexNames(
        _ names: [String: String], root: URL,
        sourceID: Int64? = nil, onlyMissing: Bool = false
    ) throws -> Bool {
        try pool.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.external_id, s.generated_title FROM session s
                JOIN source_file sf ON sf.id=s.source_file_id
                JOIN source_root sr ON sr.id=sf.root_id
                WHERE s.agent=? AND sr.path=? AND (? IS NULL OR sf.id=?)
                """, arguments: [AgentKind.codex.rawValue, root.standardizedFileURL.path, sourceID, sourceID])
            var changed = false
            for row in rows {
                let externalID: String = row["external_id"]
                let id: Int64 = row["id"]
                let existing: String? = row["generated_title"]
                if onlyMissing && existing != nil { continue }
                let title = names[externalID]
                if onlyMissing && title == nil { continue }
                if title == existing { continue }
                try db.execute(
                    sql: "UPDATE session SET generated_title=? WHERE id=?",
                    arguments: [title, id]
                )
                changed = true
            }
            return changed
        }
    }

    public func projects() throws -> [ProjectSummary] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.canonical_key, p.display_name, p.root_path,
                       count(s.id) AS session_count,
                       coalesce(max(s.last_activity_at), 0) AS last_activity
                FROM project p JOIN session s ON s.project_id=p.id
                GROUP BY p.id ORDER BY last_activity DESC
                """).map {
                    .init(
                        id: $0["id"], canonicalKey: $0["canonical_key"],
                        displayName: $0["display_name"], rootPath: $0["root_path"],
                        sessionCount: $0["session_count"], lastActivityMilliseconds: $0["last_activity"]
                    )
                }
        }
    }

    public func sessions(
        projectCanonicalKey: String? = nil, limit: Int = 500
    ) throws -> [SessionSummary] {
        try pool.read { db in
            let predicate = projectCanonicalKey == nil
                ? ""
                : "WHERE p.canonical_key=?"
            var arguments = StatementArguments()
            if let projectCanonicalKey { arguments += [projectCanonicalKey] }
            arguments += [limit]
            return try Row.fetchAll(db, sql: """
                SELECT s.*, coalesce(s.generated_title, s.first_user_message, s.title, 'Untitled session') AS resolved_title,
                       sf.path AS source_path,
                       sf.content_generation AS source_generation,
                       p.canonical_key AS project_canonical_key
                FROM session s
                JOIN source_file sf ON sf.id=s.source_file_id
                JOIN project p ON p.id=s.project_id
                \(predicate) ORDER BY s.last_activity_at DESC, s.id DESC LIMIT ?
                """, arguments: arguments).compactMap(sessionSummary(from:))
        }
    }

    public func session(id: Int64) throws -> SessionSummary? {
        try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT s.*, coalesce(s.generated_title, s.first_user_message, s.title, 'Untitled session') AS resolved_title,
                       sf.path AS source_path,
                       sf.content_generation AS source_generation,
                       p.canonical_key AS project_canonical_key
                FROM session s
                JOIN source_file sf ON sf.id=s.source_file_id
                JOIN project p ON p.id=s.project_id
                WHERE s.id=?
                """, arguments: [id]).flatMap(sessionSummary(from:))
        }
    }

    public func messages(sessionID: Int64) throws -> [MessageSummary] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.*, sf.path AS source_path, sf.format AS source_format
                FROM message m JOIN source_file sf ON sf.id=m.source_file_id
                WHERE m.session_id=? ORDER BY m.seq
                """, arguments: [sessionID])
            return rows.compactMap(messageSummary(from:))
        }
    }

    public func message(id: Int64) throws -> MessageSummary? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.*, sf.path AS source_path, sf.format AS source_format
                FROM message m JOIN source_file sf ON sf.id=m.source_file_id
                WHERE m.id=?
                """, arguments: [id])
            else { return nil }
            return messageSummary(from: row)
        }
    }

    public func sourceHealth() throws -> [SourceHealth] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                WITH scan_health AS (
                    SELECT root_id, max(error) AS error
                    FROM source_scan_error GROUP BY root_id
                ), file_health AS (
                    SELECT f.root_id, count(*) AS file_count, max(h.last_error) AS error
                    FROM source_file f
                    LEFT JOIN adapter_health h ON h.source_file_id=f.id
                    GROUP BY f.root_id
                ), session_health AS (
                    SELECT f.root_id, min(s.started_at) AS earliest
                    FROM source_file f
                    JOIN session s ON s.source_file_id=f.id
                    GROUP BY f.root_id
                )
                SELECT r.id, r.agent, r.path, r.last_scan_ms,
                       coalesce(e.error, f.error) AS resolved_error,
                       coalesce(f.file_count, 0) AS file_count, s.earliest AS earliest
                FROM source_root r
                LEFT JOIN scan_health e ON e.root_id=r.id
                LEFT JOIN file_health f ON f.root_id=r.id
                LEFT JOIN session_health s ON s.root_id=r.id
                ORDER BY r.agent, r.path
                """)
            return rows.compactMap(sourceHealth(from:))
        }
    }

    public func usage(fromDay: String?, throughDay: String?, includeSidechains: Bool) throws -> [UsageRollup] {
        try pool.read { db in
            var predicates: [String] = []
            var arguments = StatementArguments()
            if let fromDay { predicates.append("u.day >= ?"); arguments += [fromDay] }
            if let throughDay { predicates.append("u.day <= ?"); arguments += [throughDay] }
            if !includeSidechains { predicates.append("u.is_sidechain = 0") }
            let whereSQL = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
            return try Row.fetchAll(db, sql: """
                SELECT u.*, p.display_name AS project_name
                FROM usage_daily u JOIN project p ON p.id=u.project_id
                \(whereSQL) ORDER BY u.day DESC, p.display_name, u.model
                """, arguments: arguments).map {
                    .init(
                        day: $0["day"], projectID: $0["project_id"], projectName: $0["project_name"],
                        model: $0["model"], isSidechain: $0["is_sidechain"],
                        inputTokens: $0["input_tokens"], outputTokens: $0["output_tokens"],
                        cacheWriteTokens: $0["cache_write_tokens"], cacheReadTokens: $0["cache_read_tokens"],
                        reasoningTokens: $0["reasoning_tokens"]
                    )
                }
        }
    }
}

private func searchResult(from row: Row) -> SearchResult? {
    let agentRaw: String = row["agent"]
    let roleRaw: String = row["role"]
    guard let agent = AgentKind(rawValue: agentRaw),
          let role = MessageRole(rawValue: roleRaw)
    else { return nil }
    let id: Int64 = row["id"]
    let sessionID: Int64 = row["session_id"]
    let projectID: Int64 = row["project_id"]
    let projectCanonicalKey: String = row["project_canonical_key"]
    let projectName: String = row["project_name"]
    let sessionTitle: String = row["session_title"]
    let timestamp: Int64 = row["ts"]
    let prefix: String = row["prefix"]
    let sourcePath: String = row["source_path"]
    let rank: Double? = row["score"]
    return SearchResult(
        id: id, sessionID: sessionID, projectID: projectID,
        projectCanonicalKey: projectCanonicalKey,
        projectName: projectName, sessionTitle: sessionTitle, sessionHasPlan: row["has_plan"], agent: agent,
        role: role, timestampMilliseconds: timestamp, prefix: prefix,
        sourcePath: sourcePath, rank: rank
    )
}

private func sessionSummary(from row: Row) -> SessionSummary? {
    let agentRaw: String = row["agent"]
    guard let agent = AgentKind(rawValue: agentRaw) else { return nil }
    let id: Int64 = row["id"]
    let projectID: Int64 = row["project_id"]
    let projectCanonicalKey: String = row["project_canonical_key"]
    let title: String = row["resolved_title"]
    let startedAt: Int64 = row["started_at"]
    let lastActivity: Int64 = row["last_activity_at"]
    let messageCount: Int = row["message_count"]
    let hadError: Bool = row["had_error"]
    let sourcePath: String = row["source_path"]
    return SessionSummary(
        id: id, projectID: projectID, projectCanonicalKey: projectCanonicalKey, agent: agent,
        title: title, hasPlan: row["has_plan"], startedAtMilliseconds: startedAt,
        lastActivityMilliseconds: lastActivity, messageCount: messageCount,
        hadError: hadError, sourcePath: sourcePath,
        sourceGeneration: row["source_generation"], errorRevision: row["error_revision"]
    )
}

private func messageSummary(from row: Row) -> MessageSummary? {
    let roleRaw: String = row["role"]
    let formatRaw: String = row["source_format"]
    guard let role = MessageRole(rawValue: roleRaw),
          let format = SourceFormat(rawValue: formatRaw)
    else { return nil }
    let locatorKindRaw: String = row["loc_kind"]
    let locator = RecordLocator(
        kind: LocatorKind(rawValue: locatorKindRaw) ?? .byteRange,
        offset: row["loc_offset"] as Int64?,
        length: row["loc_length"] as Int64?,
        key: row["loc_key"] as String?
    )
    let id: Int64 = row["id"]
    let timestamp: Int64 = row["ts"]
    let prefix: String = row["prefix"]
    let toolSummary: String? = row["tool_summary"]
    let characterCount: Int = row["char_count"]
    let hasError: Bool = row["has_error"]
    let sourcePath: String = row["source_path"]
    return MessageSummary(
        id: id, role: role, timestampMilliseconds: timestamp,
        prefix: prefix, toolSummary: toolSummary,
        characterCount: characterCount, hasError: hasError,
        sourcePath: sourcePath, sourceFormat: format, locator: locator, sectionFlags: row["section_flags"]
    )
}

private func sourceHealth(from row: Row) -> SourceHealth? {
    let agentRaw: String = row["agent"]
    guard let agent = AgentKind(rawValue: agentRaw) else { return nil }
    let rowID: Int64 = row["id"]
    let rootPath: String = row["path"]
    let fileCount: Int = row["file_count"]
    let earliest: Int64? = row["earliest"]
    let lastScan: Int64? = row["last_scan_ms"]
    let error: String? = row["resolved_error"]
    return SourceHealth(
        id: String(rowID), agent: agent, rootPath: rootPath,
        fileCount: fileCount, earliestSessionMilliseconds: earliest,
        lastScanMilliseconds: lastScan, error: error
    )
}
