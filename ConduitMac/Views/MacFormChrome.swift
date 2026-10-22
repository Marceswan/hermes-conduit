import AppKit
import SwiftUI

/// Mac-only helpers for the shared Form sheets (D14). Upstream views call
/// these inside `#if os(macOS) // MAC:` regions; the grouped style itself comes
/// from `Form` in Compat/App/FormShim.swift.

/// A navigation row that opens a picker sheet (a Button whose label is
/// `HStack { title; Spacer(); value; chevron }`): a plain full-width row, not
/// the bordered accent-tinted button the default style draws on Mac. The hit
/// shape is applied to the label inside the style, so the whole row, Spacer
/// included, is the click target (a `contentShape` outside the Button does not
/// widen it; pinned by `MacComposerSheetTests`).
struct MacFormNavigationRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == MacFormNavigationRowStyle {
    static var macFormNavigationRow: MacFormNavigationRowStyle { MacFormNavigationRowStyle() }
}

extension View {
    /// A `TextEditor` row inside a Form: the default editor is a borderless
    /// field with no placeholder, which reads as a black void in a card. This
    /// puts it in a bordered, filled box with `prompt` shown while it is empty.
    func macFormEditor(text: String, prompt: LocalizedStringKey) -> some View {
        scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.18)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
    }

    /// The size of a Form sheet on Mac. A sheet takes the ideal size of its
    /// content, and a Form's ideal size is small, which left the sheet narrow
    /// and its content at the edge; `minWidth` keeps it from being resized
    /// below a readable width. The ideal height is clamped to the screen's
    /// visible height less a margin, so the sheet never opens taller than the
    /// display (the form scrolls).
    func macFormSheetSize(minWidth: CGFloat = 520, idealWidth: CGFloat = 560,
                          minHeight: CGFloat = 480, idealHeight: CGFloat = MacFormSheet.idealHeight) -> some View {
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: max(minHeight, idealHeight))
    }
}

/// The Settings sheet on Mac. Upstream's `SettingsView` has no size of its own on Mac: its pages sit in
/// `readableContentWidth` (a `GeometryReader`), so a sheet that takes the content's ideal size opened 470 x 80 pt
/// (live check F1). The width is the one a content-sized sheet of this kind had before (the cron job detail
/// sheet, 470 pt). The sheet can be resized larger; its height follows `MacFormSheet.idealHeight`.
enum MacSettingsSheet {
    static let idealWidth: CGFloat = 470
    static let minHeight: CGFloat = 480
}

extension View {
    func macSettingsSheetSize() -> some View {
        macFormSheetSize(minWidth: MacSettingsSheet.idealWidth, idealWidth: MacSettingsSheet.idealWidth,
                         minHeight: MacSettingsSheet.minHeight, idealHeight: MacFormSheet.idealHeight)
    }
}

enum MacFormSheet {
    /// 760 pt, or the main screen's visible height less 120 pt when that is less.
    static var idealHeight: CGFloat {
        min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 120)
    }
}
