import XCTest
@testable import ConduitMac

/// Mac policy and markdown regression guards for D36.
/// The backdrop must stay still on Mac, whatever the scene state.
/// The image and syntax paths must keep their output after the regex and
/// keyword sets move to static storage.
final class MacStillBackdropTests: XCTestCase {
    func testBackdropDoesNotAnimateOnMacWhenAllConditionsAllow() {
        XCTAssertFalse(ConduitBackdropMotionPolicy.shouldAnimate(
            drifts: true,
            sceneIsActive: true,
            reduceMotion: false,
            lowPowerMode: false,
            idle: false,
            thermalState: .nominal
        ))
    }

    func testSyntaxHighlighterKeepsSourceText() {
        let source = "let x = 1 // note"
        let result = SyntaxHighlighter.highlight(source, language: "swift")
        XCTAssertEqual(String(result.characters), source)
    }

    func testImageMarkdownParsesPlainForm() {
        let document = MarkdownParser.parseDocument("![alt](https://example.com/a.png)")
        XCTAssertEqual(document.blocks, [.image(url: "https://example.com/a.png", alt: "alt")])
    }

    func testImageMarkdownParsesTitleForm() {
        let document = MarkdownParser.parseDocument("![alt](https://example.com/a.png \"t\")")
        XCTAssertEqual(document.blocks, [.image(url: "https://example.com/a.png", alt: "alt")])
    }
}
