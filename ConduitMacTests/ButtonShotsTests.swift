import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

/// Renders the sidebar header rows, the tab strip and the toolbar pill to PNGs
/// with `ImageRenderer`, to eyeball heights, insets and centring. Off by
/// default; run with `TEST_RUNNER_CONDUIT_BTN_SHOTS=1`. Glass does not render
/// offscreen, so only geometry and flat fills are meaningful. Output goes to
/// `/private/tmp/conduit-btn-shots/`; delete it afterwards.
@MainActor
final class ButtonShotsTests: XCTestCase {
    private static let directory = "/private/tmp/conduit-btn-shots"

    private func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_BTN_SHOTS"] == "1",
                          "set TEST_RUNNER_CONDUIT_BTN_SHOTS=1 to write PNGs")
        try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previous }
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.12) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.directory)/\(name)-\(dark ? "dark" : "light").png"))
    }

    func testTabStripAtDefaultAndNarrowWidths() throws {
        for dark in [true, false] {
            try render(MacSidebarTabStrip(selectedRaw: .constant("Sessions")).padding(14),
                       size: CGSize(width: 340, height: 72), name: "tabs-340", dark: dark)
            try render(MacSidebarTabStrip(selectedRaw: .constant("Cron")).padding(14),
                       size: CGSize(width: 232, height: 72), name: "tabs-232-icons", dark: dark)
        }
    }

    func testSidebarHeaderRows() throws {
        for dark in [true, false] {
            try render(
                SidebarView(onRequestSettings: {}, presentation: .persistent)
                    .environmentObject(AppStateRuntimeRegistry.shared.appState),
                size: CGSize(width: 340, height: 260), name: "sidebar-header", dark: dark)
        }
    }

    /// The hover outline itself is AppKit drawing, so `cacheDisplay` captures it.
    func testHoverOutline() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_BTN_SHOTS"] == "1",
                          "set TEST_RUNNER_CONDUIT_BTN_SHOTS=1 to write PNGs")
        try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        for dark in [true, false] {
            let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            parent.orderFront(nil)
            let frame = CGRect(x: 130, y: 140, width: 70, height: 36)
            let path = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
            let highlight = HighlightWindow()
            highlight.show(shape: HoverOutlineShape.make(frame: frame, axPath: path), over: parent)
            HostedTestSupport.settle(0.2)
            let view = try XCTUnwrap(highlight.contentView)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            // Flat backdrop so the glow reads in the PNG.
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "\(Self.directory)/hover-outline-\(dark ? "dark" : "light").png"))
            highlight.hide()
            parent.close()
        }
    }

    func testToolbarPill() throws {
        for dark in [true, false] {
            try render(
                HStack(spacing: 12) {
                    Text("Weekly planning notes").font(.subheadline.weight(.semibold)).macToolbarTitlePill()
                        .background(Color.white.opacity(0.1), in: Capsule())
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }.padding(14),
                size: CGSize(width: 320, height: 64), name: "toolbar-pill", dark: dark)
        }
    }
}
