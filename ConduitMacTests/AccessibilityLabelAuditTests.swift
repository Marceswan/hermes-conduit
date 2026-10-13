import XCTest

/// Flags icon-only buttons/menus under Conduit/Views that have no spoken name.
///
/// Heuristic: an `Image(systemName:` within 4 lines after a `Button(`,
/// `Button {` or `} label: {` line (the "owner"). The scan covers the owner's
/// own scope: forward from the image until a line indented less than the
/// owner, the next `Button`/`Menu` (or, once the label closure has closed, `Image(systemName:`), or 25 lines. A
/// `.accessibilityLabel(`, `.accessibilityHidden(true)` or `.help(` anywhere
/// in that span clears it. `Text(`/`Label(` clear it only inside the label
/// closure itself (between the owner line and its closing brace), never
/// Menu/Button content that precedes the owner.
///
/// Allowlist format (docs/macos/a11y-audit-allowlist.txt), one per line:
///     path | trimmed source line text   # reason
/// Keyed by content so upstream line shifts do not matter.
final class AccessibilityLabelAuditTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func indent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func stripComment(_ raw: String) -> String {
        let chars = Array(raw)
        for (i, c) in chars.enumerated() where c == "#" {
            if i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                return String(chars[..<i])
            }
        }
        return raw
    }

    private func allowlist() throws -> [String] {
        let url = repoRoot.appendingPathComponent("docs/macos/a11y-audit-allowlist.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Missing allowlist file: \(url.path)")
            return []
        }
        return text.components(separatedBy: "\n").compactMap { raw in
            let line = Self.stripComment(raw).trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    private func flaggedSites() throws -> [(key: String, display: String)] {
        let viewsDir = repoRoot.appendingPathComponent("Conduit/Views")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil))
        let ownerMarkers = ["Button(", "Button {", "} label: {"]
        let clearing = [".accessibilityLabel(", ".accessibilityHidden(true)", ".help("]
        let namers = ["Text(", "Label("]
        var flagged: [(String, String)] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let rel = "Conduit/Views" + url.path.replacingOccurrences(of: viewsDir.path, with: "")
            for (i, line) in lines.enumerated() where line.contains("Image(systemName:") {
                guard let owner = (max(0, i - 4)..<i).reversed().first(where: { j in
                    ownerMarkers.contains { lines[j].contains($0) }
                }) else { continue }
                let ownerIndent = Self.indent(lines[owner])
                // A name on the image line itself (e.g. `HStack { Text(..); Image(..) }`).
                var named = clearing.contains(where: { line.contains($0) }) || namers.contains(where: { line.contains($0) })
                // Label closure content before the image.
                if lines[owner..<i].contains(where: { l in namers.contains { l.contains($0) } && !ownerMarkers.contains { l.contains($0) } }) { named = true }
                var inLabelClosure = true
                var k = i + 1
                while !named, k < lines.count, k <= i + 25 {
                    let l = lines[k]
                    let trimmed = l.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let ind = Self.indent(l)
                        if ind < ownerIndent { break }
                        if !inLabelClosure, l.contains("Image(systemName:") { break }
                        if ind <= ownerIndent, l.contains("Button") || l.contains("Menu") { break }
                        if clearing.contains(where: { l.contains($0) }) { named = true; break }
                        if inLabelClosure {
                            if ind <= ownerIndent, trimmed.hasPrefix("}") { inLabelClosure = false }
                            else if namers.contains(where: { l.contains($0) }) { named = true; break }
                        }
                    }
                    k += 1
                }
                if !named {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    flagged.append(("\(rel) | \(text)", "\(rel):\(i + 1): \(text)"))
                }
            }
        }
        return flagged
    }

    func testIconOnlyButtonsHaveAccessibilityLabels() throws {
        let allowed = try allowlist()
        let flagged = try flaggedSites()
        let allowedSet = Set(allowed)
        let unresolved = flagged.filter { !allowedSet.contains($0.key) }
        let flaggedKeys = Set(flagged.map(\.key))
        let stale = allowed.filter { !flaggedKeys.contains($0) }

        XCTAssertTrue(unresolved.isEmpty,
            "Icon-only controls without accessibility labels (\(unresolved.count)):\n" + unresolved.map(\.display).joined(separator: "\n"))
        XCTAssertTrue(stale.isEmpty,
            "Stale allowlist entries match no flagged site (remove them):\n" + stale.joined(separator: "\n"))
    }
}
