import XCTest

/// Flags icon-only buttons under Conduit/Views that have no spoken name.
/// Heuristic: an `Image(systemName:` inside a button label with no
/// accessibilityLabel/Hidden, Text, Label or help nearby.
final class AccessibilityLabelAuditTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func allowlist() -> Set<String> {
        let url = repoRoot.appendingPathComponent("docs/macos/a11y-audit-allowlist.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { entries.insert(line) }
        }
        return entries
    }

    func testIconOnlyButtonsHaveAccessibilityLabels() throws {
        let viewsDir = repoRoot.appendingPathComponent("Conduit/Views")
        let allowed = allowlist()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil))
        let buttonMarkers = ["Button(", "Button {", "} label: {"]
        let followMarkers = [".accessibilityLabel(", ".accessibilityHidden(true)", "Text(", "Label(", ".help("]
        var flagged: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            let rel = "Conduit/Views" + url.path.replacingOccurrences(of: viewsDir.path, with: "")
            for (i, line) in lines.enumerated() where line.contains("Image(systemName:") {
                let before = lines[max(0, i - 4)..<i]
                guard before.contains(where: { l in buttonMarkers.contains { l.contains($0) } }) else { continue }
                let after = lines[(i + 1)..<min(lines.count, i + 9)]
                if after.contains(where: { l in followMarkers.contains { l.contains($0) } }) { continue }
                if before.contains(where: { $0.contains("Label(") || $0.contains("Text(") }) { continue }
                if line.contains(".accessibilityLabel(") || line.contains(".accessibilityHidden(true)") { continue }
                let key = "\(rel):\(i + 1)"
                if allowed.contains(key) { continue }
                flagged.append("\(key): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(flagged.isEmpty, "Icon-only buttons without accessibility labels (\(flagged.count)):\n" + flagged.joined(separator: "\n"))
    }
}
