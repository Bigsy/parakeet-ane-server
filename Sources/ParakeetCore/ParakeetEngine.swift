import Foundation

/// One engine owns one model stack. Operations stay exclusive across actor suspension.
/// Cancellation/deadlines end a wait but do not promise to preempt a CoreML prediction.
public actor ParakeetEngine {
    public nonisolated let configuration: EngineConfiguration
    public nonisolated let modelID: String
    public private(set) var state: EngineState = .unloaded
    private var model: (any SpeechModel)?
    private let loader: ModelLoader
    private let streamingLoader: StreamingLoader
    private var streamingModel: (any StreamingModel)?
    private var streamingSession: StreamingSession?
    private var streamingSessionID: UUID?
    public var isBusy: Bool { state == .preparing || active != nil || !queue.isEmpty || streamingSessionID != nil }
    public nonisolated var supportsStreaming: Bool { configuration.model.supportsStreaming }

    typealias StreamingLoader = @Sendable (EngineConfiguration, @escaping @Sendable (PreparationProgress) -> Void) async throws -> any StreamingModel
    private var queue: [Job] = []
    private var queuedSamples = 0
    private var active: Job?
    private var activeTask: Task<Void, Never>?
    private var activeDeadline: Task<Void, Never>?

    typealias ModelLoader = @Sendable (EngineConfiguration, @escaping @Sendable (PreparationProgress) -> Void) async throws -> any SpeechModel

    public init(configuration: EngineConfiguration = .init()) {
        self.configuration = configuration
        self.modelID = configuration.model.modelID
        self.loader = loadSpeechModel
        self.streamingLoader = loadStreamingModel
    }

    init(configuration: EngineConfiguration = .init(), loader: @escaping ModelLoader) {
        self.configuration = configuration; self.modelID = configuration.model.modelID; self.loader = loader
        self.streamingLoader = loadStreamingModel
    }

    /// Test seam for the server adapter; no bypass is exported from the library.
    init(configuration: EngineConfiguration = .init(), preparedModel: any SpeechModel) {
        self.configuration = configuration; self.modelID = preparedModel.id; self.loader = loadSpeechModel
        self.streamingLoader = loadStreamingModel
        self.model = preparedModel; self.state = .ready
    }

    init(configuration: EngineConfiguration, streamingLoader: @escaping StreamingLoader) {
        self.configuration = configuration; self.modelID = configuration.model.modelID
        self.loader = loadSpeechModel; self.streamingLoader = streamingLoader
    }

    init(configuration: EngineConfiguration = .init(mode: .streaming), preparedStreamingModel: any StreamingModel) {
        self.configuration = configuration; self.modelID = configuration.model.modelID
        self.loader = loadSpeechModel; self.streamingLoader = loadStreamingModel
        self.streamingModel = preparedStreamingModel; self.state = .ready
    }

    /// Repeated successful prepare is a no-op; concurrent prepare returns busy.
    /// Callbacks run on an unspecified executor; dispatch GUI updates to MainActor.
    public func prepare(progress: @escaping @Sendable (PreparationProgress) -> Void = { _ in }) async throws {
        try checkCancellation()
        try configuration.validate()
        if state == .ready { return }
        guard state != .preparing else { throw ParakeetError.busy }
        state = .preparing
        do {
            if configuration.mode == .streaming {
                let loaded = try await streamingLoader(configuration, progress)
                try checkCancellation()
                progress(.init(stage: .warmingUp))
                do {
                    try await loaded.append([Float](repeating: 0, count: PCM16kMono.sampleRate))
                    _ = try await loaded.finish()
                    try await loaded.reset()
                } catch {
                    if Task.isCancelled || error is CancellationError { throw ParakeetError.cancelled }
                    throw ParakeetError.preparationFailed
                }
                try checkCancellation()
                streamingModel = loaded; state = .ready
                progress(.init(stage: .ready))
                return
            }
            let loaded = try await loader(configuration, progress)
            try checkCancellation()
            progress(.init(stage: .warmingUp))
            do {
                _ = try await loaded.transcribe([Float](repeating: 0, count: PCM16kMono.sampleRate))
            } catch {
                if Task.isCancelled || error is CancellationError { throw ParakeetError.cancelled }
                throw ParakeetError.preparationFailed
            }
            try checkCancellation()
            model = loaded; state = .ready
            progress(.init(stage: .ready))
        } catch {
            model = nil; streamingModel = nil; state = .failed
            if Task.isCancelled || error is CancellationError { throw ParakeetError.cancelled }
            throw error as? ParakeetError ?? .preparationFailed
        }
    }

    /// Rejects active/queued work rather than suspending indefinitely on nonpreemptible inference.
    /// Releasing model references does not guarantee immediate OS memory reclamation.
    public func unload() throws {
        guard !isBusy else { throw ParakeetError.busy }
        model = nil; streamingModel = nil; state = .unloaded
    }

    public func startStreaming() throws -> StreamingSession {
        try checkCancellation()
        try configuration.validate()
        guard state == .ready else { throw ParakeetError.notReady }
        guard configuration.mode == .streaming, let streamingModel else { throw ParakeetError.unsupportedMode }
        guard !isBusy else { throw ParakeetError.busy }
        let id = UUID()
        let session = StreamingSession(id: id, model: streamingModel, configuration: configuration) { reusable in
            await self.releaseSession(id, reusable: reusable)
        }
        streamingSessionID = id; streamingSession = session
        return session
    }

    /// Explicit recovery for an abandoned session. Prompt cancellation; unload remains busy
    /// until nonpreemptible work and reset settle. No observation-stream cancellation is inferred.
    public func cancelStreaming() async { await streamingSession?.cancel() }

    private func releaseSession(_ id: UUID, reusable: Bool) {
        guard streamingSessionID == id else { return }
        streamingSession = nil; streamingSessionID = nil
        if !reusable { streamingModel = nil; state = .failed }
    }

    public func transcribe(_ audio: PCM16kMono) async throws -> TranscriptionResult {
        try checkCancellation()
        try configuration.validate()
        guard state == .ready else { throw ParakeetError.notReady }
        guard configuration.mode == .batch else { throw ParakeetError.unsupportedMode }
        guard model != nil else { throw ParakeetError.notReady }
        guard audio.samples.count <= configuration.maximumAudioSamples else { throw ParakeetError.audioLimitExceeded }
        let start = ContinuousClock.now
        if audio.samples.isEmpty {
            return .init(text: "", modelID: modelID, actualAudioDuration: 0,
                         queueDuration: .zero, inferenceDuration: .zero, totalDuration: start.duration(to: .now))
        }
        let id = UUID()
        let cancellation = CancellationFlag()
        let result: TranscriptionResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The caller can be cancelled before the handler's actor message arrives.
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(throwing: ParakeetError.cancelled); return
                }
                if active != nil {
                    guard queue.count < configuration.queueCapacity,
                          audio.samples.count <= configuration.maximumQueuedSamples - queuedSamples
                    else { continuation.resume(throwing: ParakeetError.queueFull); return }
                }
                var job = Job(id: id, audio: audio, admitted: start, cancellation: cancellation, continuation: continuation)
                if active != nil, let timeout = configuration.queueWaitTimeout {
                    job.deadline = Task {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self.cancel(id, reason: .queueDeadlineExceeded)
                    }
                }
                queue.append(job); queuedSamples += audio.samples.count
                startNext()
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(id, reason: .cancelled) }
        }
        try checkCancellation()
        return result
    }

    private struct Job {
        let id: UUID
        let audio: PCM16kMono
        let admitted: ContinuousClock.Instant
        let cancellation: CancellationFlag
        var continuation: CheckedContinuation<TranscriptionResult, any Error>?
        var deadline: Task<Void, Never>?
    }

    private func startNext() {
        guard active == nil, !queue.isEmpty, let model else { return }
        let job = queue.removeFirst()
        queuedSamples -= job.audio.samples.count
        job.deadline?.cancel()
        active = job
        let began = ContinuousClock.now
        if let timeout = configuration.inferenceTimeout {
            activeDeadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.cancel(job.id, reason: .inferenceDeadlineExceeded)
            }
        }
        activeTask = Task {
            let outcome: Result<String, any Error>
            do {
                try Task.checkCancellation()
                guard !job.cancellation.isCancelled else { throw CancellationError() }
                let samples = job.audio.samples
                let padded = samples.count < PCM16kMono.sampleRate
                    ? samples + [Float](repeating: 0, count: PCM16kMono.sampleRate - samples.count) : samples
                guard !job.cancellation.isCancelled else { throw CancellationError() }
                let text = try await model.transcribe(padded)
                try Task.checkCancellation()
                guard !job.cancellation.isCancelled else { throw CancellationError() }
                outcome = .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch { outcome = .failure(error) }
            self.complete(job.id, began: began, outcome: outcome)
        }
    }

    private func cancel(_ id: UUID, reason: ParakeetError) {
        if active?.id == id {
            active?.continuation?.resume(throwing: reason)
            active?.continuation = nil
            activeTask?.cancel()
            // Ownership remains until complete(), even if upstream ignores cancellation.
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let job = queue.remove(at: index)
            queuedSamples -= job.audio.samples.count
            job.deadline?.cancel()
            job.continuation?.resume(throwing: reason)
        }
    }

    private func complete(_ id: UUID, began: ContinuousClock.Instant, outcome: Result<String, any Error>) {
        guard let job = active, job.id == id else { return }
        let ended = ContinuousClock.now
        activeDeadline?.cancel(); activeDeadline = nil
        activeTask = nil; active = nil
        switch outcome {
        case .success(let text):
            job.continuation?.resume(returning: .init(
                text: text, modelID: modelID, actualAudioDuration: job.audio.duration,
                queueDuration: job.admitted.duration(to: began), inferenceDuration: began.duration(to: ended),
                totalDuration: job.admitted.duration(to: ended)))
        case .failure(let error):
            job.continuation?.resume(throwing: error is CancellationError ? ParakeetError.cancelled : ParakeetError.inferenceFailed)
        }
        startNext()
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ParakeetError.cancelled }
    }

    // Internal observability for deterministic barrier tests, without public model injection.
    var pendingJobCount: Int { queue.count }
    var retainedQueuedSamples: Int { queuedSamples }
}
