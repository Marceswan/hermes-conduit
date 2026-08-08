//
//  KanbanEventStream.swift
//  Conduit
//

import Foundation

/// Ticket minting needs the WKWebView bridge (dashboard cookies), not the
/// JSON requester; a separate protocol keeps the stream testable without
/// WebKit.
@MainActor
protocol KanbanTicketProviding: AnyObject {
    func mintTicket() async throws -> String
}

@MainActor
extension DashboardTicketBridge: KanbanTicketProviding {}

enum KanbanEventStreamState: Equatable {
    case idle
    case connecting
    /// At least one frame received on the current connection — the stream is
    /// genuinely delivering, not just dialed.
    case connected
    case waitingRetry
    /// Ticket minting reported an expired sign-in; permanent until restarted.
    case stoppedAuthRequired
}

/// Transport-level frame summary. Events are cache-invalidation signals only;
/// the board is refetched, never patched from event payloads.
struct KanbanEventFrame: Equatable {
    var eventCount: Int
    var cursor: Int?
}

/// Long-lived WebSocket on `/api/plugins/kanban/events`. The board slug is
/// pinned at the handshake, so board switches require a new stream. Failure
/// is always non-fatal: the 8-second quiet poll remains the safety net.
@MainActor
final class KanbanEventStream {
    private let baseURL: String
    private let boardSlug: String?
    private let ticketProvider: KanbanTicketProviding
    private let onBatch: @MainActor (KanbanEventFrame) -> Void
    private let onStateChange: @MainActor (KanbanEventStreamState) -> Void

    private var sinceCursor: Int?
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var backoffSeconds: Double = 1

    private(set) var state: KanbanEventStreamState = .idle {
        didSet {
            if state != oldValue { onStateChange(state) }
        }
    }

    init(
        baseURL: String,
        boardSlug: String?,
        since: Int?,
        ticketProvider: KanbanTicketProviding,
        onBatch: @escaping @MainActor (KanbanEventFrame) -> Void,
        onStateChange: @escaping @MainActor (KanbanEventStreamState) -> Void
    ) {
        self.baseURL = baseURL
        self.boardSlug = boardSlug
        self.sinceCursor = since
        self.ticketProvider = ticketProvider
        self.onBatch = onBatch
        self.onStateChange = onStateChange
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .idle
    }

    /// Parses a server frame: `{"events": [{"id": N, ...}, ...], "cursor": N}`.
    /// Garbage returns nil (skipped, never fatal). A frame with a cursor but
    /// no events array counts as an empty cursor-advance frame. A missing
    /// cursor falls back to the highest event id.
    nonisolated static func parseFrame(_ text: String) -> KanbanEventFrame? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let events = object["events"] as? [[String: Any]]
        let cursor = intValue(object["cursor"])
        guard events != nil || cursor != nil else { return nil }
        let count = events?.count ?? 0
        let fallbackCursor = events?.compactMap { intValue($0["id"]) }.max()
        return KanbanEventFrame(eventCount: count, cursor: cursor ?? fallbackCursor)
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    // MARK: Run loop

    private func runLoop() async {
        while !Task.isCancelled {
            state = .connecting

            let ticket: String
            do {
                ticket = try await ticketProvider.mintTicket()
            } catch DashboardTicketBridgeError.signInRequired {
                // The bridge already retried with reloads; this is real expiry.
                state = .stoppedAuthRequired
                return
            } catch {
                if Task.isCancelled { return }
                state = .waitingRetry
                await sleepBackoff()
                continue
            }
            if Task.isCancelled { return }

            var queryItems = [URLQueryItem(name: "ticket", value: ticket)]
            if let boardSlug, !boardSlug.isEmpty {
                queryItems.append(URLQueryItem(name: "board", value: boardSlug))
            }
            if let sinceCursor {
                queryItems.append(URLQueryItem(name: "since", value: String(sinceCursor)))
            }
            guard let url = try? ConnectionURLPolicy.webSocketURL(
                baseURL: baseURL,
                path: "/api/plugins/kanban/events",
                queryItems: queryItems
            ) else {
                // A malformed base URL cannot self-heal; leave it to the poll.
                state = .idle
                return
            }

            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()

            var deliveredFrame = false
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let text: String?
                    switch message {
                    case .string(let string):
                        text = string
                    case .data(let data):
                        text = String(data: data, encoding: .utf8)
                    @unknown default:
                        text = nil
                    }
                    guard let text, let frame = Self.parseFrame(text) else { continue }
                    deliveredFrame = true
                    state = .connected
                    if let cursor = frame.cursor {
                        sinceCursor = max(sinceCursor ?? 0, cursor)
                    }
                    if frame.eventCount > 0 {
                        onBatch(frame)
                    }
                }
            } catch is CancellationError {
                // fallthrough to teardown below
            } catch {
                // Socket died: network flap, suspension resume, server restart,
                // or the single-use ticket expired before the handshake.
            }

            socket = nil
            task.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { return }
            if deliveredFrame { backoffSeconds = 1 }
            state = .waitingRetry
            await sleepBackoff()
        }
    }

    private func sleepBackoff() async {
        try? await Task.sleep(for: .seconds(backoffSeconds))
        backoffSeconds = min(backoffSeconds * 2, 15)
    }
}
