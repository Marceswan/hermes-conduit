import AppKit
import SwiftUI

/// Mac twin of Conduit/Views/ChatScrollSurfaceLocator.swift. Finds the
/// NSScrollView SwiftUI renders the chat ScrollView with and adapts it to
/// ChatScrollEngine. If none is found, the engine stays detached and the
/// view falls back to ScrollViewProxy, as on iOS.
struct ChatScrollSurfaceLocator: NSViewRepresentable {
    let engine: ChatScrollEngine

    func makeNSView(context: Context) -> ChatScrollSurfaceLocatorView {
        ChatScrollSurfaceLocatorView(engine: engine)
    }

    func updateNSView(_ view: ChatScrollSurfaceLocatorView, context: Context) {
        view.engine = engine
    }

    static func dismantleNSView(_ view: ChatScrollSurfaceLocatorView, coordinator: ()) {
        view.disconnect()
    }
}

final class ChatScrollSurfaceLocatorView: NSView {
    weak var engine: ChatScrollEngine? {
        didSet {
            guard engine !== oldValue else { return }
            disconnect()
            connectIfNeeded()
        }
    }

    private(set) var surface: NSScrollViewChatSurface?

    init(engine: ChatScrollEngine) {
        self.engine = engine
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? disconnect() : connectIfNeeded()
    }

    override func layout() {
        super.layout()
        connectIfNeeded()
    }

    func disconnect() {
        guard let surface else { return }
        self.surface = nil
        surface.invalidate()
    }

    private func connectIfNeeded() {
        guard window != nil, let engine, let scrollView = enclosingScrollView else { return }
        if let surface, surface.scrollView === scrollView { return }
        disconnect()
        let surface = NSScrollViewChatSurface(scrollView: scrollView, locator: self, engine: engine)
        self.surface = surface
        engine.attach(surface)
    }
}

/// ChatScrollSurface backed by the transcript's NSScrollView. Offsets are in
/// the document view's coordinates; SwiftUI's document view is flipped, so
/// y grows downward as on iOS.
@MainActor
final class NSScrollViewChatSurface: NSObject, ChatScrollSurface {
    private(set) weak var scrollView: NSScrollView?
    private weak var locator: NSView?
    private weak var engine: ChatScrollEngine?
    private var observers: [NSObjectProtocol] = []
    private var liveScrolling = false

    init(scrollView: NSScrollView, locator: NSView, engine: ChatScrollEngine?) {
        self.scrollView = scrollView
        self.locator = locator
        self.engine = engine
        super.init()
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.surfaceScrolled() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.documentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.surfaceLayoutChanged() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.surfaceLayoutChanged() }
            },
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.liveScrolling = true
                    self?.engine?.userDragBegan()
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.liveScrolling = false
                    self?.engine?.userDragEnded()
                }
            },
        ]
    }

    func invalidate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.detach(self)
    }

    // MARK: - ChatScrollSurface

    var contentOffsetY: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }
    var contentHeight: CGFloat { scrollView?.documentView?.frame.height ?? 0 }
    var viewportHeight: CGFloat { scrollView?.contentView.bounds.height ?? 0 }
    var insetTop: CGFloat { scrollView?.contentInsets.top ?? 0 }
    var insetBottom: CGFloat { scrollView?.contentInsets.bottom ?? 0 }
    var isTracking: Bool { liveScrolling }
    var isDecelerating: Bool { false }

    var transcriptOriginY: CGFloat {
        guard let document = scrollView?.documentView, let locator else { return 0 }
        return locator.convert(CGPoint.zero, to: document).y
    }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
