import XCTest

/// The frozen sign-in copies in ConduitMac/Login keep strings that upstream deleted from the catalog.
/// Every literal key they pass to AppLocalization or a SwiftUI text control must exist in the catalog.
final class LoginCopyStringKeysTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func catalogKeys() throws -> Set<String> {
        let url = repoRoot.appendingPathComponent("Conduit/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(object?["strings"] as? [String: Any])
        return Set(strings.keys)
    }

    /// Literal keys: no interpolation, no concatenation.
    static func literalKeys(in source: String) -> [String] {
        let pattern = #"(?:AppLocalization\.string|Text|Button|Label|Section|TextField|SecureField|Toggle|navigationTitle|Menu)\(\s*"((?:[^"\\]|\\.)*)"\s*([,)+])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: source),
                  let endRange = Range(match.range(at: 2), in: source) else { return nil }
            let raw = String(source[keyRange])
            if raw.contains("\\(") || source[endRange] == "+" || raw.isEmpty { return nil }
            return raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
        }
    }

    /// Technical literals that were never in the catalog (also absent at macos e27dc4db): a URL
    /// placeholder and the two scheme names.
    private static let neverLocalized: Set<String> = ["https://hermes.example", "HTTP", "HTTPS"]

    func testEveryLiteralKeyInTheLoginCopiesIsInTheCatalog() throws {
        let keys = try catalogKeys()
        let dir = repoRoot.appendingPathComponent("ConduitMac/Login")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        var missing: [String] = []
        var checked = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for key in Self.literalKeys(in: source) {
                checked += 1
                if !keys.contains(key), !Self.neverLocalized.contains(key) { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertGreaterThan(checked, 50, "the key scan found too few literals")
        XCTAssertTrue(missing.isEmpty, "Keys missing from Conduit/Localizable.xcstrings:\n" + missing.joined(separator: "\n"))
    }

    func testTheScannerSkipsInterpolatedAndConcatenatedLiterals() {
        let source = #"""
        Text("Plain key")
        Text("Value \(count)")
        Text("Part one " + other)
        Button("Done") { }
        """#
        XCTAssertEqual(Self.literalKeys(in: source), ["Plain key", "Done"])
    }
}
