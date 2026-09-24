import XCTest

@MainActor
final class TracePerformanceTests: XCTestCase {
    private func makeApp() throws -> (XCUIApplication, URL) {
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
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_BOTTOM_AUDIT_PATH"] = directory
            .appendingPathComponent("bottom-audit").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_FOLLOW_AUDIT_PATH"] = directory
            .appendingPathComponent("follow-audit").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_LAYOUT_AUDIT_PATH"] = directory
            .appendingPathComponent("layout-audit").path
        app.launch()
        XCTAssertTrue(app.buttons["Build Index"].waitForExistence(timeout: 10))
        app.buttons["Build Index"].click()
        let project = app.staticTexts["PerformanceProject"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30))
        project.click()
        addTeardownBlock { app.terminate() }
        return (app, directory)
    }

    func testInteractiveSearchPerformance() throws {
        let (app, _) = try makeApp()
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
        let (app, _) = try makeApp()
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

    func testStreamingTranscriptFollowPerformance() throws {
        let (app, directory) = try makeApp()
        let session = app.staticTexts["Performance session 0"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        let transcript = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.scroll(byDeltaX: 0, deltaY: -100_000)
        let source = directory.appendingPathComponent("Sources/Claude/performance-0.jsonl")
        let bottomAudit = directory.appendingPathComponent("bottom-audit")
        let followAudit = directory.appendingPathComponent("follow-audit")
        let layoutAudit = directory.appendingPathComponent("layout-audit")
        var messageIndex = 400
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let startBottom = lineCount(in: bottomAudit)
            let startFollow = lineCount(in: followAudit)
            let startLayout = lineCount(in: layoutAudit)
            for _ in 0..<10 {
                let record: [String: Any] = [
                    "type": "assistant", "uuid": "performance-0-\(messageIndex)",
                    "sessionId": "performance-0", "cwd": "/tmp/PerformanceProject",
                    "timestamp": "2026-09-18T12:01:00Z",
                    "message": ["content": "Streaming benchmark message \(messageIndex) "
                        + String(repeating: "Changing transcript height. ", count: 18)],
                ]
                let data = try! JSONSerialization.data(withJSONObject: record) + Data([10])
                let handle = try! FileHandle(forWritingTo: source)
                try! handle.seekToEnd()
                try! handle.write(contentsOf: data)
                try! handle.close()
                messageIndex += 1
                Thread.sleep(forTimeInterval: 0.06)
            }
            let finalIndex = messageIndex - 1
            let visible = transcript.staticTexts.matching(NSPredicate(
                format: "value CONTAINS %@", "Streaming benchmark message \(finalIndex)"
            )).firstMatch
            XCTAssertTrue(visible.wait(for: \.isHittable, toEqual: true, timeout: 15))
            Thread.sleep(forTimeInterval: 0.8)
            let bottomCount = lineCount(in: bottomAudit) - startBottom
            let followCount = lineCount(in: followAudit) - startFollow
            let layoutCount = lineCount(in: layoutAudit) - startLayout
            print("STREAMING_BENCHMARK bottom=\(bottomCount) follow=\(followCount) layout=\(layoutCount)")
            let settledCount = lineCount(in: bottomAudit)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(lineCount(in: bottomAudit), settledCount,
                "bottom follow must stop after layout settles")
        }
    }

    private func lineCount(in file: URL) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
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
