import CustomDump
import GRDB
import os
import XCTest
@testable import TraceCore

final class RecencySearchTests: XCTestCase {
    func testLiveExceptionalRowsKeepNormalMatchesStreamingAndPreserveCursors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceRecency-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl"), url = root.appendingPathComponent("index.sqlite")
        try Data("{\"type\":\"user\",\"uuid\":\"seed\",\"sessionId\":\"seed\",\"cwd\":\"/tmp/recency\",\"timestamp\":1700000000000,\"message\":{\"content\":\"seed\"}}\n".utf8).write(to: file)
        let statements = OSAllocatedUnfairLock(initialState: [String]())
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in
                let sql = event.expandedDescription
                if sql.contains("FROM message_fts"), sql.contains("ORDER BY") {
                    statements.withLock { $0.append(sql) }
                }
            }
        }
        let database = try IndexDatabase(url: url, configuration: configuration)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let queue = try DatabaseQueue(path: url.path)
        let count = 2_000
        try await queue.write { db in
            try db.execute(sql: """
                WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<?)
                INSERT INTO message(id,source_file_id,session_id,source_key,seq,role,ts,loc_kind,char_count,prefix)
                SELECT ((1700000000000+n)<<20),m.source_file_id,m.session_id,'fixture-'||n,n,'user',
                       1700000000000+n,'byteRange',6,'needle'
                FROM numbers CROSS JOIN message m WHERE m.source_key='seed';
                INSERT INTO message_fts(rowid,body) SELECT id,'needle' FROM message WHERE source_key LIKE 'fixture-%';
                INSERT INTO trace_meta(key,value) VALUES ('message_id_overflow','1');
                """, arguments: [count])
        }
        for state in ["absent", "unrelated", "matching", "deleted"] {
            if state == "unrelated" {
                try await queue.write { db in
                    try db.execute(sql: """
                        INSERT INTO message(id,source_file_id,session_id,source_key,seq,role,ts,loc_kind,char_count,prefix)
                        SELECT -10,source_file_id,session_id,'overflow',3000,'user',1700000003000,'byteRange',5,'other'
                        FROM message WHERE source_key='seed';
                        INSERT INTO message_fts(rowid,body) VALUES(-10,'other');
                        """)
                }
            } else if state == "matching" {
                try await queue.write { db in
                    try db.execute(sql: "DELETE FROM message_fts WHERE rowid=-10; INSERT INTO message_fts(rowid,body) VALUES(-10,'needle')")
                }
            } else if state == "deleted" {
                try await queue.write { db in
                    try db.execute(sql: "DELETE FROM message_fts WHERE rowid=-10; DELETE FROM message WHERE id=-10")
                }
            }
            statements.withLock { $0.removeAll() }
            let page = try await database.search(query: "needle", limit: 200)
            XCTAssertEqual(page.results.count, 200)
            let normal = try XCTUnwrap(statements.withLock { $0.first { $0.contains("ORDER BY message_fts.rowid DESC") } })
            let plan = try await queue.read { db in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + normal).map { $0["detail"] as String } }
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(state): ordinary matches cannot use a full sort")
            XCTAssertTrue(plan.contains { $0.contains("VIRTUAL TABLE") })
            if state == "matching" { XCTAssertEqual(page.results.first?.id, -10) }
            let next = try await database.search(query: "needle", cursor: page.nextCursor, limit: 200)
            XCTAssertTrue(Set(page.results.map(\.id)).isDisjoint(with: next.results.map(\.id)))
            XCTAssertEqual(next.results.count, 200)
        }
        let reopened = try IndexDatabase(url: url)
        let obsolete = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='message_id_overflow'")
        }
        XCTAssertNil(obsolete, "Opening an older index removes its obsolete overflow marker")
        let reopenedPage = try await reopened.search(query: "needle", limit: 200)
        XCTAssertEqual(reopenedPage.results.count, 200)
        // An already issued negative cursor remains meaningful after its row is deleted.
        let next = try await database.search(query: "needle", cursor: .init(rowID: -10, rank: nil, timestampMilliseconds: 1700000003000), limit: 1)
        XCTAssertEqual(next.results.first?.timestampMilliseconds, 1700000000000 + Int64(count))
        // Saturated/clamped positive IDs must sort by the original event timestamp.
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO message(id,source_file_id,session_id,source_key,seq,role,ts,loc_kind,char_count,prefix)
                SELECT ?,source_file_id,session_id,'clamped',4000,'user',?,'byteRange',6,'needle'
                FROM message WHERE source_key='seed';
                INSERT INTO message_fts(rowid,body) VALUES(?,'needle');
                """, arguments: [Int64.max - 1, Int64.max, Int64.max - 1])
        }
        let clamped = try await database.search(query: "needle", limit: 1)
        XCTAssertEqual(clamped.results.first?.timestampMilliseconds, Int64.max)
        let after = try await database.search(query: "needle", cursor: clamped.nextCursor, limit: 1)
        XCTAssertEqual(after.results.first?.timestampMilliseconds, 1700000000000 + Int64(count))
        expectNoDifference([Int64.max, 1700000000000 + Int64(count)],
                           [clamped.results.first?.timestampMilliseconds, after.results.first?.timestampMilliseconds].compactMap { $0 })
        // A deleted normal legacy cursor still carries recoverable timestamp bits,
        // even when an unrelated exceptional date switches the pagination path.
        let deletedNormal = (Int64(1700000000000) + 1_000) << 20
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid=?; DELETE FROM message WHERE id=?",
                           arguments: [deletedNormal, deletedNormal])
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid=?; INSERT INTO message_fts(rowid,body) VALUES(?,'other')",
                           arguments: [Int64.max - 1, Int64.max - 1])
        }
        let expected = try await database.search(query: "needle",
            cursor: .init(rowID: deletedNormal, rank: nil, timestampMilliseconds: 1700000001000), limit: 200)
        let legacy = try await database.search(query: "needle", cursor: .init(rowID: deletedNormal, rank: nil), limit: 200)
        expectNoDifference(expected.results.map(\.id), legacy.results.map(\.id))
        XCTAssertEqual(legacy.results.count, 200)
        let nextLegacy = try await database.search(query: "needle",
            cursor: .init(rowID: try XCTUnwrap(legacy.results.last).id, rank: nil), limit: 200)
        XCTAssertTrue(Set(legacy.results.map(\.id)).isDisjoint(with: nextLegacy.results.map(\.id)))
        for ambiguous in [Int64(-11), 1, Int64.max - 2] {
            do {
                _ = try await database.search(query: "needle", cursor: .init(rowID: ambiguous, rank: nil), limit: 1)
                XCTFail("A deleted ambiguous timestamp-less cursor must retain its explicit error")
            } catch SessionSourceError.missingRecord(let identity) {
                XCTAssertEqual(identity, String(ambiguous))
            }
        }
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO message(id,source_file_id,session_id,source_key,seq,role,ts,loc_kind,char_count,prefix)
                SELECT ?,source_file_id,session_id,'maximum-normal',4001,'user',?,'byteRange',6,'needle'
                FROM message WHERE source_key='seed';
                INSERT INTO message_fts(rowid,body) VALUES(?,'needle');
                DELETE FROM message_fts WHERE rowid=?;
                DELETE FROM message WHERE id=?;
                """, arguments: [Int64.max, Int64.max >> 20, Int64.max, Int64.max - 1, Int64.max - 1])
        }
        let deletedHigh = try await database.search(query: "needle", cursor: clamped.nextCursor, limit: 1)
        XCTAssertEqual(deletedHigh.results.first?.id, Int64.max,
            "Deleted clamped cursor must include earlier timestamps with larger encoded IDs")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO message(id,source_file_id,session_id,source_key,seq,role,ts,loc_kind,char_count,prefix)
                SELECT 0,source_file_id,session_id,'zero-normal',4002,'user',0,'byteRange',6,'needle'
                FROM message WHERE source_key='seed';
                INSERT INTO message_fts(rowid,body) VALUES(0,'needle');
                """)
        }
        let deletedLow = try await database.search(query: "needle",
            cursor: .init(rowID: 1, rank: nil, timestampMilliseconds: -100), limit: 1)
        XCTAssertTrue(deletedLow.results.isEmpty,
            "A deleted negative-date cursor cannot admit later timestamp-zero rows")
    }
}
