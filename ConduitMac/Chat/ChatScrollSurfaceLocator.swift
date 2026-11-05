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

    /// Flipped so `convert(.zero, to:)` yields the top-left of the transcript
    /// stack, matching the flipped document view SwiftUI uses.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? disconnect() : connectIfNeeded()
    }

    override func layout() {
        super.layout()
        connectIfNeeded()
        surface?.checkInsets()
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
    /// What caused an offset change. Only `.userDiscrete` and `.live` are
    /// reader intent; `.programmatic` is the engine or an animation.
    enum ScrollKind: Equatable {
        case programmatic
        /// Wheel notch, scroller knob, keyboard paging or scroll-bar click.
        /// None of these post willStartLiveScroll.
        case userDiscrete
        /// Between willStartLiveScroll and didEndLiveScroll.
        case live
    }

    private(set) weak var scrollView: NSScrollView?
    private weak var locator: NSView?
    private weak var engine: ChatScrollEngine?
    private var observers: [NSObjectProtocol] = []
    private var liveScrolling = false
    /// Last offset this surface wrote. A bounds change to it is ours.
    private var programmaticOffsetY: CGFloat?
    private var animatingProgrammatically = false
    private(set) var lastInsets: NSEdgeInsets
    /// View > Zoom (D27): from `MacUIZoom.willChangeNotification` until the change
    /// settles, an offset change is layout, not the reader. After the engine pins
    /// the new bottom, SwiftUI writes back the offset it kept for the old viewport
    /// size, which would read as a scroll away from the latest message.
    private(set) var zoomSettling = false
    /// The chat followed its latest message when the zoom began; it follows it after.
    private var followedBeforeZoom = false
    private var zoomGeneration = 0
    /// Longer than the layout pass a zoom change starts; a reader's scroll in it is not lost, only not read as leaving the end.
    static let zoomSettleDelay: TimeInterval = 0.3

    init(scrollView: NSScrollView, locator: NSView, engine: ChatScrollEngine?) {
        self.scrollView = scrollView
        self.locator = locator
        self.engine = engine
        self.lastInsets = scrollView.contentInsets
        super.init()
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
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
            // Synchronous (no queue): posted just before the new level is stored.
            center.addObserver(forName: MacUIZoom.willChangeNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.zoomWillChange() }
            },
        ]
    }

    func zoomWillChange() {
        if !zoomSettling { followedBeforeZoom = engine?.isFollowingLatest ?? false }
        zoomSettling = true
        zoomGeneration += 1
        let generation = zoomGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zoomSettleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.zoomGeneration == generation else { return }
                self.zoomSettling = false
                if self.followedBeforeZoom { self.engine?.explicitLatestRequested(animated: false) }
                self.followedBeforeZoom = false
            }
        }
    }

    func invalidate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.detach(self)
    }

    private func boundsChanged() {
        guard let engine, let scrollView else { return }
        let y = scrollView.contentView.bounds.origin.y
        switch classifyScroll(newOffsetY: y) {
        case .programmatic:
            engine.surfaceScrolled()
            if zoomSettling, followedBeforeZoom { engine.explicitLatestRequested(animated: false) }
        case .userDiscrete:
            // Discrete scrolls never post willStartLiveScroll, so the engine
            // would keep pinning the bottom. Treat them as a drag.
            programmaticOffsetY = nil
            engine.userDragBegan()
            engine.surfaceScrolled()
            engine.userDragEnded()
        case .live:
            engine.surfaceScrolled()
        }
    }

    /// Decides whether a bounds change came from the reader. Pure apart from
    /// reading surface state, so tests can drive it directly.
    func classifyScroll(newOffsetY: CGFloat) -> ScrollKind {
        if liveScrolling { return .live }
        if animatingProgrammatically || zoomSettling { return .programmatic }
        if let target = programmaticOffsetY, abs(newOffsetY - target) <= 0.5 {
            return .programmatic
        }
        return .userDiscrete
    }

    /// Mirrors iOS checkAdjustedInsets: insets changed (for example the
    /// window's toolbar or a title-bar change) without a layout of the
    /// document, so the engine has to be told. Returns true when they changed.
    @discardableResult
    func checkInsets() -> Bool {
        guard let scrollView else { return false }
        let current = scrollView.contentInsets
        guard current.top != lastInsets.top || current.bottom != lastInsets.bottom
            || current.left != lastInsets.left || current.right != lastInsets.right
        else { return false }
        lastInsets = current
        engine?.surfaceLayoutChanged()
        return true
    }

    // MARK: - ChatScrollSurface

    var contentOffsetY: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }
    var contentHeight: CGFloat { scrollView?.documentView?.frame.height ?? 0 }
    var viewportHeight: CGFloat { scrollView?.contentView.bounds.height ?? 0 }
    var insetTop: CGFloat { scrollView?.contentInsets.top ?? 0 }
    var insetBottom: CGFloat { scrollView?.contentInsets.bottom ?? 0 }

    /// True from willStartLiveScroll to didEndLiveScroll. On Mac this
    /// deliberately includes trackpad momentum: live scroll does not end until
    /// the momentum finishes, so the engine never pins during a fling (R14).
    var isTracking: Bool { liveScrolling }

    /// Always false on Mac. Momentum is folded into isTracking (R14); reporting
    /// deceleration separately would let the engine pin mid-fling.
    var isDecelerating: Bool { false }

    var transcriptOriginY: CGFloat {
        guard let document = scrollView?.documentView, let locator else { return 0 }
        return locator.convert(CGPoint.zero, to: document).y
    }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: y)
        programmaticOffsetY = y
        if animated {
            animatingProgrammatically = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                scrollView.contentView.animator().setBoundsOrigin(point)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.animatingProgrammatically = false }
            })
        } else {
            scrollView.contentView.setBoundsOrigin(point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
