import Foundation

/// Owned, immutable 16,000 Hz mono Float32 PCM, conventionally normalized to -1...1.
/// No container header. Capture/resampling and channel mixing belong to the caller.
/// Finite samples outside -1...1 are preserved (never clipped or normalized).
public struct PCM16kMono: Sendable {
    public static let sampleRate = 16_000
    public let samples: [Float]
    public var duration: Double { Double(samples.count) / Double(Self.sampleRate) }

    public init(samples: [Float], maximumSamples: Int = 120 * sampleRate) throws {
        if Task.isCancelled { throw ParakeetError.cancelled }
        guard maximumSamples >= 0 else { throw ParakeetError.invalidConfiguration }
        guard samples.count <= maximumSamples else { throw ParakeetError.audioLimitExceeded }
        guard samples.allSatisfy(\.isFinite) else { throw ParakeetError.invalidAudio }
        self.samples = samples
    }
}

public enum ParakeetError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration, invalidAudio, audioLimitExceeded, queueFull, busy, notReady
    case missingCache, downloadFailed, preparationFailed, inferenceFailed, cancelled
    case queueDeadlineExceeded, inferenceDeadlineExceeded, unsupportedMode
    case invalidSampleOffset, sessionFinished

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid engine limits or cache root."
        case .invalidAudio: "PCM must contain only finite 16 kHz mono samples."
        case .audioLimitExceeded: "Audio exceeds the configured sample limit."
        case .queueFull: "The transcription queue is full; retry after current work settles."
        case .busy: "The engine owns an active operation; finish or cancel it first."
        case .notReady: "Prepare the engine before transcribing."
        case .missingCache: "Model cache is missing or incomplete; allow downloads to prepare it."
        case .downloadFailed: "Model download failed; check connectivity and retry preparation."
        case .preparationFailed: "Model load or warm-up failed; check the cache and retry preparation."
        case .inferenceFailed: "Speech inference failed."
        case .cancelled: "The operation was cancelled."
        case .queueDeadlineExceeded: "The queue wait deadline expired."
        case .inferenceDeadlineExceeded: "The inference deadline expired; model work may still be settling."
        case .unsupportedMode: "This model does not support the selected mode."
        case .invalidSampleOffset: "Streaming chunks must use contiguous sample offsets."
        case .sessionFinished: "This streaming session has finished."
        }
    }
}

public enum EngineMode: Sendable { case batch, streaming }
public enum DownloadPolicy: Sendable { case allow, requireCached }
public enum EngineState: Sendable, Equatable { case unloaded, preparing, ready, failed }

public struct EngineConfiguration: Sendable {
    public var model: ModelChoice
    public var mode: EngineMode
    /// Base Models directory, containing FluidAudio's repository-named subdirectories.
    public var cacheRoot: URL?
    public var downloadPolicy: DownloadPolicy
    /// Waiting jobs, excluding the active job.
    public var queueCapacity: Int
    public var maximumAudioSamples: Int
    public var maximumQueuedSamples: Int
    public var queueWaitTimeout: Duration?
    public var inferenceTimeout: Duration?
    public var maximumStreamingChunkSamples: Int

    public init(
        model: ModelChoice = .unified, mode: EngineMode = .batch,
        cacheRoot: URL? = nil, downloadPolicy: DownloadPolicy = .allow,
        queueCapacity: Int = 8, maximumAudioSamples: Int = 120 * PCM16kMono.sampleRate,
        maximumQueuedSamples: Int = 240 * PCM16kMono.sampleRate,
        queueWaitTimeout: Duration? = nil, inferenceTimeout: Duration? = nil,
        maximumStreamingChunkSamples: Int = PCM16kMono.sampleRate
    ) {
        self.model = model; self.mode = mode; self.cacheRoot = cacheRoot
        self.downloadPolicy = downloadPolicy; self.queueCapacity = queueCapacity
        self.maximumAudioSamples = maximumAudioSamples; self.maximumQueuedSamples = maximumQueuedSamples
        self.queueWaitTimeout = queueWaitTimeout; self.inferenceTimeout = inferenceTimeout
        self.maximumStreamingChunkSamples = maximumStreamingChunkSamples
    }

    func validate() throws {
        guard queueCapacity >= 0, maximumAudioSamples >= 0, maximumQueuedSamples >= 0,
              maximumStreamingChunkSamples > 0,
              cacheRoot == nil || cacheRoot!.isFileURL,
              queueWaitTimeout == nil || queueWaitTimeout! > .zero,
              inferenceTimeout == nil || inferenceTimeout! > .zero
        else { throw ParakeetError.invalidConfiguration }
        guard mode == .batch || model == .unified else { throw ParakeetError.unsupportedMode }
    }
}

public struct PreparationProgress: Sendable, Equatable {
    public enum Stage: Sendable { case checkingCache, downloading, loading, warmingUp, ready }
    public let stage: Stage
    /// Only provided when upstream supplies a fraction, for its download/compile operation.
    public let fractionCompleted: Double?
    public init(stage: Stage, fractionCompleted: Double? = nil) {
        self.stage = stage; self.fractionCompleted = fractionCompleted
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let modelID: String
    public let actualAudioDuration: Double
    public let queueDuration: Duration
    public let inferenceDuration: Duration
    public let totalDuration: Duration
    /// Streaming residual flush only; nil for batch.
    public let finalizationDuration: Duration?

    init(text: String, modelID: String, actualAudioDuration: Double, queueDuration: Duration,
         inferenceDuration: Duration, totalDuration: Duration, finalizationDuration: Duration? = nil) {
        self.text = text; self.modelID = modelID; self.actualAudioDuration = actualAudioDuration
        self.queueDuration = queueDuration; self.inferenceDuration = inferenceDuration
        self.totalDuration = totalDuration; self.finalizationDuration = finalizationDuration
    }
}
