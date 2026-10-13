import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Profile and bot photos: an open panel instead of the iOS photo picker.
struct ImagePicker: View {
    @Binding var image: NSImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    image = NSImage(contentsOf: url)
                }
                dismiss()
            }
    }
}
