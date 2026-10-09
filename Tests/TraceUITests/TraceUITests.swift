import XCTest
import AppKit
import os

@MainActor
final class TraceUITests: XCTestCase {
    private var nativeAnchorProbe: (app: XCUIApplication, input: URL, output: URL)?
    private var nativeAnchorSessionID: String?

    private func installNativeAnchorProbe(app: XCUIApplication, directory: URL) {
        let input = directory.appendingPathComponent("native-anchor-index")
        let output = directory.appendingPathComponent("native-anchor-offset")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_ANCHOR_INDEX_PATH"] = input.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_ANCHOR_POSITION_PATH"] = output.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_ANCHOR_SAMPLES_PATH"] = directory.appendingPathComponent("native-anchor-samples").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_COMPLETED_PATH"] = directory.appendingPathComponent("native-restore-completed").path
        nativeAnchorProbe = (app, input, output)
    }
    private func nativeMenu(titled title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %ld OR elementType == %ld",
            Int(XCUIElement.ElementType.menuButton.rawValue),
            Int(XCUIElement.ElementType.popUpButton.rawValue)
        )).matching(identifier: title).firstMatch
    }

    private func makeApp(extra: [String] = []) throws -> (XCUIApplication, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceUI-\(UUID())")
        let sources = directory.appendingPathComponent("Sources/Claude")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "one", "message": ["content": "Find the sample answer"]],
            ["type": "assistant", "uuid": "two", "message": ["content": [
                ["type": "text", "text": "Here is the visible answer"],
                ["type": "thinking", "thinking": "Reasoning explanation"],
                ["type": "tool_use", "name": "UniqueInvocation", "input": ["path": "sample"]]
            ]]],
            ["type": "user", "uuid": "three", "message": ["content": [
                ["type": "tool_result", "is_error": true, "content": "UniqueOutput: file missing"]
            ]]],
            ["type": "system", "uuid": "four", "message": ["content": "System marker"]],
            ["type": "user", "uuid": "five", "message": ["content": [
                ["type": "image", "source": ["type": "base64", "data": "not-indexed"]]
            ]]],
            ["type": "user", "uuid": "six", "message": ["content": [
                ["type": "tool_result", "is_error": true, "content": ""]
            ]]]
        ]
        var data = Data()
        let fixtureTimestamp = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        for (index, var object) in records.enumerated() {
            object["sessionId"] = "test-session"
            object["cwd"] = "/tmp/TraceUIExample"
            object["timestamp"] = fixtureTimestamp + Int64(index) * 1_000
            data.append(try JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        try data.write(to: sources.appendingPathComponent("session.jsonl"))
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + extra
        app.launchEnvironment["TRACE_TEST_DIRECTORY"] = directory.path
        let suiteName = "me.haroldmartin.Trace.tests.\(directory.lastPathComponent)"
        addTeardownBlock {
            app.terminate()
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return (app, directory)
    }

    func testOnboardingRadiosAndScopePersistence() throws {
        let (app, _) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.staticTexts["Find any agent session."].waitForExistence(timeout: 10))
        for title in ["Everything", "Prose + tool invocations", "Prose only", "Everything"] {
            let radio = app.radioButtons[title]
            XCTAssertTrue(radio.exists)
            radio.click()
            XCTAssertEqual(radio.value as? Int, 1)
        }
        app.buttons["Build Index"].click()
        let search = app.textFields["mainSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("UniqueOutput")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "UniqueOutput: file missing")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Build Index"].exists)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Trace Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Search"].exists)
        attach(app, name: "settings")
    }

    func testLaunchPreservesConfiguredClaudeRootStrings() throws {
        let (app, _) = try makeApp(extra: ["--ui-show-settings"])
        let configured = ["/tmp/TraceConfiguredRoot", "/tmp/TraceConfiguredRoot"]
        let encodedRoots = try JSONEncoder().encode(configured)
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(
            decoding: encodedRoots, as: UTF8.self
        )
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"

        app.launch()

        let settings = app.windows["Trace Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let sources = app.descendants(matching: .any)["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.click()
        let first = app.staticTexts["additionalClaudeRoot-0"]
        let second = app.staticTexts["additionalClaudeRoot-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists, "launch must preserve both durable root strings")

        app.buttons["removeAdditionalClaudeRoot-0"].click()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(second.exists, "one Remove click must delete only one duplicate row")
        app.terminate()
        app.launch()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["Sources"].firstMatch.click()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(second.exists, "the single remaining duplicate must persist across relaunch")
    }

    func testSourceRemovalDuringRecoveryLoadAppliesInSameLaunch() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-settings"])
        let additionalRoot = directory.appendingPathComponent("AdditionalClaude")
        try FileManager.default.createDirectory(
            at: additionalRoot, withIntermediateDirectories: true
        )
        let encodedRoots = try JSONEncoder().encode([additionalRoot.path])
        let recoveryStarted = directory.appendingPathComponent("recovery-load-started")
        let passCompleted = directory.appendingPathComponent("index-pass-completed")
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(
            decoding: encodedRoots, as: UTF8.self
        )
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        app.launchEnvironment["TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"] = "1"
        app.launchEnvironment["TRACE_TEST_RECOVERY_LOAD_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_RECOVERY_LOAD_STARTED_PATH"] = recoveryStarted.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path

        app.launch()

        XCTAssertTrue(waitForFile(recoveryStarted, timeout: 10))
        let settings = app.windows["Trace Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let sources = app.descendants(matching: .any)["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.click()
        let remove = app.buttons["removeAdditionalClaudeRoot-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(waitForFile(passCompleted, timeout: 20))

        let escapedPath = additionalRoot.path.replacingOccurrences(of: "'", with: "''")
        let persistedRoot = pollSQLiteInteger(
            directory.appendingPathComponent("index.sqlite"),
            sql: "SELECT count(*) FROM source_root WHERE path='\(escapedPath)'",
            timeout: 10, until: { $0 == 0 }
        )
        XCTAssertNil(persistedRoot.error)
        XCTAssertEqual(
            persistedRoot.value, 0,
            "the startup coordinator must use the source configuration changed during recovery"
        )
    }

    func testSourceRemovalDuringFailureCountLoadStillStartsIndexing() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-settings"])
        let additionalRoot = directory.appendingPathComponent("AdditionalClaude")
        try FileManager.default.createDirectory(at: additionalRoot, withIntermediateDirectories: true)
        let encodedRoots = try JSONEncoder().encode([additionalRoot.path])
        let countsStarted = directory.appendingPathComponent("failure-counts-started")
        let releaseCounts = directory.appendingPathComponent("release-failure-counts")
        let passCompleted = directory.appendingPathComponent("index-pass-completed")
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(
            decoding: encodedRoots, as: UTF8.self
        )
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        app.launchEnvironment["TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"] = "1"
        app.launchEnvironment["TRACE_TEST_FAILURE_COUNTS_HOLD_MS"] = "30000"
        app.launchEnvironment["TRACE_TEST_FAILURE_COUNTS_STARTED_PATH"] = countsStarted.path
        app.launchEnvironment["TRACE_TEST_FAILURE_COUNTS_RELEASE_PATH"] = releaseCounts.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path
        app.launch()

        XCTAssertTrue(waitForFile(countsStarted, timeout: 15))
        let settings = app.windows["Trace Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["Sources"].firstMatch.click()
        let remove = app.buttons["removeAdditionalClaudeRoot-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        try Data().write(to: releaseCounts)

        XCTAssertTrue(waitForFile(passCompleted, timeout: 25),
                      "startup indexing must still run after the source revision changes")
        let escaped = additionalRoot.path.replacingOccurrences(of: "'", with: "''")
        let persisted = pollSQLiteInteger(
            directory.appendingPathComponent("index.sqlite"),
            sql: "SELECT count(*) FROM source_root WHERE path='\(escaped)'",
            timeout: 10, until: { $0 == 0 }
        )
        XCTAssertNil(persisted.error)
        XCTAssertEqual(persisted.value, 0)
    }

    func testRemovingRootAfterRecoveryReadDropsItsQueuedWork() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-settings"])
        let additionalRoot = directory.appendingPathComponent("AdditionalClaude")
        try FileManager.default.createDirectory(at: additionalRoot, withIntermediateDirectories: true)
        let encodedRoots = try JSONEncoder().encode([additionalRoot.path])
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(
            decoding: encodedRoots, as: UTF8.self
        )
        app.launchEnvironment["TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"] = "1"
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        let initialPass = directory.appendingPathComponent("initial-pass-complete")
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = initialPass.path
        app.launch()
        XCTAssertTrue(waitForFile(initialPass, timeout: 15))
        app.terminate()

        let database = directory.appendingPathComponent("index.sqlite")
        let escaped = additionalRoot.path.replacingOccurrences(of: "'", with: "''")
        let insert = Process()
        insert.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        insert.arguments = [database.path, """
            INSERT INTO source_scan_error(root_id, relative_scope, error, updated_at_ms)
            SELECT id, '', 'old root failure', 0 FROM source_root
            WHERE path='\(escaped)';
            """]
        try insert.run()
        insert.waitUntilExit()
        XCTAssertEqual(insert.terminationStatus, 0)
        XCTAssertEqual(try sqliteInteger(database, sql: "SELECT count(*) FROM source_scan_error WHERE error='old root failure'"), 1)

        let recoveryLoaded = directory.appendingPathComponent("recovery-loaded")
        let activityAudit = directory.appendingPathComponent("startup-recovery-activity")
        let startupPass = directory.appendingPathComponent("recovery-startup-pass-completed")
        app.launchEnvironment["TRACE_TEST_RECOVERY_LOADED_DELAY_MS"] = "8000"
        app.launchEnvironment["TRACE_TEST_RECOVERY_LOADED_PATH"] = recoveryLoaded.path
        app.launchEnvironment["TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"] = activityAudit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = startupPass.path
        app.launch()
        XCTAssertTrue(waitForFile(recoveryLoaded, timeout: 15))
        let settings = app.windows["Trace Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["Sources"].firstMatch.click()
        let remove = app.buttons["removeAdditionalClaudeRoot-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        let rootCount = pollSQLiteInteger(
            database, sql: "SELECT count(*) FROM source_root WHERE path='\(escaped)'",
            timeout: 15, until: { $0 == 0 }
        )
        XCTAssertNil(rootCount.error)
        XCTAssertEqual(rootCount.value, 0)
        XCTAssertEqual(try sqliteInteger(database, sql: "SELECT count(*) FROM source_scan_error WHERE error='old root failure'"), 0)
        XCTAssertTrue(waitForFile(startupPass, timeout: 20),
                      "startup indexing must settle after the root is removed")
        XCTAssertFalse(fileLines(in: activityAudit).contains("subtreeRecovery"),
                       "removed-root recovery must not leak into startup indexing")
    }

    func testAddingEmptyRootDuringStartupKeepsCachedCostsVisible() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        func waitForCachedTokens(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !app.staticTexts["Estimated equivalent API spend"].exists {
                    app.radioButtons["Costs"].click()
                }
                if app.staticTexts["10"].waitForExistence(timeout: 2) { return true }
            }
            return false
        }
        let usage: [String: Any] = [
            "type": "assistant", "uuid": "cached-startup-cost", "sessionId": "cached-cost-session",
            "cwd": "/tmp/TraceUIExample",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["id": "cached-startup-response", "model": "claude-sonnet-5",
                        "content": "Cached cost", "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        try (JSONSerialization.data(withJSONObject: usage) + Data([10])).write(
            to: directory.appendingPathComponent("Sources/Claude/cached-cost.jsonl")
        )
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        app.launchEnvironment["TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"] = "1"
        app.launch()
        XCTAssertTrue(app.radioButtons["Costs"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForCachedTokens(timeout: 20))
        app.terminate()

        let emptyRoot = directory.appendingPathComponent("EmptyAdditionalRoot")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let finalizing = directory.appendingPathComponent("startup-finalizing")
        let releaseFinalization = directory.appendingPathComponent("release-startup-finalization")
        app.launchEnvironment["TRACE_TEST_STARTUP_FINALIZATION_DELAY_MS"] = "30000"
        app.launchEnvironment["TRACE_TEST_STARTUP_FINALIZATION_PATH"] = finalizing.path
        app.launchEnvironment["TRACE_TEST_STARTUP_FINALIZATION_RELEASE_PATH"] = releaseFinalization.path
        app.launchEnvironment["TRACE_TEST_PICK_CLAUDE_ROOT_PATH"] = emptyRoot.path
        app.launch()
        XCTAssertTrue(waitForFile(finalizing, timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Trace Settings"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["Sources"].firstMatch.click()
        app.buttons["Add Folder…"].click()
        XCTAssertTrue(app.staticTexts["additionalClaudeRoot-0"].waitForExistence(timeout: 5))
        try Data().write(to: releaseFinalization)
        let main = app.windows["Trace"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        if main.exists { main.click() }
        XCTAssertTrue(waitForCachedTokens(timeout: 25),
                      "an empty root change must not prevent cached Costs from loading")
    }

    func testSourceReplacementDuringOnboardingMetadataStartUsesNewestGeneration() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let additional = directory.appendingPathComponent("AdditionalClaude")
        try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(decoding: try JSONEncoder().encode([additional.path]), as: UTF8.self)
        app.launchEnvironment["TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"] = "1"
        let entered = directory.appendingPathComponent("metadata-entered")
        let release = directory.appendingPathComponent("metadata-release")
        let audit = directory.appendingPathComponent("metadata-audit")
        let completed = directory.appendingPathComponent("index-completed")
        app.launchEnvironment["TRACE_TEST_METADATA_START_DELAY_MS"] = "30000"
        app.launchEnvironment["TRACE_TEST_METADATA_START_ENTERED_PATH"] = entered.path
        app.launchEnvironment["TRACE_TEST_METADATA_START_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_METADATA_START_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(waitForFile(entered, timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Trace Settings"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["Sources"].firstMatch.click()
        let remove = app.buttons["removeAdditionalClaudeRoot-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.fileLines(in: audit).filter { $0.hasPrefix("enter,") }.count >= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 10), .completed)
        try Data().write(to: release)
        XCTAssertTrue(waitForFile(completed, timeout: 25))
        let starts = fileLines(in: audit).filter { $0.hasPrefix("started,") }
        XCTAssertEqual(starts.count, 1, "stale startup must not report success")
        XCTAssertTrue(starts.first?.contains("revision=1") == true)
        XCTAssertEqual(try sqliteInteger(directory.appendingPathComponent("index.sqlite"),
            sql: "SELECT count(*) FROM source_root WHERE path='\(additional.path)'"), 0)
    }

    func testMonitoringWarningsPreserveOtherErrorsAndRecoverWithoutAlerts() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let codex = directory.appendingPathComponent("Sources/Codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let sidecar = directory.appendingPathComponent("Sources/session_index.jsonl")
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: "session_index.jsonl")
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        app.launchEnvironment["TRACE_TEST_SEED_STARTUP_ERROR"] = "Unrelated startup failure"
        app.launch()
        XCTAssertTrue(app.staticTexts["Unrelated startup failure"].firstMatch.waitForExistence(timeout: 15))
        app.sheets.firstMatch.buttons["OK"].click()
        let status = app.buttons["indexProgress"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        status.click()
        let warning = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "incomplete Codex metadata monitoring")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        status.click()
        try FileManager.default.removeItem(at: sidecar)
        try Data("{}\n".utf8).write(to: sidecar)
        status.click()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !warning.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testBlockedFilesystemCallbackDoesNotBlockSourceReplacement() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let additional = directory.appendingPathComponent("AdditionalClaude")
        try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(decoding: try JSONEncoder().encode([additional.path]), as: UTF8.self)
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        app.launchEnvironment["TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"] = "1"
        app.launchEnvironment["TRACE_TEST_GATE_FILESYSTEM_CALLBACK"] = "1"
        app.launchEnvironment["TRACE_TEST_GATE_FILESYSTEM_ROOT_CONTAINS"] = "AdditionalClaude"
        let entered = directory.appendingPathComponent("callback-entered")
        let release = directory.appendingPathComponent("callback-release")
        let completed = directory.appendingPathComponent("index-completed")
        app.launchEnvironment["TRACE_TEST_FILESYSTEM_CALLBACK_ENTERED_PATH"] = entered.path
        app.launchEnvironment["TRACE_TEST_FILESYSTEM_CALLBACK_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        app.launch()
        XCTAssertTrue(waitForFile(completed, timeout: 25))
        try FileManager.default.removeItem(at: completed)
        try Data("{}\n".utf8).write(to: additional.appendingPathComponent("callback-trigger.jsonl"))
        XCTAssertTrue(waitForFile(entered, timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Trace Settings"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["Sources"].firstMatch.click()
        app.buttons["removeAdditionalClaudeRoot-0"].click()
        app.descendants(matching: .any)["General"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["clearGlobalSearchOnClose"].firstMatch.waitForExistence(timeout: 3),
                      "main actor must remain responsive while old callbacks drain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
        try Data().write(to: release)
        XCTAssertTrue(waitForFile(completed, timeout: 25))
    }

    func testPartialWatcherStartupFailureStillRunsInitialIndexing() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let codex = directory.appendingPathComponent("Sources/Codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let encodedRoots = try JSONEncoder().encode(["/tmp/TraceRootRecoveryTrigger"])
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(
            decoding: encodedRoots, as: UTF8.self
        )
        let activityAudit = directory.appendingPathComponent("startup-activity-audit")
        app.launchEnvironment["TRACE_TEST_SPLIT_WATCHERS_BY_ROOT"] = "1"
        app.launchEnvironment["TRACE_TEST_FAIL_WATCHER_ROOT_CONTAINS"] = "/Claude"
        app.launchEnvironment["TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"] = activityAudit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))

        app.buttons["Build Index"].click()

        XCTAssertTrue(app.staticTexts["Find the sample answer"].firstMatch.waitForExistence(
            timeout: 15
        ), "a failed watcher must not prevent initial indexing")
        app.buttons["indexProgress"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "periodic reconciliation"
        )).firstMatch.waitForExistence(timeout: 5))
        app.buttons["indexProgress"].click()

        let rollout = codex.appendingPathComponent("rollout-live.jsonl")
        let live = [
            #"{"type":"session_meta","timestamp":"2026-09-20T18:00:00Z","payload":{"id":"watcher-live","cwd":"/tmp/WatcherLive"}}"#,
            #"{"type":"response_item","timestamp":"2026-09-20T18:00:01Z","payload":{"type":"message","id":"watcher-message","role":"user","content":[{"type":"input_text","text":"Successful watcher live marker"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(live.utf8).write(to: rollout)
        let checkpointDatabase = directory.appendingPathComponent("index.sqlite")
        let messageResult = pollSQLiteInteger(
            checkpointDatabase,
            sql: "SELECT count(*) FROM message WHERE prefix='Successful watcher live marker'",
            timeout: 15, until: { $0 == 1 }
        )
        XCTAssertNil(messageResult.error, "the message-count sqlite3 query must succeed")
        XCTAssertEqual(
            messageResult.value, 1,
            "a successful watcher must remain active after a sibling watcher fails"
        )
        let checkpointResult = pollSQLiteInteger(
            checkpointDatabase, sql: "SELECT count(*) FROM fsevents_checkpoint",
            timeout: 15, until: { $0 >= 2 }
        )
        XCTAssertNil(checkpointResult.error, "the checkpoint-count sqlite3 query must succeed")
        XCTAssertNotNil(
            checkpointResult.value,
            "split source and metadata watcher checkpoints must be persisted"
        )
        XCTAssertEqual(try sqliteInteger(
            checkpointDatabase,
            sql: "SELECT count(*) FROM fsevents_checkpoint WHERE volume_id NOT LIKE '%:root:%'"
        ), 0, "split watcher checkpoint identifiers must use the opaque root-key format")
        XCTAssertEqual(try sqliteInteger(
            checkpointDatabase,
            sql: "SELECT count(*) FROM fsevents_checkpoint WHERE volume_id LIKE '%\(directory.lastPathComponent)%'"
        ), 0, "test grouping must not leak root paths into persisted checkpoint identifiers")

        try? FileManager.default.removeItem(at: activityAudit)
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Trace Settings"].waitForExistence(timeout: 5))
        let sources = app.descendants(matching: .any)["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.click()
        let remove = app.buttons["removeAdditionalClaudeRoot-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(waitForLineCount(
            activityAudit, line: "rootRecovery", count: 1, timeout: 15
        ), "a failed sibling watcher must not downgrade forced root recovery")
    }

    func testExternalCodexSidecarTargetChangeRefreshesTitle() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let activityAudit = directory.appendingPathComponent("sidecar-index-activity")
        app.launchEnvironment["TRACE_TEST_INDEX_ACTIVITY_AUDIT_PATH"] = activityAudit.path
        let codex = directory.appendingPathComponent("Sources/Codex")
        let watcherAudit = directory.appendingPathComponent("watcher-reconfiguration-audit")
        app.launchEnvironment["TRACE_TEST_WATCHER_RECONFIG_AUDIT_PATH"] = watcherAudit.path
        defer {
            let diagnostic = XCTAttachment(string: fileLines(in: watcherAudit).joined(separator: "\n"))
            diagnostic.name = "Watcher reconfiguration"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        let targets = directory.appendingPathComponent("SidecarTargets")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true)
        let rollout = [
            #"{"type":"session_meta","payload":{"id":"linked-sidecar-live","cwd":"/tmp/LinkedSidecar"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Linked sidecar request"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(rollout.utf8).write(to: codex.appendingPathComponent("rollout-linked.jsonl"))
        let target = targets.appendingPathComponent("arbitrary-name.jsonl")
        try Data(#"{"id":"linked-sidecar-live","thread_name":"Initial linked title"}"#.utf8
            + Data([10])).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Sources/session_index.jsonl"),
            withDestinationURL: target
        )

        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let database = directory.appendingPathComponent("index.sqlite")
        let initial = pollSQLiteInteger(database, sql: """
            SELECT count(*) FROM session WHERE external_id='linked-sidecar-live'
            AND generated_title='Initial linked title'
            """, timeout: 20, until: { $0 == 1 })
        XCTAssertNil(initial.error)
        XCTAssertEqual(initial.value, 1)

        try Data(#"{"id":"linked-sidecar-live","thread_name":"Updated linked title"}"#.utf8
            + Data([10])).write(to: target)
        let updated = pollSQLiteInteger(database, sql: """
            SELECT count(*) FROM session WHERE external_id='linked-sidecar-live'
            AND generated_title='Updated linked title'
            """, timeout: 20, until: { $0 == 1 })
        XCTAssertNil(updated.error)
        XCTAssertEqual(updated.value, 1,
            "the external target's watcher event must refresh the configured sidecar cache")
        XCTAssertTrue(waitForLineCount(activityAudit, line: "fileChanges", count: 1, timeout: 10))
        let rootRecoveries = fileLines(in: activityAudit).filter { $0 == "rootRecovery" }.count
        let auditCountBeforeRepoint = fileLines(in: watcherAudit).count

        let replacementDirectory = directory.appendingPathComponent("ReplacementTargets")
        try FileManager.default.createDirectory(
            at: replacementDirectory, withIntermediateDirectories: true
        )
        let replacement = replacementDirectory.appendingPathComponent("new-name.jsonl")
        try Data(#"{"id":"linked-sidecar-live","thread_name":"Repointed linked title"}"#.utf8
            + Data([10])).write(to: replacement)
        let sidecar = directory.appendingPathComponent("Sources/session_index.jsonl")
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: replacement)
        let repointed = pollSQLiteInteger(database, sql: """
            SELECT count(*) FROM session WHERE external_id='linked-sidecar-live'
            AND generated_title='Repointed linked title'
            """, timeout: 20, until: { $0 == 1 })
        XCTAssertNil(repointed.error)
        XCTAssertEqual(repointed.value, 1)

        try Data(#"{"id":"linked-sidecar-live","thread_name":"Updated repointed title"}"#.utf8
            + Data([10])).write(to: replacement)
        let afterRepoint = pollSQLiteInteger(database, sql: """
            SELECT count(*) FROM session WHERE external_id='linked-sidecar-live'
            AND generated_title='Updated repointed title'
            """, timeout: 20, until: { $0 == 1 })
        XCTAssertNil(afterRepoint.error)
        XCTAssertEqual(afterRepoint.value, 1,
            "repointing must register the replacement target's directory")
        XCTAssertEqual(fileLines(in: activityAudit).filter { $0 == "rootRecovery" }.count,
                       rootRecoveries, "sidecar repointing must not reconcile all transcript roots")
        let repointChanges = fileLines(in: watcherAudit).dropFirst(auditCountBeforeRepoint)
            .filter { $0.hasPrefix("paths=") }
        XCTAssertFalse(repointChanges.isEmpty)
        XCTAssertTrue(repointChanges.allSatisfy { $0.contains("reconcile=[]") },
                      "sidecar repointing must request only file refreshes: \(repointChanges)")
    }

    func testRecoveryLoadFailureQueuesRootFallbackAndStartupContinues() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let activityAudit = directory.appendingPathComponent("startup-activity-audit")
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        app.launchEnvironment["TRACE_TEST_FAIL_RECOVERY_LOAD_ONCE"] = "1"
        app.launchEnvironment["TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"] = activityAudit.path

        app.launch()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "Could not load pending index recovery"
        )).firstMatch.waitForExistence(timeout: 10))
        let dismiss = app.sheets.buttons["OK"].firstMatch
        if dismiss.exists { dismiss.click() }
        XCTAssertTrue(app.staticTexts["Find the sample answer"].firstMatch.waitForExistence(
            timeout: 15
        ), "recovery metadata failure must not prevent initial indexing")
        XCTAssertTrue(waitForLineCount(
            activityAudit, line: "rootRecovery", count: 1, timeout: 15
        ), "startup must queue a whole-root recovery fallback")
    }

    func testRecoveryLoadFailureWaitsForOnboardingThenRunsOneRootPass() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let activityAudit = directory.appendingPathComponent("startup-activity-audit")
        let passAudit = directory.appendingPathComponent("index-activity-audit")
        let recoveryLoadStarted = directory.appendingPathComponent("recovery-load-started")
        app.launchEnvironment["TRACE_TEST_FAIL_RECOVERY_LOAD_ONCE"] = "1"
        app.launchEnvironment["TRACE_TEST_RECOVERY_LOAD_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_RECOVERY_LOAD_STARTED_PATH"] = recoveryLoadStarted.path
        app.launchEnvironment["TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"] = activityAudit.path
        app.launchEnvironment["TRACE_TEST_INDEX_ACTIVITY_AUDIT_PATH"] = passAudit.path

        app.launch()

        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(recoveryLoadStarted, timeout: 10))
        XCTAssertFalse(
            waitForLineCount(activityAudit, line: "rootRecovery", count: 1, timeout: 2),
            "recovery fallback must remain pending until onboarding finishes"
        )
        XCTAssertEqual(
            try sqliteInteger(
                directory.appendingPathComponent("index.sqlite"),
                sql: "SELECT count(*) FROM source_file"
            ),
            0
        )

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "Could not load pending index recovery"
        )).firstMatch.waitForExistence(timeout: 10))
        let dismiss = app.sheets.buttons["OK"].firstMatch
        if dismiss.exists { dismiss.click() }

        let mainWindow = app.windows["Trace"]
        if mainWindow.exists {
            let close = mainWindow.buttons["_XCUI:CloseWindow"]
            if close.exists { close.click() }
        }
        app.activate()
        app.buttons["Build Index"].click()

        XCTAssertTrue(app.staticTexts["Find the sample answer"].firstMatch.waitForExistence(
            timeout: 15
        ))
        XCTAssertTrue(waitForLineCount(
            activityAudit, line: "rootRecovery", count: 1, timeout: 15
        ))
        XCTAssertTrue(waitForLineCount(
            passAudit, line: "rootRecovery", count: 1, timeout: 15
        ))
        let safetyTimestamp = pollSQLiteInteger(
            directory.appendingPathComponent("index.sqlite"),
            sql: "SELECT count(*) FROM trace_meta WHERE key='last_safety_reconciliation_ms'",
            timeout: 10, until: { $0 == 1 }
        )
        XCTAssertNil(safetyTimestamp.error)
        XCTAssertEqual(safetyTimestamp.value, 1)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(
            fileLines(in: activityAudit).filter { $0 == "rootRecovery" }.count,
            1,
            "pending recovery and onboarding startup must merge into one pass"
        )
        XCTAssertFalse(fileLines(in: passAudit).contains("safetyVerification"),
                       "the merged pass must suppress the three-second safety retry")
    }

    func testForcedRootChangeOnEmptyIndexReportsInitialBuild() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-settings"])
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("Sources/Claude/session.jsonl")
        )
        let encodedRoots = try JSONEncoder().encode(["/tmp/TraceEmptyRootRecoveryTrigger"])
        app.launchEnvironment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"] = String(
            decoding: encodedRoots, as: UTF8.self
        )
        app.launchEnvironment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] = "1"
        let activityAudit = directory.appendingPathComponent("startup-activity-audit")
        let passCompleted = directory.appendingPathComponent("initial-pass-completed")
        app.launchEnvironment["TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"] = activityAudit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path

        app.launch()

        let settings = app.windows["Trace Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(passCompleted, timeout: 15))
        try? FileManager.default.removeItem(at: activityAudit)
        let sources = app.descendants(matching: .any)["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.click()
        let remove = app.buttons["removeAdditionalClaudeRoot-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        XCTAssertTrue(waitForLineCount(
            activityAudit, line: "initialBuild", count: 1, timeout: 15
        ), "forced reconciliation without cached source files must remain an initial build")
    }

    func testTranscriptVisibilityDensityProjectFilterAndErrorHover() throws {
        let (app, _) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let session = app.staticTexts["Find the sample answer"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.click()
        XCTAssertTrue(app.windows["Find the sample answer"].waitForExistence(timeout: 5))
        let metadataHeader = app.descendants(matching: .any)
            .matching(identifier: "transcriptMetadataHeader").firstMatch
        XCTAssertTrue(metadataHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(metadataHeader.staticTexts["Source: Claude Code"].exists)
        XCTAssertTrue(metadataHeader.staticTexts["6 messages"].exists)
        XCTAssertTrue(metadataHeader.buttons["Reveal"].exists)
        XCTAssertTrue(metadataHeader.buttons["Copy"].exists)
        XCTAssertEqual(metadataHeader.staticTexts.matching(NSPredicate(
            format: "value == %@", "Find the sample answer"
        )).count, 0, "the session title should remain in the window chrome, not the transcript content")
        XCTAssertTrue(app.scrollViews["transcriptScroll"].staticTexts.matching(NSPredicate(
            format: "value == %@", "Find the sample answer"
        )).firstMatch.waitForExistence(timeout: 5), "the original user message must remain visible")
        let visibleAnswer = app.staticTexts["Here is the visible answer"].firstMatch
        XCTAssertTrue(visibleAnswer.waitForExistence(timeout: 10))
        let pasteboardChangeCount = preparePasteboardForCopy()
        visibleAnswer.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        assertPasteboardChanged(
            after: pasteboardChangeCount, contains: ["Here is the visible answer"],
            message: "clicking message text must preserve text selection and copy focus"
        )
        let toolDisclosure = app.buttons["Tool invocation"].firstMatch
        XCTAssertTrue(toolDisclosure.waitForExistence(timeout: 5))
        toolDisclosure.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "UniqueInvocation"
        )).firstMatch.waitForExistence(timeout: 5))
        let reasoningDisclosure = app.buttons["Reasoning"].firstMatch
        XCTAssertTrue(reasoningDisclosure.waitForExistence(timeout: 5))
        reasoningDisclosure.click()
        XCTAssertTrue(app.staticTexts["Reasoning explanation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["Tools"].waitForExistence(timeout: 5))
        app.checkBoxes["Tools"].click()
        app.checkBoxes["System"].click()
        app.checkBoxes["Reasoning"].click()
        app.radioButtons["Compact"].click()
        XCTAssertFalse(app.staticTexts["System marker"].exists)
        XCTAssertFalse(app.staticTexts["Tool invocation"].exists)
        XCTAssertFalse(app.staticTexts["Reasoning explanation"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "UniqueInvocation")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Image or attachment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Error details hidden by current toggles."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Error recorded without text details."].waitForExistence(timeout: 5))
        let filter = app.textFields["projectFilter"]
        filter.click()
        filter.typeText("Find the sample answer")
        XCTAssertFalse(app.staticTexts["TraceUIExample"].exists, "project filter must not match transcript content")
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        let icon = app.images["Session error"].firstMatch
        if icon.exists {
            icon.hover()
            let detail = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "UniqueOutput: file missing")).firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            detail.hover()
            XCTAssertTrue(detail.exists, "moving from the icon into the popover must keep it open")
        } else { XCTFail("Session error icon missing") }
        attach(app, name: "compact-and-error-details")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.checkBoxes["Tools"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.checkBoxes["Tools"].value as? Int, 0)
        XCTAssertEqual(app.checkBoxes["System"].value as? Int, 0)
        XCTAssertEqual(app.checkBoxes["Reasoning"].value as? Int, 0)
        XCTAssertEqual(app.radioButtons["Compact"].value as? Int, 1)
    }

    func testLiveAppendRetainsHydratedTranscriptRows() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let session = app.staticTexts["Find the sample answer"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.click()
        let existing = app.staticTexts["Here is the visible answer"]
        XCTAssertTrue(existing.waitForExistence(timeout: 10))

        let file = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let appended: [String: Any] = [
            "type": "assistant", "uuid": "live-append", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:10Z",
            "message": ["content": "Live append arrived"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended))
        try handle.write(contentsOf: Data([10]))
        try handle.close()

        XCTAssertTrue(app.staticTexts["Live append arrived"].waitForExistence(timeout: 15))
        XCTAssertTrue(existing.exists, "an append must not discard already hydrated message bodies")
    }

    func testErrorPopoverInvalidatesAfterNewFailure() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let icon = app.images["Session error"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 15))
        icon.hover()
        let originalDetail = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "UniqueOutput: file missing"
        )).firstMatch
        XCTAssertTrue(originalDetail.waitForExistence(timeout: 5))

        let file = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let ordinary: [String: Any] = [
            "type": "assistant", "uuid": "ordinary-append", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:09Z",
            "message": ["content": "Ordinary append while reading errors"],
        ]
        let ordinaryHandle = try FileHandle(forWritingTo: file)
        try ordinaryHandle.seekToEnd()
        try ordinaryHandle.write(contentsOf: JSONSerialization.data(withJSONObject: ordinary) + Data([10]))
        try ordinaryHandle.close()
        XCTAssertTrue(app.staticTexts["7 messages"].waitForExistence(timeout: 15))
        XCTAssertTrue(originalDetail.exists, "an ordinary append must keep the error popover open")

        let appended: [String: Any] = [
            "type": "user", "uuid": "later-failure", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:10Z",
            "message": ["content": [["type": "tool_result", "is_error": true,
                                    "content": "Later failure detail"]]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended) + Data([10]))
        try handle.close()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "Later failure detail"
        )).firstMatch.waitForExistence(timeout: 15), "the open popover must reload on a new failure")
    }

    func testCancelledErrorPopoverLoadRetriesWhenRowReturns() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let source = directory.appendingPathComponent("Sources/Claude")
        for index in 0..<35 {
            let row: [String: Any] = [
                "type": "user", "uuid": "older-\(index)", "sessionId": "older-\(index)",
                "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T09:00:00Z",
                "message": ["content": "Older session \(index)"],
            ]
            try (JSONSerialization.data(withJSONObject: row) + Data([10]))
                .write(to: source.appendingPathComponent("older-\(index).jsonl"))
        }
        app.launchEnvironment["TRACE_TEST_ERROR_LOAD_DELAY_MS"] = "2000"
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let list = app.descendants(matching: .any).matching(identifier: "sessionSidebarList").firstMatch
        XCTAssertTrue(list.exists)
        let errorIcons = app.descendants(matching: .any).matching(identifier: "sessionError")
        var visibleIcon = firstHittable(in: errorIcons, timeout: 5)
        if visibleIcon == nil {
            list.scroll(byDeltaX: 0, deltaY: -5_000)
            visibleIcon = firstHittable(in: errorIcons, timeout: 5)
        }
        if visibleIcon == nil {
            list.scroll(byDeltaX: 0, deltaY: 10_000)
            visibleIcon = firstHittable(in: errorIcons, timeout: 5)
        }
        let icon = try XCTUnwrap(visibleIcon)
        icon.hover()
        XCTAssertTrue(app.staticTexts["Loading error details…"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        var offscreenDelta: CGFloat = -5_000
        list.scroll(byDeltaX: 0, deltaY: offscreenDelta)
        if icon.isHittable {
            offscreenDelta = 5_000
            list.scroll(byDeltaX: 0, deltaY: offscreenDelta)
        }
        XCTAssertFalse(icon.isHittable)
        list.scroll(byDeltaX: 0, deltaY: -offscreenDelta)
        let returnedIcon = try XCTUnwrap(firstHittable(in: errorIcons, timeout: 10))
        returnedIcon.hover()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "UniqueOutput: file missing"
        )).firstMatch.waitForExistence(timeout: 10))
    }

    func testPaginatedSearchOffersManualRefreshAfterIndexChange() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/paginated.jsonl")
        var data = Data()
        for index in 0..<215 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "paged-\(index)", "sessionId": "paged-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "PaginatedNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("PaginatedNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let originalTop = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "PaginatedNeedle row 214"
        )).firstMatch
        XCTAssertTrue(originalTop.waitForExistence(timeout: 10))
        for _ in 0..<3 { scroll.scroll(byDeltaX: 0, deltaY: -20_000) }
        XCTAssertFalse(originalTop.isHittable)

        let appended: [String: Any] = [
            "type": "assistant", "uuid": "paged-new", "sessionId": "paged-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_400_000,
            "message": ["content": "PaginatedNeedle newest row"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended) + Data([10]))
        try handle.close()
        let refresh = app.buttons["refreshSearchResults"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        XCTAssertFalse(originalTop.isHittable, "marking results stale must keep the current scroll position")
        refresh.click()
        XCTAssertFalse(app.staticTexts["Results may be out of date."].exists)
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "PaginatedNeedle newest row"
        )).firstMatch.waitForExistence(timeout: 10))
    }

    func testSearchUpdatesDuringControlledLongIndexPass() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/live-rebuild.jsonl")
        let committed = directory.appendingPathComponent("index-batch-committed")
        let release = directory.appendingPathComponent("index-batch-release")
        defer { try? Data().write(to: release) }
        var data = Data()
        for index in 0..<750 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "stream-\(index)", "sessionId": "stream-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "StreamingNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launchEnvironment["TRACE_TEST_INDEX_BATCH_COMMITTED_PATH"] = committed.path
        app.launchEnvironment["TRACE_TEST_INDEX_BATCH_RELEASE_PATH"] = release.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(waitForFile(committed, timeout: 15), "the first batch must commit before search observation")
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.click()
        query.typeText("StreamingNeedle")
        let early = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StreamingNeedle row"
        )).firstMatch
        XCTAssertTrue(early.waitForExistence(timeout: 8),
                      "a committed batch must refresh active search before the pass finishes")
        let progress = app.descendants(matching: .any).matching(identifier: "indexProgress").firstMatch
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(progress.label.contains("Indexing"),
                      "the first result must arrive while indexing is still running")
        let newest = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StreamingNeedle row 749"
        )).firstMatch
        XCTAssertFalse(newest.exists, "the final batch must remain uncommitted while early results are observed")
        try Data().write(to: release)
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
    }

    func testAutomaticSearchRefreshKeepsVisibleResultAnchor() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let file = directory.appendingPathComponent("Sources/Claude/anchor.jsonl")
        let completed = directory.appendingPathComponent("anchor-refresh-completed")
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_COMPLETED_PATH"] = completed.path
        let baseTimestamp = Int64(Date().timeIntervalSince1970 * 1_000) - 120_000
        var data = Data()
        for index in 0..<90 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "anchor-\(index)", "sessionId": "anchor-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": baseTimestamp + Int64(index) * 1_000,
                "message": ["content": "AnchorNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
        popoverSearch.click()
        popoverSearch.typeText("AnchorNeedle")
        popoverSearch.typeKey(.return, modifierFlags: [])
        let query = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        let dateMenu = app.descendants(matching: .any)["searchDateFilter"].firstMatch
        XCTAssertTrue(dateMenu.waitForExistence(timeout: 10))
        dateMenu.click()
        app.menuItems["7 days"].click()
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "AnchorNeedle row 89"
        )).firstMatch.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -850)
        let anchor = try XCTUnwrap(firstHittable(
            in: app.buttons.containing(NSPredicate(
                format: "label CONTAINS %@", "AnchorNeedle row"
            ))
        ))
        let anchorY = anchor.frame.minY

        let appended: [String: Any] = [
            "type": "assistant", "uuid": "anchor-new", "sessionId": "anchor-session",
            "cwd": "/tmp/TraceUIExample",
            "timestamp": Int64(Date().timeIntervalSince1970 * 1_000),
            "message": ["content": "AnchorNeedle newest row"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended) + Data([10]))
        try handle.close()
        XCTAssertTrue(waitForLineCount(completed, line: "results:91", count: 1, timeout: 15),
                      "the relative-date automatic refresh must complete without changing criteria")
        Thread.sleep(forTimeInterval: 1)
        let retained = NSPredicate { _, _ in
            anchor.isHittable && abs(anchor.frame.minY - anchorY) <= 35
        }
        expectation(for: retained, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        scroll.scroll(byDeltaX: 0, deltaY: 20_000)
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "AnchorNeedle newest row"
        )).firstMatch.waitForExistence(timeout: 15))
    }

    func testManualScrollDuringMainAutomaticRefreshWinsOverSavedAnchor() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/manual-anchor.jsonl")
        let started = directory.appendingPathComponent("manual-refresh-started")
        let completed = directory.appendingPathComponent("manual-refresh-completed")
        let passCompleted = directory.appendingPathComponent("manual-index-pass-completed")
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_STARTED_PATH"] = started.path
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path
        var data = Data()
        for index in 0..<90 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "manual-\(index)", "sessionId": "manual-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "ManualAnchorNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(waitForFile(passCompleted, timeout: 15))
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        app.activate()
        XCTAssertTrue(query.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        XCTAssertTrue(query.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "main search must be interactive after onboarding finishes dismissing")
        query.click()
        query.typeText("ManualAnchorNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        scroll.scroll(byDeltaX: 0, deltaY: -700)
        try? FileManager.default.removeItem(at: started)
        try? FileManager.default.removeItem(at: completed)
        try? FileManager.default.removeItem(at: passCompleted)
        let appended: [String: Any] = [
            "type": "assistant", "uuid": "manual-new", "sessionId": "manual-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_200_000,
            "message": ["content": "ManualAnchorNeedle newest row"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended) + Data([10]))
        try handle.close()
        XCTAssertTrue(waitForFile(passCompleted, timeout: 15))
        XCTAssertTrue(waitForFile(started, timeout: 15))
        scroll.scroll(byDeltaX: 0, deltaY: -350)
        let manual = try XCTUnwrap(firstHittable(
            in: app.buttons.containing(NSPredicate(
                format: "label CONTAINS %@", "ManualAnchorNeedle row"
            ))
        ))
        let y = manual.frame.minY
        let refreshed = waitForLineCount(completed, line: "results:91", count: 1, timeout: 15)
        let completedAudit = (try? String(contentsOf: completed, encoding: .utf8)) ?? "missing"
        XCTAssertTrue(refreshed,
                      "the automatic refresh must include the appended result; audit: \(completedAudit)")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(manual.isHittable)
        XCTAssertLessThanOrEqual(abs(manual.frame.minY - y), 35)
    }

    func testScrollerDuringNativeAutomaticRefreshWinsWithoutStealingFocus() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let file = directory.appendingPathComponent("Sources/Claude/native-anchor.jsonl")
        let started = directory.appendingPathComponent("native-refresh-started")
        let offsets = directory.appendingPathComponent("native-scroll-offsets")
        let passCompleted = directory.appendingPathComponent("native-index-pass-completed")
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_STARTED_PATH"] = started.path
        app.launchEnvironment["TRACE_TEST_NATIVE_SCROLL_OFFSET_PATH"] = offsets.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path
        var data = Data()
        for index in 0..<12 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "native-\(index)",
                "sessionId": "native-session-\(index)",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "NativeAnchorNeedle row \(index) "
                    + String(repeating: "long result content ", count: 12)],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["Search all sessions"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForFile(passCompleted, timeout: 15))
        query.click()
        query.typeText("NativeAnchorNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let scroller = app.scrollBars["searchResultsScroller"]
        XCTAssertTrue(scroller.waitForExistence(timeout: 5))
        scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).click()
        query.typeText("X")
        XCTAssertEqual(query.value as? String, "NativeAnchorNeedleX",
                       "using the scrollbar must leave keyboard focus in the search field")
        query.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(query.value as? String, "NativeAnchorNeedle")
        XCTAssertTrue(app.scrollBars["searchResultsScroller"].waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: started)
        try? FileManager.default.removeItem(at: passCompleted)
        let appended: [String: Any] = [
            "type": "assistant", "uuid": "native-new", "sessionId": "native-new-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_200_000,
            "message": ["content": "NativeAnchorNeedle newest row"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended) + Data([10]))
        try handle.close()
        XCTAssertTrue(waitForFile(passCompleted, timeout: 15))
        XCTAssertTrue(waitForFile(started, timeout: 15))
        try? FileManager.default.removeItem(at: offsets)
        let refreshedScroller = app.scrollBars["searchResultsScroller"]
        XCTAssertTrue(refreshedScroller.waitForExistence(timeout: 10))
        refreshedScroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).click()
        let manualOffset = try XCTUnwrap(waitForNumericLine(offsets, greaterThan: 20, timeout: 3),
                                         "the real scrollbar drag must move results")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "NativeAnchorNeedle newest row"
        )).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(try XCTUnwrap(numericLine(in: offsets)), manualOffset, accuracy: 35,
                       "refresh completion must not replay the pre-scroll anchor")
        let manuallyPositioned = try XCTUnwrap(firstHittable(
            in: app.buttons.containing(NSPredicate(
                format: "label CONTAINS %@", "NativeAnchorNeedle row"
            ))
        ))
        let manualY = manuallyPositioned.frame.minY
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(manuallyPositioned.isHittable)
        XCTAssertEqual(manuallyPositioned.frame.minY, manualY, accuracy: 35,
                       "anchor restoration must not undo scrollbar interaction")
        query.typeText("X")
        XCTAssertEqual(query.value as? String, "NativeAnchorNeedleX",
                       "using the scrollbar must leave keyboard focus in the search field")
    }

    func testSnippetHydrationSurvivesAutomaticRefreshForSameRow() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/hydration.jsonl")
        let hydrationStarted = directory.appendingPathComponent("hydration-started")
        app.launchEnvironment["TRACE_TEST_SNIPPET_HYDRATION_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_SNIPPET_HYDRATION_STARTED_PATH"] = hydrationStarted.path
        let oldText = "HydrationNeedle " + String(repeating: "long content ", count: 40)
            + "HydratedTailMarker"
        let original: [String: Any] = [
            "type": "assistant", "uuid": "hydration-old", "sessionId": "hydration-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000,
            "message": ["content": oldText],
        ]
        try (JSONSerialization.data(withJSONObject: original) + Data([10])).write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("HydrationNeedle")
        let oldRow = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "HydrationNeedle long content"
        )).firstMatch
        XCTAssertTrue(oldRow.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(hydrationStarted), "the old row must be hydrating before refresh")
        let newer: [String: Any] = [
            "type": "assistant", "uuid": "hydration-new", "sessionId": "hydration-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_200_000,
            "message": ["content": "HydrationNeedle new row"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: newer) + Data([10]))
        try handle.close()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "HydrationNeedle new row"
        )).firstMatch.waitForExistence(timeout: 15))
        let hydrated = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "HydratedTailMarker"
        )).firstMatch
        XCTAssertTrue(hydrated.waitForExistence(timeout: 10),
                      "the surviving row must display its hydrated snippet without reappearing")
    }

    func testSnippetHydrationRestartsAfterSourceRenameWithSameMessageID() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let original = directory.appendingPathComponent("Sources/Claude/snippet-old.jsonl")
        let renamed = directory.appendingPathComponent("Sources/Claude/snippet-new.jsonl")
        let audit = directory.appendingPathComponent("snippet-hydration-audit")
        app.launchEnvironment["TRACE_TEST_SNIPPET_HYDRATION_DELAY_MS"] = "250"
        app.launchEnvironment["TRACE_TEST_SNIPPET_HYDRATION_STARTED_PATH"] = audit.path
        let row: [String: Any] = [
            "type": "assistant", "uuid": "snippet-one", "sessionId": "snippet-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000,
            "message": ["content": "RenameHydrationNeedle " + String(repeating: "long content ", count: 40)
                        + "RenameHydratedTail"],
        ]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: original)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("RenameHydrationNeedle")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "RenameHydratedTail"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLineCount(audit, line: "started", count: 1))
        let before = ((try? String(contentsOf: audit, encoding: .utf8)) ?? "")
            .components(separatedBy: "started\n").count - 1
        try FileManager.default.moveItem(at: original, to: renamed)
        XCTAssertTrue(waitForLineCount(audit, line: "started", count: before + 1, timeout: 20),
                      "the same message ID must start hydration again after its source path changes")
    }

    func testLoadMoreQueuedDuringAutomaticRefreshUsesNewCursor() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/load-more.jsonl")
        let refreshStarted = directory.appendingPathComponent("automatic-search-started")
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_AUTOMATIC_SEARCH_STARTED_PATH"] = refreshStarted.path
        var data = Data()
        for index in 0..<220 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "load-more-\(index)", "sessionId": "load-more-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "QueuedPageNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("QueuedPageNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "QueuedPageNeedle row 219"
        )).firstMatch.waitForExistence(timeout: 10))
        let added: [String: Any] = [
            "type": "assistant", "uuid": "load-more-new", "sessionId": "load-more-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_400_000,
            "message": ["content": "An unrelated new message"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: added) + Data([10]))
        try handle.close()
        XCTAssertTrue(waitForFile(refreshStarted, timeout: 15),
                      "the automatic reset must be in flight before load-more")
        scroll.scroll(byDeltaX: 0, deltaY: -50_000)
        let oldest = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "QueuedPageNeedle row 0"
        )).firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 15),
                      "the queued request must load the next page with the refreshed cursor")
    }

    func testLauncherLoadMoreKeepsImmutableCriteriaWhenLiveControlsChange() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let audit = directory.appendingPathComponent("search-criteria-audit")
        let completed = directory.appendingPathComponent("pagination-completed")
        app.launchEnvironment["TRACE_TEST_SEARCH_CRITERIA_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_PAGINATION_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_QUERY"] = "OtherLiveNeedle"
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_SORT"] = "relevance"
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_AGENT"] = "codex"
        try writeImmutablePaginationFixture(in: directory)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
        popoverSearch.click()
        popoverSearch.typeText("StablePageNeedle")
        popoverSearch.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["searchProjectFilter"].firstMatch.click()
        app.menuItems["TraceUIExample"].click()
        app.buttons["Claude Code"].click()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StablePageNeedle row 219"
        )).firstMatch.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: audit)
        try? FileManager.default.removeItem(at: completed)
        let action = app.buttons["testPaginationCriteria"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        XCTAssertEqual(launcherSearch.value as? String, "OtherLiveNeedle")
        XCTAssertTrue(waitForFile(completed, timeout: 10),
                      "the immutable launcher page must finish loading")
        let scroll = app.scrollViews["searchResultsScroll"]
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StablePageNeedle row 0"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(
            fileLines(in: audit),
            [
                "more|StablePageNeedle|recency|/tmp/traceuiexample|"
                    + "agents:claude_code|cursor:present",
            ],
            "load-more must issue exactly one request with the original launcher criteria"
        )
    }

    func testMainLoadMoreKeepsImmutableCriteriaWhenLiveControlsChange() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let audit = directory.appendingPathComponent("main-search-criteria-audit")
        let completed = directory.appendingPathComponent("main-pagination-completed")
        app.launchEnvironment["TRACE_TEST_SEARCH_CRITERIA_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_PAGINATION_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_QUERY"] = "OtherLiveNeedle"
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_SORT"] = "relevance"
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_AGENT"] = "codex"
        try writeImmutablePaginationFixture(in: directory)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["TraceUIExample"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let mainSearch = app.textFields["mainSearch"]
        XCTAssertTrue(mainSearch.waitForExistence(timeout: 10))
        mainSearch.click()
        mainSearch.typeText("StablePageNeedle")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StablePageNeedle row 219"
        )).firstMatch.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: audit)
        try? FileManager.default.removeItem(at: completed)
        let action = app.buttons["testPaginationCriteria"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        XCTAssertEqual(mainSearch.value as? String, "OtherLiveNeedle")
        XCTAssertTrue(waitForFile(completed, timeout: 10),
                      "the immutable main-search page must finish loading")
        let scroll = app.scrollViews["searchResultsScroll"]
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StablePageNeedle row 0"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(
            fileLines(in: audit),
            [
                "more|StablePageNeedle|recency|/tmp/traceuiexample|"
                    + "agents:all|cursor:present",
            ],
            "load-more must issue exactly one request with the original main-search criteria"
        )
    }

    func testDuplicateOnlyAdditionalPageAutomaticallyAdvances() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/duplicate-page.jsonl")
        app.launchEnvironment["TRACE_TEST_DUPLICATE_FIRST_ADDITIONAL_SEARCH_PAGE"] = "1"
        var data = Data()
        for index in 0..<420 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "duplicate-page-\(index)",
                "sessionId": "duplicate-page-session", "cwd": "/tmp/TraceUIExample",
                "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "DuplicatePageNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("DuplicatePageNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "DuplicatePageNeedle row 419"
        )).firstMatch.waitForExistence(timeout: 10))

        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(app.staticTexts["Results may be out of date."].waitForExistence(timeout: 15))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "DuplicatePageNeedle row 20"
        )).firstMatch.waitForExistence(timeout: 15),
        "the buffered production page must be processed after the synthetic duplicate page")
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "DuplicatePageNeedle row 0"
        )).firstMatch.waitForExistence(timeout: 15),
        "a second load-more must continue from the buffered page's production cursor")
    }

    func testScrolledSearchQueryChangeStartsNewMainResultsAtTop() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/query-change.jsonl")
        var data = Data()
        for term in ["AlphaNeedle", "BetaNeedle"] {
            for index in 0..<90 {
                let row: [String: Any] = [
                    "type": "assistant", "uuid": "\(term)-\(index)", "sessionId": "query-session",
                    "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                    "message": ["content": "\(term) row \(index) "
                        + String(repeating: "Long result text. ", count: 9)],
                ]
                data.append(try JSONSerialization.data(withJSONObject: row))
                data.append(10)
            }
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("AlphaNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        scroll.scroll(byDeltaX: 0, deltaY: -950)
        query.click()
        query.typeKey("a", modifierFlags: .command)
        query.typeText("BetaNeedle")
        let first = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "BetaNeedle row 89"
        )).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "new SwiftUI results must start at the top")
    }

    func testScrolledSearchQueryChangeStartsNewPopoverResultsAtTop() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let file = directory.appendingPathComponent("Sources/Claude/query-change.jsonl")
        var data = Data()
        for term in ["AlphaNeedle", "BetaNeedle"] {
            for index in 0..<90 {
                let row: [String: Any] = [
                    "type": "assistant", "uuid": "\(term)-\(index)", "sessionId": "\(term)-\(index)",
                    "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                    "message": ["content": "\(term) row \(index) "
                        + String(repeating: "Long result text. ", count: 9)],
                ]
                data.append(try JSONSerialization.data(withJSONObject: row))
                data.append(10)
            }
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["Search all sessions"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("AlphaNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let alphaTop = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "AlphaNeedle row 89"
        )).firstMatch
        XCTAssertTrue(alphaTop.waitForExistence(timeout: 10))
        let before = alphaTop.frame.minY
        scroll.scroll(byDeltaX: 0, deltaY: -250)
        XCTAssertLessThan(alphaTop.frame.minY, before - 20)
        query.click()
        query.typeKey("a", modifierFlags: .command)
        query.typeText("BetaNeedle")
        let betaTop = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "BetaNeedle row 89"
        )).firstMatch
        XCTAssertTrue(betaTop.waitForExistence(timeout: 10))
        XCTAssertTrue(betaTop.isHittable, "the new native list must not replay the old scroll command")
    }

    func testIdenticalLayoutAutomaticRefreshDoesNotSnapAfterManualScroll() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/identical-layout.jsonl")
        let audit = directory.appendingPathComponent("search-requests")
        let completed = directory.appendingPathComponent("index-pass-completed")
        app.launchEnvironment["TRACE_TEST_SEARCH_REQUEST_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        var data = Data()
        for index in 0..<90 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "identical-\(index)", "sessionId": "identical-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "IdenticalNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        query.click()
        query.typeText("IdenticalNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        scroll.scroll(byDeltaX: 0, deltaY: -850)
        let baseline = ((try? String(contentsOf: audit, encoding: .utf8)) ?? "")
            .components(separatedBy: "automatic\n").count - 1
        try? FileManager.default.removeItem(at: completed)
        let unrelated: [String: Any] = [
            "type": "assistant", "uuid": "identical-unrelated", "sessionId": "identical-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_200_000,
            "message": ["content": "Unrelated message"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: unrelated) + Data([10]))
        try handle.close()
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        let automaticRefreshCount = poll(timeout: 10) {
            let content = (try? String(contentsOf: audit, encoding: .utf8)) ?? ""
            let count = content.components(separatedBy: "automatic\n").count - 1
            return count > baseline ? count : nil
        }
        XCTAssertNotNil(automaticRefreshCount)
        Thread.sleep(forTimeInterval: 0.5)
        scroll.scroll(byDeltaX: 0, deltaY: -250)
        let anchor = try XCTUnwrap(firstHittable(
            in: app.buttons.containing(NSPredicate(
                format: "label CONTAINS %@", "IdenticalNeedle row"
            ))
        ))
        let y = anchor.frame.minY
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(anchor.isHittable)
        XCTAssertLessThanOrEqual(abs(anchor.frame.minY - y), 35,
                                 "a completed identical-layout refresh must not restore later")
    }

    private func poll<Value>(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        _ value: () -> Value?
    ) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = value() { return value }
            Thread.sleep(forTimeInterval: interval)
        }
        return value()
    }

    private func pollSQLiteInteger(
        _ database: URL, sql: String, timeout: TimeInterval,
        until predicate: (Int64) -> Bool
    ) -> (value: Int64?, error: Error?) {
        var latestError: Error?
        let value: Int64? = poll(timeout: timeout) {
            do {
                let value = try sqliteInteger(database, sql: sql)
                latestError = nil
                return predicate(value) ? value : nil
            } catch {
                latestError = error
                return nil
            }
        }
        return (value, latestError)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        poll(timeout: timeout) {
            FileManager.default.fileExists(atPath: url.path) ? true : nil
        } ?? false
    }

    private func fileLines(in url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func writeImmutablePaginationFixture(in directory: URL) throws {
        let file = directory.appendingPathComponent("Sources/Claude/immutable-page.jsonl")
        var data = Data()
        for index in 0..<220 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "immutable-page-\(index)",
                "sessionId": "immutable-page-session", "cwd": "/tmp/TraceUIExample",
                "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "StablePageNeedle row \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
    }

    private func waitForLineCount(_ url: URL, line: String, count: Int,
                                  timeout: TimeInterval = 10) -> Bool {
        poll(timeout: timeout) {
            let lines = fileLines(in: url)
            if line == "finished" {
                let completions = completedInputCycles(in: lines)
                guard let latestStart = lines.last(where: { $0.hasPrefix("started,") }).map({ String($0.dropFirst(8)) }),
                      completions.contains(latestStart) else { return nil }
                return completions.count >= count ? true : nil
            }
            if line == "started" {
                let cycles = Set(lines.compactMap { entry -> String? in
                    guard entry.hasPrefix("started,") else { return nil }
                    let cycle = String(entry.dropFirst(8))
                    return UUID(uuidString: cycle) == nil ? nil : cycle
                })
                if !cycles.isEmpty { return cycles.count >= count ? true : nil }
            }
            return lines.filter { $0 == line }.count >= count ? true : nil
        } ?? false
    }

    private func completedInputCycles(in lines: [String]) -> Set<String> {
        let starts = Set(lines.filter { $0.hasPrefix("started,") }.map { String($0.dropFirst(8)) })
        let completions = Set(lines.filter { $0.hasPrefix("finished,") }.map { String($0.dropFirst(9)) })
        return completions.intersection(starts)
    }

    private func completedInputCycleCount(in url: URL) -> Int {
        completedInputCycles(in: fileLines(in: url)).count
    }

    private func numericLine(in url: URL) -> Double? {
        let content = try? String(contentsOf: url, encoding: .utf8)
        return content?.split(whereSeparator: \.isNewline).last.flatMap { Double($0) }
    }

    private func bookmarkIndex(in url: URL) -> Int? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForNumericLine(
        _ url: URL, greaterThan minimum: Double, timeout: TimeInterval = 10
    ) -> Double? {
        poll(timeout: timeout) {
            guard let value = numericLine(in: url), value > minimum else { return nil }
            return value
        }
    }

    private func waitForBookmarkIndex(
        _ url: URL, greaterThan minimum: Int, timeout: TimeInterval = 10
    ) -> Int? {
        poll(timeout: timeout) {
            guard let index = bookmarkIndex(in: url), index > minimum else { return nil }
            return index
        }
    }

    private func waitForStableBookmarkIndex(
        _ url: URL, timeout: TimeInterval = 10, stableFor: TimeInterval = 0.5
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?
        var stableSince = Date()
        while Date() < deadline {
            let value = bookmarkIndex(in: url)
            if value != lastValue {
                lastValue = value
                stableSince = Date()
            } else if value != nil, Date().timeIntervalSince(stableSince) >= stableFor {
                return value
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return lastValue
    }

    private func firstHittable(
        in query: XCUIElementQuery, timeout: TimeInterval = 10
    ) -> XCUIElement? {
        poll(timeout: timeout) {
            query.allElementsBoundByIndex.first(where: \.isHittable)
        }
    }

    private func transcriptMessage(
        _ session: String, index: Int, in scroll: XCUIElement
    ) -> XCUIElement {
        transcriptMessageQuery(session, index: index, in: scroll).firstMatch
    }

    private func transcriptMessageQuery(
        _ session: String, index: Int, in scroll: XCUIElement
    ) -> XCUIElementQuery {
        scroll.staticTexts.matching(NSPredicate(
            format: "value MATCHES %@",
            "(?s)^\(NSRegularExpression.escapedPattern(for: "\(session) message \(index)"))(?:[^0-9].*)?$"
        ))
    }

    private func hittableTranscriptAnchor(
        _ session: String, index: Int, in root: XCUIElement
    ) -> XCUIElement? {
        let rows = root.descendants(matching: .any).matching(
            identifier: "transcriptMessage-\(index)"
        )
        if let row = rows.allElementsBoundByIndex.first(where: \.isHittable) { return row }
        return transcriptMessageQuery(session, index: index, in: root)
            .allElementsBoundByIndex.first(where: \.isHittable)
    }

    private func waitForTranscriptAnchor(
        _ session: String, index: Int, in root: XCUIElement,
        timeout: TimeInterval = 5
    ) -> XCUIElement? {
        poll(timeout: timeout) {
            hittableTranscriptAnchor(session, index: index, in: root)
        }
    }

    private func savedAnchorY(
        index: Int, in scroll: XCUIElement, timeout: TimeInterval = 5
    ) -> CGFloat? {
        if let probe = nativeAnchorProbe {
            return poll(timeout: timeout) {
                try? String(index).write(to: probe.input, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: probe.output)
                probe.app.buttons["testProbeTranscriptPosition"].click()
                guard waitForFile(probe.output, timeout: 2),
                      let fields = fileLines(in: probe.output).last?.split(separator: ","),
                      fields.count == 5, fields[0] == String(index), fields[3] == "true",
                      let offset = Double(fields[1]) else { return nil }
                nativeAnchorSessionID = String(fields[4])
                return CGFloat(offset)
            }
        }
        return poll(timeout: timeout) { () -> CGFloat? in
            guard scroll.exists else { return nil }
            let viewport = scroll.frame
            let rows = scroll.descendants(matching: .any)
                .matching(identifier: "transcriptMessage-\(index)").allElementsBoundByIndex
            guard let row = rows.first(where: { $0.frame.intersects(viewport) }) else {
                return nil
            }
            return row.frame.minY - viewport.minY
        }
    }

    private func assertSavedAnchorOnScreen(
        index: Int, in scroll: XCUIElement, expectedY: CGFloat, stage: String
    ) {
        guard let actualY = savedAnchorY(index: index, in: scroll, timeout: 10) else {
            return XCTFail("\(stage): restoration did not report completion for row \(index); probe=\(nativeAnchorProbe.map { fileLines(in: $0.output) } ?? [])")
        }
        XCTAssertEqual(actualY, expectedY, accuracy: 8,
                       "\(stage): the first completed native offset must match the bookmark")
        if let probe = nativeAnchorProbe, let session = nativeAnchorSessionID {
            let samples = probe.input.deletingLastPathComponent().appendingPathComponent("native-anchor-samples")
            let observed = fileLines(in: samples).filter {
                let fields = $0.split(separator: ",")
                return fields.count >= 4 && fields[0] == String(index) && fields[3] == session
            }
            XCTAssertFalse(observed.isEmpty, "\(stage): native anchor sampling must observe main-loop frames")
            for sample in observed {
                let fields = sample.split(separator: ",")
                guard let offset = Double(fields[1]) else { XCTFail("invalid offset sample"); continue }
                var expected = Double(expectedY)
                if fields.count == 9, fields[4] != "established",
                   let height = Double(fields[5]), let rowY = Double(fields[6]),
                   let documentHeight = Double(fields[7]), let viewportHeight = Double(fields[8]) {
                    let visibleFooter = fields[4] == "waiting" ? 64.0 : 1.0
                    let clipped = max(expected, -max(0, height - visibleFooter))
                    let origin = min(max(0, rowY - clipped), max(0, documentHeight - viewportHeight))
                    expected = rowY - origin
                }
                XCTAssertEqual(offset, expected, accuracy: 8,
                    "\(stage): anchor displaced across a main-loop turn (\(sample))")
            }
            try? FileManager.default.removeItem(at: samples)
        }
    }

    private func focusTranscript(_ session: String, in scroll: XCUIElement) {
        let first = transcriptMessage(session, index: 0, in: scroll)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10))
        first.click()
    }

    private func openSidebarSession(_ title: String, in app: XCUIApplication) {
        let viewport = app.scrollViews.containing(.outline, identifier: "sessionSidebarList").firstMatch
        let label = viewport.staticTexts[title].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        for _ in 0..<10 {
            let frame = label.frame
            let visible = viewport.frame
            if visible.contains(frame) && label.isHittable {
                label.click()
                return
            }
            viewport.scroll(byDeltaX: 0, deltaY: frame.minY < visible.minY ? 100 : -100)
        }
        XCTFail("Session \(title) must be visible inside the sidebar before clicking")
    }

    func testGlobalSearchClearsAfterLauncherCloseButSurvivesHandoff() throws {
        let (app, _) = try makeApp(extra: ["--ui-show-popover"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
        popoverSearch.click()
        popoverSearch.typeText("Find")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find the sample answer"
        )).firstMatch.waitForExistence(timeout: 10))
        popoverSearch.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        XCTAssertEqual(launcherSearch.value as? String, "Find",
                       "handoff must retain the shared query while launcher is visible")
        launcherSearch.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(launcherSearch.exists)
        ensurePopoverOpen(app)
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 10))
        XCTAssertEqual(popoverSearch.value as? String, "",
                       "default clear-on-close must clear the shared global query")
    }

    func testQueryAndFilterCloseSettingsAreIndependent() throws {
        for (clearQuery, clearFilters) in [(true, true), (true, false),
                                           (false, true), (false, false)] {
            let (app, _) = try makeApp(extra: ["--ui-show-popover"])
            app.launch()
            XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
            app.buttons["Build Index"].click()
            configureGlobalCloseSettings(
                app, clearQuery: clearQuery, clearFilters: clearFilters
            )
            ensurePopoverOpen(app)
            let popoverSearch = app.textFields["Search all sessions"]
            XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
            popoverSearch.click()
            popoverSearch.typeText("Find")
            popoverSearch.typeKey(.return, modifierFlags: [])
            let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
            XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
            let errorsChip = app.buttons["Errors"].firstMatch
            XCTAssertTrue(errorsChip.exists)
            errorsChip.click()
            launcherSearch.typeKey(.escape, modifierFlags: [])
            ensurePopoverOpen(app)
            XCTAssertTrue(popoverSearch.waitForExistence(timeout: 10))
            XCTAssertEqual(popoverSearch.value as? String, clearQuery ? "" : "Find")
            let filterIndicator = app.staticTexts["Search filters active"]
            XCTAssertEqual(filterIndicator.exists, !clearFilters)
            if !clearFilters {
                app.buttons["Clear filters"].click()
                XCTAssertFalse(filterIndicator.exists)
            }
            app.terminate()
        }
    }

    func testDateFiltersSurviveRebuildAndAnyTimeIsUnbounded() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let completed = directory.appendingPathComponent("index-pass-completed")
        let reconciliationStarted = directory.appendingPathComponent(
            "project-reconciliation-started"
        )
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_PROJECT_RECONCILIATION_DELAY_MS"] = "2000"
        app.launchEnvironment["TRACE_TEST_PROJECT_RECONCILIATION_STARTED_PATH"] =
            reconciliationStarted.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        configureGlobalCloseSettings(app, clearQuery: false, clearFilters: false)
        ensurePopoverOpen(app)
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
        popoverSearch.click()
        popoverSearch.typeText("Find")
        popoverSearch.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        let projectMenu = app.descendants(matching: .any)["searchProjectFilter"].firstMatch
        XCTAssertTrue(projectMenu.waitForExistence(timeout: 10))
        projectMenu.click()
        app.menuItems["TraceUIExample"].click()
        let dateMenu = app.descendants(matching: .any)["searchDateFilter"].firstMatch
        XCTAssertTrue(dateMenu.waitForExistence(timeout: 10))
        dateMenu.click()
        app.menuItems["7 days"].click()
        app.buttons["Claude Code"].click()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find the sample answer"
        )).firstMatch.waitForExistence(timeout: 10))

        let futureTimestamp = Int64(Date().timeIntervalSince1970 * 1_000) + 2_000
        let dynamic: [String: Any] = [
            "type": "assistant", "uuid": "dynamic-date-boundary", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": futureTimestamp,
            "message": ["content": "Find dynamic date boundary"],
        ]
        let source = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: dynamic) + Data([10]))
        let ancient: [String: Any] = [
            "type": "assistant", "uuid": "ancient-date-boundary", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_500_000_000_000,
            "message": ["content": "Find ancient date boundary"],
        ]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: ancient) + Data([10]))
        try handle.close()

        let decoy: [String: Any] = [
            "type": "assistant", "uuid": "rebuild-project-decoy", "sessionId": "decoy-session",
            "cwd": "/tmp/OtherProject", "timestamp": futureTimestamp,
            "message": ["content": "Find other project decoy"],
        ]
        let decoySource = directory.appendingPathComponent("Sources/Claude/000-decoy.jsonl")
        try (JSONSerialization.data(withJSONObject: decoy) + Data([10])).write(to: decoySource)
        Thread.sleep(forTimeInterval: 2.2)

        try? FileManager.default.removeItem(at: completed)
        try? FileManager.default.removeItem(at: reconciliationStarted)
        let rebuild = app.buttons["testRebuildIndex"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 5))
        rebuild.click()
        rebuild.click()
        let resolving = app.descendants(matching: .any)["projectFilterResolving"].firstMatch
        XCTAssertTrue(resolving.waitForExistence(timeout: 5),
                      "a retained launcher filter must show reconciliation progress")
        XCTAssertTrue(waitForFile(reconciliationStarted, timeout: 20))
        XCTAssertTrue(waitForFile(completed, timeout: 20))

        XCTAssertTrue(dateMenu.waitForExistence(timeout: 10))
        XCTAssertTrue(app.menuButtons["7 days"].exists || app.popUpButtons["7 days"].exists)
        XCTAssertTrue(app.menuButtons["TraceUIExample"].exists || nativeMenu(titled: "TraceUIExample", in: app).exists,
                      "the project filter must retain its canonical identity through rebuild")
        XCTAssertEqual(launcherSearch.value as? String, "Find")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find the sample answer"
        )).firstMatch.waitForExistence(timeout: 10),
        "the query and non-default filters must remain effective after rebuild")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find dynamic date boundary"
        )).firstMatch.waitForExistence(timeout: 10),
        "relative date bounds must be recomputed when the rebuilt search starts")
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find other project decoy"
        )).firstMatch.exists, "the reused numeric ID must not select a different project")
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find ancient date boundary"
        )).firstMatch.exists, "7 days must exclude the old result")

        app.buttons["Claude Code"].click()
        dateMenu.click()
        app.menuItems["Any time"].click()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find ancient date boundary"
        )).firstMatch.waitForExistence(timeout: 10),
        "Any time must remove both date bounds before the launcher closes")
        projectMenu.click()
        app.menuItems["All projects"].click()
        XCTAssertFalse(app.staticTexts["Search filters active"].exists)
        launcherSearch.typeKey(.escape, modifierFlags: [])
        ensurePopoverOpen(app)
        XCTAssertFalse(app.staticTexts["Search filters active"].exists,
                       "Any time must clear both date bounds")
    }

    func testFailedRebuildRetainsAndUnblocksGlobalProjectFilter() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        app.launchEnvironment["TRACE_TEST_PROJECT_RECONCILIATION_DELAY_MS"] = "1000"
        let otherSource = directory.appendingPathComponent(
            "Sources/Claude/failed-rebuild-other.jsonl"
        )
        let other: [String: Any] = [
            "type": "assistant", "uuid": "failed-rebuild-other",
            "sessionId": "failed-rebuild-other", "cwd": "/tmp/OtherProject",
            "timestamp": "2026-09-14T10:01:00Z",
            "message": ["content": "FailedRebuildNeedle from other project"],
        ]
        try (JSONSerialization.data(withJSONObject: other) + Data([10]))
            .write(to: otherSource)

        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.click()
        search.typeText("FailedRebuildNeedle")
        search.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["searchProjectFilter"].firstMatch.click()
        app.menuItems["TraceUIExample"].click()
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10))

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "CREATE TRIGGER fail_rebuild_root BEFORE UPDATE OF is_default ON source_root "
                + "BEGIN SELECT RAISE(ABORT, 'forced rebuild failure'); END;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        app.buttons["testRebuildIndex"].click()
        let resolving = app.descendants(matching: .any)["projectFilterResolving"].firstMatch
        XCTAssertTrue(resolving.waitForExistence(timeout: 5))
        let indexProgress = app.descendants(matching: .any)["indexProgress"].firstMatch
        let failureLabel = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "forced rebuild failure"),
            object: indexProgress
        )
        XCTAssertEqual(XCTWaiter.wait(for: [failureLabel], timeout: 15), .completed)
        XCTAssertTrue(resolving.waitForNonExistence(timeout: 10),
                      "a failed rebuild must finish project-filter resolution")
        XCTAssertTrue(nativeMenu(titled: "TraceUIExample", in: app).exists,
                      "the failed rebuild must retain the canonical project filter")
        XCTAssertEqual(launcherSearch.value as? String, "FailedRebuildNeedle")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from other project"
        )).firstMatch.exists, "failure recovery must not broaden to every project")
    }

    func testMissingSelectedMainProjectNeverSearchesEveryProject() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let completed = directory.appendingPathComponent("main-project-pass-completed")
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        let otherSource = directory.appendingPathComponent("Sources/Claude/other-project.jsonl")
        let other: [String: Any] = [
            "type": "assistant", "uuid": "other-project-match", "sessionId": "other-project",
            "cwd": "/tmp/OtherProject", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["content": "RestrictedProjectNeedle from other project"],
        ]
        try (JSONSerialization.data(withJSONObject: other) + Data([10])).write(to: otherSource)
        let selectedSource = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let selected: [String: Any] = [
            "type": "assistant", "uuid": "selected-project-match", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:01:00Z",
            "message": ["content": "RestrictedProjectNeedle from selected project"],
        ]
        let handle = try FileHandle(forWritingTo: selectedSource)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: selected) + Data([10]))
        try handle.close()

        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["TraceUIExample"].waitForExistence(timeout: 15))
        app.staticTexts["TraceUIExample"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.click()
        query.typeText("RestrictedProjectNeedle")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from selected project"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from other project"
        )).firstMatch.exists)
        let databaseURL = directory.appendingPathComponent("index.sqlite")
        let selectedProjectID = try sqliteInteger(
            databaseURL,
            sql: "SELECT id FROM project WHERE canonical_key='/tmp/traceuiexample';"
        )

        try? FileManager.default.removeItem(at: completed)
        try FileManager.default.removeItem(at: selectedSource)
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from other project"
        )).firstMatch.exists,
        "a stale selected project ID must remain restrictive instead of becoming all projects")

        try? FileManager.default.removeItem(at: completed)
        let replacement: [String: Any] = [
            "type": "assistant", "uuid": "replacement-project-match",
            "sessionId": "replacement-project", "cwd": "/tmp/ReplacementProject",
            "timestamp": "2026-09-14T10:02:00Z",
            "message": ["content": "RestrictedProjectNeedle from replacement project"],
        ]
        let replacementSource = directory.appendingPathComponent(
            "Sources/Claude/zzz-replacement-project.jsonl"
        )
        try (JSONSerialization.data(withJSONObject: replacement) + Data([10]))
            .write(to: replacementSource)
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        let replacementProjectID = try sqliteInteger(
            databaseURL,
            sql: "SELECT id FROM project WHERE canonical_key='/tmp/replacementproject';"
        )
        XCTAssertEqual(replacementProjectID, selectedProjectID,
                       "the fixture must reproduce numeric project-ID reuse")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from replacement project"
        )).firstMatch.exists,
        "a replacement project reusing the deleted numeric ID must remain excluded")
        XCTAssertEqual(query.placeholderValue, "Search this project")
    }

    func testLauncherProjectFilterRenamesThenClearsWhenProjectDisappears() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let completed = directory.appendingPathComponent("launcher-project-pass-completed")
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        let otherSource = directory.appendingPathComponent("Sources/Claude/other-filter-project.jsonl")
        let other: [String: Any] = [
            "type": "assistant", "uuid": "other-filter-match", "sessionId": "other-filter",
            "cwd": "/tmp/OtherProject", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["content": "LauncherProjectNeedle from other project"],
        ]
        try (JSONSerialization.data(withJSONObject: other) + Data([10])).write(to: otherSource)
        let selectedSource = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let selected: [String: Any] = [
            "type": "assistant", "uuid": "selected-filter-match", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:01:00Z",
            "message": ["content": "LauncherProjectNeedle from selected project"],
        ]
        let selectedHandle = try FileHandle(forWritingTo: selectedSource)
        try selectedHandle.seekToEnd()
        try selectedHandle.write(
            contentsOf: JSONSerialization.data(withJSONObject: selected) + Data([10])
        )
        try selectedHandle.close()

        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
        popoverSearch.click()
        popoverSearch.typeText("LauncherProjectNeedle")
        popoverSearch.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["searchProjectFilter"].firstMatch.click()
        app.menuItems["TraceUIExample"].click()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from selected project"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from other project"
        )).firstMatch.exists)

        let rename = Process()
        rename.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        rename.arguments = [directory.appendingPathComponent("index.sqlite").path,
                            "UPDATE project SET display_name='Renamed Trace Project' WHERE display_name='TraceUIExample';"]
        try rename.run()
        rename.waitUntilExit()
        XCTAssertEqual(rename.terminationStatus, 0)
        try? FileManager.default.removeItem(at: completed)
        let unrelated: [String: Any] = [
            "type": "user", "uuid": "unrelated-refresh", "sessionId": "other-filter",
            "cwd": "/tmp/OtherProject", "timestamp": "2026-09-14T10:02:00Z",
            "message": ["content": "Unrelated project refresh"],
        ]
        let otherHandle = try FileHandle(forWritingTo: otherSource)
        try otherHandle.seekToEnd()
        try otherHandle.write(
            contentsOf: JSONSerialization.data(withJSONObject: unrelated) + Data([10])
        )
        try otherHandle.close()
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        XCTAssertTrue(nativeMenu(titled: "Renamed Trace Project", in: app).waitForExistence(timeout: 10),
                      "final reconciliation must refresh the filter's displayed project name")

        try? FileManager.default.removeItem(at: completed)
        try FileManager.default.removeItem(at: selectedSource)
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        XCTAssertTrue(nativeMenu(titled: "All projects", in: app).waitForExistence(timeout: 15),
                      "a vanished launcher project filter must clear to All projects")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from other project"
        )).firstMatch.waitForExistence(timeout: 15))
    }

    func testRetainedHiddenGlobalSearchRefreshesOnlyOnReopening() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let requests = directory.appendingPathComponent("search-requests")
        let completed = directory.appendingPathComponent("index-pass-completed")
        app.launchEnvironment["TRACE_TEST_SEARCH_REQUEST_AUDIT_PATH"] = requests.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        configureGlobalCloseSettings(app, clearQuery: false, clearFilters: true)
        ensurePopoverOpen(app)
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 15))
        popoverSearch.click()
        popoverSearch.typeText("Find")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find the sample answer"
        )).firstMatch.waitForExistence(timeout: 10))
        popoverSearch.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        launcherSearch.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(launcherSearch.exists)
        let before = try String(contentsOf: requests, encoding: .utf8)
            .components(separatedBy: "automatic\n").count - 1
        try? FileManager.default.removeItem(at: completed)
        let file = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let added: [String: Any] = [
            "type": "user", "uuid": "hidden-new", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:10Z",
            "message": ["content": "Find HiddenRefreshNeedle"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: added) + Data([10]))
        try handle.close()
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        let whileHidden = try String(contentsOf: requests, encoding: .utf8)
            .components(separatedBy: "automatic\n").count - 1
        XCTAssertEqual(whileHidden, before, "hidden retained searches must make no automatic requests")
        ensurePopoverOpen(app)
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 10))
        XCTAssertEqual(popoverSearch.value as? String, "Find")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "HiddenRefreshNeedle"
        )).firstMatch.waitForExistence(timeout: 10))
        let after = try String(contentsOf: requests, encoding: .utf8)
            .components(separatedBy: "automatic\n").count - 1
        XCTAssertEqual(after, before + 1, "reopening must refresh missed mutations once")
    }

    func testCostsControlsUseCompletedSnapshotUntilAggregation() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/costs.jsonl")
        let audit = directory.appendingPathComponent("rollup-rebuilds")
        let completed = directory.appendingPathComponent("index-pass-completed")
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_INDEX_BATCH_DELAY_MS"] = "5000"
        let initial: [String: Any] = [
            "type": "assistant", "uuid": "cost-original", "sessionId": "cost-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["id": "cost-original-response", "model": "claude-sonnet-5",
                        "content": "Cost fixture", "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        try (JSONSerialization.data(withJSONObject: initial) + Data([10])).write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        app.radioButtons["Costs"].click()
        XCTAssertTrue(app.staticTexts["10"].waitForExistence(timeout: 15))
        try? FileManager.default.removeItem(at: audit)
        try? FileManager.default.removeItem(at: completed)

        var added = Data()
        for index in 0..<300 {
            let message: [String: Any] = index == 299
                ? ["id": "cost-added-response", "model": "claude-sonnet-5",
                   "content": "New cost fixture", "usage": ["input_tokens": 4, "output_tokens": 1]]
                : ["content": "Additional row \(index)"]
            let row: [String: Any] = [
                "type": "assistant", "uuid": "cost-added-\(index)", "sessionId": "cost-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:10:00Z",
                "message": message,
            ]
            added.append(try JSONSerialization.data(withJSONObject: row))
            added.append(10)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: added)
        try handle.close()
        XCTAssertTrue(app.staticTexts["Updating token totals…"].waitForExistence(timeout: 15))
        let range = app.windows["Trace"].popUpButtons.matching(NSPredicate(
            format: "value == %@", "30 days"
        )).firstMatch
        XCTAssertTrue(range.exists)
        range.click()
        app.menuItems["All time"].click()
        app.checkBoxes["Include sidechains"].click()
        XCTAssertTrue(app.staticTexts["10"].exists,
                      "active indexing must leave the prior completed totals visible")
        let during = (try? String(contentsOf: audit, encoding: .utf8)) ?? ""
        XCTAssertEqual(during.components(separatedBy: "rebuilt\n").count - 1, 0,
                       "Costs controls must not rebuild rollups during indexing")
        XCTAssertTrue(waitForFile(completed, timeout: 20))
        XCTAssertTrue(app.staticTexts["14"].waitForExistence(timeout: 15))
        let after = try String(contentsOf: audit, encoding: .utf8)
        XCTAssertEqual(after.components(separatedBy: "rebuilt\n").count - 1, 1,
                       "aggregation must rebuild the dirty rollups once")

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "CREATE TRIGGER fail_next_rollup BEFORE DELETE ON usage_daily BEGIN SELECT RAISE(ABORT, 'rollup unavailable'); END;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        try? FileManager.default.removeItem(at: completed)
        let failedUsage: [String: Any] = [
            "type": "assistant", "uuid": "cost-failed", "sessionId": "cost-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:20:00Z",
            "message": ["id": "cost-failed-response", "model": "claude-sonnet-5",
                        "content": "Failed rollup fixture", "usage": ["input_tokens": 6, "output_tokens": 1]],
        ]
        let failedHandle = try FileHandle(forWritingTo: file)
        try failedHandle.seekToEnd()
        try failedHandle.write(contentsOf: JSONSerialization.data(withJSONObject: failedUsage) + Data([10]))
        try failedHandle.close()
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "rollup unavailable"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["14"].exists,
                      "a rollup failure must retain the last completed Costs snapshot")
        let failedRepairBanner = app.staticTexts["Updating token totals…"]
        expectation(for: NSPredicate { _, _ in !failedRepairBanner.exists }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

    func testFailedPassDefersDirtyUsageRepairAndKeepsCompletedSnapshot() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/failed-pass-costs.jsonl")
        let repairStarted = directory.appendingPathComponent("deferred-rollup-started")
        let initialCompleted = directory.appendingPathComponent("initial-pass-completed")
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = initialCompleted.path
        let initial: [String: Any] = [
            "type": "assistant", "uuid": "failed-pass-initial", "sessionId": "failed-pass",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["id": "failed-pass-initial-response", "model": "claude-sonnet-5",
                        "content": "Failed pass baseline",
                        "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        try (JSONSerialization.data(withJSONObject: initial) + Data([10])).write(to: file)
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(waitForFile(initialCompleted, timeout: 15))
        app.radioButtons["Costs"].click()
        XCTAssertEqual(app.radioButtons["Costs"].value as? Int, 1,
                       "the baseline snapshot must be observed in the Costs section")
        XCTAssertTrue(app.staticTexts["10"].waitForExistence(timeout: 15))
        app.terminate()

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "CREATE TRIGGER fail_root_scan BEFORE UPDATE OF last_scan_ms ON source_root BEGIN SELECT RAISE(ABORT, 'full scan failed'); END;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        let added: [String: Any] = [
            "type": "assistant", "uuid": "failed-pass-added", "sessionId": "failed-pass",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:01:00Z",
            "message": ["id": "failed-pass-added-response", "model": "claude-sonnet-5",
                        "content": "Failed pass committed mutation",
                        "usage": ["input_tokens": 6, "output_tokens": 1]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: added) + Data([10]))
        try handle.close()

        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_STARTED_PATH"] = repairStarted.path
        app.launch()
        app.activate()
        XCTAssertTrue(waitForFile(repairStarted, timeout: 15),
                      "a failed pass with committed mutations must schedule dirty-rollup repair")
        app.radioButtons["Costs"].click()
        XCTAssertTrue(app.staticTexts["10"].exists,
                      "the last completed snapshot must remain visible during repair")
        XCTAssertTrue(app.staticTexts["Updating token totals…"].exists)
        XCTAssertTrue(app.staticTexts["16"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Updating token totals…"].exists)
    }

    func testRollupErrorKeepsCompletedSnapshotUntilDeferredRepairSucceeds() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/repair-costs.jsonl")
        let repairStarted = directory.appendingPathComponent("rollup-repair-started")
        let repairAudit = directory.appendingPathComponent("rollup-repair-audit")
        let passCompleted = directory.appendingPathComponent("index-pass-completed")
        let quietPeriodStarted = directory.appendingPathComponent(
            "rollup-repair-quiet-period-started"
        )
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_STARTED_PATH"] = repairStarted.path
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_AUDIT_PATH"] = repairAudit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path
        app.launchEnvironment["TRACE_TEST_USAGE_REPAIR_QUIET_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_USAGE_REPAIR_QUIET_PERIOD_STARTED_PATH"] =
            quietPeriodStarted.path
        let initial: [String: Any] = [
            "type": "assistant", "uuid": "repair-initial", "sessionId": "repair",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["id": "repair-initial-response", "model": "claude-sonnet-5",
                        "content": "Repair snapshot baseline",
                        "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        try (JSONSerialization.data(withJSONObject: initial) + Data([10])).write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        app.radioButtons["Costs"].click()
        XCTAssertTrue(app.staticTexts["10"].waitForExistence(timeout: 15))
        try? FileManager.default.removeItem(at: repairStarted)
        try? FileManager.default.removeItem(at: repairAudit)
        try? FileManager.default.removeItem(at: passCompleted)
        try? FileManager.default.removeItem(at: quietPeriodStarted)

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "CREATE TRIGGER fail_next_rollup_refresh BEFORE DELETE ON usage_daily BEGIN SELECT RAISE(ABORT, 'rollup unavailable'); END;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        let added: [String: Any] = [
            "type": "assistant", "uuid": "repair-added", "sessionId": "repair",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:01:00Z",
            "message": ["id": "repair-added-response", "model": "claude-sonnet-5",
                        "content": "Repair snapshot added record",
                        "usage": ["input_tokens": 6, "output_tokens": 1]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: JSONSerialization.data(withJSONObject: added) + Data([10])
        )
        try handle.close()

        XCTAssertTrue(waitForFile(passCompleted, timeout: 15))
        XCTAssertTrue(waitForFile(quietPeriodStarted, timeout: 10))
        XCTAssertEqual(
            ((try? String(contentsOf: repairStarted, encoding: .utf8)) ?? "")
                .components(separatedBy: "started\n").count - 1,
            1,
            "the deferred repair must not immediately repeat the failed terminal rebuild"
        )
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "rollup unavailable"
        )).firstMatch.exists,
        "the original rollup error must remain visible during the quiet period")
        XCTAssertTrue(app.staticTexts["Updating token totals…"].exists)

        let replaceTrigger = Process()
        replaceTrigger.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        replaceTrigger.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "DROP TRIGGER fail_next_rollup_refresh; "
                + "CREATE TRIGGER fail_retry_rollup_refresh BEFORE DELETE ON usage_daily "
                + "BEGIN SELECT RAISE(ABORT, 'repair retry unavailable'); END;"]
        try replaceTrigger.run()
        replaceTrigger.waitUntilExit()
        XCTAssertEqual(replaceTrigger.terminationStatus, 0)

        XCTAssertTrue(waitForLineCount(repairStarted, line: "started", count: 2, timeout: 15),
                      "a terminal rollup error must schedule one deferred dirty-rollup repair")
        XCTAssertTrue(app.staticTexts["10"].exists,
                      "the last completed totals must remain visible during repair")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "repair retry unavailable"
        )).firstMatch.waitForExistence(timeout: 10),
        "a newer repair failure must replace the earlier terminal error")
        XCTAssertFalse(app.staticTexts["Updating token totals…"].exists,
                       "the updating banner must end after the deferred repair fails")

        let dropTrigger = Process()
        dropTrigger.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        dropTrigger.arguments = [directory.appendingPathComponent("index.sqlite").path,
                                 "DROP TRIGGER fail_retry_rollup_refresh;"]
        try dropTrigger.run()
        dropTrigger.waitUntilExit()
        XCTAssertEqual(dropTrigger.terminationStatus, 0)

        let retryKick: [String: Any] = [
            "type": "assistant", "uuid": "repair-retry-kick", "sessionId": "repair",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:02:00Z",
            "message": ["content": "Retry dirty token rollups"],
        ]
        let retryHandle = try FileHandle(forWritingTo: file)
        try retryHandle.seekToEnd()
        try retryHandle.write(
            contentsOf: JSONSerialization.data(withJSONObject: retryKick) + Data([10])
        )
        try retryHandle.close()

        XCTAssertTrue(waitForLineCount(repairAudit, line: "rebuilt", count: 1, timeout: 15))
        XCTAssertTrue(app.staticTexts["16"].waitForExistence(timeout: 15))
        let error = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "repair retry unavailable"
        )).firstMatch
        expectation(for: NSPredicate { _, _ in !error.exists }, evaluatedWith: nil)
        let banner = app.staticTexts["Updating token totals…"]
        expectation(for: NSPredicate { _, _ in !banner.exists }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

    private func ensurePopoverOpen(_ app: XCUIApplication) {
        let search = app.textFields["Search all sessions"]
        if search.exists { return }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground,
                       "popover observation requires the test app to own the foreground")
        if search.exists { return }
        let status = app.statusItems["Trace"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.isHittable, "the menu-bar item must be visible before opening the popover")
        status.click()
        XCTAssertTrue(search.waitForExistence(timeout: 10))
    }

    private func configureGlobalCloseSettings(
        _ app: XCUIApplication, clearQuery: Bool, clearFilters: Bool
    ) {
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows["Trace Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let queryToggle = app.descendants(matching: .any)["clearGlobalSearchOnClose"].firstMatch
        let filtersToggle = app.descendants(matching: .any)["clearGlobalFiltersOnClose"].firstMatch
        XCTAssertTrue(queryToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(filtersToggle.exists)
        if !clearQuery { queryToggle.click() }
        if !clearFilters { filtersToggle.click() }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
    }

    func testVersionOneIndexUpgradeKeepsMainWindowResponsive() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let current = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Index current"
        )).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        app.terminate()

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "UPDATE trace_meta SET value='1' WHERE key='index_format_version';"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        app.launchEnvironment["TRACE_TEST_INDEX_OPEN_DELAY_MS"] = "5000"
        app.launch()
        let status = app.buttons["indexProgress"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isHittable)
        status.click()
        XCTAssertTrue(app.staticTexts["Ready to build index"].exists,
                      "the main window should respond while the index opens")
        XCTAssertTrue(current.waitForExistence(timeout: 20))
    }

    func testStartupRollupRepairFailureKeepsSearchAvailable() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        let usage: [String: Any] = [
            "type": "assistant", "uuid": "cost-record", "sessionId": "test-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000,
            "message": ["id": "cost-response", "model": "claude-sonnet-5",
                        "content": "Searchable usage record",
                        "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: usage) + Data([10]))
        try handle.close()
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let current = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Index current")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        app.terminate()

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "CREATE TRIGGER fail_startup_rollup BEFORE DELETE ON usage_daily BEGIN SELECT RAISE(ABORT, 'rollup unavailable'); END; UPDATE trace_meta SET value='1' WHERE key='usage_rollups_dirty';"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        app.launch()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 15), "rollup repair must not abort startup")
        query.click()
        query.typeText("Searchable")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Searchable usage record"
        )).firstMatch.waitForExistence(timeout: 15), "indexed search must remain usable")
        app.radioButtons["Costs"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "rollup unavailable"
        )).firstMatch.waitForExistence(timeout: 10))
    }

    func testStartupShowsCachedCostsAndWatchesDuringRollupRepair() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/cached-costs.jsonl")
        let usage: [String: Any] = [
            "type": "assistant", "uuid": "cached-cost", "sessionId": "cached-cost-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["id": "cached-cost-response", "model": "claude-sonnet-5",
                        "content": "Cached Costs fixture",
                        "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        try (JSONSerialization.data(withJSONObject: usage) + Data([10])).write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        app.radioButtons["Costs"].click()
        XCTAssertTrue(app.staticTexts["10"].waitForExistence(timeout: 15))
        app.terminate()

        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [directory.appendingPathComponent("index.sqlite").path,
            "UPDATE trace_meta SET value='1' WHERE key='usage_rollups_dirty';"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        let rebuilding = directory.appendingPathComponent("startup-rollup-started")
        let rebuildRelease = directory.appendingPathComponent("startup-rollup-release")
        let sourceChanges = directory.appendingPathComponent("startup-watcher-changes")
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_DELAY_MS"] = "30000"
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_STARTED_PATH"] = rebuilding.path
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_RELEASE_PATH"] = rebuildRelease.path
        app.launchEnvironment["TRACE_TEST_SOURCE_CHANGES_AUDIT_PATH"] = sourceChanges.path
        app.launch()
        XCTAssertTrue(waitForFile(rebuilding, timeout: 15), "initial indexing must repair dirty rollups")
        app.radioButtons["Costs"].click()
        XCTAssertTrue(app.staticTexts["10"].waitForExistence(timeout: 2),
                      "cached Costs totals should remain visible while startup repair runs")
        XCTAssertTrue(app.staticTexts["Updating token totals…"].waitForExistence(timeout: 2))

        let watched = directory.appendingPathComponent("Sources/Claude/startup-watched.jsonl")
        let row: [String: Any] = [
            "type": "user", "uuid": "startup-watched", "sessionId": "startup-watched-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:01:00Z",
            "message": ["content": "StartupWatchNeedle arrived during repair"],
        ]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: watched)
        XCTAssertNotNil(poll(timeout: 10) {
            fileLines(in: sourceChanges).first { $0.hasSuffix("/startup-watched.jsonl") }
        }, "the watcher must queue this file while rollup repair is gated")
        try Data().write(to: rebuildRelease)
        app.radioButtons["Transcript"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.click()
        query.typeText("StartupWatchNeedle")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StartupWatchNeedle arrived during repair"
        )).firstMatch.waitForExistence(timeout: 25),
                      "watcher should queue the new file while the first repair is running")
    }

    func testSuccessfulIncrementalPassClearsEarlierFileFailure() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let current = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Index current"
        )).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 15))

        let file = directory.appendingPathComponent("Sources/Claude/retry.jsonl")
        let row: [String: Any] = [
            "type": "user", "uuid": "retry-one", "sessionId": "retry-session",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:01:00Z",
            "message": ["content": "Recovered index file"],
        ]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let failed = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "files still failing"
        )).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Recovered index file"].waitForExistence(timeout: 10))
    }

    func testPopoverKeepsSearchAndFooterVisibleWithTenSessions() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let source = directory.appendingPathComponent("Sources/Claude")
        let offsets = directory.appendingPathComponent("popover-scroll-offsets")
        app.launchEnvironment["TRACE_TEST_NATIVE_SCROLL_OFFSET_PATH"] = offsets.path
        for index in 0..<12 {
            let object: [String: Any] = ["type": "user", "uuid": "long-\(index)", "sessionId": "long-\(index)",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "Session \(index): " + String(repeating: "A lengthy session title ", count: 20)]]
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try data.write(to: source.appendingPathComponent("long-\(index).jsonl"))
        }
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["Open Trace"].isHittable)
        XCTAssertLessThanOrEqual(search.frame.width, 480)
        let list = app.scrollViews.firstMatch
        try? FileManager.default.removeItem(at: offsets)
        let recentPoint = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        recentPoint.hover()
        recentPoint.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertNotNil(waitForNumericLine(offsets, greaterThan: 20),
                        "the recent-session list must make a meaningful native scroll")
        let lowerRecentSession = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Session 4:"
        )).firstMatch
        XCTAssertTrue(lowerRecentSession.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["Open Trace"].isHittable)
        search.click()
        search.typeText("lengthy")
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Session 11:"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: offsets)
        let resultPoint = app.scrollViews.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        resultPoint.hover()
        resultPoint.scroll(byDeltaX: 0, deltaY: -250)
        XCTAssertNotNil(waitForNumericLine(offsets, greaterThan: 20),
                        "the filtered-result list must make a meaningful native scroll")
        let lowerResult = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Session 4:"
        )).firstMatch
        XCTAssertTrue(lowerResult.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["Open Trace"].isHittable)
        attach(app, name: "popover")
    }

    func testRecentSessionOpenClearsHidingFilterAndRevealsSidebarSelection() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addSession(
            id: "popup-target", title: "Popup selected session",
            project: "PopupTargetProject", timestamp: 1_800_000_000_000,
            content: "Popup selection transcript marker", directory: directory
        )
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let targetProject = app.staticTexts["PopupTargetProject"].firstMatch
        XCTAssertTrue(targetProject.waitForExistence(timeout: 20))

        let database = directory.appendingPathComponent("index.sqlite")
        let projectID = try sqliteInteger(
            database, sql: "SELECT id FROM project WHERE display_name='PopupTargetProject'"
        )
        let sessionID = try sqliteInteger(
            database, sql: "SELECT id FROM session WHERE external_id='popup-target'"
        )
        let filter = app.textFields["projectFilter"]
        filter.click()
        filter.typeText("TraceUIExample")
        XCTAssertTrue(targetProject.waitForNonExistence(timeout: 5))

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 5))
        ensurePopoverOpen(app)
        let recent = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Popup selected session"
        )).firstMatch
        XCTAssertTrue(recent.wait(for: \.isHittable, toEqual: true, timeout: 10))
        recent.click()

        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertEqual(filter.value as? String, "",
                       "opening a hidden recent session must clear only the hiding filter")
        assertSidebarSelection(
            app, projectID: projectID, sessionID: sessionID,
            projectName: "PopupTargetProject", sessionTitle: "Popup selected session"
        )
        let transcript = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "Popup selection transcript marker"
        )).firstMatch.waitForExistence(timeout: 10))
    }

    func testGlobalSearchOpenRevealsOffscreenProjectAndSessionSelections() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let revealAudit = directory.appendingPathComponent("native-project-reveal-audit")
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_AUDIT_PATH"] = revealAudit.path
        defer {
            let attachment = XCTAttachment(string: fileLines(in: revealAudit).joined(separator: "\n"))
            attachment.name = "native-project-reveal"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for index in 0..<30 {
            try addSession(
                id: "global-project-decoy-\(index)", title: "Global project decoy \(index)",
                project: "GlobalTargetProject",
                timestamp: 1_800_000_000_000 + Int64(index) * 1_000,
                content: "Ordinary project message \(index)", directory: directory
            )
        }
        try addSession(
            id: "global-sidebar-target", title: "Global sidebar target",
            project: "GlobalTargetProject", timestamp: 1_600_000_000_000,
            content: "UniqueSidebarRevealNeedle", directory: directory
        )
        for index in 0..<15 {
            try addSession(
                id: "project-list-decoy-\(index)", title: "Other project session \(index)",
                project: "NewerProject\(index)",
                timestamp: 1_900_000_000_000 + Int64(index) * 1_000,
                content: "Unrelated newer project \(index)", directory: directory
            )
        }

        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.click()
        search.typeText("UniqueSidebarRevealNeedle")
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "UniqueSidebarRevealNeedle"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let database = directory.appendingPathComponent("index.sqlite")
        let projectID = try sqliteInteger(
            database, sql: "SELECT id FROM project WHERE display_name='GlobalTargetProject'"
        )
        let sessionID = try sqliteInteger(
            database, sql: "SELECT id FROM session WHERE external_id='global-sidebar-target'"
        )
        result.click()

        assertSidebarSelection(
            app, projectID: projectID, sessionID: sessionID,
            projectName: "GlobalTargetProject", sessionTitle: "Global sidebar target"
        )
        let transcript = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "UniqueSidebarRevealNeedle"
        )).firstMatch.waitForExistence(timeout: 10))
    }

    func testSidebarMaterializesProjectWhenItAppearsAfterSearchNavigation() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let entered = directory.appendingPathComponent("project-unavailable")
        let release = directory.appendingPathComponent("project-available")
        let ack = directory.appendingPathComponent("project-ack")
        app.launchEnvironment["TRACE_TEST_PROJECT_AVAILABILITY_ENTERED_PATH"] = entered.path
        app.launchEnvironment["TRACE_TEST_PROJECT_AVAILABILITY_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_ACK_PATH"] = ack.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        if !search.waitForExistence(timeout: 3) { ensurePopoverOpen(app) }
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.click(); search.typeText("Find the sample answer")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Find the sample answer")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.click()
        XCTAssertTrue(waitForFile(entered, timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
        try Data().write(to: release)
        XCTAssertTrue(waitForFile(ack, timeout: 5), "the existing token must materialize its newly available project")
    }

    func testSessionsHeaderDoesNotCancelProjectsReveal() throws { try runUnrelatedSidebarInteraction(titleBar: false) }
    func testTitleBarDragDoesNotCancelProjectsReveal() throws { try runUnrelatedSidebarInteraction(titleBar: true) }

    private func runUnrelatedSidebarInteraction(titleBar: Bool) throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let release = directory.appendingPathComponent("reveal-release")
        let ack = directory.appendingPathComponent("reveal-ack")
        let cancel = directory.appendingPathComponent("reveal-cancel")
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_ACK_PATH"] = ack.path
        app.launchEnvironment["TRACE_TEST_SIDEBAR_REVEAL_CANCELLED_PATH"] = cancel.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.click(); search.typeText("Find the sample answer")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Find the sample answer")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.click()
        XCTAssertTrue(app.staticTexts["TraceUIExample"].firstMatch.waitForExistence(timeout: 5))
        if titleBar {
            let window = app.windows.containing(.scrollView, identifier: "transcriptScroll").firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            let point = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 200, dy: 12))
            point.click(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 30, dy: 20)))
        } else { app.staticTexts["Sessions"].firstMatch.click() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancel.path))
        try Data().write(to: release)
        XCTAssertTrue(waitForFile(ack, timeout: 5))
    }

    func testSidebarRevealUpdatesItsRowIndexDuringMaterialization() throws { try runSidebarRevealMutation(userInterrupt: false) }
    func testUserScrollCancelsOutstandingSidebarReveal() throws { try runSidebarRevealMutation(userInterrupt: true) }
    func testSidebarRowIndexChangeDoesNotExtendProductionDeadline() throws {
        try runSidebarRevealMutation(userInterrupt: false, expire: true)
    }

    private func runSidebarRevealMutation(userInterrupt: Bool, expire: Bool = false) throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let gate = directory.appendingPathComponent("sidebar-gate")
        let ack = directory.appendingPathComponent("sidebar-ack")
        let cancel = directory.appendingPathComponent("sidebar-cancel")
        let audit = directory.appendingPathComponent("sidebar-index-audit")
        let clock = directory.appendingPathComponent("sidebar-clock")
        let expired = directory.appendingPathComponent("sidebar-expired")
        if expire {
            try Data("0".utf8).write(to: clock)
            app.launchEnvironment["TRACE_TEST_SIDEBAR_REVEAL_CLOCK_PATH"] = clock.path
            app.launchEnvironment["TRACE_TEST_SIDEBAR_REVEAL_EXPIRED_PATH"] = expired.path
        }
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_RELEASE_PATH"] = gate.path
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_ACK_PATH"] = ack.path
        app.launchEnvironment["TRACE_TEST_SIDEBAR_REVEAL_CANCELLED_PATH"] = cancel.path
        app.launchEnvironment["TRACE_TEST_SIDEBAR_PROJECT_REVEAL_AUDIT_PATH"] = audit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.click()
        search.typeText("Find the sample answer")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Find the sample answer")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()
        let project = app.staticTexts["TraceUIExample"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
        if userInterrupt {
            let point = project.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            point.hover()
            point.scroll(byDeltaX: 0, deltaY: -100)
            XCTAssertTrue(waitForFile(cancel, timeout: 3), "wheel input must cancel even at a scroll boundary")
            try Data().write(to: gate)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
        } else {
            if expire {
                let initialCheck = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !self.fileLines(in: audit).isEmpty
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [initialCheck], timeout: 3), .completed)
                try Data("2.9".utf8).write(to: clock, options: .atomic)
            }
            try addSession(id: "newer-sidebar", title: "New sidebar session", project: "NewerSidebarProject",
                timestamp: 2_000_000_000_000, content: "A newly indexed sidebar row", directory: directory)
            XCTAssertTrue(app.staticTexts["NewerSidebarProject"].firstMatch.waitForExistence(timeout: 3))
            if expire {
                let changedRow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    Set(self.fileLines(in: audit).compactMap { line in
                        line.split(separator: ",").first { $0.hasPrefix("row=") }.map(String.init)
                    }).count > 1
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [changedRow], timeout: 3), .completed)
                try Data("3.01".utf8).write(to: clock, options: .atomic)
                XCTAssertTrue(waitForFile(expired, timeout: 3))
                XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
                return
            }
            try Data().write(to: gate)
            XCTAssertTrue(waitForFile(ack, timeout: 3))
            let rows = Set(fileLines(in: audit).compactMap { line in
                line.split(separator: ",").first { $0.hasPrefix("row=") }.map(String.init)
            })
            XCTAssertGreaterThan(rows.count, 1, "the same reveal token must track the new native index")
        }
    }

    func testSidebarRevealRequestFallsBackWhenAnAcknowledgementNeverArrives() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let fallback = directory.appendingPathComponent("sidebar-reveal-fallback")
        app.launchEnvironment["TRACE_TEST_SKIP_SIDEBAR_PROJECT_REVEAL_ACK"] = "1"
        app.launchEnvironment["TRACE_TEST_SIDEBAR_REVEAL_FALLBACK_DELAY_MS"] = "300"
        app.launchEnvironment["TRACE_TEST_SIDEBAR_REVEAL_FALLBACK_PATH"] = fallback.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.click()
        search.typeText("Find the sample answer")
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find the sample answer"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()

        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(fallback, timeout: 5),
                      "a missing sidebar acknowledgement must release the reveal request")
    }

    func testGlobalSearchKeepsSelectedSessionBeyondProjectListLimit() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let file = directory.appendingPathComponent("Sources/Claude/many-sessions.jsonl")
        var data = Data()
        for index in 0..<505 {
            let row: [String: Any] = [
                "type": "user", "uuid": "large-session-message-\(index)",
                "sessionId": "large-session-\(index)", "cwd": "/tmp/TraceUIExample",
                "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": index == 0
                    ? "OldestSessionSurvivalNeedle"
                    : "Large project session \(index)"],
            ]
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let search = app.textFields["Search all sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.click()
        search.typeText("OldestSessionSurvivalNeedle")
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "OldestSessionSurvivalNeedle"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let sessionID = try sqliteInteger(
            directory.appendingPathComponent("index.sqlite"),
            sql: "SELECT id FROM session WHERE external_id='large-session-0';"
        )
        result.click()

        let session = app.descendants(matching: .any)[
            "sessionSidebarRow-\(sessionID)"
        ].firstMatch
        XCTAssertTrue(session.wait(for: \.isHittable, toEqual: true, timeout: 15),
                      "the selected session must be merged beyond the 500-row project page")
        XCTAssertTrue(session.isSelected)
    }

    func testDeselectingSelectedProjectClosesAnOpenTranscript() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["TraceUIExample"].waitForExistence(timeout: 15))
        let projectID = try sqliteInteger(
            directory.appendingPathComponent("index.sqlite"),
            sql: "SELECT id FROM project WHERE canonical_key='/tmp/traceuiexample';"
        )
        let project = app.descendants(matching: .any)[
            "projectSidebarRow-\(projectID)"
        ].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.click()
        let session = app.staticTexts["Find the sample answer"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))

        XCUIElement.perform(withKeyModifiers: [.command]) { project.click() }

        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews["transcriptScroll"].exists)
        XCTAssertFalse(project.isSelected,
                       "deselecting the project row must clear both selections")
    }

    func testCrossProjectSearchResultDoesNotRunAnIntermediateMainSearch() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addSession(
            id: "cross-project-target", title: "Cross project target",
            project: "CrossProject", timestamp: 1_800_000_000_000,
            content: "CrossProjectNeedle", directory: directory
        )
        let audit = directory.appendingPathComponent("cross-project-search-requests")
        app.launchEnvironment["TRACE_TEST_SEARCH_REQUEST_AUDIT_PATH"] = audit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["TraceUIExample"].waitForExistence(timeout: 15))
        app.staticTexts["TraceUIExample"].click()
        let mainSearch = app.textFields["mainSearch"]
        XCTAssertTrue(mainSearch.waitForExistence(timeout: 10))
        mainSearch.click()
        mainSearch.typeText("Find")
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find the sample answer"
        )).firstMatch.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)
        ensurePopoverOpen(app)
        let globalSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(globalSearch.waitForExistence(timeout: 10))
        globalSearch.click()
        globalSearch.typeText("CrossProjectNeedle")
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "CrossProjectNeedle"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: audit)
        result.click()

        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(fileLines(in: audit), [],
                       "cross-project navigation must not search stale main criteria")
    }

    private func addSession(
        id: String, title: String, project: String, timestamp: Int64,
        content: String, directory: URL
    ) throws {
        let records: [[String: Any]] = [
            ["type": "custom-title", "customTitle": title],
            [
                "type": "user", "uuid": "\(id)-message", "sessionId": id,
                "cwd": "/tmp/\(project)", "timestamp": timestamp,
                "message": ["content": content],
            ],
        ]
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        try data.write(to: directory.appendingPathComponent("Sources/Claude/\(id).jsonl"))
    }

    private func assertSidebarSelection(
        _ app: XCUIApplication, projectID: Int64, sessionID: Int64,
        projectName: String, sessionTitle: String
    ) {
        let project = app.descendants(matching: .any)["projectSidebarRow-\(projectID)"].firstMatch
        let session = app.descendants(matching: .any)["sessionSidebarRow-\(sessionID)"].firstMatch
        // SwiftUI can expose the selected container as unhittable even when its
        // text is fully visible. Check the leaf's hit target and the row's state.
        let projectText = project.staticTexts[projectName].firstMatch
        XCTAssertTrue(projectText.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "\(projectName) must be revealed in the project pane")
        XCTAssertTrue(project.isSelected, "\(projectName) must be selected")
        XCTAssertTrue(session.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "\(sessionTitle) must be revealed in the session pane")
        XCTAssertTrue(session.isSelected, "\(sessionTitle) must be selected")
    }

    private func addLongSession(
        _ name: String, project: String, directory: URL, count: Int = 70,
        mostlySystem: Bool = false, contentRepeats: Int = 24
    ) throws {
        var objects: [[String: Any]] = [["type": "custom-title", "customTitle": name]]
        for index in 0..<count {
            let type = mostlySystem && index > 0 && index < count - 1
                ? "system"
                : index == 0 ? "user" : "assistant"
            objects.append(["type": type, "uuid": "\(name)-\(index)",
                "sessionId": name, "cwd": "/tmp/\(project)", "timestamp": "2026-09-14T12:00:00Z",
                "message": ["content": "\(name) message \(index)\n" + String(repeating: "Transcript fixture content. ", count: contentRepeats)]])
        }
        var data = Data()
        for object in objects { data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10) }
        try data.write(to: directory.appendingPathComponent("Sources/Claude/\(name).jsonl"))
    }

    func testWheelOverTranscriptTextAndGutterScrollsWithoutBreakingCopy() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Wheel routing", project: "WheelProject", directory: directory,
            contentRepeats: 0
        )
        let offsets = directory.appendingPathComponent("transcript-wheel-offsets")
        let idleAudit = directory.appendingPathComponent("transcript-wheel-idle")
        let gapOffsets = directory.appendingPathComponent("transcript-wheel-gap-offsets")
        let wheelRoute = directory.appendingPathComponent("transcript-wheel-route")
        let bookmark = directory.appendingPathComponent("transcript-wheel-bookmark")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_OFFSET_PATH"] = offsets.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_GAP_OFFSET_PATH"] = gapOffsets.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_WHEEL_ROUTE_PATH"] = wheelRoute.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmark.path
        defer {
            for (name, file) in [("wheel-routes", wheelRoute), ("wheel-gap-offsets", gapOffsets),
                                 ("wheel-viewport-offsets", offsets)] {
                let attachment = XCTAttachment(string: fileLines(in: file).joined(separator: "\n"))
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["WheelProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["WheelProject"].firstMatch.click()
        openSidebarSession("Wheel routing", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let first = transcriptMessage("Wheel routing", index: 0, in: scroll)
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10))
        app.activate()
        let initialOffset = numericLine(in: offsets) ?? 0

        let firstFinishCount = completedInputCycleCount(in: idleAudit)
        // The accessibility frame spans the proposed text width, including blank
        // space. Aim at the visible glyphs so this exercises NSTextView routing.
        let textPoint = first.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: 9))
        // Finish moving the pointer before XCTest synthesizes the wheel gesture.
        textPoint.hover()
        textPoint.scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: firstFinishCount + 1, timeout: 10
        ), "wheel input over selectable message text must reach the transcript")
        let afterText = try XCTUnwrap(numericLine(in: offsets))
        XCTAssertGreaterThan(afterText, initialOffset + 50)
        XCTAssertTrue(fileLines(in: wheelRoute).contains("text"),
                      "wheel input over message text must traverse its responder")
        XCTAssertTrue(fileLines(in: wheelRoute).contains("scroll"),
                      "the responder must forward the wheel to the transcript scroll view")

        try? FileManager.default.removeItem(at: gapOffsets)
        app.buttons["testProbeTranscriptPosition"].click()
        let gapOffset = try XCTUnwrap(poll(timeout: 5) {
            numericLine(in: gapOffsets)
        }, "the table must expose a visible gap between messages")
        let gapFinishCount = completedInputCycleCount(in: idleAudit)
        let gapPoint = scroll.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: scroll.frame.width / 2, dy: gapOffset))
        gapPoint.hover()
        gapPoint.scroll(byDeltaX: 0, deltaY: -350)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: gapFinishCount + 1, timeout: 10
        ), "wheel input in a table gap must reach the transcript")
        let afterGap = try XCTUnwrap(numericLine(in: offsets))
        XCTAssertGreaterThan(afterGap, afterText + 30)
        XCTAssertTrue(fileLines(in: wheelRoute).contains("table"),
                      "wheel input in a row gap must traverse the table responder")

        let paddingFinishCount = completedInputCycleCount(in: idleAudit)
        let paddingPoint = scroll.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 14, dy: scroll.frame.height / 2))
        paddingPoint.hover()
        paddingPoint.scroll(byDeltaX: 0, deltaY: -350)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: paddingFinishCount + 1, timeout: 10
        ), "wheel input in row padding must reach the transcript")
        let afterPadding = try XCTUnwrap(numericLine(in: offsets))
        XCTAssertGreaterThan(afterPadding, afterGap + 30)

        let secondFinishCount = completedInputCycleCount(in: idleAudit)
        let gutterPoint = scroll.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 4, dy: scroll.frame.height / 2))
        gutterPoint.hover()
        gutterPoint.scroll(byDeltaX: 0, deltaY: -450)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: secondFinishCount + 1, timeout: 10
        ), "wheel input in the table gutter must reach the transcript")
        let afterGutter = try XCTUnwrap(numericLine(in: offsets))
        XCTAssertGreaterThan(afterGutter, afterPadding + 30)

        let readingIndex = try XCTUnwrap(poll(timeout: 10) {
            fileLines(in: bookmark).last.flatMap(Int.init)
        })
        // Re-query by logical message identity: index-bound AX elements can be
        // recycled between the geometry check and reading their text value.
        let message = transcriptMessage("Wheel routing", index: readingIndex + 2, in: scroll)
        XCTAssertTrue(message.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertTrue(scroll.frame.contains(message.frame), "Copy needs a fully visible line")
        app.activate()
        let pasteboardChangeCount = preparePasteboardForCopy()
        message.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: 9)).click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        assertPasteboardChanged(
            after: pasteboardChangeCount, contains: ["Wheel routing message"],
            message: "wheel routing must preserve native text selection and Copy"
        )
    }

    func testTranscriptBottomFollowsLiveAppendOnlyWhilePinned() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Bottom follow", project: "BottomProject", directory: directory)
        let offsets = directory.appendingPathComponent("transcript-bottom-offsets")
        let idleAudit = directory.appendingPathComponent("transcript-bottom-idle")
        let bookmarkSaved = directory.appendingPathComponent("transcript-bottom-bookmark")
        let restoreAudit = directory.appendingPathComponent("transcript-bottom-restore")
        let bottomAudit = directory.appendingPathComponent("transcript-bottom-applied")
        let positionProbe = directory.appendingPathComponent("transcript-bottom-position")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_OFFSET_PATH"] = offsets.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_AUDIT_PATH"] = restoreAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOTTOM_AUDIT_PATH"] = bottomAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = positionProbe.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "1500"
        let boundsAudit = directory.appendingPathComponent("transcript-bottom-bounds")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"] = boundsAudit.path
        defer {
            for (name, file) in [("bottom-bounds", boundsAudit), ("bottom-restores", restoreAudit),
                                 ("bottom-applied", bottomAudit), ("bottom-position", positionProbe)] {
                let attachment = XCTAttachment(string: fileLines(in: file).joined(separator: "\n"))
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        func appendMessage(_ index: Int, content: String) throws {
            let record: [String: Any] = [
                "type": "assistant", "uuid": "Bottom follow-\(index)",
                "sessionId": "Bottom follow", "cwd": "/tmp/BottomProject",
                "timestamp": "2026-09-14T12:00:10Z",
                "message": ["content": "Bottom follow message \(index)\n\(content)"],
            ]
            let file = directory.appendingPathComponent("Sources/Claude/Bottom follow.jsonl")
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
            try handle.close()
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["BottomProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["BottomProject"].firstMatch.click()
        openSidebarSession("Bottom follow", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let first = transcriptMessage("Bottom follow", index: 0, in: scroll)
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(first.isHittable, "initial hydration must leave the first message in view")

        let transcriptPoint = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        try? FileManager.default.removeItem(at: idleAudit)
        transcriptPoint.hover()
        transcriptPoint.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 10))
        transcriptPoint.scroll(byDeltaX: 0, deltaY: -600)
        transcriptPoint.scroll(byDeltaX: 0, deltaY: -600)
        transcriptPoint.scroll(byDeltaX: 0, deltaY: 700)
        app.buttons["testProbeTranscriptPosition"].click()
        let upwardPosition = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(String(upwardPosition[2]), "false", "upward wheel input must unpin")
        XCTAssertGreaterThan(try XCTUnwrap(Double(upwardPosition[1])) - XCTUnwrap(Double(upwardPosition[0])), 50,
            "upward wheel input must move above the current measured bottom")

        let settledFinishes = completedInputCycleCount(in: idleAudit)
        transcriptPoint.hover()
        transcriptPoint.scroll(byDeltaX: 0, deltaY: -100_000)
        try appendMessage(70, content: "Append while the bottom scroll settles")
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: settledFinishes + 1, timeout: 10
        ))
        let appended = transcriptMessage("Bottom follow", index: 70, in: scroll)
        XCTAssertTrue(appended.wait(for: \.isHittable, toEqual: true, timeout: 15),
                      "reaching the bottom must follow an append during the idle interval")
        try appendMessage(71, content: String(repeating: "Late **Markdown** height. ", count: 80))
        let lateHeight = transcriptMessage("Bottom follow", index: 71, in: scroll)
        XCTAssertTrue(lateHeight.wait(for: \.isHittable, toEqual: true, timeout: 15),
                      "a settled reader at the bottom must see a live append after hydration")
        XCTAssertNotNil(poll(timeout: 10) { () -> [Double]? in
            guard let fields = fileLines(in: bottomAudit).last?.split(separator: ",")
                    .compactMap({ Double($0) }),
                  fields.count == 2, abs(fields[0] - fields[1]) <= 2 else { return nil }
            return fields
        }, "late row measurement must leave the viewport at the measured bottom")

        app.checkBoxes["Tools"].click()
        let reasoningFilter = app.checkBoxes["Reasoning"].firstMatch
        XCTAssertTrue(reasoningFilter.waitForExistence(timeout: 10))
        reasoningFilter.click()
        try appendMessage(72, content: "Append after changing transcript filters")
        XCTAssertTrue(transcriptMessage("Bottom follow", index: 72, in: scroll)
            .wait(for: \.isHittable, toEqual: true, timeout: 15),
            "Tools and Reasoning filters must retain live bottom follow")

        let window = app.windows.firstMatch
        let previousHeight = window.frame.height
        app.buttons["testProbeTranscriptPosition"].click()
        let beforeResize = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(String(beforeResize[2]), "true", "reader must be pinned before resize")
        XCTAssertEqual(try XCTUnwrap(Double(beforeResize[0])),
            try XCTUnwrap(Double(beforeResize[1])), accuracy: 2)
        try? FileManager.default.removeItem(at: positionProbe)
        let resize = app.buttons["testResizeWindow"]
        XCTAssertTrue(resize.waitForExistence(timeout: 5))
        resize.click()
        XCTAssertLessThan(window.frame.height, previousHeight - 20,
            "the UI test must actually resize the transcript viewport")
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertTrue(waitForFile(positionProbe, timeout: 10))
        let positionFields = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(positionFields.count, 3)
        XCTAssertEqual(String(positionFields[2]), "true",
            "resize must preserve bottom-follow mode")
        let resizedOrigin = try XCTUnwrap(Double(positionFields[0]))
        let resizedMaximum = try XCTUnwrap(Double(positionFields[1]))
        XCTAssertEqual(resizedOrigin, resizedMaximum, accuracy: 2,
            "resize itself must leave the viewport at the new bottom")
        try appendMessage(73, content: "Append after resizing the pinned viewport")
        XCTAssertTrue(transcriptMessage("Bottom follow", index: 73, in: scroll)
            .wait(for: \.isHittable, toEqual: true, timeout: 15),
            "resizing the window must retain live bottom follow")

        let upwardFinishCount = completedInputCycleCount(in: idleAudit)
        transcriptPoint.hover()
        transcriptPoint.scroll(byDeltaX: 0, deltaY: 1_100)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: upwardFinishCount + 1, timeout: 10
        ))
        let readingIndex = try XCTUnwrap(waitForStableBookmarkIndex(bookmarkSaved))
        try? FileManager.default.removeItem(at: positionProbe)
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertTrue(waitForFile(positionProbe, timeout: 10))
        let readingPosition = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(String(readingPosition[2]), "false", "upward input must unpin after idle")
        XCTAssertGreaterThan(try XCTUnwrap(Double(readingPosition[1]))
            - XCTUnwrap(Double(readingPosition[0])), 50,
            "upward input must leave the reader above the current document bottom")
        let restoreCountBeforeAppend = fileLines(in: restoreAudit).count
        try appendMessage(74, content: "A later message while reading above the bottom")
        XCTAssertTrue(app.staticTexts["75 messages"].waitForExistence(timeout: 15))
        let measurement = try XCTUnwrap(poll(timeout: 10) { () -> [String]? in
            let lines = fileLines(in: restoreAudit)
            guard lines.count > restoreCountBeforeAppend,
                  let fields = lines.last?.split(separator: ",").map(String.init),
                  fields.count == 5,
                  fields[0] == String(readingIndex) else { return nil }
            return fields
        })
        XCTAssertEqual(try XCTUnwrap(Double(measurement[1])),
                       try XCTUnwrap(Double(measurement[2])), accuracy: 1,
                       "a live append must preserve the saved row offset when not pinned")
    }

    func testExpandingReasoningAtBottomKeepsTheClickedHeaderVisible() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Reasoning growth", project: "ReasoningProject", directory: directory,
            count: 24, contentRepeats: 0
        )
        let layoutAudit = directory.appendingPathComponent("disclosure-row-layout-audit")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_ROW_LAYOUT_AUDIT_PATH"] = layoutAudit.path
        defer {
            let diagnostic = XCTAttachment(string: fileLines(in: layoutAudit).joined(separator: "\n"))
            diagnostic.name = "Disclosure row layout"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        let file = directory.appendingPathComponent("Sources/Claude/Reasoning growth.jsonl")
        func append(_ id: String, content: Any) throws {
            let record: [String: Any] = [
                "type": "assistant", "uuid": id, "sessionId": "Reasoning growth",
                "cwd": "/tmp/ReasoningProject", "timestamp": "2026-09-14T12:00:10Z",
                "message": ["content": content],
            ]
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
            try handle.close()
        }
        try append("reasoning-disclosure", content: [
            ["type": "text", "text": "Reasoning growth message 24"],
            ["type": "thinking", "thinking": String(repeating: "A long thought. ", count: 220)],
        ])
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ReasoningProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["ReasoningProject"].firstMatch.click()
        openSidebarSession("Reasoning growth", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        let disclosure = scroll.buttons["Reasoning"].firstMatch
        XCTAssertTrue(disclosure.wait(for: \.isHittable, toEqual: true, timeout: 10))
        let headerY = disclosure.frame.minY
        disclosure.click()
        XCTAssertTrue(disclosure.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "expansion must keep the clicked header on screen")
        XCTAssertEqual(disclosure.frame.minY, headerY, accuracy: 64)
        try append("reasoning-later", content: "Later message")
        XCTAssertTrue(app.staticTexts["26 messages"].waitForExistence(timeout: 15))
        XCTAssertTrue(disclosure.isHittable,
                      "an append after expansion must not resume bottom following")
        XCTAssertEqual(disclosure.frame.minY, headerY, accuracy: 64)
    }

    func testMonitoringWarningsAreVisibleOnAllSearchSurfaces() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let sidecar = directory.appendingPathComponent("Sources/session_index.jsonl")
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: "session_index.jsonl")
        app.launch(); app.buttons["Build Index"].click()
        let statusText = "Index current · Monitoring incomplete"
        XCTAssertTrue(app.buttons["indexProgress"].waitForExistence(timeout: 20))
        let main = app.windows.firstMatch
        let mainStatus = main.buttons["indexProgress"]
        XCTAssertNotNil(poll(timeout: 15) { mainStatus.label.contains(statusText) ? true : nil }, mainStatus.label)
        attach(app, name: "main-monitoring-incomplete")
        app.buttons["indexProgress"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "symlink cycle")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["indexProgress"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(main.waitForNonExistence(timeout: 5))
        ensurePopoverOpen(app)
        let popover = app.textFields["Search all sessions"]
        XCTAssertTrue(popover.exists)
        XCTAssertTrue(app.buttons["indexProgress"].label.contains(statusText), app.buttons["indexProgress"].label)
        attach(app, name: "popover-monitoring-incomplete")
        popover.click(); popover.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["Search Claude Code, Codex, and Gemini"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["indexProgress"].label.contains(statusText), app.buttons["indexProgress"].label)
        attach(app, name: "launcher-monitoring-incomplete")
        app.buttons["indexProgress"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "symlink cycle")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty)
    }

    func testRestoreWaitsForHydrationBeyond450Milliseconds() throws { try runHydrationRestore(delay: 650) }
    func testRestoreWaitsForHydrationBeyond825Milliseconds() throws { try runHydrationRestore(delay: 1300) }
    func testHydrationTimeoutPreservesBookmarkAndLateCompletionResumes() throws {
        try runHydrationRestore(delay: 15_000, timeout: true)
    }
    func testUserInputCancelsTimedOutHydrationRestore() throws {
        try runHydrationRestore(delay: 15_000, timeout: true, cancel: true)
    }
    func testCollapsedLargeToolRowClampsOffsetWithoutHydrating() throws {
        try runHydrationRestore(delay: 1300, collapsed: true)
    }

    func testDevNullSourceRootDoesNotCrashStartup() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let root = directory.appendingPathComponent("Sources/Claude")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: "/dev/null")
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Trace Settings"].waitForExistence(timeout: 5))
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
    }

    func testShortLiveGeminiFollowsAppendWhileHydrationIsGated() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let project = directory.appendingPathComponent("Sources/Gemini/live")
        let chats = project.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try "/tmp/GeminiLoadingProject\n".write(to: project.appendingPathComponent(".project_root"), atomically: true, encoding: .utf8)
        let source = chats.appendingPathComponent("session-live.jsonl")
        func record(_ index: Int) throws -> Data {
            let object: [String: Any] = ["sessionId": "session-live", "$set": ["messages": [[
                "id": "gemini-\(index)", "type": index == 0 ? "user" : "gemini",
                "timestamp": "2026-09-14T12:00:00Z",
                "content": index == 0 ? "Gemini loading" : "Live Gemini message \(index) " + String(repeating: "stream content ", count: 40)
            ]]]]
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            return data
        }
        try record(0).write(to: source)
        let release = directory.appendingPathComponent("gemini-hydration-release")
        let completed = directory.appendingPathComponent("gemini-provisional-completed")
        let probe = directory.appendingPathComponent("gemini-position")
        let follow = directory.appendingPathComponent("gemini-follow")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_DELAY_MS"] = "30000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = probe.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_FOLLOW_MARKER_PREFIX"] = follow.path
        app.launch(); app.activate(); app.buttons["Build Index"].click()
        let projectRow = app.staticTexts["GeminiLoadingProject"].firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 30)); projectRow.click()
        openSidebarSession("Gemini loading", in: app)
        XCTAssertTrue(waitForFile(completed, timeout: 10))
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        for index in 1..<30 { try handle.write(contentsOf: record(index)) }
        try handle.close()
        XCTAssertTrue(waitForFile(URL(fileURLWithPath: follow.path + "-30"), timeout: 15))
        func assertFollowing() {
            app.buttons["testProbeTranscriptPosition"].click()
            let fields = fileLines(in: probe).last?.split(separator: ",").map(String.init) ?? []
            XCTAssertEqual(fields.count, 3)
            if fields.count == 3 {
                XCTAssertEqual(fields[2], "true")
                XCTAssertEqual(Double(fields[0]) ?? -100, Double(fields[1]) ?? 100, accuracy: 2)
            }
        }
        assertFollowing()
        try Data().write(to: release)
        XCTAssertNotNil(poll(timeout: 10) {
            app.buttons["testProbeTranscriptPosition"].click()
            let fields = fileLines(in: probe).last?.split(separator: ",").map(String.init) ?? []
            guard fields.count == 3, fields[2] == "true",
                  let y = Double(fields[0]), let maximum = Double(fields[1]), abs(y - maximum) <= 2 else { return nil }
            return y
        }, "late hydration must retain the newer bottom-follow intent")
        assertFollowing()
    }

    func testHiddenBookmarkFallsBackToEarlierVisibleRow() throws {
        try runHydrationRestore(delay: 1300, hidden: true)
    }
    func testSourceGenerationChangeDuringDeferredHydrationDoesNotStrandRestore() throws {
        try runHydrationRestore(delay: 30_000, timeout: true, replaceGeneration: true)
    }
    func testNeverCompletingHydrationLeavesScrollingAndSavingUsable() throws {
        try runHydrationRestore(delay: 30_000, timeout: true, cancel: true, neverCompletes: true)
    }
    func testCollapsedRestoreRetainsEffectiveOffsetDuringPassiveAndVisibilityChanges() throws {
        try runHydrationRestore(delay: 1300, collapsed: true, passiveAndVisibility: true)
    }

    func testOversizedRestoreOffsetSettlesAfterDensityChangeAndWidening() throws {
        try runHydrationRestore(delay: 0, oversized: true)
    }
    func testSessionSwitchCancelsDeferredContentRefinement() throws {
        try runHydrationRestore(delay: 30_000, timeout: true, switchSession: true)
    }

    func testFinalRowBookmarkWaitsWithoutFollowingProvisionalBottom() throws {
        try runHydrationRestore(delay: 15_000, timeout: true, bookmarkIndex: 29)
    }
    func testLateDensityAndVisibilityChangesPreserveHydrationIntent() throws {
        try runHydrationRestore(delay: 15_000, timeout: true, lateChanges: true)
    }
    func testFailedBookmarkLoadKeepsIntentUntilManualRetry() throws {
        try runHydrationRestore(delay: 0, failedRead: true)
    }
    func testFinalRowFailedLoadKeepsIntentUntilManualRetry() throws {
        try runHydrationRestore(delay: 0, bookmarkIndex: 29, failedRead: true)
    }
    func testShortenedContentNormalizesBookmarkAfterHydrationSettles() throws {
        try runHydrationRestore(delay: 15_000, timeout: true, shortenedContent: true)
    }
    func testDensityChangeDuringGatedGeometryResetsRefinement() throws {
        try runHydrationRestore(delay: 0, geometryGate: true)
    }
    func testExhaustedGeometryWaitsForMeaningfulChangeBeforeSaving() throws {
        try runHydrationRestore(delay: 0, exhaustGeometryBudget: true)
    }

    func testReplacementWithReusedIDsAndChangedLocatorsRejectsLateHydration() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Sources/Claude/session.jsonl"))
        let name = "Replacement race"
        try addLongSession(name, project: "ReplacementProject", directory: directory, count: 30, contentRepeats: 300)
        let entered = directory.appendingPathComponent("result-entered")
        let release = directory.appendingPathComponent("result-release")
        let accepted = directory.appendingPathComponent("accepted-hydration")
        app.launchEnvironment["TRACE_TEST_HYDRATION_RESULT_ENTERED_PATH"] = entered.path
        app.launchEnvironment["TRACE_TEST_HYDRATION_RESULT_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_COMPLETED_PATH"] = accepted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_INDEX"] = "12"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_OFFSET"] = "-450"
        installNativeAnchorProbe(app: app, directory: directory)
        app.launch(); app.activate(); app.buttons["Build Index"].click()
        let project = app.staticTexts["ReplacementProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30)); project.click()
        openSidebarSession(name, in: app)
        XCTAssertTrue(waitForFile(entered, timeout: 10))
        let db = directory.appendingPathComponent("index.sqlite")
        let previousID = try sqliteInteger(db, sql: "SELECT id FROM message WHERE seq=12;")
        let previousLocator = try sqliteInteger(db, sql: "SELECT coalesce(max(loc_offset), -1) FROM message WHERE seq=12;")
        let source = directory.appendingPathComponent("Sources/Claude/\(name).jsonl")
        let lines = try String(contentsOf: source, encoding: .utf8).split(separator: "\n")
        var replacement = Data()
        for line in lines {
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if var message = record["message"] as? [String: Any], let text = message["content"] as? String {
                message["content"] = text + " ReplacementHydratedTail " + String(repeating: "changed bytes ", count: 100)
                record["message"] = message
            }
            replacement.append(try JSONSerialization.data(withJSONObject: record)); replacement.append(10)
        }
        try replacement.write(to: source, options: .atomic)
        XCTAssertNotNil(poll(timeout: 15) {
            guard let offset = try? self.sqliteInteger(db, sql: "SELECT coalesce(max(loc_offset), -1) FROM message WHERE seq=12;"),
                  offset > 0, offset != previousLocator else { return nil }
            return offset
        })
        XCTAssertEqual(try sqliteInteger(db, sql: "SELECT id FROM message WHERE seq=12;"), previousID,
                       "the fixture must exercise reused IDs")
        XCTAssertTrue(fileLines(in: accepted).isEmpty)
        try Data().write(to: release)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "ReplacementHydratedTail")).firstMatch.waitForExistence(timeout: 15),
                      "only hydration for the replacement locators may publish")
        assertSavedAnchorOnScreen(index: 12, in: scroll, expectedY: -450, stage: "replacement locators")
    }

    func testAppendCannotCancelSearchAndSettledBottomSearchFollowsLaterAppends() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let name = "Search append"
        try addLongSession(name, project: "SearchAppendProject", directory: directory, count: 30, contentRepeats: 0)
        let source = directory.appendingPathComponent("Sources/Claude/\(name).jsonl")
        let entered = directory.appendingPathComponent("search-restore-entered")
        let release = directory.appendingPathComponent("search-restore-release")
        let completed = directory.appendingPathComponent("search-restore-completed")
        let probe = directory.appendingPathComponent("search-position")
        let follow = directory.appendingPathComponent("search-follow")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_RELEASE_PATH"] = release.path
        let initialCompleted = directory.appendingPathComponent("initial-completed")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_STARTED_PATH"] = entered.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_COMPLETED_PATH"] = completed.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_COMPLETED_PATH"] = initialCompleted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = probe.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_FOLLOW_MARKER_PREFIX"] = follow.path
        app.launch(); app.activate(); app.buttons["Build Index"].click()
        let project = app.staticTexts["SearchAppendProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30)); project.click()
        openSidebarSession(name, in: app)
        XCTAssertTrue(waitForFile(initialCompleted, timeout: 10))
        app.buttons["testOpenLauncher"].click()
        let search = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.click(); search.typeText("Search append message 29")
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Search append message 29")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10)); hit.click()
        XCTAssertTrue(waitForFile(entered, timeout: 10))
        func append(_ index: Int) throws {
            let record: [String: Any] = ["type": "assistant", "uuid": "append-\(index)", "sessionId": name,
                "cwd": "/tmp/SearchAppendProject", "timestamp": 1_790_000_000_000 + index,
                "message": ["content": "Search append message \(index)"]]
            let writer = try FileHandle(forWritingTo: source)
            try writer.seekToEnd(); try writer.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10])); try writer.close()
        }
        try append(30)
        XCTAssertTrue(app.staticTexts["31 messages"].waitForExistence(timeout: 15))
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertEqual(fileLines(in: probe).last?.split(separator: ",").last, "false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        try Data().write(to: release)
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertEqual(fileLines(in: probe).last?.split(separator: ",").last, "true",
                       "search may follow bottom only after it fully settles")
        try append(31)
        XCTAssertTrue(waitForFile(URL(fileURLWithPath: follow.path + "-32"), timeout: 15))
    }

    private func runHydrationRestore(delay: Int, timeout: Bool = false, cancel: Bool = false, collapsed: Bool = false,
                                     hidden: Bool = false, replaceGeneration: Bool = false,
                                     neverCompletes: Bool = false, passiveAndVisibility: Bool = false,
                                     oversized: Bool = false, switchSession: Bool = false, bookmarkIndex: Int = 12,
                                     lateChanges: Bool = false, failedRead: Bool = false, geometryGate: Bool = false,
                                     exhaustGeometryBudget: Bool = false, shortenedContent: Bool = false) throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let name = "Hydration restore"
        try addLongSession(name, project: "HydrationProject", directory: directory, count: 30, contentRepeats: 300)
        if switchSession { try addLongSession("Other restore", project: "HydrationProject", directory: directory, count: 2) }
        if shortenedContent {
            // The saved -450 bookmark belongs to the original long content.
            // Rewrite it while the app is closed, then gate opening the shorter
            // source so placeholder geometry cannot normalize that old intent.
            let source = directory.appendingPathComponent("Sources/Claude/\(name).jsonl")
            var lines = try String(contentsOf: source, encoding: .utf8).split(separator: "\n").map(String.init)
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[bookmarkIndex + 1].utf8)) as? [String: Any])
            var message = try XCTUnwrap(record["message"] as? [String: Any])
            XCTAssertGreaterThan(try XCTUnwrap(message["content"] as? String).count, 450)
            message["content"] = "\(name) message \(bookmarkIndex)\nShortened answer."
            record["message"] = message
            lines[bookmarkIndex + 1] = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            try (lines.joined(separator: "\n") + "\n").write(to: source, atomically: true, encoding: .utf8)
        }
        if collapsed || hidden {
            let file = directory.appendingPathComponent("Sources/Claude/\(name).jsonl")
            var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            let record: [String: Any] = ["type": "user", "uuid": "collapsed-output", "sessionId": name,
                "cwd": "/tmp/HydrationProject", "timestamp": "2026-09-14T12:00:00Z",
                "message": ["content": [["type": "tool_result", "content": "Large collapsed tool output " + String(repeating: "output data. ", count: 50_000)]]]]
            lines[13] = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        installNativeAnchorProbe(app: app, directory: directory)
        if let probe = nativeAnchorProbe {
            try String(bookmarkIndex).write(to: probe.input, atomically: true, encoding: .utf8)
        }
        let release = directory.appendingPathComponent("hydration-release")
        let timedOut = directory.appendingPathComponent("hydration-timeout")
        let completed = directory.appendingPathComponent("native-restore-completed")
        let cancelled = directory.appendingPathComponent("restore-cancelled")
        let audit = directory.appendingPathComponent("hydration-restore-audit")
        let hydrated = directory.appendingPathComponent("hydrated-ids")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_DELAY_MS"] = String(delay)
        if timeout { app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_RELEASE_PATH"] = release.path }
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_TIMEOUT_PATH"] = timedOut.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_COMPLETED_PATH"] = hydrated.path
        let savedReader = directory.appendingPathComponent("saved-reader-bookmark")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = savedReader.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = cancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_HYDRATION_RESTORE_AUDIT_PATH"] = audit.path
        let intent = directory.appendingPathComponent("intended-bookmark")
        let position = directory.appendingPathComponent("hydration-position")
        let passes = directory.appendingPathComponent("geometry-passes")
        let geometry = directory.appendingPathComponent("geometry-entered")
        let geometryRelease = directory.appendingPathComponent("geometry-release")
        let stabilityRelease = directory.appendingPathComponent("geometry-stability-release")
        let exhausted = directory.appendingPathComponent("geometry-exhausted")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_INTENDED_BOOKMARK_PROBE_PATH"] = intent.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = position.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_GEOMETRY_PASSES_PATH"] = passes.path
        if failedRead {
            app.launchEnvironment["TRACE_TEST_FAIL_HYDRATION_ONCE"] = "1"
            app.launchEnvironment["TRACE_TEST_FAIL_HYDRATION_MESSAGE_INDEX"] = String(bookmarkIndex)
        }
        if geometryGate {
            app.launchEnvironment["TRACE_TEST_TRANSCRIPT_GEOMETRY_RELEASE_PATH"] = geometryRelease.path
            app.launchEnvironment["TRACE_TEST_TRANSCRIPT_GEOMETRY_ENTERED_PATH"] = geometry.path
        }
        if exhaustGeometryBudget {
            app.launchEnvironment["TRACE_TEST_TRANSCRIPT_GEOMETRY_STABILITY_RELEASE_PATH"] = stabilityRelease.path
            app.launchEnvironment["TRACE_TEST_TRANSCRIPT_GEOMETRY_BUDGET_EXHAUSTED_PATH"] = exhausted.path
        }
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_INDEX"] = String(bookmarkIndex)
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_OFFSET"] = oversized ? "-100000" : "-450"
        app.launchEnvironment["TRACE_TEST_WINDOW_WIDTH_DELTA"] = "600"
        app.launchEnvironment["TRACE_TEST_WINDOW_HEIGHT_DELTA"] = "0"
        let persisted = directory.appendingPathComponent("persisted-restore-bookmark")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_PERSISTED_BOOKMARK_PATH"] = persisted.path
        defer {
            for file in [audit, hydrated, directory.appendingPathComponent("native-anchor-offset")] {
                let attachment = XCTAttachment(string: fileLines(in: file).joined(separator: "\n"))
                attachment.name = file.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        app.launch(); app.activate(); app.buttons["Build Index"].click()
        let project = app.staticTexts["HydrationProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30)); project.click()
        openSidebarSession(name, in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        if exhaustGeometryBudget {
            XCTAssertTrue(waitForFile(exhausted, timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            let attempted = fileLines(in: passes).count
            XCTAssertGreaterThanOrEqual(attempted, 12)
            XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
            XCTAssertTrue(fileLines(in: persisted).isEmpty,
                          "exhaustion cannot replace the intended bookmark with provisional geometry")
            try Data().write(to: stabilityRelease)
            let filter = app.textFields["projectFilter"]
            XCTAssertTrue(filter.exists); filter.click()
            for character in "Hydra" {
                filter.typeText(String(character))
                XCTAssertEqual(fileLines(in: passes).count, attempted,
                               "unrelated model redraws cannot extend an exhausted geometry budget")
                XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
            }
            app.radioButtons["Compact"].click()
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            XCTAssertGreaterThanOrEqual(fileLines(in: passes).count - attempted, 6,
                                       "a layout change requires a new measurement and five stable checks")
        }
        func assertIntendedBookmark() {
            app.buttons["testProbeTranscriptPosition"].click()
            XCTAssertEqual(fileLines(in: intent).last, "\(bookmarkIndex),-450.0")
            XCTAssertEqual(fileLines(in: position).last?.split(separator: ",").last, "false",
                           "provisional geometry cannot establish bottom-follow")
            XCTAssertTrue(fileLines(in: passes).isEmpty, "waiting consumes no full-content geometry passes")
            let samples = directory.appendingPathComponent("native-anchor-samples")
            let waiting = fileLines(in: samples).filter { $0.split(separator: ",").dropFirst(4).first == "waiting" }
            XCTAssertFalse(waiting.isEmpty, "the provisional anchor must be sampled while restoration is pending")
            for sample in waiting {
                let fields = sample.split(separator: ",")
                guard fields.count == 9, let y = Double(fields[1]), let height = Double(fields[5]),
                      let rowY = Double(fields[6]), let documentHeight = Double(fields[7]),
                      let viewportHeight = Double(fields[8]) else { XCTFail("invalid geometry sample"); continue }
                let clipped = max(-450.0, -max(0, height - 64))
                let origin = min(max(0, rowY - clipped), max(0, documentHeight - viewportHeight))
                XCTAssertEqual(y, rowY - origin, accuracy: 8, "placeholder must retain its fixture-clamped position across main-loop turns")
                XCTAssertEqual(fields[2], "true")
            }
            try? FileManager.default.removeItem(at: samples)
        }
        if failedRead {
            let retry = scroll.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "retryMessage-")).firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 10))
            assertIntendedBookmark()
            app.radioButtons["Compact"].click()
            app.checkBoxes["Reasoning"].click()
            assertIntendedBookmark()
            retry.click()
            XCTAssertTrue(retry.waitForNonExistence(timeout: 10))
        }
        if geometryGate {
            XCTAssertTrue(waitForFile(geometry, timeout: 10))
            app.radioButtons["Compact"].click()
            app.checkBoxes["Reasoning"].click()
            XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
            try Data().write(to: geometryRelease)
        }
        if timeout {
            XCTAssertTrue(waitForFile(timedOut, timeout: 10))
            XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path), "a placeholder must not commit restoration while content remains gated")
            let fields = try XCTUnwrap(fileLines(in: audit).last?.split(separator: ",").map(String.init))
            XCTAssertEqual(fields.first, "timeout")
            assertIntendedBookmark()
            if lateChanges {
                app.radioButtons["Compact"].click()
                app.checkBoxes["Reasoning"].click()
                assertIntendedBookmark()
            }
            XCTAssertFalse(fileLines(in: persisted).contains { $0 != "\(bookmarkIndex),-450.0" }, "automatic saves must preserve the intended bookmark")
            if switchSession {
                app.buttons["backToProject"].click()
                openSidebarSession("Other restore", in: app)
            }
            if cancel {
                try Data().write(to: audit)
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -300)
                XCTAssertTrue(waitForFile(cancelled, timeout: 5))
            }
            if replaceGeneration {
                let database = directory.appendingPathComponent("index.sqlite")
                let previous = try sqliteInteger(database, sql: "SELECT max(content_generation) FROM source_file;")
                let source = directory.appendingPathComponent("Sources/Claude/\(name).jsonl")
                // Inject a generation change without deleting/recreating the session.
                // An append then publishes the current summary through normal indexing.
                let escaped = source.path.replacingOccurrences(of: "'", with: "''")
                _ = try sqliteInteger(database, sql: "UPDATE source_file SET content_generation=content_generation+1 WHERE path='\(escaped)'; SELECT max(content_generation) FROM source_file;")
                let record: [String: Any] = ["type": "assistant", "uuid": "generation-append", "sessionId": name,
                    "cwd": "/tmp/HydrationProject", "message": ["content": "Current generation append"]]
                let writer = try FileHandle(forWritingTo: source)
                try writer.seekToEnd()
                try writer.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
                try writer.close()
                XCTAssertTrue(app.staticTexts["31 messages"].waitForExistence(timeout: 15))
                XCTAssertNotNil(poll(timeout: 10) {
                    guard let generation = try? sqliteInteger(database, sql: "SELECT max(content_generation) FROM source_file;"),
                          generation > previous else { return nil }
                    return generation
                })
            }
            if neverCompletes {
                XCTAssertNotNil(poll(timeout: 5) {
                    guard let value = fileLines(in: savedReader).last, value != String(bookmarkIndex) else { return nil }
                    return value
                }, "new reader position must replace the deferred bookmark")
                XCTAssertTrue(scroll.exists)
                return
            }
            try Data().write(to: release)
        }
        if switchSession {
            XCTAssertTrue(waitForFile(hydrated, timeout: 10))
            assertSavedAnchorOnScreen(index: 0, in: scroll, expectedY: 10, stage: "session switch cancels late refinement")
            XCTAssertEqual(fileLines(in: savedReader).last, "0")
        } else if shortenedContent {
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            let offset = try XCTUnwrap(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
            XCTAssertGreaterThan(offset, -450, "the rewritten content must really be too short for the old offset")
            let fields = try XCTUnwrap(fileLines(in: persisted).last?.split(separator: ","))
            XCTAssertEqual(fields.first.map(String.init), String(bookmarkIndex))
            XCTAssertEqual(try XCTUnwrap(Double(fields[1])), offset, accuracy: 2,
                           "only settled full-content geometry can normalize the intended bookmark")
            app.buttons["testProbeTranscriptPosition"].click()
            XCTAssertEqual(fileLines(in: position).last?.split(separator: ",").last, "false")
        } else if oversized {
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            XCTAssertGreaterThan(try XCTUnwrap(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10)), -100000)
            app.radioButtons["Compact"].click()
            XCTAssertNotNil(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
            app.buttons["testResizeWindow"].click()
            let y = try XCTUnwrap(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
            let fields = try XCTUnwrap(fileLines(in: persisted).last?.split(separator: ","))
            XCTAssertEqual(fields.first.map(String.init), String(bookmarkIndex))
            XCTAssertEqual(try XCTUnwrap(Double(fields[1])), y, accuracy: 2, "normalized geometry must replace the impossible persisted offset")
        } else if hidden {
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            XCTAssertTrue(app.checkBoxes["Tools"].waitForExistence(timeout: 5))
            app.checkBoxes["Tools"].click()
            app.buttons["backToProject"].click()
            try FileManager.default.removeItem(at: completed)
            openSidebarSession(name, in: app)
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            assertSavedAnchorOnScreen(index: 11, in: scroll, expectedY: 0, stage: "hidden bookmark fallback")
        } else if replaceGeneration {
            XCTAssertTrue(waitForFile(hydrated, timeout: 10))
            XCTAssertNotNil(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10), "current-generation content must settle without another user action")
        } else if cancel {
            XCTAssertTrue(waitForFile(hydrated, timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            let completions = fileLines(in: audit).filter { $0.hasPrefix("completed,") }
            XCTAssertTrue(completions.allSatisfy { $0.split(separator: ",")[3] == "false" },
                "late source completion may preserve the new reader anchor but must not replay the cancelled navigation")
        } else if collapsed {
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            let offset = try XCTUnwrap(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
            XCTAssertGreaterThan(offset, -450)
            let id = try sqliteInteger(directory.appendingPathComponent("index.sqlite"),
                sql: "SELECT id FROM message WHERE prefix LIKE 'Large collapsed tool output%' LIMIT 1;")
            XCTAssertFalse(fileLines(in: hydrated).contains(String(id)), "restoring a collapsed row must not hydrate its large output")
            XCTAssertFalse(fileLines(in: audit).contains { $0.hasPrefix("waiting,\(bookmarkIndex),") })
            if passiveAndVisibility {
                app.radioButtons["Compact"].click()
                XCTAssertNotNil(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
                app.checkBoxes["Reasoning"].click()
                XCTAssertNotNil(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
                if let probe = nativeAnchorProbe {
                    let samples = probe.input.deletingLastPathComponent().appendingPathComponent("native-anchor-samples")
                    XCTAssertFalse(fileLines(in: samples).isEmpty)
                    XCTAssertTrue(fileLines(in: samples).allSatisfy { $0.split(separator: ",")[2] == "true" },
                        "effective collapsed bookmark must remain visible on settled main-loop turns")
                }
            }
        } else {
            XCTAssertTrue(waitForFile(completed, timeout: 10))
            assertSavedAnchorOnScreen(index: bookmarkIndex, in: scroll, expectedY: -450, stage: "delayed hydration")
            let waits = fileLines(in: audit).filter { $0.hasPrefix("waiting,\(bookmarkIndex),") }
            if delay > 0 || failedRead { XCTAssertFalse(waits.isEmpty) }
            let saved = try XCTUnwrap(fileLines(in: persisted).last?.split(separator: ","))
            XCTAssertEqual(saved.first.map(String.init), String(bookmarkIndex))
            XCTAssertEqual(try XCTUnwrap(Double(saved[1])), -450, accuracy: 2)
        }
    }

    func testStreamingUpdatesRespectUpwardWheelInput() throws { try runStreamingUpwardInput("wheel") }
    func testStreamingUpdatesRespectUpwardKeyboardInput() throws { try runStreamingUpwardInput("keyboard") }
    func testStreamingUpdatesRespectUpwardScrollbarInput() throws { try runStreamingUpwardInput("scrollbar") }

    private func runStreamingUpwardInput(_ input: String) throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        installNativeAnchorProbe(app: app, directory: directory)
        let name = "Streaming input"
        try addLongSession(name, project: "StreamingInputProject", directory: directory, count: 40)
        let readerProbe = directory.appendingPathComponent("streaming-input-reader")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_READER_PROBE_PATH"] = readerProbe.path
        let idle = directory.appendingPathComponent("streaming-input-idle")
        let probe = directory.appendingPathComponent("streaming-input-position")
        let routes = directory.appendingPathComponent("streaming-input-routes")
        let bounds = directory.appendingPathComponent("streaming-input-bounds")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idle.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = probe.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_WHEEL_ROUTE_PATH"] = routes.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_KEY_ROUTE_PATH"] = routes.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"] = bounds.path
        defer {
            for file in [routes, bounds, probe, readerProbe] {
                let attachment = XCTAttachment(string: fileLines(in: file).joined(separator: "\n"))
                attachment.name = file.lastPathComponent
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        app.launch(); app.activate()
        app.buttons["Build Index"].click()
        let project = app.staticTexts["StreamingInputProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30))
        project.click()
        openSidebarSession(name, in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let point = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        try? FileManager.default.removeItem(at: idle)
        point.hover(); point.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(idle, line: "finished", count: 1, timeout: 10))
        if input == "keyboard" { point.click() }
        try Data().write(to: routes)
        let source = directory.appendingPathComponent("Sources/Claude/\(name).jsonl")
        let records = try (40..<70).map { index -> Data in
            let record: [String: Any] = ["type": "assistant", "uuid": "streaming-input-\(index)",
                "sessionId": name, "cwd": "/tmp/StreamingInputProject",
                "message": ["content": "\(name) message \(index)\nLive appended content"]]
            return try JSONSerialization.data(withJSONObject: record) + Data([10])
        }
        let finished = OSAllocatedUnfairLock(initialState: false)
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        DispatchQueue.global(qos: .utility).async {
            defer { finished.withLock { $0 = true } }
            do {
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.seekToEnd()
                for record in records {
                    try handle.write(contentsOf: record)
                    Thread.sleep(forTimeInterval: 0.2)
                }
            } catch { failure.withLock { $0 = String(describing: error) } }
        }
        switch input {
        case "wheel":
            for _ in 0..<3 { point.scroll(byDeltaX: 0, deltaY: 250) }
            XCTAssertTrue(fileLines(in: routes).contains("scroll"), "physical wheel events must enter the scroll view")
        case "keyboard":
            app.typeKey(.pageUp, modifierFlags: [])
            app.typeKey(.pageUp, modifierFlags: [])
            XCTAssertTrue(fileLines(in: routes).contains("116,true"), "Page Up must reach the transcript")
        default:
            let scroller = scroll.scrollBars["transcriptScroller"]
            XCTAssertTrue(scroller.waitForExistence(timeout: 5))
            let thumb = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            thumb.click(forDuration: 0.1, thenDragTo: thumb.withOffset(CGVector(dx: 0, dy: -120)))
        }
        app.buttons["testProbeTranscriptPosition"].click()
        let reader = try XCTUnwrap(fileLines(in: readerProbe).last?.split(separator: ","))
        let readingIndex = try XCTUnwrap(Int(reader[0]))
        let readerY = try XCTUnwrap(Double(reader[1]))
        XCTAssertLessThan(readerY, Double(scroll.frame.height), "the recorded reader anchor must be in the viewport")
        let anchorProbe = try XCTUnwrap(nativeAnchorProbe)
        try String(readingIndex).write(to: anchorProbe.input, atomically: true, encoding: .utf8)
        XCTAssertNotNil(poll(timeout: 10) { finished.withLock { $0 } ? true : nil })
        XCTAssertNil(failure.withLock { $0 })
        XCTAssertTrue(app.staticTexts["70 messages"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3.2)
        assertSavedAnchorOnScreen(index: readingIndex, in: scroll, expectedY: CGFloat(readerY), stage: "streaming idle completion")
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertTrue(waitForFile(probe, timeout: 5))
        let fields = try XCTUnwrap(fileLines(in: probe).last?.split(separator: ","))
        XCTAssertEqual(String(fields[2]), "false", "upward input must remain unpinned after stream updates and idle completion")
        XCTAssertGreaterThan(try XCTUnwrap(Double(fields[1])) - XCTUnwrap(Double(fields[0])), 50)
    }

    func testSearchReplacesDisclosureRestoreAfterMessagesEmpty() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Disclosure race", project: "DisclosureProject", directory: directory,
            count: 36, contentRepeats: 0
        )
        let file = directory.appendingPathComponent("Sources/Claude/Disclosure race.jsonl")
        let record: [String: Any] = [
            "type": "assistant", "uuid": "disclosure-race-thinking",
            "sessionId": "Disclosure race", "cwd": "/tmp/DisclosureProject",
            "timestamp": "2026-09-14T12:01:00Z",
            "message": ["content": [
                ["type": "text", "text": "Disclosure race message 36"],
                ["type": "thinking", "thinking": String(repeating: "A thought. ", count: 300)],
            ]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        try handle.close()
        let interactionStarted = directory.appendingPathComponent("interaction-started")
        let interactionRelease = directory.appendingPathComponent("interaction-release")
        let restoreAudit = directory.appendingPathComponent("disclosure-search-restores")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_INTERACTION_RESTORE_DELAY_MS"] = "8000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_INTERACTION_RESTORE_RELEASE_PATH"] = interactionRelease.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_INTERACTION_STARTED_PATH"] = interactionStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_AUDIT_PATH"] = restoreAudit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["DisclosureProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["DisclosureProject"].firstMatch.click()
        openSidebarSession("Disclosure race", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        let disclosure = scroll.buttons["Reasoning"].firstMatch
        XCTAssertTrue(disclosure.wait(for: \.isHittable, toEqual: true, timeout: 10))
        disclosure.click()
        XCTAssertTrue(waitForFile(interactionStarted), "disclosure restore must be pending")
        XCTAssertFalse(fileLines(in: restoreAudit).contains { $0.hasPrefix("36,") },
            "the delayed disclosure restore must still be pending when search begins")

        app.buttons["testOpenLauncher"].click()
        let search = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        app.typeText("Disclosure race message 4")
        let hit = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Disclosure race message 4"
        )).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10))
        hit.click()
        let target = transcriptMessage("Disclosure race", index: 4, in: scroll)
        XCTAssertTrue(target.wait(for: \.isHittable, toEqual: true, timeout: 20),
            "explicit search must replace the pending disclosure restore")
        try Data().write(to: interactionRelease)
        XCTAssertTrue(target.isHittable,
            "the cancelled disclosure restore must not replay after the message list clears")
        XCTAssertTrue(fileLines(in: restoreAudit).contains { $0.hasPrefix("4,") },
            "the search target must receive an exact-row restore")
        XCTAssertFalse(fileLines(in: restoreAudit).contains { $0.hasPrefix("36,") },
            "the old disclosure restore must never run after search")
    }

    func testDisclosureCancelsSearchIntentAcrossHideAndShow() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        installNativeAnchorProbe(app: app, directory: directory)
        let boundsAudit = directory.appendingPathComponent("disclosure-bounds")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"] = boundsAudit.path
        defer {
            let attachment = XCTAttachment(string: fileLines(in: boundsAudit).joined(separator: "\n"))
            attachment.name = "disclosure-cancellation-bounds"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] = "disclosure-position"
        try addLongSession(
            "Disclosure race", project: "DisclosureProject", directory: directory,
            count: 36, mostlySystem: true, contentRepeats: 0
        )
        let file = directory.appendingPathComponent("Sources/Claude/Disclosure race.jsonl")
        let record: [String: Any] = [
            "type": "assistant", "uuid": "disclosure-race-thinking",
            "sessionId": "Disclosure race", "cwd": "/tmp/DisclosureProject",
            "timestamp": "2026-09-14T12:01:00Z",
            "message": ["content": [
                ["type": "text", "text": "Disclosure race message 36"],
                ["type": "thinking", "thinking": String(repeating: "A thought. ", count: 300)],
            ]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        try handle.close()
        let searchStarted = directory.appendingPathComponent("search-started")
        let searchCancelled = directory.appendingPathComponent("search-cancelled")
        let searchRelease = directory.appendingPathComponent("search-release")
        let restoreAudit = directory.appendingPathComponent("cancelled-search-restores")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_RELEASE_PATH"] = searchRelease.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SEARCH_RESTORE_STARTED_PATH"] = searchStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = searchCancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_AUDIT_PATH"] = restoreAudit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["DisclosureProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["DisclosureProject"].firstMatch.click()
        openSidebarSession("Disclosure race", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        let disclosure = scroll.buttons["Reasoning"].firstMatch
        XCTAssertTrue(disclosure.wait(for: \.isHittable, toEqual: true, timeout: 10))
        try? FileManager.default.removeItem(at: searchStarted)
        try? FileManager.default.removeItem(at: searchCancelled)
        app.buttons["testOpenLauncher"].click()
        let search = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        app.typeText("Disclosure race message 4")
        let hit = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Disclosure race message 4"
        )).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10))
        hit.click()
        XCTAssertTrue(waitForFile(searchStarted, timeout: 10))
        XCTAssertNotNil(poll(timeout: 10) {
            app.buttons["testSimulateTranscriptScroll"].click()
            guard disclosure.isHittable, scroll.frame.contains(disclosure.frame) else { return nil }
            return true
        }, "the entire disclosure must be visible without cancelling search; button=\(disclosure.frame), viewport=\(scroll.frame)")
        disclosure.click()
        XCTAssertTrue(waitForFile(searchCancelled, timeout: 5))
        app.checkBoxes["System"].click()
        app.checkBoxes["System"].click()
        try Data().write(to: searchRelease)
        // Wait for the visibility restore to complete, then inspect its first
        // native result. Search index 4 must never appear in the restore audit.
        XCTAssertNotNil(savedAnchorY(index: 36, in: scroll, timeout: 10), "the disclosure/visibility restore must complete")
        let target = transcriptMessage("Disclosure race", index: 4, in: scroll)
        XCTAssertFalse(target.isHittable)
        XCTAssertFalse(fileLines(in: restoreAudit).contains { $0.hasPrefix("4,") },
            "a consumed search intent must not replay when the hit becomes visible again")
    }

    func testMissingLiveScrollEndRecoversOnIdle() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Lost scroll end", project: "ScrollProject", directory: directory)
        let idleAudit = directory.appendingPathComponent("lost-scroll-end-idle")
        let bookmarkSaved = directory.appendingPathComponent("lost-scroll-end-bookmark")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_FORCE_LIVE_SCROLL"] = "1"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_DROP_LIVE_SCROLL_END"] = "1"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ScrollProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["ScrollProject"].firstMatch.click()
        openSidebarSession("Lost scroll end", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: idleAudit)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -900)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "started", count: 1, timeout: 10))
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 10),
            "a missing end notification must not keep user-scrolling state active")
        XCTAssertNotNil(waitForBookmarkIndex(bookmarkSaved, greaterThan: 0),
            "the idle backstop must save the scrolled position")
    }

    func testExternalTranscriptScrollUnpinsAndDensityKeepsLiveViewport() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        installNativeAnchorProbe(app: app, directory: directory)
        try addLongSession("External scroll", project: "ScrollProject", directory: directory)
        let idleAudit = directory.appendingPathComponent("external-scroll-idle")
        let bookmarkSaved = directory.appendingPathComponent("external-scroll-bookmark")
        let boundsAudit = directory.appendingPathComponent("external-scroll-bounds")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] = "external-midpoint"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"] = boundsAudit.path
        defer {
            for (name, path) in [("external-bounds", boundsAudit), ("external-idle", idleAudit),
                                 ("external-bookmark", bookmarkSaved)] {
                let attachment = XCTAttachment(string: fileLines(in: path).joined(separator: "\n"))
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ScrollProject"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["ScrollProject"].firstMatch.click()
        openSidebarSession("External scroll", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(directory.appendingPathComponent("native-restore-completed"), timeout: 10))
        let initialFinishes = completedInputCycleCount(in: idleAudit)
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: initialFinishes + 1, timeout: 10))
        let bottomIndex = try XCTUnwrap(waitForStableBookmarkIndex(bookmarkSaved))
        XCTAssertGreaterThan(bottomIndex, 50, "the initial wheel must reach the end of the 70-message transcript")
        let finishes = completedInputCycleCount(in: idleAudit)

        app.buttons["testSimulateTranscriptScroll"].click()
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: finishes + 1, timeout: 10),
            "an external viewport move must be saved as reading position; "
                + "bounds: \(fileLines(in: boundsAudit).suffix(12))")
        let readingIndex = try XCTUnwrap(waitForStableBookmarkIndex(bookmarkSaved))
        XCTAssertLessThan(readingIndex, bottomIndex,
            "external scrolling must leave bottom-follow mode")
        let readingY = try XCTUnwrap(savedAnchorY(index: readingIndex, in: scroll, timeout: 10))
        app.radioButtons["Compact"].click()
        assertSavedAnchorOnScreen(index: readingIndex, in: scroll, expectedY: readingY,
            stage: "density after external scroll")
    }

    func testUpwardReaderMotionDuringDocumentGrowthUnpins() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Growing scroll", project: "ScrollProject", directory: directory)
        let idleAudit = directory.appendingPathComponent("growth-scroll-idle")
        let simulationDone = directory.appendingPathComponent("growth-scroll-done")
        let positionProbe = directory.appendingPathComponent("growth-scroll-position")
        let jumpDone = directory.appendingPathComponent("growth-scroll-jump-done")
        let boundsAudit = directory.appendingPathComponent("growth-scroll-bounds")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_JUMP_DONE_PATH"] = jumpDone.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"] = boundsAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = positionProbe.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] = "growing-up"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH"] = simulationDone.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ScrollProject"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["ScrollProject"].firstMatch.click()
        openSidebarSession("Growing scroll", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 10))
        app.buttons["testJumpTranscriptBottom"].click()
        XCTAssertTrue(waitForFile(jumpDone, timeout: 5))
        let initialPosition = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(String(initialPosition[2]), "true")
        try? FileManager.default.removeItem(at: positionProbe)
        try? FileManager.default.removeItem(at: idleAudit)
        app.buttons["testSimulateTranscriptScroll"].click()
        XCTAssertTrue(waitForFile(simulationDone, timeout: 5))
        XCTAssertTrue(fileLines(in: boundsAudit).contains("simulation-classified-bottom=false"),
            "coalesced upward motion must unpin before any later layout; \(fileLines(in: boundsAudit).suffix(8))")
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 5))
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertTrue(waitForFile(positionProbe, timeout: 5))
        let position = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(String(position[2]), "false",
            "document growth must not suppress simultaneous upward reader motion")
    }

    func testDelayedResizePreservesBottomFollow() throws { try runViewportRegression("delayed-resize") }
    func testMultiStageResizePreservesBottomFollowDuringAppend() throws { try runViewportRegression("multi-stage-resize") }
    func testNativeDocumentAdjustmentsPreserveBottomFollowDuringIdleAppend() throws { try runViewportRegression("multi-stage-document") }
    func testUserInputInvalidatesNativeDocumentAdjustment() throws { try runViewportRegression("interrupted-document") }
    func testExpiredResizeDoesNotSuppressUpwardMotion() throws { try runViewportRegression("expired-resize") }
    func testUserInputInvalidatesResizeTransaction() throws { try runViewportRegression("interrupted-resize") }
    func testUnchangedGeometryScrollingUsesCachedExtentAndLazyRows() throws { try runViewportRegression("cached-extent") }
    func testLastRowRemainsReachableBeyondDocumentFrame() throws { try runViewportRegression("row-extent") }
    func testRubberBandReturnKeepsFollowDuringAppend() throws { try runViewportRegression("rubber-band-return") }

    private func runViewportRegression(_ simulation: String) throws {
        let expectedFollowing = simulation != "expired-resize" && simulation != "interrupted-resize"
            && simulation != "interrupted-document"
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Viewport regression", project: "ViewportProject", directory: directory,
            count: simulation == "cached-extent" ? 2_000 : 70)
        let audit = directory.appendingPathComponent("viewport-audit")
        let done = directory.appendingPathComponent("viewport-done")
        let jump = directory.appendingPathComponent("viewport-jump")
        let probe = directory.appendingPathComponent("viewport-position")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] = simulation
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH"] = done.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOUNDS_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_JUMP_DONE_PATH"] = jump.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = probe.path
        if simulation == "multi-stage-document" {
            app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "1500"
        }
        defer {
            let attachment = XCTAttachment(string: fileLines(in: audit).joined(separator: "\n"))
            attachment.name = "viewport-regression-\(simulation)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ViewportProject"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["ViewportProject"].firstMatch.click()
        openSidebarSession("Viewport regression", in: app)
        app.buttons["testJumpTranscriptBottom"].click()
        XCTAssertTrue(waitForFile(jump, timeout: 10))
        app.buttons["testSimulateTranscriptScroll"].click()
        XCTAssertTrue(waitForFile(done, timeout: 5))
        if simulation == "interrupted-resize" {
            XCTAssertTrue(fileLines(in: audit).contains("resize-rearmed-after-input=false"))
        }
        if simulation == "cached-extent" {
            let line = try XCTUnwrap(fileLines(in: audit).last { $0.hasPrefix("cache=") })
            let fields = line.dropFirst(6).split(separator: ",").compactMap { Int($0) }
            XCTAssertEqual(fields.count, 8)
            guard fields.count == 8 else { return }
            XCTAssertEqual(fields[0], fields[1], "scroll-only bounds checks must not query the last row")
            XCTAssertEqual(fields[2], fields[3], "origin changes must not invalidate row geometry")
            XCTAssertLessThan(fields[4], fields[5], "the table must retain lazy row materialization")
            XCTAssertEqual(fields[6], fields[1], "invalidation must defer the extent query")
            XCTAssertEqual(fields[7], fields[6] + 1, "multiple invalidations must flush in one query")
            return
        } else if simulation == "row-extent" {
            let line = try XCTUnwrap(fileLines(in: audit).last { $0.hasPrefix("extent=") })
            let fields = line.split(separator: ",").map { $0.split(separator: "=").last! }
            XCTAssertEqual(try XCTUnwrap(Double(fields[0])), try XCTUnwrap(Double(fields[1])), accuracy: 1)
        } else {
            XCTAssertTrue(fileLines(in: audit).contains("simulation-classified-bottom=\(expectedFollowing)"))
        }
        if simulation == "rubber-band-return" || simulation == "multi-stage-resize"
            || simulation == "multi-stage-document" {
            let source = directory.appendingPathComponent("Sources/Claude/Viewport regression.jsonl")
            let record: [String: Any] = ["type": "assistant", "uuid": "viewport-append", "sessionId": "Viewport regression",
                "cwd": "/tmp/ViewportProject", "message": ["content": "Viewport regression message 70\nAppend after viewport adjustment"]]
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
            try handle.close()
            XCTAssertTrue(app.staticTexts["71 messages"].waitForExistence(timeout: 15))
            XCTAssertTrue(transcriptMessage("Viewport regression", index: 70, in: app.scrollViews["transcriptScroll"])
                .wait(for: \.isHittable, toEqual: true, timeout: 15))
            if simulation == "rubber-band-return" {
                XCTAssertTrue(fileLines(in: audit).contains("post-append-native-motion"))
            }
        }
        try? FileManager.default.removeItem(at: probe)
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertTrue(waitForFile(probe, timeout: 5))
        let fields = try XCTUnwrap(fileLines(in: probe).last?.split(separator: ","))
        XCTAssertEqual(String(fields[2]), String(expectedFollowing))
        if expectedFollowing {
            XCTAssertEqual(try XCTUnwrap(Double(fields[0])), try XCTUnwrap(Double(fields[1])), accuracy: 2)
        } else {
            XCTAssertGreaterThan(try XCTUnwrap(Double(fields[1])) - XCTUnwrap(Double(fields[0])), 2)
        }
    }

    func testUpArrowInSelectableTextCancelsGatedRestore() throws { try runArrowRestoreCancellation(.upArrow) }
    func testDownArrowInSelectableTextCancelsGatedRestore() throws { try runArrowRestoreCancellation(.downArrow) }

    private func runArrowRestoreCancellation(_ key: XCUIKeyboardKey) throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Arrow restore", project: "ArrowProject", directory: directory)
        let started = directory.appendingPathComponent("arrow-started")
        let cancelled = directory.appendingPathComponent("arrow-cancelled")
        let release = directory.appendingPathComponent("arrow-release")
        let routes = directory.appendingPathComponent("arrow-routes")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_RELEASE_PATH"] = release.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = started.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = cancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] = "focus-text"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_KEY_ROUTE_PATH"] = routes.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ArrowProject"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["ArrowProject"].firstMatch.click()
        openSidebarSession("Arrow restore", in: app)
        XCTAssertTrue(waitForFile(started, timeout: 10))
        app.buttons["testSimulateTranscriptScroll"].click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path), "focus setup must preserve the gate")
        app.typeKey(key, modifierFlags: [])
        XCTAssertTrue(waitForFile(cancelled, timeout: 5), "native text scrolling must cancel the restore before moving")
        XCTAssertTrue(fileLines(in: routes).contains(key == .upArrow ? "126,true" : "125,true"))
        try Data().write(to: release)
    }

    func testSlowViewportMotionKeepsLiveScrollActiveUntilMotionStops() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Slow scroll", project: "ScrollProject", directory: directory)
        let idleAudit = directory.appendingPathComponent("slow-scroll-idle")
        let offsets = directory.appendingPathComponent("slow-scroll-offsets")
        let simulationDone = directory.appendingPathComponent("slow-scroll-done")
        let positionProbe = directory.appendingPathComponent("slow-scroll-position")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = positionProbe.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION"] = "slow-up"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_OFFSET_PATH"] = offsets.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SIMULATION_DONE_PATH"] = simulationDone.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["ScrollProject"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["ScrollProject"].firstMatch.click()
        openSidebarSession("Slow scroll", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 10))
        try? FileManager.default.removeItem(at: idleAudit)

        app.buttons["testSimulateTranscriptScroll"].click()
        XCTAssertTrue(waitForFile(simulationDone, timeout: 5))
        XCTAssertFalse(fileLines(in: idleAudit).contains("finished"),
            "the live-scroll backstop must wait for the last viewport motion")
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 5))
        app.buttons["testProbeTranscriptPosition"].click()
        let position = try XCTUnwrap(fileLines(in: positionProbe).last?.split(separator: ","))
        XCTAssertEqual(String(position[2]), "false", "fractional upward motion must unpin")
        XCTAssertGreaterThan(try XCTUnwrap(Double(position[1])) - XCTUnwrap(Double(position[0])), 3,
            "fractional upward motion must leave the reader above the current bottom")
    }

    func testRevealingTrailingRowsKeepsTheVisibilityAnchor() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let bottomAudit = directory.appendingPathComponent("visibility-bottom-applied")
        let restoreAudit = directory.appendingPathComponent("visibility-restores")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOTTOM_AUDIT_PATH"] = bottomAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_AUDIT_PATH"] = restoreAudit.path
        let file = directory.appendingPathComponent("Sources/Claude/Trailing visibility.jsonl")
        var records: [[String: Any]] = [["type": "custom-title", "customTitle": "Trailing visibility"]]
        for index in 0..<24 {
            records.append([
                "type": index < 2 ? "user" : "system",
                "uuid": "trailing-\(index)", "sessionId": "Trailing visibility",
                "cwd": "/tmp/TrailingProject", "timestamp": "2026-09-14T12:00:00Z",
                "message": ["content": "Trailing visibility message \(index)"],
            ])
        }
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["TrailingProject"].firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["TrailingProject"].firstMatch.click()
        openSidebarSession("Trailing visibility", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let first = transcriptMessage("Trailing visibility", index: 0, in: scroll)
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10))
        let system = app.checkBoxes["System"]
        system.click()
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10))
        let anchorY = first.frame.minY
        system.click()
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "revealing trailing rows must keep the first row visible; bottom \(fileLines(in: bottomAudit).suffix(5)); restores \(fileLines(in: restoreAudit).suffix(5))")
        XCTAssertEqual(first.frame.minY, anchorY, accuracy: 45)
    }

    func testSessionNavigationScrollRestorationAndRestart() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        installNativeAnchorProbe(app: app, directory: directory)
        func sidebarSession(named title: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(identifier: "sessionSidebarList").firstMatch
                .cells.containing(.staticText, identifier: title).firstMatch
        }
        try addLongSession("Alpha session", project: "ProjectAlpha", directory: directory)
        try addLongSession("Beta session", project: "ProjectBeta", directory: directory)
        let bookmarkSaved = directory.appendingPathComponent("navigation-bookmark-saved")
        let idleAudit = directory.appendingPathComponent("navigation-scroll-idle-audit")
        let restoreAudit = directory.appendingPathComponent("navigation-restore-audit")
        let rowAudit = directory.appendingPathComponent("navigation-row-audit")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_AUDIT_PATH"] = restoreAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_ROW_LAYOUT_AUDIT_PATH"] = rowAudit.path
        defer {
            let attachment = XCTAttachment(string: fileLines(in: restoreAudit).joined(separator: "\n"))
            attachment.name = "navigation-native-restores"
            attachment.lifetime = .keepAlways
            add(attachment)
            for name in ["native-anchor-offset", "native-anchor-samples", "navigation-row-audit"] {
                let data = XCTAttachment(string: fileLines(in: directory.appendingPathComponent(name)).joined(separator: "\n"))
                data.name = name
                data.lifetime = .keepAlways
                add(data)
            }
        }
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let alphaProject = app.staticTexts["ProjectAlpha"].firstMatch
        XCTAssertTrue(alphaProject.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["All Projects"].exists)
        alphaProject.click()
        let alpha = sidebarSession(named: "Alpha session")
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        app.radioButtons["Costs"].click()
        let alphaAfterSectionChange = sidebarSession(named: "Alpha session")
        XCTAssertTrue(alphaAfterSectionChange.wait(for: \.isHittable, toEqual: true, timeout: 10))
        openSidebarSession("Alpha session", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["mainSearch"].exists)
        XCTAssertFalse(app.radioButtons["Costs"].exists)
        XCTAssertTrue(app.windows["Alpha session"].exists)
        let first = transcriptMessage("Alpha session", index: 0, in: scroll)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        try? FileManager.default.removeItem(at: idleAudit)
        scroll.scroll(byDeltaX: 0, deltaY: -950)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 10),
                      "the transcript scroll must finish before its bookmark is inspected")
        let bookmarkIndex = try XCTUnwrap(waitForStableBookmarkIndex(bookmarkSaved))
        XCTAssertGreaterThan(bookmarkIndex, 0)
        let anchorY = try XCTUnwrap(savedAnchorY(index: bookmarkIndex, in: scroll, timeout: 10))
        assertSavedAnchorOnScreen(index: bookmarkIndex, in: scroll, expectedY: anchorY,
                                  stage: "before density change")
        let compactRestoreStart = fileLines(in: restoreAudit).count
        app.radioButtons["Compact"].click()
        XCTAssertNotNil(poll(timeout: 10) {
            let lines = fileLines(in: restoreAudit)
            guard lines.count > compactRestoreStart,
                  let fields = lines.last?.split(separator: ",").compactMap({ Double($0) }),
                  fields.count == 5,
                  abs(fields[1] - fields[2]) <= 1 else { return nil }
            return fields
        }, "density change must restore the visible row offset")
        assertSavedAnchorOnScreen(index: bookmarkIndex, in: scroll, expectedY: anchorY,
                                  stage: "compact density")
        let comfortableRestoreStart = fileLines(in: restoreAudit).count
        app.radioButtons["Comfortable"].click()
        XCTAssertNotNil(poll(timeout: 10) {
            let lines = fileLines(in: restoreAudit)
            guard lines.count > comfortableRestoreStart,
                  let fields = lines.last?.split(separator: ",").compactMap({ Double($0) }),
                  fields.count == 5,
                  abs(fields[1] - fields[2]) <= 1 else { return nil }
            return fields
        }, "returning to comfortable density must restore the visible row offset")
        assertSavedAnchorOnScreen(index: bookmarkIndex, in: scroll, expectedY: anchorY,
                                  stage: "comfortable density")
        app.staticTexts["ProjectBeta"].firstMatch.click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        XCTAssertFalse(scroll.exists)
        XCTAssertTrue(app.windows["ProjectBeta"].exists)
        let beta = sidebarSession(named: "Beta session")
        XCTAssertTrue(beta.wait(for: \.isHittable, toEqual: true, timeout: 10))
        openSidebarSession("Beta session", in: app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let betaFirst = transcriptMessage("Beta session", index: 0, in: scroll)
        XCTAssertTrue(betaFirst.waitForExistence(timeout: 10))
        XCTAssertTrue(betaFirst.isHittable)
        app.staticTexts["ProjectAlpha"].firstMatch.click()
        let returningAlpha = sidebarSession(named: "Alpha session")
        XCTAssertTrue(returningAlpha.wait(for: \.isHittable, toEqual: true, timeout: 10))
        let restoreCountBeforeReturn = fileLines(in: restoreAudit).count
        openSidebarSession("Alpha session", in: app)
        let restoredScroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(restoredScroll.waitForExistence(timeout: 10))
        assertSavedAnchorOnScreen(index: bookmarkIndex, in: restoredScroll, expectedY: anchorY,
                                  stage: "navigation restore")
        for _ in 0..<5 {
            let measurement = try XCTUnwrap(poll(timeout: 10) { () -> [String]? in
                let lines = fileLines(in: restoreAudit)
                guard lines.count > restoreCountBeforeReturn,
                  let fields = lines.last?.split(separator: ",").map(String.init),
                  fields.count == 5,
                  let row = Int(fields[0]),
                  row == bookmarkIndex else { return nil }
                return fields
            }, "navigation restore near row \(bookmarkIndex): \(fileLines(in: restoreAudit).suffix(12))")
            XCTAssertEqual(try XCTUnwrap(Double(measurement[1])),
                           try XCTUnwrap(Double(measurement[2])), accuracy: 1,
                           "restoration retries must retain the saved table-row offset")
            assertSavedAnchorOnScreen(index: bookmarkIndex, in: restoredScroll, expectedY: anchorY,
                                      stage: "restoration retry")
            Thread.sleep(forTimeInterval: 0.08)
        }
        app.buttons["backToProject"].click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        try addLongSession("Background update", project: "BackgroundProject", directory: directory, count: 1)
        XCTAssertTrue(app.staticTexts["BackgroundProject"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(scroll.exists, "an index refresh must not reopen the last session")
        let alphaAfterRefresh = sidebarSession(named: "Alpha session")
        XCTAssertTrue(alphaAfterRefresh.wait(for: \.isHittable, toEqual: true, timeout: 10))
        openSidebarSession("Alpha session", in: app)
        app.terminate()
        app.launch()
        let relaunchedScroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(relaunchedScroll.waitForExistence(timeout: 15))
        let relaunchedFirst = transcriptMessage("Alpha session", index: 0, in: relaunchedScroll)
        XCTAssertTrue(relaunchedFirst.waitForExistence(timeout: 10))
        XCTAssertTrue(relaunchedFirst.isHittable, "scroll bookmarks must not survive process restart")
        app.buttons["backToProject"].click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alpha session"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Beta session"].firstMatch.exists,
                       "restart restoration must reload the restored project's sessions")
        attach(app, name: "session-navigation")
    }

    func testPageDownContinuouslyUpdatesTranscriptBookmark() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Keyboard scroll", project: "KeyboardProject", directory: directory)
        let bookmarkSaved = directory.appendingPathComponent("keyboard-bookmark-saved")
        let idleAudit = directory.appendingPathComponent("keyboard-scroll-idle-audit")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        defer {
            let attachment = XCTAttachment(string: fileLines(in: idleAudit).joined(separator: "\n"))
            attachment.name = "keyboard-input-cycles"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["KeyboardProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let session = app.staticTexts["Keyboard scroll"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        openSidebarSession("Keyboard scroll", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        focusTranscript("Keyboard scroll", in: scroll)
        let firstFinishBaseline = completedInputCycleCount(in: idleAudit)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.activate()
        app.typeKey(.pageDown, modifierFlags: [])
        let firstBookmarkIndex = try XCTUnwrap(waitForBookmarkIndex(bookmarkSaved, greaterThan: 0))
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: firstFinishBaseline + 1, timeout: 10))
        let visibleAfterFirstPage = transcriptMessage(
            "Keyboard scroll", index: firstBookmarkIndex, in: scroll
        )
        XCTAssertTrue(visibleAfterFirstPage.wait(for: \.isHittable, toEqual: true, timeout: 10))
        visibleAfterFirstPage.click()
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.activate()
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertNotNil(waitForBookmarkIndex(bookmarkSaved, greaterThan: firstBookmarkIndex))
        let finishesBeforeWheel = completedInputCycleCount(in: idleAudit)
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: finishesBeforeWheel + 1, timeout: 10
        ), "the preceding wheel scroll must be fully idle before testing the boundary")
        let visibleMessage = transcriptMessage("Keyboard scroll", index: 69, in: scroll)
        XCTAssertTrue(visibleMessage.wait(for: \.isHittable, toEqual: true, timeout: 10))
        let pasteboardChangeCount = preparePasteboardForCopy()
        visibleMessage.click()
        app.activate()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        assertPasteboardChanged(
            after: pasteboardChangeCount, contains: ["Keyboard scroll message"],
            message: "the boundary case must run with selectable message text as first responder"
        )
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: completedInputCycleCount(in: idleAudit), timeout: 10))
        let boundaryStarts = fileLines(in: idleAudit).filter { $0.hasPrefix("started,") }.count
        let boundaryFinishes = completedInputCycleCount(in: idleAudit)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.activate()
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertTrue(waitForLineCount(idleAudit, line: "started", count: boundaryStarts + 1, timeout: 3),
                      "a boundary Page Down must schedule idle completion directly")
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: boundaryFinishes + 1, timeout: 3),
                      "a boundary Page Down must clear user scrolling without geometry changes")
        XCTAssertTrue(waitForFile(bookmarkSaved, timeout: 3),
                      "a boundary Page Down must still finish user scrolling and save its bookmark")
    }

    func testClosingWindowDuringScrollIdleDelayStillOpensSearchResult() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Window lifecycle", project: "WindowLifecycleProject", directory: directory
        )
        let idleAudit = directory.appendingPathComponent("window-scroll-idle-audit")
        let keyRoute = directory.appendingPathComponent("window-key-route")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_KEY_ROUTE_PATH"] = keyRoute.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["WindowLifecycleProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let session = app.staticTexts["Window lifecycle"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        openSidebarSession("Window lifecycle", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        app.activate()
        focusTranscript("Window lifecycle", in: scroll)
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 8),
                      "the focusing click must finish before Page Down starts a new scroll")
        try? FileManager.default.removeItem(at: idleAudit)
        app.activate()
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertTrue(fileLines(in: keyRoute).contains { $0 == "121,true" },
            "Page Down must reach the transcript's keyboard route")
        XCTAssertTrue(waitForLineCount(idleAudit, line: "started", count: 1, timeout: 3),
                      "the scroll-idle delay must be pending before the window closes; keys: \(fileLines(in: keyRoute))")

        let mainWindow = app.windows["Window lifecycle"]
        XCTAssertTrue(mainWindow.exists)
        app.activate()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 5))

        ensurePopoverOpen(app)
        let popoverSearch = app.textFields["Search all sessions"]
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 10))
        popoverSearch.click()
        popoverSearch.typeText("Window lifecycle message 60")
        popoverSearch.typeKey(.return, modifierFlags: [])
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Window lifecycle message 60"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()

        let target = transcriptMessage("Window lifecycle", index: 60, in: scroll)
        XCTAssertTrue(target.wait(for: \.isHittable, toEqual: true, timeout: 20))
    }

    func testUserScrollDuringTranscriptRestorationCancelsBookmarkRetry() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Alpha session", project: "ProjectAlpha", directory: directory)
        let restorationStarted = directory.appendingPathComponent("restoration-started")
        let restorationCancelled = directory.appendingPathComponent("restoration-cancelled")
        let restorationRelease = directory.appendingPathComponent("restoration-release")
        let bookmarkSaved = directory.appendingPathComponent("bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_RELEASE_PATH"] = restorationRelease.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "15000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = restorationStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = restorationCancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["ProjectAlpha"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let sessionList = app.descendants(matching: .any)
            .matching(identifier: "sessionSidebarList").firstMatch
        let alpha = sessionList.cells.containing(
            .staticText, identifier: "Alpha session"
        ).firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        openSidebarSession("Alpha session", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -1000)
        let savedBookmarkIndex = try XCTUnwrap(
            waitForBookmarkIndex(bookmarkSaved, greaterThan: 0),
            "the scrolled bookmark must be saved"
        )
        XCTAssertGreaterThan(savedBookmarkIndex, 0)
        app.buttons["backToProject"].click()
        try? FileManager.default.removeItem(at: restorationStarted)
        try? FileManager.default.removeItem(at: restorationCancelled)
        let returningAlpha = sessionList.cells.containing(
            .staticText, identifier: "Alpha session"
        ).firstMatch
        XCTAssertTrue(returningAlpha.wait(for: \.isHittable, toEqual: true, timeout: 10))
        openSidebarSession("Alpha session", in: app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(restorationStarted), "bookmark restoration must be pending")
        try? FileManager.default.removeItem(at: bookmarkSaved)
        let transcriptScroller = scroll.scrollBars["transcriptScroller"]
        XCTAssertTrue(transcriptScroller.waitForExistence(timeout: 5))
        app.activate()
        scroll.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertTrue(waitForFile(restorationCancelled),
                      "user scrolling must cancel the pending bookmark")
        XCTAssertTrue(waitForFile(bookmarkSaved), "the cancelling user scroll must save its position")
        let firstScrollerIndex = try XCTUnwrap(bookmarkIndex(in: bookmarkSaved))
        app.activate()
        scroll.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertNotNil(waitForBookmarkIndex(bookmarkSaved, greaterThan: firstScrollerIndex),
                        "continued scrollbar movement must keep updating the bookmark")
        try? FileManager.default.removeItem(at: restorationStarted)
        app.activate()
        app.buttons["testOpenLauncher"].click()
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        app.activate()
        launcherSearch.click()
        launcherSearch.typeText("Alpha session message 60")
        let requested = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Alpha session message 60"
        )).firstMatch
        XCTAssertTrue(requested.waitForExistence(timeout: 20))
        requested.click()
        XCTAssertTrue(waitForFile(restorationStarted),
                      "an explicit search navigation must start immediately")
        let targetPredicate = NSPredicate(
            format: "value BEGINSWITH %@", "Alpha session message 60"
        )
        let targetVisible = NSPredicate { _, _ in
            scroll.staticTexts.matching(targetPredicate).allElementsBoundByIndex.contains {
                $0.isHittable
            }
        }
        expectation(for: targetVisible, evaluatedWith: nil)
        waitForExpectations(timeout: 30)
    }

    func testVisibilityChangeDuringUserScrollDoesNotReplayOldRestore() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Forced restore", project: "ForcedProject", directory: directory,
            mostlySystem: true
        )
        let restorationStarted = directory.appendingPathComponent("forced-restoration-started")
        let restorationCancelled = directory.appendingPathComponent("forced-restoration-cancelled")
        let bookmarkSaved = directory.appendingPathComponent("forced-bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_RELEASE_PATH"] =
            directory.appendingPathComponent("forced-restoration-release").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = restorationStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = restorationCancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["ForcedProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let session = app.staticTexts["Forced restore"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        openSidebarSession("Forced restore", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -1000)
        XCTAssertTrue(waitForFile(bookmarkSaved), "the system-row bookmark must be saved")
        app.buttons["backToProject"].click()
        try? FileManager.default.removeItem(at: restorationStarted)
        try? FileManager.default.removeItem(at: restorationCancelled)
        openSidebarSession("Forced restore", in: app)
        XCTAssertTrue(waitForFile(restorationStarted), "bookmark restoration must be pending")
        scroll.scroll(byDeltaX: 0, deltaY: -350)
        XCTAssertTrue(waitForFile(restorationCancelled), "real scrolling must cancel restoration")
        try? FileManager.default.removeItem(at: restorationStarted)
        app.checkBoxes["System"].click()
        XCTAssertFalse(waitForFile(restorationStarted, timeout: 5),
                       "a cancelled restore must not replay after scrolling becomes idle")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    }

    func testForcedVisibilityRestoreIgnoresHiddenSearchTarget() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Saved restore", project: "SavedRestoreProject", directory: directory,
            mostlySystem: true
        )
        let bookmarkSaved = directory.appendingPathComponent("saved-restore-bookmark")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["SavedRestoreProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let session = app.staticTexts["Saved restore"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        openSidebarSession("Saved restore", in: app)
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let first = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Saved restore message 0"
        )).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -40)
        XCTAssertTrue(waitForFile(bookmarkSaved))
        app.checkBoxes["System"].click()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)

        app.buttons["testOpenLauncher"].click()
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        launcherSearch.click()
        launcherSearch.typeText("Saved restore message 60")
        let result = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Saved restore message 60"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable,
                      "the hidden search target must not replace the saved bookmark")

        app.checkBoxes["System"].click()
        let target = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Saved restore message 60"
        )).firstMatch
        for _ in 0..<5 {
            XCTAssertTrue(first.isHittable,
                          "forced visibility restoration must keep the saved position")
            XCTAssertTrue(!target.exists || !target.isHittable,
                           "forced restoration must not jump to an unconsumed old search target")
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func testCopyMessageIncludesCollapsedContentAndDividerPersists() throws {
        let (app, _) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let session = app.staticTexts["Find the sample answer"].firstMatch
        let foundSession = session.waitForExistence(timeout: 20)
        XCTAssertTrue(foundSession)
        session.click()
        let answer = app.staticTexts["Here is the visible answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.rightClick()
        XCTAssertTrue(app.menuItems["Copy Message"].waitForExistence(timeout: 5))
        let pasteboardChangeCount = preparePasteboardForCopy()
        app.menuItems["Copy Message"].click()
        assertPasteboardChanged(
            after: pasteboardChangeCount,
            contains: ["Here is the visible answer", "Reasoning explanation", "UniqueInvocation"],
            message: "Copy Message must replace the sentinel with the complete message"
        )
        let divider = app.descendants(matching: .any)["projectSessionDivider"].firstMatch
        XCTAssertTrue(divider.exists)
        let dividerFrame = divider.frame
        let oldY = dividerFrame.midY
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        // Keep both mouse coordinates anchored to the window as the divider moves.
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: dividerFrame.midX - windowFrame.minX,
            dy: dividerFrame.midY - windowFrame.minY
        ))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)))
        let newY = divider.frame.midY
        XCTAssertGreaterThan(newY, oldY + 40)
        app.terminate()
        app.launch()
        XCTAssertTrue(divider.waitForExistence(timeout: 10))
        XCTAssertEqual(divider.frame.midY, newY, accuracy: 10)
    }

    func testSearchJumpsToMatchAndPlanBadge() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Search session", project: "SearchProject", directory: directory, count: 300)
        let file = directory.appendingPathComponent("Sources/Claude/Search session.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let plan: [String: Any] = ["type": "assistant", "uuid": "plan", "sessionId": "Search session",
            "cwd": "/tmp/SearchProject", "timestamp": "2026-09-14T12:01:00Z",
            "message": ["content": "<proposed_plan>UniquePlanNeedle. Build the requested feature.</proposed_plan>"]]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: plan))
        try handle.write(contentsOf: Data([10]))
        let target: [String: Any] = ["type": "assistant", "uuid": "search-target", "sessionId": "Search session",
            "cwd": "/tmp/SearchProject", "timestamp": "2026-09-14T12:01:01Z",
            "message": ["content": "UniqueSearchNeedle. This message must be visible after the jump."]]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: target))
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["SearchProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20))
        project.click()
        let search = app.textFields["mainSearch"]
        search.click()
        search.typeText("UniqueSearchNeedle")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "UniqueSearchNeedle")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Generated plan").firstMatch.exists)
        result.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let matches = scroll.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "UniqueSearchNeedle"
        ))
        XCTAssertNotNil(firstHittable(in: matches, timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: 100_000)
        XCTAssertNotNil(waitForTranscriptAnchor(
            "Search session", index: 0, in: scroll
        ))
        app.radioButtons["Compact"].click()
        XCTAssertNotNil(waitForTranscriptAnchor(
            "Search session", index: 0, in: scroll
        ))

        app.buttons["testOpenLauncher"].click()
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        launcherSearch.click()
        launcherSearch.typeText("UniqueSearchNeedle")
        let launcherHit = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "UniqueSearchNeedle"
        )).firstMatch
        XCTAssertTrue(launcherHit.waitForExistence(timeout: 10))
        launcherHit.click()
        XCTAssertNotNil(
            firstHittable(in: matches, timeout: 10),
            "opening a hit in the already scrolled session must jump to it"
        )
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let target = name == "popover" ? app.descendants(matching: .popover).firstMatch : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.exists ? target.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func preparePasteboardForCopy() -> Int {
        let pasteboard = NSPasteboard.general
        let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type.rawValue] = data }
            }
            return values
        }
        addTeardownBlock {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let items = originalItems.map { values in
                let item = NSPasteboardItem()
                for (rawType, data) in values {
                    item.setData(data, forType: .init(rawType))
                }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        pasteboard.clearContents()
        pasteboard.setString("Trace pasteboard sentinel \(UUID())", forType: .string)
        return pasteboard.changeCount
    }

    private func assertPasteboardChanged(
        after changeCount: Int, contains expected: [String], timeout: TimeInterval = 5,
        message: String
    ) {
        let copied = NSPredicate { _, _ in
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != changeCount,
                  let text = pasteboard.string(forType: .string) else { return false }
            return expected.allSatisfy(text.contains)
        }
        expectation(for: copied, evaluatedWith: nil)
        waitForExpectations(timeout: timeout)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(expected.allSatisfy(text.contains), message)
    }

    private func sqliteInteger(_ database: URL, sql: String) throws -> Int64 {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TraceUITests.SQLite", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "sqlite3 query failed: \(sql)"]
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int64(value), "Expected integer sqlite3 output for: \(sql)")
    }

}

