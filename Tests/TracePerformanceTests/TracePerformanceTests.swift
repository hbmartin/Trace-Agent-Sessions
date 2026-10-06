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
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_JUMP_DONE_PATH"] = directory
            .appendingPathComponent("jump-done").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_POSITION_PROBE_PATH"] = directory
            .appendingPathComponent("position-probe").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_FOLLOW_MARKER_PREFIX"] = directory
            .appendingPathComponent("follow-marker").path
        app.launchEnvironment["TRACE_TEST_TRANSCRIPT_SCROLL_SWEEP_DONE_PREFIX"] = directory
            .appendingPathComponent("scroll-sweep-done").path
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
            metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric()],
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
        let (app, directory) = try makeApp()
        let session = app.staticTexts["Performance session 0"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        let donePrefix = directory.appendingPathComponent("scroll-sweep-done").path
        func requestSweep(_ number: Int) {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("traceTestTranscriptBenchmark"), object: nil,
                userInfo: ["sweep": number]
            )
        }
        let warmupDone = URL(fileURLWithPath: "\(donePrefix)-1")
        var warmedUp = false
        for _ in 0..<60 {
            requestSweep(1)
            if waitForFile(warmupDone, timeout: 2) {
                warmedUp = true
                break
            }
        }
        XCTAssertTrue(warmedUp,
            "the warm-up scroll sweep must complete")
        let firstDistance = try XCTUnwrap(Double(String(
            contentsOfFile: "\(donePrefix)-1", encoding: .utf8
        )))
        XCTAssertGreaterThan(firstDistance, 4_000,
            "the measured session must have enough content for the full scroll sweep")
        var sweep = 1
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [
                XCTClockMetric(), XCTCPUMetric(application: app),
                XCTOSSignpostMetric(
                    subsystem: "me.haroldmartin.Trace", category: "PointsOfInterest",
                    name: "Transcript Update"
                ),
            ],
            options: options
        ) {
            sweep += 1
            let done = URL(fileURLWithPath: "\(donePrefix)-\(sweep)")
            var completed = false
            for _ in 0..<60 {
                requestSweep(sweep)
                if waitForFile(done, timeout: 2) {
                    completed = true
                    break
                }
            }
            XCTAssertTrue(completed,
                "the app must complete every 5,000-point scroll sweep")
        }
    }

    func testStreamingTranscriptFollowPerformance() throws {
        let (app, directory) = try makeApp()
        let session = app.staticTexts["Performance session 1"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        let transcript = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let loadedMessage = transcript.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "PerformanceNeedle commonterm session 1 message "
        )).firstMatch
        XCTAssertTrue(loadedMessage.waitForExistence(timeout: 10),
            "streaming must start after the initial transcript is loaded")
        let jumpDone = directory.appendingPathComponent("jump-done")
        let positionProbe = directory.appendingPathComponent("position-probe")
        app.buttons["testJumpTranscriptBottom"].click()
        XCTAssertTrue(waitForFile(jumpDone, timeout: 10))
        let startPosition = try XCTUnwrap(probedPosition(in: positionProbe))
        XCTAssertTrue(startPosition.pinned && startPosition.distance <= 2,
            "streaming must start at a pinned bottom")
        let source = directory.appendingPathComponent("Sources/Claude/performance-1.jsonl")
        let bottomAudit = directory.appendingPathComponent("bottom-audit")
        let followAudit = directory.appendingPathComponent("follow-audit")
        let layoutAudit = directory.appendingPathComponent("layout-audit")
        let followMarkerPrefix = directory.appendingPathComponent("follow-marker").path
        let startBottom = lineCount(in: bottomAudit)
        let startFollow = lineCount(in: followAudit)
        let startLayout = lineCount(in: layoutAudit)
        var messageIndex = 70
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [
            XCTClockMetric(), XCTCPUMetric(application: app),
            XCTOSSignpostMetric(
                subsystem: "me.haroldmartin.Trace", category: "PointsOfInterest",
                name: "Transcript Update"
            ),
        ], options: options) {
            for _ in 0..<10 {
                let record: [String: Any] = [
                    "type": "assistant", "uuid": "performance-1-\(messageIndex)",
                    "sessionId": "performance-1", "cwd": "/tmp/PerformanceProject",
                    "timestamp": "2026-09-18T12:01:00Z",
                    "message": ["content": "Streaming benchmark message \(messageIndex) "
                        + String(repeating: "Changing transcript height. ", count: 18)],
                ]
                do {
                    try appendBenchmarkRecord(record, to: source)
                } catch {
                    XCTFail("Could not append streaming benchmark message: \(error)")
                    return
                }
                messageIndex += 1
            }
            let count = app.staticTexts["\(messageIndex) messages"].firstMatch
            XCTAssertTrue(count.waitForExistence(timeout: 15),
                "the app must index the appended batch before the measurement ends")
            XCTAssertTrue(waitForFile(
                URL(fileURLWithPath: "\(followMarkerPrefix)-\(messageIndex)"), timeout: 15
            ), "the measured batch must finish bottom following")
        }
        let bottomCount = lineCount(in: bottomAudit) - startBottom
        let followCount = lineCount(in: followAudit) - startFollow
        let layoutCount = lineCount(in: layoutAudit) - startLayout
        print("STREAMING_BENCHMARK bottom=\(bottomCount) follow=\(followCount) layout=\(layoutCount)")
        try? FileManager.default.removeItem(at: positionProbe)
        app.buttons["testProbeTranscriptPosition"].click()
        XCTAssertTrue(waitForFile(positionProbe, timeout: 10))
        let finalPosition = try XCTUnwrap(probedPosition(in: positionProbe))
        XCTAssertTrue(finalPosition.pinned && finalPosition.distance <= 2,
            "the measured append batch must end at the pinned bottom")
    }

    private func lineCount(in file: URL) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    private func appendBenchmarkRecord(_ record: [String: Any], to source: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: record) + Data([10])
        let handle = try FileHandle(forWritingTo: source)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func waitForFile(_ file: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private func probedPosition(in file: URL) -> (distance: Double, pinned: Bool)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").last else { return nil }
        let fields = line.split(separator: ",")
        guard fields.count == 3, let origin = Double(fields[0]),
              let maximum = Double(fields[1]) else { return nil }
        return (maximum - origin, fields[2] == "true")
    }

    private func makeCorpus(in directory: URL) throws {
        for session in 0..<20 {
            let count = session == 0 ? 2_000 : session == 1 ? 70 : 80
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
