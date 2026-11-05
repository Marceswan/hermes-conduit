import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Mounted `MarkdownText` is the ground truth for what a row draws; the
/// projection (`MacChatFindText`) must report the same number of hits for each
/// common block type, so the "N of M" count matches what the user can see.
@MainActor
final class MacChatFindParityTests: XCTestCase {
    private struct Sample {
        let name: String
        let markdown: String
        let query: String
        var gateway = false
    }

    private let samples: [Sample] = [
        Sample(name: "plain", markdown: "The needle is in the haystack. Another needle.", query: "needle"),
        Sample(name: "emphasis", markdown: "A **needle** and *needle* and `needle` and ~~needle~~.", query: "needle"),
        Sample(name: "link", markdown: "See [needle docs](https://example.com/needle/guide) for the needle.", query: "needle"),
        Sample(name: "heading", markdown: "# needle title\n\nBody with a needle.", query: "needle"),
        // Flow path: list and quote markers are real characters.
        Sample(name: "list", markdown: "- first needle\n- second item\n- third needle", query: "needle"),
        Sample(name: "ordered", markdown: "1. needle one\n2. two\n3. needle three", query: "needle"),
        Sample(name: "tasks", markdown: "- [ ] needle todo\n- [x] done needle", query: "needle"),
        Sample(name: "quote", markdown: "> a quoted needle\n> and another needle", query: "needle"),
        Sample(name: "nestedQuote", markdown: "> outer needle\n>> inner needle", query: "needle"),
        // Rich path: markers are separate views, not text-view characters.
        Sample(name: "table", markdown: "| col | needle |\n|---|---|\n| needle | other |\n", query: "needle"),
        Sample(name: "code", markdown: "Before needle\n\n```swift\nlet needle = 1\n```\n\nAfter needle", query: "needle"),
        Sample(name: "listBesideCode", markdown: "- needle one\n- two\n\n```\nneedle\n```", query: "needle"),
        Sample(name: "quoteBesideCode", markdown: "> needle quoted\n\n```\nneedle\n```", query: "needle"),
        Sample(name: "listMarkerQuery", markdown: "- first\n- second\n\n```\ncode\n```", query: "\u{2022}"),
        Sample(name: "callout", markdown: "> [!NOTE]\n> a needle in a note\n\nplain needle", query: "needle"),
        Sample(name: "directiveCallout", markdown: "::: note\na needle in a note\n:::\n\nplain needle", query: "needle"),
        Sample(name: "columns", markdown: "::: columns\nleft needle\n::: column\nright needle\n:::", query: "needle"),
        Sample(name: "image", markdown: "![needle alt](https://example.com/a.png)\n\nafter needle", query: "needle"),
        Sample(name: "math", markdown: "$$needle + 1$$\n\nafter needle", query: "needle"),
        Sample(name: "gatewayMedia", markdown: "see MEDIA:/tmp/needle.png here\n\nafter needle", query: "needle", gateway: true),
        Sample(name: "diacritics", markdown: "Un café, des CAFÉS et du cafe.", query: "cafe"),
    ]

    private func mountedCount(_ sample: Sample) -> Int {
        let controller = MacChatFindController()
        let resolver: ((String) async -> String?)? = sample.gateway ? { _ in nil } : nil
        let window = HostedTestSupport.host(
            MarkdownText(source: sample.markdown, gatewayMediaDataURL: resolver)
                .macChatFindRow(id: "m", engine: ChatScrollEngine())
                .environment(\.macChatFindController, controller)
                .frame(width: 520),
            size: NSSize(width: 520, height: 600)
        )
        defer { HostedTestSupport.tearDown(window) }
        _ = HostedTestSupport.waitUntil { controller.registry.mountedViewCount > 0 }
        HostedTestSupport.settle(0.15)
        return controller.registry.views(for: "m")
            .map { MacChatFindMatcher.ranges(of: sample.query, in: $0.string).count }
            .reduce(0, +)
    }

    private func projectedCount(_ sample: Sample) -> Int {
        let message = ChatMessage(id: "m", role: .assistant, content: sample.markdown, timestamp: "")
        return MacChatFindText.searchableText(for: message)
            .map { MacChatFindMatcher.ranges(of: sample.query, in: $0).count } ?? 0
    }

    func testProjectedHitCountEqualsTheHitsInTheMountedViews() {
        for sample in samples {
            XCTAssertEqual(projectedCount(sample), mountedCount(sample),
                           "\(sample.name): projection and drawn text disagree")
        }
    }
}
