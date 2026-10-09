import os

/// The cancellation handler sets this synchronously, before its actor lookup is scheduled.
/// A cancelled queued job cannot start merely because its actor message arrived late.
final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}
