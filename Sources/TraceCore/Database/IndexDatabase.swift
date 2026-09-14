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
}

public actor IndexDatabase {
    public static let schemaVersion = 1
    public static let indexFormatVersion = 1
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
        try Self.rebuildContentIfNeeded(pool)
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
                arguments: [String(schemaVersion), String(indexFormatVersion), String(IndexScope.proseOnly.rawValue)]
            )
        }
        try migrator.migrate(pool)
    }

    private static func rebuildContentIfNeeded(_ pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            let stored = try String.fetchOne(
                db,
                sql: "SELECT value FROM trace_meta WHERE key='index_format_version'"
            )
            guard stored != String(indexFormatVersion) else { return }
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM message_fts")
                try db.execute(sql: "DELETE FROM source_file")
                try db.execute(sql: "DELETE FROM project")
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(
                    sql: "INSERT INTO trace_meta(key, value) VALUES ('index_format_version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [String(indexFormatVersion)]
                )
                return .commit
            }
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

    public func clearIndex(keepingRoots: Bool = true) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM message_fts")
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM source_file")
                try db.execute(sql: "DELETE FROM project")
                if !keepingRoots { try db.execute(sql: "DELETE FROM source_root") }
                return .commit
            }
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
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

    public func indexScope() throws -> IndexScope {
        try pool.read { db in
            let raw = try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='index_scope'")
            return IndexScope(rawValue: Int(raw ?? "0") ?? 0) ?? .proseOnly
        }
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

    func sourceState(path: String) throws -> IndexedSourceState? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_file WHERE path=?", arguments: [path]) else {
                return nil
            }
            return sourceState(from: row)
        }
    }

    func sourceState(device: UInt64, inode: UInt64) throws -> IndexedSourceState? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_file WHERE dev=? AND inode=? LIMIT 1",
                arguments: [Int64(bitPattern: device), Int64(bitPattern: inode)]
            ) else { return nil }
            return sourceState(from: row)
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
            headLength: row["head_length"]
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

    func deleteSource(id: Int64) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(
                    sql: "DELETE FROM message_fts WHERE rowid IN (SELECT id FROM message WHERE source_file_id=?)",
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: "DELETE FROM source_file WHERE id=?", arguments: [id])
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
                try deleteOrphanedProjects(db: db)
                try db.execute(sql: "UPDATE source_file SET scanned_bytes=0, last_error=NULL WHERE id=?", arguments: [id])
                return .commit
            }
        }
    }

    func insert(record: ParsedRecord, sourceFileID: Int64, scope: IndexScope) throws {
        try insert(records: [record], sourceFileID: sourceFileID, scope: scope)
    }

    func insert(records: [ParsedRecord], sourceFileID: Int64, scope: IndexScope) throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try insert(records: records, sourceFileID: sourceFileID, scope: scope, db: db)
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
                try deleteOrphanedProjects(db: db)
                try insert(records: records, sourceFileID: id, scope: scope, db: db)
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
            switch record {
            case .message(let message):
                try insert(message: message, sourceFileID: sourceFileID, scope: scope, db: db)
            case .usage(let parsed):
                let sessionID = try upsertSession(
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
                    sessionID: sessionID,
                    sourceFileID: sourceFileID,
                    agent: agent,
                    db: db
                )
            case .event(let event):
                let sessionID = try upsertSession(
                    externalID: event.sessionExternalID,
                    cwd: event.cwd,
                    timestamp: event.timestampMilliseconds,
                    agent: agent,
                    sourceFileID: sourceFileID,
                    db: db
                )
                try db.execute(sql: "UPDATE session SET had_error=1 WHERE id=?", arguments: [sessionID])
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
        let sessionID = try upsertSession(
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
            arguments: [sessionID]
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
                    tool_name, is_sidechain, has_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                messageID, sourceFileID, sessionID, message.sourceKey, nextSequence,
                message.externalID, message.role.rawValue, message.timestampMilliseconds,
                message.locator.kind.rawValue, message.locator.offset, message.locator.length,
                message.locator.key, message.sections.preferredPreview.count, preview, toolSummary,
                message.toolName, message.isSidechain, message.hasError,
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
                message.role.rawValue, preview, preview, message.hasError, sessionID,
            ]
        )

        if let usage = message.usage {
            try insertUsage(
                usage,
                sourceKey: "message:\(message.sourceKey)",
                timestamp: message.timestampMilliseconds,
                sidechain: message.isSidechain,
                sessionID: sessionID,
                sourceFileID: sourceFileID,
                agent: agent,
                db: db
            )
        }
    }

    private func upsertSession(
        externalID: String,
        cwd: String,
        timestamp: Int64,
        agent: AgentKind,
        sourceFileID: Int64,
        db: Database
    ) throws -> Int64 {
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
        return try Int64.fetchOne(
            db,
            sql: "SELECT id FROM session WHERE source_file_id=? AND external_id=?",
            arguments: [sourceFileID, externalID]
        )!
    }

    private func insertUsage(
        _ usage: UsageObservation,
        sourceKey: String,
        timestamp: Int64,
        sidechain: Bool,
        sessionID: Int64,
        sourceFileID: Int64,
        agent: AgentKind,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO usage_observation(
                    source_file_id, session_id, source_key, agent, dedupe_key, ts, model,
                    input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
                    reasoning_tokens, is_sidechain
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sourceFileID, sessionID, sourceKey, agent.rawValue, usage.dedupeKey,
                timestamp, usage.model, usage.inputTokens, usage.outputTokens,
                usage.cacheWriteTokens, usage.cacheReadTokens, usage.reasoningTokens, sidechain,
            ]
        )
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
                SET dev=?, inode=?, size=?, mtime_ns=?, scanned_bytes=?, head_hash=?, head_length=?, last_error=?
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
                    last_error=excluded.last_error,
                    error_count=CASE WHEN excluded.last_error IS NULL THEN adapter_health.error_count ELSE adapter_health.error_count + 1 END
                """,
            arguments: [id, Int64(Date().timeIntervalSince1970 * 1_000), error, error]
        )
    }

    private func deleteOrphanedProjects(db: Database) throws {
        try db.execute(sql: "DELETE FROM project WHERE NOT EXISTS (SELECT 1 FROM session WHERE session.project_id=project.id)")
    }

    func recordSourceError(path: String, error: String) throws {
        try pool.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM source_file WHERE path=?", arguments: [path]) else { return }
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

    func recordRootScan(rootID: Int64, error: String?) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE source_root SET last_scan_ms=?, last_error=? WHERE id=?",
                arguments: [Int64(Date().timeIntervalSince1970 * 1_000), error, rootID]
            )
        }
    }

    func paths(agent: AgentKind) throws -> [(id: Int64, path: String)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM source_file WHERE agent=?", arguments: [agent.rawValue])
                .map { ($0["id"], $0["path"]) }
        }
    }

    public func rebuildUsageRollups() throws {
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM usage_daily")
                try db.execute(sql: """
                    INSERT INTO usage_daily(
                        day, project_id, model, is_sidechain, input_tokens, output_tokens,
                        cache_write_tokens, cache_read_tokens, reasoning_tokens
                    )
                    WITH canonical AS (
                        SELECT u.*,
                               row_number() OVER (PARTITION BY u.agent, u.dedupe_key ORDER BY u.id) AS occurrence
                        FROM usage_observation u
                    )
                    SELECT strftime('%Y-%m-%d', c.ts / 1000, 'unixepoch', 'localtime'),
                           s.project_id, c.model, c.is_sidechain,
                           sum(coalesce(c.input_tokens, 0)),
                           sum(coalesce(c.output_tokens, 0)),
                           sum(coalesce(c.cache_write_tokens, 0)),
                           sum(coalesce(c.cache_read_tokens, 0)),
                           sum(coalesce(c.reasoning_tokens, 0))
                    FROM canonical c
                    JOIN session s ON s.id = c.session_id
                    WHERE c.occurrence = 1
                    GROUP BY 1, 2, 3, 4
                    """)
                return .commit
            }
        }
    }

    public func search(
        query: String,
        filters: SearchFilters = .init(),
        sort: SearchSort = .recency,
        cursor: SearchCursor? = nil,
        limit: Int = 200
    ) throws -> SearchPage {
        guard let pattern = FTSQueryParser.parse(query) else { return .init(results: [], nextCursor: nil) }
        return try pool.read { db in
            var filterArguments = StatementArguments()
            var predicates: [String] = []

            if !filters.agents.isEmpty {
                let values = filters.agents.sorted { $0.rawValue < $1.rawValue }
                predicates.append("s.agent IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
                for value in values { filterArguments += [value.rawValue] }
            }
            if let projectID = filters.projectID {
                predicates.append("s.project_id = ?")
                filterArguments += [projectID]
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
                    SELECT m.id, m.session_id, s.project_id, p.display_name AS project_name,
                           coalesce(s.title, 'Untitled session') AS session_title, s.agent,
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
                    SELECT m.id, m.session_id, s.project_id, p.display_name AS project_name,
                           coalesce(s.title, 'Untitled session') AS session_title, s.agent,
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

    public func projects() throws -> [ProjectSummary] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.display_name, p.root_path, count(s.id) AS session_count,
                       coalesce(max(s.last_activity_at), 0) AS last_activity
                FROM project p JOIN session s ON s.project_id=p.id
                GROUP BY p.id ORDER BY last_activity DESC
                """).map {
                    .init(
                        id: $0["id"], displayName: $0["display_name"], rootPath: $0["root_path"],
                        sessionCount: $0["session_count"], lastActivityMilliseconds: $0["last_activity"]
                    )
                }
        }
    }

    public func sessions(projectID: Int64? = nil, limit: Int = 500) throws -> [SessionSummary] {
        try pool.read { db in
            let predicate = projectID == nil ? "" : "WHERE s.project_id=?"
            var arguments = StatementArguments()
            if let projectID { arguments += [projectID] }
            arguments += [limit]
            return try Row.fetchAll(db, sql: """
                SELECT s.*, coalesce(s.title, 'Untitled session') AS resolved_title, sf.path AS source_path
                FROM session s JOIN source_file sf ON sf.id=s.source_file_id
                \(predicate) ORDER BY s.last_activity_at DESC LIMIT ?
                """, arguments: arguments).compactMap(sessionSummary(from:))
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
                SELECT r.id, r.agent, r.path, r.last_scan_ms,
                       coalesce(r.last_error, max(h.last_error)) AS resolved_error,
                       count(DISTINCT f.id) AS file_count, min(s.started_at) AS earliest
                FROM source_root r
                LEFT JOIN source_file f ON f.root_id=r.id
                LEFT JOIN adapter_health h ON h.source_file_id=f.id
                LEFT JOIN session s ON s.source_file_id=f.id
                GROUP BY r.id ORDER BY r.agent, r.path
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
    let projectName: String = row["project_name"]
    let sessionTitle: String = row["session_title"]
    let timestamp: Int64 = row["ts"]
    let prefix: String = row["prefix"]
    let sourcePath: String = row["source_path"]
    let rank: Double? = row["score"]
    return SearchResult(
        id: id, sessionID: sessionID, projectID: projectID,
        projectName: projectName, sessionTitle: sessionTitle, agent: agent,
        role: role, timestampMilliseconds: timestamp, prefix: prefix,
        sourcePath: sourcePath, rank: rank
    )
}

private func sessionSummary(from row: Row) -> SessionSummary? {
    let agentRaw: String = row["agent"]
    guard let agent = AgentKind(rawValue: agentRaw) else { return nil }
    let id: Int64 = row["id"]
    let projectID: Int64 = row["project_id"]
    let title: String = row["resolved_title"]
    let startedAt: Int64 = row["started_at"]
    let lastActivity: Int64 = row["last_activity_at"]
    let messageCount: Int = row["message_count"]
    let hadError: Bool = row["had_error"]
    let sourcePath: String = row["source_path"]
    return SessionSummary(
        id: id, projectID: projectID, agent: agent,
        title: title, startedAtMilliseconds: startedAt,
        lastActivityMilliseconds: lastActivity, messageCount: messageCount,
        hadError: hadError, sourcePath: sourcePath
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
        sourcePath: sourcePath, sourceFormat: format, locator: locator
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
