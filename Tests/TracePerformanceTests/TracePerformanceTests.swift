import XCTest
import Darwin

@MainActor
final class TracePerformanceTests: XCTestCase {
    private func makeApp(sidecarTraffic: Bool = false) throws -> (XCUIApplication, URL) {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TracePerformance-\(UUID())")
        let claude = directory.appendingPathComponent("Sources/Claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try makeCorpus(in: claude)
        let codex = directory.appendingPathComponent("Sources/Codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/Gemini"), withIntermediateDirectories: true)
        try Data((#"{"type":"session_meta","payload":{"id":"benchmark-sidecar","cwd":"/tmp/PerformanceProject"}}"# + "\n" +
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Watcher benchmark"}]}}"# + "\n").utf8)
            .write(to: codex.appendingPathComponent("rollout-watcher.jsonl"))
        if sidecarTraffic {
            let store = directory.appendingPathComponent("external-metadata")
            for name in ["one", "two"] {
                let targetDirectory = store.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                try Data().write(to: targetDirectory.appendingPathComponent("names.jsonl"))
            }
            // Both revisions must discover the external dependency at startup.
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Sources/session_index.jsonl"),
                withDestinationURL: store.appendingPathComponent("one/names.jsonl"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-show-main", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRACE_BENCHMARK_EXPORT_DIRECTORY"] = directory.appendingPathComponent("measurements").path
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
            metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
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
        openSession(0, in: app)
        XCTAssertTrue(app.staticTexts["2,000 messages"].waitForExistence(timeout: 10),
            "scroll measurements must use the complete 2,000-message transcript")
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
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
            options: options
        ) {
            sweep += 1
            let sample = "scroll-\(sweep)"
            benchmarkControl("begin", id: sample, directory: directory)
            startMeasuring()
            let done = URL(fileURLWithPath: "\(donePrefix)-\(sweep)")
            var completed = false
            for _ in 0..<60 {
                requestSweep(sweep)
                if waitForFile(done, timeout: 2) {
                    completed = true
                    break
                }
            }
            stopMeasuring()
            benchmarkControl("end", id: sample, directory: directory)
            XCTAssertTrue(completed,
                "the app must complete every 5,000-point scroll sweep")
        }
    }

    func testStreamingTranscriptFollowPerformance() throws {
        let (app, directory) = try makeApp()
        openSession(1, in: app)
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
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            let sample = "streaming-\(messageIndex)"
            benchmarkControl("begin", id: sample, directory: directory)
            startMeasuring()
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
            stopMeasuring()
            benchmarkControl("end", id: sample, directory: directory)
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

    private func benchmarkControl(_ action: String, id: String, directory: URL) {
        let exports = directory.appendingPathComponent("measurements")
        let output = exports.appendingPathComponent(action == "begin" ? "\(id)-begun" : "\(id).json")
        for _ in 0..<15 {
            DistributedNotificationCenter.default().post(name: Notification.Name("traceBenchmarkControl"),
                object: nil, userInfo: ["action": action, "id": id])
            if waitForFile(output, timeout: 1) { break }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "missing acknowledged \(action) for \(id)")
        if action == "end", let data = try? Data(contentsOf: output) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "benchmark-\(id).json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testExternalSidecarTrafficPerformance() throws {
        let (app, directory) = try makeApp(sidecarTraffic: true)
        openSession(1, in: app)
        let home = directory.appendingPathComponent("Sources")
        let store = directory.appendingPathComponent("external-metadata")
        let targets = [store.appendingPathComponent("one/names.jsonl"), store.appendingPathComponent("two/names.jsonl")]
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        // Materialize the initial dependency outside measurement.
        Thread.sleep(forTimeInterval: 2)
        var iteration = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            iteration += 1
            let sample = "watcher-\(iteration)"
            benchmarkControl("begin", id: sample, directory: directory)
            startMeasuring()
            do {
                for index in 0..<10_000 {
                    try Data([1]).write(to: store.appendingPathComponent("one/unrelated-\(index)"))
                }
                for index in 0..<100 {
                    try Data("{\"id\":\"benchmark-sidecar\",\"thread_name\":\"Target \(iteration)-\(index)\"}\n".utf8).write(to: targets[index % 2])
                    Thread.sleep(forTimeInterval: 0.005)
                }
                for index in 0..<50 {
                    let temporary = home.appendingPathComponent("next-link")
                    try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: targets[index % 2])
                    // rename atomically replaces the link, avoiding an artificial gap.
                    XCTAssertEqual(rename(temporary.path, sidecar.path), 0)
                    Thread.sleep(forTimeInterval: 0.06)
                }
                // An append provides a common indexed completion barrier on both revisions.
                let source = directory.appendingPathComponent("Sources/Claude/performance-1.jsonl")
                try appendBenchmarkRecord(["type": "assistant", "uuid": "watcher-barrier-\(iteration)",
                    "sessionId": "performance-1", "message": ["content": "Watcher barrier \(iteration)"]], to: source)
                XCTAssertTrue(app.staticTexts["\(70 + iteration) messages"].waitForExistence(timeout: 15))
                XCTAssertTrue(app.staticTexts["Target \(iteration)-99"].firstMatch.waitForExistence(timeout: 15),
                    "the final retargeted sidecar must be refreshed before measurement ends")
            } catch { XCTFail("watcher workload failed: \(error)") }
            stopMeasuring()
            benchmarkControl("end", id: sample, directory: directory)
        }
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

    private func openSession(_ index: Int, in app: XCUIApplication) {
        app.activate()
        let title = "Performance session \(index)"
        let viewport = app.scrollViews.containing(.outline, identifier: "sessionSidebarList").firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let label = viewport.staticTexts.matching(NSPredicate(format: "value == %@", title)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        for _ in 0..<30 {
            let frame = label.frame
            let visible = viewport.frame
            if visible.contains(frame) && label.isHittable {
                label.click()
                let content = app.scrollViews["transcriptScroll"].staticTexts.matching(NSPredicate(
                    format: "value BEGINSWITH %@", "PerformanceNeedle commonterm session \(index) message "
                )).firstMatch
                XCTAssertTrue(content.waitForExistence(timeout: 10),
                    "the selected benchmark transcript must load before measurement")
                return
            }
            let point = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            point.hover()
            point.scroll(byDeltaX: 0, deltaY: frame.minY < visible.minY ? 100 : -100)
        }
        XCTFail("Benchmark session \(title) must be visible before clicking")
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
