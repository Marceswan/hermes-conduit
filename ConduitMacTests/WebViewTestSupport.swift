import WebKit
import XCTest
@testable import ConduitMac

/// A frame that says whether it is the main frame. WebKit builds the real
/// one; a test cannot. `-[WKFrameInfo dealloc]` releases an object that a
/// stub never has and traps, so each stub stays alive until the process ends.
final class StubFrameInfo: WKFrameInfo {
    private static var kept: [StubFrameInfo] = []
    private let stubIsMainFrame: Bool

    init(isMainFrame: Bool) {
        stubIsMainFrame = isMainFrame
        super.init()
        Self.kept.append(self)
    }

    override var isMainFrame: Bool { stubIsMainFrame }
}

/// The navigation a delegate is asked about. WebKit builds the real one;
/// a test states the URL, the way the user got there and the frame.
final class StubNavigationAction: WKNavigationAction {
    private let stubRequest: URLRequest
    private let stubType: WKNavigationType
    private let stubFrame: StubFrameInfo?

    init(url: String, type: WKNavigationType, isMainFrame: Bool? = nil) {
        stubRequest = URLRequest(url: URL(string: url)!)
        stubType = type
        stubFrame = isMainFrame.map { StubFrameInfo(isMainFrame: $0) }
        super.init()
    }

    override var request: URLRequest { stubRequest }
    override var navigationType: WKNavigationType { stubType }
    override var targetFrame: WKFrameInfo? { stubFrame }
}

/// Asks a delegate the question WebKit asks before a navigation, and
/// returns the answer it gives.
@MainActor
func decidePolicy(
    _ url: String,
    type: WKNavigationType,
    isMainFrame: Bool? = nil,
    delegate: WKNavigationDelegate
) async -> WKNavigationActionPolicy {
    let action = StubNavigationAction(url: url, type: type, isMainFrame: isMainFrame)
    return await withCheckedContinuation { continuation in
        delegate.webView?(WKWebView(), decidePolicyFor: action) { policy in
            continuation.resume(returning: policy)
        }
    }
}
