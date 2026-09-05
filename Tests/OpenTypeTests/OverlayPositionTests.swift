import XCTest
@testable import OpenType

final class OverlayPositionTests: XCTestCase {
    func testRestoresDraggedPositionOnAnOffsetDisplay() {
        let screen = CGRect(x: -1500, y: 30, width: 1500, height: 900)
        let frame = CGRect(x: -1200, y: 400, width: 500, height: 160)
        let anchor = OverlayPosition.anchor(for: frame, in: screen)
        XCTAssertEqual(OverlayPosition.frame(size: frame.size, screen: screen, anchor: anchor), frame)
    }

    func testExpansionKeepsBottomAndCenterWhereThereIsRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = CGRect(x: 600, y: 100, width: 400, height: 100)
        let grown = OverlayPosition.frame(size: CGSize(width: 700, height: 600), screen: screen,
                                          anchor: OverlayPosition.anchor(for: frame, in: screen))
        XCTAssertEqual(grown.midX, frame.midX)
        XCTAssertEqual(grown.minY, frame.minY)
    }

    func testLargeCardNearScreenEdgeStaysVisible() {
        let screen = CGRect(x: 1920, y: 30, width: 1280, height: 770)
        let frame = OverlayPosition.frame(size: CGSize(width: 700, height: 650), screen: screen,
                                         anchor: CGPoint(x: 0.98, y: 0.92))
        XCTAssertTrue(screen.contains(frame))
    }

    func testSavedAnchorCanBeReusedOnSmallerScreen() {
        let oldScreen = CGRect(x: -2000, y: 0, width: 2000, height: 1400)
        let anchor = OverlayPosition.anchor(for: CGRect(x: -1900, y: 900, width: 500, height: 150), in: oldScreen)
        let screen = CGRect(x: 0, y: 25, width: 1000, height: 700)
        let frame = OverlayPosition.frame(size: CGSize(width: 700, height: 600), screen: screen, anchor: anchor)
        XCTAssertTrue(screen.contains(frame))
    }
}