extension TraceUITests {
    func testSessionPageRejectsCompletionAfterProjectSwitchAndRefreshesLoadedPages() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        var data = Data()
        for index in 0..<230 {
            let record: [String: Any] = ["type": "user", "uuid": "race-\(index)", "sessionId": "race-\(index)",
                "cwd": "/tmp/RaceProject", "timestamp": 1_700_000_000_000 + index,
                "message": ["content": "Race session \(index)"]]
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        try data.write(to: directory.appendingPathComponent("Sources/Claude/race.jsonl"))
        let started = directory.appendingPathComponent("page-started")
        let finished = directory.appendingPathComponent("page-finished")
        app.launchEnvironment["TRACE_TEST_SESSION_PAGE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_SESSION_PAGE_STARTED_PATH"] = started.path
        app.launchEnvironment["TRACE_TEST_SESSION_PAGE_FINISHED_PATH"] = finished.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        let project = app.staticTexts["RaceProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.click()
        let list = app.descendants(matching: .any)["sessionSidebarList"].firstMatch
        list.scroll(byDeltaX: 0, deltaY: -60_000)
        let more = app.buttons["loadMoreSessions"]
        XCTAssertTrue(more.wait(for: \.isHittable, toEqual: true, timeout: 10)); more.click()
        XCTAssertTrue(waitForFile(started, timeout: 10))
        app.staticTexts["TraceUIExample"].firstMatch.click()
        XCTAssertTrue(waitForFile(finished, timeout: 10))
        XCTAssertEqual(app.staticTexts["sessionTotalCount"].value as? String, "1")
        XCTAssertFalse(more.exists)
        project.click()
        list.scroll(byDeltaX: 0, deltaY: -60_000)
        XCTAssertTrue(more.wait(for: \.isHittable, toEqual: true, timeout: 10)); more.click()
        let oldestID = try sqliteInteger(directory.appendingPathComponent("index.sqlite"), sql: "SELECT id FROM session WHERE external_id='race-0';")
        XCTAssertTrue(app.descendants(matching: .any)["sessionSidebarRow-\(oldestID)"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(more.exists)
        try addSession(id: "new-race", title: "Newest race session", project: "RaceProject",
                       timestamp: 1_800_000_000_000, content: "New race content", directory: directory)
        let count = app.staticTexts["sessionTotalCount"]
        expectation(for: NSPredicate { _, _ in count.value as? String == "231" }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.descendants(matching: .any)["sessionSidebarRow-\(oldestID)"].firstMatch.exists,
                      "live updates must refresh both previously loaded pages")
        XCTAssertFalse(more.exists)
    }

    func testMainSearchReturnDefersLiveReplacementAndRebuildKeepsCriteria() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 20)); query.click(); query.typeText("Find")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Find the sample answer")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.click()
        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
        try addSession(id: "return-new", title: "Find retained new result", project: "OtherReturnProject",
                       timestamp: 1_800_000_000_000, content: "Find newest result", directory: directory)
        XCTAssertTrue(app.staticTexts["OtherReturnProject"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["backToProject"].click()
        XCTAssertEqual(query.value as? String, "Find")
        let newest = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Find newest result")).firstMatch
        XCTAssertFalse(newest.exists, "return must retain the original result set until explicit refresh")
        let refresh = app.buttons["refreshSearchResults"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10)); refresh.click()
        XCTAssertTrue(newest.waitForExistence(timeout: 10)); newest.click()
        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Trace Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.descendants(matching: .any)["Sources"].firstMatch.click()
        settings.buttons["Rebuild Index…"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        XCTAssertEqual(query.value as? String, "Find")
        XCTAssertEqual(query.placeholderValue, "Search all sessions")
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(newest.waitForExistence(timeout: 15))
    }

    func testDeletedOpenResultReturnsToRetainedMainSearch() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 20)); query.click(); query.typeText("Find")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Find the sample answer")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.click()
        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Sources/Claude/session.jsonl"))
        XCTAssertTrue(query.waitForExistence(timeout: 15))
        XCTAssertEqual(query.value as? String, "Find")
        XCTAssertEqual(query.placeholderValue, "Search all sessions")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let refresh = app.buttons["refreshSearchResults"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10)); refresh.click()
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10))
    }

    func testMainSearchBackRetainsPagesScopeAndScrollPosition() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("ReturnNeedle", project: "ReturnProject", directory: directory, count: 220, contentRepeats: 1)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let query = app.textFields["mainSearch"]
        XCTAssertTrue(query.waitForExistence(timeout: 20))
        query.click(); query.typeText("ReturnNeedle")
        let scroll = app.scrollViews["searchResultsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        let oldest = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "ReturnNeedle message 0")).firstMatch
        for _ in 0..<4 {
            if oldest.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        }
        XCTAssertTrue(oldest.wait(for: \.isHittable, toEqual: true, timeout: 15))
        let y = oldest.frame.minY
        oldest.click()
        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["backToProject"].label, "Back to results")
        app.buttons["backToProject"].click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertEqual(query.value as? String, "ReturnNeedle")
        XCTAssertTrue(oldest.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertEqual(oldest.frame.minY, y, accuracy: 24)
        XCTAssertEqual(query.placeholderValue, "Search all sessions", "Back must restore the original all-project scope")
    }

    func testSessionSidebarPagesBeyondFiveHundredAndUsesTrueTotal() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/session.jsonl")
        var data = Data()
        for index in 0..<605 {
            data.append(try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "paged-m-\(index)",
                "sessionId": "paged-\(index)", "cwd": "/tmp/PagingProject", "timestamp": 1_700_000_000_000 + index / 3,
                "message": ["content": "Paged session \(index)"]]))
            data.append(10)
        }
        try data.write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["PagingProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.click()
        let count = app.staticTexts["sessionTotalCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(count.value as? String, "605")
        let list = app.descendants(matching: .any)["sessionSidebarList"].firstMatch
        for page in 1...3 {
            list.scroll(byDeltaX: 0, deltaY: -60_000)
            let more = app.buttons["loadMoreSessions"]
            XCTAssertTrue(more.wait(for: \.isHittable, toEqual: true, timeout: 10)); more.click()
            let index = max(0, 605 - (page + 1) * 200)
            let id = try sqliteInteger(directory.appendingPathComponent("index.sqlite"), sql: "SELECT id FROM session WHERE external_id='paged-\(index)';")
            XCTAssertTrue(app.descendants(matching: .any)["sessionSidebarRow-\(id)"].firstMatch.waitForExistence(timeout: 10))
        }
        XCTAssertFalse(app.buttons["loadMoreSessions"].exists)
        list.scroll(byDeltaX: 0, deltaY: -60_000)
        let oldest = app.staticTexts["Paged session 0"].firstMatch
        XCTAssertTrue(oldest.wait(for: \.isHittable, toEqual: true, timeout: 10)); oldest.click()
        XCTAssertTrue(app.scrollViews["transcriptScroll"].waitForExistence(timeout: 10))
    }

    func testHydrationFailureIsInlineDoesNotAutomaticallyRetryAndRecovers() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let audit = directory.appendingPathComponent("hydration-requests")
        app.launchEnvironment["TRACE_TEST_FAIL_HYDRATION_ONCE"] = "1"
        app.launchEnvironment["TRACE_TEST_HYDRATION_REQUESTS_PATH"] = audit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        let session = app.staticTexts["Find the sample answer"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 20)); session.click()
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "retryMessage-")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let id = String(retry.identifier.dropFirst("retryMessage-".count))
        func requests() -> Int {
            ((try? String(contentsOf: audit, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == id }.count
        }
        XCTAssertEqual(requests(), 1)
        let tools = app.checkBoxes["Tools"]
        tools.click(); tools.click()
        XCTAssertTrue(retry.isHittable)
        XCTAssertEqual(requests(), 1, "row recreation must not automatically retry a failed read")
        retry.click()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 10))
        XCTAssertEqual(requests(), 2)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testMarkdownPreservesParagraphWhitespaceAndNativeCopy() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let content = "First paragraph.\n\nSecond paragraph.\n\n- First item\n- Second item\n\n```swift\nlet value = 1\n```"
        let object: [String: Any] = ["type": "user", "uuid": "markdown", "sessionId": "markdown", "cwd": "/tmp/MarkdownProject",
            "timestamp": 1_700_000_000_000, "message": ["content": content]]
        try (JSONSerialization.data(withJSONObject: object) + Data([10])).write(to: directory.appendingPathComponent("Sources/Claude/session.jsonl"))
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        let project = app.staticTexts["MarkdownProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.click()
        let id = try sqliteInteger(directory.appendingPathComponent("index.sqlite"), sql: "SELECT id FROM session WHERE external_id='markdown';")
        let session = app.descendants(matching: .any)["sessionSidebarRow-\(id)"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10)); session.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let text = scroll.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "First paragraph.\n\nSecond paragraph.")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String)?.contains("```swift\nlet value = 1\n```") == true,
                      "fenced code must keep its syntax and line breaks visible")
        text.click()
        let nativeChange = preparePasteboardForCopy()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        assertPasteboardChanged(after: nativeChange, contains: [content], message: "native selection and copy must preserve whitespace")
        let change = preparePasteboardForCopy()
        text.rightClick(); app.menuItems["Copy Message"].click()
        assertPasteboardChanged(after: change, contains: [content], message: "native message copy must preserve whitespace")
    }

    func testCaptureReadmeShowcaseWithoutTestControls() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        app.launchEnvironment["TRACE_TEST_SHOWCASE"] = "1"
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Sources/Claude/session.jsonl"))
        func writeSession(_ title: String, project: String, agent: String, number: Int) throws {
            let lines = [title,
                "Keep the app focused on the work in front of you.\n\nUse clear labels and make every state easy to understand.",
                "Add a compact dashboard with activation, retention, and weekly active teams.",
                "Add a seven-day funnel with accessible colors and direct labels.\n\nLoad each section independently so the dashboard stays responsive.\n\nShow clear empty, loading, error, and complete states.",
                "Make keyboard navigation and reduced motion part of the definition of done.",
                "Include focus order, VoiceOver labels, contrast checks, and a no-animation path in the acceptance criteria.",
                "Use a disposable cache so source transcripts stay untouched.",
                "Cache only the local search index. Rebuild it safely when the source format changes."]
            let root = directory.appendingPathComponent("Sources/\(agent)")
            let parent = agent == "Gemini" ? root.appendingPathComponent("\(project)/chats") : root
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var records: [[String: Any]] = []
            if agent == "Codex" { records.append(["type": "session_meta", "payload": ["id": title, "cwd": "/tmp/\(project)"]]) }
            for (index, text) in lines.enumerated() {
                let timestamp = 1_789_746_000_000 + number * 60_000 + index * 60_000
                if agent == "Codex" {
                    records.append(["type": "response_item", "timestamp": timestamp,
                        "payload": ["type": "message", "id": "showcase-\(number)-\(index)", "role": index % 2 == 0 ? "user" : "assistant", "content": text]])
                } else if agent == "Gemini" {
                    records.append(["id": "showcase-\(number)-\(index)", "type": index % 2 == 0 ? "user" : "gemini", "timestamp": timestamp, "content": text])
                } else {
                    records.append(["type": index % 2 == 0 ? "user" : "assistant", "uuid": "showcase-\(number)-\(index)", "sessionId": title,
                        "cwd": "/tmp/\(project)", "timestamp": timestamp, "message": ["content": text]])
                }
            }
            let file = parent.appendingPathComponent(agent == "Codex" ? "rollout-\(number).jsonl" : "session-\(number).\(agent == "Gemini" ? "json" : "jsonl")")
            if agent == "Gemini" {
                try JSONSerialization.data(withJSONObject: ["sessionId": title, "messages": records]).write(to: file)
                try Data("/tmp/\(project)".utf8).write(to: parent.deletingLastPathComponent().appendingPathComponent(".project_root"))
            } else {
                var data = Data()
                for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
                try data.write(to: file)
            }
        }
        try writeSession("Plan the analytics dashboard", project: "AtlasApp", agent: "Claude", number: 0)
        try writeSession("Investigate search latency", project: "AtlasApp", agent: "Codex", number: 1)
        try writeSession("Migrate authentication flow", project: "NimbusAPI", agent: "Gemini", number: 2)
        try writeSession("Ship the macOS release", project: "OrbitMobile", agent: "Claude", number: 3)
        try writeSession("Polish first-run onboarding", project: "OrbitMobile", agent: "Claude", number: 4)
        let output = URL(fileURLWithPath: "/tmp/trace-readme-showcase")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture(_ name: String) throws {
            let screenshot = app.windows.firstMatch.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]))
            try jpeg.write(to: output.appendingPathComponent("\(name).jpg"))
            attach(app, name: "showcase-\(name)")
        }
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10)); app.buttons["Build Index"].click()
        XCTAssertTrue(app.staticTexts["AtlasApp"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["NimbusAPI"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 session"].firstMatch.exists)
        try capture("project-browser")
        let query = app.textFields["mainSearch"]
        query.click(); query.typeText("cache")
        XCTAssertTrue(app.scrollViews["searchResultsScroll"].waitForExistence(timeout: 10))
        try capture("search-results")
        query.click(); query.typeKey("a", modifierFlags: .command); query.typeKey(.delete, modifierFlags: [])
        app.staticTexts["AtlasApp"].firstMatch.click()
        let session = app.staticTexts["Plan the analytics dashboard"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10)); session.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["testOpenLauncher"].exists)
        XCTAssertTrue(scroll.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Keep the app focused")).firstMatch.waitForExistence(timeout: 10))
        try capture("transcript-view")
        app.radioButtons["Compact"].click()
        try capture("compact-transcript")
    }
}
