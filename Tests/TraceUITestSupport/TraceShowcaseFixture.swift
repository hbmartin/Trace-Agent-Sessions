import AppKit
import XCTest

/// The README and visual regressions use the same public, generated session corpus.
@MainActor
enum TraceShowcaseFixture {
    static func makeApp(test: XCTestCase, appearance: String? = nil) throws -> XCUIApplication {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceShowcase-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-show-main", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleAccentColor", "4"]
        app.launchEnvironment["TRACE_TEST_DIRECTORY"] = directory.path
        app.launchEnvironment["TRACE_TEST_SHOWCASE"] = "1"
        app.launchEnvironment["TZ"] = "UTC"
        if let appearance { app.launchEnvironment["TRACE_TEST_SNAPSHOT_APPEARANCE"] = appearance }
        test.addTeardownBlock {
            app.terminate()
            UserDefaults(suiteName: "me.haroldmartin.Trace.tests.\(directory.lastPathComponent)")?
                .removePersistentDomain(forName: "me.haroldmartin.Trace.tests.\(directory.lastPathComponent)")
            try? FileManager.default.removeItem(at: directory)
        }
        try seed(directory: directory)
        return app
    }

    private static func seed(directory: URL) throws {
        func writeSession(_ title: String, project: String, agent: String, number: Int) throws {
            let lines = [title,
                "Keep the app focused on the work in front of you.\n\nUse clear labels and make every state easy to understand.",
                "Add a compact dashboard with activation, retention, and weekly active teams.",
                "Add a seven-day funnel with accessible colors and direct labels.\n\nLoad each section independently so the dashboard stays responsive.\n\nShow clear empty, loading, error, and complete states.",
                "Make keyboard navigation and reduced motion part of the definition of done.",
                "Include focus order, VoiceOver labels, contrast checks, and a no-animation path in the acceptance criteria.",
                "Use a disposable cache so source transcripts stay untouched.",
                "Cache only the local search index. Rebuild it safely when the source format changes."]
            let root = directory.appendingPathComponent("Sources/\(agent)")
            let parent = agent == "Gemini" ? root.appendingPathComponent("\(project)/chats") : root
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var records: [[String: Any]] = []
            if agent == "Codex" { records.append(["type": "session_meta", "payload": ["id": title, "cwd": "/tmp/\(project)"]]) }
            for (index, text) in lines.enumerated() {
                let timestamp = 1_789_746_000_000 + number * 60_000 + index * 60_000
                if agent == "Codex" {
                    records.append(["type": "response_item", "timestamp": timestamp,
                        "payload": ["type": "message", "id": "showcase-\(number)-\(index)", "role": index % 2 == 0 ? "user" : "assistant", "content": text]])
                } else if agent == "Gemini" {
                    records.append(["id": "showcase-\(number)-\(index)", "type": index % 2 == 0 ? "user" : "gemini", "timestamp": timestamp, "content": text])
                } else {
                    records.append(["type": index % 2 == 0 ? "user" : "assistant", "uuid": "showcase-\(number)-\(index)", "sessionId": title,
                        "cwd": "/tmp/\(project)", "timestamp": timestamp, "message": ["content": text]])
                }
            }
            let file = parent.appendingPathComponent(agent == "Codex" ? "rollout-\(number).jsonl" : "session-\(number).\(agent == "Gemini" ? "json" : "jsonl")")
            if agent == "Gemini" {
                try JSONSerialization.data(withJSONObject: ["sessionId": title, "messages": records]).write(to: file)
                try Data("/tmp/\(project)".utf8).write(to: parent.deletingLastPathComponent().appendingPathComponent(".project_root"))
            } else {
                var data = Data()
                for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
                try data.write(to: file)
            }
        }
        try writeSession("Plan the analytics dashboard", project: "AtlasApp", agent: "Claude", number: 0)
        try writeSession("Investigate search latency", project: "AtlasApp", agent: "Codex", number: 1)
        try writeSession("Migrate authentication flow", project: "NimbusAPI", agent: "Gemini", number: 2)
        try writeSession("Ship the macOS release", project: "OrbitMobile", agent: "Claude", number: 3)
        try writeSession("Polish first-run onboarding", project: "OrbitMobile", agent: "Claude", number: 4)
    }

    static func captureScreens(app: XCUIApplication, capture: (String) throws -> Void) throws {
        app.launch()
        let build = app.buttons["Build Index"]
        try require(build.waitForExistence(timeout: 10), "Onboarding did not appear")
        build.click()
        try require(app.staticTexts["AtlasApp"].firstMatch.waitForExistence(timeout: 20), "AtlasApp is missing")
        try require(app.staticTexts["NimbusAPI"].firstMatch.waitForExistence(timeout: 10), "NimbusAPI is missing")
        try require(app.staticTexts["1 session"].firstMatch.exists, "Expected fixture session count")
        let progress = app.buttons["indexProgress"]
        let complete = NSPredicate(format: "label BEGINSWITH %@", "Index current")
        try require(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: complete, object: progress)], timeout: 20) == .completed,
                    "Fixture indexing did not finish")
        let query = app.textFields["mainSearch"]
        query.click(); stabilizeFocus(query)
        try capture("project-browser")

        query.click(); query.typeText("cache")
        let results = app.scrollViews["searchResultsScroll"]
        try require(results.waitForExistence(timeout: 10), "Search results did not appear")
        let cache = results.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Use a disposable cache"))
        try require(cache.firstMatch.waitForExistence(timeout: 10), "Search snippets did not hydrate")
        let expectedResults = results.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "cache"))
        let tenResults = NSPredicate { _, _ in expectedResults.count == 10 }
        try require(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: tenResults, object: results)], timeout: 10) == .completed,
                    "Expected ten fixture search results")
        // Move focus out of the text editor so caret blinking cannot enter a reference image.
        stabilizeFocus(query)
        try capture("search-results")

        query.click(); query.typeKey("a", modifierFlags: .command); query.typeKey(.delete, modifierFlags: [])
        app.staticTexts["AtlasApp"].firstMatch.click()
        let session = app.staticTexts["Plan the analytics dashboard"].firstMatch
        try require(session.waitForExistence(timeout: 10), "Transcript session did not appear")
        session.click()
        let scroll = app.scrollViews["transcriptScroll"]
        try require(scroll.waitForExistence(timeout: 10), "Transcript did not appear")
        try require(!app.buttons["testOpenLauncher"].exists, "Showcase must hide test controls")
        try require(scroll.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Keep the app focused")).firstMatch.waitForExistence(timeout: 10),
                    "Transcript did not hydrate")
        if app.launchEnvironment["TRACE_TEST_SNAPSHOT_APPEARANCE"] != nil {
            // Realize the complete small fixture before comparing a static viewport.
            // Otherwise AppKit's offscreen row-height estimates change the scrollbar.
            scroll.scroll(byDeltaX: 0, deltaY: -10_000)
            let lastMessage = scroll.staticTexts.matching(NSPredicate(
                format: "value CONTAINS %@", "Cache only the local search index"
            )).firstMatch
            try require(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in lastMessage.isHittable }, object: lastMessage
            )], timeout: 10) == .completed, "Last fixture message did not hydrate")
            scroll.scroll(byDeltaX: 0, deltaY: 10_000)
            let firstMessage = scroll.staticTexts.matching(NSPredicate(
                format: "value == %@", "Plan the analytics dashboard"
            )).firstMatch
            try require(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in firstMessage.isHittable }, object: firstMessage
            )], timeout: 10) == .completed, "Transcript did not return to its initial viewport")
        }
        let comfortable = app.radioButtons["Comfortable"]
        try require((comfortable.value as? Int) == 1, "Comfortable density was not selected")
        try capture("transcript-view")
        let compact = app.radioButtons["Compact"]
        compact.click()
        try require((compact.value as? Int) == 1, "Compact density was not selected")
        try capture("compact-transcript")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw FixtureError.unavailable(message) }
    }
    private static func stabilizeFocus(_ query: XCUIElement) {
        // The first tab reaches the sidebar filter; the second reaches its list.
        query.typeKey(.tab, modifierFlags: [])
        query.typeKey(.tab, modifierFlags: [])
    }
    private enum FixtureError: Error { case unavailable(String) }
}
