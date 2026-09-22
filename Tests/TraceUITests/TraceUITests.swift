import XCTest
import AppKit

@MainActor
final class TraceUITests: XCTestCase {
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
        for (index, var object) in records.enumerated() {
            object["sessionId"] = "test-session"
            object["cwd"] = "/tmp/TraceUIExample"
            object["timestamp"] = "2026-09-14T10:00:0\(index)Z"
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "periodic reconciliation"
        )).firstMatch.waitForExistence(timeout: 5))

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
        app.launchEnvironment["TRACE_TEST_INDEX_BATCH_DELAY_MS"] = "5000"
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
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
        app.popUpButtons["Any time"].click()
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
        app.popUpButtons["All projects"].click()
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
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return content.components(separatedBy: line + "\n").count - 1 >= count
                ? true
                : nil
        } ?? false
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

    private func visibleTranscriptMessage(
        _ session: String, near index: Int, in scroll: XCUIElement,
        timeout: TimeInterval = 5
    ) -> (index: Int, element: XCUIElement)? {
        let candidates = [index, index + 1, index - 1, index + 2, index - 2, index + 3]
            .filter { $0 >= 0 }
        return poll(timeout: timeout) {
            for candidate in candidates {
                if let element = hittableTranscriptAnchor(
                    session, index: candidate, in: scroll
                ) {
                    return (candidate, element)
                }
            }
            return nil
        }
    }

    private func focusTranscript(_ session: String, in scroll: XCUIElement) {
        let first = transcriptMessage(session, index: 0, in: scroll)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 10))
        first.click()
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
        app.popUpButtons["All projects"].click()
        app.menuItems["TraceUIExample"].click()
        app.popUpButtons["Any time"].click()
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

        XCTAssertTrue(app.popUpButtons["7 days"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.popUpButtons["TraceUIExample"].exists,
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
        app.popUpButtons["7 days"].click()
        app.menuItems["Any time"].click()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Find ancient date boundary"
        )).firstMatch.waitForExistence(timeout: 10),
        "Any time must remove both date bounds before the launcher closes")
        app.popUpButtons["TraceUIExample"].click()
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
        app.popUpButtons["All projects"].click()
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
        XCTAssertTrue(app.popUpButtons["TraceUIExample"].exists,
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
        app.popUpButtons["All projects"].click()
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
        XCTAssertTrue(app.popUpButtons["Renamed Trace Project"].waitForExistence(timeout: 10),
                      "final reconciliation must refresh the filter's displayed project name")

        try? FileManager.default.removeItem(at: completed)
        try FileManager.default.removeItem(at: selectedSource)
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        XCTAssertTrue(app.popUpButtons["All projects"].waitForExistence(timeout: 15),
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
        let initial: [String: Any] = [
            "type": "assistant", "uuid": "failed-pass-initial", "sessionId": "failed-pass",
            "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T10:00:00Z",
            "message": ["id": "failed-pass-initial-response", "model": "claude-sonnet-5",
                        "content": "Failed pass baseline",
                        "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        try (JSONSerialization.data(withJSONObject: initial) + Data([10])).write(to: file)
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        app.radioButtons["Costs"].click()
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
        let status = app.statusItems["Trace"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
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
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_STARTED_PATH"] = rebuilding.path
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
        list.scroll(byDeltaX: 0, deltaY: -300)
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
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
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
        XCTAssertTrue(project.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "\(projectName) must be revealed in the project pane")
        XCTAssertTrue(project.isSelected, "\(projectName) must be selected")
        XCTAssertTrue(session.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "\(sessionTitle) must be revealed in the session pane")
        XCTAssertTrue(session.isSelected, "\(sessionTitle) must be selected")
    }

    private func addLongSession(
        _ name: String, project: String, directory: URL, count: Int = 70,
        mostlySystem: Bool = false
    ) throws {
        var objects: [[String: Any]] = [["type": "custom-title", "customTitle": name]]
        for index in 0..<count {
            let type = mostlySystem && index > 0 && index < count - 1
                ? "system"
                : index == 0 ? "user" : "assistant"
            objects.append(["type": type, "uuid": "\(name)-\(index)",
                "sessionId": name, "cwd": "/tmp/\(project)", "timestamp": "2026-09-14T12:00:00Z",
                "message": ["content": "\(name) message \(index)\n" + String(repeating: "Transcript fixture content. ", count: 24)]])
        }
        var data = Data()
        for object in objects { data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10) }
        try data.write(to: directory.appendingPathComponent("Sources/Claude/\(name).jsonl"))
    }

    func testSessionNavigationScrollRestorationAndRestart() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        func sidebarSession(named title: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(identifier: "sessionSidebarList").firstMatch
                .cells.containing(.staticText, identifier: title).firstMatch
        }
        try addLongSession("Alpha session", project: "ProjectAlpha", directory: directory)
        try addLongSession("Beta session", project: "ProjectBeta", directory: directory)
        let bookmarkSaved = directory.appendingPathComponent("navigation-bookmark-saved")
        let idleAudit = directory.appendingPathComponent("navigation-scroll-idle-audit")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
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
        alphaAfterSectionChange.click()
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
        let anchor = try XCTUnwrap(visibleTranscriptMessage(
            "Alpha session", near: bookmarkIndex, in: scroll
        ))
        let anchorY = anchor.element.frame.minY
        app.radioButtons["Compact"].click()
        let compactAnchor = try XCTUnwrap(waitForTranscriptAnchor(
            "Alpha session", index: anchor.index, in: scroll, timeout: 10
        ))
        XCTAssertEqual(compactAnchor.frame.minY, anchorY, accuracy: 35)
        app.radioButtons["Comfortable"].click()
        let comfortableAnchor = try XCTUnwrap(waitForTranscriptAnchor(
            "Alpha session", index: anchor.index, in: scroll, timeout: 10
        ))
        XCTAssertEqual(comfortableAnchor.frame.minY, anchorY, accuracy: 35)
        app.staticTexts["ProjectBeta"].firstMatch.click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        XCTAssertFalse(scroll.exists)
        XCTAssertTrue(app.windows["ProjectBeta"].exists)
        let beta = sidebarSession(named: "Beta session")
        XCTAssertTrue(beta.wait(for: \.isHittable, toEqual: true, timeout: 10))
        beta.click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let betaFirst = transcriptMessage("Beta session", index: 0, in: scroll)
        XCTAssertTrue(betaFirst.waitForExistence(timeout: 10))
        XCTAssertTrue(betaFirst.isHittable)
        app.staticTexts["ProjectAlpha"].firstMatch.click()
        let returningAlpha = sidebarSession(named: "Alpha session")
        XCTAssertTrue(returningAlpha.wait(for: \.isHittable, toEqual: true, timeout: 10))
        returningAlpha.click()
        let restoredScroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(restoredScroll.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            let restoredAnchor = try XCTUnwrap(waitForTranscriptAnchor(
                "Alpha session", index: anchor.index, in: app, timeout: 10
            ))
            XCTAssertEqual(restoredAnchor.frame.minY, anchorY, accuracy: 35,
                           "restoration retries must retain the saved offset")
            Thread.sleep(forTimeInterval: 0.08)
        }
        app.buttons["backToProject"].click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        try addLongSession("Background update", project: "BackgroundProject", directory: directory, count: 1)
        XCTAssertTrue(app.staticTexts["BackgroundProject"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(scroll.exists, "an index refresh must not reopen the last session")
        let alphaAfterRefresh = sidebarSession(named: "Alpha session")
        XCTAssertTrue(alphaAfterRefresh.wait(for: \.isHittable, toEqual: true, timeout: 10))
        alphaAfterRefresh.click()
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
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["KeyboardProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let session = app.staticTexts["Keyboard scroll"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        focusTranscript("Keyboard scroll", in: scroll)
        try? FileManager.default.removeItem(at: idleAudit)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.typeKey(.pageDown, modifierFlags: [])
        _ = try XCTUnwrap(waitForBookmarkIndex(bookmarkSaved, greaterThan: 0))
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 10))
        let afterFirstPage = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Keyboard scroll message "
        ))
        let visibleAfterFirstPage = try XCTUnwrap(firstHittable(in: afterFirstPage, timeout: 10))
        visibleAfterFirstPage.click()
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertNotNil(waitForBookmarkIndex(bookmarkSaved, greaterThan: 0))
        let finishesBeforeWheel = fileLines(in: idleAudit).filter {
            $0 == "finished"
        }.count
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        XCTAssertTrue(waitForLineCount(
            idleAudit, line: "finished", count: finishesBeforeWheel + 1, timeout: 10
        ), "the preceding wheel scroll must be fully idle before testing the boundary")
        let visibleMessages = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Keyboard scroll message "
        ))
        let visibleMessage = try XCTUnwrap(firstHittable(in: visibleMessages, timeout: 10))
        let pasteboardChangeCount = preparePasteboardForCopy()
        visibleMessage.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        assertPasteboardChanged(
            after: pasteboardChangeCount, contains: ["Keyboard scroll message"],
            message: "the boundary case must run with selectable message text as first responder"
        )
        try? FileManager.default.removeItem(at: idleAudit)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertTrue(waitForLineCount(idleAudit, line: "started", count: 1, timeout: 3),
                      "a boundary Page Down must schedule idle completion directly")
        XCTAssertTrue(waitForLineCount(idleAudit, line: "finished", count: 1, timeout: 3),
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
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_AUDIT_PATH"] = idleAudit.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["WindowLifecycleProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let session = app.staticTexts["Window lifecycle"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        focusTranscript("Window lifecycle", in: scroll)
        try? FileManager.default.removeItem(at: idleAudit)
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertTrue(waitForLineCount(idleAudit, line: "started", count: 1, timeout: 3),
                      "the scroll-idle delay must be pending before the window closes")

        let mainWindow = app.windows["Window lifecycle"]
        XCTAssertTrue(mainWindow.exists)
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
        let bookmarkSaved = directory.appendingPathComponent("bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "15000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = restorationStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = restorationCancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
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
        alpha.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -1000)
        let savedBookmarkIndex = try XCTUnwrap(
            waitForBookmarkIndex(bookmarkSaved, greaterThan: 0),
            "the scrolled bookmark must be saved"
        )
        XCTAssertGreaterThan(savedBookmarkIndex, 0)
        let savedRow = scroll.descendants(matching: .any).matching(
            identifier: "transcriptMessage-\(savedBookmarkIndex)"
        )
        XCTAssertNotNil(firstHittable(in: savedRow, timeout: 5))
        app.buttons["backToProject"].click()
        try? FileManager.default.removeItem(at: restorationStarted)
        try? FileManager.default.removeItem(at: restorationCancelled)
        let returningAlpha = sessionList.cells.containing(
            .staticText, identifier: "Alpha session"
        ).firstMatch
        XCTAssertTrue(returningAlpha.wait(for: \.isHittable, toEqual: true, timeout: 10))
        returningAlpha.click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(restorationStarted), "bookmark restoration must be pending")
        try? FileManager.default.removeItem(at: bookmarkSaved)
        let transcriptScroller = scroll.scrollBars["transcriptScroller"]
        XCTAssertTrue(transcriptScroller.waitForExistence(timeout: 5))
        scroll.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertTrue(waitForFile(restorationCancelled), "user scrolling must cancel the pending bookmark")
        XCTAssertTrue(waitForFile(bookmarkSaved), "the cancelling user scroll must save its position")
        let firstScrollerIndex = try XCTUnwrap(bookmarkIndex(in: bookmarkSaved))
        scroll.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertNotNil(waitForBookmarkIndex(bookmarkSaved, greaterThan: firstScrollerIndex),
                        "continued scrollbar movement must keep updating the bookmark")
        try? FileManager.default.removeItem(at: restorationStarted)
        app.buttons["testOpenLauncher"].click()
        let launcherSearch = app.textFields["Search Claude Code, Codex, and Gemini"]
        XCTAssertTrue(launcherSearch.waitForExistence(timeout: 10))
        launcherSearch.click()
        launcherSearch.typeText("Alpha session message 60")
        let requested = app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "Alpha session message 60"
        )).firstMatch
        XCTAssertTrue(requested.waitForExistence(timeout: 10))
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
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS"] = "5000"
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
        session.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -1000)
        XCTAssertTrue(waitForFile(bookmarkSaved), "the system-row bookmark must be saved")
        app.buttons["backToProject"].click()
        try? FileManager.default.removeItem(at: restorationStarted)
        try? FileManager.default.removeItem(at: restorationCancelled)
        session.click()
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
        session.click()
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
        let oldY = divider.frame.midY
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)))
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
