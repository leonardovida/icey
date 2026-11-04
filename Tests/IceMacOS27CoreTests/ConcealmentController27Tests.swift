import Testing
@testable import IceMacOS27Core

/// Simulates MenuBarAgent: an item shows if any live assertion allows it.
@MainActor
final class FakeConcealmentBackend: ConcealmentBackend27 {
    final class Token: ConcealmentToken27 {
        let allowed: Set<String>
        init(allowed: Set<String>) { self.allowed = allowed }
    }

    struct Rejected: Error {}

    var universe: Set<String>
    var rejectNextActivation = false
    /// Rejects an activation once this many more have succeeded.
    var rejectAfter: Int?
    private(set) var liveTokens = [Token]()
    private(set) var activationCount = 0
    /// What the bar conceals after every activation and invalidation.
    private(set) var history = [Set<String>]()

    init(universe: Set<String>) {
        self.universe = universe
    }

    var concealed: Set<String> {
        guard !liveTokens.isEmpty else { return [] }
        let allowed = liveTokens.reduce(into: Set<String>()) { $0.formUnion($1.allowed) }
        return universe.subtracting(allowed)
    }

    func activate(allowedBundleIDs: [String]) async throws -> ConcealmentToken27 {
        if rejectNextActivation {
            rejectNextActivation = false
            throw Rejected()
        }
        if let remaining = rejectAfter {
            guard remaining > 0 else {
                rejectAfter = nil
                throw Rejected()
            }
            rejectAfter = remaining - 1
        }
        activationCount += 1
        let token = Token(allowed: Set(allowedBundleIDs))
        liveTokens.append(token)
        history.append(concealed)
        return token
    }

    func invalidate(_ token: ConcealmentToken27) {
        liveTokens.removeAll { $0 === token }
        history.append(concealed)
    }
}

@Suite("ConcealmentController27")
@MainActor
struct ConcealmentController27Tests {
    let running: Set<String> = ["visible.app", "hidden.app", "always.app"]
    let allHidden: [Set<String>] = [["hidden.app", "always.app"]]
    let hiddenRevealed: [Set<String>] = [["always.app"]]

    @Test("Hiding conceals the target set")
    func hiding() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        #expect(backend.concealed == ["hidden.app", "always.app"])
        #expect(controller.isActive)
    }

    @Test("Revealing the hidden section never exposes always-hidden apps")
    func revealing() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        try await controller.apply(target: hiddenRevealed, running: running)
        #expect(backend.concealed == ["always.app"])
        #expect(backend.history.allSatisfy { $0.contains("always.app") })
    }

    @Test("Hiding again never exposes always-hidden apps")
    func hidingAgain() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        try await controller.apply(target: hiddenRevealed, running: running)
        try await controller.apply(target: allHidden, running: running)
        #expect(backend.concealed == ["hidden.app", "always.app"])
        #expect(backend.history.allSatisfy { $0.contains("always.app") })
    }

    @Test("Re-applying the same state does not churn assertions")
    func noChurn() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        try await controller.apply(target: allHidden, running: running)
        #expect(backend.activationCount == 1)
    }

    @Test("A launched app is allowed without exposing concealed apps")
    func launchedApp() async throws {
        let backend = FakeConcealmentBackend(universe: running.union(["new.app"]))
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        #expect(backend.concealed.contains("new.app"))
        try await controller.apply(target: allHidden, running: running.union(["new.app"]))
        #expect(backend.concealed == ["hidden.app", "always.app"])
        #expect(backend.history.allSatisfy { $0.isSuperset(of: ["hidden.app", "always.app"]) })
    }

    @Test("A rejected activation keeps the previous state")
    func rejected() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        backend.rejectNextActivation = true
        await #expect(throws: FakeConcealmentBackend.Rejected.self) {
            try await controller.apply(target: hiddenRevealed, running: running)
        }
        #expect(backend.concealed == ["hidden.app", "always.app"])
        #expect(backend.liveTokens.count == 1)
    }

    @Test("Applying again after a rejection reaches the target")
    func retryAfterRejection() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: [], running: running)
        backend.rejectNextActivation = true
        await #expect(throws: FakeConcealmentBackend.Rejected.self) {
            try await controller.apply(target: allHidden, running: running)
        }
        #expect(backend.concealed.isEmpty)
        try await controller.apply(target: allHidden, running: running)
        #expect(backend.concealed == ["hidden.app", "always.app"])
        #expect(backend.liveTokens.count == 1)
    }

    @Test("Retries back off and stop after a few")
    func retryDelays() {
        let delays = (0...7).map { ConcealmentController27.retryDelay(afterFailures: $0) }
        #expect(delays == [nil, .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), nil, nil])
        #expect(ConcealmentController27.retryDelay(afterFailures: ConcealmentController27.maximumRetries) != nil)
        #expect(ConcealmentController27.retryDelay(afterFailures: -1) == nil)
        #expect(ConcealmentController27.retryDelay(afterFailures: .max) == nil)
    }

    @Test("A rejection part way through releases what the same apply had activated")
    func rejectedPartWay() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        backend.rejectAfter = 1
        await #expect(throws: FakeConcealmentBackend.Rejected.self) {
            try await controller.apply(target: [["always.app"], ["hidden.app"]], running: running)
        }
        #expect(backend.activationCount == 2)
        #expect(backend.liveTokens.count == 1)
        #expect(backend.concealed == ["hidden.app", "always.app"])
        // The controller still knows what is live: the same target again changes nothing.
        try await controller.apply(target: allHidden, running: running)
        #expect(backend.activationCount == 2)
    }

    @Test("An assertion that stays in the target is kept, and only the new one is activated")
    func keepsWhatStays() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: [["always.app"], ["hidden.app"]], running: running)
        let kept = backend.liveTokens[0]
        try await controller.apply(target: [["always.app"], ["visible.app"]], running: running)
        #expect(backend.activationCount == 3)
        #expect(backend.liveTokens.count == 2)
        #expect(backend.liveTokens.contains { $0 === kept })
    }

    @Test("Releasing restores every item")
    func releasing() async throws {
        let backend = FakeConcealmentBackend(universe: running)
        let controller = ConcealmentController27(backend: backend)
        try await controller.apply(target: allHidden, running: running)
        controller.releaseAll()
        #expect(backend.concealed.isEmpty)
        #expect(!controller.isActive)
    }
}
