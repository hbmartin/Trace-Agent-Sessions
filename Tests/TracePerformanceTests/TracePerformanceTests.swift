import XCTest

@MainActor
final class TracePerformanceTests: XCTestCase {
    private func makeApp() throws -> XCUIApplication {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TracePerformance-\(UUID())")
        let claude = directory.appendingPathComponent("Sources/Claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try makeCorpus(in: claude)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-show-main"]
        app.launchEnvironment["TRACE_TEST_DIRECTORY"] = directory.path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["PerformanceProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30))
        project.click()
        addTeardownBlock { app.terminate() }
        return app
    }

    func testInteractiveSearchPerformance() throws {
        let app = try makeApp()
        let search = app.textFields["mainSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            search.click()
            search.typeText("PerformanceNeedle")
            let result = app.buttons.containing(NSPredicate(
                format: "label CONTAINS %@", "PerformanceNeedle"
            )).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10))
            search.typeKey("a", modifierFlags: .command)
            search.typeKey(.delete, modifierFlags: [])
        }
    }

    func testTranscriptScrollPerformance() throws {
        let app = try makeApp()
        let session = app.staticTexts["Performance session 0"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        let transcript = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            transcript.scroll(byDeltaX: 0, deltaY: -2_500)
            transcript.scroll(byDeltaX: 0, deltaY: 2_500)
        }
    }

    private func makeCorpus(in directory: URL) throws {
        for session in 0..<20 {
            let count = session == 0 ? 400 : 80
            var data = Data()
            let title: [String: Any] = [
                "type": "custom-title", "customTitle": "Performance session \(session)",
            ]
            data.append(try JSONSerialization.data(withJSONObject: title))
            data.append(10)
            for message in 0..<count {
                let content = "PerformanceNeedle commonterm session \(session) message \(message). "
                    + String(repeating: "Representative transcript content. ", count: 12)
                let record: [String: Any] = [
                    "type": message == 0 ? "user" : "assistant",
                    "uuid": "performance-\(session)-\(message)",
                    "sessionId": "performance-\(session)",
                    "cwd": "/tmp/PerformanceProject",
                    "timestamp": "2026-09-18T12:00:00Z",
                    "message": ["content": content],
                ]
                data.append(try JSONSerialization.data(withJSONObject: record))
                data.append(10)
            }
            try data.write(
                to: directory.appendingPathComponent("performance-\(session).jsonl")
            )
        }
    }
}
