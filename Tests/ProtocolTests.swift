import XCTest
@testable import Peripherals

/// Expected values come from the Python prototypes (razeroled.py, razerlight.py),
/// which were checked against the real keyboard and mouse.
final class ProtocolTests: XCTestCase {
    func testReportLayoutAndChecksum() {
        let report = RazerReport.make(0x17, 0x0D, [6, 6])
        XCTAssertEqual(report.count, 90)
        XCTAssertEqual(Array(report[0..<10]), [0, 0x1F, 0, 0, 0, 2, 0x17, 0x0D, 6, 6])
        XCTAssertEqual(report[88], 24)
        XCTAssertEqual(report[89], 0)
    }

    func testPackPutsTheLeftPixelInTheLowNibble() {
        let image = GreyImage(width: 4, height: 2, pixels: [0x10, 0xF0, 0x80, 0x00, 0xFF, 0x11, 0x22, 0x33])
        XCTAssertEqual(image.packed(), [241, 8, 31, 50])
    }

    func testClockRecordMatchesThePrototype() {
        XCTAssertEqual(Screens.clockRecord, [6, 113, 117, 113, 5, 0, 0, 8, 10, 150, 10, 14, 14, 156, 14, 11, 7, 153, 7])
    }

    func testLiveValuesUseFixedSlots() {
        let buffer = Screens.liveValues(hour: 13, minute: 42, second: 56, cpu: 37, memory: 81)
        XCTAssertEqual(buffer.count, 40)
        XCTAssertEqual(Array(buffer[0...1]), [1, 37])
        XCTAssertEqual(Array(buffer[20...21]), [5, 81])
        XCTAssertEqual(Array(buffer[30...34]), [7, 1, 42, 56, 1])
    }

    func testTwelveHourEdges() {
        XCTAssertEqual(Array(Screens.liveValues(hour: 0, minute: 5, second: 0, cpu: 0, memory: 0)[30...34]), [7, 12, 5, 0, 0])
        XCTAssertEqual(Array(Screens.liveValues(hour: 12, minute: 0, second: 0, cpu: 0, memory: 0)[30...34]), [7, 12, 0, 0, 1])
        XCTAssertEqual(Array(Screens.liveValues(hour: 11, minute: 59, second: 0, cpu: 0, memory: 0)[30...34]), [7, 11, 59, 0, 0])
    }

    func testArtworkAdjustmentMatchesRazerlight() {
        // Each case is (pixel, gamma) -> razerlight's colour. A dark grid picks
        // gamma 0.75, a bright one 0.9, so each pixel is tested in a grid of its own.
        let cases: [(RGB, RGB)] = [
            ((0.5, 0.2, 0.1), (0.5358867312681466, 0.1798937418573476, 0.06122941205374788)),
            ((0.05, 0.03, 0.04), (0.10573712634405642, 0.06254784861543394, 0.08414248747974518)),
            ((0.9, 0.9, 0.9), (0.9095325760829622, 0.9095325760829622, 0.9095325760829622)),
        ]
        for (input, expected) in cases {
            let out = ArtworkGrid.adjust([[input]])[0][0]
            XCTAssertEqual(out.r, expected.r, accuracy: 1e-9)
            XCTAssertEqual(out.g, expected.g, accuracy: 1e-9)
            XCTAssertEqual(out.b, expected.b, accuracy: 1e-9)
        }
    }

    func testFramesAreTheRightSize() {
        let frame = Screens.nowPlaying(.init(id: "x", name: "never do", artist: "Olivia Rodrigo", album: "GUTS"), cover: nil)
        XCTAssertEqual(frame.width, 232)
        XCTAssertEqual(frame.packed().count, 232 * 64 / 2)
        XCTAssertTrue(frame.pixels.contains { $0 > 200 }, "title should be drawn in white")
        XCTAssertEqual(BootAnimation.frame(1.0).packed().count, 0x2000)
    }

    func testDitherOnlyUsesPanelLevels() {
        let ramp = (0..<64).map { Float($0 * 4) }
        XCTAssertTrue(Artwork.dither(ramp, width: 64, height: 1).allSatisfy { $0 % 17 == 0 })
    }
}
