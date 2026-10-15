import Foundation

/// Pure helpers for "Ask About Window": output size, encode ladder, file name.
enum MacWindowCaptureMath {
    static let maxLongestSide = 2560

    enum Encoding: Equatable {
        case png
        case jpeg(quality: Double, scale: Double)
    }

    enum Failure: Equatable { case noPicture, encodeFailed, pickerFailed }

    /// Caps the longest side at `cap`, keeps aspect, never upscales, minimum 1 px.
    static func targetPixelSize(width: Int, height: Int, cap: Int = maxLongestSide) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > cap, longest > 0 else { return (max(width, 1), max(height, 1)) }
        let scale = Double(cap) / Double(longest)
        return (max(Int((Double(width) * scale).rounded()), 1), max(Int((Double(height) * scale).rounded()), 1))
    }

    /// PNG when it fits in 80% of the limit; otherwise a JPEG ladder.
    static func encodePlan(pngByteCount: Int, limitBytes: Int64) -> [Encoding] {
        if Double(pngByteCount) <= Double(limitBytes) * 0.8 { return [.png] }
        return [.jpeg(quality: 0.85, scale: 1.0), .jpeg(quality: 0.7, scale: 0.75), .jpeg(quality: 0.5, scale: 0.5625)]
    }

    /// Base name (no extension) for the staged screenshot.
    static func filename(windowTitle: String?, appName: String?) -> String {
        func clean(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = [clean(appName), clean(windowTitle)].filter { !$0.isEmpty }
        let joined = parts.isEmpty ? "Window" : parts.joined(separator: " - ")
        return String(joined.prefix(60))
    }
}
