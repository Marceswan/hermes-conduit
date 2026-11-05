import XCTest
@testable import ConduitMac

final class MacNewChatIntentTests: XCTestCase {
    func testNoProfileNoMessage() throws {
        XCTAssertEqual(try NewChatIntentCore.request(profileID: nil, message: nil, knownProfiles: ["default"]),
                       .newChat(profile: nil, message: nil))
    }

    func testKnownProfileAndMessagePassThrough() throws {
        XCTAssertEqual(try NewChatIntentCore.request(profileID: "work", message: "hi", knownProfiles: ["default", "work"]),
                       .newChat(profile: "work", message: "hi"))
    }

    func testBlankMessageBecomesNil() throws {
        XCTAssertEqual(try NewChatIntentCore.request(profileID: nil, message: "  \n", knownProfiles: []),
                       .newChat(profile: nil, message: nil))
    }

    func testUnknownProfileThrowsAUserVisibleError() {
        XCTAssertThrowsError(try NewChatIntentCore.request(profileID: "gone", message: "x", knownProfiles: ["default"])) { error in
            guard case MacIntentError.unknownProfile("gone") = error else { return XCTFail("\(error)") }
        }
    }

    func testMessageIsCappedLikeAService() throws {
        let long = String(repeating: "a", count: MacServiceText.limit + 10)
        let request = try NewChatIntentCore.request(profileID: nil, message: long, knownProfiles: [])
        guard case .newChat(_, let text?) = request else { return XCTFail() }
        XCTAssertTrue(text.hasSuffix("[truncated]"))
    }

    @MainActor
    func testPerformEnqueuesAndNeverSends() async throws {
        _ = MacIntentInbox.shared.take()
        let intent = NewChatIntent(profile: nil, message: "draft")
        _ = try await intent.perform()
        XCTAssertEqual(MacIntentInbox.shared.take(), .newChat(profile: nil, message: "draft"))
    }
}
