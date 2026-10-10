import AppKit
import SnapshotTesting
import XCTest

@MainActor
final class TraceSnapshotTests: XCTestCase {
    private var records: Bool { ProcessInfo.processInfo.environment["TRACE_SNAPSHOT_RECORD"] == "1" }
    private let recordedReferences = FileManager.default.temporaryDirectory
        .appendingPathComponent("TraceRecordedSnapshots-\(UUID())")

    func testLightShowcase() throws { try capture(appearance: "light") }
    func testDarkShowcase() throws { try capture(appearance: "dark") }

    private func capture(appearance: String) throws {
        // Expected recording notices must return so the remaining screens are captured.
        continueAfterFailure = records
        // Bundle comparison references so the sandboxed runner need not read an external volume.
        let references = records ? recordedReferences : try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "__Snapshots__", withExtension: nil),
            "Snapshot references are missing from the test bundle; rebuild the snapshot target."
        )
        let app = try TraceShowcaseFixture.makeApp(test: self, appearance: appearance)
        try TraceShowcaseFixture.captureScreens(app: app) { name in
            // Window screenshots capture the desktop rectangle; keep Trace in front
            // even if another application became active between fixture steps.
            app.activate()
            let window = app.windows.firstMatch
            XCTAssertEqual(window.frame.width, 1180, accuracy: 0.5, "Snapshot window must retain its fixed width")
            let png = try stableScreenshot(window)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            let image = try XCTUnwrap(NSImage(data: png))
            let environment = try SnapshotEnvironment(
                scale: Double(bitmap.pixelsWide) / window.frame.width,
                windowWidth: window.frame.width, windowHeight: window.frame.height
            )
            let metadata = references.appendingPathComponent("environment.json")
            if records {
                try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(environment).write(to: metadata, options: .atomic)
            } else {
                let expected = try JSONDecoder().decode(SnapshotEnvironment.self, from: Data(contentsOf: metadata))
                XCTAssertEqual(environment, expected,
                    "Snapshot environment changed. Review and re-record all eight baselines with Scripts/run-snapshot-tests.sh --record.")
            }
            let assertImage = {
                // A fixed test name keeps filenames stable if test organization changes.
                if let failure = verifySnapshot(
                    of: image, as: .image(precision: 1, perceptualPrecision: 1), named: "\(appearance)-\(name)",
                    record: self.records ? .all : .never,
                    snapshotDirectory: references.path, testName: "showcase"
                ) { XCTFail(failure) }
            }
            if records {
                let options = XCTExpectedFailure.Options()
                options.issueMatcher = { issue in
                    issue.type == .assertionFailure
                        && issue.compactDescription.contains("Record mode is on. Automatically recorded snapshot")
                }
                XCTExpectFailure("Explicitly recording a reviewed visual baseline", options: options, failingBlock: assertImage)
            } else {
                assertImage()
            }
        }
        // The shell promotes both appearances together only after xcodebuild succeeds.
        if records { print("TRACE_SNAPSHOT_RECORDED_DIRECTORY=\(recordedReferences.path)") }
    }

    /// Allow layout and hydration to settle, and exclude transient animation/caret frames.
    private func stableScreenshot(_ window: XCUIElement) throws -> Data {
        let deadline = Date().addingTimeInterval(10)
        var previous: Data?
        var stableSince: Date?
        while Date() < deadline {
            let current = window.screenshot().pngRepresentation
            if current == previous {
                stableSince = stableSince ?? Date()
                // Offscreen AppKit row measurements can update the scrollbar after
                // the first few identical frames. Require a complete quiet interval.
                if Date().timeIntervalSince(stableSince!) >= 2 { return current }
            } else {
                stableSince = nil
            }
            previous = current
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        throw SnapshotError.unstableWindow
    }
    private enum SnapshotError: Error { case unstableWindow }
}

private struct SnapshotEnvironment: Codable, Equatable {
    let macOS: String
    let xcode: String
    let architecture: String
    let scale: Double
    let windowWidth: Double
    let windowHeight: Double

    init(scale: Double, windowWidth: Double, windowHeight: Double) throws {
        macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let environment = ProcessInfo.processInfo.environment
        guard let version = environment["TRACE_SNAPSHOT_XCODE_VERSION"],
              let build = environment["TRACE_SNAPSHOT_XCODE_BUILD"],
              let versionNumber = Int(version), !build.contains("$(") else {
            throw EnvironmentError.missingXcodeVersion
        }
        xcode = "\(versionNumber / 100).\((versionNumber % 100) / 10) (\(build))"
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "x86_64"
        #endif
        self.scale = scale; self.windowWidth = windowWidth; self.windowHeight = windowHeight
    }

    private enum EnvironmentError: Error { case missingXcodeVersion }
}
