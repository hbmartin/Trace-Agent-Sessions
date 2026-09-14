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
            ["type": "system", "uuid": "four", "message": ["content": "System marker"]]
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
        let filter = app.textFields["projectFilter"]
        filter.click()
        filter.typeText("Find the sample answer")
        XCTAssertFalse(app.staticTexts["TraceUIExample"].exists, "project filter must not match transcript content")
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        let icon = app.images["Session error"].firstMatch
        if icon.exists {
            icon.hover()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "UniqueOutput: file missing")).firstMatch.waitForExistence(timeout: 5))
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
        try handle.close()
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["SearchProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20))
        project.click()
        let search = app.textFields["mainSearch"]
        search.click()
        search.typeText("UniquePlanNeedle")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "UniquePlanNeedle")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Generated plan").firstMatch.exists)
        result.click()
        let scroll = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let match = scroll.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "UniquePlanNeedle")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        XCTAssertTrue(match.isHittable)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let target = name == "popover" ? app.descendants(matching: .popover).firstMatch : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.exists ? target.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
