import XCTest
@testable import TraceCore

final class SidebarRevealProgressTests: XCTestCase {
    func testThreeConsecutiveStableChecksWithoutOneSecondFloor() {
        var progress = SidebarRevealProgress()
        let row = CGRect(x: 0, y: 100, width: 200, height: 40)
        let viewport = CGRect(x: 0, y: 50, width: 200, height: 200)
        XCTAssertFalse(progress.observe(row: 2, rect: row, viewport: viewport))
        XCTAssertFalse(progress.observe(row: 2, rect: row, viewport: viewport))
        XCTAssertTrue(progress.observe(row: 2, rect: row, viewport: viewport))
    }
    func testIndexGeometryAndClippingInterruptConsecutiveStability() {
        var progress = SidebarRevealProgress()
        let rect = CGRect(x: 0, y: 100, width: 200, height: 40)
        let viewport = CGRect(x: 0, y: 50, width: 200, height: 200)
        for _ in 0..<2 { XCTAssertFalse(progress.observe(row: 2, rect: rect, viewport: viewport)) }
        XCTAssertFalse(progress.observe(row: 3, rect: rect, viewport: viewport))
        XCTAssertFalse(progress.observe(row: 3, rect: rect, viewport: viewport.offsetBy(dx: 0, dy: 1)))
        XCTAssertFalse(progress.observe(row: 3, rect: rect, viewport: CGRect(x: 0, y: 120, width: 200, height: 200)))
        XCTAssertFalse(progress.observe(row: 3, rect: rect, viewport: viewport))
        XCTAssertFalse(progress.observe(row: 3, rect: rect, viewport: viewport))
        XCTAssertTrue(progress.observe(row: 3, rect: rect, viewport: viewport))
    }
}
