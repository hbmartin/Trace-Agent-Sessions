import XCTest

@MainActor
final class TraceUITests: XCTestCase {
    func testOnboardingExplainsLocalIndexAndScope() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Find any agent session."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Build Index"].exists)
        XCTAssertTrue(app.staticTexts["What should be searchable?"].exists)
    }
}
