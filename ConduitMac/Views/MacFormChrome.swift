import SwiftUI

/// Mac-only helpers for the shared Form sheets (D14). Upstream views call
/// these inside `#if os(macOS) // MAC:` regions; the grouped style itself comes
/// from `Form` in Compat/App/FormShim.swift.
extension View {
    /// A navigation row that opens a picker sheet (a Button whose label is
    /// `HStack { title; Spacer(); value; chevron }`): a plain full-width row,
    /// not the bordered accent-tinted button the default style draws on Mac,
    /// with the whole row, Spacer included, as the click target.
    func macFormNavigationRow() -> some View {
        buttonStyle(.plain)
            .contentShape(Rectangle())
    }

    /// A `TextEditor` row inside a Form: the default editor is a borderless
    /// field with no placeholder, which reads as a black void in a card. This
    /// puts it in a bordered, filled box with `prompt` shown while it is empty.
    func macFormEditor(text: String, prompt: String) -> some View {
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
                        .accessibilityHidden(true)
                }
            }
    }

    /// The size of a Form sheet on Mac. A sheet takes the ideal size of its
    /// content, and a Form's ideal size is small, which left the sheet narrow
    /// and its content at the edge; `minWidth` keeps it from being resized
    /// below a readable width.
    func macFormSheetSize(minWidth: CGFloat = 520, idealWidth: CGFloat = 560,
                          minHeight: CGFloat = 480, idealHeight: CGFloat = 760) -> some View {
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
    }
}
