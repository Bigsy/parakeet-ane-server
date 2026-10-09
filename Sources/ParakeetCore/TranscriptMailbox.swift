import Foundation
import os

/// A single newest-value slot. Cancellation clears unread provisional snapshots,
/// which AsyncThrowingStream's buffered continuation cannot do by itself.
final class TranscriptMailbox: Sendable {
    private struct State {
        var latest: TranscriptUpdate?
        var terminal: Result<Void, ParakeetError>?
        var observationClosed = false
        var waiter: CheckedContinuation<TranscriptUpdate?, any Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func yield(_ update: TranscriptUpdate) {
        state.withLock { state in
            guard state.terminal == nil, !state.observationClosed else { return }
            if let waiter = state.waiter {
                state.waiter = nil; waiter.resume(returning: update)
            } else { state.latest = update }
        }
    }

    func finish(throwing error: ParakeetError? = nil) {
        state.withLock { state in
            guard state.terminal == nil else { return }
            if let error {
                state.latest = nil
                state.terminal = .failure(error)
                state.waiter?.resume(throwing: error)
            } else {
                state.terminal = .success(())
                state.waiter?.resume(returning: nil)
            }
            state.waiter = nil
        }
    }

    func next() async throws -> TranscriptUpdate? {
        let result: TranscriptUpdate? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if Task.isCancelled || state.observationClosed { continuation.resume(returning: nil) }
                    else if let latest = state.latest {
                        state.latest = nil; continuation.resume(returning: latest)
                    } else if let terminal = state.terminal {
                        switch terminal {
                        case .success: continuation.resume(returning: nil)
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    } else if state.waiter != nil { continuation.resume(throwing: ParakeetError.busy) }
                    else { state.waiter = continuation }
                }
            }
        } onCancel: { self.endObservation() }
        if Task.isCancelled { return nil }
        if let error = state.withLock({ state -> ParakeetError? in
            if case .failure(let error) = state.terminal { return error }
            return nil
        }) { throw error }
        return result
    }

    private func endObservation() {
        state.withLock { state in
            state.observationClosed = true; state.latest = nil
            state.waiter?.resume(returning: nil); state.waiter = nil
        }
    }
}
