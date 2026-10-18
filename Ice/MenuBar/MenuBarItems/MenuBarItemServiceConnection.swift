//
//  MenuBarItemServiceConnection.swift
//  Ice
//

import Foundation
import OSLog

// MARK: - MenuBarItemService.Connection

@available(macOS 26.0, *)
extension MenuBarItemService {
    /// A connection to the `MenuBarItemService` XPC service.
    final class Connection: Sendable {
        /// The shared connection.
        static let shared = Connection()

        /// The connection's underlying session.
        private let session: Session

        /// The connection's target queue.
        private let queue: DispatchQueue

        /// The connection's logger.
        private let logger: Logger

        /// The queue that requests are sent from.
        ///
        /// A request blocks its thread until the service replies, which can
        /// take seconds while the service asks slow apps for their items over
        /// Accessibility, and requests wait in turn for the session. Sent
        /// straight from an async function, each one held a thread of the
        /// Swift concurrency pool, and requests piling up behind a slow one
        /// could take all of them, leaving the app unable to run any other
        /// async work, as with the image captures (see
        /// `MenuBarItemImageCache.captureQueue`). The queue is serial, so a
        /// slow request costs one thread rather than one per request.
        private let requestQueue = DispatchQueue(
            label: "MenuBarItemService.Connection.requests",
            qos: .userInitiated
        )

        /// How long the connection asks for one window at a time after
        /// the service fails a request for several windows.
        private static let batchRequestRetryInterval = Duration.seconds(60)

        /// When the service last failed a request for several windows.
        ///
        /// A service from an older version of the app does not know that
        /// request, as when a running service is still the old one during
        /// an update.
        private let batchRequestFailure = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

        /// Creates a new connection.
        private init() {
            let queue = DispatchQueue.targetingGlobal(
                label: "MenuBarItemService.Connection.queue",
                qos: .userInteractive,
                attributes: .concurrent
            )
            let logger = Logger(category: "MenuBarItemService.Connection")
            self.session = Session(queue: queue, logger: logger)
            self.queue = queue
            self.logger = logger
        }

        /// Starts the connection.
        func start() async {
            logger.debug("Starting MenuBarItemService connection")

            await withCheckedContinuation { continuation in
                requestQueue.async { [self] in
                    guard let response = session.send(request: .start) else {
                        logger.error("Start request returned nil")
                        continuation.resume()
                        return
                    }
                    if case .start = response {
                        continuation.resume()
                    } else {
                        logger.error("Start request returned invalid response \(String(describing: response))")
                        continuation.resume()
                    }
                }
            }
        }

        /// Returns the source process identifier for the given window.
        func sourcePID(for window: WindowInfo) async -> pid_t? {
            await withCheckedContinuation { continuation in
                requestQueue.async { [self] in
                    guard let response = session.send(request: .sourcePID(window)) else {
                        logger.error("Source PID request returned nil")
                        continuation.resume(returning: nil)
                        return
                    }
                    if case .sourcePID(let pid) = response {
                        continuation.resume(returning: pid)
                    } else {
                        logger.error("Source PID request returned invalid response \(String(describing: response))")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        /// Returns the source process identifier for each of the given
        /// windows, in order.
        ///
        /// The windows are sent in one request. If the service fails it,
        /// each window is sent in a request of its own, as before the
        /// batch request existed, so a service from an older version of
        /// the app still answers.
        func sourcePIDs(for windows: [WindowInfo]) async -> [pid_t?] {
            guard !windows.isEmpty else {
                return []
            }
            if let pids = await batchSourcePIDs(for: windows) {
                return pids
            }
            var pids = [pid_t?]()
            for window in windows {
                pids.append(await sourcePID(for: window))
            }
            return pids
        }

        /// Returns the source process identifier for each of the given
        /// windows from one request, or `nil` if the request was not sent
        /// or the service failed it.
        private func batchSourcePIDs(for windows: [WindowInfo]) async -> [pid_t?]? {
            await withCheckedContinuation { continuation in
                requestQueue.async { [self] in
                    let sendsBatchRequest = batchRequestFailure.withLock { failure in
                        failure.map { .now - $0 >= Self.batchRequestRetryInterval } ?? true
                    }
                    guard sendsBatchRequest else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if
                        case .sourcePIDs(let pids) = session.send(request: .sourcePIDs(windows)),
                        pids.count == windows.count
                    {
                        batchRequestFailure.withLock { $0 = nil }
                        continuation.resume(returning: pids)
                    } else {
                        logger.notice("Source PIDs request failed, sending one request per window")
                        batchRequestFailure.withLock { $0 = .now }
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - MenuBarItemService.Session

@available(macOS 26.0, *)
extension MenuBarItemService {
    /// A wrapper around an XPC session.
    private final class Session: Sendable {
        /// A session's underlying storage.
        private final class Storage: @unchecked Sendable {
            private let name = MenuBarItemService.name
            private var session: XPCSession?
            private let queue: DispatchQueue
            private let logger: Logger

            init(queue: DispatchQueue, logger: Logger) {
                self.queue = queue
                self.logger = logger
            }

            private func getOrCreateSession() throws -> XPCSession {
                if let session {
                    return session
                }
                // The cancellation handler runs on the target queue, outside
                // the lock that protects this storage, so it must not clear
                // `session`: that raced with a request in flight. A request
                // on a cancelled session fails, and `send(request:)` drops
                // the session then, so the next request creates a new one.
                let session = try XPCSession(xpcService: name, options: .inactive) { [logger] error in
                    logger.warning("Session was cancelled with error \(error.localizedDescription)")
                }
                // The service's signing identifier is its bundle identifier,
                // which is also its service name.
                session.setPeerRequirement(MenuBarItemService.peerRequirement(signingIdentifier: name))
                session.setTargetQueue(queue)
                try session.activate()
                self.session = session
                return session
            }

            func cancel(reason: String) {
                guard let session = session.take() else {
                    return
                }
                session.cancel(reason: reason)
            }

            func send(request: Request) -> Response? {
                do {
                    let session = try getOrCreateSession()
                    let reply = try session.sendSync(request)
                    return try reply.decode(as: Response.self)
                } catch {
                    logger.error("Session failed with error \(error)")
                    cancel(reason: "Request failed")
                    return nil
                }
            }
        }

        /// Protected storage for the underlying XPC session.
        private let storage: OSAllocatedUnfairLock<Storage>

        /// The session's target queue.
        private let queue: DispatchQueue

        /// The session's logger.
        private let logger: Logger

        /// Creates a new session.
        init(queue: DispatchQueue, logger: Logger) {
            self.storage = OSAllocatedUnfairLock(initialState: Storage(queue: queue, logger: logger))
            self.queue = queue
            self.logger = logger
        }

        deinit {
            cancel(reason: "Session deinitialized")
        }

        /// Cancels the session.
        func cancel(reason: String) {
            storage.withLock { $0.cancel(reason: reason) }
        }

        /// Sends the given request to the service and returns the response.
        func send(request: Request) -> Response? {
            storage.withLock { $0.send(request: request) }
        }
    }
}
