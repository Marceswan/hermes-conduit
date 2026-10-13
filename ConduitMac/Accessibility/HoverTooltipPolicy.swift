import AppKit
import SwiftUI

/// Accessibility facts about the element under the pointer.
struct HoverElementSnapshot: Equatable {
    var role: NSAccessibility.Role?
    var label: String?
    var title: String?
    /// AX value when it is text (a field's contents, a segment's caption).
    /// Selection state (a radio button's 0 or 1) is not text and is not kept.
    var value: String?
    var help: String?
    /// SwiftUI only. A symbol-backed control carries the symbol name here, so
    /// non-empty means an icon. Empty is ambiguous (text button, or an icon
    /// from an asset or NSImage). Nil means AppKit, where `title` decides.
    var imageIdentifier: String?
    /// Text of static-text children, i.e. what the control draws on screen.
    var childTexts: [String]
    var isEnabled: Bool
    /// Screen coordinates (AppKit, bottom-left origin).
    var frame: CGRect
    /// The control's own shape in screen coordinates, when the accessibility
    /// layer reports one (SwiftUI nodes do; see `HoverOutlineShape`).
    var shapePath: NSBezierPath?

    init(role: NSAccessibility.Role?, label: String? = nil, title: String? = nil, value: String? = nil,
         help: String? = nil, imageIdentifier: String? = nil, childTexts: [String] = [],
         isEnabled: Bool, frame: CGRect, shapePath: NSBezierPath? = nil) {
        self.role = role
        self.label = label
        self.title = title
        self.value = value
        self.help = help
        self.imageIdentifier = imageIdentifier
        self.childTexts = childTexts
        self.isEnabled = isEnabled
        self.frame = frame
        self.shapePath = shapePath
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
        if element.imageIdentifier == visibleLabelIdentifier { return nil }
        if drawsLabelAsText(element, label: label) { return nil }
        if showsLabelAsVisibleText(element, label: label) { return nil }
        if showsSelectionItemLabel(element, label: label) { return nil }
        return truncated(label)
    }

    /// Identifier a SwiftUI control sets (`macVisibleLabelHint()`) to say its
    /// accessibility label is the text it draws. SwiftUI nodes expose no title,
    /// value or static-text child, so this is the only exact signal there.
    static let visibleLabelIdentifier = "conduit.mac.visibleLabel"

    /// The element exposes the label as text it shows: its AX title or value,
    /// or a static-text child, equals the label (ignoring case and padding).
    /// Holds for every role, tabs and segments included.
    static func drawsLabelAsText(_ element: HoverElementSnapshot, label: String) -> Bool {
        let shown = [element.title, element.value] + element.childTexts.map { Optional($0) }
        return shown.contains { text in
            guard let text = cleaned(text) else { return false }
            return text.caseInsensitiveCompare(label) == .orderedSame
        }
    }

    /// Tabs, segments and radio buttons name themselves with their caption.
    /// AppKit reports a segment as a radio button whose label is the caption
    /// and whose title and value stay empty, so a radio-button role whose
    /// frame can hold the label as text is treated as showing it. A SwiftUI
    /// symbol-backed node (identifier non-empty) is an icon and keeps its
    /// tooltip.
    static func showsSelectionItemLabel(_ element: HoverElementSnapshot, label: String) -> Bool {
        guard element.role == .radioButton else { return false }
        if let id = element.imageIdentifier, !id.isEmpty { return false }
        let font = NSFont.systemFont(ofSize: referenceFontSize)
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        return element.frame.width >= width
    }

    /// SwiftUI exposes no visible-text attribute (no static text child, no
    /// title element, no user-input labels; verified on macOS 26), so the
    /// label of an ambiguous node is judged by geometry. Measured frames:
    /// text buttons are wide and short (Connect 75x24, plain Settings 50x16,
    /// plain caption Retry 26x13, New Chat+icon 105x24); icon buttons are
    /// near-square or labelled with a longer string than they show (plain gear
    /// 15x15, Add 15x14, Profile photo 28x28, "Go" labelled "Send message"
    /// 41x24, bordered NSImage Avatar 39x22).
    /// A node shows its label when BOTH hold:
    ///  - width >= the label measured at a small reference font with no
    ///    padding (plain buttons have no chrome, and a caption font is
    ///    smaller than the 13pt default, so the reference must be small), and
    ///  - aspect ratio (width / height) >= `minTextAspect`.
    /// Residual failure modes: a very short text label on a near-square text
    /// button (an "OK" plain button) reads as an icon and gets a duplicate
    /// tooltip; a wide, short icon button whose label fits reads as text and
    /// loses its tooltip. Neither is harmful.
    static func showsLabelAsVisibleText(_ element: HoverElementSnapshot, label: String) -> Bool {
        guard element.role != .image, element.title == nil, element.imageIdentifier == "" else { return false }
        let font = NSFont.systemFont(ofSize: referenceFontSize)
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        let frame = element.frame
        guard frame.height > 0 else { return false }
        return frame.width >= width && frame.width / frame.height >= minTextAspect
    }

    static let referenceFontSize: CGFloat = 10
    static let minTextAspect: CGFloat = 1.9

    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncated(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength - 3)) + "..."
    }
}

extension View {
    /// Marks a control whose accessibility label is also the text it draws, so
    /// the hover layer shows no tooltip repeating it (`HoverTooltipPolicy`).
    func macVisibleLabelHint() -> some View {
        accessibilityIdentifier(HoverTooltipPolicy.visibleLabelIdentifier)
    }
}
