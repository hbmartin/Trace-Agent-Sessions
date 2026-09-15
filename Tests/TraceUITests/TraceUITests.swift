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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "UniqueOutput: file missing"
        )).firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        let file = directory.appendingPathComponent("Sources/Claude/session.jsonl")
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
        icon.hover()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "Later failure detail"
        )).firstMatch.waitForExistence(timeout: 15))
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
            format: "label CONTAINS %@", "failed files"
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
        try addLongSession("Search session", project: "SearchProject", directory: directory)
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
        scroll.scroll(byDeltaX: 0, deltaY: 20_000)
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
