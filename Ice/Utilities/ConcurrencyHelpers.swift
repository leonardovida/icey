//
//  ConcurrencyHelpers.swift
//  Ice
//

import Foundation
import os.lock

// MARK: - Task Timeout

/// An error that indicates that a task timed out.
struct TaskTimeoutError: CustomStringConvertible, LocalizedError {
    let description = "Task timed out before completion"
    var errorDescription: String? { description }
}

extension Task {
    /// Runs the given throwing operation asynchronously alongside a
    /// timeout operation in a structured task group.
    ///
    /// If the operation does not complete within the provided
    /// duration, the timeout operation cancels the group and throws
    /// a ``TaskTimeoutError``.
    ///
    /// - Parameters:
    ///   - timeout: The duration the operation must complete within.
    ///   - tolerance: The precision threshold of the timeout operation.
    ///   - clock: The clock that manages the timeout operation.
    ///   - operation: The operation to perform.
    ///
    /// - Returns: The result of the operation, if successful.
    private static func withTimeout<C: Clock>(
        _ timeout: C.Instant.Duration,
        tolerance: C.Instant.Duration?,
        clock: C,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) async throws -> Success {
        try await withThrowingTaskGroup(of: Success.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: timeout, tolerance: tolerance, clock: clock)
                throw TaskTimeoutError()
            }
            guard let success = try await group.next() else {
                throw _Concurrency.CancellationError()
            }
            group.cancelAll()
            return success
        }
    }
}

extension Task where Failure == Never {
    /// Waits for the task to finish, for no longer than the given duration,
    /// and returns a Boolean value that indicates whether it finished in time.
    ///
    /// A task that does not finish in time keeps running.
    ///
    /// `Task(timeout:)` runs its operation in a task group, and a task group
    /// waits for every child task to finish, even a cancelled one. Work that
    /// does not stop when cancelled, such as a blocking window server or XPC
    /// call, so held it up for as long as the work took, however short the
    /// timeout. This waits for the task without becoming its parent, so it
    /// returns on time.
    ///
    /// - Parameter timeout: The longest time to wait.
    func finished(within timeout: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let isResumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Bool) -> Void = { finished in
                let isFirst = isResumed.withLock { isResumed in
                    defer { isResumed = true }
                    return !isResumed
                }
                if isFirst {
                    continuation.resume(returning: finished)
                }
            }
            let timer = _Concurrency.Task {
                try? await _Concurrency.Task.sleep(for: timeout)
                resume(false)
            }
            _Concurrency.Task {
                _ = await value
                resume(true)
                timer.cancel()
            }
        }
    }
}

extension Task where Failure == any Error {
    /// Runs the given throwing operation asynchronously as part of a
    /// new _unstructured_ top-level task.
    ///
    /// If the operation does not complete within the provided duration,
    /// the task is cancelled and a ``TaskTimeoutError`` is thrown.
    ///
    /// - Parameters:
    ///   - timeout: The duration the operation must complete within.
    ///   - tolerance: The precision threshold of the timeout operation.
    ///   - clock: The clock that manages the timeout operation.
    ///   - name: Human readable name of the task.
    ///   - priority: The priority of the operation.
    ///   - operation: The operation to perform.
    @discardableResult
    init<C: Clock>(
        timeout: C.Instant.Duration,
        tolerance: C.Instant.Duration? = nil,
        clock: C = .continuous,
        name: String? = nil,
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) {
        self.init(name: name, priority: priority) {
            try await Task.withTimeout(timeout, tolerance: tolerance, clock: clock, operation: operation)
        }
    }

    /// Runs the given throwing operation asynchronously as part of a
    /// new _unstructured_ _detached_ top-level task.
    ///
    /// If the operation does not complete within the provided duration,
    /// the task is cancelled and a ``TaskTimeoutError`` is thrown.
    ///
    /// - Parameters:
    ///   - timeout: The duration the operation must complete within.
    ///   - tolerance: The precision threshold of the timeout operation.
    ///   - clock: The clock that manages the timeout operation.
    ///   - name: Human readable name of the task.
    ///   - priority: The priority of the operation.
    ///   - operation: The operation to perform.
    ///
    /// - Returns: A reference to the task.
    @discardableResult
    static func detached<C: Clock>(
        timeout: C.Instant.Duration,
        tolerance: C.Instant.Duration? = nil,
        clock: C = .continuous,
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Failure> {
        detached(name: name, priority: priority) {
            try await withTimeout(timeout, tolerance: tolerance, clock: clock, operation: operation)
        }
    }
}
