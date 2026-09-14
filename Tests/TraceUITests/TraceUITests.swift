import XCTest

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
                "message": ["content": String(repeating: "A lengthy session title ", count: 20)]]
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
        attach(app, name: "popover")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let target = name == "popover" ? app.descendants(matching: .popover).firstMatch : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.exists ? target.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
