import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindRowTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = HostedTestSupport.host(view.frame(width: 320, height: 120), size: NSSize(width: 320, height: 120))
        windows.append(window)
        return window
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    func testARowUnderTheModifierRegistersItsTextViewUnderTheRowId() {
        let controller = MacChatFindController()
        _ = host(
            SelectableTextView(text: "hello world")
                .macChatFindRow(id: "m1", engine: ChatScrollEngine())
                .environment(\.macChatFindController, controller)
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.views(for: "m1").count == 1 })
        XCTAssertEqual(controller.registry.views(for: "m1").first?.string, "hello world")
    }

    func testEveryTextViewInARowRegistersUnderTheSameId() {
        let controller = MacChatFindController()
        _ = host(
            VStack {
                SelectableTextView(text: "first block")
                SelectableTextView(text: "second block")
            }
            .macChatFindRow(id: "m7", engine: ChatScrollEngine())
            .environment(\.macChatFindController, controller)
        )
        // Reading order needs the stack laid out, so poll on the real assertion.
        XCTAssertTrue(HostedTestSupport.waitUntil {
            controller.registry.views(for: "m7").map(\.string) == ["first block", "second block"]
        }, "got \(controller.registry.views(for: "m7").map(\.string))")
    }

    func testWithoutAControllerNothingRegistersAndNoIdIsSet() {
        struct Probe: View {
            let seen: (String?) -> Void
            @Environment(\.macChatFindMessageID) private var id
            var body: some View { Color.clear.onAppear { seen(id) } }
        }
        var ids: [String?] = []
        _ = host(
            VStack {
                Probe { ids.append($0) }
                SelectableTextView(text: "hello")
            }
            .macChatFindRow(id: "m1", engine: ChatScrollEngine())
        )
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(ids.count, 1)
        XCTAssertNil(ids[0], "no controller in the environment: no id")
    }

    func testATextViewOutsideAnyRowIsNeverRegistered() {
        let controller = MacChatFindController()
        _ = host(SelectableTextView(text: "streaming tail").environment(\.macChatFindController, controller))
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(controller.registry.mountedViewCount, 0)
    }

    func testTheRowReplacesTheRevealClosureWithTheEnginesOwn() {
        let controller = MacChatFindController()
        var custom = 0
        controller.reveal = { _ in custom += 1 }
        _ = host(
            SelectableTextView(text: "x")
                .macChatFindRow(id: "m1", engine: ChatScrollEngine())
                .environment(\.macChatFindController, controller)
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.mountedViewCount == 1 })
        HostedTestSupport.settle(0.05)
        controller.reveal("unknown-row")   // the engine ignores rows it does not know
        XCTAssertEqual(custom, 0, "attach(engine:) installed the engine's closure")
    }

    func testAViewMountedWhileSearchingIsHighlightedAndRemovedWhenItGoesAway() {
        let controller = MacChatFindController()
        controller.registry.setContext(.init(query: "world", current: nil, searchable: ["m1"]))
        final class Toggle: ObservableObject { @Published var shown = true }
        struct Row: View {
            @ObservedObject var toggle: Toggle
            let controller: MacChatFindController
            var body: some View {
                VStack {
                    if toggle.shown {
                        SelectableTextView(text: "hello world")
                            .macChatFindRow(id: "m1", engine: ChatScrollEngine())
                            .environment(\.macChatFindController, controller)
                    }
                }
            }
        }
        let toggle = Toggle()
        _ = host(Row(toggle: toggle, controller: controller))
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.views(for: "m1").count == 1 })
        let view = controller.registry.views(for: "m1")[0]
        XCTAssertEqual(background(view, at: 6), MacChatFindColors.match)
        toggle.shown = false
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.mountedViewCount == 0 },
                      "dismantleNSView unregisters")
    }

    func testTheModifierDoesNotChangeTheMeasuredSize() {
        let plain = SelectableTextView(text: "hello world wrapped text")
        let controller = MacChatFindController()
        let tagged = SelectableTextView(text: "hello world wrapped text")
            .macChatFindRow(id: "m1", engine: ChatScrollEngine())
            .environment(\.macChatFindController, controller)
        let a = NSHostingView(rootView: plain.frame(width: 200)).fittingSize
        let b = NSHostingView(rootView: tagged.frame(width: 200)).fittingSize
        XCTAssertEqual(a.height, b.height, accuracy: 0.5)
    }

    // MARK: idempotent registration (didRegister fires on every updateNSView)

    func testAttachFindRegistersOnceWhileNothingChanges() {
        let controller = MacChatFindController()
        var fired = 0
        controller.registry.didRegister = { _ in fired += 1 }
        let coordinator = SelectableTextView.Coordinator()
        let view = NSTextView()
        for _ in 0..<5 {
            coordinator.attachFind(view, controller: controller, messageID: "m1", textChanged: false)
        }
        XCTAssertEqual(fired, 1, "same view, controller and id: one registration")
        coordinator.attachFind(view, controller: controller, messageID: "m1", textChanged: true)
        XCTAssertEqual(fired, 2, "new text registers again so highlights follow it")
        coordinator.attachFind(view, controller: controller, messageID: "m2", textChanged: false)
        XCTAssertEqual(fired, 3, "a different row id registers again")
    }

    func testAttachFindWithoutARowUnregistersAViewItHadRegistered() {
        let controller = MacChatFindController()
        let coordinator = SelectableTextView.Coordinator()
        let view = NSTextView()
        coordinator.attachFind(view, controller: controller, messageID: "m1", textChanged: false)
        XCTAssertEqual(controller.registry.mountedViewCount, 1)
        coordinator.attachFind(view, controller: nil, messageID: nil, textChanged: false)
        XCTAssertEqual(controller.registry.mountedViewCount, 0)
    }
}
