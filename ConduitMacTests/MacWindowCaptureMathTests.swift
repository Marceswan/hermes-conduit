import XCTest
@testable import ConduitMac

final class MacWindowCaptureMathTests: XCTestCase {
    func testDownscalesLongestSideAndKeepsAspect() {
        let s = MacWindowCaptureMath.targetPixelSize(width: 5120, height: 2880)
        XCTAssertEqual(s.width, 2560)
        XCTAssertEqual(s.height, 1440)
    }

    func testTallWindowCapsHeight() {
        let s = MacWindowCaptureMath.targetPixelSize(width: 800, height: 6400)
        XCTAssertEqual(s.height, 2560)
        XCTAssertEqual(s.width, 320)
    }

    func testNeverUpscalesAndNeverReachesZero() {
        let small = MacWindowCaptureMath.targetPixelSize(width: 640, height: 480)
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 480)
        let sliver = MacWindowCaptureMath.targetPixelSize(width: 5000, height: 1)
        XCTAssertEqual(sliver.width, 2560)
        XCTAssertEqual(sliver.height, 1)
    }

    func testPNGWhenWithinEightyPercent() {
        let limit = AttachmentSizeLimit.byteLimit(megabytes: 16)
        XCTAssertEqual(MacWindowCaptureMath.encodePlan(pngByteCount: Int(limit) / 2, limitBytes: limit), [.png])
    }

    func testJPEGLadderWhenPNGTooBig() {
        let limit = AttachmentSizeLimit.byteLimit(megabytes: 8)
        let plan = MacWindowCaptureMath.encodePlan(pngByteCount: Int(limit), limitBytes: limit)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.first, .jpeg(quality: 0.85, scale: 1.0))
    }

    func testFilename() {
        XCTAssertEqual(MacWindowCaptureMath.filename(windowTitle: "a/b: c", appName: "Safari"), "Safari - a-b- c")
        XCTAssertEqual(MacWindowCaptureMath.filename(windowTitle: nil, appName: nil), "Window")
        XCTAssertEqual(MacWindowCaptureMath.filename(windowTitle: "  ", appName: "Xcode"), "Xcode")
        XCTAssertLessThanOrEqual(MacWindowCaptureMath.filename(windowTitle: String(repeating: "x", count: 200), appName: nil).count, 60)
    }
}
