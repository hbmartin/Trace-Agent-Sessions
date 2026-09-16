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
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        let file = directory.appendingPathComponent("Sources/Claude/anchor.jsonl")
        var data = Data()
        for index in 0..<90 {
            let row: [String: Any] = [
                "type": "assistant", "uuid": "anchor-\(index)", "sessionId": "anchor-session",
                "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["content": "AnchorNeedle row \(index)"],
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
        query.typeText("AnchorNeedle")
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
            "cwd": "/tmp/TraceUIExample", "timestamp": 1_700_000_200_000,
            "message": ["content": "AnchorNeedle newest row"],
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: appended) + Data([10]))
        try handle.close()
        XCTAssertTrue(app.staticTexts["91 messages"].waitForExistence(timeout: 15))
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
        reopenPopover(app)
        XCTAssertTrue(popoverSearch.waitForExistence(timeout: 10))
        XCTAssertEqual(popoverSearch.value as? String, "",
                       "default clear-on-close must clear the shared global query")
    }

    func testRetainedHiddenGlobalSearchRefreshesOnlyOnReopening() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-popover"])
        let defaults = UserDefaults(suiteName: "me.haroldmartin.Trace.tests.\(directory.lastPathComponent)")
        defaults?.set(false, forKey: "clearGlobalSearchOnClose")
        let requests = directory.appendingPathComponent("search-requests")
        let completed = directory.appendingPathComponent("index-pass-completed")
        app.launchEnvironment["TRACE_TEST_SEARCH_REQUEST_AUDIT_PATH"] = requests.path
        app.launchEnvironment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] = completed.path
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
        reopenPopover(app)
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
        XCTAssertTrue(app.staticTexts["Totals update when indexing finishes."].waitForExistence(timeout: 15))
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
    }

    private func reopenPopover(_ app: XCUIApplication) {
        let status = app.statusItems["Trace"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.click()
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
        let initial = app.buttons.allElementsBoundByIndex.first { $0.label.hasPrefix("Session ") && $0.isHittable }
        let before = initial?.frame.minY
        list.scroll(byDeltaX: 0, deltaY: -300)
        if let initial, let before { XCTAssertLessThan(initial.frame.minY, before - 20) }
        else { XCTFail("No scrollable recent session found") }
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

    private func addLongSession(_ name: String, project: String, directory: URL, count: Int = 70) throws {
        var objects: [[String: Any]] = [["type": "custom-title", "customTitle": name]]
        for index in 0..<count {
            objects.append(["type": index == 0 ? "user" : "assistant", "uuid": "\(name)-\(index)",
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
        scroll.scroll(byDeltaX: 0, deltaY: -950)
        let visible = scroll.staticTexts.allElementsBoundByIndex.filter {
            $0.isHittable && (($0.value as? String) ?? $0.label).hasPrefix("Alpha session message")
        }
        let anchor = try XCTUnwrap(visible.first)
        let anchorText = (anchor.value as? String) ?? anchor.label
        let anchorY = anchor.frame.minY
        XCTAssertFalse(first.isHittable)
        app.radioButtons["Compact"].click()
        let compactAnchor = scroll.staticTexts.matching(NSPredicate(format: "value == %@", anchorText)).firstMatch
        XCTAssertTrue(compactAnchor.waitForExistence(timeout: 5))
        let compactAnchorSettled = NSPredicate { _, _ in
            compactAnchor.isHittable && abs(compactAnchor.frame.minY - anchorY) <= 35
        }
        expectation(for: compactAnchorSettled, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.radioButtons["Comfortable"].click()
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
        let restored = scroll.staticTexts.matching(NSPredicate(format: "value == %@", anchorText)).firstMatch
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

    func testUserScrollDuringTranscriptRestorationCancelsBookmarkRetry() throws {
        let (app, directory) = try makeApp(extra: ["--ui-show-main"])
        try addLongSession("Alpha session", project: "ProjectAlpha", directory: directory)
        let restorationStarted = directory.appendingPathComponent("restoration-started")
        let restorationCancelled = directory.appendingPathComponent("restoration-cancelled")
        let bookmarkSaved = directory.appendingPathComponent("bookmark-saved")
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_DELAY_MS"] = "1500"
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_STARTED_PATH"] = restorationStarted.path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_RESTORE_CANCELLED_PATH"] = restorationCancelled.path
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
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        alpha.click()
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFile(restorationStarted), "bookmark restoration must be pending")
        try? FileManager.default.removeItem(at: restorationCancelled)
        scroll.scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(waitForFile(restorationCancelled), "user scrolling must cancel the pending bookmark")
        let manuallyVisible = scroll.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Alpha session message "
        )).allElementsBoundByIndex.first { $0.isHittable }
        let manual = try XCTUnwrap(manuallyVisible)
        let manualY = manual.frame.minY
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertTrue(manual.isHittable)
        XCTAssertLessThanOrEqual(abs(manual.frame.minY - manualY), 35,
                                 "a delayed restoration must yield to the user's scroll")
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
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let target = name == "popover" ? app.descendants(matching: .popover).firstMatch : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.exists ? target.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
