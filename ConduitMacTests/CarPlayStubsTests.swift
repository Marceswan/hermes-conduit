import XCTest
@testable import ConduitMac

/// `CarPlayStubs.swift` is the Mac twin of `CarPlayVoiceControls` (upstream
/// `CarPlayVoiceTemplateFactory.swift`) and `CarPlayVoiceCoordinator`: it has
/// to stay in step with the upstream struct, or code that moves to the Mac
/// build later meets a missing field. The test reads both sources.
final class CarPlayStubsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The stored `var` names and defaults of `struct CarPlayVoiceControls`.
    private func controlsFields(in relativePath: String) throws -> [String] {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct CarPlayVoiceControls: Equatable {"))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n}\n"))
        let body = rest[..<end.lowerBound]
        return body.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("var "), !trimmed.hasSuffix("{") else { return nil }
            return trimmed
        }
    }

    func testControlsStructHasTheFieldsOfTheUpstreamStruct() throws {
        let upstream = try controlsFields(in: "Conduit/CarPlay/CarPlayVoiceTemplateFactory.swift")
        let twin = try controlsFields(in: "ConduitMac/Stubs/CarPlayStubs.swift")
        XCTAssertFalse(upstream.isEmpty)
        XCTAssertEqual(twin, upstream)
    }

    func testControlsDefaultsMatchUpstream() {
        let controls = CarPlayVoiceControls.initial
        XCTAssertTrue(controls.isClassic)
        XCTAssertFalse(controls.isMicrophoneMuted)
        XCTAssertNil(controls.errorIssue)
        XCTAssertNil(controls.chatTitle)
        XCTAssertTrue(controls.canStopReply, "upstream: a reply can be stopped unless GPT-Live speaks")
    }
}
