import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

@MainActor
final class HoverAccessibilityEngineTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func show(_ content: NSView, size: NSSize = NSSize(width: 320, height: 200)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    private func screenPoint(of view: NSView) -> NSPoint {
        let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return view.window!.convertPoint(toScreen: inWindow)
    }

    func testNSButtonSnapshotCarriesRoleAndLabel() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let image = try XCTUnwrap(NSImage(systemSymbolName: "xmark", accessibilityDescription: nil))
        let button = NSButton(image: image, target: nil, action: nil)
        button.setAccessibilityLabel("Close Settings")
        button.frame = NSRect(x: 100, y: 80, width: 40, height: 40)
        container.addSubview(button)
        let window = show(container)
        let snapshot = try XCTUnwrap(HoverAccessibilityEngine.snapshot(at: screenPoint(of: button), in: window))
        XCTAssertEqual(snapshot.role, .button)
        XCTAssertEqual(snapshot.label, "Close Settings")
    }

    func testEmptyBackgroundHasNoDecision() {
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)))
        let point = window.convertPoint(toScreen: NSPoint(x: 160, y: 100))
        let snapshot = HoverAccessibilityEngine.snapshot(at: point, in: window)
        let decision = snapshot.map { HoverTooltipPolicy.decide($0, highlightEnabled: true) } ?? .none
        XCTAssertEqual(decision, .none)
    }

    func testSwiftUIButtonShapesProduceExpectedDecisions() throws {
        let root = VStack(spacing: 20) {
            Button { } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Settings")
            Button("Connect") { }
            Button { } label: { Label("Send", systemImage: "paperplane") }.labelStyle(.iconOnly)
            Button { } label: { Image(systemName: "gear") }.help("Settings")
        }
        .padding(30)
        // Real-app condition: no assistive client; only the engine's own switch.
        HoverAccessibilityEngine.enableSwiftUIAccessibilityTree()
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 260)
        let window = show(host, size: host.frame.size)
        // SwiftUI builds its accessibility tree lazily: queries kick it off, so poll.
        var attempts = 0
        while (host.accessibilityChildren() ?? []).isEmpty, attempts < 20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            attempts += 1
        }
        let kids: [Any] = host.axValue("accessibilityChildren") ?? []
        XCTAssertEqual(kids.count, 4, "SwiftUI exposed one accessibility node per button")
        var decisions: [HoverDecision] = []
        for kid in kids.compactMap({ $0 as? NSObject }) {
            let frame: NSValue? = kid.axValue("accessibilityFrame")
            let r = try XCTUnwrap(frame?.rectValue)
            let snapshot = HoverAccessibilityEngine.snapshot(at: NSPoint(x: r.midX, y: r.midY), in: window)
            decisions.append(snapshot.map { HoverTooltipPolicy.decide($0, highlightEnabled: true) } ?? .none)
        }
        let control = { (tip: String?) in HoverDecision(tooltip: tip, showsPointingHand: true, highlights: true) }
        // Observed: labels arrive as `label` (title is always nil); the image-only
        // buttons carry their symbol name in the identifier, the text button "".
        XCTAssertEqual(decisions, [control("Close Settings"), control(nil), control("Send"), control("Settings")])
    }
}
