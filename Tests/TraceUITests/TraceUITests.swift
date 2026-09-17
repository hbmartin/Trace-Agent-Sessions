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
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + extra
        app.launchEnvironment["TRACE_TEST_DIRECTORY"] = directory.path
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
        let icon = app.images["Session error"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 20))
        icon.hover()
        XCTAssertTrue(app.staticTexts["Loading error details…"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        let list = app.descendants(matching: .any).matching(identifier: "sessionSidebarList").firstMatch
        XCTAssertTrue(list.exists)
        list.scroll(byDeltaX: 0, deltaY: -5_000)
        XCTAssertFalse(icon.isHittable)
        list.scroll(byDeltaX: 0, deltaY: 5_000)
        XCTAssertTrue(icon.isHittable)
        icon.hover()
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
        let visible = app.buttons.allElementsBoundByIndex.first {
            $0.isHittable && $0.label.contains("AnchorNeedle row")
        }
        let anchor = try XCTUnwrap(visible)
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
        XCTAssertTrue(waitForInteractable(query, timeout: 10),
                      "main search must be enabled after onboarding finishes dismissing")
        app.activate()
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
        let manual = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
            $0.isHittable && $0.label.contains("ManualAnchorNeedle row")
        })
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
        XCTAssertTrue(waitForFile(offsets, timeout: 3))
        let manualOffset = try XCTUnwrap(lastNumericLine(in: offsets))
        XCTAssertGreaterThan(manualOffset, 0, "the real scrollbar drag must move results")
        let manuallyPositioned = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
            $0.isHittable && $0.label.contains("NativeAnchorNeedle row")
        })
        let manualY = manuallyPositioned.frame.minY
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "NativeAnchorNeedle newest row"
        )).firstMatch.waitForExistence(timeout: 15))
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

    func testLoadMoreKeepsImmutableCriteriaWhenLiveControlsChange() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let file = directory.appendingPathComponent("Sources/Claude/immutable-page.jsonl")
        let audit = directory.appendingPathComponent("search-criteria-audit")
        app.launchEnvironment["TRACE_TEST_SEARCH_CRITERIA_AUDIT_PATH"] = audit.path
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_QUERY"] = "OtherLiveNeedle"
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_SORT"] = "relevance"
        app.launchEnvironment["TRACE_TEST_PAGINATION_LIVE_AGENT"] = "codex"
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
        app.buttons["Claude Code"].click()
        XCTAssertTrue(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "StablePageNeedle row 219"
        )).firstMatch.waitForExistence(timeout: 10))
        let action = app.buttons["testPaginationCriteria"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        XCTAssertTrue(waitForLineCount(
            audit,
            line: "more|StablePageNeedle|recency|all|agents:claude_code",
            count: 1,
            timeout: 10
        ), "load-more must keep the query, filters, sort, and cursor from its active request")
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
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let content = (try? String(contentsOf: audit, encoding: .utf8)) ?? ""
            if content.components(separatedBy: "automatic\n").count - 1 > baseline { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertGreaterThan(((try? String(contentsOf: audit, encoding: .utf8)) ?? "")
            .components(separatedBy: "automatic\n").count - 1, baseline)
        Thread.sleep(forTimeInterval: 0.5)
        scroll.scroll(byDeltaX: 0, deltaY: -250)
        let visible = app.buttons.allElementsBoundByIndex.first {
            $0.isHittable && $0.label.contains("IdenticalNeedle row")
        }
        let anchor = try XCTUnwrap(visible)
        let y = anchor.frame.minY
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(anchor.isHittable)
        XCTAssertLessThanOrEqual(abs(anchor.frame.minY - y), 35,
                                 "a completed identical-layout refresh must not restore later")
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func waitForInteractable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled, element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func waitForLineCount(_ url: URL, line: String, count: Int,
                                  timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if content.components(separatedBy: line + "\n").count - 1 >= count { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func lastNumericLine(in url: URL) -> Double? {
        let content = try? String(contentsOf: url, encoding: .utf8)
        return content?.split(whereSeparator: \.isNewline).last.flatMap { Double($0) }
    }

    private func waitForNumericLine(
        _ url: URL, greaterThan minimum: Double, timeout: TimeInterval = 10
    ) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = lastNumericLine(in: url), value > minimum { return value }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func waitForBookmarkIndex(
        _ url: URL, greaterThan minimum: Int, timeout: TimeInterval = 10
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let index = Int(content), index > minimum {
                return index
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func waitForStableBookmarkIndex(
        _ url: URL, timeout: TimeInterval = 10
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Int?
        var repeatedObservations = 0
        while Date() < deadline {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let index = Int(content) {
                if index == previous {
                    repeatedObservations += 1
                    if repeatedObservations >= 2 { return index }
                } else {
                    previous = index
                    repeatedObservations = 0
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
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
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
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
        let rebuild = app.buttons["testRebuildIndex"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 5))
        rebuild.click()
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

        try? FileManager.default.removeItem(at: completed)
        try FileManager.default.removeItem(at: selectedSource)
        XCTAssertTrue(waitForFile(completed, timeout: 15))
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons.containing(NSPredicate(
            format: "label CONTAINS %@", "from other project"
        )).firstMatch.exists,
        "a stale selected project ID must remain restrictive instead of becoming all projects")
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
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_STARTED_PATH"] = repairStarted.path
        app.launchEnvironment["TRACE_TEST_ROLLUP_REBUILD_AUDIT_PATH"] = repairAudit.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = passCompleted.path
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
        XCTAssertTrue(waitForLineCount(repairStarted, line: "started", count: 2, timeout: 15),
                      "a terminal rollup error must schedule one deferred dirty-rollup repair")
        XCTAssertTrue(app.staticTexts["10"].exists,
                      "the last completed totals must remain visible during repair")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "rollup unavailable"
        )).firstMatch.waitForExistence(timeout: 10),
        "the rollup error must remain visible while repair is pending")
        XCTAssertTrue(app.staticTexts["Updating token totals…"].exists,
                      "the updating banner must remain visible while repair is pending")

        let dropTrigger = Process()
        dropTrigger.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        dropTrigger.arguments = [directory.appendingPathComponent("index.sqlite").path,
                                 "DROP TRIGGER fail_next_rollup_refresh;"]
        try dropTrigger.run()
        dropTrigger.waitUntilExit()
        XCTAssertEqual(dropTrigger.terminationStatus, 0)

        XCTAssertTrue(waitForLineCount(repairAudit, line: "rebuilt", count: 1, timeout: 15))
        XCTAssertTrue(app.staticTexts["16"].waitForExistence(timeout: 15))
        let error = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "rollup unavailable"
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
                "cwd": "/tmp/TraceUIExample", "timestamp": "2026-09-14T11:00:00Z",
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
        XCTAssertNotNil(waitForNumericLine(offsets, greaterThan: 0),
                        "the recent-session list must consume a real native scroll")
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["Open Trace"].isHittable)
        search.click()
        search.typeText("lengthy")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "lengthy")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let searchBefore = result.frame.minY
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
        XCTAssertLessThan(result.frame.minY, searchBefore - 20)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["Open Trace"].isHittable)
        attach(app, name: "popover")
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
        try addLongSession("Alpha session", project: "ProjectAlpha", directory: directory)
        try addLongSession("Beta session", project: "ProjectBeta", directory: directory)
        let bookmarkSaved = directory.appendingPathComponent("navigation-bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let alphaProject = app.staticTexts["ProjectAlpha"].firstMatch
        XCTAssertTrue(alphaProject.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["All Projects"].exists)
        alphaProject.click()
        let alpha = app.staticTexts["Alpha session"].firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        app.radioButtons["Costs"].click()
        alpha.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["mainSearch"].exists)
        XCTAssertFalse(app.radioButtons["Costs"].exists)
        XCTAssertTrue(app.windows["Alpha session"].exists)
        let first = scroll.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Alpha session message 0")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -950)
        let bookmarkIndex = try XCTUnwrap(waitForStableBookmarkIndex(bookmarkSaved))
        XCTAssertGreaterThan(bookmarkIndex, 0)
        let anchorPrefix = "Alpha session message \(bookmarkIndex)"
        let anchor = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", anchorPrefix
        )).firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        XCTAssertTrue(anchor.isHittable)
        let anchorY = anchor.frame.minY
        XCTAssertFalse(first.isHittable)
        app.radioButtons["Compact"].click()
        let compactAnchor = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", anchorPrefix
        )).firstMatch
        XCTAssertTrue(compactAnchor.waitForExistence(timeout: 5))
        let compactAnchorSettled = NSPredicate { _, _ in
            compactAnchor.isHittable && abs(compactAnchor.frame.minY - anchorY) <= 35
        }
        expectation(for: compactAnchorSettled, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.radioButtons["Comfortable"].click()
        let comfortableAnchorSettled = NSPredicate { _, _ in
            compactAnchor.isHittable && abs(compactAnchor.frame.minY - anchorY) <= 35
        }
        expectation(for: comfortableAnchorSettled, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.staticTexts["ProjectBeta"].firstMatch.click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        XCTAssertFalse(scroll.exists)
        XCTAssertTrue(app.windows["ProjectBeta"].exists)
        app.staticTexts["Beta session"].firstMatch.click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let betaFirst = scroll.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Beta session message 0")).firstMatch
        XCTAssertTrue(betaFirst.waitForExistence(timeout: 10))
        XCTAssertTrue(betaFirst.isHittable)
        app.staticTexts["ProjectAlpha"].firstMatch.click()
        alpha.click()
        let restored = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", anchorPrefix
        )).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue(restored.isHittable)
        let offsetRestored = NSPredicate { _, _ in
            restored.isHittable && abs(restored.frame.minY - anchorY) <= 35
        }
        expectation(for: offsetRestored, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        for _ in 0..<5 {
            XCTAssertEqual(restored.frame.minY, anchorY, accuracy: 35,
                           "restoration retries must retain the saved offset")
            Thread.sleep(forTimeInterval: 0.08)
        }
        XCTAssertEqual(restored.frame.minY, anchorY, accuracy: 35)
        app.buttons["backToProject"].click()
        XCTAssertTrue(app.textFields["mainSearch"].waitForExistence(timeout: 5))
        try addLongSession("Background update", project: "BackgroundProject", directory: directory, count: 1)
        XCTAssertTrue(app.staticTexts["BackgroundProject"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(scroll.exists, "an index refresh must not reopen the last session")
        alpha.click()
        app.terminate()
        app.launch()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "scroll bookmarks must not survive process restart")
        attach(app, name: "session-navigation")
    }

    func testPageDownContinuouslyUpdatesTranscriptBookmark() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Keyboard scroll", project: "KeyboardProject", directory: directory)
        let bookmarkSaved = directory.appendingPathComponent("keyboard-bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
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
        scroll.click()
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.typeKey(.pageDown, modifierFlags: [])
        let firstIndex = try XCTUnwrap(waitForBookmarkIndex(bookmarkSaved, greaterThan: 0))
        app.typeKey(.pageDown, modifierFlags: [])
        let secondIndex = try XCTUnwrap(waitForBookmarkIndex(
            bookmarkSaved, greaterThan: firstIndex
        ))
        XCTAssertGreaterThan(secondIndex, firstIndex,
                             "each keyboard movement must update the saved transcript position")
        scroll.scroll(byDeltaX: 0, deltaY: -100_000)
        let last = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Keyboard scroll message 69"
        )).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertTrue(last.isHittable)
        Thread.sleep(forTimeInterval: 0.5)
        try? FileManager.default.removeItem(at: bookmarkSaved)
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertTrue(waitForFile(bookmarkSaved, timeout: 3),
                      "a boundary Page Down must still finish user scrolling and save its bookmark")
    }

    func testUserScrollDuringTranscriptRestorationCancelsBookmarkRetry() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Alpha session", project: "ProjectAlpha", directory: directory)
        let restorationStarted = directory.appendingPathComponent("restoration-started")
        let restorationCancelled = directory.appendingPathComponent("restoration-cancelled")
        let restorationDeferred = directory.appendingPathComponent("restoration-deferred")
        let bookmarkSaved = directory.appendingPathComponent("bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "15000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = restorationStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = restorationCancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DEFERRED_PATH"] = restorationDeferred.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOOKMARK_SAVED_PATH"] = bookmarkSaved.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["ProjectAlpha"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
        let alpha = app.staticTexts["Alpha session"].firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        alpha.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        try? FileManager.default.removeItem(at: bookmarkSaved)
        scroll.scroll(byDeltaX: 0, deltaY: -1000)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(waitForFile(bookmarkSaved), "the scrolled bookmark must be saved")
        let bookmarkIndex = Int((try? String(contentsOf: bookmarkSaved, encoding: .utf8)) ?? "") ?? 0
        XCTAssertGreaterThan(bookmarkIndex, 0)
        let bookmarked = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Alpha session message "
        )).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(bookmarked)
        app.buttons["backToProject"].click()
        try? FileManager.default.removeItem(at: restorationStarted)
        try? FileManager.default.removeItem(at: restorationCancelled)
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        alpha.click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(restorationStarted), "bookmark restoration must be pending")
        try? FileManager.default.removeItem(at: bookmarkSaved)
        let transcriptScroller = scroll.scrollBars.firstMatch
        XCTAssertTrue(transcriptScroller.waitForExistence(timeout: 5))
        transcriptScroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).click()
        XCTAssertTrue(waitForFile(restorationCancelled), "user scrolling must cancel the pending bookmark")
        XCTAssertTrue(waitForFile(bookmarkSaved), "the cancelling user scroll must save its position")
        let firstScrollerIndex = Int(
            (try? String(contentsOf: bookmarkSaved, encoding: .utf8)) ?? ""
        ) ?? 0
        transcriptScroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).click()
        XCTAssertNotNil(waitForBookmarkIndex(bookmarkSaved, greaterThan: firstScrollerIndex),
                        "continued scrollbar movement must keep updating the bookmark")
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
        XCTAssertTrue(waitForFile(restorationDeferred),
                      "navigation requested while user scrolling is held must be deferred")
        let target = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Alpha session message 60"
        )).firstMatch
        let targetVisible = NSPredicate { _, _ in target.exists && target.isHittable }
        expectation(for: targetVisible, evaluatedWith: nil)
        waitForExpectations(timeout: 30)
    }

    func testDeferredForcedTranscriptRestorationReplaysAfterScrollingEnds() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession(
            "Forced restore", project: "ForcedProject", directory: directory,
            mostlySystem: true
        )
        let restorationStarted = directory.appendingPathComponent("forced-restoration-started")
        let restorationCancelled = directory.appendingPathComponent("forced-restoration-cancelled")
        let restorationDeferred = directory.appendingPathComponent("forced-restoration-deferred")
        let bookmarkSaved = directory.appendingPathComponent("forced-bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS"] = "5000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_IDLE_DELAY_MS"] = "3000"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = restorationStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = restorationCancelled.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DEFERRED_PATH"] = restorationDeferred.path
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
        try? FileManager.default.removeItem(at: restorationDeferred)
        app.checkBoxes["System"].click()
        XCTAssertTrue(waitForFile(restorationDeferred),
                      "hiding the bookmarked row while scrolling must defer a forced restore")
        XCTAssertTrue(waitForFile(restorationStarted, timeout: 12),
                      "the deferred forced restore must replay after scrolling becomes idle")
        XCTAssertTrue(scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Forced restore message 69"
        )).firstMatch.waitForExistence(timeout: 12))
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
        app.menuItems["Copy Message"].click()
        let copied = NSPredicate { _, _ in
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            return text.contains("Here is the visible answer") && text.contains("Reasoning explanation") && text.contains("UniqueInvocation")
        }
        expectation(for: copied, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
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
        let match = scroll.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "UniqueSearchNeedle")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        XCTAssertTrue(match.isHittable)
        scroll.scroll(byDeltaX: 0, deltaY: 100_000)
        let first = scroll.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Search session message 0")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isHittable)
        app.radioButtons["Compact"].click()
        let searchJumpStayedConsumed = NSPredicate { _, _ in
            first.isHittable && !match.isHittable
        }
        expectation(for: searchJumpStayedConsumed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

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
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        XCTAssertTrue(match.isHittable, "opening a hit in the already scrolled session must jump to it")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let target = name == "popover" ? app.descendants(matching: .popover).firstMatch : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.exists ? target.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
