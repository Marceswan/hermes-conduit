import AppKit

/// Accessibility facts about the element under the pointer.
struct HoverElementSnapshot: Equatable {
    var role: NSAccessibility.Role?
    var label: String?
    var title: String?
    var help: String?
    /// SwiftUI only. A symbol-backed control carries the symbol name here, so
    /// non-empty means an icon. Empty is ambiguous (text button, or an icon
    /// from an asset or NSImage). Nil means AppKit, where `title` decides.
    var imageIdentifier: String?
    var isEnabled: Bool
    /// Screen coordinates (AppKit, bottom-left origin).
    var frame: CGRect

    init(role: NSAccessibility.Role?, label: String? = nil, title: String? = nil, help: String? = nil,
         imageIdentifier: String? = nil, isEnabled: Bool, frame: CGRect) {
        self.role = role
        self.label = label
        self.title = title
        self.help = help
        self.imageIdentifier = imageIdentifier
        self.isEnabled = isEnabled
        self.frame = frame
    }
}

/// What the hover layer does for that element.
struct HoverDecision: Equatable {
    var tooltip: String?
    var showsPointingHand: Bool
    var highlights: Bool

    static let none = HoverDecision(tooltip: nil, showsPointingHand: false, highlights: false)
}

/// Mac-only tooltip rules. iOS has no hover, so upstream labels its icon
/// controls for VoiceOver only; on Mac the same label becomes the tooltip.
enum HoverTooltipPolicy {
    static let maxLength = 120

    static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .link, .popUpButton, .menuButton, .checkBox, .radioButton, .disclosureTriangle,
    ]

    static func decide(_ element: HoverElementSnapshot, highlightEnabled: Bool) -> HoverDecision {
        guard let role = element.role else { return .none }
        let interactive = interactiveRoles.contains(role)
        guard interactive || role == .image else { return .none }
        let pointer = interactive && element.isEnabled
        return HoverDecision(
            tooltip: tooltipText(element),
            showsPointingHand: pointer,
            highlights: pointer && highlightEnabled
        )
    }

    static func tooltipText(_ element: HoverElementSnapshot) -> String? {
        if let help = cleaned(element.help) { return truncated(help) }
        guard let label = cleaned(element.label) else { return nil }
        if showsLabelAsVisibleText(element, label: label) { return nil }
        if let title = cleaned(element.title), title.caseInsensitiveCompare(label) == .orderedSame {
            return nil
        }
        return truncated(label)
    }

    /// SwiftUI exposes no visible-text attribute (no static text child, no
    /// title element, no user-input labels; verified on macOS 26), so the
    /// label of an ambiguous node is judged by geometry: a control wide enough
    /// to hold its label in the system font is showing it. A narrower one
    /// (icon, or a short title with a longer accessibility label) is not.
    static func showsLabelAsVisibleText(_ element: HoverElementSnapshot, label: String) -> Bool {
        guard element.role != .image, element.title == nil, element.imageIdentifier == "" else { return false }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        return element.frame.width >= width + labelPadding
    }

    /// Horizontal chrome a bordered text button adds around its title.
    static let labelPadding: CGFloat = 12

    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncated(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength - 3)) + "..."
    }
}
