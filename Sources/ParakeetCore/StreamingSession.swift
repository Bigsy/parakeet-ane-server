import Foundation

public struct TranscriptUpdate: Sendable, Equatable {
    public let sessionID: UUID
    public let revision: UInt64
    public let fullTranscript: String
    /// Accepted samples whose append/process operation has completed at this observation.
    /// This is not a token timestamp or a claim that look-ahead audio has been decoded.
    public let receivedAudioPosition: Int
    /// The pinned manager does not expose its decoded-window frontier.
    public var processedAudioPosition: Int? { nil }
}

/// One recording, one ordered queue and one authoritative final result.
/// Send owned PCM from a capture worker; append suspends and is unsuitable for an audio callback.
public actor StreamingSession {
    public nonisolated let id: UUID
    /// Single observer, bounded newest-value snapshots. Cancelling observation does not cancel recording.
    public nonisolated let updates: AsyncThrowingStream<TranscriptUpdate, any Error>
    private let mailbox: TranscriptMailbox
    private var model: (any StreamingModel)?
    private let configuration: EngineConfiguration
    private var release: (@Sendable (Bool) async -> Void)?
    private let started = ContinuousClock.now
    private var phase: Phase = .open
    private var acceptedSamples = 0
    private var receivedSamples = 0
    private var revision: UInt64 = 0
    private var lastText = ""
    private var settled = false
    private var finalResult: TranscriptionResult?
    private var terminalError: ParakeetError = .cancelled
    private var queue: [Job] = []
    private var queuedSamples = 0
    private var active: Job?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var inferenceDuration: Duration = .zero

    private enum Phase { case open, finishing, finished, cancelling, cancelled }
    private enum Kind { case append(PCM16kMono), finish }
    private enum Output { case appended(String?), finished(String, Duration) }
    private struct Job {
        let id: UUID
        let kind: Kind
        let admitted: ContinuousClock.Instant
        let cancellation: CancellationFlag
        var continuation: CheckedContinuation<TranscriptionResult?, any Error>?
        var deadline: Task<Void, Never>?
        var sampleCount: Int { if case .append(let pcm) = kind { pcm.samples.count } else { 0 } }
    }

    init(id: UUID, model: any StreamingModel, configuration: EngineConfiguration,
         release: @escaping @Sendable (Bool) async -> Void) {
        self.id = id; self.model = model; self.configuration = configuration; self.release = release
        let mailbox = TranscriptMailbox()
        self.mailbox = mailbox
        self.updates = AsyncThrowingStream(unfolding: { try await mailbox.next() })
    }

    public func append(_ audio: PCM16kMono, startingAt offset: Int) async throws {
        guard !Task.isCancelled else { requestCancellation(.cancelled); throw ParakeetError.cancelled }
        guard phase == .open else { throw phase == .cancelling || phase == .cancelled ? terminalError : .sessionFinished }
        guard offset == acceptedSamples else { throw ParakeetError.invalidSampleOffset }
        guard !audio.samples.isEmpty else { throw ParakeetError.invalidAudio }
        guard audio.samples.count <= configuration.maximumStreamingChunkSamples,
              audio.samples.count <= configuration.maximumAudioSamples - acceptedSamples
        else { throw ParakeetError.audioLimitExceeded }
        if active != nil {
            guard queue.count < configuration.queueCapacity,
                  audio.samples.count <= configuration.maximumQueuedSamples - queuedSamples
            else { throw ParakeetError.queueFull }
        }
        // Reservation is atomic before suspension; invalid/overflowed chunks never change offsets.
        acceptedSamples += audio.samples.count
        _ = try await submit(.append(audio))
        if Task.isCancelled { requestCancellation(.cancelled); throw ParakeetError.cancelled }
    }

    /// Drains accepted audio, flushes once, resets and releases the engine before returning.
    /// Repeated finish returns the same cached result. A concurrent finish returns busy.
    public func finish() async throws -> TranscriptionResult {
        if Task.isCancelled { requestCancellation(.cancelled); throw ParakeetError.cancelled }
        if let finalResult { await waitForSettlement(); return finalResult }
        if phase == .cancelling || phase == .cancelled { throw terminalError }
        guard phase == .open else { throw ParakeetError.busy }
        phase = .finishing
        guard let result = try await submit(.finish) else { throw ParakeetError.inferenceFailed }
        if Task.isCancelled { throw ParakeetError.cancelled }
        return result
    }

    /// Prompt, idempotent cancellation. Model ownership remains held until safe reset.
    /// Use waitForSettlement before unloading/changing engines or performing batch fallback.
    public func cancel() { requestCancellation(.cancelled) }

    public func waitForSettlement() async {
        if settled { return }
        await withCheckedContinuation { settlementWaiters.append($0) }
    }

    private func submit(_ kind: Kind) async throws -> TranscriptionResult? {
        let requestID = UUID()
        let cancellation = CancellationFlag()
        let result: TranscriptionResult? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    requestCancellation(.cancelled)
                    continuation.resume(throwing: ParakeetError.cancelled); return
                }
                guard phase == .open || phase == .finishing else {
                    continuation.resume(throwing: terminalError); return
                }
                var job = Job(id: requestID, kind: kind, admitted: .now, cancellation: cancellation, continuation: continuation)
                if active != nil, let timeout = configuration.queueWaitTimeout {
                    job.deadline = Task {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        if self.queue.contains(where: { $0.id == requestID }) {
                            self.requestCancellation(.queueDeadlineExceeded)
                        }
                    }
                }
                queue.append(job); queuedSamples += job.sampleCount
                startNext()
            }
        } onCancel: {
            cancellation.cancel()
            // Cancelling an accepted append cancels the recording, rather than silently
            // deleting a chunk and leaving a hole in the model timeline.
            Task { await self.requestCancellation(.cancelled) }
        }
        return result
    }

    private func startNext() {
        guard active == nil, !queue.isEmpty, let model, phase == .open || phase == .finishing else { return }
        let job = queue.removeFirst()
        queuedSamples -= job.sampleCount; job.deadline?.cancel(); active = job
        let began = ContinuousClock.now
        if let timeout = configuration.inferenceTimeout {
            deadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if self.active?.id == job.id { self.requestCancellation(.inferenceDeadlineExceeded) }
            }
        }
        worker = Task {
            let outcome: Result<Output, any Error>
            var resetAttempted = false
            var resetSucceeded = false
            do {
                try Task.checkCancellation()
                guard !job.cancellation.isCancelled else { throw CancellationError() }
                switch job.kind {
                case .append(let pcm):
                    try await model.append(pcm.samples)
                    try Task.checkCancellation()
                    guard !job.cancellation.isCancelled else { throw CancellationError() }
                    outcome = .success(.appended(try await model.process()))
                case .finish:
                    let flushBegan = ContinuousClock.now
                    let text = acceptedSamples == 0 ? "" : try await model.finish()
                    let flushDuration = flushBegan.duration(to: .now)
                    resetAttempted = true
                    try await model.reset()
                    resetSucceeded = true
                    outcome = .success(.finished(text, flushDuration))
                }
            } catch { outcome = .failure(error) }
            await complete(job.id, began: began, outcome: outcome, resetAttempted: resetAttempted, resetSucceeded: resetSucceeded)
        }
    }

    private func complete(_ requestID: UUID, began: ContinuousClock.Instant,
                          outcome: Result<Output, any Error>, resetAttempted: Bool, resetSucceeded: Bool) async {
        guard let job = active, job.id == requestID else { return }
        deadline?.cancel(); deadline = nil; worker = nil
        let ended = ContinuousClock.now
        inferenceDuration += began.duration(to: ended)
        if job.cancellation.isCancelled { requestCancellation(.cancelled) }
        if phase == .cancelling {
            active = nil; resetAndRelease(alreadyReset: resetAttempted, reusable: !resetAttempted || resetSucceeded); return
        }
        switch outcome {
        case .success(.appended(let text)):
            receivedSamples += job.sampleCount
            if let text { publish(text) }
            active = nil
            job.continuation?.resume(returning: nil)
            startNext()
        case .success(.finished(let text, let flushDuration)):
            publish(text)
            let result = TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                modelID: configuration.model.modelID, actualAudioDuration: Double(acceptedSamples) / 16000,
                queueDuration: job.admitted.duration(to: began), inferenceDuration: inferenceDuration,
                totalDuration: started.duration(to: ended), finalizationDuration: flushDuration)
            // This is the completion point. Later cancel cannot undo the cached final result.
            finalResult = result; phase = .finished; active = nil
            mailbox.finish()
            await release?(true)
            model = nil; release = nil
            settled = true
            job.continuation?.resume(returning: result)
            settleWaiters()
        case .failure(let error):
            requestCancellation(error is CancellationError ? .cancelled : .inferenceFailed)
            active = nil
            resetAndRelease(alreadyReset: resetAttempted, reusable: !resetAttempted || resetSucceeded)
        }
    }

    private func publish(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != lastText, phase == .open || phase == .finishing else { return }
        lastText = text; revision += 1
        mailbox.yield(.init(sessionID: id, revision: revision, fullTranscript: text,
                                       receivedAudioPosition: receivedSamples))
    }

    private func requestCancellation(_ reason: ParakeetError) {
        guard phase != .finished, phase != .cancelled, phase != .cancelling else { return }
        terminalError = reason; phase = .cancelling
        mailbox.finish(throwing: reason)
        deadline?.cancel(); deadline = nil
        active?.continuation?.resume(throwing: reason); active?.continuation = nil
        worker?.cancel()
        for job in queue {
            job.deadline?.cancel(); job.continuation?.resume(throwing: reason)
        }
        queue.removeAll(); queuedSamples = 0
        if active == nil { resetAndRelease(alreadyReset: false) }
    }

    private func resetAndRelease(alreadyReset: Bool, reusable initialReusable: Bool = true) {
        guard cleanup == nil else { return }
        cleanup = Task {
            var reusable = initialReusable
            if !alreadyReset {
                do { try await model?.reset() } catch { reusable = false }
            }
            await release?(reusable)
            model = nil; release = nil
            phase = .cancelled
            settled = true
            cleanup = nil
            settleWaiters()
        }
    }

    private func settleWaiters() {
        for waiter in settlementWaiters { waiter.resume() }
        settlementWaiters.removeAll()
    }

    var pendingJobCount: Int { queue.count }
    var retainedQueuedSamples: Int { queuedSamples }
}
