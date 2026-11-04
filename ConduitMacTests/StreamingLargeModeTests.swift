import AppKit
import SwiftUI
import XCTest
@testable import UIKit
@testable import ConduitMac

/// D36 task 4: on Mac a streaming reply enters large-stream mode early and
/// promotes finished text into stable chunks, so the part that re-renders on
/// each tick stays near 8 KB. These tests drive the same pure policy the view
/// uses (`LargeStreamPromotion.nextStreamingBoundary`) and assert byte bounds,
/// never timing.
final class StreamingLargeModeTests: XCTestCase {
    private let policy = MarkdownLargeDocumentPolicy.self
    /// One reveal batch: `StreamingText.revealBatchSize` admits at most 18 characters per tick.
    private let revealStep = 18

    // MARK: Corpus

    /// Ordinary assistant prose: paragraphs of about 200 to 1,100 bytes.
    private func prose(bytes target: Int) -> String {
        var paragraphs: [String] = []
        var total = 0
        var index = 0
        while total < target {
            let sentences = 3 + (index * 7) % 14
            let paragraph = (0..<sentences)
                .map { "Sentence \(index).\($0) carries ordinary explanatory prose about the design." }
                .joined(separator: " ")
            paragraphs.append(paragraph)
            total += paragraph.utf8.count + 2
            index += 1
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private func table(rows: Int) -> String {
        let body = (0..<rows).map { "| row \($0) | value \($0) | some note text |" }
        return (["| Name | Value | Notes |", "|---|---|---|"] + body).joined(separator: "\n")
    }

    /// A fence with blank lines inside (they are not safe boundaries).
    private func fence(bytes target: Int) -> String {
        var lines = ["```swift"]
        var total = lines[0].utf8.count + 1
        var index = 0
        while total < target {
            let line = index % 10 == 9 ? "" : "let value\(index) = compute(\(index)) // fence body line"
            lines.append(line)
            total += line.utf8.count + 1
            index += 1
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    // MARK: Simulation

    private struct Run {
        /// The re-rendered tail in bytes after each tick's promotion.
        var tails: [Int] = []
        var sliceSizes: [Int] = []
        var promotedContent = ""
        var promotedBytes = 0
        var revealedBytes = 0
        var maxTail: Int { tails.max() ?? 0 }
    }

    /// Mirrors `StreamingText`: the scanner runs ahead of the reveal, the reveal
    /// advances one batch per tick, and promotion runs to a fixpoint each tick.
    /// Starts at the streaming threshold, as the view does when it crosses.
    private func simulate(_ source: String, startRevealed: Int? = nil) -> Run {
        let bytes = Array(source.utf8)
        var scanner = MarkdownStableBoundaryScanner()
        var boundaries = scanner.append(source)
        var run = Run()
        var revealed = min(startRevealed ?? policy.streamingThresholdBytes, bytes.count)
        var promoted = 0

        func promote() {
            while let next = LargeStreamPromotion.nextStreamingBoundary(
                promotedBytes: promoted,
                revealedBytes: revealed,
                boundaries: boundaries,
                constructIntervals: scanner.constructIntervals
            ) {
                run.sliceSizes.append(next - promoted)
                run.promotedContent += String(decoding: bytes[promoted..<next], as: UTF8.self)
                promoted = next
                boundaries.removeAll { $0 <= next }
            }
        }

        promote()
        run.tails.append(revealed - promoted)
        while revealed < bytes.count {
            revealed = min(revealed + revealStep, bytes.count)
            promote()
            run.tails.append(revealed - promoted)
        }
        run.promotedBytes = promoted
        run.revealedBytes = revealed
        return run
    }

    private func assertContentIntact(_ run: Run, of source: String, file: StaticString = #filePath, line: UInt = #line) {
        let prefix = String(decoding: Array(source.utf8).prefix(run.promotedBytes), as: UTF8.self)
        XCTAssertEqual(run.promotedContent, prefix, "promoted slices must equal the revealed prefix", file: file, line: line)
    }

    // MARK: Policy values

    func testMacStreamingValues() {
        XCTAssertEqual(policy.streamingThresholdBytes, 8_000)
        XCTAssertEqual(policy.streamingTailWindowBytes, 2_000)
        XCTAssertEqual(policy.streamingMinChunkBytes, 3_000)
    }

    func testStreamingThresholdIsByteBased() {
        XCTAssertFalse(policy.isLargeStreamingReply(String(repeating: "a", count: 7_999)))
        XCTAssertTrue(policy.isLargeStreamingReply(String(repeating: "a", count: 8_000)))
        // 4,000 two-byte characters are 8,000 bytes.
        XCTAssertTrue(policy.isLargeStreamingReply(String(repeating: "\u{00E9}", count: 4_000)))
    }

    func testDocumentThresholdStillDrivesSettledDocuments() {
        XCTAssertEqual(policy.documentThresholdBytes, 100_000)
        XCTAssertFalse(policy.isLargeDocument(String(repeating: "a", count: 99_999)))
        XCTAssertTrue(policy.isLargeDocument(String(repeating: "a", count: 100_000)))
        // A reply the stream treats as large is still an ordinary settled document.
        let streamSized = prose(bytes: 40_000)
        XCTAssertTrue(policy.isLargeStreamingReply(streamSized))
        XCTAssertFalse(policy.isLargeDocument(streamSized))
    }

    @MainActor
    func testSettledReplyBetweenThresholdsRendersAsOneDocument() {
        // Above the old threshold a settled MarkdownText parses only a 16 KB
        // preview; below it, the whole source.
        // A unique source per run: MarkdownRenderCache is process-wide, and a
        // cached source records no parse.
        let source = "Run \(UUID().uuidString).\n\n" + prose(bytes: 40_000)
        XCTAssertTrue(policy.isLargeStreamingReply(source))
        MarkdownParser.parseSourceSizes = []
        let window = HostedTestSupport.host(
            MarkdownText(source: source).frame(width: 600),
            size: NSSize(width: 640, height: 600)
        )
        defer { HostedTestSupport.tearDown(window) }
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(
            MarkdownParser.parseSourceSizes.contains { $0 > policy.previewBytes },
            "a settled reply under documentThresholdBytes must parse as one document"
        )
    }

    // MARK: Stable chunks

    func testChunkEqualityIgnoresTheGatewayClosure() {
        let first = LargeStreamChunkView(source: "same", gatewayMediaDataURL: { _ in nil })
        let second = LargeStreamChunkView(source: "same", gatewayMediaDataURL: { _ in "other" })
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, LargeStreamChunkView(source: "different"))
    }

    @MainActor
    func testStableChunksSkipTheirBodyAndNeverParseAgain() {
        // 300 chunks is more than MarkdownRenderCache holds (countLimit 256),
        // so a body that ran again on each tick would scan past the limit and
        // evict. The parent re-evaluates with a new gateway closure each tick.
        let tag = UUID().uuidString
        let chunks = (0..<300).map { index in
            "Chunk \(index) of run \(tag). " + String(repeating: "A finished chunk holds stable words. ", count: 8)
        }
        let model = TickModel()
        LargeStreamChunkView.bodyEvaluations = 0
        ChunkHarness.evaluations = 0
        MarkdownParser.parseSourceSizes = []
        let window = HostedTestSupport.host(
            ChunkHarness(model: model, chunks: chunks),
            size: NSSize(width: 640, height: 600)
        )
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 30) {
            LargeStreamChunkView.bodyEvaluations >= chunks.count
        }, "every chunk must mount")
        HostedTestSupport.settle(0.3)

        let bodies = LargeStreamChunkView.bodyEvaluations
        let parses = MarkdownParser.parseSourceSizes.count
        let evaluations = ChunkHarness.evaluations
        for _ in 0..<10 {
            model.generation += 1
            HostedTestSupport.settle(0.1)
        }
        XCTAssertGreaterThanOrEqual(ChunkHarness.evaluations - evaluations, 10, "the parent must re-evaluate on each tick")
        XCTAssertEqual(LargeStreamChunkView.bodyEvaluations, bodies, "an unchanged chunk must not run its body again")
        XCTAssertEqual(MarkdownParser.parseSourceSizes.count, parses, "no chunk may parse again across ticks")
    }

    // MARK: Tail bound

    func testProseStreamKeepsTailAtOrBelow8KBAtEveryStep() {
        let source = prose(bytes: 150_000)
        let run = simulate(source)
        XCTAssertGreaterThan(run.tails.count, 1_000, "the simulation must walk the whole stream")
        XCTAssertLessThanOrEqual(run.maxTail, 8_000)
        assertContentIntact(run, of: source)
        XCTAssertFalse(run.sliceSizes.isEmpty)
        // Chunk count stays bounded: no chunk under the minimum step.
        XCTAssertTrue(run.sliceSizes.allSatisfy { $0 >= policy.streamingMinChunkBytes })
        XCTAssertTrue(run.sliceSizes.allSatisfy { $0 <= policy.maxStreamChunkBytes })
    }

    func testReplyJumpingPastTheThresholdPromotesInOneTick() {
        // A view rebuilt for a 60 KB reply reveals everything at once; the first
        // tick must still leave a bounded tail.
        let source = prose(bytes: 60_000)
        let run = simulate(source, startRevealed: source.utf8.count)
        XCTAssertLessThanOrEqual(run.tails[0], 8_000)
        assertContentIntact(run, of: source)
    }

    /// Stated bound for text with no safe boundary: tail window plus two minimum
    /// steps (the hard cut), plus one reveal batch.
    private var unbrokenBound: Int {
        policy.streamingTailWindowBytes + 2 * policy.streamingMinChunkBytes + revealStep
    }

    func testLongUnbrokenParagraphTailIsBounded() {
        let source = String(repeating: "word ", count: 16_000) // 80 KB, one line
        let run = simulate(source)
        XCTAssertLessThanOrEqual(run.maxTail, unbrokenBound)
        XCTAssertLessThanOrEqual(unbrokenBound, 8_100)
        XCTAssertGreaterThan(run.promotedBytes, 60_000, "promotion must keep advancing")
        assertContentIntact(run, of: source)
    }

    func testLongTableTailIsBoundedByHardCuts() {
        let source = prose(bytes: 4_000) + "\n\n" + table(rows: 1_000) + "\n\nClosing paragraph."
        XCTAssertGreaterThan(source.utf8.count, 40_000)
        let run = simulate(source)
        XCTAssertLessThanOrEqual(run.maxTail, unbrokenBound)
        assertContentIntact(run, of: source)
    }

    func testLongCodeFenceTailGrowsWithTheFence() {
        // A fence cannot be split, so the tail holds the whole fence while it
        // streams. This pins the stated bound: fence length so far, plus one
        // minimum step, plus the tail window.
        let fenceText = fence(bytes: 12_000)
        let source = prose(bytes: 4_000) + "\n\n" + fenceText + "\n\n" + prose(bytes: 20_000)
        let fenceBytes = fenceText.utf8.count + 2
        let run = simulate(source)
        XCTAssertGreaterThan(run.maxTail, 8_000, "an open fence keeps the tail above the prose bound")
        XCTAssertLessThanOrEqual(
            run.maxTail,
            fenceBytes + policy.streamingMinChunkBytes + policy.streamingTailWindowBytes + revealStep
        )
        // Once the fence has closed and been promoted, the bound holds again.
        XCTAssertLessThanOrEqual(run.tails.last ?? 0, unbrokenBound)
        assertContentIntact(run, of: source)
    }

    func testKnownLimitFenceBeyondChunkWindowStallsPromotion() {
        // The window for one stable chunk is `maxStreamChunkBytes` (16,000). A
        // fence longer than that has no boundary inside the window and no safe
        // hard cut, so promotion stops for the rest of the stream. This is the
        // existing behavior (iOS shares it); a user decision is open.
        let fenceText = fence(bytes: 24_000)
        let source = prose(bytes: 4_000) + "\n\n" + fenceText + "\n\n" + prose(bytes: 40_000)
        let run = simulate(source)
        XCTAssertGreaterThan(run.tails.last ?? 0, 40_000)
        assertContentIntact(run, of: source)
    }

    // MARK: Crossing

    func testCrossingRevealsOnlyWhatTheSmallStreamHadShown() {
        let text = prose(bytes: 9_000)
        let shown = Array(text.prefix(300))
        XCTAssertEqual(StreamingText.charactersRevealedAtCrossing(visible: shown, in: text), 300)
        // Nothing shown, or a non-append target: reveal everything.
        XCTAssertNil(StreamingText.charactersRevealedAtCrossing(visible: [], in: text))
        XCTAssertNil(StreamingText.charactersRevealedAtCrossing(visible: Array("other text"), in: text))
    }

    // MARK: Diagrams and formulas

    func testDiagramsDrawInPlaceUntilTheDocumentThreshold() {
        XCTAssertTrue(StreamingText.drawsMarkupInPlace(revealedBytes: 8_000))
        XCTAssertTrue(StreamingText.drawsMarkupInPlace(revealedBytes: policy.documentThresholdBytes - 1))
        XCTAssertFalse(StreamingText.drawsMarkupInPlace(revealedBytes: policy.documentThresholdBytes))
    }
}

private final class TickModel: ObservableObject {
    @Published var generation = 0
}

/// Stands in for `StreamingBubble`: it re-evaluates on every tick and builds a
/// new gateway closure each time.
private struct ChunkHarness: View {
    nonisolated(unsafe) static var evaluations = 0
    @ObservedObject var model: TickModel
    let chunks: [String]

    var body: some View {
        let _ = { Self.evaluations += 1 }()
        let generation = model.generation
        VStack(alignment: .leading, spacing: 10) {
            LargeStreamChunkList(chunks: chunks, gatewayMediaDataURL: { _ in "tick \(generation)" })
        }
        .frame(width: 600)
    }
}
